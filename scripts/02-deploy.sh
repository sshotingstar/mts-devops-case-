#!/usr/bin/env bash
# Развертывание решения в текущий кластер (KUBECONFIG): Envoy Gateway, Prometheus, приложение,
# ресурсы Gateway API, Filebeat + Elasticsearch. Идемпотентен (helm upgrade --install, kubectl apply).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source versions.env

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
need() { command -v "$1" >/dev/null || { echo "Не найден $1 (выполните make node)"; exit 1; }; }
need kubectl; need helm; need openssl

kubectl cluster-info >/dev/null

log "1/6 Envoy Gateway ${ENVOY_GATEWAY_VERSION} (вместе с CRD Gateway API)"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  -n envoy-gateway-system --create-namespace --wait --timeout 10m
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=900s

log "2/6 kube-prometheus-stack"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -hex 12)"
fi
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update prometheus-community >/dev/null
KPS_VERSION_ARGS=()
[[ -n "${KPS_CHART_VERSION:-}" ]] && KPS_VERSION_ARGS=(--version "${KPS_CHART_VERSION}")
helm upgrade --install kps prometheus-community/kube-prometheus-stack "${KPS_VERSION_ARGS[@]}" \
  -n monitoring -f monitoring/values.yaml --wait --timeout 15m

log "3/6 Демо-приложение (namespace demo)"
kubectl apply -k app/

log "4/6 TLS-секрет и ресурсы Gateway API"
if ! kubectl -n demo get secret hello-tls >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj "/CN=hello.local" -addext "subjectAltName=DNS:hello.local" \
    -keyout "${TMP}/tls.key" -out "${TMP}/tls.crt" 2>/dev/null
  kubectl -n demo create secret tls hello-tls --cert="${TMP}/tls.crt" --key="${TMP}/tls.key"
  rm -rf "${TMP}"
fi
kubectl apply -k gateway/

log "5/6 Метрики: ServiceMonitor / PodMonitor / PrometheusRule"
kubectl apply -k monitoring/

log "6/6 Логирование: Elasticsearch + Filebeat"
kubectl apply -k logging/

log "Ожидание готовности"
kubectl -n demo rollout status deployment/hello-v1 --timeout=900s
kubectl -n demo rollout status deployment/hello-v2 --timeout=900s
kubectl -n demo wait gateway/web --for=condition=Programmed --timeout=900s
kubectl -n logging rollout status deployment/elasticsearch --timeout=900s
kubectl -n logging rollout status daemonset/filebeat --timeout=900s

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
SVC="$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=web,gateway.envoyproxy.io/owning-gateway-namespace=demo \
  -o jsonpath='{.items[0].metadata.name}')"
HTTP_PORT="$(kubectl -n envoy-gateway-system get svc "${SVC}" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
HTTPS_PORT="$(kubectl -n envoy-gateway-system get svc "${SVC}" -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')"

cat <<EOF

================ Развертывание завершено ================
Приложение (HTTP):  curl -H 'Host: hello.local' http://${NODE_IP}:${HTTP_PORT}/
Приложение (HTTPS): curl -k --resolve hello.local:${HTTPS_PORT}:${NODE_IP} https://hello.local:${HTTPS_PORT}/
Grafana:            http://${NODE_IP}:30300  (логин admin, пароль:
                    kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
Prometheus:         kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
Проверка всего:     make check
=========================================================
EOF
