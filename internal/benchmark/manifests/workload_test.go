// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package manifests

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SlinkyProject/slurm-bridge/internal/benchmark/trace"
	"github.com/SlinkyProject/slurm-bridge/internal/utils"
	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/scheduler-plugins/apis/scheduling/v1alpha1"
)

func TestPodGroupForJob(t *testing.T) {
	job := benchmarkJob()
	got := PodGroupForJob(job, WorkloadOptions{Namespace: "bench", RunID: "run-1"})

	if got.APIVersion != podGroupAPIVersion || got.Kind != "PodGroup" {
		t.Fatalf("type meta = %s/%s", got.APIVersion, got.Kind)
	}
	if got.Name != "pai-1001" || got.Namespace != "bench" {
		t.Fatalf("metadata = %s/%s", got.Namespace, got.Name)
	}
	if got.Labels[LabelSource] != SourceAlibabaPAI || got.Labels[LabelRunID] != "run-1" || got.Labels[LabelJobID] != "1001" {
		t.Fatalf("labels = %#v", got.Labels)
	}
	if got.Annotations[wellknown.AnnotationJobName] != "pai-1001" {
		t.Fatalf("annotations = %#v", got.Annotations)
	}
	if got.Spec.MinMember != 3 {
		t.Fatalf("minMember = %d, want 3", got.Spec.MinMember)
	}
}

func TestPodsForJob(t *testing.T) {
	job := benchmarkJob()
	got, err := PodsForJob(job, WorkloadOptions{
		Namespace:        "bench",
		SchedulerName:    "custom-scheduler",
		RunID:            "run-1",
		RuntimeTimeScale: 10,
	})
	if err != nil {
		t.Fatalf("PodsForJob() error = %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("PodsForJob() returned %d pods, want 3", len(got))
	}

	pod := got[1]
	if pod.Name != "pai-1001-worker-worker-0-0" || pod.Namespace != "bench" {
		t.Fatalf("pod metadata = %s/%s", pod.Namespace, pod.Name)
	}
	if pod.Labels[v1alpha1.PodGroupLabel] != "pai-1001" || pod.Labels[LabelTaskName] != "worker" {
		t.Fatalf("pod labels = %#v", pod.Labels)
	}
	if pod.Annotations[AnnotationTraceSubmitTime] != "10" || pod.Annotations[AnnotationTraceInstanceName] != "worker-0" || pod.Annotations[AnnotationTraceStartTime] != "12" || pod.Annotations[AnnotationTraceEndTime] != "30" || pod.Annotations[AnnotationSimulatedRuntimeSeconds] != "18" || pod.Annotations[AnnotationRuntimeDelay] != "1.8s" {
		t.Fatalf("pod annotations = %#v", pod.Annotations)
	}
	if pod.Spec.SchedulerName != "custom-scheduler" || pod.Spec.RestartPolicy != corev1.RestartPolicyNever {
		t.Fatalf("pod spec scheduler/restart = %q/%q", pod.Spec.SchedulerName, pod.Spec.RestartPolicy)
	}

	wantToleration := utils.NewTolerationNodeBridged("custom-scheduler")
	if len(pod.Spec.Tolerations) != 1 || pod.Spec.Tolerations[0] != *wantToleration {
		t.Fatalf("tolerations = %#v, want %#v", pod.Spec.Tolerations, []corev1.Toleration{*wantToleration})
	}

	container := pod.Spec.Containers[0]
	assertQuantityString(t, container.Resources.Requests, corev1.ResourceCPU, "4")
	assertQuantityString(t, container.Resources.Requests, corev1.ResourceMemory, "30Gi")
	assertQuantityString(t, container.Resources.Requests, ResourceNvidiaGPU, "1")
	assertQuantityString(t, container.Resources.Limits, corev1.ResourceCPU, "4")
	assertQuantityString(t, container.Resources.Limits, corev1.ResourceMemory, "30Gi")
	assertQuantityString(t, container.Resources.Limits, ResourceNvidiaGPU, "1")

	ps := got[0]
	if _, ok := ps.Spec.Containers[0].Resources.Requests[ResourceNvidiaGPU]; ok {
		t.Fatalf("cpu-only role unexpectedly requested GPU: %#v", ps.Spec.Containers[0].Resources.Requests)
	}
}

func TestWriteWorkloadYAML(t *testing.T) {
	jobs := []trace.BenchmarkJob{benchmarkJob()}

	var podGroups bytes.Buffer
	if err := WritePodGroupsYAML(&podGroups, jobs, WorkloadOptions{}); err != nil {
		t.Fatalf("WritePodGroupsYAML() error = %v", err)
	}
	if !strings.Contains(podGroups.String(), "kind: PodGroup") || !strings.Contains(podGroups.String(), "minMember: 3") {
		t.Fatalf("podgroup yaml = %s", podGroups.String())
	}

	var pods bytes.Buffer
	if err := WritePodsYAML(&pods, jobs, WorkloadOptions{}); err != nil {
		t.Fatalf("WritePodsYAML() error = %v", err)
	}
	if strings.Count(pods.String(), "kind: Pod") != 3 {
		t.Fatalf("pods yaml = %s", pods.String())
	}
	if !strings.Contains(pods.String(), v1alpha1.PodGroupLabel+": pai-1001") {
		t.Fatalf("pods yaml missing podgroup label: %s", pods.String())
	}
}

func benchmarkJob() trace.BenchmarkJob {
	return trace.BenchmarkJob{
		JobID:                   "1001",
		SourceJobName:           "job-a",
		SubmitTime:              10,
		SimulatedRuntimeSeconds: 28,
		Roles: []trace.BenchmarkRole{
			{
				TaskName: "ps",
				Replicas: 1,
				CPUCores: 2,
				MemoryGB: 10,
				Pods: []trace.BenchmarkPod{
					{
						InstanceName:            "ps-0",
						OriginalStartTime:       14,
						OriginalEndTime:         20,
						SimulatedRuntimeSeconds: 6,
					},
				},
			},
			{
				TaskName: "worker",
				Replicas: 2,
				CPUCores: 4,
				MemoryGB: 29.296875,
				GPUCount: 1,
				GPUType:  "V100",
				Pods: []trace.BenchmarkPod{
					{
						InstanceName:            "worker-0",
						OriginalStartTime:       12,
						OriginalEndTime:         30,
						SimulatedRuntimeSeconds: 18,
					},
					{
						InstanceName:            "worker-1",
						OriginalStartTime:       13,
						OriginalEndTime:         40,
						SimulatedRuntimeSeconds: 27,
					},
				},
			},
		},
	}
}
