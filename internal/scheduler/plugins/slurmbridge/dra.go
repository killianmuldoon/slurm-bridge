// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-FileCopyrightText: Copyright 2024 The Kubernetes Authors.
// SPDX-License-Identifier: Apache-2.0

package slurmbridge

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/puttsk/hostlist"
	corev1 "k8s.io/api/core/v1"
	resourcev1 "k8s.io/api/resource/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/klog/v2"
	"k8s.io/kubernetes/pkg/util/slice"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/SlinkyProject/slurm-bridge/internal/nodeinfo"
	"github.com/SlinkyProject/slurm-bridge/internal/scheduler/plugins/slurmbridge/slurmcontrol"
)

// manageResourceClaim will create DRA ResourceClaims for each
// Slurm GRES type that matches a DRA DeviceClass name. Additionally,
// if the CPU DRA driver is installed, A ResourceClaim for CPUs will
// be generated. The ResourceClaim is reconstructed in a similar manner
// to the way the Kubernetes scheduler handles the DRA Extended Resource
// Claim capability.
func (sb *SlurmBridge) manageResourceClaim(ctx context.Context, pod *corev1.Pod, nodeName string, resources *slurmcontrol.NodeResources) error {
	logger := klog.FromContext(ctx)
	claim, requestMappings, claimResources, err := sb.createRequestsAndMappings(ctx, pod, nodeName, resources)
	if err != nil {
		logger.Error(err, "failed to prepare DRA extended resource claim", "pod", klog.KObj(pod), "node", nodeName)
		return err
	}
	if claim == nil || requestMappings == nil || claimResources == nil {
		logger.V(4).Info("no DRA extended resource claim needed", "pod", klog.KObj(pod), "node", nodeName)
		return nil
	}

	logger.Info("Creating generated DRA extended ResourceClaim",
		"pod", klog.KObj(pod),
		"node", nodeName,
		"generateName", claim.GenerateName,
		"deviceRequests", len(claim.Spec.Devices.Requests),
		"deviceConfigs", len(claim.Spec.Devices.Config),
		"requestMappings", requestMappings)
	if err := sb.Create(ctx, claim); err != nil {
		return fmt.Errorf("create claim for extended resources %v: %w", klog.KObj(claim), err)
	}
	logger.Info("Created generated DRA extended ResourceClaim", "pod", klog.KObj(pod), "claim", klog.KObj(claim))

	if err := sb.bindClaim(ctx, claim, pod, nodeName, claimResources); err != nil {
		return err
	}

	if err := sb.patchPodExtendedResourceClaimStatus(ctx, pod, claim, requestMappings); err != nil {
		return err
	}

	return nil
}

func (sb *SlurmBridge) createRequestsAndMappings(ctx context.Context, pod *corev1.Pod, nodeName string, resources *slurmcontrol.NodeResources) (*resourcev1.ResourceClaim, []corev1.ContainerExtendedResourceRequest, *slurmcontrol.NodeResources, error) {
	if pod == nil {
		return nil, nil, nil, errors.New("expected a pod to be given")
	}
	logger := klog.FromContext(ctx)
	requiresDRAExtendedClaim := podRequestsDRAExtendedResource(pod)

	claimResources, mappings, err := buildClaimResourcesAndMappings(pod, resources)
	if err != nil {
		return nil, nil, nil, err
	}
	if len(mappings) == 0 {
		if requiresDRAExtendedClaim {
			return nil, nil, nil, errors.New("pod requests DRA extended resources but no matching Slurm GRES allocation was found")
		}
		logger.V(4).Info("no Slurm GRES mappings for DRA extended ResourceClaim", "pod", klog.KObj(pod), "node", nodeName)
		return nil, nil, nil, nil
	}

	nodeInfo, err := nodeinfo.NewNodeInfo(ctx, sb.Client, nodeName)
	if err != nil {
		return nil, nil, nil, err
	}

	deviceRequests, err := nodeInfo.GetDeviceRequests(ctx, sb.Client, claimResources)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("get generated device requests from Slurm resources %+v: %w", claimResources, err)
	}
	logger.Info("Generated DRA extended resource device requests",
		"pod", klog.KObj(pod),
		"node", nodeName,
		"claimResources", claimResources,
		"deviceRequests", summarizeDeviceRequests(deviceRequests),
		"requestMappings", mappings)
	if len(deviceRequests) == 0 {
		if requiresDRAExtendedClaim {
			return nil, nil, nil, errors.New("pod requests DRA extended resources but no generated device requests were created")
		}
		logger.V(4).Info("no device requests for DRA extended ResourceClaim", "pod", klog.KObj(pod), "node", nodeName, "requestMappings", mappings)
		return nil, nil, nil, nil
	}
	deviceConfigs, err := nodeInfo.GetDeviceClaimConfigurations(ctx, sb.Client, claimResources)
	if err != nil {
		return nil, nil, nil, err
	}
	mappings = filterMappingsForDeviceRequests(mappings, deviceRequests)
	if len(mappings) == 0 {
		if requiresDRAExtendedClaim {
			return nil, nil, nil, errors.New("pod requests DRA extended resources but no generated request mappings matched device requests")
		}
		logger.V(4).Info("no request mappings matched generated device requests for DRA extended ResourceClaim",
			"pod", klog.KObj(pod),
			"node", nodeName,
			"deviceRequests", len(deviceRequests))
		return nil, nil, nil, nil
	}

	claim := &resourcev1.ResourceClaim{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:    pod.Namespace,
			GenerateName: pod.Name + "-extended-resources-",
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion:         "v1",
					Kind:               "Pod",
					Name:               pod.Name,
					UID:                pod.UID,
					Controller:         ptr.To(true),
					BlockOwnerDeletion: ptr.To(true),
				},
			},
			Annotations: map[string]string{
				resourcev1.ExtendedResourceClaimAnnotation: "true",
			},
		},
		Spec: resourcev1.ResourceClaimSpec{
			Devices: resourcev1.DeviceClaim{
				Requests: deviceRequests,
				Config:   deviceConfigs,
			},
		},
	}

	return claim, mappings, claimResources, nil
}

type gresCursor struct {
	layout  slurmcontrol.GresLayout
	indices []string
	next    int
}

func buildClaimResourcesAndMappings(pod *corev1.Pod, resources *slurmcontrol.NodeResources) (*slurmcontrol.NodeResources, []corev1.ContainerExtendedResourceRequest, error) {
	claimResources := &slurmcontrol.NodeResources{}
	if resources != nil {
		*claimResources = *resources
	}
	claimResources.Gres = nil

	containers := slices.Clone(pod.Spec.InitContainers)
	containers = append(containers, pod.Spec.Containers...)

	var mappings []corev1.ContainerExtendedResourceRequest
	cursors := map[string]*gresCursor{}
	cpuRequestName := ""

	for containerIndex, container := range containers {
		creqs := container.Resources.Requests
		keys := make([]string, 0, len(creqs))
		for k := range creqs {
			keys = append(keys, k.String())
		}
		// Resource requests are a map; sort names to match kubelet's stable request naming.
		slice.SortStrings(keys)
		for ridx, key := range keys {
			rName := corev1.ResourceName(key)
			quantity := creqs[rName]
			if quantity.Value() <= 0 {
				continue
			}
			reqName := fmt.Sprintf("container-%d-request-%d", containerIndex, ridx)
			if key == corev1.ResourceCPU.String() {
				if cpuRequestName == "" {
					cpuRequestName = reqName
					claimResources.CPURequestName = reqName
				}
				mappings = append(mappings, corev1.ContainerExtendedResourceRequest{
					ContainerName: container.Name,
					RequestName:   cpuRequestName,
					ResourceName:  corev1.ResourceCPU.String(),
				})
				continue
			}

			deviceClassName, ok := deviceClassNameFromResourceName(rName)
			if !ok {
				continue
			}
			cursor, err := getGresCursor(cursors, resources, deviceClassName)
			if err != nil {
				return nil, nil, err
			}
			if cursor == nil {
				continue
			}
			count := int(quantity.Value())
			if cursor.next+count > len(cursor.indices) {
				return nil, nil, fmt.Errorf("not enough Slurm GRES indices for %s: requested %d, available %d, index=%q", deviceClassName, count, len(cursor.indices)-cursor.next, cursor.layout.Index)
			}
			selected := cursor.indices[cursor.next : cursor.next+count]
			cursor.next += count

			claimResources.Gres = append(claimResources.Gres, slurmcontrol.GresLayout{
				Name:  reqName,
				Type:  cursor.layout.Type,
				Count: int64(count),
				Index: strings.Join(selected, ","),
			})
			mappings = append(mappings, corev1.ContainerExtendedResourceRequest{
				ContainerName: container.Name,
				RequestName:   reqName,
				ResourceName:  key,
			})
		}
	}

	return claimResources, mappings, nil
}

func podRequestsDRAExtendedResource(pod *corev1.Pod) bool {
	containers := slices.Clone(pod.Spec.InitContainers)
	containers = append(containers, pod.Spec.Containers...)
	for _, container := range containers {
		for resourceName, quantity := range container.Resources.Requests {
			if quantity.Value() > 0 && strings.HasPrefix(resourceName.String(), resourcev1.ResourceDeviceClassPrefix) {
				return true
			}
		}
	}
	return false
}

func deviceClassNameFromResourceName(resourceName corev1.ResourceName) (string, bool) {
	name := resourceName.String()
	if !strings.HasPrefix(name, resourcev1.ResourceDeviceClassPrefix) {
		return "", false
	}
	return strings.TrimPrefix(name, resourcev1.ResourceDeviceClassPrefix), true
}

func getGresCursor(cursors map[string]*gresCursor, resources *slurmcontrol.NodeResources, deviceClassName string) (*gresCursor, error) {
	if cursor, ok := cursors[deviceClassName]; ok {
		return cursor, nil
	}
	if resources == nil {
		return nil, nil
	}
	for _, gres := range resources.Gres {
		if gres.Type != deviceClassName {
			continue
		}
		if gres.Index == "" {
			return nil, fmt.Errorf("Slurm GRES %s:%s did not include concrete IDX; cannot generate deterministic DRA claim", gres.Name, gres.Type)
		}
		indices, err := hostlist.Expand(fmt.Sprintf("[%s]", gres.Index))
		if err != nil {
			return nil, err
		}
		cursor := &gresCursor{layout: gres, indices: indices}
		cursors[deviceClassName] = cursor
		return cursor, nil
	}
	return nil, nil
}

func filterMappingsForDeviceRequests(mappings []corev1.ContainerExtendedResourceRequest, requests []resourcev1.DeviceRequest) []corev1.ContainerExtendedResourceRequest {
	requestNames := map[string]struct{}{}
	for _, req := range requests {
		requestNames[req.Name] = struct{}{}
	}
	filtered := mappings[:0]
	for _, mapping := range mappings {
		if _, ok := requestNames[mapping.RequestName]; ok {
			filtered = append(filtered, mapping)
		}
	}
	return filtered
}

type deviceRequestSummary struct {
	Name            string `json:"name"`
	DeviceClassName string `json:"deviceClassName"`
	Count           int64  `json:"count"`
	Expression      string `json:"expression,omitempty"`
}

func summarizeDeviceRequests(requests []resourcev1.DeviceRequest) []deviceRequestSummary {
	summary := make([]deviceRequestSummary, 0, len(requests))
	for _, request := range requests {
		item := deviceRequestSummary{Name: request.Name}
		if request.Exactly != nil {
			item.DeviceClassName = request.Exactly.DeviceClassName
			item.Count = request.Exactly.Count
			if len(request.Exactly.Selectors) > 0 && request.Exactly.Selectors[0].CEL != nil {
				item.Expression = request.Exactly.Selectors[0].CEL.Expression
			}
		}
		summary = append(summary, item)
	}
	return summary
}

// bindClaim gets called for claims which are not reserved for the pod yet.
// It might not even be allocated. bindClaim then ensures that the allocation
// and reservation are recorded.
func (sb *SlurmBridge) bindClaim(
	ctx context.Context,
	claim *resourcev1.ResourceClaim,
	pod *corev1.Pod,
	nodeName string,
	resources *slurmcontrol.NodeResources,
) error {
	logger := klog.FromContext(ctx)
	nodeInfo, err := nodeinfo.NewNodeInfo(ctx, sb.Client, nodeName)
	if err != nil {
		return err
	}

	devices, err := nodeInfo.GetDeviceRequestAllocationResult(ctx, sb.Client, resources)
	if err != nil {
		return err
	}
	logger.Info("Binding generated DRA extended ResourceClaim",
		"pod", klog.KObj(pod),
		"claim", klog.KObj(claim),
		"node", nodeName,
		"allocationResults", len(devices))

	toUpdate := claim.DeepCopy()

	toUpdate.Status.Allocation = &resourcev1.AllocationResult{
		AllocationTimestamp: &metav1.Time{
			Time: time.Now(),
		},
		Devices: resourcev1.DeviceAllocationResult{
			Results: devices,
		},
		NodeSelector: &corev1.NodeSelector{
			NodeSelectorTerms: []corev1.NodeSelectorTerm{
				{
					MatchFields: []corev1.NodeSelectorRequirement{
						{
							Key:      "metadata.name",
							Operator: corev1.NodeSelectorOpIn,
							Values:   []string{nodeName},
						},
					},
				},
			},
		},
	}

	toUpdate.Status.ReservedFor = []resourcev1.ResourceClaimConsumerReference{
		{Resource: "pods", Name: pod.Name, UID: pod.UID},
	}

	if err := sb.Status().Patch(ctx, toUpdate, client.StrategicMergeFrom(claim)); err != nil {
		return fmt.Errorf("failed to add reservation to claim %s status: %w", klog.KObj(claim), err)
	}
	logger.Info("Patched generated DRA extended ResourceClaim status",
		"pod", klog.KObj(pod),
		"claim", klog.KObj(claim),
		"node", nodeName,
		"allocationResults", len(devices))

	if err := sb.Get(ctx, client.ObjectKeyFromObject(claim), claim); err != nil {
		return fmt.Errorf("failed to get claim %s: %w", klog.KObj(claim), err)
	}

	return nil
}

// patchPodExtendedResourceClaimStatus updates the pod's status with information about
// the extended resource claim.
func (sb *SlurmBridge) patchPodExtendedResourceClaimStatus(
	ctx context.Context,
	pod *corev1.Pod,
	claim *resourcev1.ResourceClaim,
	requestMappings []corev1.ContainerExtendedResourceRequest,
) error {
	logger := klog.FromContext(ctx)
	if len(requestMappings) == 0 {
		return fmt.Errorf("nil or empty request mappings, no update of pod %s/%s ExtendedResourceClaimStatus", pod.Namespace, pod.Name)
	}

	toUpdate := pod.DeepCopy()
	toUpdate.Status.ExtendedResourceClaimStatus = &corev1.PodExtendedResourceClaimStatus{
		RequestMappings:   requestMappings,
		ResourceClaimName: claim.Name,
	}
	logger.Info("Patching pod ExtendedResourceClaimStatus",
		"pod", klog.KObj(pod),
		"claim", klog.KObj(claim),
		"requestMappings", requestMappings)
	if err := sb.Status().Patch(ctx, toUpdate, client.StrategicMergeFrom(pod)); err != nil {
		return fmt.Errorf("failed to update pod %s ExtendedResourceClaimStatus: %w", klog.KObj(pod), err)
	}
	logger.Info("Patched pod ExtendedResourceClaimStatus",
		"pod", klog.KObj(pod),
		"claim", klog.KObj(claim),
		"requestMappings", requestMappings)

	if err := sb.Get(ctx, client.ObjectKeyFromObject(toUpdate), toUpdate); err != nil {
		return fmt.Errorf("failed to get pod %s: %w", klog.KObj(pod), err)
	}
	persistedStatus := toUpdate.Status.ExtendedResourceClaimStatus
	if persistedStatus == nil {
		return fmt.Errorf("pod %s ExtendedResourceClaimStatus patch returned success but read-back status is empty", klog.KObj(pod))
	}
	if persistedStatus.ResourceClaimName != claim.Name {
		return fmt.Errorf("pod %s ExtendedResourceClaimStatus read-back claim name = %q, want %q", klog.KObj(pod), persistedStatus.ResourceClaimName, claim.Name)
	}
	logger.Info("Verified pod ExtendedResourceClaimStatus after read-back",
		"pod", klog.KObj(pod),
		"claim", klog.KObj(claim),
		"resourceClaimName", persistedStatus.ResourceClaimName,
		"requestMappings", persistedStatus.RequestMappings)

	return nil
}
