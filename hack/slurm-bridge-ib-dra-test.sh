#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MANIFEST="${SLURM_BRIDGE_IB_DRA_TEST_MANIFEST:-${REPO_ROOT}/hack/examples/ib/podgroup-dra.yaml}"
NAMESPACE="${SLURM_BRIDGE_IB_DRA_TEST_NAMESPACE:-slurm-bridge}"
PODGROUP="${SLURM_BRIDGE_IB_DRA_TEST_PODGROUP:-ib-dra}"
POD_A="${SLURM_BRIDGE_IB_DRA_TEST_POD_A:-ib-dra-a}"
POD_B="${SLURM_BRIDGE_IB_DRA_TEST_POD_B:-ib-dra-b}"
DEVICE_CLASS="${SLURM_BRIDGE_IB_DRA_TEST_DEVICE_CLASS:-dranet-ib}"

IB_IFACE="${SLURM_BRIDGE_IB_DRA_TEST_IFACE:-ib0}"
IP_A="${SLURM_BRIDGE_IB_DRA_TEST_IP_A:-10.200.2.101/24}"
IP_B="${SLURM_BRIDGE_IB_DRA_TEST_IP_B:-10.200.2.102/24}"
RDMA_DEVICE="${SLURM_BRIDGE_IB_DRA_TEST_RDMA_DEVICE:-}"

WAIT_TIMEOUT="${SLURM_BRIDGE_IB_DRA_TEST_WAIT_TIMEOUT:-300s}"
BW_DURATION="${SLURM_BRIDGE_IB_DRA_TEST_BW_DURATION:-10}"
BW_QPS="${SLURM_BRIDGE_IB_DRA_TEST_BW_QPS:-4}"
RUN_BW="${SLURM_BRIDGE_IB_DRA_TEST_RUN_BW:-true}"
BIND_SOURCE_IP="${SLURM_BRIDGE_IB_DRA_TEST_BIND_SOURCE_IP:-auto}"

function log() {
	echo "[slurm-bridge-ib-dra-test] $*"
}

function usage() {
	cat <<EOF
usage: $(basename "$0") [run|apply|test|status|cleanup|manifest]

Environment overrides:
  KUBECTL=$KUBECTL
  SLURM_BRIDGE_IB_DRA_TEST_MANIFEST=$MANIFEST
  SLURM_BRIDGE_IB_DRA_TEST_NAMESPACE=$NAMESPACE
  SLURM_BRIDGE_IB_DRA_TEST_PODGROUP=$PODGROUP
  SLURM_BRIDGE_IB_DRA_TEST_POD_A=$POD_A
  SLURM_BRIDGE_IB_DRA_TEST_POD_B=$POD_B
  SLURM_BRIDGE_IB_DRA_TEST_DEVICE_CLASS=$DEVICE_CLASS
  SLURM_BRIDGE_IB_DRA_TEST_IFACE=$IB_IFACE
  SLURM_BRIDGE_IB_DRA_TEST_IP_A=$IP_A
  SLURM_BRIDGE_IB_DRA_TEST_IP_B=$IP_B
  SLURM_BRIDGE_IB_DRA_TEST_RDMA_DEVICE=$RDMA_DEVICE
  SLURM_BRIDGE_IB_DRA_TEST_RUN_BW=$RUN_BW
  SLURM_BRIDGE_IB_DRA_TEST_BW_QPS=$BW_QPS
  SLURM_BRIDGE_IB_DRA_TEST_BIND_SOURCE_IP=$BIND_SOURCE_IP
EOF
}

function ip_without_prefix() {
	local ip="$1"
	printf '%s\n' "${ip%%/*}"
}

function ensure_numeric() {
	local name="$1"
	local value="$2"

	case "$value" in
	"" | *[!0-9]*)
		echo "${name} must be an integer, got: ${value}" >&2
		exit 2
		;;
	esac
}

function apply_manifest() {
	log "Applying PodGroup DRA IB workload to context: $("$KUBECTL" config current-context)"
	"$KUBECTL" apply -f "$MANIFEST"
}

function reset_workload() {
	if ! "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
		return
	fi

	log "Removing previous ${PODGROUP} pods and PodGroup"
	"$KUBECTL" -n "$NAMESPACE" delete pod "$POD_A" "$POD_B" --ignore-not-found --wait=false
	"$KUBECTL" -n "$NAMESPACE" delete podgroup "$PODGROUP" --ignore-not-found
}

function wait_for_pods() {
	log "Waiting for ${POD_A} and ${POD_B} to become Ready"
	if "$KUBECTL" -n "$NAMESPACE" wait \
		--for=condition=Ready \
		"pod/${POD_A}" "pod/${POD_B}" \
		--timeout="$WAIT_TIMEOUT"; then
		return
	fi

	log "Pods did not become Ready; current state follows"
	show_status >&2 || true
	"$KUBECTL" -n "$NAMESPACE" get events --sort-by=.lastTimestamp >&2 || true
	exit 1
}

function exec_in_pod() {
	local pod="$1"
	shift
	"$KUBECTL" -n "$NAMESPACE" exec "$pod" -- "$@"
}

function configure_pod_ipoib() {
	log "Configuring ${POD_A} interface ${IB_IFACE} with ${IP_A}"
	exec_in_pod "$POD_A" sh -c \
		"ip link show '${IB_IFACE}' && ip link set '${IB_IFACE}' up && ip addr replace '${IP_A}' dev '${IB_IFACE}' && ip -br addr show '${IB_IFACE}'"

	log "Configuring ${POD_B} interface ${IB_IFACE} with ${IP_B}"
	exec_in_pod "$POD_B" sh -c \
		"ip link show '${IB_IFACE}' && ip link set '${IB_IFACE}' up && ip addr replace '${IP_B}' dev '${IB_IFACE}' && ip -br addr show '${IB_IFACE}'"
}

function rdma_device_arg() {
	if [ -n "$RDMA_DEVICE" ]; then
		printf ' -d %s' "$RDMA_DEVICE"
	fi
}

function check_ib_state() {
	log "Checking RDMA devices from ${POD_A}"
	if [ -n "$RDMA_DEVICE" ]; then
		exec_in_pod "$POD_A" sh -c "ibstat '${RDMA_DEVICE}'; ibv_devinfo -d '${RDMA_DEVICE}'"
	else
		exec_in_pod "$POD_A" sh -c "ibstat; ibv_devinfo"
	fi

	log "Checking RDMA devices from ${POD_B}"
	if [ -n "$RDMA_DEVICE" ]; then
		exec_in_pod "$POD_B" sh -c "ibstat '${RDMA_DEVICE}'; ibv_devinfo -d '${RDMA_DEVICE}'"
	else
		exec_in_pod "$POD_B" sh -c "ibstat; ibv_devinfo"
	fi
}

function supports_bind_source_ip() {
	local pod="$1"
	exec_in_pod "$pod" sh -c "ib_write_bw --help 2>&1 | grep -q -- '--bind_source_ip'" >/dev/null 2>&1
}

function bind_source_ip_arg() {
	local pod="$1"
	local addr="$2"

	case "$BIND_SOURCE_IP" in
	false | 0)
		return
		;;
	true | 1)
		printf ' --bind_source_ip %s' "$addr"
		return
		;;
	auto)
		if supports_bind_source_ip "$pod"; then
			printf ' --bind_source_ip %s' "$addr"
		fi
		return
		;;
	*)
		echo "SLURM_BRIDGE_IB_DRA_TEST_BIND_SOURCE_IP must be auto, true, or false, got: $BIND_SOURCE_IP" >&2
		exit 2
		;;
	esac
}

function run_smoke_tests() {
	local addr_a addr_b
	addr_a="$(ip_without_prefix "$IP_A")"
	addr_b="$(ip_without_prefix "$IP_B")"

	configure_pod_ipoib
	check_ib_state

	log "Checking route from ${POD_A} to ${addr_b}"
	exec_in_pod "$POD_A" ip route get "$addr_b"

	log "Checking IPoIB connectivity from ${POD_A} to ${addr_b} over ${IB_IFACE}"
	exec_in_pod "$POD_A" ping -I "$IB_IFACE" -c 3 "$addr_b"

	if [ "$RUN_BW" = "false" ] || [ "$RUN_BW" = "0" ]; then
		log "Skipping ib_write_bw because SLURM_BRIDGE_IB_DRA_TEST_RUN_BW=${RUN_BW}"
		return
	fi

	run_bandwidth_test "$addr_a" "$addr_b"
}

function run_bandwidth_test() {
	local addr_a="$1"
	local addr_b="$2"
	local server_timeout server_pid client_rc server_rc server_bind client_bind device_arg

	ensure_numeric SLURM_BRIDGE_IB_DRA_TEST_BW_DURATION "$BW_DURATION"
	ensure_numeric SLURM_BRIDGE_IB_DRA_TEST_BW_QPS "$BW_QPS"
	server_timeout=$((BW_DURATION + 30))
	server_bind="$(bind_source_ip_arg "$POD_A" "$addr_a")"
	client_bind="$(bind_source_ip_arg "$POD_B" "$addr_b")"
	device_arg="$(rdma_device_arg)"

	log "Starting ib_write_bw server in ${POD_A} with ${BW_QPS} QPs"
	"$KUBECTL" -n "$NAMESPACE" exec "$POD_A" -- sh -c \
		"rm -f /tmp/ib-write-bw.log; timeout ${server_timeout}s ib_write_bw -F -R --report_gbits -D ${BW_DURATION} -q ${BW_QPS}${device_arg}${server_bind} >/tmp/ib-write-bw.log 2>&1" &
	server_pid=$!

	sleep 3

	log "Running ib_write_bw client from ${POD_B} to ${addr_a} with ${BW_QPS} QPs"
	set +e
	"$KUBECTL" -n "$NAMESPACE" exec "$POD_B" -- sh -c \
		"ib_write_bw -F -R --report_gbits -D ${BW_DURATION} -q ${BW_QPS}${device_arg}${client_bind} '${addr_a}'"
	client_rc=$?
	wait "$server_pid"
	server_rc=$?
	set -e

	log "ib_write_bw server output from ${POD_A}"
	exec_in_pod "$POD_A" sh -c "cat /tmp/ib-write-bw.log || true"

	if [ "$client_rc" -ne 0 ]; then
		echo "ib_write_bw client failed with exit code ${client_rc}" >&2
		exit "$client_rc"
	fi
	if [ "$server_rc" -ne 0 ]; then
		echo "ib_write_bw server failed with exit code ${server_rc}" >&2
		exit "$server_rc"
	fi
}

function show_status() {
	"$KUBECTL" -n "$NAMESPACE" get podgroup "$PODGROUP" -o wide
	"$KUBECTL" -n "$NAMESPACE" get pods \
		-l "app.kubernetes.io/name=slurm-bridge-ib-dra-test,app.kubernetes.io/instance=${PODGROUP}" \
		-o wide --show-labels
	"$KUBECTL" -n "$NAMESPACE" get resourceclaims -o wide || true
	"$KUBECTL" get deviceclass "$DEVICE_CLASS" -o wide || true
}

function cleanup() {
	log "Removing test IP addresses from ${IB_IFACE} where pods are still running"
	exec_in_pod "$POD_A" sh -c "ip addr del '${IP_A}' dev '${IB_IFACE}' 2>/dev/null || true" >/dev/null 2>&1 || true
	exec_in_pod "$POD_B" sh -c "ip addr del '${IP_B}' dev '${IB_IFACE}' 2>/dev/null || true" >/dev/null 2>&1 || true

	reset_workload
}

case "${1:-run}" in
run)
	reset_workload
	apply_manifest
	wait_for_pods
	run_smoke_tests
	;;
apply)
	apply_manifest
	;;
test)
	wait_for_pods
	run_smoke_tests
	;;
status)
	show_status
	;;
manifest)
	cat "$MANIFEST"
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
