#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script currently supports Debian/Ubuntu (apt-get required)." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

DOWNLOAD_DIR="${DOWNLOAD_DIR:-/var/tmp}"
CURL_OPTS="${CURL_OPTS:--fsSL --retry 5 --retry-delay 2 --retry-connrefused}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
GITHUB_BASE="${GITHUB_BASE:-https://github.com}"
GITHUB_RAW_BASE="${GITHUB_RAW_BASE:-https://raw.githubusercontent.com}"

log "Installing base dependencies and Kubernetes prerequisites"
apt-get update -y
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  iproute2 \
  iptables \
  ethtool \
  socat \
  conntrack \
  ebtables \
  bash-completion \
  rdma-core \
  infiniband-diags \
  perftest \
  ibverbs-utils \
  mstflint

log "Disabling swap"
swapoff -a || true
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

log "Configuring kernel modules and sysctl for Kubernetes"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

log "Installing containerd 2.x, runc, and CNI plugins"
mkdir -p "${DOWNLOAD_DIR}"

if [[ -n "${CONTAINERD_TAR_PATH:-}" ]]; then
  if [[ ! -s "${CONTAINERD_TAR_PATH}" ]]; then
    echo "CONTAINERD_TAR_PATH is set but file not found: ${CONTAINERD_TAR_PATH}" >&2
    exit 1
  fi
else
  if [[ -z "${CONTAINERD_TAG:-}" ]]; then
    CONTAINERD_TAG="$(curl ${CURL_OPTS} "${GITHUB_API_BASE}/repos/containerd/containerd/releases/latest" | \
      sed -n 's/.*"tag_name": "\(v[^"]*\)".*/\1/p' | head -n1)"
    if [[ -z "${CONTAINERD_TAG}" || "${CONTAINERD_TAG}" != v2.* ]]; then
      CONTAINERD_TAG="v2.0.1"
    fi
  fi

  CONTAINERD_TAR="containerd-${CONTAINERD_TAG#v}-linux-amd64.tar.gz"
  CONTAINERD_TAR_PATH="${DOWNLOAD_DIR}/${CONTAINERD_TAR}"
  if [[ ! -s "${CONTAINERD_TAR_PATH}" ]]; then
    curl ${CURL_OPTS} -o "${CONTAINERD_TAR_PATH}" \
      "${GITHUB_BASE}/containerd/containerd/releases/download/${CONTAINERD_TAG}/${CONTAINERD_TAR}"
  fi
fi
tar -C /usr/local -xzf "${CONTAINERD_TAR_PATH}"

mkdir -p /usr/local/lib/systemd/system
curl ${CURL_OPTS} -o /usr/local/lib/systemd/system/containerd.service \
  "${GITHUB_RAW_BASE}/containerd/containerd/main/containerd.service"
systemctl daemon-reload
systemctl enable --now containerd

if [[ -n "${RUNC_BIN_PATH:-}" ]]; then
  if [[ ! -s "${RUNC_BIN_PATH}" ]]; then
    echo "RUNC_BIN_PATH is set but file not found: ${RUNC_BIN_PATH}" >&2
    exit 1
  fi
else
  if [[ -z "${RUNC_VERSION:-}" ]]; then
    RUNC_VERSION="$(curl ${CURL_OPTS} "${GITHUB_API_BASE}/repos/opencontainers/runc/releases/latest" | \
      sed -n 's/.*"tag_name": "\(v[^"]*\)".*/\1/p' | head -n1)"
  fi
  RUNC_BIN_PATH="${DOWNLOAD_DIR}/runc.amd64"
  if [[ ! -s "${RUNC_BIN_PATH}" ]]; then
    curl ${CURL_OPTS} -o "${RUNC_BIN_PATH}" \
      "${GITHUB_BASE}/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64"
  fi
fi
install -m 0755 "${RUNC_BIN_PATH}" /usr/local/sbin/runc
chmod +x /usr/local/sbin/runc

mkdir -p /opt/cni/bin
if [[ -n "${CNI_TGZ_PATH:-}" ]]; then
  if [[ ! -s "${CNI_TGZ_PATH}" ]]; then
    echo "CNI_TGZ_PATH is set but file not found: ${CNI_TGZ_PATH}" >&2
    exit 1
  fi
else
  if [[ -z "${CNI_VERSION:-}" ]]; then
    CNI_VERSION="$(curl ${CURL_OPTS} "${GITHUB_API_BASE}/repos/containernetworking/plugins/releases/latest" | \
      sed -n 's/.*"tag_name": "\(v[^"]*\)".*/\1/p' | head -n1)"
  fi
  CNI_TGZ="cni-plugins-linux-amd64-${CNI_VERSION#v}.tgz"
  CNI_TGZ_PATH="${DOWNLOAD_DIR}/${CNI_TGZ}"
  if [[ ! -s "${CNI_TGZ_PATH}" ]]; then
    curl ${CURL_OPTS} -o "${CNI_TGZ_PATH}" \
      "${GITHUB_BASE}/containernetworking/plugins/releases/download/${CNI_VERSION}/${CNI_TGZ}"
  fi
fi
tar -C /opt/cni/bin -xzf "${CNI_TGZ_PATH}"

log "Configuring containerd to use systemd cgroups"
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/^\s*SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

log "Installing latest Kubernetes packages (non-snap)"
K8S_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
K8S_MINOR="$(echo "${K8S_VERSION}" | sed -E 's/^v([0-9]+\.[0-9]+)\..*$/\1/')"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
  gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

log "Installing NVIDIA drivers and container toolkit (Ubuntu)"
if command -v ubuntu-drivers >/dev/null 2>&1; then
  ubuntu-drivers autoinstall || true
  distribution=$(. /etc/os-release; echo "${ID}${VERSION_ID}")
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  repo_ok=false
  for dist_try in "${distribution}" "ubuntu24.04" "ubuntu22.04" "ubuntu20.04"; do
    if curl -fsSL "https://nvidia.github.io/libnvidia-container/${dist_try}/libnvidia-container.list" | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
      tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null; then
      repo_ok=true
      break
    fi
  done

  if [[ "${repo_ok}" == "true" ]]; then
    apt-get update -y
    apt-get install -y \
      nvidia-driver-580 \
      nvidia-utils-580 \
      nvidia-container-toolkit
    if command -v nvidia-ctk >/dev/null 2>&1; then
      nvidia-ctk runtime configure --runtime=containerd
      systemctl restart containerd
    fi
  else
    log "Skipping NVIDIA container toolkit repo (no matching distro entry)."
  fi
else
  log "Skipping NVIDIA driver install (ubuntu-drivers not found)"
fi

log "Done. Reboot recommended if NVIDIA drivers were installed."

if [[ "${VERIFY_TOOLS:-1}" == "1" ]]; then
  log "Verification checks (best-effort)"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L || true
  else
    echo "nvidia-smi: missing"
  fi

  if command -v rdma >/dev/null 2>&1; then
    rdma link show || true
    rdma dev show || true
  else
    echo "rdma: missing"
  fi

  if command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devinfo -l || true
  else
    echo "ibv_devinfo: missing"
  fi
fi
