SHELL := /bin/bash

.PHONY: all node cluster deploy check lint destroy reset

## Полный цикл на чистой Ubuntu 24.04: узел -> кластер kubeadm -> платформа -> проверка
all: node cluster deploy check

## Подготовка узла: containerd, kubeadm/kubelet/kubectl, helm (нужен sudo)
node:
	sudo bash scripts/00-bootstrap-node.sh

## Инициализация одноузлового кластера kubeadm + CNI Flannel
cluster:
	bash scripts/01-init-cluster.sh

## Развертывание приложения, Gateway API, Prometheus, Filebeat (работает на любом кластере)
deploy:
	bash scripts/02-deploy.sh

## Smoke-проверка: приложение, маршрутизация, TLS, метрики, логи
check:
	bash scripts/03-check.sh

## Статическая проверка скриптов и манифестов
lint:
	shellcheck scripts/*.sh
	for d in app gateway monitoring logging; do kubectl kustomize $$d > /dev/null && echo "$$d: OK"; done

## Удалить компоненты решения из кластера (кластер остается)
destroy:
	bash scripts/99-destroy.sh

## Полностью снести кластер kubeadm на узле
reset:
	sudo kubeadm reset -f
	rm -rf $$HOME/.kube/config
