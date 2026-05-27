#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0
#
# Build a real kubeadm cluster on routable VMs.
#
# Nodes must be supplied explicitly. The script assumes all nodes are mutually
# routable on the interface passed by --node-interface.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
WORKER_IPS=()
SLURM_WORKER_IPS=()
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
NODE_INTERFACE="${NODE_INTERFACE:-eth1}"
K8S_VERSION="${K8S_VERSION:-v1.35.0}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CLUSTER_NAME="${CLUSTER_NAME:-slurm-bridge-vm}"
PARTITION="${PARTITION:-slurm-bridge}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"
ENABLE_CONTAINERD_NRI="${ENABLE_CONTAINERD_NRI:-true}"
K8S_FEATURE_GATES="${K8S_FEATURE_GATES:-DynamicResourceAllocation=true,DRAExtendedResource=true,DRAResourceClaimDeviceStatus=true,DRAConsumableCapacity=true}"
RESET=false
SKIP_CNI=false
KUBECONFIG_OUT="${KUBECONFIG_OUT:-}"
INSTALL_DRA_DRIVER_CPU=false

function log() {
	printf '[kubeadm-vm] %s\n' "$*"
}

function fail() {
	printf '[kubeadm-vm] ERROR: %s\n' "$*" >&2
	exit 1
}

function usage() {
	cat <<EOF
$(basename "$0") - create a kubeadm cluster on routable VMs

usage: $(basename "$0") [options]

Options:
  --control-plane IP      Control-plane VM IP. Required.
  --worker IP             Untainted worker VM IP. Required unless --slurm-worker is set; may be repeated.
  --slurm-worker IP       Slurm-managed worker VM IP. Gets slurm-bridge labels, taint, and partition annotation.
                           May be repeated.
  --normal-worker IP      Deprecated alias for --worker.
  --user USER             SSH user. Default: ${REMOTE_USER}
  --password PASS         SSH password. Prefer REMOTE_PASSWORD=... to avoid shell history.
  --node-interface IFACE  Interface used for Kubernetes node IPs. Default: ${NODE_INTERFACE}
  --k8s-version VERSION   Kubernetes version. Default: ${K8S_VERSION}
  --pod-cidr CIDR         Pod CIDR. Default: ${POD_CIDR}
  --service-cidr CIDR     Service CIDR. Default: ${SERVICE_CIDR}
  --partition NAME        slurm-bridge partition annotation for Slurm-managed workers. Default: ${PARTITION}
  --kubeconfig PATH       Write admin kubeconfig locally after init.
  --skip-cni              Do not install Calico.
  --disable-containerd-nri
                          Do not enable containerd NRI during node preparation.
  --feature-gates GATES   Kubernetes component feature gates. Default: ${K8S_FEATURE_GATES}
  --dra-driver-cpu        Install kubernetes-sigs/dra-driver-cpu after the cluster is Ready.
                          The driver is scoped to Slurm-managed workers and defaults to individual CPU mode.
  --reset                 Run kubeadm reset and clear CNI state before init/join.
  -h, --help              Show this help.

Examples:
  REMOTE_PASSWORD=3tango $(basename "$0") \\
    --control-plane 10.237.153.215 \\
    --worker 10.237.153.213 \\
    --slurm-worker 10.237.153.203 \\
    --slurm-worker 10.237.153.204
  REMOTE_PASSWORD=3tango $(basename "$0") --reset \\
    --control-plane 10.237.153.215 \\
    --worker 10.237.153.213 \\
    --slurm-worker 10.237.153.203 \\
    --slurm-worker 10.237.153.204
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--control-plane)
		CONTROL_PLANE_IP="$2"
		shift 2
		;;
	--control-plane=*)
		CONTROL_PLANE_IP="${1#*=}"
		shift
		;;
	--worker)
		WORKER_IPS+=("$2")
		shift 2
		;;
	--worker=*)
		WORKER_IPS+=("${1#*=}")
		shift
		;;
	--slurm-worker)
		SLURM_WORKER_IPS+=("$2")
		shift 2
		;;
	--slurm-worker=*)
		SLURM_WORKER_IPS+=("${1#*=}")
		shift
		;;
	--normal-worker)
		WORKER_IPS+=("$2")
		shift 2
		;;
	--normal-worker=*)
		WORKER_IPS+=("${1#*=}")
		shift
		;;
	--user)
		REMOTE_USER="$2"
		shift 2
		;;
	--user=*)
		REMOTE_USER="${1#*=}"
		shift
		;;
	--password)
		REMOTE_PASSWORD="$2"
		shift 2
		;;
	--password=*)
		REMOTE_PASSWORD="${1#*=}"
		shift
		;;
	--node-interface)
		NODE_INTERFACE="$2"
		shift 2
		;;
	--node-interface=*)
		NODE_INTERFACE="${1#*=}"
		shift
		;;
	--k8s-version)
		K8S_VERSION="$2"
		shift 2
		;;
	--k8s-version=*)
		K8S_VERSION="${1#*=}"
		shift
		;;
	--pod-cidr)
		POD_CIDR="$2"
		shift 2
		;;
	--pod-cidr=*)
		POD_CIDR="${1#*=}"
		shift
		;;
	--service-cidr)
		SERVICE_CIDR="$2"
		shift 2
		;;
	--service-cidr=*)
		SERVICE_CIDR="${1#*=}"
		shift
		;;
	--partition)
		PARTITION="$2"
		shift 2
		;;
	--partition=*)
		PARTITION="${1#*=}"
		shift
		;;
	--kubeconfig)
		KUBECONFIG_OUT="$2"
		shift 2
		;;
	--kubeconfig=*)
		KUBECONFIG_OUT="${1#*=}"
		shift
		;;
	--skip-cni)
		SKIP_CNI=true
		shift
		;;
	--disable-containerd-nri)
		ENABLE_CONTAINERD_NRI=false
		shift
		;;
	--feature-gates)
		K8S_FEATURE_GATES="$2"
		shift 2
		;;
	--feature-gates=*)
		K8S_FEATURE_GATES="${1#*=}"
		shift
		;;
	--dra-driver-cpu)
		INSTALL_DRA_DRIVER_CPU=true
		shift
		;;
	--reset)
		RESET=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		fail "unknown option: $1"
		;;
	esac
done

if [[ -z "$CONTROL_PLANE_IP" ]]; then
	fail "--control-plane IP is required"
fi
if [[ $((${#WORKER_IPS[@]} + ${#SLURM_WORKER_IPS[@]})) -eq 0 ]]; then
	fail "at least one --worker or --slurm-worker IP is required"
fi
if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
	log "warning: no untainted --worker nodes supplied; infrastructure pods may remain Pending on tainted nodes"
fi

if [[ -z "$KUBECONFIG_OUT" ]]; then
	KUBECONFIG_OUT="$PWD/kubeadm-${CLUSTER_NAME}.conf"
fi

K8S_MINOR="v$(printf '%s' "$K8S_VERSION" | cut -d. -f1,2 | sed 's/^v//')"
CALICO_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

function require_command() {
	local name="$1"
	command -v "$name" >/dev/null 2>&1 || fail "'$name' is required"
}

require_command ssh
require_command scp
require_command expect
if $INSTALL_DRA_DRIVER_CPU; then
	require_command kubectl
	require_command curl
fi

if [[ -z "$REMOTE_PASSWORD" ]]; then
	fail "REMOTE_PASSWORD or --password is required because this script uses password SSH auth"
fi

function remote() {
	local ip="$1"
	shift

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

function clean_remote_scalar() {
	tr -d '\r' | awk 'NF { line = $0 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line }'
}

function require_ip_address() {
	local name="$1"
	local value="$2"

	if [[ ! "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ! "$value" =~ : ]]; then
		fail "${name} must be an IPv4 or IPv6 address, got: '${value}'"
	fi
}

function node_name_for() {
	local ip="$1"
	remote "$ip" "hostname -s | tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//'" |
		clean_remote_scalar
}

function node_ip_for() {
	local ip="$1"
	remote "$ip" "ip -4 -o addr show dev '${NODE_INTERFACE}' | awk '{print \$4}' | cut -d/ -f1 | head -n1" |
		clean_remote_scalar
}

function prepare_node() {
	local ip="$1"
	local prepare_script

	log "preparing ${ip}"
	prepare_script="$(mktemp)"
	cat >"$prepare_script" <<'REMOTE'
set -euo pipefail

if ! ip -4 -o addr show dev "$NODE_INTERFACE" >/dev/null 2>&1; then
	echo "interface ${NODE_INTERFACE} does not exist or has no IPv4 address" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg

install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
	gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF

apt-get update
apt-get install -y \
	"kubelet=${K8S_VERSION#v}-1.1" \
	"kubeadm=${K8S_VERSION#v}-1.1" \
	"kubectl=${K8S_VERSION#v}-1.1"
apt-mark hold kubelet kubeadm kubectl

swapoff -a || true
sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab || true

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

function configure_containerd() {
	local config="/etc/containerd/config.toml"
	local backup
	local nri_disable="true"

	mkdir -p /etc/containerd
	if [[ "$ENABLE_CONTAINERD_NRI" == "true" ]]; then
		nri_disable="false"
	fi
	if [[ -e "$config" ]]; then
		backup="/etc/containerd/config.toml.$(date +%Y%m%d%H%M%S).bak"
		cp "$config" "$backup"
		echo "saved existing containerd config to ${backup}"
	fi

	# These VMs are dedicated kubeadm nodes. Render the containerd config
	# deterministically instead of preserving Docker's CRI-disabled defaults.
	cat >"$config" <<EOF
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"
oom_score = 0
disabled_plugins = []
required_plugins = []

[grpc]
  address = "/run/containerd/containerd.sock"
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216
  uid = 0

[plugins]

  [plugins."io.containerd.grpc.v1.cri"]
    device_ownership_from_security_context = false
    disable_apparmor = false
    disable_cgroup = false
    disable_hugetlb_controller = true
    disable_proc_mount = false
    disable_tcp_service = true
    enable_cdi = true
    enable_selinux = false
    enable_tls_streaming = false
    enable_unprivileged_icmp = false
    enable_unprivileged_ports = false
    ignore_image_defined_volumes = false
    max_concurrent_downloads = 3
    max_container_log_line_size = 16384
    netns_mounts_under_state_dir = false
    restrict_oom_score_adj = false
    sandbox_image = "registry.k8s.io/pause:3.10"
    selinux_category_range = 1024
    stats_collect_period = 10
    stream_idle_timeout = "4h0m0s"
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    systemd_cgroup = false
    tolerate_missing_hugetlb_controller = true
    unset_seccomp_profile = ""
    cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]

    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
      max_conf_num = 1
      setup_serially = false

    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      disable_snapshot_annotations = true
      discard_unpacked_layers = false
      ignore_blockio_not_enabled_errors = false
      ignore_rdt_not_enabled_errors = false
      no_pivot = false
      snapshotter = "overlayfs"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
        base_runtime_spec = ""
        container_annotations = []
        pod_annotations = []
        privileged_without_host_devices = false
        runtime_type = "io.containerd.runc.v2"
        sandbox_mode = "podsandbox"
        snapshotter = ""

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
          BinaryName = ""
          CriuImagePath = ""
          CriuPath = ""
          CriuWorkPath = ""
          IoGid = 0
          IoUid = 0
          NoNewKeyring = false
          NoPivotRoot = false
          Root = ""
          ShimCgroup = ""
          SystemdCgroup = true

    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = ""

  [plugins."io.containerd.nri.v1.nri"]
    disable = ${nri_disable}
    disable_connections = false
    plugin_config_path = "/etc/nri/conf.d"
    plugin_path = "/opt/nri/plugins"
    plugin_registration_timeout = "5s"
    plugin_request_timeout = "2s"
    socket_path = "/var/run/nri/nri.sock"
EOF
}

mkdir -p /etc/containerd
mkdir -p /etc/cdi /var/run/cdi
if [[ "$ENABLE_CONTAINERD_NRI" == "true" ]]; then
	mkdir -p /etc/nri/conf.d /opt/nri/plugins /var/run/nri
fi
configure_containerd

systemctl enable --now containerd
systemctl restart containerd

if ! ctr plugins ls | awk '$1 == "io.containerd.grpc.v1" && $2 == "cri" && $4 == "ok" { found = 1 } END { exit !found }'; then
	echo "containerd CRI plugin is not enabled after restart" >&2
	exit 1
fi

if [[ "$ENABLE_CONTAINERD_NRI" == "true" ]]; then
	if ! ctr plugins ls | awk '$1 == "io.containerd.nri.v1" && $2 == "nri" && $4 == "ok" { found = 1 } END { exit !found }'; then
		echo "containerd NRI plugin is not enabled after restart" >&2
		exit 1
	fi
	for _ in {1..20}; do
		if [[ -S /var/run/nri/nri.sock ]]; then
			break
		fi
		sleep 0.5
	done
	if [[ ! -S /var/run/nri/nri.sock ]]; then
		echo "containerd NRI socket was not created after restart" >&2
		exit 1
	fi
fi
REMOTE
	scp_to_remote "$ip" "$prepare_script" /tmp/kubeadm-vm-prepare.sh
	rm -f "$prepare_script"
	remote "$ip" "NODE_INTERFACE='${NODE_INTERFACE}' K8S_VERSION='${K8S_VERSION}' K8S_MINOR='${K8S_MINOR}' ENABLE_CONTAINERD_NRI='${ENABLE_CONTAINERD_NRI}' bash /tmp/kubeadm-vm-prepare.sh"
}

function reset_node() {
	local ip="$1"

	log "resetting kubeadm state on ${ip}"
	remote "$ip" "kubeadm reset -f || true; rm -rf /etc/cni/net.d /var/lib/cni /run/cni-ipam-state /var/lib/kubelet/pki"
}

function init_control_plane() {
	local cp_name="$1"
	local cp_node_ip="$2"
	local init_config

	if remote "$CONTROL_PLANE_IP" "test -s /etc/kubernetes/admin.conf"; then
		log "control plane already initialized on ${CONTROL_PLANE_IP}"
		return
	fi

	log "initializing control plane ${cp_name} at ${cp_node_ip}"
	init_config="$(mktemp)"
	cat >"$init_config" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${cp_node_ip}"
  bindPort: 6443
nodeRegistration:
  name: "${cp_name}"
  criSocket: "unix:///run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: "node-ip"
      value: "${cp_node_ip}"
    - name: "feature-gates"
      value: "${K8S_FEATURE_GATES}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: "${CLUSTER_NAME}"
kubernetesVersion: "${K8S_VERSION}"
controlPlaneEndpoint: "${cp_node_ip}:6443"
networking:
  dnsDomain: "cluster.local"
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  certSANs:
    - "${cp_node_ip}"
    - "${CONTROL_PLANE_IP}"
    - "${cp_name}"
  extraArgs:
    - name: "feature-gates"
      value: "${K8S_FEATURE_GATES}"
controllerManager:
  extraArgs:
    - name: "feature-gates"
      value: "${K8S_FEATURE_GATES}"
scheduler:
  extraArgs:
    - name: "feature-gates"
      value: "${K8S_FEATURE_GATES}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
failSwapOn: false
EOF
	scp_to_remote "$CONTROL_PLANE_IP" "$init_config" /tmp/kubeadm-init.yaml
	rm -f "$init_config"
	remote "$CONTROL_PLANE_IP" "kubeadm init --config /tmp/kubeadm-init.yaml"
}

function install_calico() {
	if $SKIP_CNI; then
		log "skipping CNI install"
		return
	fi

	log "installing Calico ${CALICO_VERSION}"
	remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f '${CALICO_MANIFEST}'"
	remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=interface='${NODE_INTERFACE}' CALICO_IPV4POOL_CIDR='${POD_CIDR}'"
}

function join_worker() {
	local ip="$1"
	local node_name="$2"
	local node_ip="$3"
	local slurm_managed="$4"
	local join_config
	local join_command
	local token
	local ca_hash
	local labels="scheduler.slinky.slurm.net/slurm-bridge=worker,scheduler.slinky.slurm.net/external-node=true"

	if remote "$ip" "test -s /etc/kubernetes/kubelet.conf"; then
		log "${ip} already has kubelet.conf; skipping kubeadm join"
	else
		log "joining worker ${node_name} at ${node_ip}"
		join_command="$(remote "$CONTROL_PLANE_IP" "kubeadm token create --print-join-command --ttl 2h")"
		token="$(awk '{for (i=1; i<=NF; i++) if ($i=="--token") {print $(i+1); exit}}' <<<"$join_command")"
		ca_hash="$(awk '{for (i=1; i<=NF; i++) if ($i=="--discovery-token-ca-cert-hash") {print $(i+1); exit}}' <<<"$join_command")"
		if [[ -z "$token" || -z "$ca_hash" ]]; then
			fail "could not parse kubeadm join command: ${join_command}"
		fi
		join_config="$(mktemp)"
		cat >"$join_config" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CONTROL_PLANE_NODE_IP}:6443"
    token: "${token}"
    caCertHashes:
      - "${ca_hash}"
nodeRegistration:
  name: "${node_name}"
  criSocket: "unix:///run/containerd/containerd.sock"
EOF
		if [[ "$slurm_managed" == "true" ]]; then
			cat >>"$join_config" <<EOF
  taints:
    - key: "slinky.slurm.net/managed-node"
      value: "slurm-bridge-scheduler"
      effect: "NoExecute"
EOF
		fi
		cat >>"$join_config" <<EOF
  kubeletExtraArgs:
    - name: "node-ip"
      value: "${node_ip}"
    - name: "feature-gates"
      value: "${K8S_FEATURE_GATES}"
EOF
		if [[ "$slurm_managed" == "true" ]]; then
			cat >>"$join_config" <<EOF
    - name: "node-labels"
      value: "${labels}"
EOF
		fi
		scp_to_remote "$ip" "$join_config" /tmp/kubeadm-join.yaml
		rm -f "$join_config"
		remote "$ip" "kubeadm join --config /tmp/kubeadm-join.yaml"
		log "kubeadm join completed for ${node_name}"
	fi

	log "waiting for Kubernetes node object ${node_name}"
	remote "$CONTROL_PLANE_IP" "for i in \$(seq 1 60); do KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=10s get node '${node_name}' >/dev/null 2>&1 && exit 0; sleep 1; done; KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=10s get node '${node_name}'"
	log "Kubernetes node object ${node_name} exists"
}

function apply_node_metadata() {
	local node_name="$1"
	local slurm_managed="$2"

	if [[ "$slurm_managed" == "true" ]]; then
		log "labeling Slurm-managed node ${node_name}"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s label node '${node_name}' scheduler.slinky.slurm.net/slurm-bridge=worker scheduler.slinky.slurm.net/external-node=true --overwrite"
		log "tainting Slurm-managed node ${node_name}"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s taint node '${node_name}' slinky.slurm.net/managed-node=slurm-bridge-scheduler:NoExecute --overwrite"
		log "annotating Slurm-managed node ${node_name}"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s annotate node '${node_name}' scheduler.slinky.slurm.net/external-node-partitions='${PARTITION}' --overwrite"
	else
		log "clearing Slurm-managed metadata from untainted worker ${node_name}"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s taint node '${node_name}' slinky.slurm.net/managed-node- || true"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s label node '${node_name}' scheduler.slinky.slurm.net/slurm-bridge- scheduler.slinky.slurm.net/external-node- || true"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s annotate node '${node_name}' scheduler.slinky.slurm.net/external-node-partitions- || true"
	fi
}

function write_kubeconfig() {
	local kubeconfig_dir

	log "writing kubeconfig to ${KUBECONFIG_OUT}"
	kubeconfig_dir="$(dirname "$KUBECONFIG_OUT")"
	if [[ ! -d "$kubeconfig_dir" ]]; then
		mkdir -p "$kubeconfig_dir"
	fi
	remote "$CONTROL_PLANE_IP" "cat /etc/kubernetes/admin.conf" |
		sed "s#server: https://.*:6443#server: https://${CONTROL_PLANE_NODE_IP}:6443#" \
			>"$KUBECONFIG_OUT"
	chmod 0600 "$KUBECONFIG_OUT"
}

function install_dra_driver_cpu() {
	log "installing dra-driver-cpu into ${KUBECONFIG_OUT}"
	KUBECONFIG="$KUBECONFIG_OUT" "${SCRIPT_DIR}/dra-driver-cpu.sh"
}

all_ips=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}" "${SLURM_WORKER_IPS[@]}")

for ip in "${all_ips[@]}"; do
	if $RESET; then
		reset_node "$ip"
	fi
	prepare_node "$ip"
done

CONTROL_PLANE_NODE_NAME="$(node_name_for "$CONTROL_PLANE_IP")"
CONTROL_PLANE_NODE_IP="$(node_ip_for "$CONTROL_PLANE_IP")"
if [[ -z "$CONTROL_PLANE_NODE_NAME" || -z "$CONTROL_PLANE_NODE_IP" ]]; then
	fail "could not determine control-plane node name/IP"
fi
require_ip_address "control-plane node IP" "$CONTROL_PLANE_NODE_IP"

init_control_plane "$CONTROL_PLANE_NODE_NAME" "$CONTROL_PLANE_NODE_IP"
install_calico

for ip in "${WORKER_IPS[@]}"; do
	node_name="$(node_name_for "$ip")"
	node_ip="$(node_ip_for "$ip")"
	if [[ -z "$node_name" || -z "$node_ip" ]]; then
		fail "could not determine node name/IP for ${ip}"
	fi
	require_ip_address "worker node IP for ${ip}" "$node_ip"
	join_worker "$ip" "$node_name" "$node_ip" false
done

for ip in "${SLURM_WORKER_IPS[@]}"; do
	node_name="$(node_name_for "$ip")"
	node_ip="$(node_ip_for "$ip")"
	if [[ -z "$node_name" || -z "$node_ip" ]]; then
		fail "could not determine node name/IP for ${ip}"
	fi
	require_ip_address "Slurm-managed worker node IP for ${ip}" "$node_ip"
	join_worker "$ip" "$node_name" "$node_ip" true
done

for ip in "${WORKER_IPS[@]}"; do
	node_name="$(node_name_for "$ip")"
	apply_node_metadata "$node_name" false
done

for ip in "${SLURM_WORKER_IPS[@]}"; do
	node_name="$(node_name_for "$ip")"
	apply_node_metadata "$node_name" true
done

log "waiting for all Kubernetes nodes to become Ready"
remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=30s wait --for=condition=Ready nodes --all --timeout=600s"

write_kubeconfig
remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"

if $INSTALL_DRA_DRIVER_CPU; then
	install_dra_driver_cpu
fi
