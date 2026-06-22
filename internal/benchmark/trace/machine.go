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

const MachineSpecFilename = "pai_machine_spec.csv"

// The upstream Alibaba PAI machine spec file is headerless and ordered as:
// machine,gpu_type,cap_cpu,cap_mem,cap_gpu
const (
	machineSpecMachineIndex = iota
	machineSpecGPUTypeIndex
	machineSpecCapCPUIndex
	machineSpecCapMemIndex
	machineSpecCapGPUIndex
	machineSpecColumnCount
)

type MachineSpec struct {
	Machine string
	GPUType string
	CapCPU  float64
	CapMem  float64
	CapGPU  int64
}

var ErrStopScan = errors.New("stop machine spec scan")

func ReadMachineSpecsFile(path string) ([]MachineSpec, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	return ReadMachineSpecs(file)
}

func ReadMachineSpecs(r io.Reader) ([]MachineSpec, error) {
	var specs []MachineSpec
	if err := ScanMachineSpecs(r, func(spec MachineSpec) error {
		specs = append(specs, spec)
		return nil
	}); err != nil {
		return nil, err
	}

	return specs, nil
}

func ScanMachineSpecs(r io.Reader, visit func(MachineSpec) error) error {
	reader := csv.NewReader(r)
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true

	seenData := false
	for rowNumber := 1; ; rowNumber++ {
		row, err := reader.Read()
		if err != nil {
			if errors.Is(err, io.EOF) {
				if !seenData {
					return fmt.Errorf("%s is empty", MachineSpecFilename)
				}
				return nil
			}
			return fmt.Errorf("read %s row %d: %w", MachineSpecFilename, rowNumber, err)
		}
		if emptyCSVRow(row) {
			continue
		}

		seenData = true
		spec, err := parseMachineSpec(row)
		if err != nil {
			return fmt.Errorf("parse %s row %d: %w", MachineSpecFilename, rowNumber, err)
		}
		if err := visit(spec); err != nil {
			if errors.Is(err, ErrStopScan) {
				return nil
			}
			return err
		}
	}
}

func parseMachineSpec(row []string) (MachineSpec, error) {
	if len(row) < machineSpecColumnCount {
		return MachineSpec{}, fmt.Errorf("expected at least %d columns, got %d", machineSpecColumnCount, len(row))
	}

	machine := strings.TrimSpace(row[machineSpecMachineIndex])
	if machine == "" {
		return MachineSpec{}, fmt.Errorf("machine is required")
	}

	cpu, err := parsePositiveFloat(row[machineSpecCapCPUIndex], "cap_cpu")
	if err != nil {
		return MachineSpec{}, err
	}
	mem, err := parsePositiveFloat(row[machineSpecCapMemIndex], "cap_mem")
	if err != nil {
		return MachineSpec{}, err
	}
	gpu, err := parseNonNegativeInteger(row[machineSpecCapGPUIndex], "cap_gpu")
	if err != nil {
		return MachineSpec{}, err
	}

	return MachineSpec{
		Machine: machine,
		GPUType: strings.TrimSpace(row[machineSpecGPUTypeIndex]),
		CapCPU:  cpu,
		CapMem:  mem,
		CapGPU:  gpu,
	}, nil
}

func parsePositiveFloat(value, field string) (float64, error) {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a number: %w", field, err)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("%s must be positive", field)
	}
	return parsed, nil
}

func parseNonNegativeInteger(value, field string) (int64, error) {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a number: %w", field, err)
	}
	if parsed < 0 {
		return 0, fmt.Errorf("%s must be non-negative", field)
	}
	if math.Trunc(parsed) != parsed {
		return 0, fmt.Errorf("%s must be an integer", field)
	}
	return int64(parsed), nil
}

func emptyCSVRow(row []string) bool {
	for _, cell := range row {
		if strings.TrimSpace(cell) != "" {
			return false
		}
	}
	return true
}
