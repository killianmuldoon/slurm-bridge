# Alibaba PAI v2020 KWOK Benchmark

## Review Outcome

This is the simplified implementation spec. The first version should prove one
benchmark path end to end:

```text
Alibaba PAI CSVs
  -> normalized jobs
  -> KWOK fake nodes
  -> scheduler-plugins PodGroups + Pods
  -> scheduler under test binds Pods
  -> KWOK marks Pods Running
  -> KWOK waits the per-pod runtime delay
  -> KWOK marks Pods Succeeded
  -> event log and metrics
```

Keep the MVP narrow. Do not implement JobSet generation, fractional GPUs, trace
placement replay, or multiple completion backends until the direct
PodGroup-plus-Pod path is working and measured.

Default target scheduler: `slurm-bridge-scheduler`.

The scheduler name must remain configurable so the same harness can test another
scheduler, but the generated objects should be correct for this repository's
current Slurm Bridge conventions.

## Goal

Build an in-repo benchmark harness that replays the Alibaba PAI GPU v2020 trace
into a KWOK-backed Kubernetes cluster for multi-pod AI/ML scheduling tests.

The benchmark must:

- Parse the Alibaba PAI GPU v2020 job, task, instance, and machine CSV files.
- Generate fake Kubernetes nodes from the trace machine inventory.
- Generate DRA `ResourceSlice` objects for fake GPU nodes so Slurm Bridge can
  derive Slurm-side GPU GRES.
- Submit trace-derived jobs as `PodGroup` plus member `Pod` objects.
- Let the external scheduler under test bind Pods.
- Use KWOK to simulate node and pod lifecycle on fake nodes.
- Simulate job runtime after Pods become Running.
- Emit simple post-run metrics for bind rate, completion rate, queue wait, job
  completion time, makespan, and requested utilization.

The benchmark must not implement scheduling logic.

## MVP Scope

Implement now:

- Direct `PodGroup` plus `Pod` workload generation.
- Generic integer GPU requests using `nvidia.com/gpu`.
- GPU-node-only replay by default; ignore Alibaba `gpu_type` for placement.
- Trace-window and max-job controls for bounded renders.
- Compressed per-pod runtime.
- KWOK-driven runtime completion from per-pod runtime-delay annotations.
- Rendered node, ResourceSlice, PodGroup, Pod, and normalized JSONL output.
- Slurm Bridge compatible object labels, annotations, and tolerations.

Defer:

- JobSet, MPIJob, PyTorchJob, RayJob, LeaderWorkerSet, Kueue, and Volcano
  workload adapters.
- Live submission/replay command.
- Post-run metrics collection.
- Fractional GPU resources.
- GPU type placement.
- Slurm GPU/GRES fidelity beyond generic Kubernetes GPU capacity.
- Original Alibaba placement replay.
- Sensor, machine metric, and group tag tables.
- Real GPU cluster support.
- Multiple scheduler API variants beyond the scheduler-plugins PodGroup API used
  by this repo.

## Benchmark Limits

This benchmark observes scheduler outcomes; it does not prove scheduler
correctness.

It can measure:

- Whether Pods bind.
- Which nodes Pods bind to.
- How long jobs wait before enough Pods are Running.
- Whether jobs complete under KWOK lifecycle simulation.
- Requested-resource utilization.

It cannot independently prove:

- The scheduler chose the globally optimal placement.
- Slurm Bridge respected every Slurm policy, priority, fairshare, preemption, or
  QoS rule.
- Slurm Bridge allocated GPUs through the same GRES/DRA path it would use on a
  real GPU cluster.
- The selected nodes are the only valid nodes for the job.
- A different valid scheduling decision would have been better.
- Runtime behavior on real hardware would match the fake KWOK lifecycle.

The MVP intentionally models GPUs as generic integer capacity. It does not use
Alibaba `gpu_type` for placement. It does generate node-local DRA
`ResourceSlice` objects for fake GPUs so Slurm Bridge can derive Slurm-side
GRES, but those slices are still a generic fake-device model. GPU results should
be read as generic GPU scheduling pressure rather than proof of real hardware
device correctness.

Treat the output as comparative and diagnostic. Use it to find regressions,
throughput bottlenecks, starvation, and surprising placement patterns. Do not use
it as the only correctness test for scheduling policy.

Scheduler correctness needs separate policy-focused tests with controlled inputs
and expected placements or expected Slurm decisions.

## In-Repo Shape

Keep the implementation isolated from the production scheduler code:

```text
cmd/benchmark/
internal/benchmark/
  trace/
  manifests/
  replay/
  metrics/
```

Preferred language: Go.

Reason: this repo already depends on the Kubernetes, JobSet, and scheduler
plugins APIs. A Go implementation can use the same object types and constants as
Slurm Bridge.

Object creation should be Go-native:

- Build `corev1.Node`, `corev1.Pod`, and scheduler-plugins `PodGroup` objects
  with typed Go structs.
- Apply objects with controller-runtime or client-go clients.
- Serialize YAML only for `render` output and dry-run inspection.
- Do not add a Python object-generation path for the MVP.

## Source Data

Required files:

```text
pai_job_table.csv
pai_task_table.csv
pai_instance_table.csv
pai_machine_spec.csv
```

The first implementation should read extracted CSVs from a local directory:

```text
data/
  pai_job_table.csv
  pai_task_table.csv
  pai_instance_table.csv
  pai_machine_spec.csv
```

`.tar.gz` support is optional and should not block the MVP.

### Headerless CSV Structures

The parser assumes the upstream CSV files are headerless and ordered as:

```csv
pai_job_table:
job_name,inst_id,user,status,start_time,end_time

pai_task_table:
job_name,task_name,inst_num,status,start_time,end_time,plan_cpu,plan_mem,plan_gpu,gpu_type

pai_instance_table:
job_name,task_name,inst_name,worker_name,inst_id,status,start_time,end_time,machine

pai_machine_spec:
machine,gpu_type,cap_cpu,cap_mem,cap_gpu
```

## Normalization

Normalize one Alibaba job into one benchmark job record.

Use `pai_task_table` as the authoritative source for resource templates. Use
`pai_instance_table` as the authoritative source for each generated pod and its
runtime.

Default filter:

```text
job.status == Terminated
```

Job-level runtime rule:

```text
simulated_runtime_seconds =
  pai_job_table.end_time - min(instance.start_time for the job)
```

Pod-level runtime rule:

```text
pod.simulated_runtime_seconds =
  pai_instance_table.end_time - pai_instance_table.start_time
```

Do not use:

```text
pai_job_table.end_time - pai_job_table.start_time
```

That includes Alibaba's original scheduling wait and would contaminate this
benchmark's queue-wait metric.

Resource conversion:

```text
cpu_cores = plan_cpu / 100
memory_gb = plan_mem

if plan_gpu <= 0:
  no GPU request
else:
  nvidia.com/gpu = ceil(plan_gpu / 100)
```

The MVP collapses all GPU types into this one resource. Preserve `gpu_type` in
normalized output and metrics, but do not use it to constrain placement.

Minimal normalized JSONL object:

```json
{
  "job_id": "string",
  "source_job_name": "string",
  "user": "string",
  "submit_time": 4550879.0,
  "original_completion_time": 4551416.0,
  "original_earliest_task_start_time": 4550900.0,
  "simulated_runtime_seconds": 516.0,
  "roles": [
    {
      "task_name": "worker",
      "replicas": 2,
      "cpu_cores": 4.0,
      "memory_gb": 29.296875,
      "gpu_count": 1,
      "gpu_type": "MISC",
      "pods": [
        {
          "instance_name": "worker-0",
          "instance_id": "string",
          "original_start_time": 4550900.0,
          "original_end_time": 4551416.0,
          "simulated_runtime_seconds": 516.0
        }
      ]
    }
  ]
}
```

Normalization rules:

- `job_id`: use `pai_job_table.inst_id` when present; otherwise use a sanitized
  `job_name` plus a short hash.
- `submit_time`: use `pai_job_table.start_time`.
- `simulated_runtime_seconds`: fail on values less than or equal to zero.
- `replicas`: parse `task.inst_num` as a non-negative integer.
- `pods`: include one normalized pod per terminated instance row.
- `bench.ai/runtime-delay`: derive from each pod's own instance runtime.
- `gpu_type`: preserve for metrics only.

## Time Scaling

Never replay the trace in real time.

Use these controls in the current render command:

```text
runtime_time_scale
trace_window
max_jobs
max_pods_per_job
```

Runtime scaling formula:

```text
runtime_delay =
```

Example future replay scale:

```text
runtime_time_scale = 360

3600 trace seconds = 10 wall-clock seconds
24 trace hours     = 4 wall-clock minutes
30 trace days      = 2 wall-clock hours
```

Current size controls:

```text
--trace-window
--max-jobs
--max-pods-per-job
--node-limit
--include-cpu-only-nodes
```

Expected modes:

```text
smoke:       tens of jobs, seconds to minutes
calibration: hundreds or thousands of jobs, minutes
large:       larger trace slice, hours if API server or scheduler throughput is the bottleneck
```

When live replay is added, use timers or a priority queue for job submissions
only. Do not create a goroutine or wall-clock sleep per pod completion; KWOK owns
completion timing.

## KWOK Lifecycle Fit

KWOK lifecycle configuration is Stage based: a Stage selects resources, waits
for a configured delay, and then updates status or deletes the object.

For this benchmark, use KWOK for Pod status ownership:

- Node stages keep generated fake nodes Ready.
- Pod stages move scheduled Pods to Running after `spec.nodeName` is set.
- Pod completion stages move Running Pods to Succeeded after
  `bench.ai/runtime-delay`.

Do not use a runner watch loop to start or complete jobs. Encode each Pod's
scaled runtime at object creation:

```yaml
metadata:
  annotations:
    bench.ai/runtime-delay: "<duration>"
```

Example values:

```text
bench.ai/runtime-delay: "10s"
bench.ai/runtime-delay: "2m30s"
```

KWOK's `durationFrom` can parse duration strings from annotations. The Pod
completion Stage starts its delay when the Pod matches the Stage selector, which
is after KWOK has moved the Pod to Running.

The Stage shape is:

```yaml
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Stage
metadata:
  name: bench-pod-succeeded-after-runtime
spec:
  resourceRef:
    apiGroup: v1
    kind: Pod
  selector:
    matchLabels:
      bench.ai/source: alibaba-pai-v2020
    matchExpressions:
      - key: .metadata.deletionTimestamp
        operator: DoesNotExist
      - key: .status.phase
        operator: In
        values:
          - Running
      - key: '.metadata.annotations["bench.ai/runtime-delay"]'
        operator: Exists
  delay:
    durationFrom:
      expressionFrom: '.metadata.annotations["bench.ai/runtime-delay"]'
  next:
    statusTemplate: |
      {{ $now := Now }}
      phase: Succeeded
      containerStatuses:
        {{ range .spec.containers }}
        - image: {{ .image | Quote }}
          name: {{ .name | Quote }}
          ready: false
          restartCount: 0
          started: false
          state:
            terminated:
              exitCode: 0
              finishedAt: {{ $now | Quote }}
              reason: Completed
              startedAt: {{ $now | Quote }}
        {{ end }}
```

This is passive: after objects are submitted, no benchmark component needs to
watch Pods or patch Pods for lifecycle progress.

Tradeoff: this starts runtime per Pod, not from an exact all-pods-running job
barrier. With a true gang scheduler, the difference should be small because all
Pods in the PodGroup should bind and transition to Running together. If we need
exact "start runtime only after every Pod in the job is Running" semantics for
arbitrary schedulers, some active component must observe the PodGroup and write a
start or finish signal. KWOK stages cannot count sibling Pods in a PodGroup by
themselves.

The MVP should use passive KWOK runtime. Add an exact active lifecycle mode only
if measurement shows the per-Pod runtime approximation is not good enough.

## Kubernetes Objects

The canonical scheduler-facing API for the MVP is:

```text
fake Nodes + scheduler-plugins PodGroup + member Pods
```

### Fake Nodes And ResourceSlices

Generate one fake node per selected `pai_machine_spec` row. Generate one
node-local `ResourceSlice` for each selected GPU node.

Default selection:

```text
include rows where cap_gpu > 0
exclude CPU-only rows unless --include-cpu-only-nodes is set
```

The upstream machine inventory is mostly GPU nodes, with a small CPU-only tail.
For the MVP, excluding CPU-only nodes removes a scheduling corner case without
changing the benchmark's main GPU pressure signal.

Node mapping:

```text
machine  -> metadata.name
gpu_type -> bench.ai/gpu-type label for metrics/debug only
cap_cpu  -> status.capacity.cpu and status.allocatable.cpu
cap_mem  -> status.capacity.memory and status.allocatable.memory
cap_gpu  -> generic status.capacity["nvidia.com/gpu"] and status.allocatable["nvidia.com/gpu"]
```

ResourceSlice mapping:

```text
machine -> spec.nodeName and spec.pool.name
cap_gpu -> one fake device named gpu-<index> per GPU
```

For Slurm Bridge runs, generated nodes should also be eligible as external nodes:

```yaml
apiVersion: v1
kind: Node
metadata:
  name: pai-machine-<hash>
  labels:
    kwok.x-k8s.io/node: fake
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
    bench.ai/source: alibaba-pai-v2020
    bench.ai/gpu-type: <gpu_type>
    scheduler.slinky.slurm.net/external-node: "true"
  annotations:
    scheduler.slinky.slurm.net/external-node-partitions: <partition>
spec:
  taints:
    - key: slinky.slurm.net/managed-node
      value: <schedulerName>
      effect: NoExecute
status:
  capacity:
    cpu: "<cap_cpu>"
    memory: "<ceil(cap_mem)>Gi"
    nvidia.com/gpu: "<cap_gpu>"
    pods: "110"
  allocatable:
    cpu: "<cap_cpu>"
    memory: "<ceil(cap_mem)>Gi"
    nvidia.com/gpu: "<cap_gpu>"
    pods: "110"
```

The Slurm Bridge node controller may add or reconcile the managed-node taint in
real runs. Including it in generated manifests keeps dry-run output explicit and
ensures generated pods carry the matching toleration.

Do not generate a `DeviceClass` in the MVP. The node-local `ResourceSlice`
objects are enough for Slurm Bridge to derive GRES for fake benchmark nodes.

### PodGroups

Use the scheduler-plugins PodGroup API already used by this repo:

```yaml
apiVersion: scheduling.x-k8s.io/v1alpha1
kind: PodGroup
metadata:
  name: pai-<job-id>
  namespace: <namespace>
  labels:
    bench.ai/source: alibaba-pai-v2020
    bench.ai/run-id: <run-id>
    bench.ai/job-id: <job-id>
  annotations:
    slurmjob.slinky.slurm.net/job-name: pai-<job-id>
spec:
  minMember: <sum(task.replicas)>
```

Do not use `spec.schedulingGroup.podGroupName`; that is not the PodGroup shape
currently consumed by Slurm Bridge.

### Pods

Create one Pod per normalized instance.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pai-<job-id>-<task-name>-<instance-name>-<index>
  namespace: <namespace>
  labels:
    bench.ai/source: alibaba-pai-v2020
    bench.ai/run-id: <run-id>
    bench.ai/job-id: <job-id>
    bench.ai/task-name: <task-name>
    scheduling.x-k8s.io/pod-group: pai-<job-id>
  annotations:
    bench.ai/trace-submit-time: "<submit_time>"
    bench.ai/trace-instance-name: "<instance_name>"
    bench.ai/trace-start-time: "<instance_start_time>"
    bench.ai/trace-end-time: "<instance_end_time>"
    bench.ai/simulated-runtime-seconds: "<pod_simulated_runtime_seconds>"
    bench.ai/runtime-delay: "<runtime_delay>"
spec:
  schedulerName: <schedulerName>
  restartPolicy: Never
  tolerations:
    - key: slinky.slurm.net/managed-node
      operator: Equal
      value: <schedulerName>
      effect: NoExecute
  containers:
    - name: fake
      image: registry.k8s.io/pause:3.9
      resources:
        requests:
          cpu: "<cpu_cores>"
          memory: "<ceil(memory_gb)>Gi"
          nvidia.com/gpu: "<gpu_count>"
        limits:
          cpu: "<cpu_cores>"
          memory: "<ceil(memory_gb)>Gi"
          nvidia.com/gpu: "<gpu_count>"
```

Do not emit `nvidia.com/gpu` when `gpu_count` is zero.

Do not enforce `gpu_type` through `nodeSelector`. If we need GPU-type placement,
add it later as an explicit feature that maps trace GPU types to Slurm
constraints or scheduler-specific labels. The MVP should avoid hidden placement
policy.

## Replay Semantics

The submitter:

1. Validates and normalizes the trace.
2. Applies generated fake nodes.
3. Submits each job's PodGroup and Pods at scaled trace submission time.
4. Relies on KWOK stages to move scheduled Pods to Running.
5. Relies on KWOK stages to move Running Pods to Succeeded after
   `bench.ai/runtime-delay`.
6. Exits after all submissions are sent, or after `--submit-timeout`.

The submitter must not watch Pods for lifecycle decisions and must not patch Pods
after creation.

KWOK handles Pod lifecycle after submission. It can move Pods to Running and then
Succeeded, but it does not decide when the benchmark command should stop waiting
for results. Metric collection is a separate post-hoc step.

The collector:

1. Reads Pods, PodGroups, and Kubernetes Events for `bench.ai/run-id`.
2. Waits until all submitted jobs have completed, failed, or exceeded
   `--collect-timeout`.
3. Writes `events.jsonl`, `jobs.csv`, and `metrics.json`.

Metric job start, when timestamps are available:

```text
max(running_time for all Pods in the job)
```

Record Ready condition timestamps when present, but do not make Ready a hard MVP
dependency unless the KWOK stage reliably sets it.

Metric job completion:

```text
max(succeeded_time for all Pods in the job)
```

Timeout:

```text
--submit-timeout
--collect-timeout
```

If a job has not completed by `--collect-timeout`, mark it incomplete in
`jobs.csv`. Cleanup is a separate best-effort operation after metric collection.

## Event Log

Write `events.jsonl` as a normalized post-hoc event stream derived from
submitted-object records, final Pod state, and retained Kubernetes Events.

Minimal event types:

```text
JOB_SUBMITTED
POD_CREATED
POD_BOUND
POD_RUNNING
POD_SUCCEEDED
JOB_COMPLETED
JOB_FAILED
JOB_INCOMPLETE_TIMEOUT
```

Only include events whose timestamps can be recovered reliably. Missing
timestamps should produce null fields or omitted events, not fabricated timing.

## Metrics

Generate:

```text
events.jsonl
jobs.csv
metrics.json
```

`jobs.csv` fields:

```text
run_id
job_id
source_job_name
submit_time_trace
submit_time_wall
first_observed_bound_time
all_observed_bound_time
all_observed_running_time
job_start_time
job_completion_time
simulated_runtime_seconds
wall_runtime_seconds
num_pods
cpu_requested
memory_gb_requested
gpu_requested
gpu_type_set
queue_wait_seconds
jct_seconds
status
```

Per-job definitions:

```text
queue_wait_seconds =
  job_start_time - submit_time_wall, if job_start_time is known

jct_seconds =
  job_completion_time - submit_time_wall, if job_completion_time is known

wall_runtime_seconds =
  simulated_runtime_seconds / runtime_time_scale
```

`metrics.json` fields:

```text
run_id
num_jobs_submitted
num_jobs_completed
num_jobs_failed
num_jobs_incomplete_timeout
makespan_seconds
mean_jct_seconds
median_jct_seconds
p95_jct_seconds
mean_queue_wait_seconds
median_queue_wait_seconds
p95_queue_wait_seconds
gpu_utilization_requested_time
cpu_utilization_requested_time
```

Aggregate definitions:

```text
makespan_seconds =
  max(job_completion_time) - min(submit_time_wall)

gpu_utilization_requested_time =
  sum(running_gpu_request * running_duration) / available_gpu_time

cpu_utilization_requested_time =
  sum(running_cpu_request * running_duration) / available_cpu_time
```

If timing data is missing for a job, omit it from latency percentile
calculations and report the omitted count in `metrics.json`.

## CLI

Keep the CLI small:

```text
go run ./cmd/benchmark render   --data-dir data/ --output-dir out/rendered/
```

Implemented `render` options:

```text
--data-dir
--output-dir
--namespace
--scheduler-name
--run-id
--trace-window
--max-jobs
--max-pods-per-job
--node-limit
--n
--include-cpu-only-nodes
--runtime-time-scale
--only-nodes
--only-workloads
```

`render` writes normalized jobs and manifests without applying them.

Future commands may add live apply/submission and metric generation, but those
are not implemented yet.

## Validation

Current render-time validation checks:

1. Required CSV files exist.
2. Required positional columns exist.
3. `job_name` joins from job table to task table.
4. `task.inst_num` is non-negative and integral after parsing.
5. `plan_cpu`, `plan_mem`, and `plan_gpu` are non-negative.
6. Machine specs have positive `cap_cpu`, `cap_mem`, and non-negative `cap_gpu`.
7. By default, generated node inventory excludes rows where `cap_gpu == 0`.
8. `task.inst_num` matches the number of selected terminated instance rows.
9. `simulated_runtime_seconds > 0` for included jobs.

Future validation should add:

1. Unsupported statuses are counted and reported.
2. Single-Pod requests that exceed every generated node are reported before
    replay.
3. A PodGroup that cannot fit in the generated cluster under a simple aggregate
    upper-bound check is reported before replay.

Instance/task mismatches currently fail. Keep the benchmark strict until there is
a specific reason to tolerate trace inconsistencies.

## Determinism

Generated output must be deterministic:

```text
stable sort by submit_time, then job_id
fixed random seed for sampling
stable generated names
stable manifest ordering
stable JSON object field order where practical
```

Kubernetes names must be DNS-label safe:

```text
lowercase
replace invalid characters with hyphen
append short hash to avoid collisions
limit to 63 characters where required
```

## Tests

Unit tests:

- CSV parsing.
- Normalization and runtime calculation.
- Resource conversion.
- Kubernetes name sanitization.
- Node manifest generation.
- PodGroup and Pod manifest generation.
- Post-hoc event derivation and metric calculation.
- Submit and collect timeout handling.

Integration test:

```text
2 machines
3 jobs
job A: 1 ps + 2 workers
job B: 4 workers
job C: 1 worker
```

Acceptance:

- Nodes, PodGroups, and Pods are generated.
- Pods use `scheduling.x-k8s.io/pod-group`.
- Pods use `schedulerName: slurm-bridge-scheduler`.
- Pods include the Slurm Bridge managed-node toleration.
- `events.jsonl`, `jobs.csv`, and `metrics.json` exist.
- Completed jobs have `jct_seconds >= wall_runtime_seconds`.
- `makespan_seconds` is non-null.

## Open Follow-Ups

Track these before broadening the benchmark:

1. Should the benchmark be explicitly Slurm Bridge focused, or should it keep a
   scheduler-agnostic mode with Slurm Bridge as one profile?
2. Why can Slurm Bridge mark PodGroups finished before all Kubernetes Pods bind
   under multi-job pressure?
3. What time scale gives reliable scheduler handoff without making smoke tests
   too slow?
4. Should an active lifecycle mode be added for exact job-level runtime barriers?

## Completion Criteria

The MVP is complete when:

1. It parses the required Alibaba CSVs.
2. It validates joins, resource fields, runtime fields, and obvious oversized
   jobs.
3. It emits deterministic normalized JSONL.
4. It emits Slurm Bridge compatible fake nodes.
5. It emits scheduler-plugins `PodGroup` objects and member Pods.
6. It replays at least 1,000 trace jobs into a KWOK cluster.
7. It encodes compressed runtime as `bench.ai/runtime-delay` at Pod creation.
8. KWOK completes Pods from the passive runtime Stage.
9. It writes event logs and per-job and aggregate metrics.
10. It has unit tests for parsing, manifest generation, and metrics.
11. It has a small end-to-end benchmark run documented in the README or docs.

## References

- Alibaba PAI GPU v2020 trace: https://github.com/alibaba/clusterdata/tree/master/cluster-trace-gpu-v2020
- KWOK manage nodes and pods: https://kwok.sigs.k8s.io/docs/user/kwok-manage-nodes-and-pods/
- KWOK stages configuration: https://kwok.sigs.k8s.io/docs/user/stages-configuration/
- Scheduler plugins PodGroup: https://github.com/kubernetes-sigs/scheduler-plugins/tree/master/pkg/coscheduling
