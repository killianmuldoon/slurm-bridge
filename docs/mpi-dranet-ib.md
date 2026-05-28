# MPI over DRANET InfiniBand with Kubeflow Trainer

This repository includes a first-pass MPI-over-IB smoke path using Kubeflow
Trainer v2 `TrainJob`, Trainer-generated PodGroup and JobSet, and
DRANET-provided DRA devices.

Use `TrainJob` first, not the MPI Operator. Kubeflow Trainer v2 replaces the
older framework-specific job CRDs, including `MPIJob`, with one `TrainJob` API
that can enforce MPI policy and generate the required JobSet, SSH secret, and
hostfile objects. See the Kubeflow Trainer v2 migration guide:
<https://www.kubeflow.org/docs/components/trainer/operator-guides/migration/>.

## Initial Scope

The smoke test uses Trainer's PodGroupPolicy path:

- `TrainJob/mpi-dranet-ib` references a custom `ClusterTrainingRuntime`.
- The runtime sets `podGroupPolicy.coscheduling`, so Kubeflow Trainer creates a
  PodGroup for gang scheduling.
- Kubeflow Trainer expands the TrainJob into a JobSet and child Jobs whose pods
  are labeled with the Trainer-created PodGroup.
- The runtime uses Kubeflow's public DeepSpeed image,
  `ghcr.io/kubeflow/trainer/deepspeed-runtime:v2.2.0`.
- Each pod requests `deviceclass.resource.kubernetes.io/dranet-ib: 1`.
- The runtime does not run privileged and drops `NET_ADMIN` and `SYS_ADMIN`, so
  the test no longer bypasses DRA device isolation for manual IPoIB setup.
- The runtime adds only `IPC_LOCK`, which UCX verbs needs so it can register
  pinned memory for RDMA without restoring full privileged mode.
- UCX auto-selects an available RDMA device; the proof checks UCX logs for the
  `rc_mlx5` transport instead of forcing a specific HCA.
- Each pod starts SSH, copies Trainer's `/etc/mpi/hostfile` to
  `/tmp/mpi-hostfile`, writes the MPI smoke payload, then holds. The script runs
  `kubectl exec` against the held launcher to prove MPI traffic over UCX/RDMA.
- The MPI proof prints rank output, allreduce validation, elapsed time,
  approximate per-rank and aggregate MiB/s, and UCX `rc_mlx5` transport logs.

This proves the TrainJob -> Trainer-created PodGroup -> JobSet ->
`slurm-bridge` -> DRANET IB path can run MPI traffic over RDMA. The PodGroup is
created by Trainer; the test does not create one directly.

## Prerequisites

- `slurm-bridge` scheduler deployed and configured as `slurm-bridge-scheduler`.
- Worker nodes labeled `scheduler.slinky.slurm.net/slurm-bridge=worker` and
  tolerating `slinky.slurm.net/managed-node=slurm-bridge-scheduler:NoExecute`,
  or matching overrides supplied through the script environment.
- DRANET installed and advertising InfiniBand devices through DRA.
- `DeviceClass/dranet-ib` already present.
- Slurm nodes exposing matching generic GRES capacity, for example
  `GresTypes=gpu,dranet` plus `Gres=dranet:dranet-ib:<count>`.
- `kubectl` and `helm`.

The `install` subcommand installs Kubeflow Trainer `2.2.0` and applies the
Trainer CRDs from the Helm chart before running Helm upgrade. This matters
because Helm does not upgrade CRDs during normal chart upgrades, and the
`podGroupPolicy` field lives on the Trainer runtime CRDs. If the script finds an
existing Helm release named `jobset` in `jobset-system`, it upgrades that release
to JobSet `0.11.0`, which is the JobSet API level expected by Trainer `2.2.0`.
Controller restarts are scoped to `install`; the workload subcommands do not
touch Helm releases or restart controllers.

Install DRANET separately when needed:

```sh
make install-dranet
```

## Run

For the existing kubeadm cluster:

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/trainjob-dranet-ib-test.sh install
```

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/trainjob-dranet-ib-test.sh run
```

## Record A Demo

Install or refresh dependencies outside the recording:

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/trainjob-dranet-ib-test.sh install
```

Then record the terminal demo:

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/record-mpi-dranet-ib-demo.sh record
```

The recorder uses `asciinema` and writes a `.cast` file under
`demo-recordings/`. If `agg` is installed, it also renders a GIF next to the
cast file. The recorder sets a consistent terminal size with asciinema's
`--window-size` option; override it with `SLURM_BRIDGE_MPI_DEMO_WINDOW_SIZE`,
for example `132x40` or `120x36`. The recording intentionally does not clean up
at the end so the TrainJob, JobSet, PodGroup, pods, ResourceClaims, and Slurm
allocation remain available for inspection. Run cleanup manually when finished:

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/trainjob-dranet-ib-test.sh cleanup
```

To run the same demo flow without recording:

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/record-mpi-dranet-ib-demo.sh demo
```

`run` recreates the TrainJob in hold mode, waits for the launcher and worker
pods to become Ready, runs MPI via `kubectl exec`, checks that the MPI output and
UCX logs prove RDMA traffic, and cleans up the held pods on success. To keep
successful pods running:

```sh
SLURM_BRIDGE_TRAINJOB_IB_TEST_KEEP_PODS=true \
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/trainjob-dranet-ib-test.sh run
```

To hold the same launcher and worker pods open without running the scripted MPI
proof:

```sh
KUBECONFIG=/Users/kmuldoon/go/src/slurm-bridge/kubeadm-slurm-bridge-vm.conf \
./hack/trainjob-dranet-ib-test.sh debug
```

Debug mode applies the same TrainJob/runtime path, requests the same
`dranet-ib` DRA device, configures SSH, writes `/tmp/mpi-hostfile` and
`/tmp/mpi_ib_smoke.py`, then sleeps in each pod. Use `test` to run the
`kubectl exec` MPI proof against already-held pods, and `cleanup` when done.

Useful subcommands:

```sh
./hack/trainjob-dranet-ib-test.sh install
./hack/trainjob-dranet-ib-test.sh run
./hack/trainjob-dranet-ib-test.sh test
./hack/trainjob-dranet-ib-test.sh debug
./hack/trainjob-dranet-ib-test.sh apply
./hack/trainjob-dranet-ib-test.sh manifest
./hack/trainjob-dranet-ib-test.sh status
./hack/trainjob-dranet-ib-test.sh logs
./hack/trainjob-dranet-ib-test.sh cleanup
```

## Common Overrides

```sh
SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES=4
SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_BYTES=16777216
SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_ITERS=8
SLURM_BRIDGE_TRAINJOB_IB_TEST_KEEP_PODS=true
SLURM_BRIDGE_TRAINER_VERSION=2.2.0
```

The runtime expects the DeepSpeed image to contain OpenMPI, UCX, SSH, and
`mpi4py`. It does not install packages at pod startup.

## Follow-up Features

- Whole-JobSet scheduling in `slurm-bridge`, so a TrainJob JobSet can map to
  one Slurm allocation even when a runtime does not create a PodGroup.
- A non-smoke MPI runtime with explicit site policy for UCX device selection
  when multi-HCA placement matters.
- Hardware e2e coverage where DRANET and IB are available.
