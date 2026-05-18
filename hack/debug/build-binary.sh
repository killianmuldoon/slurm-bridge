#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

# Skaffold runs this as a pre-sync hook for each debug artifact. It uses the
# changed file list to decide whether that component's dependency graph changed,
# then builds a replacement debug binary and marks it pending for the post hook.

set -euo pipefail
component="${1:?usage: $0 scheduler|controllers|admission}"

case "$component" in
	scheduler | controllers | admission) ;;
	*)
		echo "unknown debug component: $component" >&2
		exit 2
		;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
out_dir="$repo_root/.skaffold-bin"
pending="$out_dir/$component.pending"
changed_runtime_files=""
dry_run="${DEBUG_BUILD_DRY_RUN:-false}"

changed_files() {
	local files="${SKAFFOLD_FILES_ADDED_OR_MODIFIED:-}"
	if [ -n "${SKAFFOLD_FILES_DELETED:-}" ]; then
		files="${files:+$files;}${SKAFFOLD_FILES_DELETED}"
	fi

	if [ -z "$files" ]; then
		return
	fi

	tr ';' '\n' <<<"$files" | sed '/^$/d'
}

normalize_changed_file() {
	local file="$1"
	local dir base abs_dir candidate skaffold_dir

	file="${file#./}"
	skaffold_dir="$repo_root/helm/slurm-bridge"
	case "$file" in
		/tmp/skaffold-sync/*)
			printf '%s\n' "${file#/tmp/skaffold-sync/}"
			return
			;;
		/*)
			dir="$(dirname "$file")"
			base="$(basename "$file")"
			if abs_dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
				case "$abs_dir/$base" in
					"$repo_root"/*)
						printf '%s\n' "${abs_dir#"$repo_root"/}/$base"
						return
						;;
					/tmp/skaffold-sync/*)
						printf '%s\n' "${abs_dir#/tmp/skaffold-sync/}/$base"
						return
						;;
				esac
			fi
			return
			;;
	esac

	for candidate in "$repo_root/$file" "$skaffold_dir/$file"; do
		dir="$(dirname "$candidate")"
		base="$(basename "$candidate")"
		if abs_dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
			case "$abs_dir/$base" in
				"$repo_root"/*)
					printf '%s\n' "${abs_dir#"$repo_root"/}/$base"
					return
					;;
			esac
		fi
	done

	printf '%s\n' "$file"
}

runtime_changed_files() {
	local file rel_file
	while IFS= read -r file; do
		rel_file="$(normalize_changed_file "$file")"
		[ -n "$rel_file" ] || continue
		case "$rel_file" in
			go.mod | go.sum | *.go)
				printf '%s\n' "$rel_file"
				;;
		esac
	done < <(changed_files || true)
}

component_changed() {
	local module_path
	if ! module_path="$(cd "$repo_root" && go list -m)"; then
		echo "could not determine Go module path; building $component" >&2
		return 0
	fi

	local deps_output
	if ! deps_output="$(
		cd "$repo_root"
		go list -deps -f '{{with .Module}}{{if eq .Path "'"$module_path"'"}}{{$.Dir}}{{end}}{{end}}' "./cmd/$component"
	)"; then
		echo "could not determine $component dependency set; building $component" >&2
		return 0
	fi

	local raw_pkg_dirs=()
	mapfile -t raw_pkg_dirs <<<"$deps_output"

	local pkg_dirs=()
	local pkg_dir rel_dir
	for pkg_dir in "${raw_pkg_dirs[@]}"; do
		[ -n "$pkg_dir" ] || continue
		case "$pkg_dir" in
			"$repo_root"/*) rel_dir="${pkg_dir#"$repo_root"/}" ;;
			*) continue ;;
		esac
		pkg_dirs+=("$rel_dir")
	done

	local changed rel_file file_dir dep_dir
	changed="$(runtime_changed_files || true)"
	changed_runtime_files="$changed"
	if [ -z "$changed" ]; then
		return 0
	fi

	while IFS= read -r rel_file; do
		case "$rel_file" in
			go.mod | go.sum)
				return 0
				;;
			*_test.go)
				continue
				;;
			*.go)
				file_dir="${rel_file%/*}"
				[ "$file_dir" != "$rel_file" ] || file_dir="."
				for dep_dir in "${pkg_dirs[@]}"; do
					if [ "$file_dir" = "$dep_dir" ]; then
						return 0
					fi
				done
				;;
		esac
	done <<<"$changed"

	return 1
}

if [ "$dry_run" = "true" ]; then
	if component_changed; then
		echo "build"
	else
		echo "skip"
	fi
	exit 0
fi

mkdir -p "$out_dir"
rm -f "$pending"

if ! component_changed; then
	if [ -n "$changed_runtime_files" ]; then
		echo "no $component runtime dependency changes for: $(tr '\n' ' ' <<<"$changed_runtime_files" | sed 's/[[:space:]]*$//'); skipping debug binary build"
	else
		echo "no $component runtime dependency changes; skipping debug binary build"
	fi
	exit 0
fi

goos="${DEBUG_GOOS:-linux}"
goarch="${DEBUG_GOARCH:-}"

if [ -z "$goarch" ] && command -v kubectl >/dev/null 2>&1; then
	goarch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
fi

if [ -z "$goarch" ]; then
	goarch="$(go env GOARCH)"
fi

tmp="$(mktemp "$out_dir/$component.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

(
	cd "$repo_root"
	CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build -gcflags=all="-N -l" -o "$tmp" "./cmd/$component"
)

chmod +x "$tmp"
mv "$tmp" "$out_dir/$component"
printf '%s\n' "$out_dir/$component" >"$pending"
trap - EXIT

echo "built $component debug binary for $goos/$goarch at $out_dir/$component"
