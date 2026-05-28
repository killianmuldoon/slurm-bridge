#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"

NAMESPACE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NAMESPACE:-slurm-bridge}"
TRAINJOB="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NAME:-mpi-dranet-ib}"
RUNTIME="${SLURM_BRIDGE_TRAINJOB_IB_TEST_RUNTIME:-slurm-bridge-mpi-dranet-ib}"
DEVICE_CLASS="${SLURM_BRIDGE_TRAINJOB_IB_TEST_DEVICE_CLASS:-dranet-ib}"
TRAINER_NAMESPACE="${SLURM_BRIDGE_TRAINER_NAMESPACE:-kubeflow-system}"
TRAINER_RELEASE="${SLURM_BRIDGE_TRAINER_RELEASE:-kubeflow-trainer}"
TRAINER_VERSION="${SLURM_BRIDGE_TRAINER_VERSION:-2.2.0}"
JOBSET_NAMESPACE="${SLURM_BRIDGE_JOBSET_NAMESPACE:-jobset-system}"
JOBSET_RELEASE="${SLURM_BRIDGE_JOBSET_RELEASE:-jobset}"
JOBSET_VERSION="${SLURM_BRIDGE_JOBSET_VERSION:-0.11.0}"

IMAGE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_IMAGE:-ghcr.io/kubeflow/trainer/deepspeed-runtime:v${TRAINER_VERSION}}"
IMAGE_PULL_POLICY="${SLURM_BRIDGE_TRAINJOB_IB_TEST_IMAGE_PULL_POLICY:-IfNotPresent}"
NUM_NODES="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES:-2}"
UCX_TLS="rc,sm,self"
UCX_LOG_LEVEL="info"
WAIT_TIMEOUT="${SLURM_BRIDGE_TRAINJOB_IB_TEST_WAIT_TIMEOUT:-600s}"
SSH_WAIT_TIMEOUT_SECONDS="${SLURM_BRIDGE_TRAINJOB_IB_TEST_SSH_WAIT_TIMEOUT_SECONDS:-180}"
CPU_REQUEST="${SLURM_BRIDGE_TRAINJOB_IB_TEST_CPU_REQUEST:-1}"
MEMORY_REQUEST="${SLURM_BRIDGE_TRAINJOB_IB_TEST_MEMORY_REQUEST:-512Mi}"
MEMORY_LIMIT="${SLURM_BRIDGE_TRAINJOB_IB_TEST_MEMORY_LIMIT:-1Gi}"
MPI_TRAFFIC_BYTES="${SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_BYTES:-8388608}"
MPI_TRAFFIC_ITERS="${SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_ITERS:-4}"
MODE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_MODE:-hold}"
KEEP_PODS="${SLURM_BRIDGE_TRAINJOB_IB_TEST_KEEP_PODS:-false}"
POD_GROUP_SCHEDULE_TIMEOUT_SECONDS="${SLURM_BRIDGE_TRAINJOB_IB_TEST_POD_GROUP_SCHEDULE_TIMEOUT_SECONDS:-60}"

TAINT_KEY="${SLURM_BRIDGE_TRAINJOB_IB_TEST_TAINT_KEY:-slinky.slurm.net/managed-node}"
TAINT_VALUE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_TAINT_VALUE:-slurm-bridge-scheduler}"
SCHEDULER_NAME="${SLURM_BRIDGE_TRAINJOB_IB_TEST_SCHEDULER_NAME:-slurm-bridge-scheduler}"
WORKER_NODE_SELECTOR_KEY="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NODE_SELECTOR_KEY:-scheduler.slinky.slurm.net/slurm-bridge}"
WORKER_NODE_SELECTOR_VALUE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NODE_SELECTOR_VALUE:-worker}"

function log() {
  echo "[trainjob-dranet-ib-test] $*"
}

function usage() {
  cat <<EOF
usage: $(basename "$0") [install|run|debug|apply|test|status|logs|manifest|cleanup]

Subcommands:
  install   Install or upgrade Kubeflow Trainer and JobSet dependencies.
  run       Recreate the hold-mode TrainJob, exec MPI over IB, then clean up.
  debug     Recreate the hold-mode TrainJob and leave pods running for exec.
  test      Exec the MPI proof against already-running hold-mode pods.

Environment overrides:
  KUBECTL=$KUBECTL
  HELM=$HELM
  SLURM_BRIDGE_TRAINJOB_IB_TEST_NAMESPACE=$NAMESPACE
  SLURM_BRIDGE_TRAINJOB_IB_TEST_NAME=$TRAINJOB
  SLURM_BRIDGE_TRAINJOB_IB_TEST_RUNTIME=$RUNTIME
  SLURM_BRIDGE_TRAINJOB_IB_TEST_DEVICE_CLASS=$DEVICE_CLASS
  SLURM_BRIDGE_TRAINJOB_IB_TEST_IMAGE=$IMAGE
  SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES=$NUM_NODES
  SLURM_BRIDGE_TRAINJOB_IB_TEST_WAIT_TIMEOUT=$WAIT_TIMEOUT
  SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_BYTES=$MPI_TRAFFIC_BYTES
  SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_ITERS=$MPI_TRAFFIC_ITERS
  SLURM_BRIDGE_TRAINJOB_IB_TEST_MODE=$MODE
  SLURM_BRIDGE_TRAINJOB_IB_TEST_KEEP_PODS=$KEEP_PODS
  SLURM_BRIDGE_TRAINJOB_IB_TEST_POD_GROUP_SCHEDULE_TIMEOUT_SECONDS=$POD_GROUP_SCHEDULE_TIMEOUT_SECONDS
  SLURM_BRIDGE_TRAINER_VERSION=$TRAINER_VERSION
  SLURM_BRIDGE_JOBSET_VERSION=$JOBSET_VERSION
EOF
}

function require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command not found: ${cmd}" >&2
    exit 1
  fi
}

function ensure_numeric() {
  local name="$1"
  local value="$2"
  case "$value" in
  '' | *[!0-9]*)
    echo "${name} must be an integer, got: ${value}" >&2
    exit 2
    ;;
  esac
}

function ensure_mode() {
  case "$MODE" in
  run | hold)
    ;;
  *)
    echo "SLURM_BRIDGE_TRAINJOB_IB_TEST_MODE must be run or hold, got: ${MODE}" >&2
    exit 2
    ;;
  esac
}

function apply_jobset_crds() {
  require_command "$KUBECTL"
  require_command "$HELM"
  local tmpdir
  tmpdir="$(mktemp -d)"
  log "Applying JobSet CRDs ${JOBSET_VERSION}"
  "$HELM" show crds oci://registry.k8s.io/jobset/charts/jobset \
    --version "$JOBSET_VERSION" >"${tmpdir}/jobset-crds.yaml"
  if [ ! -s "${tmpdir}/jobset-crds.yaml" ]; then
    echo "JobSet chart ${JOBSET_VERSION} did not render any CRDs" >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  "$KUBECTL" apply --server-side --force-conflicts -f "${tmpdir}/jobset-crds.yaml"
  rm -rf "$tmpdir"
}

function apply_trainer_crds() {
  require_command "$KUBECTL"
  require_command "$HELM"
  local tmpdir
  tmpdir="$(mktemp -d)"
  log "Applying Kubeflow Trainer CRDs ${TRAINER_VERSION}"
  "$HELM" show crds oci://ghcr.io/kubeflow/charts/kubeflow-trainer \
    --version "$TRAINER_VERSION" >"${tmpdir}/trainer-crds.yaml"
  if [ ! -s "${tmpdir}/trainer-crds.yaml" ]; then
    echo "Kubeflow Trainer chart ${TRAINER_VERSION} did not render any CRDs" >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  "$KUBECTL" apply --server-side --force-conflicts -f "${tmpdir}/trainer-crds.yaml"
  rm -rf "$tmpdir"
}

function install_jobset_if_release_exists() {
  require_command "$KUBECTL"
  require_command "$HELM"
  if ! "$HELM" -n "$JOBSET_NAMESPACE" status "$JOBSET_RELEASE" >/dev/null 2>&1; then
    return 1
  fi

  apply_jobset_crds
  log "Upgrading existing JobSet release ${JOBSET_NAMESPACE}/${JOBSET_RELEASE} to ${JOBSET_VERSION}"
  "$HELM" upgrade --install "$JOBSET_RELEASE" \
    oci://registry.k8s.io/jobset/charts/jobset \
    --namespace "$JOBSET_NAMESPACE" \
    --create-namespace \
    --version "$JOBSET_VERSION" \
    --set controller.resources.requests.cpu=50m \
    --set controller.resources.requests.memory=64Mi \
    --set controller.resources.limits.cpu=500m \
    --set controller.resources.limits.memory=512Mi
  log "Restarting JobSet controller so admission webhooks use the current serving certificate"
  "$KUBECTL" -n "$JOBSET_NAMESPACE" rollout restart "deployment/jobset-controller"
  "$KUBECTL" -n "$JOBSET_NAMESPACE" rollout status "deployment/jobset-controller" --timeout="$WAIT_TIMEOUT"
  return 0
}

function install_trainer() {
  require_command "$KUBECTL"
  require_command "$HELM"
  apply_trainer_crds
  local jobset_install
  jobset_install=true
  if install_jobset_if_release_exists; then
    jobset_install=false
  elif "$KUBECTL" get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1; then
    jobset_install=false
    apply_jobset_crds
    log "JobSet CRD already exists; installing Trainer with jobset.install=false"
  fi
  log "Installing Kubeflow Trainer ${TRAINER_VERSION}"
  "$HELM" upgrade --install "$TRAINER_RELEASE" \
    oci://ghcr.io/kubeflow/charts/kubeflow-trainer \
    --namespace "$TRAINER_NAMESPACE" \
    --create-namespace \
    --version "$TRAINER_VERSION" \
    --set runtimes.defaultEnabled=false \
    --set "jobset.install=${jobset_install}"
  "$KUBECTL" -n "$TRAINER_NAMESPACE" rollout status "deployment/${TRAINER_RELEASE}-controller-manager" --timeout="$WAIT_TIMEOUT"
  log "Restarting Trainer controller so admission webhooks use the current serving certificate"
  "$KUBECTL" -n "$TRAINER_NAMESPACE" rollout restart "deployment/${TRAINER_RELEASE}-controller-manager"
  "$KUBECTL" -n "$TRAINER_NAMESPACE" rollout status "deployment/${TRAINER_RELEASE}-controller-manager" --timeout="$WAIT_TIMEOUT"
}

function render_manifest() {
  ensure_mode
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES "$NUM_NODES"
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_SSH_WAIT_TIMEOUT_SECONDS "$SSH_WAIT_TIMEOUT_SECONDS"
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_BYTES "$MPI_TRAFFIC_BYTES"
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_MPI_TRAFFIC_ITERS "$MPI_TRAFFIC_ITERS"
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_POD_GROUP_SCHEDULE_TIMEOUT_SECONDS "$POD_GROUP_SCHEDULE_TIMEOUT_SECONDS"
  if [ "$NUM_NODES" -lt 2 ]; then
    echo "SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES must be at least 2 for cross-pod IB validation" >&2
    exit 2
  fi

  cat <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    slurm-bridge.slinky.slurm.net/managed: "true"
---
apiVersion: trainer.kubeflow.org/v1alpha1
kind: ClusterTrainingRuntime
metadata:
  name: ${RUNTIME}
  labels:
    trainer.kubeflow.org/framework: mpi
    app.kubernetes.io/name: trainjob-dranet-ib-test
spec:
  podGroupPolicy:
    coscheduling:
      scheduleTimeoutSeconds: ${POD_GROUP_SCHEDULE_TIMEOUT_SECONDS}
  mlPolicy:
    numNodes: 1
    mpi:
      numProcPerNode: 1
      mpiImplementation: OpenMPI
      sshAuthMountPath: /root/.ssh
      runLauncherAsNode: true
  template:
    metadata:
      annotations:
        slurmjob.slinky.slurm.net/job-name: ${TRAINJOB}
        slurmjob.slinky.slurm.net/exclusive: "true"
        slurmjob.slinky.slurm.net/timelimit: "30"
    spec:
      network:
        publishNotReadyAddresses: true
      successPolicy:
        operator: All
        targetReplicatedJobs:
          - launcher
          - node
      replicatedJobs:
        - name: launcher
          template:
            metadata:
              labels:
                trainer.kubeflow.org/trainjob-ancestor-step: trainer
                app.kubernetes.io/name: trainjob-dranet-ib-test
                app.kubernetes.io/instance: ${TRAINJOB}
            spec:
              template:
                metadata:
                  labels:
                    app.kubernetes.io/name: trainjob-dranet-ib-test
                    app.kubernetes.io/instance: ${TRAINJOB}
                    app.kubernetes.io/component: launcher
                spec:
                  schedulerName: ${SCHEDULER_NAME}
                  restartPolicy: Never
                  automountServiceAccountToken: false
                  nodeSelector:
                    ${WORKER_NODE_SELECTOR_KEY}: ${WORKER_NODE_SELECTOR_VALUE}
                  affinity:
                    podAntiAffinity:
                      requiredDuringSchedulingIgnoredDuringExecution:
                        - labelSelector:
                            matchLabels:
                              app.kubernetes.io/name: trainjob-dranet-ib-test
                              app.kubernetes.io/instance: ${TRAINJOB}
                          topologyKey: kubernetes.io/hostname
                  tolerations:
                    - key: ${TAINT_KEY}
                      operator: Equal
                      value: ${TAINT_VALUE}
                      effect: NoExecute
                  containers:
                    - name: node
                      image: ${IMAGE}
                      imagePullPolicy: ${IMAGE_PULL_POLICY}
                      command:
                        - /bin/bash
                        - -lc
                      args:
                        - &mpi_ib_node_script |
                          set -euo pipefail
                          export DEBIAN_FRONTEND=noninteractive
                          export PYTHONPATH="/home/mpiuser/.local/lib/python3.10/site-packages:\${PYTHONPATH:-}"
                          /usr/bin/python3 -c 'from mpi4py import MPI'
                          mkdir -p /tmp/ssh /run/sshd
                          cp /root/.ssh/id_rsa /tmp/ssh/id_rsa
                          cp /root/.ssh/id_rsa.pub /tmp/ssh/id_rsa.pub
                          cp /root/.ssh/authorized_keys /tmp/ssh/authorized_keys
                          chmod 600 /tmp/ssh/id_rsa /tmp/ssh/authorized_keys
                          chmod 644 /tmp/ssh/id_rsa.pub
                          ssh-keygen -A
                          cat >/tmp/sshd_config <<'SSHD'
                          Port 2222
                          PermitRootLogin yes
                          PubkeyAuthentication yes
                          PasswordAuthentication no
                          StrictModes no
                          UsePAM no
                          AuthorizedKeysFile /tmp/ssh/authorized_keys
                          SSHD
                          /usr/sbin/sshd -f /tmp/sshd_config -E /tmp/sshd.log
                          replicated_job="\${JOBSET_REPLICATED_JOB_NAME:?missing JobSet replicated job label}"
                          completion_index="\${JOB_COMPLETION_INDEX:?missing indexed Job completion label}"
                          hostfile=/tmp/mpi-hostfile
                          if [ -f /etc/mpi/hostfile ]; then
                            cp /etc/mpi/hostfile "\$hostfile"
                          elif [ "\$replicated_job" = "launcher" ]; then
                            echo "/etc/mpi/hostfile is missing from launcher; Kubeflow Trainer did not publish MPI hostfile data" >&2
                            exit 1
                          else
                            : >"\$hostfile"
                          fi
                          world_size="\$TRAINJOB_NUM_NODES"
                          cat >/tmp/mpi_ib_smoke.py <<'PY'
                          import os
                          from array import array
                          from mpi4py import MPI

                          comm = MPI.COMM_WORLD
                          rank = comm.Get_rank()
                          size = comm.Get_size()
                          if size < 2:
                              raise SystemExit("need at least 2 MPI ranks for cross-node traffic")
                          traffic_bytes = int(os.getenv("MPI_TRAFFIC_BYTES", "8388608"))
                          traffic_iters = int(os.getenv("MPI_TRAFFIC_ITERS", "4"))
                          payload = bytearray([rank % 251]) * traffic_bytes
                          recv = bytearray(traffic_bytes)
                          next_rank = (rank + 1) % size
                          prev_rank = (rank - 1) % size
                          comm.Barrier()
                          start = MPI.Wtime()
                          for _ in range(traffic_iters):
                              comm.Sendrecv([payload, MPI.BYTE], dest=next_rank, sendtag=7, recvbuf=[recv, MPI.BYTE], source=prev_rank, recvtag=7)
                          comm.Barrier()
                          elapsed = max(MPI.Wtime() - start, 1e-9)
                          send_total = array("i", [rank + 1])
                          recv_total = array("i", [0])
                          comm.Allreduce([send_total, MPI.INT], [recv_total, MPI.INT], op=MPI.SUM)
                          send_mib = traffic_bytes * traffic_iters / 1048576
                          rank_bandwidth = send_mib / elapsed
                          send_bandwidth = array("d", [rank_bandwidth])
                          aggregate_bandwidth = array("d", [0.0])
                          comm.Allreduce([send_bandwidth, MPI.DOUBLE], [aggregate_bandwidth, MPI.DOUBLE], op=MPI.SUM)
                          checksum = sum(recv[::4096])
                          print(
                              f"rank={rank} size={size} host={os.uname().nodename} "
                              f"allreduce_sum={recv_total[0]} traffic_bytes_per_rank={traffic_bytes} "
                              f"traffic_iters={traffic_iters} mpi_elapsed_seconds={elapsed:.6f} "
                              f"rank_bandwidth_mib_s={rank_bandwidth:.2f} "
                              f"aggregate_bandwidth_mib_s={aggregate_bandwidth[0]:.2f} checksum={checksum}",
                              flush=True,
                          )
                          with open("/tmp/mpi_done", "w", encoding="utf-8") as done:
                              done.write("ok\n")
                          PY
                          echo "node ready replicated_job=\${replicated_job} completion_index=\${completion_index} world_size=\${world_size}"
                          cat "\$hostfile"
                          if [ "\$MPI_SMOKE_MODE" = "hold" ]; then
                            echo "debug hold active; pod is ready for kubectl exec"
                            trap 'exit 0' TERM INT
                            while true; do
                              sleep 3600 &
                              wait "\$!"
                            done
                          fi
                          if [ "\$replicated_job" != "launcher" ] || [ "\$completion_index" != "0" ]; then
                            while [ ! -f /tmp/mpi_done ]; do
                              sleep 2
                            done
                            exit 0
                          fi
                          deadline="\$((\$(date +%s) + SSH_WAIT_TIMEOUT_SECONDS))"
                          while read -r host _; do
                            until ssh -p 2222 -i /tmp/ssh/id_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@\${host}" true >/dev/null 2>&1; do
                              if [ "\$(date +%s)" -ge "\$deadline" ]; then
                                echo "timed out waiting for ssh on \${host}" >&2
                                cat /tmp/sshd.log >&2 || true
                                exit 1
                              fi
                              sleep 2
                            done
                          done <"\$hostfile"
                          mpirun \
                            --allow-run-as-root \
                            --hostfile "\$hostfile" \
                            -np "\$world_size" \
                            --mca pml ucx \
                            --mca osc ucx \
                            --mca plm_rsh_args "-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10" \
                            -x UCX_TLS \
                            -x UCX_LOG_LEVEL \
                            -x PYTHONPATH \
                            -x MPI_TRAFFIC_BYTES \
                            -x MPI_TRAFFIC_ITERS \
                            /usr/bin/python3 /tmp/mpi_ib_smoke.py
                          while read -r host _; do
                            ssh -p 2222 -i /tmp/ssh/id_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@\${host}" 'touch /tmp/mpi_done' >/dev/null 2>&1 || true
                          done <"\$hostfile"
                      env:
                        - name: TRAINJOB_NUM_NODES
                          value: "${NUM_NODES}"
                        - name: UCX_TLS
                          value: "${UCX_TLS}"
                        - name: UCX_LOG_LEVEL
                          value: "${UCX_LOG_LEVEL}"
                        - name: SSH_WAIT_TIMEOUT_SECONDS
                          value: "${SSH_WAIT_TIMEOUT_SECONDS}"
                        - name: MPI_TRAFFIC_BYTES
                          value: "${MPI_TRAFFIC_BYTES}"
                        - name: MPI_TRAFFIC_ITERS
                          value: "${MPI_TRAFFIC_ITERS}"
                        - name: MPI_SMOKE_MODE
                          value: "${MODE}"
                        - name: JOBSET_REPLICATED_JOB_NAME
                          valueFrom:
                            fieldRef:
                              fieldPath: metadata.labels['jobset.sigs.k8s.io/replicatedjob-name']
                      securityContext:
                        allowPrivilegeEscalation: false
                        capabilities:
                          add:
                            - IPC_LOCK
                          drop:
                            - NET_ADMIN
                            - SYS_ADMIN
                      resources:
                        requests:
                          cpu: "${CPU_REQUEST}"
                          memory: ${MEMORY_REQUEST}
                          deviceclass.resource.kubernetes.io/${DEVICE_CLASS}: "1"
                        limits:
                          cpu: "${CPU_REQUEST}"
                          memory: ${MEMORY_LIMIT}
                          deviceclass.resource.kubernetes.io/${DEVICE_CLASS}: "1"
        - name: node
          template:
            metadata:
              labels:
                app.kubernetes.io/name: trainjob-dranet-ib-test
                app.kubernetes.io/instance: ${TRAINJOB}
            spec:
              template:
                metadata:
                  labels:
                    app.kubernetes.io/name: trainjob-dranet-ib-test
                    app.kubernetes.io/instance: ${TRAINJOB}
                    app.kubernetes.io/component: worker
                spec:
                  schedulerName: ${SCHEDULER_NAME}
                  restartPolicy: Never
                  automountServiceAccountToken: false
                  nodeSelector:
                    ${WORKER_NODE_SELECTOR_KEY}: ${WORKER_NODE_SELECTOR_VALUE}
                  affinity:
                    podAntiAffinity:
                      requiredDuringSchedulingIgnoredDuringExecution:
                        - labelSelector:
                            matchLabels:
                              app.kubernetes.io/name: trainjob-dranet-ib-test
                              app.kubernetes.io/instance: ${TRAINJOB}
                          topologyKey: kubernetes.io/hostname
                  tolerations:
                    - key: ${TAINT_KEY}
                      operator: Equal
                      value: ${TAINT_VALUE}
                      effect: NoExecute
                  containers:
                    - name: node
                      image: ${IMAGE}
                      imagePullPolicy: ${IMAGE_PULL_POLICY}
                      command:
                        - /bin/bash
                        - -lc
                      args:
                        - *mpi_ib_node_script
                      env:
                        - name: TRAINJOB_NUM_NODES
                          value: "${NUM_NODES}"
                        - name: UCX_TLS
                          value: "${UCX_TLS}"
                        - name: UCX_LOG_LEVEL
                          value: "${UCX_LOG_LEVEL}"
                        - name: MPI_TRAFFIC_BYTES
                          value: "${MPI_TRAFFIC_BYTES}"
                        - name: MPI_TRAFFIC_ITERS
                          value: "${MPI_TRAFFIC_ITERS}"
                        - name: MPI_SMOKE_MODE
                          value: "${MODE}"
                        - name: JOBSET_REPLICATED_JOB_NAME
                          valueFrom:
                            fieldRef:
                              fieldPath: metadata.labels['jobset.sigs.k8s.io/replicatedjob-name']
                      readinessProbe:
                        tcpSocket:
                          port: 2222
                        initialDelaySeconds: 5
                        periodSeconds: 2
                        failureThreshold: 60
                      securityContext:
                        allowPrivilegeEscalation: false
                        capabilities:
                          add:
                            - IPC_LOCK
                          drop:
                            - NET_ADMIN
                            - SYS_ADMIN
                      resources:
                        requests:
                          cpu: "${CPU_REQUEST}"
                          memory: ${MEMORY_REQUEST}
                          deviceclass.resource.kubernetes.io/${DEVICE_CLASS}: "1"
                        limits:
                          cpu: "${CPU_REQUEST}"
                          memory: ${MEMORY_LIMIT}
                          deviceclass.resource.kubernetes.io/${DEVICE_CLASS}: "1"
---
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: ${TRAINJOB}
  namespace: ${NAMESPACE}
spec:
  runtimeRef:
    apiGroup: trainer.kubeflow.org
    kind: ClusterTrainingRuntime
    name: ${RUNTIME}
  trainer:
    numNodes: ${NUM_NODES}
    numProcPerNode: 1
EOF
}

function apply_manifest() {
  require_command "$KUBECTL"
  local tmpdir
  tmpdir="$(mktemp -d)"
  render_manifest >"${tmpdir}/trainjob-dranet-ib.yaml"
  log "Applying TrainJob JobSet DRANET IB workload to context: $("$KUBECTL" config current-context)"
  "$KUBECTL" apply -f "${tmpdir}/trainjob-dranet-ib.yaml"
  rm -rf "$tmpdir"
}

function pod_selector() {
  printf 'app.kubernetes.io/name=trainjob-dranet-ib-test,app.kubernetes.io/instance=%s' "$TRAINJOB"
}

function launcher_pod_name() {
  "$KUBECTL" -n "$NAMESPACE" get pods \
    -l "$(pod_selector),app.kubernetes.io/component=launcher,batch.kubernetes.io/job-completion-index=0" \
    -o jsonpath='{.items[0].metadata.name}'
}

function test_pod_names() {
  "$KUBECTL" -n "$NAMESPACE" get pods \
    -l "$(pod_selector)" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

function timeout_seconds() {
  local value="$1"
  case "$value" in
  *s) printf '%s\n' "${value%s}" ;;
  *m) printf '%s\n' "$((${value%m} * 60))" ;;
  *h) printf '%s\n' "$((${value%h} * 3600))" ;;
  '' | *[!0-9]*)
    echo "unsupported timeout format: ${value}; use an integer number of seconds or a value ending in s/m/h" >&2
    exit 2
    ;;
  *) printf '%s\n' "$value" ;;
  esac
}

function wait_for_pod_count() {
  local selector="$1"
  local expected="$2"
  local deadline count
  deadline="$(($(date +%s) + $(timeout_seconds "$WAIT_TIMEOUT")))"
  while true; do
    count="$("$KUBECTL" -n "$NAMESPACE" get pods -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -ge "$expected" ]; then
      return
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timed out waiting for ${expected} pods matching ${selector}; saw ${count}" >&2
      return 1
    fi
    sleep 2
  done
}

function wait_for_hold_pods() {
  require_command "$KUBECTL"
  log "Waiting for hold-mode TrainJob ${NAMESPACE}/${TRAINJOB} to create JobSet pods"
  wait_for_pod_count "$(pod_selector)" "$NUM_NODES"

  log "Waiting for hold-mode pods to become Ready"
  "$KUBECTL" -n "$NAMESPACE" wait \
    --for=condition=Ready \
    "pod" -l "$(pod_selector)" \
    --timeout="$WAIT_TIMEOUT"
}

function run_exec_mpi_test() {
  require_command "$KUBECTL"
  local launcher pods output mpirun_cmd pod
  launcher="$(launcher_pod_name)"
  pods="$(test_pod_names)"
  if [ -z "$launcher" ] || [ -z "$pods" ]; then
    echo "test pods are not available" >&2
    exit 1
  fi

  log "RDMA devices visible to each pod"
  while read -r pod; do
    [ -n "$pod" ] || continue
    "$KUBECTL" -n "$NAMESPACE" exec "$pod" -- /bin/bash -lc \
      'set -euo pipefail; echo "pod=$(hostname)"; for d in /sys/class/infiniband/*; do [ -e "$d" ] || continue; dev=$(basename "$d"); for p in "$d"/ports/*; do [ -e "$p" ] || continue; port=$(basename "$p"); printf "%s:%s state=%s link_layer=%s rate=%s\n" "$dev" "$port" "$(cat "$p/state" 2>/dev/null || true)" "$(cat "$p/link_layer" 2>/dev/null || true)" "$(cat "$p/rate" 2>/dev/null || true)"; done; done'
  done <<<"$pods"

  log "MPI hostfile from launcher"
  "$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- cat /tmp/mpi-hostfile

  log "Verifying MPI launcher SSH control path"
  "$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- /bin/bash -lc \
    'set -euo pipefail; while read -r host _; do ssh -p 2222 -i /tmp/ssh/id_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@${host}" true; done </tmp/mpi-hostfile'

  mpirun_cmd='set -euo pipefail
export PYTHONPATH="/home/mpiuser/.local/lib/python3.10/site-packages:${PYTHONPATH:-}"
mpirun --allow-run-as-root --hostfile /tmp/mpi-hostfile -np '"${NUM_NODES}"' --mca pml ucx --mca osc ucx --mca plm_rsh_args "-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10" -x UCX_TLS -x UCX_LOG_LEVEL -x PYTHONPATH -x MPI_TRAFFIC_BYTES -x MPI_TRAFFIC_ITERS /usr/bin/python3 /tmp/mpi_ib_smoke.py'

  log "Running MPI traffic over UCX/RDMA"
  if ! output="$("$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- /bin/bash -lc "$mpirun_cmd" 2>&1)"; then
    printf '%s\n' "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output"

  if ! printf '%s\n' "$output" | grep -q 'allreduce_sum='; then
    echo "MPI output does not contain allreduce proof" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -q 'aggregate_bandwidth_mib_s='; then
    echo "MPI output does not contain bandwidth proof" >&2
    exit 1
  fi
  if [ "$UCX_LOG_LEVEL" = "info" ] && ! printf '%s\n' "$output" | grep -q 'rc_mlx5/'; then
    echo "UCX info logs do not show rc_mlx5 RDMA transport" >&2
    exit 1
  fi
}

function wait_for_debug() {
  require_command "$KUBECTL"
  wait_for_hold_pods

  show_status
  log "Debug pods are running. Exec into them with:"
  "$KUBECTL" -n "$NAMESPACE" get pods \
    -l "$(pod_selector)" \
    -o custom-columns=NAME:.metadata.name,COMPONENT:.metadata.labels.app\\.kubernetes\\.io/component,NODE:.spec.nodeName,IP:.status.podIP,PHASE:.status.phase
  cat <<EOF

Launcher shell:
  ${KUBECTL} -n ${NAMESPACE} exec -it \$(${KUBECTL} -n ${NAMESPACE} get pods -l "$(pod_selector),app.kubernetes.io/component=launcher" -o jsonpath='{.items[0].metadata.name}') -- bash

Useful checks inside a pod:
  cat /tmp/mpi-hostfile
  for d in /sys/class/infiniband/*; do echo "\$d"; cat "\$d"/ports/*/state; cat "\$d"/ports/*/link_layer; done
  while read -r host _; do ssh -p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@\$host hostname; done </tmp/mpi-hostfile

Manual MPI from the launcher:
  PYTHONPATH="/home/mpiuser/.local/lib/python3.10/site-packages:\${PYTHONPATH:-}" mpirun --allow-run-as-root --hostfile /tmp/mpi-hostfile -np ${NUM_NODES} --mca pml ucx --mca osc ucx --mca plm_rsh_args "-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10" -x UCX_TLS -x UCX_LOG_LEVEL -x PYTHONPATH -x MPI_TRAFFIC_BYTES -x MPI_TRAFFIC_ITERS /usr/bin/python3 /tmp/mpi_ib_smoke.py
EOF
}

function show_status() {
  "$KUBECTL" get deviceclass "$DEVICE_CLASS" -o wide || true
  "$KUBECTL" -n "$NAMESPACE" get trainjob "$TRAINJOB" -o wide || true
  "$KUBECTL" -n "$NAMESPACE" get jobset "$TRAINJOB" -o wide || true
  "$KUBECTL" -n "$NAMESPACE" get pods -l "$(pod_selector)" -o wide --show-labels || true
  "$KUBECTL" -n "$NAMESPACE" get resourceclaims -o wide || true
}

function show_logs() {
  local pods
  pods="$("$KUBECTL" -n "$NAMESPACE" get pods -l "$(pod_selector)" -o name || true)"
  if [ -z "$pods" ]; then
    echo "no test pods found" >&2
    return 1
  fi
  while read -r pod; do
    [ -n "$pod" ] || continue
    log "Logs for ${pod}"
    "$KUBECTL" -n "$NAMESPACE" logs "$pod" || true
  done <<<"$pods"
}

function cleanup() {
  require_command "$KUBECTL"
  local claims deadline
  log "Deleting TrainJob JobSet DRANET IB workload from context: $("$KUBECTL" config current-context)"
  "$KUBECTL" -n "$NAMESPACE" delete trainjob "$TRAINJOB" --ignore-not-found --wait=false
  "$KUBECTL" -n "$NAMESPACE" delete jobset "$TRAINJOB" --ignore-not-found --wait=false
  "$KUBECTL" -n "$NAMESPACE" delete podgroup "$TRAINJOB" --ignore-not-found --wait=false
  "$KUBECTL" -n "$NAMESPACE" delete pods -l "$(pod_selector)" --ignore-not-found --wait=false
  claims="$("$KUBECTL" -n "$NAMESPACE" get resourceclaims -o name 2>/dev/null | grep "^resourceclaim/${TRAINJOB}" || true)"
  if [ -n "$claims" ]; then
    "$KUBECTL" -n "$NAMESPACE" delete $claims --ignore-not-found --wait=false
  fi
  "$KUBECTL" -n "$NAMESPACE" wait --for=delete trainjob "$TRAINJOB" --timeout="$WAIT_TIMEOUT" 2>/dev/null || true
  "$KUBECTL" -n "$NAMESPACE" wait --for=delete jobset "$TRAINJOB" --timeout="$WAIT_TIMEOUT" 2>/dev/null || true
  "$KUBECTL" -n "$NAMESPACE" wait --for=delete podgroup "$TRAINJOB" --timeout="$WAIT_TIMEOUT" 2>/dev/null || true
  "$KUBECTL" -n "$NAMESPACE" wait --for=delete pods -l "$(pod_selector)" --timeout="$WAIT_TIMEOUT" || true
  deadline="$(($(date +%s) + $(timeout_seconds "$WAIT_TIMEOUT")))"
  while "$KUBECTL" -n "$NAMESPACE" get resourceclaims -o name 2>/dev/null | grep -q "^resourceclaim/${TRAINJOB}"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timed out waiting for generated ResourceClaims for ${TRAINJOB} to delete" >&2
      return 1
    fi
    sleep 2
  done
}

case "${1:-run}" in
run)
  MODE=hold
  cleanup
  apply_manifest
  wait_for_hold_pods
  show_status
  run_exec_mpi_test
  if [ "$KEEP_PODS" = "true" ]; then
    log "Leaving hold-mode pods running because SLURM_BRIDGE_TRAINJOB_IB_TEST_KEEP_PODS=true"
  else
    cleanup
  fi
  ;;
debug)
  MODE=hold
  cleanup
  apply_manifest
  wait_for_debug
  ;;
install)
  install_trainer
  ;;
apply)
  apply_manifest
  ;;
test)
  wait_for_hold_pods
  run_exec_mpi_test
  ;;
status)
  show_status
  ;;
logs)
  show_logs
  ;;
manifest)
  render_manifest
  ;;
cleanup)
  cleanup
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 2
  ;;
esac
