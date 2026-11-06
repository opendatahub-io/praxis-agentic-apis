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
#              ENABLE_WEB_SEARCH=true)
#   full       everything
#
# Environment (passed through to the tests and deploy.sh):
#   NAMESPACE RELEASE MODEL EMBEDDING_MODEL VECTOR_STORE_PROVIDER
#   OGX_ENDPOINT OGX_NAMESPACE OGX_SERVICE OGX_PORT MCP_SERVER_URL
#   INFERENCE_HOST INFERENCE_PORT
#   MCP                mcp tier fixture: auto (default) | openshift | everything
#   DEPLOY=true        run scripts/deploy.sh first (the caller must still
#                      pre-create the backend credential Secret; see
#                      docs/configuration.md); with the mcp tier, the resolved
#                      fixture's MCP_SERVER_URL is passed through
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

for tool in oc python3; do
  command -v "$tool" >/dev/null
done
python3 -c 'import yaml'

# Unmet preconditions SKIP the tier (they are missing credentials/features,
# not test failures).
require_ok() {
  case "$1" in
    '') return 0 ;;
    web-search)
      [[ -n $(oc -n "$NAMESPACE" get "deployment/$RELEASE" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="praxis")].env[?(@.name=="WEB_SEARCH_API_KEY")].name}') ]]
      ;;
    *)
      echo "Unknown requires value: $1" >&2
      return 1
      ;;
  esac
}

require_reason() {
  case "$1" in
    web-search) echo "web search not enabled on $RELEASE (deploy with ENABLE_WEB_SEARCH=true)" ;;
  esac
}

MCP_FIXTURE=

# Resolve the mcp tier's fixture before deploy: the OpenShift MCP server's
# URL must be baked into the gateway config (MCP_SERVER_URL) at deploy time.
# The everything fallback URL is deploy.sh's default.
resolve_mcp_fixture() {
  if [[ $MCP == everything ]]; then
    MCP_FIXTURE=everything
  elif url=$(NAMESPACE="$NAMESPACE" scripts/provision-mcp.sh); then
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
    scripts/cleanup.sh || c=$?
    case "$MCP_FIXTURE" in
      everything)
        oc delete -f infra/mcp/everything/deployment.yaml -n "$NAMESPACE" \
          --ignore-not-found || c=$?
        ;;
      openshift)
        oc delete -f infra/mcp/openshift/mcpserver.yaml -n "$NAMESPACE" \
          --ignore-not-found || c=$?
        ;;
    esac
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
  scripts/deploy.sh
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
