#!/usr/bin/env bash
# Render contract test (T1.3): run scripts/deploy.sh in render-only (DRY_RUN)
# mode for ENABLE_WEB_SEARCH=true and =false, and assert that the web-search
# filter (openai_web_search_dispatch) and its WEB_SEARCH_API_KEY env toggle
# with the flag. No cluster access required; needs helm + python3(+PyYAML).
#
# Usage: .github/scripts/render-check.sh   (or: make render-check)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEPLOY="$ROOT/scripts/deploy.sh"

render() {
  ENABLE_WEB_SEARCH="$1" DRY_RUN=true bash "$DEPLOY"
}

fail() {
  echo "render-check: FAIL: $1" >&2
  exit 1
}

echo "== render contract: ENABLE_WEB_SEARCH=true =="
on=$(render true)
grep -q 'openai_web_search_dispatch' <<<"$on" \
  || fail "web-search filter missing from rendered config with ENABLE_WEB_SEARCH=true"
grep -q 'name: WEB_SEARCH_API_KEY' <<<"$on" \
  || fail "WEB_SEARCH_API_KEY env missing from rendered Deployment with ENABLE_WEB_SEARCH=true"

echo "== render contract: ENABLE_WEB_SEARCH=false =="
off=$(render false)
grep -q 'openai_web_search_dispatch' <<<"$off" \
  && fail "web-search filter present in rendered config with ENABLE_WEB_SEARCH=false"
grep -q 'name: WEB_SEARCH_API_KEY' <<<"$off" \
  && fail "WEB_SEARCH_API_KEY env present in rendered Deployment with ENABLE_WEB_SEARCH=false"

echo "render-check: PASS (filter + env toggle with ENABLE_WEB_SEARCH)"
