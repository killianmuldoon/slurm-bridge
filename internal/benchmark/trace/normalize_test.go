// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package trace

import (
	"bytes"
	"strings"
	"testing"
)

func TestNormalizeJobs(t *testing.T) {
	jobsInput := `job-b,1002,user-b,Running,5,20
job-a,1001,user-a,Terminated,10,40
job-c,1003,user-c,Terminated,9,30
`
	tasksInput := `job-a,ps,1,Terminated,14,40,200,10,0,CPU
job-a,worker,2,Terminated,12,40,400,29.296875,100,V100
job-c,worker,1,Terminated,11,30,800,50,250,T4
`
	instancesInput := `job-a,ps,ps-0,worker-ps,inst-ps,Terminated,14,20,m1
job-a,worker,worker-0,worker-a,inst-w0,Terminated,12,30,m2
job-a,worker,worker-1,worker-b,inst-w1,Terminated,13,40,m3
job-c,worker,worker-0,worker-c,inst-c0,Terminated,11,30,m4
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("NormalizeJobs() returned %d jobs, want 2", len(got))
	}
	if got[0].JobID != "1003" || got[1].JobID != "1001" {
		t.Fatalf("jobs not sorted by submit time then id: %#v", got)
	}

	job := got[1]
	if job.SourceJobName != "job-a" || job.User != "user-a" || job.SubmitTime != 10 || job.OriginalCompletionTime != 40 || job.OriginalEarliestTaskStartTime != 12 || job.SimulatedRuntimeSeconds != 28 {
		t.Fatalf("normalized job = %#v", job)
	}
	if len(job.Roles) != 2 {
		t.Fatalf("job roles = %#v, want 2 roles", job.Roles)
	}
	worker := job.Roles[1]
	if worker.TaskName != "worker" || worker.Replicas != 2 || worker.CPUCores != 4 || worker.MemoryGB != 29.296875 || worker.GPUCount != 1 || worker.GPUType != "V100" {
		t.Fatalf("worker role = %#v", worker)
	}
	if len(worker.Pods) != 2 {
		t.Fatalf("worker pods = %#v, want 2 pods", worker.Pods)
	}
	if worker.Pods[0].InstanceName != "worker-0" || worker.Pods[0].SimulatedRuntimeSeconds != 18 {
		t.Fatalf("worker pod 0 = %#v, want instance runtime", worker.Pods[0])
	}
	if worker.Pods[1].InstanceName != "worker-1" || worker.Pods[1].SimulatedRuntimeSeconds != 27 {
		t.Fatalf("worker pod 1 = %#v, want instance runtime", worker.Pods[1])
	}
	if got[0].Roles[0].GPUCount != 3 {
		t.Fatalf("ceil GPU conversion = %d, want 3", got[0].Roles[0].GPUCount)
	}
}

func TestNormalizeJobsMaxJobs(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,20,40
job-b,1002,user-b,Terminated,10,40
`
	tasksInput := `job-a,worker,1,Terminated,21,40,400,10,0,CPU
job-b,worker,1,Terminated,11,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,21,40,m1
job-b,worker,worker-0,worker-b,inst-b,Terminated,11,40,m2
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{MaxJobs: 1})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 1 || got[0].JobID != "1002" {
		t.Fatalf("NormalizeJobs() = %#v, want earliest submitted job", got)
	}
}

func TestNormalizeJobsMaxPodsPerJob(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
job-b,1002,user-b,Terminated,11,40
`
	tasksInput := `job-a,worker,2,Terminated,12,40,400,10,0,CPU
job-b,worker,1,Terminated,13,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a0,inst-a0,Terminated,12,40,m1
job-a,worker,worker-1,worker-a1,inst-a1,Terminated,13,40,m2
job-b,worker,worker-0,worker-b,inst-b,Terminated,13,40,m3
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{MaxPodsPerJob: 1})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 1 || got[0].JobID != "1002" {
		t.Fatalf("NormalizeJobs() = %#v, want only job with one pod", got)
	}
}

func TestNormalizeJobsTraceWindow(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
job-b,1002,user-b,Terminated,19,40
job-c,1003,user-c,Terminated,20,40
`
	tasksInput := `job-a,worker,1,Terminated,11,40,400,10,0,CPU
job-b,worker,1,Terminated,20,40,400,10,0,CPU
job-c,worker,1,Terminated,21,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,11,40,m1
job-b,worker,worker-0,worker-b,inst-b,Terminated,20,40,m2
job-c,worker,worker-0,worker-c,inst-c,Terminated,21,40,m3
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{TraceWindowSeconds: 10})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 2 || got[0].JobID != "1001" || got[1].JobID != "1002" {
		t.Fatalf("NormalizeJobs() = %#v, want jobs starting before the window boundary", got)
	}
}

func TestNormalizeJobsFailsOnNegativeTraceWindow(t *testing.T) {
	_, err := normalizeJobsForTest("", "", "", NormalizeOptions{TraceWindowSeconds: -1})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want negative trace window error")
	}
	if !strings.Contains(err.Error(), "trace window seconds must be non-negative") {
		t.Fatalf("NormalizeJobs() error = %v, want trace window message", err)
	}
}

func TestNormalizeJobsFailsOnMissingTasks(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
`
	tasksInput := `job-b,worker,1,Terminated,12,40,400,10,0,CPU
`
	instancesInput := `job-b,worker,worker-0,worker-b,inst-b,Terminated,12,40,m1
`

	_, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want missing task error")
	}
	if !strings.Contains(err.Error(), `job "job-a" has no matching tasks`) {
		t.Fatalf("NormalizeJobs() error = %v, want missing task message", err)
	}
}

func TestNormalizeJobsFailsOnInvalidRuntime(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,12
`
	tasksInput := `job-a,worker,1,Terminated,12,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,12,40,m1
`

	_, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want invalid runtime error")
	}
	if !strings.Contains(err.Error(), "non-positive simulated runtime") {
		t.Fatalf("NormalizeJobs() error = %v, want runtime message", err)
	}
}

func TestNormalizeJobsFailsOnInstanceCountMismatch(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
`
	tasksInput := `job-a,worker,2,Terminated,12,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,12,40,m1
`

	_, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want instance count error")
	}
	if !strings.Contains(err.Error(), `has 1 instances, want 2`) {
		t.Fatalf("NormalizeJobs() error = %v, want instance count message", err)
	}
}

func TestNormalizeJobsUsesTerminatedRetryAttempt(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,80
`
	tasksInput := `job-a,worker,1,Terminated,12,80,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Failed,12,,m1
job-a,worker,worker-0,worker-b,inst-a,Terminated,40,80,m2
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	pod := got[0].Roles[0].Pods[0]
	if pod.InstanceName != "worker-0" || pod.OriginalStartTime != 40 || pod.OriginalEndTime != 80 || pod.SimulatedRuntimeSeconds != 40 {
		t.Fatalf("pod = %#v, want terminated retry attempt", pod)
	}
}

func TestNormalizeJobsSkipsNonMatchingStatusBeforeParsingTimes(t *testing.T) {
	jobsInput := `job-running,1000,user-a,Running,10,
job-a,1001,user-a,Terminated,20,40
`
	tasksInput := `job-a,worker,1,Terminated,21,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,21,40,m1
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 1 || got[0].JobID != "1001" {
		t.Fatalf("NormalizeJobs() = %#v, want only terminated job", got)
	}
}

func TestNormalizeJobsFailsWhenIncludedStatusHasBlankEndTime(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,20,
`
	tasksInput := `job-a,worker,1,Terminated,21,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,21,40,m1
`

	_, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want blank included end_time error")
	}
	if !strings.Contains(err.Error(), "end_time must be a number") {
		t.Fatalf("NormalizeJobs() error = %v, want end_time parse error", err)
	}
}

func TestNormalizeJobsSkipsUnselectedTaskBeforeParsingTimes(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,20,40
job-failed,1002,user-a,Failed,20,30
`
	tasksInput := `job-failed,worker,1,Failed,21,,400,10,0,CPU
job-a,worker,1,Terminated,21,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,21,40,m1
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 1 || got[0].JobID != "1001" {
		t.Fatalf("NormalizeJobs() = %#v, want only selected job", got)
	}
}

func TestNormalizeJobsSkipsUnselectedInstanceBeforeParsingTimes(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,20,40
job-failed,1002,user-a,Failed,20,30
`
	tasksInput := `job-a,worker,1,Terminated,21,40,400,10,0,CPU
`
	instancesInput := `job-failed,worker,worker-0,worker-failed,inst-failed,Failed,21,,m1
job-a,worker,worker-0,worker-a,inst-a,Terminated,21,40,m2
`

	got, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 1 || got[0].JobID != "1001" {
		t.Fatalf("NormalizeJobs() = %#v, want only selected job", got)
	}
}

func TestNormalizeJobsFailsWhenSelectedTaskHasBlankEndTime(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,20,40
`
	tasksInput := `job-a,worker,1,Terminated,21,,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,21,40,m1
`

	_, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want blank selected task end_time error")
	}
	if !strings.Contains(err.Error(), "end_time must be a number") {
		t.Fatalf("NormalizeJobs() error = %v, want end_time parse error", err)
	}
}

func TestNormalizeJobsFailsWhenSelectedInstanceHasBlankEndTime(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,20,40
`
	tasksInput := `job-a,worker,1,Terminated,21,40,400,10,0,CPU
`
	instancesInput := `job-a,worker,worker-0,worker-a,inst-a,Terminated,21,,m1
`

	_, err := normalizeJobsForTest(jobsInput, tasksInput, instancesInput, NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want blank selected instance end_time error")
	}
	if !strings.Contains(err.Error(), "end_time must be a number") {
		t.Fatalf("NormalizeJobs() error = %v, want end_time parse error", err)
	}
}

func TestNormalizeJobsFailsOnDuplicateJobID(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
job-b,1001,user-b,Terminated,11,40
`

	_, err := normalizeJobsForTest(jobsInput, "", "", NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want duplicate job_id error")
	}
	if !strings.Contains(err.Error(), `both normalize to job_id "1001"`) {
		t.Fatalf("NormalizeJobs() error = %v, want duplicate job_id message", err)
	}
}

func TestWriteJobsJSONL(t *testing.T) {
	jobs := []BenchmarkJob{
		{JobID: "1001", SourceJobName: "job-a"},
		{JobID: "1002", SourceJobName: "job-b"},
	}

	var out bytes.Buffer
	if err := WriteJobsJSONL(&out, jobs); err != nil {
		t.Fatalf("WriteJobsJSONL() error = %v", err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("WriteJobsJSONL() wrote %d lines, want 2: %q", len(lines), out.String())
	}
	if !strings.Contains(lines[0], `"job_id":"1001"`) || !strings.Contains(lines[1], `"job_id":"1002"`) {
		t.Fatalf("WriteJobsJSONL() output = %q", out.String())
	}
}

func normalizeJobsForTest(jobs, tasks, instances string, opts NormalizeOptions) ([]BenchmarkJob, error) {
	return NormalizeJobs(strings.NewReader(jobs), strings.NewReader(tasks), strings.NewReader(instances), opts)
}
