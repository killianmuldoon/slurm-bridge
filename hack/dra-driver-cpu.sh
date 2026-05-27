#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DRA_DRIVER_CPU_REPO="${DRA_DRIVER_CPU_REPO:-kubernetes-sigs/dra-driver-cpu}"
DRA_DRIVER_CPU_VERSION="${DRA_DRIVER_CPU_VERSION:-v0.1.0}"
DRA_DRIVER_CPU_NAMESPACE="${DRA_DRIVER_CPU_NAMESPACE:-kube-system}"
DRA_DRIVER_CPU_DEVICE_MODE="${DRA_DRIVER_CPU_DEVICE_MODE:-individual}"
DRA_DRIVER_CPU_IMAGE="${DRA_DRIVER_CPU_IMAGE:-}"
DRA_DRIVER_CPU_IMAGE_PULL_POLICY="${DRA_DRIVER_CPU_IMAGE_PULL_POLICY:-Always}"
DRA_DRIVER_CPU_LOG_LEVEL="${DRA_DRIVER_CPU_LOG_LEVEL:-4}"
DRA_DRIVER_CPU_ROLLOUT_TIMEOUT="${DRA_DRIVER_CPU_ROLLOUT_TIMEOUT:-180s}"
DRA_DRIVER_CPU_NODE_SELECTOR_KEY="${DRA_DRIVER_CPU_NODE_SELECTOR_KEY:-scheduler.slinky.slurm.net/slurm-bridge}"
DRA_DRIVER_CPU_NODE_SELECTOR_VALUE="${DRA_DRIVER_CPU_NODE_SELECTOR_VALUE:-worker}"
DRA_DRIVER_CPU_TAINT_KEY="${DRA_DRIVER_CPU_TAINT_KEY:-slinky.slurm.net/managed-node}"
DRA_DRIVER_CPU_TAINT_VALUE="${DRA_DRIVER_CPU_TAINT_VALUE:-slurm-bridge-scheduler}"
KUBECTL="${KUBECTL:-kubectl}"
CURL="${CURL:-curl}"
TMPDIRS=()

function cleanup() {
	local dir
	for dir in "${TMPDIRS[@]}"; do
		rm -rf "$dir"
	done
}
trap cleanup EXIT

function log() {
	printf '[dra-driver-cpu] %s\n' "$*"
}

function usage() {
	cat <<EOF
$(basename "$0") - install or uninstall kubernetes-sigs/dra-driver-cpu

usage: $(basename "$0") [install|uninstall]

Environment:
  DRA_DRIVER_CPU_REPO                 Default: ${DRA_DRIVER_CPU_REPO}
  DRA_DRIVER_CPU_VERSION              Default: ${DRA_DRIVER_CPU_VERSION}
  DRA_DRIVER_CPU_NAMESPACE            Default: ${DRA_DRIVER_CPU_NAMESPACE}
  DRA_DRIVER_CPU_DEVICE_MODE          Default: ${DRA_DRIVER_CPU_DEVICE_MODE}
  DRA_DRIVER_CPU_IMAGE                Optional image override
  DRA_DRIVER_CPU_IMAGE_PULL_POLICY    Default: ${DRA_DRIVER_CPU_IMAGE_PULL_POLICY}
  DRA_DRIVER_CPU_LOG_LEVEL            Default: ${DRA_DRIVER_CPU_LOG_LEVEL}
  DRA_DRIVER_CPU_ROLLOUT_TIMEOUT      Default: ${DRA_DRIVER_CPU_ROLLOUT_TIMEOUT}
  DRA_DRIVER_CPU_NODE_SELECTOR_KEY    Default: ${DRA_DRIVER_CPU_NODE_SELECTOR_KEY}
  DRA_DRIVER_CPU_NODE_SELECTOR_VALUE  Default: ${DRA_DRIVER_CPU_NODE_SELECTOR_VALUE}
  DRA_DRIVER_CPU_TAINT_KEY            Default: ${DRA_DRIVER_CPU_TAINT_KEY}
  DRA_DRIVER_CPU_TAINT_VALUE          Default: ${DRA_DRIVER_CPU_TAINT_VALUE}
EOF
}

function require_command() {
	local name="$1"
	command -v "$name" >/dev/null 2>&1 || {
		printf '[dra-driver-cpu] ERROR: %s is required\n' "$name" >&2
		exit 1
	}
}

function validate_config() {
	case "$DRA_DRIVER_CPU_DEVICE_MODE" in
	individual | grouped) ;;
	*)
		printf '[dra-driver-cpu] ERROR: DRA_DRIVER_CPU_DEVICE_MODE must be individual or grouped, got: %s\n' "$DRA_DRIVER_CPU_DEVICE_MODE" >&2
		exit 1
		;;
	esac
}

function manifest_url() {
	local file="$1"
	printf 'https://raw.githubusercontent.com/%s/%s/manifests/base/%s\n' \
		"$DRA_DRIVER_CPU_REPO" "$DRA_DRIVER_CPU_VERSION" "$file"
}

function fetch_manifest() {
	local file="$1"
	local output="$2"

	"$CURL" -fsSL "$(manifest_url "$file")" -o "$output"
}

function make_tmpdir() {
	local dir
	dir="$(mktemp -d)"
	TMPDIRS+=("$dir")
	printf '%s\n' "$dir"
}

function patch_daemonset() {
	local input="$1"
	local output="$2"
	local tmpdir

	tmpdir="$(make_tmpdir)"

	cat >"${tmpdir}/scope-patch.yaml" <<EOF
spec:
  template:
    spec:
      nodeSelector:
        "${DRA_DRIVER_CPU_NODE_SELECTOR_KEY}": "${DRA_DRIVER_CPU_NODE_SELECTOR_VALUE}"
      tolerations:
        - key: "${DRA_DRIVER_CPU_TAINT_KEY}"
          operator: "Equal"
          value: "${DRA_DRIVER_CPU_TAINT_VALUE}"
          effect: "NoExecute"
EOF

	"$KUBECTL" patch --local -f "$input" --type merge \
		--patch-file "${tmpdir}/scope-patch.yaml" -o yaml >"${tmpdir}/daemonset-scoped.yaml"

	cat >"${tmpdir}/container-patch.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: dracpu
          imagePullPolicy: "${DRA_DRIVER_CPU_IMAGE_PULL_POLICY}"
          args:
            - /dracpu
            - --v=${DRA_DRIVER_CPU_LOG_LEVEL}
            - --cpu-device-mode=${DRA_DRIVER_CPU_DEVICE_MODE}
EOF
	if [[ -n "$DRA_DRIVER_CPU_IMAGE" ]]; then
		cat >>"${tmpdir}/container-patch.yaml" <<EOF
          image: "${DRA_DRIVER_CPU_IMAGE}"
EOF
	fi

	"$KUBECTL" patch --local -f "${tmpdir}/daemonset-scoped.yaml" --type strategic \
		--patch-file "${tmpdir}/container-patch.yaml" -o yaml >"$output"
}

function install() {
	local tmpdir
	tmpdir="$(make_tmpdir)"

	log "Using ${DRA_DRIVER_CPU_REPO}@${DRA_DRIVER_CPU_VERSION}"
	for file in \
		clusterrole-dracpu.part.yaml \
		serviceaccount-dracpu.part.yaml \
		clusterrolebinding-dracpu.part.yaml \
		deviceclass-dracpu.part.yaml \
		daemonset-dracpu.part.yaml; do
		fetch_manifest "$file" "${tmpdir}/${file}"
	done

	patch_daemonset "${tmpdir}/daemonset-dracpu.part.yaml" "${tmpdir}/daemonset-dracpu.yaml"

	"$KUBECTL" apply -f "${tmpdir}/clusterrole-dracpu.part.yaml"
	"$KUBECTL" apply -f "${tmpdir}/serviceaccount-dracpu.part.yaml"
	"$KUBECTL" apply -f "${tmpdir}/clusterrolebinding-dracpu.part.yaml"
	"$KUBECTL" apply -f "${tmpdir}/deviceclass-dracpu.part.yaml"
	"$KUBECTL" apply -f "${tmpdir}/daemonset-dracpu.yaml"
	"$KUBECTL" -n "$DRA_DRIVER_CPU_NAMESPACE" rollout status daemonset/dracpu --timeout="$DRA_DRIVER_CPU_ROLLOUT_TIMEOUT"
	"$KUBECTL" -n "$DRA_DRIVER_CPU_NAMESPACE" get daemonset dracpu -o wide
	"$KUBECTL" get deviceclass dra.cpu
	"$KUBECTL" get resourceslices -o wide || true
}

function uninstall() {
	"$KUBECTL" -n "$DRA_DRIVER_CPU_NAMESPACE" delete daemonset dracpu --ignore-not-found
	"$KUBECTL" delete deviceclass dra.cpu --ignore-not-found
	"$KUBECTL" delete clusterrolebinding dracpu --ignore-not-found
	"$KUBECTL" delete clusterrole dracpu --ignore-not-found
	"$KUBECTL" -n "$DRA_DRIVER_CPU_NAMESPACE" delete serviceaccount dracpu --ignore-not-found
}

case "${1:-install}" in
install)
	require_command "$KUBECTL"
	require_command "$CURL"
	validate_config
	install
	;;
uninstall)
	require_command "$KUBECTL"
	uninstall
	;;
-h | --help)
	usage
	;;
*)
	usage >&2
	exit 1
	;;
esac
