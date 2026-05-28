#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAINJOB_SCRIPT="${ROOT_DIR}/hack/trainjob-dranet-ib-test.sh"
SELF_PATH="${ROOT_DIR}/hack/record-mpi-dranet-ib-demo.sh"
TRAINJOB_SCRIPT_REL="./hack/trainjob-dranet-ib-test.sh"

KUBECTL="${KUBECTL:-kubectl}"
ASCIINEMA="${ASCIINEMA:-asciinema}"
AGG="${AGG:-agg}"

NAMESPACE="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NAMESPACE:-slurm-bridge}"
TRAINJOB="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NAME:-mpi-dranet-ib}"
DEVICE_CLASS="${SLURM_BRIDGE_TRAINJOB_IB_TEST_DEVICE_CLASS:-dranet-ib}"
NUM_NODES="${SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES:-2}"

WAIT_SECONDS="${SLURM_BRIDGE_MPI_DEMO_WAIT_SECONDS:-600}"
STEP_PAUSE_SECONDS="${SLURM_BRIDGE_MPI_DEMO_STEP_PAUSE_SECONDS:-1}"
OUTPUT_DIR="${SLURM_BRIDGE_MPI_DEMO_OUTPUT_DIR:-${ROOT_DIR}/demo-recordings}"
CAST_PATH="${SLURM_BRIDGE_MPI_DEMO_CAST_PATH:-}"
GIF_PATH="${SLURM_BRIDGE_MPI_DEMO_GIF_PATH:-}"
WINDOW_SIZE="${SLURM_BRIDGE_MPI_DEMO_WINDOW_SIZE:-132x40}"
IDLE_TIME_LIMIT="${SLURM_BRIDGE_MPI_DEMO_IDLE_TIME_LIMIT:-2}"

function usage() {
  cat <<EOF
usage: $(basename "$0") [record|demo]

Subcommands:
  record   Record the terminal demo with asciinema, and render a GIF with agg if available.
  demo     Run the visible demo flow without recording.

Environment overrides:
  KUBECONFIG=${KUBECONFIG:-}
  KUBECTL=$KUBECTL
  ASCIINEMA=$ASCIINEMA
  AGG=$AGG
  SLURM_BRIDGE_MPI_DEMO_OUTPUT_DIR=$OUTPUT_DIR
  SLURM_BRIDGE_MPI_DEMO_CAST_PATH=$CAST_PATH
  SLURM_BRIDGE_MPI_DEMO_GIF_PATH=$GIF_PATH
  SLURM_BRIDGE_MPI_DEMO_WINDOW_SIZE=$WINDOW_SIZE
  SLURM_BRIDGE_MPI_DEMO_IDLE_TIME_LIMIT=$IDLE_TIME_LIMIT
  SLURM_BRIDGE_MPI_DEMO_WAIT_SECONDS=$WAIT_SECONDS
  SLURM_BRIDGE_MPI_DEMO_STEP_PAUSE_SECONDS=$STEP_PAUSE_SECONDS
  SLURM_BRIDGE_TRAINJOB_IB_TEST_NAMESPACE=$NAMESPACE
  SLURM_BRIDGE_TRAINJOB_IB_TEST_NAME=$TRAINJOB
  SLURM_BRIDGE_TRAINJOB_IB_TEST_DEVICE_CLASS=$DEVICE_CLASS
  SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES=$NUM_NODES

Run dependency setup outside the recording when needed:
  KUBECONFIG=... ${TRAINJOB_SCRIPT_REL} install
EOF
}

function require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command not found: ${cmd}" >&2
    exit 1
  fi
}

function pause() {
  sleep "$STEP_PAUSE_SECONDS"
}

function title() {
  printf '\n# %s\n' "$*"
  pause
}

function note() {
  printf '%s\n' "$*"
  pause
}

function prompt() {
  printf '\n$ %s\n' "$*"
  pause
}

function run_cmd() {
  local description="$1"
  local command="$2"
  title "$description"
  prompt "$command"
  bash -o pipefail -c "$command"
  pause
}

function capture_cmd() {
  local __var="$1"
  local description="$2"
  local command="$3"
  local value
  title "$description"
  prompt "$command"
  value="$(bash -o pipefail -c "$command")"
  printf -v "$__var" '%s' "$value"
  printf '%s=%s\n' "$__var" "$value"
  pause
}

function wait_until() {
  local description="$1"
  local shown_command="$2"
  local check_command="$3"
  local deadline
  title "$description"
  prompt "$shown_command"
  deadline="$(($(date +%s) + WAIT_SECONDS))"
  until bash -o pipefail -c "$check_command"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timed out waiting for: ${shown_command}" >&2
      exit 1
    fi
    sleep 2
  done
  bash -o pipefail -c "$shown_command"
  pause
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

function ensure_no_existing_workload() {
  if "$KUBECTL" -n "$NAMESPACE" get trainjob "$TRAINJOB" >/dev/null 2>&1; then
    cat >&2 <<EOF
${NAMESPACE}/${TRAINJOB} already exists.
Run this before recording if you want the demo to show a fresh TrainJob creation:
  KUBECONFIG=${KUBECONFIG:-} ${TRAINJOB_SCRIPT_REL} cleanup
EOF
    exit 1
  fi
}

function wait_for_pod_count() {
  local selector="$1"
  local expected="$2"
  local deadline count
  title "Wait for JobSet pods to exist"
  prompt "until [ \"\$(${KUBECTL} get pods -n ${NAMESPACE} -l '${selector}' --no-headers | wc -l)\" -ge ${expected} ]; do sleep 2; done"
  deadline="$(($(date +%s) + WAIT_SECONDS))"
  while true; do
    count="$("$KUBECTL" -n "$NAMESPACE" get pods -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -ge "$expected" ]; then
      echo "pods=${count}"
      pause
      return
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timed out waiting for ${expected} pods matching ${selector}; saw ${count}" >&2
      exit 1
    fi
    sleep 2
  done
}

function run_mpi() {
  local launcher="$1"
  local mpi_cmd
  mpi_cmd='set -euo pipefail
export PYTHONPATH="/home/mpiuser/.local/lib/python3.10/site-packages:${PYTHONPATH:-}"
mpirun --allow-run-as-root --hostfile /tmp/mpi-hostfile -np '"${NUM_NODES}"' --mca pml ucx --mca osc ucx --mca plm_rsh_args "-p 2222 -i /tmp/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectionAttempts=10" -x UCX_TLS -x UCX_LOG_LEVEL -x PYTHONPATH -x MPI_TRAFFIC_BYTES -x MPI_TRAFFIC_ITERS /usr/bin/python3 /tmp/mpi_ib_smoke.py'

  title "Run MPI traffic over UCX/RDMA"
  prompt "${KUBECTL} -n ${NAMESPACE} exec ${launcher} -- /bin/bash -lc 'mpirun --mca pml ucx --mca osc ucx ...'"
  "$KUBECTL" -n "$NAMESPACE" exec "$launcher" -- /bin/bash -lc "$mpi_cmd"
  pause
}

function run_demo() {
  local selector launcher worker jobid

  require_command "$KUBECTL"
  require_command jq
  ensure_numeric SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES "$NUM_NODES"
  ensure_numeric SLURM_BRIDGE_MPI_DEMO_WAIT_SECONDS "$WAIT_SECONDS"
  ensure_numeric SLURM_BRIDGE_MPI_DEMO_STEP_PAUSE_SECONDS "$STEP_PAUSE_SECONDS"
  if [ "$NUM_NODES" -ne 2 ]; then
    echo "this recorded demo expects exactly two nodes; got SLURM_BRIDGE_TRAINJOB_IB_TEST_NUM_NODES=${NUM_NODES}" >&2
    exit 2
  fi
  ensure_no_existing_workload
  cd "$ROOT_DIR"

  selector="app.kubernetes.io/name=trainjob-dranet-ib-test,app.kubernetes.io/instance=${TRAINJOB}"

  title "MPI over DRANET InfiniBand with Slinky slurm-bridge"
  note "This demo uses Kubeflow Trainer, a Trainer-created PodGroup, JobSet pods, DRANET DRA claims, and a Slurm allocation with DRANET represented as GRES."

  run_cmd "Kubernetes context" \
    "${KUBECTL} config current-context"

  run_cmd "DRANET advertises an InfiniBand DeviceClass through DRA" \
    "${KUBECTL} get deviceclass ${DEVICE_CLASS} -o json | jq '{name:.metadata.name, spec:.spec}'"

  run_cmd "DRANET ResourceSlices advertise RDMA-capable devices" \
    "${KUBECTL} get resourceslices -A -o json | jq '[.items[] | select(.spec.driver==\"dra.net\") | {node:.spec.nodeName, rdmaDevices:[.spec.devices[] | select(.attributes[\"dra.net/rdma\"].bool == true) | {name:.name, ifName:(.attributes[\"dra.net/ifName\"].string // null), encapsulation:(.attributes[\"dra.net/encapsulation\"].string // null), pci:(.attributes[\"dra.net/pciAddress\"].string // null)}]} | select(.rdmaDevices | length > 0)]'"

  run_cmd "Create the Kubeflow TrainJob" \
    "${TRAINJOB_SCRIPT_REL} manifest | ${KUBECTL} apply -f -"

  run_cmd "TrainJob exists" \
    "${KUBECTL} get trainjob -n ${NAMESPACE} ${TRAINJOB} -o wide"

  wait_until "Wait for Trainer-created PodGroup and JobSet" \
    "${KUBECTL} get podgroup,jobset -n ${NAMESPACE} ${TRAINJOB}" \
    "${KUBECTL} get podgroup -n ${NAMESPACE} ${TRAINJOB} >/dev/null 2>&1 && ${KUBECTL} get jobset -n ${NAMESPACE} ${TRAINJOB} >/dev/null 2>&1"

  run_cmd "Trainer-created PodGroup" \
    "${KUBECTL} get podgroup -n ${NAMESPACE} ${TRAINJOB} -o json | jq '{name:.metadata.name, owner:(.metadata.ownerReferences[0].kind + \"/\" + .metadata.ownerReferences[0].name), minMember:.spec.minMember, minResources:.spec.minResources, phase:.status.phase}'"

  run_cmd "Trainer-created JobSet" \
    "${KUBECTL} get jobset -n ${NAMESPACE} ${TRAINJOB} -o wide"

  wait_for_pod_count "scheduling.x-k8s.io/pod-group=${TRAINJOB}" "$NUM_NODES"

  run_cmd "JobSet-created pods are labeled into the PodGroup" \
    "${KUBECTL} get pods -n ${NAMESPACE} -l scheduling.x-k8s.io/pod-group=${TRAINJOB} -o json | jq '.items[] | {pod:.metadata.name, component:.metadata.labels[\"app.kubernetes.io/component\"], jobset:.metadata.labels[\"jobset.sigs.k8s.io/jobset-name\"], podGroup:.metadata.labels[\"scheduling.x-k8s.io/pod-group\"], slurmJobID:.metadata.labels[\"scheduler.slinky.slurm.net/slurm-jobid\"], node:.spec.nodeName, podIP:.status.podIP}'"

  run_cmd "Wait for held launcher and worker pods to become Ready" \
    "${KUBECTL} wait --for=condition=Ready pod -n ${NAMESPACE} -l scheduling.x-k8s.io/pod-group=${TRAINJOB} --timeout=${WAIT_SECONDS}s"

  run_cmd "DRA ResourceClaims are allocated for DRANET IB" \
    "${KUBECTL} get resourceclaims -n ${NAMESPACE} -o wide"

  run_cmd "DRA allocation details for DRANET IB" \
    "${KUBECTL} get resourceclaims -n ${NAMESPACE} -o json | jq '.items[] | (.spec.devices.requests[] | select(.exactly.deviceClassName==\"${DEVICE_CLASS}\")) as \$request | {claim:.metadata.name, deviceClass:\$request.exactly.deviceClassName, selector:(\$request.exactly.selectors[0].cel.expression // null), allocation:[.status.allocation.devices.results[] | select(.request==\$request.name)]}'"

  run_cmd "slurm-bridge scheduling metadata on the pods" \
    "${KUBECTL} get pods -n ${NAMESPACE} -l scheduling.x-k8s.io/pod-group=${TRAINJOB} -o json | jq '.items[] | {pod:.metadata.name, scheduler:.spec.schedulerName, node:.spec.nodeName, podGroup:.metadata.labels[\"scheduling.x-k8s.io/pod-group\"], slurmJobID:.metadata.labels[\"scheduler.slinky.slurm.net/slurm-jobid\"]}'"

  capture_cmd launcher "Select launcher pod" \
    "${KUBECTL} get pod -n ${NAMESPACE} -l '${selector},app.kubernetes.io/component=launcher' -o jsonpath='{.items[0].metadata.name}'"

  capture_cmd worker "Select worker pod" \
    "${KUBECTL} get pod -n ${NAMESPACE} -l '${selector},app.kubernetes.io/component=worker' -o jsonpath='{.items[0].metadata.name}'"

  capture_cmd jobid "Select Slurm job ID from pod labels" \
    "${KUBECTL} get pods -n ${NAMESPACE} -l scheduling.x-k8s.io/pod-group=${TRAINJOB} -o json | jq -r '.items[0].metadata.labels[\"scheduler.slinky.slurm.net/slurm-jobid\"]'"

  run_cmd "Slurm sees one allocation with DRANET represented as GRES" \
    "${KUBECTL} exec -n slurm slurm-controller-0 -c slurmctld -- squeue -o '%.18i %.9T %.30R %.4D %.30b'"

  run_cmd "Slurm job details include nodes and TRES/GRES" \
    "${KUBECTL} exec -n slurm slurm-controller-0 -c slurmctld -- /bin/bash -lc 'scontrol show job ${jobid} | grep -E \"JobId=|NodeList=|NumNodes=|TresPerNode|TRES\"'"

  run_cmd "Visible RDMA ports inside launcher" \
    "${KUBECTL} exec -n ${NAMESPACE} ${launcher} -- /bin/bash -lc 'for d in /sys/class/infiniband/*; do [ -e \"\$d\" ] || continue; dev=\$(basename \"\$d\"); for p in \"\$d\"/ports/*; do [ -e \"\$p\" ] || continue; printf \"%s:%s state=%s link_layer=%s rate=%s\n\" \"\$dev\" \"\$(basename \"\$p\")\" \"\$(cat \"\$p/state\" 2>/dev/null || true)\" \"\$(cat \"\$p/link_layer\" 2>/dev/null || true)\" \"\$(cat \"\$p/rate\" 2>/dev/null || true)\"; done; done'"

  run_cmd "Open MPI hostfile from Trainer" \
    "${KUBECTL} exec -n ${NAMESPACE} ${launcher} -- cat /tmp/mpi-hostfile"

  run_mpi "$launcher"

  run_cmd "Demo workload is left running for inspection" \
    "${KUBECTL} get pods,podgroup,jobset,trainjob -n ${NAMESPACE} -o wide"

  note "No cleanup was run. Use ${TRAINJOB_SCRIPT_REL} cleanup when you are finished inspecting the demo workload."
}

function record_demo() {
  local timestamp command gif
  require_command "$ASCIINEMA"
  mkdir -p "$OUTPUT_DIR"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  if [ -z "$CAST_PATH" ]; then
    CAST_PATH="${OUTPUT_DIR}/mpi-dranet-ib-${timestamp}.cast"
  fi

  command="cd $(printf '%q' "$ROOT_DIR") && $(printf '%q' "$SELF_PATH") demo"
  "$ASCIINEMA" record \
    --window-size "$WINDOW_SIZE" \
    --idle-time-limit "$IDLE_TIME_LIMIT" \
    --return \
    -c "$command" \
    "$CAST_PATH"
  echo "asciinema recording: ${CAST_PATH}"

  if command -v "$AGG" >/dev/null 2>&1; then
    if [ -z "$GIF_PATH" ]; then
      gif="${CAST_PATH%.cast}.gif"
    else
      gif="$GIF_PATH"
    fi
    "$AGG" "$CAST_PATH" "$gif"
    echo "gif rendering: ${gif}"
  else
    echo "agg not found; skipped GIF rendering"
  fi
}

case "${1:-record}" in
record)
  record_demo
  ;;
demo)
  run_demo
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 2
  ;;
esac
