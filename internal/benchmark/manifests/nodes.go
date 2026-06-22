// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package manifests

import (
	"fmt"
	"io"
	"math"
	"strconv"

	"github.com/SlinkyProject/slurm-bridge/internal/benchmark/trace"
	"github.com/SlinkyProject/slurm-bridge/internal/utils"
	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	DefaultSchedulerName = "slurm-bridge-scheduler"
	DefaultPartition     = "slurm-bridge"
	DefaultPodsCapacity  = 110

	LabelSource  = "bench.ai/source"
	LabelGPUType = "bench.ai/gpu-type"
	LabelKWOK    = "kwok.x-k8s.io/node"

	SourceAlibabaPAI = "alibaba-pai-v2020"

	ResourceNvidiaGPU = corev1.ResourceName("nvidia.com/gpu")
)

type NodeOptions struct {
	SchedulerName       string
	Partition           string
	IncludeCPUOnlyNodes bool
	NodeLimit           int
	PodsCapacity        int64
}

func NodesFromMachineSpecs(specs []trace.MachineSpec, opts NodeOptions) ([]*corev1.Node, error) {
	opts = opts.withDefaults()
	if err := opts.validate(); err != nil {
		return nil, err
	}

	nodes := make([]*corev1.Node, 0, len(specs))
	seenNames := map[string]string{}
	for _, spec := range specs {
		if spec.CapGPU == 0 && !opts.IncludeCPUOnlyNodes {
			continue
		}
		if opts.NodeLimit > 0 && len(nodes) >= opts.NodeLimit {
			break
		}

		node, err := NodeFromMachineSpec(spec, opts)
		if err != nil {
			return nil, err
		}
		if previous, ok := seenNames[node.Name]; ok {
			return nil, fmt.Errorf("machine %q and %q both map to node name %q", previous, spec.Machine, node.Name)
		}
		seenNames[node.Name] = spec.Machine
		nodes = append(nodes, node)
	}

	return nodes, nil
}

func WriteNodesYAMLFromMachineSpecs(w io.Writer, r io.Reader, opts NodeOptions) (int, error) {
	opts = opts.withDefaults()
	if err := opts.validate(); err != nil {
		return 0, err
	}

	written := 0
	seenNames := map[string]string{}
	err := trace.ScanMachineSpecs(r, func(spec trace.MachineSpec) error {
		if spec.CapGPU == 0 && !opts.IncludeCPUOnlyNodes {
			return nil
		}

		node, err := NodeFromMachineSpec(spec, opts)
		if err != nil {
			return err
		}
		if previous, ok := seenNames[node.Name]; ok {
			return fmt.Errorf("machine %q and %q both map to node name %q", previous, spec.Machine, node.Name)
		}
		seenNames[node.Name] = spec.Machine

		if err := writeYAMLDocument(w, node, written > 0); err != nil {
			return err
		}
		written++
		if opts.NodeLimit > 0 && written >= opts.NodeLimit {
			return trace.ErrStopScan
		}

		return nil
	})
	if err != nil {
		return written, err
	}

	return written, nil
}

func NodeFromMachineSpec(spec trace.MachineSpec, opts NodeOptions) (*corev1.Node, error) {
	opts = opts.withDefaults()

	resources, err := nodeResourceList(spec, opts.PodsCapacity)
	if err != nil {
		return nil, fmt.Errorf("machine %q: %w", spec.Machine, err)
	}

	taint := utils.NewTaintNodeBridged(opts.SchedulerName)
	node := &corev1.Node{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "v1",
			Kind:       "Node",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name: MachineNodeName(spec.Machine),
			Labels: map[string]string{
				LabelKWOK:                   "fake",
				corev1.LabelArchStable:      "amd64",
				corev1.LabelOSStable:        "linux",
				LabelSource:                 SourceAlibabaPAI,
				LabelGPUType:                LabelValue(spec.GPUType),
				wellknown.LabelExternalNode: "true",
			},
			Annotations: map[string]string{
				wellknown.AnnotationExternalNodePartitions: opts.Partition,
			},
		},
		Spec: corev1.NodeSpec{
			Taints: []corev1.Taint{*taint},
		},
		Status: corev1.NodeStatus{
			Capacity:    resources,
			Allocatable: resources.DeepCopy(),
			Conditions: []corev1.NodeCondition{
				{
					Type:    corev1.NodeReady,
					Status:  corev1.ConditionTrue,
					Reason:  "BenchmarkNodeReady",
					Message: "benchmark fake node is ready",
				},
			},
		},
	}

	return node, nil
}

func WriteNodesYAML(w io.Writer, nodes []*corev1.Node) error {
	for i, node := range nodes {
		if err := writeYAMLDocument(w, node, i > 0); err != nil {
			return err
		}
	}
	return nil
}

func nodeResourceList(spec trace.MachineSpec, pods int64) (corev1.ResourceList, error) {
	cpu, err := resource.ParseQuantity(formatFloat(spec.CapCPU))
	if err != nil {
		return nil, fmt.Errorf("parse cpu capacity: %w", err)
	}
	memory, err := resource.ParseQuantity(fmt.Sprintf("%dGi", int64(math.Ceil(spec.CapMem))))
	if err != nil {
		return nil, fmt.Errorf("parse memory capacity: %w", err)
	}
	gpu, err := resource.ParseQuantity(strconv.FormatInt(spec.CapGPU, 10))
	if err != nil {
		return nil, fmt.Errorf("parse gpu capacity: %w", err)
	}
	podCapacity, err := resource.ParseQuantity(strconv.FormatInt(pods, 10))
	if err != nil {
		return nil, fmt.Errorf("parse pod capacity: %w", err)
	}

	return corev1.ResourceList{
		corev1.ResourceCPU:    cpu,
		corev1.ResourceMemory: memory,
		ResourceNvidiaGPU:     gpu,
		corev1.ResourcePods:   podCapacity,
	}, nil
}

func formatFloat(value float64) string {
	return strconv.FormatFloat(value, 'f', -1, 64)
}

func (o NodeOptions) withDefaults() NodeOptions {
	if o.SchedulerName == "" {
		o.SchedulerName = DefaultSchedulerName
	}
	if o.Partition == "" {
		o.Partition = DefaultPartition
	}
	if o.PodsCapacity == 0 {
		o.PodsCapacity = DefaultPodsCapacity
	}
	return o
}

func (o NodeOptions) validate() error {
	if o.NodeLimit < 0 {
		return fmt.Errorf("node limit must be non-negative")
	}
	if o.PodsCapacity < 0 {
		return fmt.Errorf("pods capacity must be non-negative")
	}
	return nil
}
