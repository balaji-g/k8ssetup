#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SSH_HOST:-}" || -z "${SSH_USER:-}" || -z "${SSH_PASS:-}" ]]; then
  echo "Usage: SSH_HOST=... SSH_USER=... SSH_PASS=... $0 [OUTPUT_PATH]" >&2
  exit 1
fi

OUTPUT_PATH="${1:-/home/balaji/personal/metabalite/k8ssetup/kubeconfig}"

sshpass -p "${SSH_PASS}" ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "${SSH_USER}@${SSH_HOST}" "echo \"${SSH_PASS}\" | sudo -S cat /etc/kubernetes/admin.conf" \
  > "${OUTPUT_PATH}"

echo "Wrote kubeconfig to ${OUTPUT_PATH}"
