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
IB_IFACE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_IFACE:-ib0}"
IB_IPV4_PREFIX="${SLURM_BRIDGE_TRAINJOB_IB_TEST_IPV4_PREFIX:-10.200.3}"
IB_IPV4_PREFIX_LEN="${SLURM_BRIDGE_TRAINJOB_IB_TEST_IPV4_PREFIX_LEN:-24}"
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
  SLURM_BRIDGE_TRAINJOB_IB_TEST_IFACE=$IB_IFACE
  SLURM_BRIDGE_TRAINJOB_IB_TEST_IPV4_PREFIX=$IB_IPV4_PREFIX
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
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_IPV4_PREFIX_LEN "$IB_IPV4_PREFIX_LEN"
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
                          if ! command -v ip >/dev/null 2>&1 || ! /usr/bin/python3 -c 'from mpi4py import MPI' >/dev/null 2>&1; then
                            apt-get update
                            apt-get install -y --no-install-recommends iproute2 python3-mpi4py
                          fi
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
                          case "\$replicated_job" in
                          launcher)
                            ordinal="\$completion_index"
                            ;;
                          node)
                            ordinal="\$((1 + completion_index))"
                            ;;
                          *)
                            echo "unsupported replicated job: \${replicated_job}" >&2
                            exit 1
                            ;;
                          esac
                          if [ -f /etc/mpi/hostfile ]; then
                            world_size="\$(wc -l </etc/mpi/hostfile)"
                          else
                            world_size="\$TRAINJOB_NUM_NODES"
                          fi
                          world_size="\$(echo "\$world_size" | tr -d ' ')"
                          if ! ip link show "\$IB_INTERFACE" >/dev/null 2>&1; then
                            IB_INTERFACE=""
                            for candidate in /sys/class/net/*; do
                              if [ "\$(cat "\${candidate}/type")" = "32" ]; then
                                IB_INTERFACE="\$(basename "\$candidate")"
                                break
                              fi
                            done
                          fi
                          if [ -z "\$IB_INTERFACE" ]; then
                            echo "no InfiniBand interface found in pod" >&2
                            ip -br link >&2 || true
                            exit 1
                          fi
                          ip_addr="\${IB_IPV4_PREFIX}.\$((101 + ordinal))/\${IB_IPV4_PREFIX_LEN}"
                          ip link show "\$IB_INTERFACE"
                          ip link set "\$IB_INTERFACE" up
                          ip addr replace "\$ip_addr" dev "\$IB_INTERFACE"
                          ip -br addr show "\$IB_INTERFACE"
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
                          echo "node ready replicated_job=\${replicated_job} completion_index=\${completion_index} ordinal=\${ordinal} world_size=\${world_size}"
                          hostfile=/tmp/mpi-hostfile
                          : >"\$hostfile"
                          i=0
                          while [ "\$i" -lt "\$world_size" ]; do
                            printf '%s.%d slots=1\n' "\$IB_IPV4_PREFIX" "\$((101 + i))" >>"\$hostfile"
                            i="\$((i + 1))"
                          done
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
                          rx_before="\$(cat "/sys/class/net/\${IB_INTERFACE}/statistics/rx_bytes")"
                          tx_before="\$(cat "/sys/class/net/\${IB_INTERFACE}/statistics/tx_bytes")"
                          echo "ib_link_stats_before \${IB_INTERFACE} rx_bytes=\${rx_before} tx_bytes=\${tx_before}"
                          mpirun \
                            --allow-run-as-root \
                            --hostfile "\$hostfile" \
                            -np "\$world_size" \
                            --mca btl_tcp_if_include "\$IB_INTERFACE" \
                            --mca oob_tcp_if_include "\$IB_INTERFACE" \
                            --mca plm_rsh_args "-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10" \
                            -x MPI_TRAFFIC_BYTES \
                            -x MPI_TRAFFIC_ITERS \
                            /usr/bin/python3 /tmp/mpi_ib_smoke.py
                          while read -r host _; do
                            ssh -p 2222 -i /tmp/ssh/id_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@\${host}" 'touch /tmp/mpi_done' >/dev/null 2>&1 || true
                          done <"\$hostfile"
                          rx_after="\$(cat "/sys/class/net/\${IB_INTERFACE}/statistics/rx_bytes")"
                          tx_after="\$(cat "/sys/class/net/\${IB_INTERFACE}/statistics/tx_bytes")"
                          echo "ib_link_stats_after \${IB_INTERFACE} rx_bytes=\${rx_after} tx_bytes=\${tx_after}"
                      env:
                        - name: TRAINJOB_NUM_NODES
                          value: "${NUM_NODES}"
                        - name: IB_INTERFACE
                          value: ${IB_IFACE}
                        - name: IB_IPV4_PREFIX
                          value: ${IB_IPV4_PREFIX}
                        - name: IB_IPV4_PREFIX_LEN
                          value: "${IB_IPV4_PREFIX_LEN}"
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
                        privileged: true
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
                        - name: IB_INTERFACE
                          value: ${IB_IFACE}
                        - name: IB_IPV4_PREFIX
                          value: ${IB_IPV4_PREFIX}
                        - name: IB_IPV4_PREFIX_LEN
                          value: "${IB_IPV4_PREFIX_LEN}"
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
                        privileged: true
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

function read_pod_counter() {
  local pod="$1"
  local counter="$2"
  "$KUBECTL" -n "$NAMESPACE" exec "$pod" -- \
    cat "/sys/class/net/${IB_IFACE}/statistics/${counter}" | tr -d '\r\n'
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
  local launcher pods tmpdir output mpirun_cmd pod
  local rx_before tx_before rx_after tx_after rx_delta tx_delta
  local total_rx_delta total_tx_delta
  launcher="$(launcher_pod_name)"
  pods="$(test_pod_names)"
  if [ -z "$launcher" ] || [ -z "$pods" ]; then
    echo "test pods are not available" >&2
    exit 1
  fi

  log "IB addresses"
  while read -r pod; do
    [ -n "$pod" ] || continue
    "$KUBECTL" -n "$NAMESPACE" exec "$pod" -- ip -br addr show "$IB_IFACE"
  done <<<"$pods"

  log "MPI hostfile from launcher"
  "$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- cat /tmp/mpi-hostfile

  log "Verifying SSH over ${IB_IFACE}"
  "$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- /bin/bash -lc \
    'set -euo pipefail; while read -r host _; do ssh -p 2222 -i /tmp/ssh/id_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "root@${host}" true; done </tmp/mpi-hostfile'

  tmpdir="$(mktemp -d)"
  while read -r pod; do
    [ -n "$pod" ] || continue
    read_pod_counter "$pod" rx_bytes >"${tmpdir}/${pod}.rx_before"
    read_pod_counter "$pod" tx_bytes >"${tmpdir}/${pod}.tx_before"
  done <<<"$pods"

  mpirun_cmd="mpirun --allow-run-as-root --hostfile /tmp/mpi-hostfile -np ${NUM_NODES} --mca btl_tcp_if_include ${IB_IFACE} --mca oob_tcp_if_include ${IB_IFACE} --mca plm_rsh_args \"-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10\" -x MPI_TRAFFIC_BYTES -x MPI_TRAFFIC_ITERS /usr/bin/python3 /tmp/mpi_ib_smoke.py"

  log "Running MPI traffic over ${IB_IFACE}"
  if ! output="$("$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- /bin/bash -lc "$mpirun_cmd")"; then
    printf '%s\n' "$output" >&2
    rm -rf "$tmpdir"
    exit 1
  fi
  printf '%s\n' "$output"

  total_rx_delta=0
  total_tx_delta=0
  while read -r pod; do
    [ -n "$pod" ] || continue
    rx_before="$(cat "${tmpdir}/${pod}.rx_before")"
    tx_before="$(cat "${tmpdir}/${pod}.tx_before")"
    rx_after="$(read_pod_counter "$pod" rx_bytes)"
    tx_after="$(read_pod_counter "$pod" tx_bytes)"
    rx_delta="$((rx_after - rx_before))"
    tx_delta="$((tx_after - tx_before))"
    total_rx_delta="$((total_rx_delta + rx_delta))"
    total_tx_delta="$((total_tx_delta + tx_delta))"
    echo "ib_counter_delta pod=${pod} iface=${IB_IFACE} rx_bytes_delta=${rx_delta} tx_bytes_delta=${tx_delta}"
  done <<<"$pods"
  rm -rf "$tmpdir"

  if ! printf '%s\n' "$output" | grep -q 'allreduce_sum='; then
    echo "MPI output does not contain allreduce proof" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -q 'aggregate_bandwidth_mib_s='; then
    echo "MPI output does not contain bandwidth proof" >&2
    exit 1
  fi
  if [ "$total_rx_delta" -le 0 ] || [ "$total_tx_delta" -le 0 ]; then
    echo "IB counters did not increase during MPI run: total_rx_delta=${total_rx_delta} total_tx_delta=${total_tx_delta}" >&2
    exit 1
  fi
  echo "ib_counter_delta_total iface=${IB_IFACE} rx_bytes_delta=${total_rx_delta} tx_bytes_delta=${total_tx_delta}"
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
  ip -br addr
  cat /tmp/mpi-hostfile
  ssh -p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no root@${IB_IPV4_PREFIX}.102 true

Manual MPI from the launcher:
  mpirun --allow-run-as-root --hostfile /tmp/mpi-hostfile -np ${NUM_NODES} --mca btl_tcp_if_include ${IB_IFACE} --mca oob_tcp_if_include ${IB_IFACE} --mca plm_rsh_args "-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10" -x MPI_TRAFFIC_BYTES -x MPI_TRAFFIC_ITERS /usr/bin/python3 /tmp/mpi_ib_smoke.py
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
  log "Deleting TrainJob JobSet DRANET IB workload from context: $("$KUBECTL" config current-context)"
  "$KUBECTL" -n "$NAMESPACE" delete trainjob "$TRAINJOB" --ignore-not-found --wait=false
  "$KUBECTL" -n "$NAMESPACE" delete jobset "$TRAINJOB" --ignore-not-found --wait=false
  "$KUBECTL" -n "$NAMESPACE" delete pods -l "$(pod_selector)" --ignore-not-found --wait=false
  "$KUBECTL" -n "$NAMESPACE" wait --for=delete pods -l "$(pod_selector)" --timeout="$WAIT_TIMEOUT" || true
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
