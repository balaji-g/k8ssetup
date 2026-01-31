#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

ROLE="${ROLE:-}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
JOIN_CMD="${JOIN_CMD:-}"

if [[ -z "${ROLE}" ]]; then
  echo "Set ROLE=control-plane or ROLE=worker." >&2
  exit 1
fi

if [[ "${ROLE}" != "control-plane" && "${ROLE}" != "worker" ]]; then
  echo "Invalid ROLE: ${ROLE}" >&2
  exit 1
fi

if [[ "${ROLE}" == "control-plane" && -z "${CONTROL_PLANE_IP}" ]]; then
  echo "CONTROL_PLANE_IP is required for control-plane role." >&2
  exit 1
fi

if [[ "${ROLE}" == "worker" && -z "${JOIN_CMD}" ]]; then
  echo "JOIN_CMD is required for worker role." >&2
  exit 1
fi

if ! command -v kubeadm >/dev/null 2>&1; then
  echo "kubeadm not found. Run the install script first." >&2
  exit 1
fi

if [[ "${ROLE}" == "control-plane" ]]; then
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log "Control plane already initialized; skipping kubeadm init"
  else
    log "Initializing control plane"
    kubeadm init --apiserver-advertise-address="${CONTROL_PLANE_IP}" --pod-network-cidr="${POD_CIDR}"
  fi

  log "Configuring kubeconfig"
  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    USER_GROUP="$(id -gn "${SUDO_USER}" 2>/dev/null || true)"
    if [[ -n "${USER_HOME}" ]]; then
      mkdir -p "${USER_HOME}/.kube"
      cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
      if [[ -n "${USER_GROUP}" ]]; then
        chown -R "${SUDO_USER}:${USER_GROUP}" "${USER_HOME}/.kube" || true
      else
        chown -R "${SUDO_USER}" "${USER_HOME}/.kube" || true
      fi
    fi
  fi

  export KUBECONFIG=/etc/kubernetes/admin.conf
  log "Installing Flannel CNI (${POD_CIDR})"
  kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

  log "Generating join command"
  JOIN_CMD_OUT="$(kubeadm token create --print-join-command)"
  echo "#!/usr/bin/env bash" > /var/tmp/kubeadm-join.sh
  echo "sudo ${JOIN_CMD_OUT}" >> /var/tmp/kubeadm-join.sh
  chmod +x /var/tmp/kubeadm-join.sh
  log "Join command saved to /var/tmp/kubeadm-join.sh"

  if [[ -n "${WORKER_NODES:-}" && -n "${SSH_USER:-}" && -n "${SSH_PASS:-}" ]]; then
    SUDO_PASS="${SUDO_PASS:-${SSH_PASS}}"
    log "Joining workers: ${WORKER_NODES}"
    for node in ${WORKER_NODES}; do
      sshpass -p "${SSH_PASS}" ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        "${SSH_USER}@${node}" \
        "echo \"${SUDO_PASS}\" | sudo -S ${JOIN_CMD_OUT}"
    done
  else
    log "To join workers, run: ${JOIN_CMD_OUT}"
  fi
fi

if [[ "${ROLE}" == "worker" ]]; then
  log "Joining worker to cluster"
  bash -lc "${JOIN_CMD}"
fi

log "Done"
