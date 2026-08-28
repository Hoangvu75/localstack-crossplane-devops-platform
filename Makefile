# Every lifecycle verb. There are four: start it, give it a token, bootstrap it, tear it
# down. Everything else the platform does to itself.
#
# `status` and `run-ci` used to be shell scripts. They are plain kubectl sequences with no
# logic worth putting in a file, and keeping them here makes the whole surface of the
# project visible in one screen.
# ── Why these are exported ───────────────────────────────────────────────────
# aws eks update-kubeconfig writes an exec credential plugin:
#     command: aws
#     args:    [--region, us-east-1, eks, get-token, --cluster-name, ...]
#     env:     null
# env: null means the plugin inherits the shell environment, so EVERY kubectl call
# needs AWS credentials present or it fails with something that names neither kubectl
# nor the cluster:
#     Unable to locate credentials. You can configure credentials by running "aws configure".
#     Unable to connect to the server: getting credentials: exec: executable aws failed
#
# The scripts get these from .env via scripts/lib.sh. make runs each recipe in its own
# shell and does not read .env, so status and run-ci need them here.
#
# ?= so a real AWS profile in the environment still wins.
export AWS_ACCESS_KEY_ID ?= mock_access_key
export AWS_SECRET_ACCESS_KEY ?= mock_secret_key
export AWS_DEFAULT_REGION ?= us-east-1

.PHONY: all up secrets bootstrap status run-ci destroy purge

# secrets before bootstrap: step 5 of the bootstrap reads the token back out of Secrets
# Manager to build the in-cluster git-credentials Secret.
all: up secrets bootstrap

up:
	docker compose up -d localstack

secrets:
	@bash scripts/secrets.sh

bootstrap:
	@bash scripts/bootstrap.sh

# ── Diagnostics ──────────────────────────────────────────────────────────────
# Read top to bottom. The first section that looks wrong is the one to fix, because
# everything below it depends on that one.
#
# On managed resources, the two columns mean different things:
#   SYNCED=False  the request never reached AWS. A selector matched nothing, or a field
#                 was pruned by the API server.
#   READY=False   LocalStack received it and rejected it, or it is still being created.
status:
	@echo ""
	@echo "── Crossplane providers ─────────────────────────────────────"
	-@kubectl get providers.pkg.crossplane.io
	@echo ""
	@echo "── Managed resources ────────────────────────────────────────"
	-@kubectl get managed
	@echo ""
	@echo "── ArgoCD applications ──────────────────────────────────────"
	-@kubectl -n argocd get applications
	@echo ""
	@echo "── Workloads ────────────────────────────────────────────────"
	-@kubectl -n devops-apps get pods
	@echo ""
	@echo "── Tekton CI ────────────────────────────────────────────────"
	-@kubectl -n tekton-pipelines get secret git-credentials
	-@kubectl -n tekton-pipelines get pipelinerun
	@echo ""
	@echo "── Entry URLs, from the last localstack-wiring run ──────────"
	-@kubectl -n localstack-wiring logs -l app=localstack-wiring --tail=20

# Start the pipeline by hand. The manifest is the same one the TriggerTemplate renders,
# so this exercises the real Pipeline but skips the interceptor chain — README §8.2 has
# the curl that tests the interceptors too.
run-ci:
	@kubectl create -f gitops/platform/tekton/ci/pipelinerun-manual.yaml

# Keeps ./data/localstack, so the next `make up` resumes from the persisted state.
destroy:
	@bash scripts/destroy.sh

# True clean slate. Prompts for confirmation; roughly 20 minutes to rebuild the cache.
purge:
	@bash scripts/destroy.sh --purge-data
