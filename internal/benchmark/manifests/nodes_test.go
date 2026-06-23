// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package manifests

import (
	"bytes"
	"strconv"
	"strings"
	"testing"

	"github.com/SlinkyProject/slurm-bridge/internal/benchmark/trace"
	"github.com/SlinkyProject/slurm-bridge/internal/nodeinfo"
	"github.com/SlinkyProject/slurm-bridge/internal/utils"
	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
	corev1 "k8s.io/api/core/v1"
)

func TestNodesFromMachineSpecsDefaultsToGPUOnly(t *testing.T) {
	specs := []trace.MachineSpec{
		{Machine: "cpu-only", GPUType: "", CapCPU: 32, CapMem: 128, CapGPU: 0},
		{Machine: "gpu-node", GPUType: "V100", CapCPU: 64, CapMem: 29.296875, CapGPU: 8},
	}

	nodes, err := NodesFromMachineSpecs(specs, NodeOptions{})
	if err != nil {
		t.Fatalf("NodesFromMachineSpecs() error = %v", err)
	}
	if len(nodes) != 1 {
		t.Fatalf("NodesFromMachineSpecs() returned %d nodes, want 1", len(nodes))
	}

	node := nodes[0]
	if node.Name != "gpu-node" {
		t.Fatalf("node.Name = %q, want gpu-node", node.Name)
	}
	if got := node.Labels[LabelKWOK]; got != "fake" {
		t.Fatalf("kwok label = %q, want fake", got)
	}
	if got := node.Labels[corev1.LabelArchStable]; got != "amd64" {
		t.Fatalf("arch label = %q, want amd64", got)
	}
	if got := node.Labels[corev1.LabelOSStable]; got != "linux" {
		t.Fatalf("os label = %q, want linux", got)
	}
	if got := node.Labels[LabelSource]; got != SourceAlibabaPAI {
		t.Fatalf("source label = %q, want %q", got, SourceAlibabaPAI)
	}
	if got := node.Labels[LabelGPUType]; got != "V100" {
		t.Fatalf("gpu type label = %q, want V100", got)
	}
	if got := node.Labels[wellknown.LabelExternalNode]; got != "true" {
		t.Fatalf("external node label = %q, want true", got)
	}
	if got := node.Annotations[wellknown.AnnotationExternalNodePartitions]; got != DefaultPartition {
		t.Fatalf("partition annotation = %q, want %q", got, DefaultPartition)
	}

	wantTaint := utils.NewTaintNodeBridged(DefaultSchedulerName)
	if len(node.Spec.Taints) != 1 || node.Spec.Taints[0] != *wantTaint {
		t.Fatalf("node taints = %#v, want %#v", node.Spec.Taints, []corev1.Taint{*wantTaint})
	}

	assertQuantityString(t, node.Status.Capacity, corev1.ResourceCPU, "64")
	assertQuantityString(t, node.Status.Capacity, corev1.ResourceMemory, "30Gi")
	assertQuantityString(t, node.Status.Capacity, ResourceNvidiaGPU, "8")
	assertQuantityString(t, node.Status.Capacity, corev1.ResourcePods, "110")
	assertQuantityString(t, node.Status.Allocatable, corev1.ResourceCPU, "64")
	assertQuantityString(t, node.Status.Allocatable, corev1.ResourceMemory, "30Gi")
	assertQuantityString(t, node.Status.Allocatable, ResourceNvidiaGPU, "8")
	assertQuantityString(t, node.Status.Allocatable, corev1.ResourcePods, "110")

	if len(node.Status.Conditions) != 1 || node.Status.Conditions[0].Type != corev1.NodeReady || node.Status.Conditions[0].Status != corev1.ConditionTrue {
		t.Fatalf("node ready conditions = %#v", node.Status.Conditions)
	}
}

func TestNodesFromMachineSpecsCanIncludeCPUOnlyAndLimit(t *testing.T) {
	specs := []trace.MachineSpec{
		{Machine: "cpu-only", CapCPU: 32, CapMem: 128, CapGPU: 0},
		{Machine: "gpu-node-a", GPUType: "A100", CapCPU: 64, CapMem: 512, CapGPU: 8},
		{Machine: "gpu-node-b", GPUType: "A100", CapCPU: 64, CapMem: 512, CapGPU: 8},
	}

	nodes, err := NodesFromMachineSpecs(specs, NodeOptions{IncludeCPUOnlyNodes: true, NodeLimit: 2})
	if err != nil {
		t.Fatalf("NodesFromMachineSpecs() error = %v", err)
	}
	if len(nodes) != 2 {
		t.Fatalf("NodesFromMachineSpecs() returned %d nodes, want 2", len(nodes))
	}
	if nodes[0].Name != "cpu-only" || nodes[1].Name != "gpu-node-a" {
		t.Fatalf("node names = %q, %q; want cpu-only, gpu-node-a", nodes[0].Name, nodes[1].Name)
	}
	assertQuantityString(t, nodes[0].Status.Capacity, ResourceNvidiaGPU, "0")
}

func TestMachineNodeNameSanitizesInvalidKubernetesNames(t *testing.T) {
	got := MachineNodeName("Machine_01/GPU")
	if !strings.HasPrefix(got, "machine-01-gpu-") {
		t.Fatalf("MachineNodeName() = %q, want sanitized prefix", got)
	}
	if len(got) > 63 {
		t.Fatalf("MachineNodeName() length = %d, want <= 63", len(got))
	}
}

func TestResourceSliceFromMachineSpec(t *testing.T) {
	resourceSlice, err := ResourceSliceFromMachineSpec(trace.MachineSpec{
		Machine: "gpu-node",
		GPUType: "V100",
		CapGPU:  4,
	})
	if err != nil {
		t.Fatalf("ResourceSliceFromMachineSpec() error = %v", err)
	}

	if resourceSlice.APIVersion != "resource.k8s.io/v1" || resourceSlice.Kind != "ResourceSlice" {
		t.Fatalf("resource slice type = %s/%s", resourceSlice.APIVersion, resourceSlice.Kind)
	}
	if resourceSlice.Name != "gpu-node-gpu" {
		t.Fatalf("resource slice name = %q, want gpu-node-gpu", resourceSlice.Name)
	}
	if resourceSlice.Spec.Driver != nodeinfo.DraDriverGpuNvidia {
		t.Fatalf("driver = %q, want %q", resourceSlice.Spec.Driver, nodeinfo.DraDriverGpuNvidia)
	}
	if resourceSlice.Spec.NodeName == nil || *resourceSlice.Spec.NodeName != "gpu-node" {
		t.Fatalf("nodeName = %#v, want gpu-node", resourceSlice.Spec.NodeName)
	}
	if resourceSlice.Spec.Pool.Name != "gpu-node" || resourceSlice.Spec.Pool.Generation != 1 || resourceSlice.Spec.Pool.ResourceSliceCount != 1 {
		t.Fatalf("pool = %#v, want node-local generation 1 pool", resourceSlice.Spec.Pool)
	}
	if len(resourceSlice.Spec.Devices) != 4 {
		t.Fatalf("devices = %#v, want 4 devices", resourceSlice.Spec.Devices)
	}
	for i, device := range resourceSlice.Spec.Devices {
		want := "gpu-" + strconv.Itoa(i)
		if device.Name != want {
			t.Fatalf("device %d name = %q, want %q", i, device.Name, want)
		}
	}
}

func TestWriteNodesYAML(t *testing.T) {
	nodes, err := NodesFromMachineSpecs([]trace.MachineSpec{
		{Machine: "gpu-node", GPUType: "A100", CapCPU: 64, CapMem: 512, CapGPU: 8},
	}, NodeOptions{})
	if err != nil {
		t.Fatalf("NodesFromMachineSpecs() error = %v", err)
	}

	var out bytes.Buffer
	if err := WriteNodesYAML(&out, nodes); err != nil {
		t.Fatalf("WriteNodesYAML() error = %v", err)
	}

	text := out.String()
	for _, want := range []string{
		"apiVersion: v1",
		"kind: Node",
		"name: gpu-node",
		"kwok.x-k8s.io/node: fake",
		`scheduler.slinky.slurm.net/external-node: "true"`,
		"slinky.slurm.net/managed-node",
		"nvidia.com/gpu:",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("rendered YAML missing %q:\n%s", want, text)
		}
	}
}

func TestWriteResourceSlicesYAMLFromMachineSpecsStreamsAndStopsAtLimit(t *testing.T) {
	input := `cpu-only,,32,128,0
gpu-node-a,A100,64,512,8
gpu-node-b,A100,64,512,4
`

	var out bytes.Buffer
	written, err := WriteResourceSlicesYAMLFromMachineSpecs(&out, strings.NewReader(input), NodeOptions{IncludeCPUOnlyNodes: true, NodeLimit: 2})
	if err != nil {
		t.Fatalf("WriteResourceSlicesYAMLFromMachineSpecs() error = %v", err)
	}
	if written != 1 {
		t.Fatalf("WriteResourceSlicesYAMLFromMachineSpecs() wrote %d slices, want 1", written)
	}

	text := out.String()
	for _, want := range []string{
		"apiVersion: resource.k8s.io/v1",
		"kind: ResourceSlice",
		"name: gpu-node-a-gpu",
		"driver: gpu.nvidia.com",
		"nodeName: gpu-node-a",
		"name: gpu-node-a",
		"name: gpu-7",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("rendered YAML missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "gpu-node-b") {
		t.Fatalf("rendered YAML contains resource slice beyond limit:\n%s", text)
	}
}

func TestWriteNodesYAMLFromMachineSpecsStreamsAndStopsAtLimit(t *testing.T) {
	input := `cpu-only,,32,128,0
gpu-node-a,A100,64,512,8
gpu-node-b,A100,64,512,8
gpu-node-c,A100,64,512,8
`

	var out bytes.Buffer
	written, err := WriteNodesYAMLFromMachineSpecs(&out, strings.NewReader(input), NodeOptions{NodeLimit: 2})
	if err != nil {
		t.Fatalf("WriteNodesYAMLFromMachineSpecs() error = %v", err)
	}
	if written != 2 {
		t.Fatalf("WriteNodesYAMLFromMachineSpecs() wrote %d nodes, want 2", written)
	}

	text := out.String()
	if strings.Contains(text, "cpu-only") {
		t.Fatalf("rendered YAML contains filtered CPU-only node:\n%s", text)
	}
	if !strings.Contains(text, "name: gpu-node-a") || !strings.Contains(text, "name: gpu-node-b") {
		t.Fatalf("rendered YAML missing first two GPU nodes:\n%s", text)
	}
	if strings.Contains(text, "name: gpu-node-c") {
		t.Fatalf("rendered YAML contains node beyond limit:\n%s", text)
	}
}

func assertQuantityString(t *testing.T, list corev1.ResourceList, name corev1.ResourceName, want string) {
	t.Helper()
	got, ok := list[name]
	if !ok {
		t.Fatalf("resource %q is missing from %#v", name, list)
	}
	if got.String() != want {
		t.Fatalf("resource %q = %q, want %q", name, got.String(), want)
	}
}
