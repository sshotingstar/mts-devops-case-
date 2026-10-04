#!/usr/bin/env bash
# Инициализация одноузлового кластера kubeadm и установка CNI Flannel.
# Идемпотентен: если кластер уже инициализирован, kubeadm init пропускается.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log "kubeadm init (pod CIDR ${POD_CIDR})"
  sudo kubeadm init --pod-network-cidr="${POD_CIDR}"
else
  log "Кластер уже инициализирован, kubeadm init пропущен"
fi

log "kubeconfig для пользователя ${USER}"
mkdir -p "${HOME}/.kube"
sudo cp /etc/kubernetes/admin.conf "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

log "Разрешаем рабочую нагрузку на control-plane (одноузловой кластер)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

log "CNI Flannel ${FLANNEL_VERSION}"
kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"   || kubectl apply -f "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"

log "Ожидание готовности узла"
kubectl wait --for=condition=Ready nodes --all --timeout=900s
kubectl -n kube-system rollout status deployment/coredns --timeout=900s
kubectl get nodes -o wide
