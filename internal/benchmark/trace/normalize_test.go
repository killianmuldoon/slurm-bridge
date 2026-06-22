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

	got, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
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
	if job.Roles[1].TaskName != "worker" || job.Roles[1].Replicas != 2 || job.Roles[1].CPUCores != 4 || job.Roles[1].MemoryGB != 29.296875 || job.Roles[1].GPUCount != 1 || job.Roles[1].GPUType != "V100" {
		t.Fatalf("worker role = %#v", job.Roles[1])
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

	got, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{MaxJobs: 1})
	if err != nil {
		t.Fatalf("NormalizeJobs() error = %v", err)
	}
	if len(got) != 1 || got[0].JobID != "1002" {
		t.Fatalf("NormalizeJobs() = %#v, want earliest submitted job", got)
	}
}

func TestNormalizeJobsFailsOnMissingTasks(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
`
	tasksInput := `job-b,worker,1,Terminated,12,40,400,10,0,CPU
`

	_, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
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

	_, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want invalid runtime error")
	}
	if !strings.Contains(err.Error(), "non-positive simulated runtime") {
		t.Fatalf("NormalizeJobs() error = %v, want runtime message", err)
	}
}

func TestNormalizeJobsSkipsNonMatchingStatusBeforeParsingTimes(t *testing.T) {
	jobsInput := `job-running,1000,user-a,Running,10,
job-a,1001,user-a,Terminated,20,40
`
	tasksInput := `job-a,worker,1,Terminated,21,40,400,10,0,CPU
`

	got, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
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

	_, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
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

	got, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
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

	_, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
	if err == nil {
		t.Fatal("NormalizeJobs() error = nil, want blank selected task end_time error")
	}
	if !strings.Contains(err.Error(), "end_time must be a number") {
		t.Fatalf("NormalizeJobs() error = %v, want end_time parse error", err)
	}
}

func TestNormalizeJobsFailsOnDuplicateJobID(t *testing.T) {
	jobsInput := `job-a,1001,user-a,Terminated,10,40
job-b,1001,user-b,Terminated,11,40
`
	tasksInput := `job-a,worker,1,Terminated,12,40,400,10,0,CPU
job-b,worker,1,Terminated,13,40,400,10,0,CPU
`

	_, err := NormalizeJobs(strings.NewReader(jobsInput), strings.NewReader(tasksInput), NormalizeOptions{})
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
