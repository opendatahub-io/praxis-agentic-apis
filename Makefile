# Static-gate entry points shared by CI (.github/workflows/static.yml) and
# developers: `make lint` and `make render` run the exact commands CI runs.
#
# Quick start:
#   make tools   # one-time: install the pinned linters
#   make lint    # shellcheck + yamllint + actionlint + ruff
#   make render  # chart render dry-run (needs helm; no cluster writes)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Pinned tool versions — single source of truth for CI and local runs.
# ruff is pinned: rule sets evolve between releases and an unpinned install
# broke this gate once already (UP017 in the demo app).
RUFF_VERSION := 0.17.3
ACTIONLINT_VERSION := 1.7.12
ACTIONLINT_SHA256_LINUX_AMD64 := 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

# Render defaults — mirror scripts/deploy.sh (nothing cluster-specific).
OGX_ENDPOINT ?= ogx-distribution-service.redhat-ods-applications.svc.cluster.local:8321
INFERENCE_HOST ?= litemaas.example.com
INFERENCE_PORT ?= 443
MCP_SERVER_URL ?= http://openshift-mcp:8080/mcp

.PHONY: tools lint lint-shellcheck lint-yamllint lint-actionlint lint-ruff render

## tools: install the pinned lint tools (yamllint, ruff via pip; actionlint
## via GitHub release on linux/amd64 — install actionlint manually elsewhere,
## e.g. `brew install actionlint`).
tools:
	python3 -m pip install --quiet yamllint 'ruff==$(RUFF_VERSION)'
	@if [[ "$$(uname -s)/$$(uname -m)" == "Linux/x86_64" ]]; then \
		curl -sSL -o /tmp/actionlint.tar.gz \
			https://github.com/rhysd/actionlint/releases/download/v$(ACTIONLINT_VERSION)/actionlint_$(ACTIONLINT_VERSION)_linux_amd64.tar.gz; \
		echo "$(ACTIONLINT_SHA256_LINUX_AMD64)  /tmp/actionlint.tar.gz" | sha256sum -c -; \
		mkdir -p ~/.local/bin; \
		tar -xzf /tmp/actionlint.tar.gz -C ~/.local/bin actionlint; \
	else \
		echo "actionlint: auto-install only covers linux/amd64; install it manually (e.g. brew install actionlint)"; \
	fi

## lint: run every static gate CI runs.
lint: lint-shellcheck lint-yamllint lint-actionlint lint-ruff

lint-shellcheck:
	rc=0; while IFS= read -r script; do echo "shellcheck: $$script"; shellcheck "$$script" || rc=1; done < <(find scripts tests demos .github/scripts -name '*.sh' -type f | sort); exit $$rc

lint-yamllint:
	yamllint --strict configs/ demos/shop-outage/manifests/ .github/workflows/ .yamllint.yaml

lint-actionlint:
	actionlint

lint-ruff:
	ruff check demos/shop-outage/sre-assistant demos/shop-outage/app/

## render: chart render dry-run mirroring scripts/deploy.sh's render path
## (envsubst -> helm template), no cluster writes. Helm 3 and Helm 4 render
## the same way; no post-renderer is involved.
render:
	# PyYAML is needed by the assertion below.
	python3 -c 'import yaml' 2>/dev/null || python3 -m pip install --quiet pyyaml
	work="$$(mktemp -d)"; \
	envsubst '$${OGX_ENDPOINT} $${INFERENCE_HOST} $${INFERENCE_PORT} $${MCP_SERVER_URL}' \
		< configs/openai-ogx/config.yaml > "$$work/config.yaml"; \
	helm template praxis-gateway \
		oci://ghcr.io/praxis-proxy/charts/praxis-gateway --version 0.2.1 \
		-f configs/common-values.yaml -f configs/openai-ogx/values.yaml \
		--set-string fullnameOverride=praxis-gateway \
		--set-file "config.inline=$$work/config.yaml" > "$$work/rendered.yaml"; \
	python3 -c 'import sys, yaml; docs = list(yaml.safe_load_all(open(sys.argv[1]))); assert docs, "rendered output is empty"; print(f"rendered.yaml: valid YAML, {len(docs)} resources")' "$$work/rendered.yaml"
