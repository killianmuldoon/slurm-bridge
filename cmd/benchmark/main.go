// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/SlinkyProject/slurm-bridge/internal/benchmark/manifests"
	"github.com/SlinkyProject/slurm-bridge/internal/benchmark/trace"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: benchmark render --data-dir data/ --output-dir out/rendered/")
	}

	switch args[0] {
	case "render":
		return runRender(args[1:])
	default:
		return fmt.Errorf("unknown command %q; only render is implemented", args[0])
	}
}

func runRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ContinueOnError)
	dataDir := fs.String("data-dir", "data", "directory containing Alibaba PAI CSV files")
	outputDir := fs.String("output-dir", "out/rendered", "directory to write rendered manifests")
	schedulerName := fs.String("scheduler-name", manifests.DefaultSchedulerName, "scheduler name for Slurm Bridge managed-node taints")
	partition := fs.String("partition", manifests.DefaultPartition, "Slurm partition for generated external nodes")
	nodeLimit := 0
	fs.IntVar(&nodeLimit, "node-limit", 0, "maximum number of nodes to render; 0 means unlimited")
	fs.IntVar(&nodeLimit, "n", 0, "shorthand for --node-limit")
	includeCPUOnlyNodes := fs.Bool("include-cpu-only-nodes", false, "include machine rows with cap_gpu == 0")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("render does not accept positional arguments: %v", fs.Args())
	}

	if err := os.MkdirAll(*outputDir, 0o755); err != nil {
		return err
	}

	specPath := filepath.Join(*dataDir, trace.MachineSpecFilename)
	specFile, err := os.Open(specPath)
	if err != nil {
		return err
	}
	defer specFile.Close()

	nodesPath := filepath.Join(*outputDir, "nodes.yaml")
	file, err := os.Create(nodesPath)
	if err != nil {
		return err
	}
	defer file.Close()

	written, err := manifests.WriteNodesYAMLFromMachineSpecs(file, specFile, manifests.NodeOptions{
		SchedulerName:       *schedulerName,
		Partition:           *partition,
		IncludeCPUOnlyNodes: *includeCPUOnlyNodes,
		NodeLimit:           nodeLimit,
	})
	if err != nil {
		return err
	}

	fmt.Fprintf(os.Stdout, "wrote %d nodes to %s\n", written, nodesPath)
	return nil
}
