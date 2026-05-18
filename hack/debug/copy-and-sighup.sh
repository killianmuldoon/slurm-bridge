#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

# Skaffold runs this as a post-sync hook after build-binary.sh. When that pre
# hook produced a pending component binary, this copies it into the running pod
# and sends SIGHUP so the Delve wrapper promotes and restarts it.

set -euo pipefail

component="${1:?usage: $0 scheduler|controllers|admission}"
namespace="${DEBUG_NAMESPACE:-slinky}"
kubectl_cmd="${KUBECTL:-kubectl}"

case "$component" in
	scheduler)
		app_name="slurm-bridge-scheduler"
		container="scheduler"
		;;
	controllers)
		app_name="slurm-bridge-controllers"
		container="slurm-bridge-controllers"
		;;
	admission)
		app_name="slurm-bridge-admission"
		container="slurm-bridge-admission"
		;;
	*)
		echo "unknown debug component: $component" >&2
		exit 2
		;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
binary="$repo_root/.skaffold-bin/$component"
pending="$repo_root/.skaffold-bin/$component.pending"
dest="/workspace/next/$component"
selector="app.kubernetes.io/instance=slurm-bridge,app.kubernetes.io/name=$app_name"

if [ ! -f "$pending" ]; then
	echo "no pending $component debug binary; skipping copy and reload"
	exit 0
fi

if [ ! -x "$binary" ]; then
	echo "debug binary is missing or not executable: $binary" >&2
	exit 1
fi

pod="$("$kubectl_cmd" -n "$namespace" get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
if [ -z "$pod" ]; then
	echo "no running pod found for selector: $selector" >&2
	exit 1
fi

"$kubectl_cmd" -n "$namespace" exec "$pod" -c "$container" -- mkdir -p /workspace/next
"$kubectl_cmd" -n "$namespace" cp "$binary" "$namespace/$pod:$dest" -c "$container"
"$kubectl_cmd" -n "$namespace" exec "$pod" -c "$container" -- kill -HUP 1
rm -f "$pending"

echo "copied $component debug binary to $pod:$dest and sent SIGHUP"
