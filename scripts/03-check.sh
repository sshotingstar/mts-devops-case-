#!/usr/bin/env bash
# Smoke-проверка всех обязательных компонентов и дополнительных возможностей.
# Код возврата != 0, если хотя бы одна обязательная проверка не прошла.
set -uo pipefail

GREEN='\033[1;32m'; RED='\033[1;31m'; BLUE='\033[1;34m'; NC='\033[0m'
FAILED=0
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILED=1; }
step() { echo -e "\n${BLUE}==> $*${NC}"; }

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
SVC="$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=web,gateway.envoyproxy.io/owning-gateway-namespace=demo \
  -o jsonpath='{.items[0].metadata.name}')"
HTTP_PORT="$(kubectl -n envoy-gateway-system get svc "${SVC}" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
HTTPS_PORT="$(kubectl -n envoy-gateway-system get svc "${SVC}" -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')"
URL="http://${NODE_IP}:${HTTP_PORT}"
echo "Gateway: ${URL} (HTTPS :${HTTPS_PORT}), сервис ${SVC}"

step "1. Ресурсы Gateway API"
kubectl get gatewayclass envoy
kubectl -n demo get gateway web
kubectl -n demo get httproute

step "2. Приложение через Gateway API"
BODY="$(curl -s --max-time 5 -H 'Host: hello.local' "${URL}/")"
echo "  curl -H 'Host: hello.local' ${URL}/  ->  ${BODY}"
[[ "${BODY}" == *"Hello World!"* ]] && pass "Приложение отвечает Hello World! через Gateway" || fail "Нет ответа Hello World!"

BODY="$(curl -s --max-time 5 -H 'Host: hello.local' "${URL}/v2")"
[[ "${BODY}" == *"version: v2"* ]] && pass "Маршрут по path /v2 -> hello-v2" || fail "Маршрут /v2: ${BODY}"

BODY="$(curl -s --max-time 5 -H 'Host: v2.hello.local' "${URL}/")"
[[ "${BODY}" == *"version: v2"* ]] && pass "Маршрут по hostname v2.hello.local -> hello-v2" || fail "Маршрут по hostname: ${BODY}"

BODY="$(curl -sk --max-time 5 --resolve "hello.local:${HTTPS_PORT}:${NODE_IP}" "https://hello.local:${HTTPS_PORT}/")"
[[ "${BODY}" == *"Hello World!"* ]] && pass "HTTPS (TLS-терминация на Gateway)" || fail "HTTPS: ${BODY}"

V1=0; V2=0
for _ in $(seq 1 50); do
  B="$(curl -s --max-time 5 -H 'Host: hello.local' "${URL}/canary")"
  [[ "${B}" == *"version: v1"* ]] && V1=$((V1+1))
  [[ "${B}" == *"version: v2"* ]] && V2=$((V2+1))
done
echo "  /canary: v1=${V1}, v2=${V2} из 50 (ожидается ~80/20)"
(( V1 > 0 && V2 > 0 )) && pass "Traffic splitting 80/20" || fail "Traffic splitting не работает"

step "3. Мониторинг (Prometheus)"
prom() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/$1"
}
for _ in $(seq 1 12); do
  UP="$(prom 'query?query=sum(nginx_up)' 2>/dev/null | jq -r '.data.result[0].value[1] // "0"')"
  [[ "${UP}" != "0" && -n "${UP}" ]] && break
  sleep 5
done
TARGETS="$(prom 'targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.namespace=="demo") | "\(.labels.job) \(.labels.pod) \(.health)"')"
while IFS= read -r t; do echo "  target: ${t}"; done <<< "${TARGETS}"
echo "${TARGETS}" | grep -q ' up$' && pass "Targets приложения в состоянии UP" || fail "Нет UP targets приложения"
[[ "${UP:-0}" != "0" ]] && pass "Query sum(nginx_up) = ${UP}" || fail "Query nginx_up пустой"
REQ="$(prom 'query?query=sum(nginx_http_requests_total)' | jq -r '.data.result[0].value[1] // "нет данных"')"
echo "  sum(nginx_http_requests_total) = ${REQ}"
ENVOY="$(prom 'query?query=sum%20by%20(envoy_response_code_class)(envoy_cluster_upstream_rq_xx)' \
  | jq -r '.data.result[] | "\(.metric.envoy_response_code_class)xx=\(.value[1])"' | tr '\n' ' ')"
[[ -n "${ENVOY}" ]] && pass "HTTP-метрики Envoy по классам кодов: ${ENVOY}" || echo "  (доп.) метрики Envoy пока не получены"

step "4. Логирование (Filebeat -> Elasticsearch)"
TOKEN="logcheck$(date +%s)"
curl -s -o /dev/null -H 'Host: hello.local' "${URL}/${TOKEN}"
echo "  Отправлен запрос ${URL}/${TOKEN}, ищем его в Elasticsearch..."
HITS=0
for _ in $(seq 1 24); do
  RES="$(kubectl get --raw "/api/v1/namespaces/logging/services/elasticsearch:9200/proxy/filebeat-*/_search?q=${TOKEN}&size=1" 2>/dev/null)"
  HITS="$(echo "${RES}" | jq -r '.hits.total.value // 0' 2>/dev/null || echo 0)"
  (( HITS > 0 )) && break
  sleep 5
done
if (( HITS > 0 )); then
  echo "${RES}" | jq '.hits.hits[0]._source | {"@timestamp", pod: .kubernetes.pod.name, nginx: .nginx}'
  pass "Запись access-лога найдена в Elasticsearch"
else
  fail "Запись access-лога не найдена за 2 минуты"
fi

echo
if (( FAILED == 0 )); then echo -e "${GREEN}ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ${NC}"; else echo -e "${RED}ЕСТЬ ОШИБКИ${NC}"; fi
exit "${FAILED}"
