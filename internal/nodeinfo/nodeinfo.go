// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package nodeinfo

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/puttsk/hostlist"
	corev1 "k8s.io/api/core/v1"
	resourcev1 "k8s.io/api/resource/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/SlinkyProject/slurm-bridge/internal/scheduler/plugins/slurmbridge/slurmcontrol"
	"github.com/SlinkyProject/slurm-bridge/internal/utils/bitmaputil"
	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
)

// Represents a Kubernetes node for Slurm.
type NodeInfo struct {
	CpuMap  CPUMap
	GpuMap  GPUMap
	NetMaps map[string]NetMap
}

func (n *NodeInfo) GetDeviceRequests(ctx context.Context, kubeclient client.Client, resources *slurmcontrol.NodeResources) ([]resourcev1.DeviceRequest, error) {
	var requests []resourcev1.DeviceRequest

	if resources == nil {
		return requests, nil
	}

	if hasDeviceClass(ctx, kubeclient, DraDriverCpu) {
		bitmap, err := bitmaputil.NewFrom(resources.CoreBitmap)
		if err != nil {
			return nil, err
		}
		cpuSet := n.CpuMap.ToMachineCPUs(bitmap)
		cpuSetString := strings.ReplaceAll(fmt.Sprint(cpuSet.List()), " ", ",")
		req := resourcev1.DeviceRequest{
			Name: corev1.ResourceCPU.String(),
			Exactly: &resourcev1.ExactDeviceRequest{
				DeviceClassName: DraDriverCpu,
				AllocationMode:  resourcev1.DeviceAllocationModeExactCount,
				Count:           int64(cpuSet.Size()),
				Selectors: []resourcev1.DeviceSelector{
					{
						CEL: &resourcev1.CELDeviceSelector{
							Expression: fmt.Sprintf("device.attributes['%s'].cpuID in %s", DraDriverCpu, cpuSetString),
						},
					},
				},
			},
		}
		requests = append(requests, req)
	}

	for _, gres := range resources.Gres {
		deviceClassName := gres.Type
		if !hasDeviceClass(ctx, kubeclient, gres.Type) {
			continue
		}
		indexList, err := hostlist.Expand(fmt.Sprintf("[%s]", gres.Index))
		if err != nil {
			return nil, err
		}
		var celExpr string
		switch deviceClassName {
		case DraDriverGpuNvidia:
			// NVIDIA k8s-dra-driver-gpu: use device.attributes['gpu.nvidia.com'].name (e.g. "gpu-0", "gpu-1").
			names := make([]string, 0, len(indexList))
			for _, i := range indexList {
				names = append(names, fmt.Sprintf("'gpu-%s'", i))
			}
			celExpr = fmt.Sprintf("device.attributes['%s'].name in [%s]", DraDriverGpuNvidia, strings.Join(names, ","))
		case DraExampleDriver:
			// Example DRA driver: use device.attributes['gpu.example.com'].index (e.g. 0, 1, 2).
			indexListString := strings.Join(indexList, ",")
			celExpr = fmt.Sprintf("device.attributes['%s'].index in [%s]", deviceClassName, indexListString)
		case wellknown.DraNetDeviceClassIB:
			netMap, ok := n.NetMaps[deviceClassName]
			if !ok {
				continue
			}
			ifNames := make([]string, 0, len(indexList))
			for _, i := range indexList {
				index, err := strconv.Atoi(i)
				if err != nil {
					return nil, err
				}
				netInfo, ok := netMap.NetInfoMap[index]
				if !ok || netInfo.IfName == "" {
					continue
				}
				ifNames = append(ifNames, fmt.Sprintf("'%s'", netInfo.IfName))
			}
			if len(ifNames) == 0 {
				continue
			}
			celExpr = fmt.Sprintf("device.attributes['%s'].ifName in [%s]", wellknown.DraDriverNet, strings.Join(ifNames, ","))
		default:
			continue
		}
		req := resourcev1.DeviceRequest{
			Name: gres.Name,
			Exactly: &resourcev1.ExactDeviceRequest{
				DeviceClassName: deviceClassName,
				AllocationMode:  resourcev1.DeviceAllocationModeExactCount,
				Count:           gres.Count,
				Selectors: []resourcev1.DeviceSelector{
					{
						CEL: &resourcev1.CELDeviceSelector{
							Expression: celExpr,
						},
					},
				},
			},
		}
		requests = append(requests, req)
	}

	return requests, nil
}

func (n *NodeInfo) GetDeviceClaimConfigurations(ctx context.Context, kubeclient client.Client, resources *slurmcontrol.NodeResources) ([]resourcev1.DeviceClaimConfiguration, error) {
	configs := []resourcev1.DeviceClaimConfiguration{}

	if resources == nil {
		return configs, nil
	}

	for _, gres := range resources.Gres {
		if gres.Type != wellknown.DraNetDeviceClassIB || !hasDeviceClass(ctx, kubeclient, gres.Type) {
			continue
		}
		netMap, ok := n.NetMaps[gres.Type]
		if !ok {
			continue
		}
		indexList, err := hostlist.Expand(fmt.Sprintf("[%s]", gres.Index))
		if err != nil {
			return nil, err
		}
		if len(indexList) == 0 {
			continue
		}
		if len(indexList) > 1 || gres.Count > 1 {
			return nil, fmt.Errorf("DRANET claim config currently supports one %s device per request, got count=%d index=%q", wellknown.SlurmGresNameNIC, gres.Count, gres.Index)
		}
		index, err := strconv.Atoi(indexList[0])
		if err != nil {
			return nil, err
		}
		netInfo, ok := netMap.NetInfoMap[index]
		if !ok || netInfo.IfName == "" {
			continue
		}
		parameters, err := json.Marshal(map[string]any{
			"interface": map[string]any{
				"name": netInfo.IfName,
			},
		})
		if err != nil {
			return nil, err
		}
		configs = append(configs, resourcev1.DeviceClaimConfiguration{
			Requests: []string{gres.Name},
			DeviceConfiguration: resourcev1.DeviceConfiguration{
				Opaque: &resourcev1.OpaqueDeviceConfiguration{
					Driver: wellknown.DraDriverNet,
					Parameters: runtime.RawExtension{
						Raw: parameters,
					},
				},
			},
		})
	}

	return configs, nil
}

func (n *NodeInfo) GetDeviceRequestAllocationResult(ctx context.Context, kubeclient client.Client, resources *slurmcontrol.NodeResources) ([]resourcev1.DeviceRequestAllocationResult, error) {
	var devices []resourcev1.DeviceRequestAllocationResult

	if resources == nil {
		return devices, nil
	}

	if hasDeviceClass(ctx, kubeclient, DraDriverCpu) {
		bitmap, err := bitmaputil.NewFrom(resources.CoreBitmap)
		if err != nil {
			return nil, err
		}
		// Individual Mode: each CPU is enumerated
		cpuSet := n.CpuMap.ToMachineCPUs(bitmap)
		for _, cpuID := range cpuSet.List() {
			cpuInfo, ok := n.CpuMap.CPUInfoMap[cpuID]
			if !ok {
				continue
			}
			dev := resourcev1.DeviceRequestAllocationResult{
				Request: corev1.ResourceCPU.String(),
				Driver:  DraDriverCpu,
				Pool:    resources.Node,
				Device:  cpuInfo.Name,
			}
			devices = append(devices, dev)
		}
	}

	for _, gres := range resources.Gres {
		deviceClassName := gres.Type
		if !hasDeviceClass(ctx, kubeclient, gres.Type) {
			continue
		}
		indexList, err := hostlist.Expand(fmt.Sprintf("[%s]", gres.Index))
		if err != nil {
			return nil, err
		}
		switch deviceClassName {
		case DraDriverGpuNvidia, DraExampleDriver:
			for _, i := range indexList {
				index, err := strconv.Atoi(i)
				if err != nil {
					return nil, err
				}
				gpuInfo, ok := n.GpuMap.GPUInfoMap[index]
				if !ok {
					continue
				}
				dev := resourcev1.DeviceRequestAllocationResult{
					Request: gres.Name,
					Driver:  deviceClassName,
					Pool:    resources.Node,
					Device:  gpuInfo.Name,
				}
				devices = append(devices, dev)
			}
		case wellknown.DraNetDeviceClassIB:
			netMap, ok := n.NetMaps[deviceClassName]
			if !ok {
				continue
			}
			for _, i := range indexList {
				index, err := strconv.Atoi(i)
				if err != nil {
					return nil, err
				}
				netInfo, ok := netMap.NetInfoMap[index]
				if !ok {
					continue
				}
				dev := resourcev1.DeviceRequestAllocationResult{
					Request: gres.Name,
					Driver:  wellknown.DraDriverNet,
					Pool:    netInfo.PoolName,
					Device:  netInfo.Name,
				}
				devices = append(devices, dev)
			}
		}
	}

	return devices, nil
}

func NewNodeInfo(ctx context.Context, kubeclient client.Client, nodeName string) (*NodeInfo, error) {
	resourceSliceList := &resourcev1.ResourceSliceList{}
	if err := kubeclient.List(ctx, resourceSliceList); err != nil {
		return nil, err
	}

	nodeInfo := &NodeInfo{}
	for _, resourceSlice := range resourceSliceList.Items {
		if ptr.Deref(resourceSlice.Spec.NodeName, "") != nodeName {
			continue
		}
		switch resourceSlice.Spec.Driver {
		case DraDriverCpu:
			cpuInfos := NewCPUInfos(&resourceSlice)
			nodeInfo.CpuMap = NewCPUMap(cpuInfos)
		case DraExampleDriver, DraDriverGpuNvidia:
			gpuInfos := NewGPUInfos(ctx, &resourceSlice)
			nodeInfo.GpuMap = NewGPUMap(resourceSlice.Spec.Driver, gpuInfos)
		case wellknown.DraDriverNet:
			netInfos := NewNetInfos(&resourceSlice)
			if len(netInfos) > 0 {
				if nodeInfo.NetMaps == nil {
					nodeInfo.NetMaps = map[string]NetMap{}
				}
				nodeInfo.NetMaps[wellknown.DraNetDeviceClassIB] = NewNetMap(wellknown.DraNetDeviceClassIB, netInfos)
			}
		default:
			// TODO: can we even default?
		}
	}

	return nodeInfo, nil
}

// GetGresAndGresConf returns Slurm GRES and GresConf strings for this node's devices.
// GRES and GresConf are derived from DRA ResourceSlices (e.g. GPU and NIC devices); CPU is not included.
// Returns ("", "") when the node has no GRES devices.
func (n *NodeInfo) GetGresAndGresConf() (gres, gresConf string) {
	gresParts := []string{}
	gresConfParts := []string{}
	if len(n.GpuMap.GPUInfoMap) > 0 {
		count := len(n.GpuMap.GPUInfoMap)
		gresParts = append(gresParts, fmt.Sprintf("gpu:%s:%d", n.GpuMap.Driver, count))
		gresConfParts = append(gresConfParts, formatGresConf("gpu", n.GpuMap.Driver, gpuDeviceFiles(n.GpuMap)))
	}

	netClasses := make([]string, 0, len(n.NetMaps))
	for deviceClass := range n.NetMaps {
		netClasses = append(netClasses, deviceClass)
	}
	sort.Strings(netClasses)
	for _, deviceClass := range netClasses {
		netMap := n.NetMaps[deviceClass]
		if len(netMap.NetInfoMap) == 0 {
			continue
		}
		gresParts = append(gresParts, fmt.Sprintf("%s:%s:%d", wellknown.SlurmGresNameNIC, deviceClass, len(netMap.NetInfoMap)))
		gresConfParts = append(gresConfParts, formatGresConf(wellknown.SlurmGresNameNIC, deviceClass, netDeviceFiles(netMap)))
	}

	return strings.Join(gresParts, ","), strings.Join(gresConfParts, ";")
}

func gpuDeviceFiles(gpuMap GPUMap) []string {
	count := len(gpuMap.GPUInfoMap)
	indices := make([]int, 0, count)
	for idx := range gpuMap.GPUInfoMap {
		indices = append(indices, idx)
	}
	sort.Ints(indices)
	files := make([]string, 0, count)
	for _, idx := range indices {
		info := gpuMap.GPUInfoMap[idx]
		deviceName := fmt.Sprintf("gpu-%d", idx)
		if info != nil && info.Name != "" {
			deviceName = info.Name
		}
		files = append(files, deviceName)
	}
	return files
}

func netDeviceFiles(netMap NetMap) []string {
	indices := make([]int, 0, len(netMap.NetInfoMap))
	for idx := range netMap.NetInfoMap {
		indices = append(indices, idx)
	}
	sort.Ints(indices)
	files := make([]string, 0, len(indices))
	for _, idx := range indices {
		info := netMap.NetInfoMap[idx]
		deviceName := fmt.Sprintf("nic-%d", idx)
		if info != nil && info.IfName != "" {
			deviceName = info.IfName
		} else if info != nil && info.Name != "" {
			deviceName = info.Name
		}
		files = append(files, deviceName)
	}
	return files
}

func formatGresConf(name, deviceType string, files []string) string {
	fileParts := make([]string, 0, len(files))
	for _, file := range files {
		fileParts = append(fileParts, "file="+file)
	}
	return fmt.Sprintf("count=%d,name=%s,type=%s,%s", len(files), name, deviceType, strings.Join(fileParts, ","))
}

func hasDeviceClass(ctx context.Context, kubeclient client.Client, deviceClassName string) bool {
	if deviceClassName == "" {
		return false
	}
	deviceClass := &resourcev1.DeviceClass{}
	err := kubeclient.Get(ctx, types.NamespacedName{Name: deviceClassName}, deviceClass)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return false
		}
		return false
	}
	return true
}
