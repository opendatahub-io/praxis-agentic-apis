#!/usr/bin/env bash
# T2.1: Tiered E2E test runner. Executes the entries in demos/manifest.yaml
# selected by LEVEL, skipping tiers whose preconditions (credentials,
# deployment features) are unmet, and always cleaning up on exit.
#
# Usage:
#   LEVEL=smoke tests/e2e.sh
#
# Levels (cumulative tag sets, manifest order = run order):
#   smoke      free tier only (no inference calls)
#   functional + Responses API (paid inference)
#   mcp        + MCP tool calls (fixture: OpenShift MCP server, or the
#              everything test server as fallback)
#   websearch  + web search (SKIP unless the gateway was deployed with
#              WEB_SEARCH=true, i.e. global.webSearch.enabled)
#   full       everything
#
# Environment (passed through to the tests and the Helm install):
#   NAMESPACE RELEASE MODEL EMBEDDING_MODEL VECTOR_STORE_PROVIDER
#   OGX_ENDPOINT OGX_NAMESPACE OGX_SERVICE OGX_PORT MCP_SERVER_URL
#   INFERENCE_HOST INFERENCE_PORT
#   MCP                mcp tier fixture: auto (default) | openshift | everything
#   DEPLOY=true        helm-install charts/praxis-agentic-apis first (the
#                      caller must export OPENAI_API_KEY for the backend
#                      credential Secret; see docs/configuration.md); with
#                      the mcp tier, the resolved fixture's MCP_SERVER_URL is
#                      passed through
#   WEB_SEARCH=true    with DEPLOY=true, install with global.webSearch.enabled
#   SKIP_CLEANUP=true  leave the deployment in place after the run (dev
#                      iteration; default is to always clean up)
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL=${LEVEL:-smoke}
NAMESPACE=${NAMESPACE:-praxis-standalone}
RELEASE=${RELEASE:-praxis-gateway}
DEPLOY=${DEPLOY:-false}
SKIP_CLEANUP=${SKIP_CLEANUP:-false}
# mcp tier fixture: auto (try OpenShift MCP, fall back to the everything test
# server), openshift (require it) or everything (skip the OpenShift MCP).
MCP=${MCP:-auto}

case "$LEVEL" in
  smoke) TAGS=smoke ;;
  functional) TAGS=smoke,functional ;;
  mcp) TAGS=smoke,functional,mcp ;;
  websearch) TAGS=smoke,functional,websearch ;;
  full) TAGS=all ;;
  *)
    echo "LEVEL must be one of: smoke functional mcp websearch full (got: $LEVEL)" >&2
    exit 1
    ;;
esac
case "$DEPLOY$SKIP_CLEANUP" in
  truetrue | truefalse | falsetrue | falsefalse) ;;
  *) echo 'DEPLOY and SKIP_CLEANUP must be true or false' >&2; exit 1 ;;
esac
case "$MCP" in
  auto | openshift | everything) ;;
  *) echo "MCP must be one of: auto openshift everything (got: $MCP)" >&2; exit 1 ;;
esac

for tool in oc helm python3; do
  command -v "$tool" >/dev/null
done
python3 -c 'import yaml'

# Unmet preconditions SKIP the tier (they are missing credentials/features,
# not test failures).
require_ok() {
  case "$1" in
    '') return 0 ;;
    web-search)
      # The chart always renders WEB_SEARCH_API_KEY as an optional env, so
      # the toggle is read from the release's user-supplied values instead.
      helm get values "$RELEASE" -n "$NAMESPACE" -o yaml 2>/dev/null | \
        python3 -c 'import sys, yaml
vals = yaml.safe_load(sys.stdin) or {}
sys.exit(0 if vals.get("global", {}).get("webSearch", {}).get("enabled") else 1)' ;;
    *)
      echo "Unknown requires value: $1" >&2
      return 1
      ;;
  esac
}

require_reason() {
  case "$1" in
    web-search) echo "web search not enabled on $RELEASE (deploy with WEB_SEARCH=true)" ;;
  esac
}

MCP_FIXTURE=

# Resolve the mcp tier's fixture before deploy: the OpenShift MCP server's
# URL must be baked into the gateway config (MCP_SERVER_URL) at deploy time.
# The everything fallback URL is the mcp-test fixture's.
resolve_mcp_fixture() {
  if [[ $MCP == everything ]]; then
    MCP_FIXTURE=everything
  elif url=$(NAMESPACE="$NAMESPACE" scripts/provision-mcp.sh prepare); then
    export MCP_SERVER_URL="$url"
    export MCP_TEST=openshift
    MCP_FIXTURE=openshift
  elif [[ $MCP == openshift ]]; then
    echo "MCP=openshift requested but OpenShift MCP provisioning failed" >&2
    exit 1
  else
    echo "mcp: OpenShift MCP unavailable; falling back to the everything test server" >&2
    MCP_FIXTURE=everything
  fi

  if [[ $MCP_FIXTURE == everything ]]; then
    export MCP_TEST=everything
    oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >&2
    oc apply -f infra/mcp/everything/deployment.yaml -n "$NAMESPACE" >&2
  fi
  if [[ $DEPLOY != true ]]; then
    echo "mcp: DEPLOY=false — the gateway must already be deployed with MCP_SERVER_URL=${MCP_SERVER_URL:-http://mcp-test:3001/mcp}" >&2
  fi
}

cleanup() {
  local rc=$? c=0
  if [[ $SKIP_CLEANUP != true ]]; then
    # helm uninstall also removes the chart-managed OpenShift MCPServer when
    # the openshift fixture is in use; only the everything fixture is
    # harness-owned and deleted explicitly.
    helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 120s || c=$?
    if [[ $MCP_FIXTURE == everything ]]; then
      oc delete -f infra/mcp/everything/deployment.yaml -n "$NAMESPACE" \
        --ignore-not-found || c=$?
    fi
    oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s || c=$?
    [[ $rc -eq 0 ]] && rc=$c
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $LEVEL == mcp || $LEVEL == full ]]; then
  resolve_mcp_fixture
fi

if [[ $DEPLOY == true ]]; then
  # Helm-based deploy (mirrors .github/workflows/mvp.yml): the chart composes
  # praxis-gateway with PostgreSQL and NetworkPolicies. With the everything
  # fixture the in-chart OpenShift MCP is disabled and the gateway points at
  # the harness-applied mcp-test server; with the openshift fixture the chart
  # deploys the MCPServer itself (default) using the resolved URL.
  if [[ $MCP_FIXTURE == everything ]]; then
    oc apply -f infra/mcp/everything/deployment.yaml -n "$NAMESPACE"
  fi
  oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
  oc -n "$NAMESPACE" create secret generic openai \
    --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:?DEPLOY=true requires OPENAI_API_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  args=(
    --set-string "global.ogx.endpoint=${OGX_ENDPOINT:-ogx-distribution-service.redhat-ods-applications.svc.cluster.local:8321}"
    --set-string "global.inference.host=${INFERENCE_HOST:-litemaas.example.com}"
    --set "global.inference.port=${INFERENCE_PORT:-443}"
    --set-string "global.mcp.serverUrl=${MCP_SERVER_URL:-http://mcp-test:3001/mcp}"
  )
  if [[ $MCP_FIXTURE == everything ]]; then
    args+=(--set "openshiftMcp.enabled=false")
  fi
  if [[ ${WEB_SEARCH:-false} == true ]]; then
    args+=(--set "global.webSearch.enabled=true")
  fi
  helm dependency build charts/praxis-agentic-apis
  helm upgrade --install "$RELEASE" charts/praxis-agentic-apis \
    --namespace "$NAMESPACE" "${args[@]}" --wait --timeout 5m
  if [[ $MCP_FIXTURE == openshift ]]; then
    # Wait for the chart-deployed MCPServer before running the mcp tier.
    scripts/provision-mcp.sh wait
  fi
fi

echo "=========================================="
echo "E2E level: $LEVEL (tags: $TAGS)"
echo "namespace: $NAMESPACE  release: $RELEASE"
echo "=========================================="

FOUND=0 RUN=0 SKIPPED=0 FAILED=0
FAILED_NAMES=() SKIPPED_NAMES=()

while IFS='|' read -r path name type requires; do
  FOUND=$((FOUND + 1))
  if [[ -n $requires ]] && ! require_ok "$requires"; then
    echo "=========================================="
    echo "SKIP: $name"
    echo "  Reason: $(require_reason "$requires")"
    echo "=========================================="
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_NAMES+=("$name")
    continue
  fi
  echo "=========================================="
  echo "Running: $name"
  echo "=========================================="
  case "$type" in
    shell)
      if bash "$path"; then
        RUN=$((RUN + 1))
      else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
      fi
      ;;
    *)
      echo "Unknown type: $type" >&2
      FAILED=$((FAILED + 1))
      FAILED_NAMES+=("$name")
      ;;
  esac
done < <(python3 scripts/parse-manifest.py "$TAGS")

echo "=========================================="
echo "Summary: $RUN/$FOUND tests passed, $SKIPPED skipped, $FAILED failed"
if ((SKIPPED > 0)); then
  printf '         skipped: %s\n' "${SKIPPED_NAMES[*]}"
fi
if ((FAILED > 0)); then
  printf '         failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
