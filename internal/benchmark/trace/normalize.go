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
	MaxJobs int
	Status  string
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
	TaskName string  `json:"task_name"`
	Replicas int32   `json:"replicas"`
	CPUCores float64 `json:"cpu_cores"`
	MemoryGB float64 `json:"memory_gb"`
	GPUCount int64   `json:"gpu_count"`
	GPUType  string  `json:"gpu_type"`
}

func NormalizeJobs(jobReader io.Reader, taskReader io.Reader, opts NormalizeOptions) ([]BenchmarkJob, error) {
	if opts.Status == "" {
		opts.Status = DefaultIncludedJobStatus
	}
	if opts.MaxJobs < 0 {
		return nil, fmt.Errorf("max jobs must be non-negative")
	}

	selected := map[string]JobRecord{}
	order := []string{}
	if err := ScanJobRecords(jobReader, func(record JobRecord) error {
		if record.Status != opts.Status {
			return nil
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

	tasksByJob := map[string][]TaskRecord{}
	if err := ScanTaskRecords(taskReader, func(record TaskRecord) error {
		if _, ok := selected[record.JobName]; !ok {
			return nil
		}
		tasksByJob[record.JobName] = append(tasksByJob[record.JobName], record)
		return nil
	}); err != nil {
		return nil, err
	}

	jobs := make([]BenchmarkJob, 0, len(order))
	seenJobIDs := map[string]string{}
	for _, jobName := range order {
		job, ok := selected[jobName]
		if !ok {
			continue
		}
		tasks := tasksByJob[jobName]
		if len(tasks) == 0 {
			return nil, fmt.Errorf("job %q has no matching tasks", jobName)
		}

		normalized, err := normalizeJob(job, tasks)
		if err != nil {
			return nil, err
		}
		if previous, ok := seenJobIDs[normalized.JobID]; ok {
			return nil, fmt.Errorf("jobs %q and %q both normalize to job_id %q", previous, jobName, normalized.JobID)
		}
		seenJobIDs[normalized.JobID] = jobName
		jobs = append(jobs, normalized)
	}

	sort.SliceStable(jobs, func(i, j int) bool {
		if jobs[i].SubmitTime == jobs[j].SubmitTime {
			return jobs[i].JobID < jobs[j].JobID
		}
		return jobs[i].SubmitTime < jobs[j].SubmitTime
	})

	if opts.MaxJobs > 0 && len(jobs) > opts.MaxJobs {
		jobs = jobs[:opts.MaxJobs]
	}

	return jobs, nil
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

func normalizeJob(job JobRecord, tasks []TaskRecord) (BenchmarkJob, error) {
	earliestStart := math.Inf(1)
	roles := make([]BenchmarkRole, 0, len(tasks))
	for _, task := range tasks {
		if task.InstNum == 0 {
			continue
		}
		if task.StartTime < earliestStart {
			earliestStart = task.StartTime
		}
		roles = append(roles, BenchmarkRole{
			TaskName: task.TaskName,
			Replicas: task.InstNum,
			CPUCores: task.PlanCPU / 100,
			MemoryGB: task.PlanMem,
			GPUCount: gpuCount(task.PlanGPU),
			GPUType:  task.GPUType,
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
