// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package trace

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
)

const DefaultIncludedJobStatus = "Terminated"

type NormalizeOptions struct {
	MaxJobs            int
	MaxPodsPerJob      int
	TraceWindowSeconds float64
	Status             string
}

type BenchmarkJob struct {
	JobID                         string          `json:"job_id"`
	SourceJobName                 string          `json:"source_job_name"`
	User                          string          `json:"user"`
	SubmitTime                    float64         `json:"submit_time"`
	OriginalCompletionTime        float64         `json:"original_completion_time"`
	OriginalEarliestTaskStartTime float64         `json:"original_earliest_task_start_time"`
	SimulatedRuntimeSeconds       float64         `json:"simulated_runtime_seconds"`
	Roles                         []BenchmarkRole `json:"roles"`
}

type BenchmarkRole struct {
	TaskName string         `json:"task_name"`
	Replicas int32          `json:"replicas"`
	CPUCores float64        `json:"cpu_cores"`
	MemoryGB float64        `json:"memory_gb"`
	GPUCount int64          `json:"gpu_count"`
	GPUType  string         `json:"gpu_type"`
	Pods     []BenchmarkPod `json:"pods"`
}

type BenchmarkPod struct {
	InstanceName            string  `json:"instance_name"`
	InstanceID              string  `json:"instance_id,omitempty"`
	OriginalStartTime       float64 `json:"original_start_time"`
	OriginalEndTime         float64 `json:"original_end_time"`
	SimulatedRuntimeSeconds float64 `json:"simulated_runtime_seconds"`
}

func NormalizeJobs(jobReader io.Reader, taskReader io.Reader, instanceReader io.Reader, opts NormalizeOptions) ([]BenchmarkJob, error) {
	if opts.Status == "" {
		opts.Status = DefaultIncludedJobStatus
	}
	if opts.MaxJobs < 0 {
		return nil, fmt.Errorf("max jobs must be non-negative")
	}
	if opts.MaxPodsPerJob < 0 {
		return nil, fmt.Errorf("max pods per job must be non-negative")
	}
	if opts.TraceWindowSeconds < 0 {
		return nil, fmt.Errorf("trace window seconds must be non-negative")
	}

	selected := map[string]JobRecord{}
	order := []string{}
	if err := scanJobRows(jobReader, func(row []string) error {
		if len(row) < jobColumnCount {
			return fmt.Errorf("expected at least %d columns, got %d", jobColumnCount, len(row))
		}
		if strings.TrimSpace(row[jobStatusIndex]) != opts.Status {
			return nil
		}

		record, err := parseJobRecord(row)
		if err != nil {
			return err
		}
		if _, exists := selected[record.JobName]; exists {
			return fmt.Errorf("duplicate job_name %q", record.JobName)
		}
		selected[record.JobName] = record
		order = append(order, record.JobName)
		return nil
	}); err != nil {
		return nil, err
	}

	orderedJobs, err := selectOrderedJobs(selected, order, opts.MaxJobs, opts.TraceWindowSeconds)
	if err != nil {
		return nil, err
	}

	selected = map[string]JobRecord{}
	order = order[:0]
	for _, job := range orderedJobs {
		selected[job.JobName] = job
		order = append(order, job.JobName)
	}

	tasksByJob := map[string][]TaskRecord{}
	taskTemplates := map[string]map[string]TaskRecord{}
	if err := scanTaskRows(taskReader, func(row []string) error {
		if len(row) < taskColumnCount {
			return fmt.Errorf("expected at least %d columns, got %d", taskColumnCount, len(row))
		}
		jobName := strings.TrimSpace(row[taskJobNameIndex])
		if _, ok := selected[jobName]; !ok {
			return nil
		}

		record, err := parseTaskRecord(row)
		if err != nil {
			return err
		}
		if record.Status != opts.Status {
			return fmt.Errorf("job %q task %q has status %q, want %q", record.JobName, record.TaskName, record.Status, opts.Status)
		}
		if taskTemplates[record.JobName] == nil {
			taskTemplates[record.JobName] = map[string]TaskRecord{}
		}
		if _, exists := taskTemplates[record.JobName][record.TaskName]; exists {
			return fmt.Errorf("job %q has duplicate task_name %q", record.JobName, record.TaskName)
		}
		taskTemplates[record.JobName][record.TaskName] = record
		tasksByJob[record.JobName] = append(tasksByJob[record.JobName], record)
		return nil
	}); err != nil {
		return nil, err
	}

	instancesByJob := map[string]map[string][]InstanceRecord{}
	if err := scanInstanceRows(instanceReader, func(row []string) error {
		if len(row) < instanceColumnCount {
			return fmt.Errorf("expected at least %d columns, got %d", instanceColumnCount, len(row))
		}
		jobName := strings.TrimSpace(row[instanceJobNameIndex])
		if _, ok := selected[jobName]; !ok {
			return nil
		}
		taskName := strings.TrimSpace(row[instanceTaskNameIndex])
		if _, ok := taskTemplates[jobName][taskName]; !ok {
			return fmt.Errorf("job %q instance task %q has no matching task template", jobName, taskName)
		}
		status := strings.TrimSpace(row[instanceStatusIndex])
		if status != opts.Status {
			return nil
		}

		record, err := parseInstanceRecord(row)
		if err != nil {
			return err
		}
		if instancesByJob[record.JobName] == nil {
			instancesByJob[record.JobName] = map[string][]InstanceRecord{}
		}
		instancesByJob[record.JobName][record.TaskName] = append(instancesByJob[record.JobName][record.TaskName], record)
		return nil
	}); err != nil {
		return nil, err
	}

	jobs := make([]BenchmarkJob, 0, len(order))
	for _, jobName := range order {
		job, ok := selected[jobName]
		if !ok {
			continue
		}
		tasks := tasksByJob[jobName]
		if len(tasks) == 0 {
			return nil, fmt.Errorf("job %q has no matching tasks", jobName)
		}

		normalized, err := normalizeJob(job, tasks, instancesByJob[jobName])
		if err != nil {
			return nil, err
		}
		if opts.MaxPodsPerJob > 0 && podCount(normalized) > opts.MaxPodsPerJob {
			continue
		}
		jobs = append(jobs, normalized)
	}

	return jobs, nil
}

func podCount(job BenchmarkJob) int {
	count := 0
	for _, role := range job.Roles {
		count += len(role.Pods)
	}
	return count
}

func WriteJobsJSONL(w io.Writer, jobs []BenchmarkJob) error {
	encoder := json.NewEncoder(w)
	for _, job := range jobs {
		if err := encoder.Encode(job); err != nil {
			return err
		}
	}
	return nil
}

func scanJobRows(r io.Reader, visit func([]string) error) error {
	return scanCSVRows(JobTableFilename, r, visit)
}

func scanTaskRows(r io.Reader, visit func([]string) error) error {
	return scanCSVRows(TaskTableFilename, r, visit)
}

func scanInstanceRows(r io.Reader, visit func([]string) error) error {
	return scanCSVRows(InstanceTableFilename, r, visit)
}

func selectOrderedJobs(selected map[string]JobRecord, order []string, maxJobs int, traceWindowSeconds float64) ([]JobRecord, error) {
	jobs := make([]JobRecord, 0, len(order))
	seenJobIDs := map[string]string{}
	for _, jobName := range order {
		job, ok := selected[jobName]
		if !ok {
			continue
		}
		id := jobID(job)
		if previous, ok := seenJobIDs[id]; ok {
			return nil, fmt.Errorf("jobs %q and %q both normalize to job_id %q", previous, jobName, id)
		}
		seenJobIDs[id] = jobName
		jobs = append(jobs, job)
	}

	sort.SliceStable(jobs, func(i, j int) bool {
		if jobs[i].StartTime == jobs[j].StartTime {
			return jobID(jobs[i]) < jobID(jobs[j])
		}
		return jobs[i].StartTime < jobs[j].StartTime
	})

	if traceWindowSeconds > 0 && len(jobs) > 0 {
		windowEnd := jobs[0].StartTime + traceWindowSeconds
		limit := 0
		for limit < len(jobs) && jobs[limit].StartTime < windowEnd {
			limit++
		}
		jobs = jobs[:limit]
	}

	if maxJobs > 0 && len(jobs) > maxJobs {
		jobs = jobs[:maxJobs]
	}
	return jobs, nil
}

func normalizeJob(job JobRecord, tasks []TaskRecord, instancesByTask map[string][]InstanceRecord) (BenchmarkJob, error) {
	earliestStart := math.Inf(1)
	roles := make([]BenchmarkRole, 0, len(tasks))
	for _, task := range tasks {
		instances := append([]InstanceRecord(nil), instancesByTask[task.TaskName]...)
		instancesByName := map[string]InstanceRecord{}
		for _, instance := range instances {
			name, err := logicalInstanceName(instance)
			if err != nil {
				return BenchmarkJob{}, fmt.Errorf("job %q task %q: %w", job.JobName, task.TaskName, err)
			}
			if _, exists := instancesByName[name]; exists {
				return BenchmarkJob{}, fmt.Errorf("job %q task %q has duplicate terminated instance %q", job.JobName, task.TaskName, name)
			}
			instancesByName[name] = instance
		}

		instances = instances[:0]
		for _, instance := range instancesByName {
			instances = append(instances, instance)
		}
		sort.SliceStable(instances, func(i, j int) bool {
			if instances[i].StartTime == instances[j].StartTime {
				if instances[i].InstName == instances[j].InstName {
					return instances[i].InstID < instances[j].InstID
				}
				return instances[i].InstName < instances[j].InstName
			}
			return instances[i].StartTime < instances[j].StartTime
		})

		if int32(len(instances)) != task.InstNum {
			return BenchmarkJob{}, fmt.Errorf("job %q task %q has %d instances, want %d", job.JobName, task.TaskName, len(instances), task.InstNum)
		}
		if len(instances) == 0 {
			continue
		}

		pods := make([]BenchmarkPod, 0, len(instances))
		for _, instance := range instances {
			if instance.StartTime < earliestStart {
				earliestStart = instance.StartTime
			}
			runtime := instance.EndTime - instance.StartTime
			if runtime <= 0 {
				return BenchmarkJob{}, fmt.Errorf("job %q task %q instance %q has non-positive simulated runtime", job.JobName, task.TaskName, instanceName(instance))
			}
			pods = append(pods, BenchmarkPod{
				InstanceName:            instanceName(instance),
				InstanceID:              instance.InstID,
				OriginalStartTime:       instance.StartTime,
				OriginalEndTime:         instance.EndTime,
				SimulatedRuntimeSeconds: runtime,
			})
		}

		roles = append(roles, BenchmarkRole{
			TaskName: task.TaskName,
			Replicas: int32(len(pods)),
			CPUCores: task.PlanCPU / 100,
			MemoryGB: task.PlanMem,
			GPUCount: gpuCount(task.PlanGPU),
			GPUType:  task.GPUType,
			Pods:     pods,
		})
	}
	if len(roles) == 0 {
		return BenchmarkJob{}, fmt.Errorf("job %q has no positive-replica tasks", job.JobName)
	}
	if math.IsInf(earliestStart, 1) {
		return BenchmarkJob{}, fmt.Errorf("job %q has no task start time", job.JobName)
	}

	runtime := job.EndTime - earliestStart
	if runtime <= 0 {
		return BenchmarkJob{}, fmt.Errorf("job %q has non-positive simulated runtime", job.JobName)
	}

	return BenchmarkJob{
		JobID:                         jobID(job),
		SourceJobName:                 job.JobName,
		User:                          job.User,
		SubmitTime:                    job.StartTime,
		OriginalCompletionTime:        job.EndTime,
		OriginalEarliestTaskStartTime: earliestStart,
		SimulatedRuntimeSeconds:       runtime,
		Roles:                         roles,
	}, nil
}

func logicalInstanceName(instance InstanceRecord) (string, error) {
	if instance.InstName != "" {
		return instance.InstName, nil
	}
	if instance.WorkerName != "" {
		return instance.WorkerName, nil
	}
	return "", fmt.Errorf("instance is missing inst_name and worker_name")
}

func instanceName(instance InstanceRecord) string {
	if instance.InstName != "" {
		return instance.InstName
	}
	if instance.WorkerName != "" {
		return instance.WorkerName
	}
	return instance.InstID
}

func gpuCount(planGPU float64) int64 {
	if planGPU <= 0 {
		return 0
	}
	return int64(math.Ceil(planGPU / 100))
}

func jobID(job JobRecord) string {
	if job.InstID != "" {
		return job.InstID
	}
	sum := sha256.Sum256([]byte(job.JobName))
	return strings.Trim(job.JobName, "-") + "-" + hex.EncodeToString(sum[:])[:8]
}
