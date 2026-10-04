#!/usr/bin/env bash
# Удаление компонентов решения из кластера (сам кластер не трогаем; для него — make reset).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

kubectl delete -k logging/ --ignore-not-found
kubectl delete -k monitoring/ --ignore-not-found
kubectl delete -k gateway/ --ignore-not-found
kubectl delete -k app/ --ignore-not-found
helm uninstall kps -n monitoring 2>/dev/null || true
helm uninstall eg -n envoy-gateway-system 2>/dev/null || true
kubectl delete namespace monitoring envoy-gateway-system --ignore-not-found
