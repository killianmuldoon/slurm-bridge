// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package trace

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"strings"
)

const (
	JobTableFilename      = "pai_job_table.csv"
	TaskTableFilename     = "pai_task_table.csv"
	InstanceTableFilename = "pai_instance_table.csv"
)

// The upstream Alibaba PAI job file is headerless and ordered as:
// job_name,inst_id,user,status,start_time,end_time
const (
	jobJobNameIndex = iota
	jobInstIDIndex
	jobUserIndex
	jobStatusIndex
	jobStartTimeIndex
	jobEndTimeIndex
	jobColumnCount
)

// The upstream Alibaba PAI task file is headerless and ordered as:
// job_name,task_name,inst_num,status,start_time,end_time,plan_cpu,plan_mem,plan_gpu,gpu_type
const (
	taskJobNameIndex = iota
	taskTaskNameIndex
	taskInstNumIndex
	taskStatusIndex
	taskStartTimeIndex
	taskEndTimeIndex
	taskPlanCPUIndex
	taskPlanMemIndex
	taskPlanGPUIndex
	taskGPUTypeIndex
	taskColumnCount
)

// The upstream Alibaba PAI instance file is headerless and ordered as:
// job_name,task_name,inst_name,worker_name,inst_id,status,start_time,end_time,machine
const (
	instanceJobNameIndex = iota
	instanceTaskNameIndex
	instanceInstNameIndex
	instanceWorkerNameIndex
	instanceInstIDIndex
	instanceStatusIndex
	instanceStartTimeIndex
	instanceEndTimeIndex
	instanceMachineIndex
	instanceColumnCount
)

type JobRecord struct {
	JobName   string
	InstID    string
	User      string
	Status    string
	StartTime float64
	EndTime   float64
}

type TaskRecord struct {
	JobName   string
	TaskName  string
	InstNum   int32
	Status    string
	StartTime float64
	EndTime   float64
	PlanCPU   float64
	PlanMem   float64
	PlanGPU   float64
	GPUType   string
}

type InstanceRecord struct {
	JobName    string
	TaskName   string
	InstName   string
	WorkerName string
	InstID     string
	Status     string
	StartTime  float64
	EndTime    float64
	Machine    string
}

func ReadJobRecordsFile(path string) ([]JobRecord, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var records []JobRecord
	if err := ScanJobRecords(file, func(record JobRecord) error {
		records = append(records, record)
		return nil
	}); err != nil {
		return nil, err
	}

	return records, nil
}

func ReadTaskRecordsFile(path string) ([]TaskRecord, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var records []TaskRecord
	if err := ScanTaskRecords(file, func(record TaskRecord) error {
		records = append(records, record)
		return nil
	}); err != nil {
		return nil, err
	}

	return records, nil
}

func ReadInstanceRecordsFile(path string) ([]InstanceRecord, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var records []InstanceRecord
	if err := ScanInstanceRecords(file, func(record InstanceRecord) error {
		records = append(records, record)
		return nil
	}); err != nil {
		return nil, err
	}

	return records, nil
}

func ScanJobRecords(r io.Reader, visit func(JobRecord) error) error {
	return scanCSVRows(JobTableFilename, r, func(row []string) error {
		record, err := parseJobRecord(row)
		if err != nil {
			return err
		}
		if err := visit(record); err != nil {
			if errors.Is(err, ErrStopScan) {
				return ErrStopScan
			}
			return err
		}
		return nil
	})
}

func ScanTaskRecords(r io.Reader, visit func(TaskRecord) error) error {
	return scanCSVRows(TaskTableFilename, r, func(row []string) error {
		record, err := parseTaskRecord(row)
		if err != nil {
			return err
		}
		if err := visit(record); err != nil {
			if errors.Is(err, ErrStopScan) {
				return ErrStopScan
			}
			return err
		}
		return nil
	})
}

func ScanInstanceRecords(r io.Reader, visit func(InstanceRecord) error) error {
	return scanCSVRows(InstanceTableFilename, r, func(row []string) error {
		record, err := parseInstanceRecord(row)
		if err != nil {
			return err
		}
		if err := visit(record); err != nil {
			if errors.Is(err, ErrStopScan) {
				return ErrStopScan
			}
			return err
		}
		return nil
	})
}

func scanCSVRows(filename string, r io.Reader, visit func([]string) error) error {
	reader := csv.NewReader(r)
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true

	seenData := false
	for rowNumber := 1; ; rowNumber++ {
		row, err := reader.Read()
		if err != nil {
			if errors.Is(err, io.EOF) {
				if !seenData {
					return fmt.Errorf("%s is empty", filename)
				}
				return nil
			}
			return fmt.Errorf("read %s row %d: %w", filename, rowNumber, err)
		}
		if emptyCSVRow(row) {
			continue
		}

		seenData = true
		if err := visit(row); err != nil {
			if errors.Is(err, ErrStopScan) {
				return nil
			}
			return fmt.Errorf("parse %s row %d: %w", filename, rowNumber, err)
		}
	}
}

func parseJobRecord(row []string) (JobRecord, error) {
	if len(row) < jobColumnCount {
		return JobRecord{}, fmt.Errorf("expected at least %d columns, got %d", jobColumnCount, len(row))
	}

	startTime, err := parseFloat(row[jobStartTimeIndex], "start_time")
	if err != nil {
		return JobRecord{}, err
	}
	endTime, err := parseFloat(row[jobEndTimeIndex], "end_time")
	if err != nil {
		return JobRecord{}, err
	}

	return JobRecord{
		JobName:   strings.TrimSpace(row[jobJobNameIndex]),
		InstID:    strings.TrimSpace(row[jobInstIDIndex]),
		User:      strings.TrimSpace(row[jobUserIndex]),
		Status:    strings.TrimSpace(row[jobStatusIndex]),
		StartTime: startTime,
		EndTime:   endTime,
	}, nil
}

func parseTaskRecord(row []string) (TaskRecord, error) {
	if len(row) < taskColumnCount {
		return TaskRecord{}, fmt.Errorf("expected at least %d columns, got %d", taskColumnCount, len(row))
	}

	instNum, err := parseNonNegativeInt32(row[taskInstNumIndex], "inst_num")
	if err != nil {
		return TaskRecord{}, err
	}
	startTime, err := parseFloat(row[taskStartTimeIndex], "start_time")
	if err != nil {
		return TaskRecord{}, err
	}
	endTime, err := parseFloat(row[taskEndTimeIndex], "end_time")
	if err != nil {
		return TaskRecord{}, err
	}
	cpu, err := parseNonNegativeFloat(row[taskPlanCPUIndex], "plan_cpu")
	if err != nil {
		return TaskRecord{}, err
	}
	mem, err := parseNonNegativeFloat(row[taskPlanMemIndex], "plan_mem")
	if err != nil {
		return TaskRecord{}, err
	}
	gpu, err := parseOptionalPlanGPU(row[taskPlanGPUIndex])
	if err != nil {
		return TaskRecord{}, err
	}

	return TaskRecord{
		JobName:   strings.TrimSpace(row[taskJobNameIndex]),
		TaskName:  strings.TrimSpace(row[taskTaskNameIndex]),
		InstNum:   instNum,
		Status:    strings.TrimSpace(row[taskStatusIndex]),
		StartTime: startTime,
		EndTime:   endTime,
		PlanCPU:   cpu,
		PlanMem:   mem,
		PlanGPU:   gpu,
		GPUType:   strings.TrimSpace(row[taskGPUTypeIndex]),
	}, nil
}

func parseInstanceRecord(row []string) (InstanceRecord, error) {
	if len(row) < instanceColumnCount {
		return InstanceRecord{}, fmt.Errorf("expected at least %d columns, got %d", instanceColumnCount, len(row))
	}

	startTime, err := parseFloat(row[instanceStartTimeIndex], "start_time")
	if err != nil {
		return InstanceRecord{}, err
	}
	endTime, err := parseFloat(row[instanceEndTimeIndex], "end_time")
	if err != nil {
		return InstanceRecord{}, err
	}

	return InstanceRecord{
		JobName:    strings.TrimSpace(row[instanceJobNameIndex]),
		TaskName:   strings.TrimSpace(row[instanceTaskNameIndex]),
		InstName:   strings.TrimSpace(row[instanceInstNameIndex]),
		WorkerName: strings.TrimSpace(row[instanceWorkerNameIndex]),
		InstID:     strings.TrimSpace(row[instanceInstIDIndex]),
		Status:     strings.TrimSpace(row[instanceStatusIndex]),
		StartTime:  startTime,
		EndTime:    endTime,
		Machine:    strings.TrimSpace(row[instanceMachineIndex]),
	}, nil
}

func parseFloat(value, field string) (float64, error) {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a number: %w", field, err)
	}
	return parsed, nil
}

func parseNonNegativeFloat(value, field string) (float64, error) {
	parsed, err := parseFloat(value, field)
	if err != nil {
		return 0, err
	}
	if parsed < 0 {
		return 0, fmt.Errorf("%s must be non-negative", field)
	}
	return parsed, nil
}

func parseOptionalPlanGPU(value string) (float64, error) {
	// Alibaba uses empty plan_gpu and gpu_type fields for CPU-only task roles.
	if strings.TrimSpace(value) == "" {
		return 0, nil
	}
	return parseNonNegativeFloat(value, "plan_gpu")
}

func parseNonNegativeInt32(value, field string) (int32, error) {
	parsed, err := parseNonNegativeFloat(value, field)
	if err != nil {
		return 0, err
	}
	if math.Trunc(parsed) != parsed {
		return 0, fmt.Errorf("%s must be an integer", field)
	}
	if parsed > math.MaxInt32 {
		return 0, fmt.Errorf("%s exceeds int32 range", field)
	}
	return int32(parsed), nil
}
