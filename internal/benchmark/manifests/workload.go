// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package manifests

import (
	"fmt"
	"io"
	"math"
	"strconv"
	"time"

	"github.com/SlinkyProject/slurm-bridge/internal/benchmark/trace"
	"github.com/SlinkyProject/slurm-bridge/internal/utils"
	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/scheduler-plugins/apis/scheduling/v1alpha1"
	"sigs.k8s.io/yaml"
)

const (
	DefaultNamespace        = "slurm-bridge"
	DefaultRunID            = "render"
	DefaultRuntimeTimeScale = 360
	DefaultPauseImage       = "registry.k8s.io/pause:3.9"

	LabelRunID    = "bench.ai/run-id"
	LabelJobID    = "bench.ai/job-id"
	LabelTaskName = "bench.ai/task-name"

	AnnotationTraceSubmitTime         = "bench.ai/trace-submit-time"
	AnnotationSimulatedRuntimeSeconds = "bench.ai/simulated-runtime-seconds"
	AnnotationRuntimeDelay            = "bench.ai/runtime-delay"
	AnnotationTraceInstanceName       = "bench.ai/trace-instance-name"
	AnnotationTraceStartTime          = "bench.ai/trace-start-time"
	AnnotationTraceEndTime            = "bench.ai/trace-end-time"
	podGroupAPIVersion                = "scheduling.x-k8s.io/v1alpha1"
)

type WorkloadOptions struct {
	Namespace        string
	SchedulerName    string
	RunID            string
	RuntimeTimeScale float64
	PauseImage       string
}

func PodGroupForJob(job trace.BenchmarkJob, opts WorkloadOptions) *v1alpha1.PodGroup {
	opts = opts.withDefaults()
	name := PodGroupName(job)
	return &v1alpha1.PodGroup{
		TypeMeta: metav1.TypeMeta{
			APIVersion: podGroupAPIVersion,
			Kind:       "PodGroup",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: opts.Namespace,
			Labels:    workloadLabels(job, opts.RunID),
			Annotations: map[string]string{
				wellknown.AnnotationJobName: name,
			},
		},
		Spec: v1alpha1.PodGroupSpec{
			MinMember: totalReplicas(job),
		},
	}
}

func PodsForJob(job trace.BenchmarkJob, opts WorkloadOptions) ([]*corev1.Pod, error) {
	opts = opts.withDefaults()
	if err := opts.validate(); err != nil {
		return nil, err
	}

	podGroupName := PodGroupName(job)
	pods := make([]*corev1.Pod, 0, totalReplicas(job))
	for _, role := range job.Roles {
		for i, benchmarkPod := range role.Pods {
			resources, err := podResourceRequirements(role)
			if err != nil {
				return nil, fmt.Errorf("job %q role %q: %w", job.JobID, role.TaskName, err)
			}

			labels := workloadLabels(job, opts.RunID)
			labels[LabelTaskName] = LabelValue(role.TaskName)
			labels[v1alpha1.PodGroupLabel] = podGroupName

			pod := &corev1.Pod{
				TypeMeta: metav1.TypeMeta{
					APIVersion: "v1",
					Kind:       "Pod",
				},
				ObjectMeta: metav1.ObjectMeta{
					Name:      PodName(job, role, benchmarkPod, i),
					Namespace: opts.Namespace,
					Labels:    labels,
					Annotations: map[string]string{
						AnnotationTraceSubmitTime:         formatFloat(job.SubmitTime),
						AnnotationTraceInstanceName:       benchmarkPod.InstanceName,
						AnnotationTraceStartTime:          formatFloat(benchmarkPod.OriginalStartTime),
						AnnotationTraceEndTime:            formatFloat(benchmarkPod.OriginalEndTime),
						AnnotationSimulatedRuntimeSeconds: formatFloat(benchmarkPod.SimulatedRuntimeSeconds),
						AnnotationRuntimeDelay:            runtimeDelay(benchmarkPod.SimulatedRuntimeSeconds, opts.RuntimeTimeScale),
					},
				},
				Spec: corev1.PodSpec{
					SchedulerName: opts.SchedulerName,
					RestartPolicy: corev1.RestartPolicyNever,
					Tolerations: []corev1.Toleration{
						*utils.NewTolerationNodeBridged(opts.SchedulerName),
					},
					Containers: []corev1.Container{
						{
							Name:      "fake",
							Image:     opts.PauseImage,
							Resources: resources,
						},
					},
				},
			}
			pods = append(pods, pod)
		}
	}

	return pods, nil
}

func PodGroupName(job trace.BenchmarkJob) string {
	return KubernetesName("pai", "pai", job.JobID)
}

func PodName(job trace.BenchmarkJob, role trace.BenchmarkRole, pod trace.BenchmarkPod, index int) string {
	return KubernetesName("pai-pod", "pai", job.JobID, role.TaskName, pod.InstanceName, strconv.FormatInt(int64(index), 10))
}

func WritePodGroupsYAML(w io.Writer, jobs []trace.BenchmarkJob, opts WorkloadOptions) error {
	for i, job := range jobs {
		if err := writeYAMLDocument(w, PodGroupForJob(job, opts), i > 0); err != nil {
			return err
		}
	}
	return nil
}

func WritePodsYAML(w io.Writer, jobs []trace.BenchmarkJob, opts WorkloadOptions) error {
	written := 0
	for _, job := range jobs {
		pods, err := PodsForJob(job, opts)
		if err != nil {
			return err
		}
		for _, pod := range pods {
			if err := writeYAMLDocument(w, pod, written > 0); err != nil {
				return err
			}
			written++
		}
	}
	return nil
}

func workloadLabels(job trace.BenchmarkJob, runID string) map[string]string {
	return map[string]string{
		LabelSource: SourceAlibabaPAI,
		LabelRunID:  LabelValue(runID),
		LabelJobID:  LabelValue(job.JobID),
	}
}

func totalReplicas(job trace.BenchmarkJob) int32 {
	var total int32
	for _, role := range job.Roles {
		total += int32(len(role.Pods))
	}
	return total
}

func podResourceRequirements(role trace.BenchmarkRole) (corev1.ResourceRequirements, error) {
	requests := corev1.ResourceList{}

	cpu, err := resource.ParseQuantity(formatFloat(role.CPUCores))
	if err != nil {
		return corev1.ResourceRequirements{}, fmt.Errorf("parse cpu request: %w", err)
	}
	memory, err := resource.ParseQuantity(fmt.Sprintf("%dGi", int64(math.Ceil(role.MemoryGB))))
	if err != nil {
		return corev1.ResourceRequirements{}, fmt.Errorf("parse memory request: %w", err)
	}
	requests[corev1.ResourceCPU] = cpu
	requests[corev1.ResourceMemory] = memory

	if role.GPUCount > 0 {
		gpu, err := resource.ParseQuantity(strconv.FormatInt(role.GPUCount, 10))
		if err != nil {
			return corev1.ResourceRequirements{}, fmt.Errorf("parse gpu request: %w", err)
		}
		requests[ResourceNvidiaGPU] = gpu
	}

	return corev1.ResourceRequirements{
		Requests: requests,
		Limits:   requests.DeepCopy(),
	}, nil
}

func runtimeDelay(runtimeSeconds, scale float64) string {
	scaled := runtimeSeconds / scale
	if scaled <= 0 {
		scaled = 1
	}
	return time.Duration(math.Ceil(scaled * float64(time.Second))).String()
}

func writeYAMLDocument(w io.Writer, obj any, separator bool) error {
	if separator {
		if _, err := fmt.Fprintln(w, "---"); err != nil {
			return err
		}
	}

	out, err := yaml.Marshal(obj)
	if err != nil {
		return err
	}
	if _, err := w.Write(out); err != nil {
		return err
	}
	return nil
}

func (o WorkloadOptions) withDefaults() WorkloadOptions {
	if o.Namespace == "" {
		o.Namespace = DefaultNamespace
	}
	if o.SchedulerName == "" {
		o.SchedulerName = DefaultSchedulerName
	}
	if o.RunID == "" {
		o.RunID = DefaultRunID
	}
	if o.RuntimeTimeScale == 0 {
		o.RuntimeTimeScale = DefaultRuntimeTimeScale
	}
	if o.PauseImage == "" {
		o.PauseImage = DefaultPauseImage
	}
	return o
}

func (o WorkloadOptions) validate() error {
	if o.RuntimeTimeScale <= 0 {
		return fmt.Errorf("runtime time scale must be positive")
	}
	return nil
}
