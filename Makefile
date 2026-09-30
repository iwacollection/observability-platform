ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
COMPOSE := docker compose -f $(ROOT)/deploy/docker-compose/docker-compose.yml

.PHONY: up down restart ps logs config-check lint test load kustomize-build terraform-check

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart: down up

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

config-check:
	bash $(ROOT)/scripts/config-check.sh

terraform-check:
	bash $(ROOT)/scripts/terraform-check.sh

lint: config-check

test:
	PYTHONPATH=$(ROOT)/examples/demo-app/src python3 -m unittest discover -s $(ROOT)/examples/demo-app/tests -v

load:
	bash $(ROOT)/scripts/generate-load.sh

kustomize-build:
	kustomize build --load-restrictor LoadRestrictionsNone $(ROOT)/deploy/kubernetes/overlays/dev >/tmp/observability-dev.yaml
	kustomize build --load-restrictor LoadRestrictionsNone $(ROOT)/deploy/kubernetes/overlays/prod >/tmp/observability-prod.yaml
	@echo "wrote /tmp/observability-dev.yaml and /tmp/observability-prod.yaml"
