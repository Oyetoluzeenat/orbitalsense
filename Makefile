# OrbitalSense — common tasks.
# Every target is a thin wrapper over a script or a terraform command, so that
# nothing is ever done by hand that could be done reproducibly.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION     ?= europe-west1
ENV        ?= dev
TAG        ?= 0.1.0
TFVARS     := envs/$(ENV).tfvars

export PROJECT_ID REGION ENV TAG

.PHONY: help bootstrap init plan apply destroy fmt validate \
        image deploy pipeline start stop stats verify teardown clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Create the remote Terraform state bucket (run once per project)
	cd infra/bootstrap && terraform init && \
	  terraform apply -var="project_id=$(PROJECT_ID)" -var="region=$(REGION)"

init: ## Initialise Terraform against the remote backend
	cd infra && terraform init -reconfigure \
	  -backend-config="bucket=$(PROJECT_ID)-tfstate" \
	  -backend-config="prefix=orbitalsense/$(ENV)"

fmt: ## Format all Terraform
	cd infra && terraform fmt -recursive

validate: ## Validate Terraform
	cd infra && terraform validate

plan: ## Show what Terraform would change
	cd infra && terraform plan -var-file=$(TFVARS)

apply: ## Apply the infrastructure
	cd infra && terraform apply -var-file=$(TFVARS)
destroy: ## Destroy everything Terraform manages
	cd infra && terraform destroy -var-file=$(TFVARS)
image: ## Build and push the producer container
	./scripts/deploy_producer.sh $(TAG)

deploy: image ## Build, push and apply
	@echo "Deployed producer image tag $(TAG)"

pipeline: ## Launch the streaming Beam pipeline on Dataflow
	./scripts/launch_pipeline.sh

start: ## Start telemetry generation
	./scripts/inject_fault.sh start

stop: ## Stop telemetry generation
	./scripts/inject_fault.sh stop

stats: ## Show producer counters and the blackout plan
	./scripts/inject_fault.sh stats

verify: ## Run the reconciliation query
	./scripts/inject_fault.sh verify

teardown: ## Stop producer, drain pipeline, destroy infrastructure
	-./scripts/inject_fault.sh stop
	-./scripts/launch_pipeline.sh --drain
	cd infra && terraform destroy -var-file=$(TFVARS)

clean: ## Remove local build artefacts
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
	rm -rf pipeline/*.egg-info

