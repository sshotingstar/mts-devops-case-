#!/usr/bin/env bash
# Подготовка узла Ubuntu 24.04 к kubeadm: ядро, containerd, kubeadm/kubelet/kubectl, helm.
# Скрипт идемпотентен: повторный запуск ничего не ломает.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }

. /etc/os-release
if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
  echo "ВНИМАНИЕ: решение тестировалось на Ubuntu 24.04, обнаружено ${PRETTY_NAME}"
fi

log "Отключение swap"
swapoff -a
sed -ri '/\sswap\s/s/^([^#])/#\1/' /etc/fstab

log "Модули ядра и sysctl"
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.max_map_count                    = 262144
fs.inotify.max_user_instances       = 512
fs.inotify.max_user_watches         = 524288
EOF
sysctl --system >/dev/null

log "Пакеты и containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg containerd openssl make jq

mkdir -p /etc/containerd
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
fi
systemctl enable containerd
systemctl restart containerd

log "kubeadm / kubelet / kubectl ${K8S_MINOR}"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

log "Helm ${HELM_VERSION}"
if ! helm version 2>/dev/null | grep -q "${HELM_VERSION}"; then
  ARCH="$(dpkg --print-architecture)"
  TMP="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar xz -C "${TMP}"
  install -m 0755 "${TMP}/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "${TMP}"
fi

log "Узел готов: $(kubeadm version -o short), $(containerd --version | awk '{print $3}'), helm $(helm version --short)"
