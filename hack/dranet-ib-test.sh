#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

NAMESPACE="${DRANET_IB_TEST_NAMESPACE:-ib-test}"
DEVICE_CLASS="${DRANET_IB_TEST_DEVICE_CLASS:-dranet-ib}"
IMAGE="${DRANET_IB_TEST_IMAGE:-public.ecr.aws/docker/library/ubuntu:24.04}"
INSTALL_TOOLS="${DRANET_IB_TEST_INSTALL_TOOLS:-true}"
TOOL_PACKAGES="${DRANET_IB_TEST_TOOL_PACKAGES:-iproute2 iputils-ping ibverbs-utils rdma-core perftest coreutils}"
TOOLS_WAIT_SECONDS="${DRANET_IB_TEST_TOOLS_WAIT_SECONDS:-300}"

POD_A="${DRANET_IB_TEST_POD_A:-ib-a}"
POD_B="${DRANET_IB_TEST_POD_B:-ib-b}"
CLAIM_A="${DRANET_IB_TEST_CLAIM_A:-ib-a}"
CLAIM_B="${DRANET_IB_TEST_CLAIM_B:-ib-b}"

HOST_IFACE="${DRANET_IB_TEST_HOST_IFACE:-ib0}"
POD_IFACE="${DRANET_IB_TEST_POD_IFACE:-ib0}"
IP_A="${DRANET_IB_TEST_IP_A:-10.200.0.101/24}"
IP_B="${DRANET_IB_TEST_IP_B:-10.200.0.102/24}"
MTU="${DRANET_IB_TEST_MTU:-4092}"

TAINT_KEY="${DRANET_IB_TEST_TAINT_KEY:-slinky.slurm.net/managed-node}"
TAINT_VALUE="${DRANET_IB_TEST_TAINT_VALUE:-slurm-bridge-scheduler}"
WAIT_TIMEOUT="${DRANET_IB_TEST_WAIT_TIMEOUT:-180s}"
BW_DURATION="${DRANET_IB_TEST_BW_DURATION:-10}"
BW_QPS="${DRANET_IB_TEST_BW_QPS:-4}"
RUN_BW="${DRANET_IB_TEST_RUN_BW:-true}"

function log() {
	echo "[dranet-ib-test] $*"
}

function usage() {
	cat <<EOF
usage: $(basename "$0") [run|apply|test|status|manifest|cleanup]

Environment overrides:
  KUBECTL=$KUBECTL
  DRANET_IB_TEST_NAMESPACE=$NAMESPACE
  DRANET_IB_TEST_IMAGE=$IMAGE
  DRANET_IB_TEST_INSTALL_TOOLS=$INSTALL_TOOLS
  DRANET_IB_TEST_HOST_IFACE=$HOST_IFACE
  DRANET_IB_TEST_POD_IFACE=$POD_IFACE
  DRANET_IB_TEST_IP_A=$IP_A
  DRANET_IB_TEST_IP_B=$IP_B
  DRANET_IB_TEST_RUN_BW=$RUN_BW
  DRANET_IB_TEST_BW_QPS=$BW_QPS
EOF
}

function ip_without_prefix() {
	local ip="$1"
	printf '%s\n' "${ip%%/*}"
}

function ensure_numeric_duration() {
	case "$BW_DURATION" in
	"" | *[!0-9]*)
		echo "DRANET_IB_TEST_BW_DURATION must be an integer number of seconds, got: $BW_DURATION" >&2
		exit 2
		;;
	esac
}

function ensure_numeric_tools_wait() {
	case "$TOOLS_WAIT_SECONDS" in
	"" | *[!0-9]*)
		echo "DRANET_IB_TEST_TOOLS_WAIT_SECONDS must be an integer number of seconds, got: $TOOLS_WAIT_SECONDS" >&2
		exit 2
		;;
	esac
}

function ensure_numeric_bw_qps() {
	case "$BW_QPS" in
	"" | *[!0-9]*)
		echo "DRANET_IB_TEST_BW_QPS must be an integer number of QPs, got: $BW_QPS" >&2
		exit 2
		;;
	esac
}

function render_container_command() {
	if [ "$INSTALL_TOOLS" = "false" ] || [ "$INSTALL_TOOLS" = "0" ]; then
		cat <<EOF
    command: ["sleep", "infinity"]
EOF
		return
	fi

	cat <<EOF
    command:
    - sh
    - -c
    - |
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ${TOOL_PACKAGES}
      touch /tmp/rdma-tools-ready
      sleep infinity
EOF
}

function render_manifest() {
	cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: ${DEVICE_CLASS}
spec:
  selectors:
  - cel:
      expression: 'device.driver == "dra.net" && device.attributes["dra.net"].rdma == true && device.attributes["dra.net"].encapsulation == "infiniband"'
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: ${CLAIM_A}
  namespace: ${NAMESPACE}
spec:
  devices:
    requests:
    - name: ib
      exactly:
        deviceClassName: ${DEVICE_CLASS}
        allocationMode: ExactCount
        count: 1
        selectors:
        - cel:
            expression: 'device.attributes["dra.net"].ifName == "${HOST_IFACE}"'
    config:
    - requests: ["ib"]
      opaque:
        driver: dra.net
        parameters:
          interface:
            name: ${POD_IFACE}
            addresses:
            - ${IP_A}
            mtu: ${MTU}
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: ${CLAIM_B}
  namespace: ${NAMESPACE}
spec:
  devices:
    requests:
    - name: ib
      exactly:
        deviceClassName: ${DEVICE_CLASS}
        allocationMode: ExactCount
        count: 1
        selectors:
        - cel:
            expression: 'device.attributes["dra.net"].ifName == "${HOST_IFACE}"'
    config:
    - requests: ["ib"]
      opaque:
        driver: dra.net
        parameters:
          interface:
            name: ${POD_IFACE}
            addresses:
            - ${IP_B}
            mtu: ${MTU}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_A}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: dranet-ib-test
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: dranet-ib-test
        topologyKey: kubernetes.io/hostname
  tolerations:
  - operator: Exists
    effect: NoSchedule
  - key: ${TAINT_KEY}
    operator: Equal
    value: ${TAINT_VALUE}
    effect: NoExecute
  containers:
  - name: rdma
    image: ${IMAGE}
    imagePullPolicy: IfNotPresent
$(render_container_command)
    resources:
      claims:
      - name: ib
  resourceClaims:
  - name: ib
    resourceClaimName: ${CLAIM_A}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_B}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: dranet-ib-test
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: dranet-ib-test
        topologyKey: kubernetes.io/hostname
  tolerations:
  - operator: Exists
    effect: NoSchedule
  - key: ${TAINT_KEY}
    operator: Equal
    value: ${TAINT_VALUE}
    effect: NoExecute
  containers:
  - name: rdma
    image: ${IMAGE}
    imagePullPolicy: IfNotPresent
$(render_container_command)
    resources:
      claims:
      - name: ib
  resourceClaims:
  - name: ib
    resourceClaimName: ${CLAIM_B}
EOF
}

function apply_manifest() {
	local tmpdir
	tmpdir="$(mktemp -d)"

	render_manifest >"${tmpdir}/dranet-ib-test.yaml"
	log "Applying IB test workload to context: $("$KUBECTL" config current-context)"
	"$KUBECTL" apply -f "${tmpdir}/dranet-ib-test.yaml"
	rm -rf "$tmpdir"
}

function wait_for_pods() {
	log "Waiting for ${POD_A} and ${POD_B} to become Ready"
	"$KUBECTL" -n "$NAMESPACE" wait \
		--for=condition=Ready \
		"pod/${POD_A}" "pod/${POD_B}" \
		--timeout="$WAIT_TIMEOUT"
}

function exec_in_pod() {
	local pod="$1"
	shift
	"$KUBECTL" -n "$NAMESPACE" exec "$pod" -- "$@"
}

function has_tool() {
	local pod="$1"
	local tool="$2"
	exec_in_pod "$pod" sh -c "command -v '$tool' >/dev/null 2>&1" >/dev/null 2>&1
}

function check_test_image() {
	local deadline missing tool

	ensure_numeric_tools_wait
	deadline=$(($(date +%s) + TOOLS_WAIT_SECONDS))
	log "Waiting for RDMA test tools in ${POD_A}"

	while true; do
		missing=()
		for tool in ip ping ibv_devinfo ib_write_bw timeout; do
			if ! has_tool "$POD_A" "$tool"; then
				missing+=("$tool")
			fi
		done

		if [ "${#missing[@]}" -eq 0 ]; then
			return
		fi

		if [ "$(date +%s)" -ge "$deadline" ]; then
			echo "required tools were not found in image '$IMAGE': ${missing[*]}" >&2
			echo "set DRANET_IB_TEST_IMAGE to an image containing iproute2, iputils-ping, rdma-core/ibverbs-utils, and perftest" >&2
			exit 1
		fi

		sleep 5
	done
}

function run_smoke_tests() {
	local addr_a addr_b
	addr_a="$(ip_without_prefix "$IP_A")"
	addr_b="$(ip_without_prefix "$IP_B")"

	check_test_image

	log "Checking ${POD_A} interface ${POD_IFACE}"
	exec_in_pod "$POD_A" ip addr show "$POD_IFACE"

	log "Checking ${POD_B} interface ${POD_IFACE}"
	exec_in_pod "$POD_B" ip addr show "$POD_IFACE"

	log "Checking RDMA devices from ${POD_A}"
	exec_in_pod "$POD_A" ibv_devinfo

	log "Checking route from ${POD_A} to ${addr_b}"
	exec_in_pod "$POD_A" ip route get "$addr_b"

	log "Checking IPoIB connectivity from ${POD_A} to ${addr_b}"
	exec_in_pod "$POD_A" ping -c 3 "$addr_b"

	if [ "$RUN_BW" = "false" ] || [ "$RUN_BW" = "0" ]; then
		log "Skipping ib_write_bw because DRANET_IB_TEST_RUN_BW=${RUN_BW}"
		return
	fi

	run_bandwidth_test "$addr_a"
}

function run_bandwidth_test() {
	local addr_a="$1"
	local server_timeout server_pid client_rc server_rc

	ensure_numeric_duration
	ensure_numeric_bw_qps
	server_timeout=$((BW_DURATION + 30))

	log "Starting ib_write_bw server in ${POD_A} with ${BW_QPS} QPs"
	"$KUBECTL" -n "$NAMESPACE" exec "$POD_A" -- sh -c \
		"rm -f /tmp/ib-write-bw.log; timeout ${server_timeout}s ib_write_bw -F -R --report_gbits -D ${BW_DURATION} -q ${BW_QPS} >/tmp/ib-write-bw.log 2>&1" &
	server_pid=$!

	sleep 3

	log "Running ib_write_bw client from ${POD_B} to ${addr_a} with ${BW_QPS} QPs"
	set +e
	"$KUBECTL" -n "$NAMESPACE" exec "$POD_B" -- sh -c \
		"ib_write_bw -F -R --report_gbits -D ${BW_DURATION} -q ${BW_QPS} ${addr_a}"
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
	"$KUBECTL" -n "$NAMESPACE" get pods,resourceclaims -o wide
	"$KUBECTL" get deviceclass "$DEVICE_CLASS" -o wide
}

function cleanup() {
	log "Deleting IB test workload from context: $("$KUBECTL" config current-context)"
	"$KUBECTL" -n "$NAMESPACE" delete pod "$POD_A" "$POD_B" --ignore-not-found --wait=false
	"$KUBECTL" -n "$NAMESPACE" delete resourceclaim "$CLAIM_A" "$CLAIM_B" --ignore-not-found --wait=false
	"$KUBECTL" delete namespace "$NAMESPACE" --ignore-not-found --wait=false
	"$KUBECTL" delete deviceclass "$DEVICE_CLASS" --ignore-not-found
}

case "${1:-run}" in
run)
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
