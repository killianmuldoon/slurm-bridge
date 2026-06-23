// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
	"fmt"
	"io"
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
	namespace := fs.String("namespace", manifests.DefaultNamespace, "namespace for generated workload objects")
	runID := fs.String("run-id", manifests.DefaultRunID, "benchmark run identifier for generated workload labels")
	maxJobs := fs.Int("max-jobs", 0, "maximum number of jobs to render; 0 means unlimited")
	maxPodsPerJob := fs.Int("max-pods-per-job", 0, "skip jobs with more than this many pods; 0 means unlimited")
	traceWindow := fs.Duration("trace-window", 0, "trace submit-time window to render from the earliest selected job, for example 168h; 0 means unlimited")
	runtimeTimeScale := fs.Float64("runtime-time-scale", manifests.DefaultRuntimeTimeScale, "runtime compression factor")
	nodeLimit := 0
	fs.IntVar(&nodeLimit, "node-limit", 0, "maximum number of nodes to render; 0 means unlimited")
	fs.IntVar(&nodeLimit, "n", 0, "shorthand for --node-limit")
	includeCPUOnlyNodes := fs.Bool("include-cpu-only-nodes", false, "include machine rows with cap_gpu == 0")
	onlyNodes := fs.Bool("only-nodes", false, "render only node manifests")
	onlyWorkloads := fs.Bool("only-workloads", false, "render only normalized jobs, PodGroups, and Pods")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("render does not accept positional arguments: %v", fs.Args())
	}
	if *onlyNodes && *onlyWorkloads {
		return fmt.Errorf("--only-nodes and --only-workloads are mutually exclusive")
	}

	needNodes := !*onlyWorkloads
	needWorkloads := !*onlyNodes
	if err := requireInputFiles(*dataDir, needNodes, needWorkloads); err != nil {
		return err
	}

	if err := os.MkdirAll(*outputDir, 0o755); err != nil {
		return err
	}

	if needNodes {
		if err := renderNodes(*dataDir, *outputDir, manifests.NodeOptions{
			SchedulerName:       *schedulerName,
			Partition:           *partition,
			IncludeCPUOnlyNodes: *includeCPUOnlyNodes,
			NodeLimit:           nodeLimit,
		}); err != nil {
			return err
		}
	}

	if needWorkloads {
		if err := renderWorkloads(*dataDir, *outputDir, manifests.WorkloadOptions{
			Namespace:        *namespace,
			SchedulerName:    *schedulerName,
			RunID:            *runID,
			RuntimeTimeScale: *runtimeTimeScale,
		}, trace.NormalizeOptions{
			MaxJobs:            *maxJobs,
			MaxPodsPerJob:      *maxPodsPerJob,
			TraceWindowSeconds: traceWindow.Seconds(),
		}); err != nil {
			return err
		}
	}

	return nil
}

func requireInputFiles(dataDir string, needNodes, needWorkloads bool) error {
	var required []string
	if needNodes {
		required = append(required, trace.MachineSpecFilename)
	}
	if needWorkloads {
		required = append(required, trace.JobTableFilename, trace.TaskTableFilename, trace.InstanceTableFilename)
	}

	for _, name := range required {
		path := filepath.Join(dataDir, name)
		if _, err := os.Stat(path); err != nil {
			return err
		}
	}
	return nil
}

func renderNodes(dataDir, outputDir string, opts manifests.NodeOptions) error {
	specPath := filepath.Join(dataDir, trace.MachineSpecFilename)
	specFile, err := os.Open(specPath)
	if err != nil {
		return err
	}
	defer specFile.Close()

	nodesPath := filepath.Join(outputDir, "nodes.yaml")
	file, err := os.Create(nodesPath)
	if err != nil {
		return err
	}
	defer file.Close()

	written, err := manifests.WriteNodesYAMLFromMachineSpecs(file, specFile, opts)
	if err != nil {
		return err
	}

	fmt.Fprintf(os.Stdout, "wrote %d nodes to %s\n", written, nodesPath)

	sliceFile, err := os.Open(specPath)
	if err != nil {
		return err
	}
	defer sliceFile.Close()

	slicesPath := filepath.Join(outputDir, "resourceslices.yaml")
	if err := writeOutputFile(slicesPath, func(w io.Writer) error {
		written, err = manifests.WriteResourceSlicesYAMLFromMachineSpecs(w, sliceFile, opts)
		return err
	}); err != nil {
		return err
	}

	fmt.Fprintf(os.Stdout, "wrote %d resource slices to %s\n", written, slicesPath)
	return nil
}

func renderWorkloads(dataDir, outputDir string, workloadOpts manifests.WorkloadOptions, normalizeOpts trace.NormalizeOptions) error {
	jobPath := filepath.Join(dataDir, trace.JobTableFilename)
	taskPath := filepath.Join(dataDir, trace.TaskTableFilename)
	jobFile, err := os.Open(jobPath)
	if err != nil {
		return err
	}
	defer jobFile.Close()

	taskFile, err := os.Open(taskPath)
	if err != nil {
		return err
	}
	defer taskFile.Close()

	instancePath := filepath.Join(dataDir, trace.InstanceTableFilename)
	instanceFile, err := os.Open(instancePath)
	if err != nil {
		return err
	}
	defer instanceFile.Close()

	jobs, err := trace.NormalizeJobs(jobFile, taskFile, instanceFile, normalizeOpts)
	if err != nil {
		return err
	}

	if err := writeOutputFile(filepath.Join(outputDir, "normalized_jobs.jsonl"), func(w io.Writer) error {
		return trace.WriteJobsJSONL(w, jobs)
	}); err != nil {
		return err
	}
	if err := writeOutputFile(filepath.Join(outputDir, "podgroups.yaml"), func(w io.Writer) error {
		return manifests.WritePodGroupsYAML(w, jobs, workloadOpts)
	}); err != nil {
		return err
	}
	if err := writeOutputFile(filepath.Join(outputDir, "pods.yaml"), func(w io.Writer) error {
		return manifests.WritePodsYAML(w, jobs, workloadOpts)
	}); err != nil {
		return err
	}

	fmt.Fprintf(os.Stdout, "wrote %d jobs to %s\n", len(jobs), outputDir)
	return nil
}

func writeOutputFile(path string, write func(io.Writer) error) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return write(file)
}
