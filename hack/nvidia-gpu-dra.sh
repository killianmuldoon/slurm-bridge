#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

NVIDIA_GPU_DRA_NAMESPACE="${NVIDIA_GPU_DRA_NAMESPACE:-dra-driver-nvidia-gpu}"
NVIDIA_GPU_DRA_RELEASE="${NVIDIA_GPU_DRA_RELEASE:-dra-driver-nvidia-gpu}"
NVIDIA_GPU_DRA_CHART="${NVIDIA_GPU_DRA_CHART:-oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu}"
NVIDIA_GPU_DRA_CHART_VERSION="${NVIDIA_GPU_DRA_CHART_VERSION:-0.4.0}"
NVIDIA_GPU_DRA_NODE_SELECTOR="${NVIDIA_GPU_DRA_NODE_SELECTOR:-scheduler.slinky.slurm.net/slurm-bridge=worker}"
NVIDIA_GPU_DRA_TAINT_KEY="${NVIDIA_GPU_DRA_TAINT_KEY:-slinky.slurm.net/managed-node}"
NVIDIA_GPU_DRA_TAINT_VALUE="${NVIDIA_GPU_DRA_TAINT_VALUE:-slurm-bridge-scheduler}"
NVIDIA_GPU_DRA_DRIVER_ROOT="${NVIDIA_GPU_DRA_DRIVER_ROOT:-/var/lib/nvml-mock/driver}"
NVIDIA_GPU_DRA_MOCK_ROOT="${NVIDIA_GPU_DRA_MOCK_ROOT:-/var/lib/nvml-mock}"
NVIDIA_GPU_DRA_MOCK_SYSFS="${NVIDIA_GPU_DRA_MOCK_SYSFS:-true}"
NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT="${NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT:-${NVIDIA_GPU_DRA_MOCK_ROOT}/sys}"
NVIDIA_GPU_DRA_COMPUTE_DOMAINS="${NVIDIA_GPU_DRA_COMPUTE_DOMAINS:-true}"
NVIDIA_GPU_DRA_ALT_PROC_DEVICES="${NVIDIA_GPU_DRA_ALT_PROC_DEVICES:-/var/lib/nvml-mock/imex/proc-devices}"
NVIDIA_GPU_DRA_MOCK_PROFILE="${NVIDIA_GPU_DRA_MOCK_PROFILE:-gb200}"
NVIDIA_GPU_DRA_MOCK_GPU_COUNT="${NVIDIA_GPU_DRA_MOCK_GPU_COUNT:-4}"
NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION="${NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION:-}"
NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS="${NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS:-true}"
NVIDIA_GPU_DRA_MOCK_VERIFY="${NVIDIA_GPU_DRA_MOCK_VERIFY:-basic}"
NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI="${NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI:-false}"
NVIDIA_GPU_DRA_DRIVER_REPO="${NVIDIA_GPU_DRA_DRIVER_REPO:-NVIDIA/k8s-dra-driver-gpu}"
NVIDIA_GPU_DRA_DRIVER_REF="${NVIDIA_GPU_DRA_DRIVER_REF:-main}"
NVIDIA_GPU_DRA_TEST_INFRA_REPO="${NVIDIA_GPU_DRA_TEST_INFRA_REPO:-https://github.com/NVIDIA/k8s-test-infra.git}"
NVIDIA_GPU_DRA_TEST_INFRA_DIR="${NVIDIA_GPU_DRA_TEST_INFRA_DIR:-/var/tmp/k8s-test-infra}"
NVIDIA_GPU_DRA_GO_VERSION="${NVIDIA_GPU_DRA_GO_VERSION:-1.26.2}"
NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT="${NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT:-300s}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"

MODE="${1:-install}"

function log() {
	printf '[nvidia-gpu-dra] %s\n' "$*"
}

function fail() {
	printf '[nvidia-gpu-dra] ERROR: %s\n' "$*" >&2
	exit 1
}

function usage() {
	cat <<EOF
$(basename "$0") - install NVIDIA GPU DRA with mock NVML fake GPUs

usage: $(basename "$0") [install|uninstall|mock-only|helm-only]

Environment:
  KUBECTL                             Default: ${KUBECTL}
  HELM                                Default: ${HELM}
  REMOTE_USER                         Default: ${REMOTE_USER}
  REMOTE_PASSWORD                     Optional; when empty, SSH key auth is used
  NVIDIA_GPU_DRA_NAMESPACE            Default: ${NVIDIA_GPU_DRA_NAMESPACE}
  NVIDIA_GPU_DRA_RELEASE              Default: ${NVIDIA_GPU_DRA_RELEASE}
  NVIDIA_GPU_DRA_CHART                Default: ${NVIDIA_GPU_DRA_CHART}
  NVIDIA_GPU_DRA_CHART_VERSION        Default: ${NVIDIA_GPU_DRA_CHART_VERSION}
  NVIDIA_GPU_DRA_NODE_SELECTOR        Default: ${NVIDIA_GPU_DRA_NODE_SELECTOR}
  NVIDIA_GPU_DRA_TAINT_KEY            Default: ${NVIDIA_GPU_DRA_TAINT_KEY}
  NVIDIA_GPU_DRA_TAINT_VALUE          Default: ${NVIDIA_GPU_DRA_TAINT_VALUE}
  NVIDIA_GPU_DRA_DRIVER_ROOT          Default: ${NVIDIA_GPU_DRA_DRIVER_ROOT}
  NVIDIA_GPU_DRA_MOCK_ROOT            Default: ${NVIDIA_GPU_DRA_MOCK_ROOT}
  NVIDIA_GPU_DRA_MOCK_SYSFS           Default: ${NVIDIA_GPU_DRA_MOCK_SYSFS}
  NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT      Default: ${NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT}
  NVIDIA_GPU_DRA_COMPUTE_DOMAINS      Default: ${NVIDIA_GPU_DRA_COMPUTE_DOMAINS}
  NVIDIA_GPU_DRA_ALT_PROC_DEVICES     Default: ${NVIDIA_GPU_DRA_ALT_PROC_DEVICES}
  NVIDIA_GPU_DRA_MOCK_PROFILE         Default: ${NVIDIA_GPU_DRA_MOCK_PROFILE}
  NVIDIA_GPU_DRA_MOCK_GPU_COUNT       Default: ${NVIDIA_GPU_DRA_MOCK_GPU_COUNT}
  NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION  Optional; defaults to the upstream profile value
  NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS
                                      Default: ${NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS}
  NVIDIA_GPU_DRA_MOCK_VERIFY          Default: ${NVIDIA_GPU_DRA_MOCK_VERIFY}; one of none,basic,full
  NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI Default: ${NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI}
  NVIDIA_GPU_DRA_DRIVER_REPO          Default: ${NVIDIA_GPU_DRA_DRIVER_REPO}
  NVIDIA_GPU_DRA_DRIVER_REF           Default: ${NVIDIA_GPU_DRA_DRIVER_REF}
  NVIDIA_GPU_DRA_TEST_INFRA_REPO      Default: ${NVIDIA_GPU_DRA_TEST_INFRA_REPO}
  NVIDIA_GPU_DRA_TEST_INFRA_DIR       Default: ${NVIDIA_GPU_DRA_TEST_INFRA_DIR}
  NVIDIA_GPU_DRA_GO_VERSION           Default: ${NVIDIA_GPU_DRA_GO_VERSION}
  NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT      Default: ${NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT}
EOF
}

function require_command() {
	local name="$1"
	command -v "$name" >/dev/null 2>&1 || fail "'$name' is required"
}

function shell_quote() {
	printf '%q' "$1"
}

function yaml_double_quote() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
}

function validate_bool() {
	local name="$1"
	local value="$2"

	case "$value" in
	true | false) ;;
	*) fail "${name} must be true or false" ;;
	esac
}

function validate_config() {
	case "$MODE" in
	install | uninstall | mock-only | helm-only) ;;
	*) fail "unknown mode: ${MODE}" ;;
	esac

	case "$NVIDIA_GPU_DRA_MOCK_PROFILE" in
	a100 | h100 | b200 | gb200 | gb300 | l40s | t4) ;;
	*) fail "NVIDIA_GPU_DRA_MOCK_PROFILE must be one of a100,h100,b200,gb200,gb300,l40s,t4" ;;
	esac

	case "$NVIDIA_GPU_DRA_MOCK_VERIFY" in
	none | basic | full) ;;
	*) fail "NVIDIA_GPU_DRA_MOCK_VERIFY must be one of none,basic,full" ;;
	esac

	if ! [[ "$NVIDIA_GPU_DRA_MOCK_GPU_COUNT" =~ ^[0-9]+$ ]]; then
		fail "NVIDIA_GPU_DRA_MOCK_GPU_COUNT must be an integer"
	fi
	if ((NVIDIA_GPU_DRA_MOCK_GPU_COUNT < 1 || NVIDIA_GPU_DRA_MOCK_GPU_COUNT > 8)); then
		fail "NVIDIA_GPU_DRA_MOCK_GPU_COUNT must be between 1 and 8"
	fi

	validate_bool NVIDIA_GPU_DRA_COMPUTE_DOMAINS "$NVIDIA_GPU_DRA_COMPUTE_DOMAINS"
	validate_bool NVIDIA_GPU_DRA_MOCK_SYSFS "$NVIDIA_GPU_DRA_MOCK_SYSFS"
	validate_bool NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS "$NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS"
	validate_bool NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI "$NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI"

	if [[ ! "$NVIDIA_GPU_DRA_NODE_SELECTOR" =~ ^[^=,]+=[^=,]+$ ]]; then
		fail "NVIDIA_GPU_DRA_NODE_SELECTOR must be a single key=value selector so it can be reused as a Helm nodeSelector"
	fi

	if [[ "$NVIDIA_GPU_DRA_COMPUTE_DOMAINS" == "true" && -z "$NVIDIA_GPU_DRA_ALT_PROC_DEVICES" ]]; then
		fail "NVIDIA_GPU_DRA_ALT_PROC_DEVICES is required when NVIDIA_GPU_DRA_COMPUTE_DOMAINS=true"
	fi

	case "$NVIDIA_GPU_DRA_MOCK_PROFILE" in
	b200 | gb200) ;;
	*)
		if [[ "$NVIDIA_GPU_DRA_COMPUTE_DOMAINS" == "true" && -z "$NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION" ]]; then
			fail "NVIDIA_GPU_DRA_COMPUTE_DOMAINS=true requires b200/gb200 or NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION >= 570.158.01"
		fi
		;;
	esac
}

function remote() {
	local ip="$1"
	shift

	if [[ -z "$REMOTE_PASSWORD" ]]; then
		ssh \
			-o StrictHostKeyChecking=accept-new \
			"${REMOTE_USER}@${ip}" "$@"
		return
	fi

	REMOTE_PASSWORD="$REMOTE_PASSWORD" expect -f - -- \
		ssh \
		-o NumberOfPasswordPrompts=1 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		-o StrictHostKeyChecking=accept-new \
		"${REMOTE_USER}@${ip}" "$@" <<'EXPECT'
set timeout -1
log_user 0
set password $env(REMOTE_PASSWORD)
spawn {*}$argv
expect {
	-nocase "password:" {
		send -- "$password\r"
		log_user 1
		exp_continue
	}
	eof {
		set result [wait]
		if {[llength $result] >= 4} {
			exit [lindex $result 3]
		}
		exit 0
	}
}
EXPECT
}

function scp_to_remote() {
	local ip="$1"
	local local_path="$2"
	local remote_path="$3"

	if [[ -z "$REMOTE_PASSWORD" ]]; then
		scp \
			-o StrictHostKeyChecking=accept-new \
			"$local_path" "${REMOTE_USER}@${ip}:${remote_path}"
		return
	fi

	REMOTE_PASSWORD="$REMOTE_PASSWORD" expect -f - -- \
		scp \
		-o NumberOfPasswordPrompts=1 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		-o StrictHostKeyChecking=accept-new \
		"$local_path" "${REMOTE_USER}@${ip}:${remote_path}" <<'EXPECT'
set timeout -1
log_user 0
set password $env(REMOTE_PASSWORD)
spawn {*}$argv
expect {
	-nocase "password:" {
		send -- "$password\r"
		log_user 1
		exp_continue
	}
	eof {
		set result [wait]
		if {[llength $result] >= 4} {
			exit [lindex $result 3]
		}
		exit 0
	}
}
EXPECT
}

function target_nodes() {
	"$KUBECTL" get nodes -l "$NVIDIA_GPU_DRA_NODE_SELECTOR" \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{end}{"\n"}{end}'
}

function write_remote_setup_script() {
	local output="$1"

	cat >"$output" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
	SUDO="sudo"
fi

function log() {
	printf '[nvidia-gpu-dra-remote] %s\n' "$*"
}

export PATH="/usr/local/go/bin:${PATH}"

function go_version_ok() {
	command -v go >/dev/null 2>&1 || return 1
	local current
	current="$(go env GOVERSION | sed 's/^go//')"
	[[ "$(printf '%s\n%s\n' "$NVIDIA_GPU_DRA_GO_VERSION" "$current" | sort -V | head -n1)" == "$NVIDIA_GPU_DRA_GO_VERSION" ]]
}

function install_go() {
	if go_version_ok; then
		return
	fi

	local arch
	case "$(uname -m)" in
	x86_64 | amd64) arch="amd64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*) echo "unsupported architecture for Go install: $(uname -m)" >&2; exit 1 ;;
	esac

	log "installing Go ${NVIDIA_GPU_DRA_GO_VERSION}"
	curl -fsSL "https://go.dev/dl/go${NVIDIA_GPU_DRA_GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz
	$SUDO rm -rf /usr/local/go
	$SUDO tar -C /usr/local -xzf /tmp/go.tgz
	rm -f /tmp/go.tgz
}

if command -v apt-get >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	$SUDO apt-get update
	$SUDO apt-get install -y \
		ca-certificates \
		curl \
		git \
		gpg \
		make \
		gcc \
		g++ \
		libc6-dev \
		binutils \
		file \
		patchelf
else
	log "apt-get not found; assuming prerequisites are already installed"
fi

install_go

mkdir -p "$(dirname "$NVIDIA_GPU_DRA_TEST_INFRA_DIR")"
if [[ ! -d "${NVIDIA_GPU_DRA_TEST_INFRA_DIR}/.git" ]]; then
	log "cloning ${NVIDIA_GPU_DRA_TEST_INFRA_REPO}"
	git clone --depth 1 "$NVIDIA_GPU_DRA_TEST_INFRA_REPO" "$NVIDIA_GPU_DRA_TEST_INFRA_DIR"
else
	log "updating ${NVIDIA_GPU_DRA_TEST_INFRA_DIR}"
	git -C "$NVIDIA_GPU_DRA_TEST_INFRA_DIR" fetch --depth 1 origin main
	git -C "$NVIDIA_GPU_DRA_TEST_INFRA_DIR" reset --hard FETCH_HEAD
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

base_url="https://raw.githubusercontent.com/${NVIDIA_GPU_DRA_DRIVER_REPO}/${NVIDIA_GPU_DRA_DRIVER_REF}/hack/ci/mock-nvml"
curl -fsSL "${base_url}/common.sh" -o "${workdir}/common.sh"
curl -fsSL "${base_url}/setup-mock-gpu.sh" -o "${workdir}/setup-mock-gpu.sh"
curl -fsSL "${base_url}/verify-mock-gpu.sh" -o "${workdir}/verify-mock-gpu.sh"
chmod +x "${workdir}/setup-mock-gpu.sh" "${workdir}/verify-mock-gpu.sh"

log "installing mock NVML profile=${NVIDIA_GPU_DRA_MOCK_PROFILE} count=${NVIDIA_GPU_DRA_MOCK_GPU_COUNT}"
GPU_PROFILE="$NVIDIA_GPU_DRA_MOCK_PROFILE" \
GPU_COUNT="$NVIDIA_GPU_DRA_MOCK_GPU_COUNT" \
K8S_TEST_INFRA_DIR="$NVIDIA_GPU_DRA_TEST_INFRA_DIR" \
DRIVER_VERSION="$NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION" \
DRIVER_ROOT="$NVIDIA_GPU_DRA_DRIVER_ROOT" \
SKIP_NVIDIA_SMI="$NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI" \
	bash "${workdir}/setup-mock-gpu.sh"

if [[ "$NVIDIA_GPU_DRA_MOCK_SYSFS" == "true" ]]; then
	log "rendering mock PCI sysfs at ${NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT}"
	(
		cd "$NVIDIA_GPU_DRA_TEST_INFRA_DIR"
		go build -o /tmp/render-pci-sysfs ./cmd/render-pci-sysfs
	)
	$SUDO rm -rf "$NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT"
	$SUDO /tmp/render-pci-sysfs \
		--config "${NVIDIA_GPU_DRA_DRIVER_ROOT}/config/config.yaml" \
		--output "$NVIDIA_GPU_DRA_MOCK_ROOT"
fi

if [[ "$NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS" == "true" ]]; then
	# The mock profiles use the Linux BDF form in nvmlPciInfo.BusId, but
	# go-nvlib expects NVML v3's eight-hex-digit domain and trims it to Linux BDF.
	$SUDO sed -i -E 's|(bus_id:[[:space:]]*")0000:|\100000000:|' "${NVIDIA_GPU_DRA_DRIVER_ROOT}/config/config.yaml"
fi

case "$NVIDIA_GPU_DRA_MOCK_VERIFY" in
none)
	log "skipping mock NVML verification"
	;;
basic)
	test -f "${NVIDIA_GPU_DRA_DRIVER_ROOT}/config/config.yaml"
	test -f /var/run/cdi/nvidia-mock.yaml
	test -f /var/lib/nvml-mock/imex/proc-devices
	if [[ "$NVIDIA_GPU_DRA_MOCK_SYSFS" == "true" ]]; then
		test -d "$NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT/bus/pci/devices"
	fi
	if [[ "$NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI" != "true" ]]; then
		"${NVIDIA_GPU_DRA_DRIVER_ROOT}/usr/bin/nvidia-smi" -L
	fi
	;;
full)
	GPU_PROFILE="$NVIDIA_GPU_DRA_MOCK_PROFILE" \
	GPU_COUNT="$NVIDIA_GPU_DRA_MOCK_GPU_COUNT" \
	K8S_TEST_INFRA_DIR="$NVIDIA_GPU_DRA_TEST_INFRA_DIR" \
	DRIVER_VERSION="$NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION" \
	DRIVER_ROOT="$NVIDIA_GPU_DRA_DRIVER_ROOT" \
	VERIFY_DOCKER=false \
		bash "${workdir}/verify-mock-gpu.sh"
	;;
esac
REMOTE
}

function install_mock_on_node() {
	local node="$1"
	local ip="$2"
	local setup_script
	local remote_cmd

	setup_script="$(mktemp)"
	write_remote_setup_script "$setup_script"
	scp_to_remote "$ip" "$setup_script" /tmp/slurm-bridge-nvidia-gpu-mock.sh
	rm -f "$setup_script"

	remote_cmd="env"
	remote_cmd+=" NVIDIA_GPU_DRA_GO_VERSION=$(shell_quote "$NVIDIA_GPU_DRA_GO_VERSION")"
	remote_cmd+=" NVIDIA_GPU_DRA_TEST_INFRA_REPO=$(shell_quote "$NVIDIA_GPU_DRA_TEST_INFRA_REPO")"
	remote_cmd+=" NVIDIA_GPU_DRA_TEST_INFRA_DIR=$(shell_quote "$NVIDIA_GPU_DRA_TEST_INFRA_DIR")"
	remote_cmd+=" NVIDIA_GPU_DRA_DRIVER_REPO=$(shell_quote "$NVIDIA_GPU_DRA_DRIVER_REPO")"
	remote_cmd+=" NVIDIA_GPU_DRA_DRIVER_REF=$(shell_quote "$NVIDIA_GPU_DRA_DRIVER_REF")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_PROFILE=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_PROFILE")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_GPU_COUNT=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_GPU_COUNT")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_DRIVER_VERSION")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_PATCH_NVML_BUS_IDS")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_VERIFY=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_VERIFY")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_ROOT=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_ROOT")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_SYSFS=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_SYSFS")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT")"
	remote_cmd+=" NVIDIA_GPU_DRA_DRIVER_ROOT=$(shell_quote "$NVIDIA_GPU_DRA_DRIVER_ROOT")"
	remote_cmd+=" NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI=$(shell_quote "$NVIDIA_GPU_DRA_MOCK_SKIP_NVIDIA_SMI")"
	remote_cmd+=" bash /tmp/slurm-bridge-nvidia-gpu-mock.sh"

	log "installing mock GPUs on ${node} (${ip})"
	remote "$ip" "$remote_cmd"
}

function install_mock() {
	local rows
	rows="$(target_nodes)"
	if [[ -z "$rows" ]]; then
		fail "no target nodes matched selector ${NVIDIA_GPU_DRA_NODE_SELECTOR}"
	fi

	while IFS=$'\t' read -r node ip; do
		[[ -n "$node" ]] || continue
		if [[ -z "$ip" ]]; then
			fail "node ${node} has no InternalIP"
		fi
		install_mock_on_node "$node" "$ip"
		"$KUBECTL" label node "$node" \
			nvidia.com/gpu.present=true \
			feature.node.kubernetes.io/pci-10de.present=true \
			--overwrite
	done <<<"$rows"
}

function patch_mock_sysfs_daemonset() {
	local daemonset
	local patch

	if [[ "$NVIDIA_GPU_DRA_MOCK_SYSFS" != "true" ]]; then
		return
	fi

	daemonset="${NVIDIA_GPU_DRA_RELEASE}-kubelet-plugin"
	patch="$(mktemp)"
	cat >"$patch" <<EOF
spec:
  template:
    spec:
      volumes:
        - name: mock-sysfs
          hostPath:
            path: $(yaml_double_quote "$NVIDIA_GPU_DRA_MOCK_SYSFS_ROOT")
            type: Directory
      containers:
        - name: gpus
          volumeMounts:
            - name: mock-sysfs
              mountPath: /sys
              readOnly: true
EOF

	log "patching ${daemonset} to mount mock PCI sysfs"
	"$KUBECTL" -n "$NVIDIA_GPU_DRA_NAMESPACE" patch daemonset "$daemonset" \
		--type=strategic \
		--patch-file "$patch"
	rm -f "$patch"

	"$KUBECTL" -n "$NVIDIA_GPU_DRA_NAMESPACE" rollout status daemonset/"$daemonset" \
		--timeout "$NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT"
}

function install_chart() {
	local values
	local node_selector_key
	local node_selector_value
	local alt_proc_devices_value='""'

	node_selector_key="${NVIDIA_GPU_DRA_NODE_SELECTOR%%=*}"
	node_selector_value="${NVIDIA_GPU_DRA_NODE_SELECTOR#*=}"

	if [[ "$NVIDIA_GPU_DRA_COMPUTE_DOMAINS" == "true" ]]; then
		alt_proc_devices_value="$(yaml_double_quote "$NVIDIA_GPU_DRA_ALT_PROC_DEVICES")"
	fi

	values="$(mktemp)"
	cat >"$values" <<EOF
nvidiaDriverRoot: $(yaml_double_quote "$NVIDIA_GPU_DRA_DRIVER_ROOT")
altProcDevices: ${alt_proc_devices_value}
gpuResourcesEnabledOverride: true
resourceApiVersion: resource.k8s.io/v1
resources:
  gpus:
    enabled: true
  computeDomains:
    enabled: ${NVIDIA_GPU_DRA_COMPUTE_DOMAINS}
webhook:
  enabled: false
kubeletPlugin:
  nodeSelector:
    ${node_selector_key}: $(yaml_double_quote "$node_selector_value")
  tolerations:
    - key: "${NVIDIA_GPU_DRA_TAINT_KEY}"
      operator: "Equal"
      value: "${NVIDIA_GPU_DRA_TAINT_VALUE}"
      effect: "NoExecute"
EOF

	log "installing ${NVIDIA_GPU_DRA_CHART} ${NVIDIA_GPU_DRA_CHART_VERSION}"
	"$HELM" upgrade --install "$NVIDIA_GPU_DRA_RELEASE" "$NVIDIA_GPU_DRA_CHART" \
		--version "$NVIDIA_GPU_DRA_CHART_VERSION" \
		--namespace "$NVIDIA_GPU_DRA_NAMESPACE" \
		--create-namespace \
		--wait \
		--timeout "$NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT" \
		-f "$values"
	rm -f "$values"

	patch_mock_sysfs_daemonset

	"$KUBECTL" -n "$NVIDIA_GPU_DRA_NAMESPACE" get pods -o wide
	"$KUBECTL" get deviceclass gpu.nvidia.com
	"$KUBECTL" get resourceslices -o wide
}

function uninstall_chart() {
	"$HELM" uninstall "$NVIDIA_GPU_DRA_RELEASE" \
		--namespace "$NVIDIA_GPU_DRA_NAMESPACE" \
		--wait \
		--timeout "$NVIDIA_GPU_DRA_ROLLOUT_TIMEOUT" || true
}

case "$MODE" in
-h | --help)
	usage
	exit 0
	;;
esac

validate_config

case "$MODE" in
install)
	require_command "$KUBECTL"
	require_command "$HELM"
	require_command ssh
	require_command scp
	if [[ -n "$REMOTE_PASSWORD" ]]; then
		require_command expect
	fi
	install_mock
	install_chart
	;;
mock-only)
	require_command "$KUBECTL"
	require_command ssh
	require_command scp
	if [[ -n "$REMOTE_PASSWORD" ]]; then
		require_command expect
	fi
	install_mock
	;;
helm-only)
	require_command "$KUBECTL"
	require_command "$HELM"
	install_chart
	;;
uninstall)
	require_command "$HELM"
	uninstall_chart
	;;
esac
