# MTS Engineer Hack — DevOps-кейс

Простое веб-приложение (nginx, «Hello World!») в Kubernetes на **kubeadm** с публикацией через
**Gateway API (Envoy Gateway)**, мониторингом **Prometheus** и сбором логов **Filebeat → Elasticsearch**.
Всё разворачивается на чистой **Ubuntu 24.04** одной командой `make all`.

## Быстрый старт

```bash
git clone https://github.com/sshotingstar/mts-devops-case-.git mts-devops-case
cd mts-devops-case
sudo apt-get update && sudo apt-get install -y make git
make all        # node -> cluster -> deploy -> check (~15–20 минут)
```

Если кластер уже есть (любой, в т.ч. kind/minikube) и `kubectl`/`helm` настроены:

```bash
make deploy && make check
```

## Архитектура

```
                         ┌──────────────── Kubernetes (kubeadm v1.34, 1 узел, Flannel) ─────────────────┐
 Пользователь            │                                                                                 │
 curl hello.local ──────►│ NodePort ─► Envoy Proxy  (Gateway "web": HTTP :80, HTTPS :443)                  │
                         │              │  HTTPRoute "hello":  /        -> Service hello-v1               │
                         │              │                      /v2      -> Service hello-v2               │
                         │              │                      /canary  -> 80% v1 / 20% v2               │
                         │              │  HTTPRoute "hello-v2-host": v2.hello.local -> hello-v2          │
                         │              ▼                                                                  │
                         │   ns demo:  nginx v1 (x2), nginx v2 (x1)  + sidecar nginx-prometheus-exporter   │
                         │              │ stdout (JSON access-log)          │ :9113/metrics               │
                         │              ▼                                   ▼                              │
                         │   Filebeat DaemonSet ──► Elasticsearch     Prometheus (kube-prometheus-stack)   │
                         │   (ns logging)            (ns logging)       ◄─ ServiceMonitor / PodMonitor     │
                         │                                              ──► Grafana (NodePort 30300)       │
                         └─────────────────────────────────────────────────────────────────────────────────┘
```

## Технологии и версии

| Компонент | Версия | Способ установки |
|---|---|---|
| ОС | Ubuntu 24.04 LTS | — |
| Kubernetes | v1.34.x (kubeadm, kubelet, kubectl из pkgs.k8s.io) | `scripts/00-bootstrap-node.sh`, `scripts/01-init-cluster.sh` |
| Container runtime | containerd 1.7 (пакет Ubuntu), SystemdCgroup | `00-bootstrap-node.sh` |
| CNI | Flannel v0.27.0 | `01-init-cluster.sh` |
| Helm | v3.18.4 | `00-bootstrap-node.sh` |
| Gateway API | Envoy Gateway v1.5.0 (CRD Gateway API v1 ставятся чартом) | Helm, `02-deploy.sh` |
| Приложение | nginxinc/nginx-unprivileged:1.27-alpine | Kustomize, `app/` |
| Экспортер метрик | nginx/nginx-prometheus-exporter:1.3.0 | sidecar, `app/` |
| Мониторинг | kube-prometheus-stack (Prometheus Operator, Prometheus, Grafana, node-exporter, kube-state-metrics) | Helm, `monitoring/values.yaml` |
| Логирование | Filebeat 8.15.3 (DaemonSet) | Kustomize, `logging/` |
| Хранилище логов | Elasticsearch 8.15.3 single-node | Kustomize, `logging/` |

Все версии собраны в [`versions.env`](versions.env).

## Требования к среде

* Ubuntu 24.04, **2+ vCPU (рекомендуется 4), 6–8 ГБ RAM**, 30 ГБ диска.
* Пользователь с `sudo`, доступ в интернет (пакеты, образы, Helm-чарты).
* Платные/облачные сервисы не нужны.

## Структура репозитория

```
Makefile                 точка входа: make all / node / cluster / deploy / check / destroy / reset
versions.env             версии всех компонентов
scripts/00-bootstrap-node.sh  подготовка узла (swap, sysctl, containerd, kubeadm, helm)
scripts/01-init-cluster.sh    kubeadm init + Flannel (идемпотентно)
scripts/02-deploy.sh          Envoy Gateway, Prometheus, приложение, Gateway API, логирование
scripts/03-check.sh           smoke-тесты всех компонентов
app/          Namespace, Deployment v1/v2, Service, PDB, шаблон конфигурации nginx (Kustomize)
gateway/      EnvoyProxy, GatewayClass, Gateway (HTTP+HTTPS), HTTPRoute
monitoring/   values для kube-prometheus-stack, ServiceMonitor, PodMonitor, PrometheusRule
logging/      Elasticsearch, Filebeat (RBAC, ConfigMap, DaemonSet)
.github/workflows/ci.yml  CI: shellcheck + kubeconform + e2e на kind
```

## Пошаговое развертывание

| Шаг | Команда | Что происходит |
|---|---|---|
| 1 | `make node` | отключение swap, модули `overlay`/`br_netfilter`, sysctl, containerd, kubeadm/kubelet/kubectl v1.34, helm |
| 2 | `make cluster` | `kubeadm init --pod-network-cidr=10.244.0.0/16`, kubeconfig, снятие taint control-plane, Flannel |
| 3 | `make deploy` | Envoy Gateway → kube-prometheus-stack → приложение → TLS-секрет + Gateway API → мониторы → Filebeat/ES |
| 4 | `make check` | автоматическая проверка (см. ниже), код возврата 0 = всё работает |

**Идемпотентность:** `kubeadm init` пропускается, если кластер уже создан; Helm-релизы ставятся через
`helm upgrade --install`; манифесты — `kubectl apply -k`; секреты (TLS, пароль Grafana) создаются только
если их ещё нет. Повторный `make all` / `make deploy` безопасен.

## Проверка

`make check` выполняет все проверки ниже автоматически. Ручные команды:

```bash
# адрес узла и NodePort Envoy
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
SVC=$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=web -o jsonpath='{.items[0].metadata.name}')
PORT=$(kubectl -n envoy-gateway-system get svc $SVC -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
```

### Приложение через Gateway API

```bash
curl -H 'Host: hello.local' http://$NODE_IP:$PORT/
# Hello World! (version: v1, pod: hello-v1-...)
kubectl get gatewayclass,gateway,httproute -A
```

Ресурсы Gateway API: `GatewayClass envoy` (+ `EnvoyProxy nodeport-proxy`), `Gateway demo/web`,
`HTTPRoute demo/hello`, `HTTPRoute demo/hello-v2-host`.

### Мониторинг

Собираемые метрики:
* **nginx** (через exporter, `ServiceMonitor demo/hello`): `nginx_up`, `nginx_http_requests_total`,
  `nginx_connections_active/accepted/handled` и др.;
* **Envoy Gateway proxy** (`PodMonitor envoy-gateway-system/envoy-proxy`): HTTP-коды
  `envoy_cluster_upstream_rq_xx`, latency `envoy_cluster_upstream_rq_time_bucket`, RPS;
* **инфраструктура**: node-exporter (CPU/RAM/диск узла), kube-state-metrics, kubelet/cAdvisor (CPU/RAM подов), apiserver, CoreDNS.

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
# http://localhost:9090/targets  — targets serviceMonitor/demo/hello в состоянии UP
# Примеры запросов:
#   nginx_up
#   rate(nginx_http_requests_total[1m])
#   sum by (envoy_response_code_class) (rate(envoy_cluster_upstream_rq_xx[5m]))
#   histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket[5m])))
#   sum by (pod) (container_memory_working_set_bytes{namespace="demo"})
```

Без port-forward: `kubectl get --raw '/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/query?query=nginx_up'`

Grafana: `http://<NODE_IP>:30300`, логин `admin`, пароль —
`kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`.
Дашборды: стандартные Kubernetes/Node из kube-prometheus-stack + «NGINX exporter» (папка Demo).

### Логирование

* **Что собирается:** stdout/stderr контейнеров namespace `demo` — access-лог nginx в формате JSON
  (`time, remote_addr, method, uri, status, request_time, user_agent, app_version …`) и error-лог.
* **Как:** Filebeat DaemonSet читает `/var/log/containers/*_demo_*.log`, добавляет метаданные Kubernetes
  (`kubernetes.pod.name`, `namespace`, labels), раскладывает JSON в поле `nginx.*`.
* **Куда:** Elasticsearch `logging/elasticsearch:9200`, data stream `filebeat-8.15.3`.

```bash
TOKEN=test$RANDOM
curl -s -H 'Host: hello.local' http://$NODE_IP:$PORT/$TOKEN
sleep 15
kubectl get --raw "/api/v1/namespaces/logging/services/elasticsearch:9200/proxy/filebeat-*/_search?q=$TOKEN" \
  | jq '.hits.hits[]._source | {pod: .kubernetes.pod.name, nginx}'
```

## Дополнительные возможности

* **Расширенный Gateway API:** маршрутизация по path (`/v2`) и hostname (`v2.hello.local`), несколько
  backend, **traffic splitting 80/20** (`/canary`), **TLS-терминация** (HTTPS-листенер, сертификат
  генерируется при развертывании), модификация заголовков ответа (`X-Gateway`).
* **Расширенный мониторинг:** HTTP-коды и latency Envoy, CPU/RAM узла и подов, Grafana с дашбордами,
  алерты `PrometheusRule` (nginx down, рост 5xx).
* **Централизованное хранение и поиск логов** в Elasticsearch, структурированные JSON-логи.
* **CI/CD (GitHub Actions):** shellcheck, валидация манифестов kubeconform, e2e-развертывание на kind
  с прогоном тех же smoke-тестов `scripts/03-check.sh`.
* **Надежность и безопасность:** 2 реплики v1 + PodDisruptionBudget, readiness/liveness-пробы,
  requests/limits, non-root контейнеры, `readOnlyRootFilesystem`, drop ALL capabilities, seccomp,
  Pod Security Standard `restricted` на namespace `demo`, секреты не хранятся в репозитории
  (TLS и пароль Grafana генерируются в кластере).

## Известные ограничения

* Кластер одноузловой (control-plane + worker); для продакшена нужны 3 control-plane и отдельные worker'ы.
* Нет LoadBalancer (bare-metal) — Gateway опубликован через NodePort; в продакшене — MetalLB/Cilium LB.
* Elasticsearch в режиме single-node без аутентификации и без PersistentVolume (данные на `emptyDir`),
  Kibana не устанавливается — поиск через REST API Elasticsearch.
* Prometheus хранит данные 2 дня без PV.
* TLS-сертификат самоподписанный (для проверки используйте `curl -k`); в продакшене — cert-manager.
* Метрики etcd/scheduler/controller-manager/kube-proxy отключены (на kubeadm они слушают только 127.0.0.1).

## Удаление

```bash
make destroy   # удалить компоненты решения
make reset     # полностью снести кластер kubeadm
```
