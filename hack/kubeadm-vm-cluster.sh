#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0
#
# Build a real kubeadm cluster on routable VMs.
#
# Nodes must be supplied explicitly. The script assumes all nodes are mutually
# routable on the interface passed by --node-interface.

set -euo pipefail

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
IB_WORKER_IPS=()
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
NODE_INTERFACE="${NODE_INTERFACE:-eth1}"
K8S_VERSION="${K8S_VERSION:-v1.35.0}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CLUSTER_NAME="${CLUSTER_NAME:-slurm-bridge-vm}"
PARTITION="${PARTITION:-slurm-bridge}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"
RESET=false
SKIP_CNI=false
KUBECONFIG_OUT="${KUBECONFIG_OUT:-}"

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
  --worker IP             IB worker VM IP. Required; may be repeated.
  --user USER             SSH user. Default: ${REMOTE_USER}
  --password PASS         SSH password. Prefer REMOTE_PASSWORD=... to avoid shell history.
  --node-interface IFACE  Interface used for Kubernetes node IPs. Default: ${NODE_INTERFACE}
  --k8s-version VERSION   Kubernetes version. Default: ${K8S_VERSION}
  --pod-cidr CIDR         Pod CIDR. Default: ${POD_CIDR}
  --service-cidr CIDR     Service CIDR. Default: ${SERVICE_CIDR}
  --partition NAME        slurm-bridge partition annotation for IB workers. Default: ${PARTITION}
  --kubeconfig PATH       Write admin kubeconfig locally after init.
  --skip-cni              Do not install Calico.
  --reset                 Run kubeadm reset and clear CNI state before init/join.
  -h, --help              Show this help.

Examples:
  REMOTE_PASSWORD=3tango $(basename "$0") \\
    --control-plane 10.237.153.215 \\
    --worker 10.237.153.203 \\
    --worker 10.237.153.204
  REMOTE_PASSWORD=3tango $(basename "$0") --reset \\
    --control-plane 10.237.153.215 \\
    --worker 10.237.153.203 \\
    --worker 10.237.153.204
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
		IB_WORKER_IPS+=("$2")
		shift 2
		;;
	--worker=*)
		IB_WORKER_IPS+=("${1#*=}")
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
if [[ ${#IB_WORKER_IPS[@]} -eq 0 ]]; then
	fail "at least one --worker IP is required"
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

mkdir -p /etc/containerd
if [[ ! -s /etc/containerd/config.toml ]] ||
	grep -Eq '^[[:space:]]*disabled_plugins[[:space:]]*=.*"cri"' /etc/containerd/config.toml; then
	if [[ -s /etc/containerd/config.toml ]]; then
		cp /etc/containerd/config.toml "/etc/containerd/config.toml.$(date +%Y%m%d%H%M%S).bak"
	fi
	containerd config default >/etc/containerd/config.toml
fi
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

if ! ctr plugins ls | awk '$1 == "io.containerd.grpc.v1" && $2 == "cri" && $4 == "ok" { found = 1 } END { exit !found }'; then
	echo "containerd CRI plugin is not enabled after restart" >&2
	exit 1
fi
REMOTE
	scp_to_remote "$ip" "$prepare_script" /tmp/kubeadm-vm-prepare.sh
	rm -f "$prepare_script"
	remote "$ip" "NODE_INTERFACE='${NODE_INTERFACE}' K8S_VERSION='${K8S_VERSION}' K8S_MINOR='${K8S_MINOR}' bash /tmp/kubeadm-vm-prepare.sh"
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
	fi

	remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready node/${node_name} --timeout=300s"
	if [[ "$slurm_managed" == "true" ]]; then
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node '${node_name}' scheduler.slinky.slurm.net/slurm-bridge=worker scheduler.slinky.slurm.net/external-node=true --overwrite"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint node '${node_name}' slinky.slurm.net/managed-node=slurm-bridge-scheduler:NoExecute --overwrite"
		remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl annotate node '${node_name}' scheduler.slinky.slurm.net/external-node-partitions='${PARTITION}' --overwrite"
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

all_ips=("$CONTROL_PLANE_IP" "${IB_WORKER_IPS[@]}")

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

for ip in "${IB_WORKER_IPS[@]}"; do
	node_name="$(node_name_for "$ip")"
	node_ip="$(node_ip_for "$ip")"
	if [[ -z "$node_name" || -z "$node_ip" ]]; then
		fail "could not determine node name/IP for ${ip}"
	fi
	require_ip_address "worker node IP for ${ip}" "$node_ip"
	join_worker "$ip" "$node_name" "$node_ip" true
done

write_kubeconfig
remote "$CONTROL_PLANE_IP" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"
