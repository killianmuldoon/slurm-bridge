#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DRANET_REPO="${DRANET_REPO:-kubernetes-sigs/dranet}"
DRANET_VERSION="${DRANET_VERSION:-latest}"
DRANET_NAMESPACE="${DRANET_NAMESPACE:-kube-system}"
DRANET_ROLLOUT_TIMEOUT="${DRANET_ROLLOUT_TIMEOUT:-180s}"
DRANET_TAINT_KEY="${DRANET_TAINT_KEY:-slinky.slurm.net/managed-node}"
DRANET_TAINT_VALUE="${DRANET_TAINT_VALUE:-slurm-bridge-scheduler}"

KUBECTL="${KUBECTL:-kubectl}"
CURL="${CURL:-curl}"

function log() {
	echo "[dranet] $*"
}

function resolve_version() {
	local version="$1"
	if [ "$version" != "latest" ]; then
		printf '%s\n' "$version"
		return
	fi

	"$CURL" -fsSL "https://api.github.com/repos/${DRANET_REPO}/releases/latest" |
		sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
		head -n1
}

function install_dranet() {
	local version
	version="$(resolve_version "$DRANET_VERSION")"
	if [ -z "$version" ]; then
		echo "failed to resolve DRANET release version" >&2
		exit 1
	fi

	local manifest_url="https://raw.githubusercontent.com/${DRANET_REPO}/${version}/install.yaml"
	log "Using ${DRANET_REPO}@${version}"
	log "Using Kubernetes context: $("$KUBECTL" config current-context)"
	log "Applying ${manifest_url}"

	"$KUBECTL" apply -f "$manifest_url"
	patch_dranet_daemonset
	"$KUBECTL" -n "$DRANET_NAMESPACE" rollout status daemonset/dranet --timeout="$DRANET_ROLLOUT_TIMEOUT"
	"$KUBECTL" -n "$DRANET_NAMESPACE" get daemonset dranet -o wide
}

function patch_dranet_daemonset() {
	local tmpdir
	tmpdir="$(mktemp -d)"

	cat >"${tmpdir}/daemonset-patch.yaml" <<EOF
spec:
  template:
    spec:
      tolerations:
      - operator: Exists
        effect: NoSchedule
      - key: "${DRANET_TAINT_KEY}"
        operator: Equal
        value: "${DRANET_TAINT_VALUE}"
        effect: NoExecute
      hostPID: false
      initContainers:
      - name: enable-nri
        \$patch: delete
      volumes:
      - name: etc
        \$patch: delete
EOF

	log "Patching DRANET DaemonSet tolerations for this cluster"
	"$KUBECTL" -n "$DRANET_NAMESPACE" patch daemonset dranet --type=strategic --patch-file "${tmpdir}/daemonset-patch.yaml"
	rm -rf "$tmpdir"
}

function uninstall_dranet() {
	log "Using Kubernetes context: $("$KUBECTL" config current-context)"
	"$KUBECTL" delete daemonset -n "$DRANET_NAMESPACE" dranet --ignore-not-found
	"$KUBECTL" delete serviceaccount -n "$DRANET_NAMESPACE" dranet --ignore-not-found
	"$KUBECTL" delete clusterrolebinding dranet --ignore-not-found
	"$KUBECTL" delete clusterrole dranet --ignore-not-found
}

case "${1:-install}" in
install)
	install_dranet
	;;
uninstall)
	uninstall_dranet
	;;
*)
	echo "usage: $(basename "$0") [install|uninstall]" >&2
	exit 2
	;;
esac
