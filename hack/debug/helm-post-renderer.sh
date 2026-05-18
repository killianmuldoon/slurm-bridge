#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

# Helm invokes this post-renderer from the Skaffold debug profile. It captures
# Helm's rendered manifests, applies the debug Kustomize overlay, and emits the
# patched deployments that run under the reloadable Delve wrapper.

set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp -R "$script_dir/kustomize/." "$tmpdir/"
cat >"$tmpdir/rendered.yaml"

kubectl kustomize "$tmpdir"
