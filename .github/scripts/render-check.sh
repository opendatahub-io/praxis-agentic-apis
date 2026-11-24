#!/usr/bin/env bash
# Render contract test (T1.3): helm template the umbrella chart with
# global.webSearch.enabled=true and =false, and assert that the web-search
# filter (openai_web_search_dispatch) and its WEB_SEARCH_API_KEY env toggle
# with the flag. No cluster access required; needs helm + python3(+PyYAML).
#
# Usage: .github/scripts/render-check.sh   (or: make render-check)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHART="$ROOT/charts/praxis-agentic-apis"

render() {
  helm dependency build "$CHART" >/dev/null
  helm template praxis-gateway "$CHART" \
    --set-string "global.ogx.endpoint=${OGX_ENDPOINT:-ogx-distribution-service.redhat-ods-applications.svc.cluster.local:8321}" \
    --set-string "global.inference.host=${INFERENCE_HOST:-litemaas.example.com}" \
    --set "global.inference.port=${INFERENCE_PORT:-443}" \
    --set-string "global.mcp.serverUrl=${MCP_SERVER_URL:-http://openshift-mcp:8080/mcp}" \
    --set "global.webSearch.enabled=$1"
}

fail() {
  echo "render-check: FAIL: $1" >&2
  exit 1
}

echo "== render contract: global.webSearch.enabled=true =="
on=$(render true)
grep -q 'openai_web_search_dispatch' <<<"$on" \
  || fail "web-search filter missing from rendered config with global.webSearch.enabled=true"
grep -q 'name: WEB_SEARCH_API_KEY' <<<"$on" \
  || fail "WEB_SEARCH_API_KEY env missing from rendered Deployment with global.webSearch.enabled=true"

echo "== render contract: global.webSearch.enabled=false =="
off=$(render false)
grep -q 'openai_web_search_dispatch' <<<"$off" \
  && fail "web-search filter present in rendered config with global.webSearch.enabled=false"
# WEB_SEARCH_API_KEY is intentionally NOT asserted here: the chart always
# renders it as an optional secretRef so the container spec is stable; only
# the openai_web_search_dispatch filter toggles with the flag.

echo "render-check: PASS (filter toggles with global.webSearch.enabled)"
