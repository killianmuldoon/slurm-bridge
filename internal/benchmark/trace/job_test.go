// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package trace

import (
	"strings"
	"testing"
)

func TestReadJobRecords(t *testing.T) {
	input := `job-a,1001,user-a,Terminated,10,40
job-b,1002,user-b,Running,20,50
`

	got, err := ReadJobRecordsFileFromString(input)
	if err != nil {
		t.Fatalf("ReadJobRecords() error = %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadJobRecords() returned %d records, want 2", len(got))
	}
	if got[0].JobName != "job-a" || got[0].InstID != "1001" || got[0].User != "user-a" || got[0].Status != "Terminated" || got[0].StartTime != 10 || got[0].EndTime != 40 {
		t.Fatalf("first job = %#v", got[0])
	}
}

func TestReadTaskRecords(t *testing.T) {
	input := `job-a,worker,2,Terminated,12,40,400,29.296875,100,V100
`

	var got []TaskRecord
	err := ScanTaskRecords(strings.NewReader(input), func(record TaskRecord) error {
		got = append(got, record)
		return nil
	})
	if err != nil {
		t.Fatalf("ScanTaskRecords() error = %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ScanTaskRecords() returned %d records, want 1", len(got))
	}
	if got[0].TaskName != "worker" || got[0].InstNum != 2 || got[0].PlanCPU != 400 || got[0].PlanMem != 29.296875 || got[0].PlanGPU != 100 || got[0].GPUType != "V100" {
		t.Fatalf("task = %#v", got[0])
	}
}

func TestReadTaskRecordsRejectsFractionalInstNum(t *testing.T) {
	input := `job-a,worker,1.5,Terminated,12,40,400,29.296875,100,V100
`

	err := ScanTaskRecords(strings.NewReader(input), func(record TaskRecord) error {
		return nil
	})
	if err == nil {
		t.Fatal("ScanTaskRecords() error = nil, want error")
	}
	if !strings.Contains(err.Error(), "inst_num must be an integer") {
		t.Fatalf("ScanTaskRecords() error = %v, want inst_num integer error", err)
	}
}

func ReadJobRecordsFileFromString(input string) ([]JobRecord, error) {
	var got []JobRecord
	err := ScanJobRecords(strings.NewReader(input), func(record JobRecord) error {
		got = append(got, record)
		return nil
	})
	return got, err
}
