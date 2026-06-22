// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package trace

import (
	"strings"
	"testing"
)

func TestReadMachineSpecs(t *testing.T) {
	input := `machine_a,MISC,96,512,8

machine_b,V100,64.5,29.296875,1
`

	got, err := ReadMachineSpecs(strings.NewReader(input))
	if err != nil {
		t.Fatalf("ReadMachineSpecs() error = %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadMachineSpecs() returned %d specs, want 2", len(got))
	}
	if got[0].Machine != "machine_a" {
		t.Fatalf("specs did not preserve CSV order: first machine = %q", got[0].Machine)
	}
	if got[0].GPUType != "MISC" || got[0].CapCPU != 96 || got[0].CapMem != 512 || got[0].CapGPU != 8 {
		t.Fatalf("first spec = %#v", got[0])
	}
}

func TestScanMachineSpecsStopsEarly(t *testing.T) {
	input := `machine_a,V100,64,512,8
machine_b,V100,64,512,8
`

	var got []MachineSpec
	err := ScanMachineSpecs(strings.NewReader(input), func(spec MachineSpec) error {
		got = append(got, spec)
		return ErrStopScan
	})
	if err != nil {
		t.Fatalf("ScanMachineSpecs() error = %v", err)
	}
	if len(got) != 1 || got[0].Machine != "machine_a" {
		t.Fatalf("ScanMachineSpecs() got = %#v, want only first row", got)
	}
}

func TestReadMachineSpecsHeaderless(t *testing.T) {
	input := `7399a758eb02bae1a3621236,CPU,96,512,0
0ada2343597a34b8ab9a3d00,T4,96,512,2
`

	got, err := ReadMachineSpecs(strings.NewReader(input))
	if err != nil {
		t.Fatalf("ReadMachineSpecs() error = %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadMachineSpecs() returned %d specs, want 2", len(got))
	}
	if got[0].Machine != "7399a758eb02bae1a3621236" || got[0].GPUType != "CPU" || got[0].CapCPU != 96 || got[0].CapMem != 512 || got[0].CapGPU != 0 {
		t.Fatalf("first spec = %#v", got[0])
	}
	if got[1].Machine != "0ada2343597a34b8ab9a3d00" || got[1].GPUType != "T4" || got[1].CapGPU != 2 {
		t.Fatalf("second spec = %#v", got[1])
	}
}

func TestReadMachineSpecsShortRow(t *testing.T) {
	input := `machine_a,V100,64,512
`

	_, err := ReadMachineSpecs(strings.NewReader(input))
	if err == nil {
		t.Fatal("ReadMachineSpecs() error = nil, want short row error")
	}
	if !strings.Contains(err.Error(), "expected at least 5 columns") {
		t.Fatalf("ReadMachineSpecs() error = %v, want short row message", err)
	}
}

func TestReadMachineSpecsRejectsInvalidRows(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name: "zero cpu",
			input: `machine_a,V100,0,512,8
`,
			want: "cap_cpu must be positive",
		},
		{
			name: "negative gpu",
			input: `machine_a,V100,64,512,-1
`,
			want: "cap_gpu must be non-negative",
		},
		{
			name: "fractional gpu",
			input: `machine_a,V100,64,512,0.5
`,
			want: "cap_gpu must be an integer",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ReadMachineSpecs(strings.NewReader(tt.input))
			if err == nil {
				t.Fatal("ReadMachineSpecs() error = nil, want error")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("ReadMachineSpecs() error = %v, want %q", err, tt.want)
			}
		})
	}
}
