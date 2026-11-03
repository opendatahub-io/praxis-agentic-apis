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
#   mcp        + MCP tool calls (applies the mcp-test fixture)
#   websearch  + web search (SKIP unless the gateway was deployed with
#              ENABLE_WEB_SEARCH=true)
#   full       everything
#
# Environment (passed through to the tests and deploy.sh):
#   NAMESPACE RELEASE MODEL EMBEDDING_MODEL VECTOR_STORE_PROVIDER
#   OGX_ENDPOINT OGX_NAMESPACE OGX_SERVICE OGX_PORT MCP_SERVER_URL
#   INFERENCE_HOST INFERENCE_PORT
#   DEPLOY=true        run scripts/deploy.sh first (the caller must still
#                      pre-create the backend credential Secret; see
#                      docs/configuration.md)
#   SKIP_CLEANUP=true  leave the deployment in place after the run (dev
#                      iteration; default is to always clean up)
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL=${LEVEL:-smoke}
NAMESPACE=${NAMESPACE:-praxis-standalone}
RELEASE=${RELEASE:-praxis-gateway}
DEPLOY=${DEPLOY:-false}
SKIP_CLEANUP=${SKIP_CLEANUP:-false}

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

MCP_FIXTURE_APPLIED=false

cleanup() {
  local rc=$? c=0
  if [[ $SKIP_CLEANUP != true ]]; then
    scripts/cleanup.sh || c=$?
    if [[ $MCP_FIXTURE_APPLIED == true ]]; then
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

if [[ $DEPLOY == true ]]; then
  scripts/deploy.sh
fi

# The mcp tier needs the mcp-test fixture server; the harness owns it.
if [[ $LEVEL == mcp || $LEVEL == full ]]; then
  oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
  oc apply -f infra/mcp/everything/deployment.yaml -n "$NAMESPACE"
  MCP_FIXTURE_APPLIED=true
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
