#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAMESPACE=${NAMESPACE:-praxis-standalone}
RELEASE=${RELEASE:-praxis-gateway}
CONFIG_DIR=${CONFIG_DIR:-$ROOT/configs/openai-ogx}
CONFIG_FILE=${CONFIG_FILE:-$CONFIG_DIR/config.yaml}
VALUES_FILE=${VALUES_FILE:-$CONFIG_DIR/values.yaml}
API_KEY_SECRET=${API_KEY_SECRET:-openai}
API_KEY_SECRET_KEY=${API_KEY_SECRET_KEY:-OPENAI_API_KEY}
ENABLE_WEB_SEARCH=${ENABLE_WEB_SEARCH:-false}
DRY_RUN=${DRY_RUN:-false}
WEB_SEARCH_API_KEY_SECRET=${WEB_SEARCH_API_KEY_SECRET:-brave-search}
WEB_SEARCH_API_KEY_SECRET_KEY=${WEB_SEARCH_API_KEY_SECRET_KEY:-WEB_SEARCH_API_KEY}
OGX_NAMESPACE=${OGX_NAMESPACE:-redhat-ods-applications}
OGX_SERVICE=${OGX_SERVICE:-ogx-distribution-service}
OGX_PORT=${OGX_PORT:-8321}
OGX_APP_LABEL=${OGX_APP_LABEL:-ogx}
OGX_INSTANCE_LABEL=${OGX_INSTANCE_LABEL:-ogx-distribution}
export OGX_ENDPOINT=${OGX_ENDPOINT:-$OGX_SERVICE.$OGX_NAMESPACE.svc.cluster.local:$OGX_PORT}
export INFERENCE_HOST=${INFERENCE_HOST:-api.openai.com}
export INFERENCE_PORT=${INFERENCE_PORT:-443}
export MCP_SERVER_URL=${MCP_SERVER_URL:-http://mcp-test:3001/mcp}

# Optional image override (envs append Helm --set-string; unset = common-values.yaml pin).
# A tag alone must also clear the pinned digest, otherwise the digest (which takes
# precedence in the chart) would silently keep the default image.
IMAGE_ARGS=()
if [[ -n "${PRAXIS_IMAGE_REPO:-}" ]]; then
  [[ "$PRAXIS_IMAGE_REPO" =~ ^[a-zA-Z0-9._/-]+$ ]] || {
    echo "Invalid PRAXIS_IMAGE_REPO format: $PRAXIS_IMAGE_REPO" >&2
    exit 1
  }
  IMAGE_ARGS+=(--set-string "image.repository=$PRAXIS_IMAGE_REPO")
fi
if [[ -n "${PRAXIS_IMAGE_DIGEST:-}" ]]; then
  [[ "$PRAXIS_IMAGE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || {
    echo "Invalid PRAXIS_IMAGE_DIGEST format: $PRAXIS_IMAGE_DIGEST" >&2
    exit 1
  }
  IMAGE_ARGS+=(--set-string "image.digest=$PRAXIS_IMAGE_DIGEST")
elif [[ -n "${PRAXIS_IMAGE_TAG:-}" ]]; then
  [[ "$PRAXIS_IMAGE_TAG" =~ ^[a-zA-Z0-9._-]+$ ]] || {
    echo "Invalid PRAXIS_IMAGE_TAG format: $PRAXIS_IMAGE_TAG" >&2
    exit 1
  }
  IMAGE_ARGS+=(--set-string "image.tag=$PRAXIS_IMAGE_TAG")
  IMAGE_ARGS+=(--set image.digest=null)
fi

for tool in python3 envsubst helm; do
  command -v "$tool" >/dev/null
done
# Render-only mode needs no cluster access.
[[ $DRY_RUN == true ]] || command -v oc >/dev/null
python3 -c 'import yaml'
[[ $ENABLE_WEB_SEARCH == true || $ENABLE_WEB_SEARCH == false ]] || {
  echo 'ENABLE_WEB_SEARCH must be true or false' >&2
  exit 1
}
[[ $DRY_RUN == true || $DRY_RUN == false ]] || {
  echo 'DRY_RUN must be true or false' >&2
  exit 1
}
[[ -r "$CONFIG_FILE" && -r "$CONFIG_DIR/values.yaml" && -r "$VALUES_FILE" ]]
WORK=$(mktemp -d)
trap 'rm -f "$WORK/config.yaml"; rmdir "$WORK"' EXIT
envsubst "\${OGX_ENDPOINT} \${INFERENCE_HOST} \${INFERENCE_PORT} \${MCP_SERVER_URL}" <"$CONFIG_FILE" >"$WORK/config.yaml"
SEARCH_ARGS=()
if [[ $ENABLE_WEB_SEARCH == true ]]; then
  SEARCH_ARGS=(
    --set-string 'env[1].name=WEB_SEARCH_API_KEY'
    --set-string "env[1].valueFrom.secretKeyRef.name=$WEB_SEARCH_API_KEY_SECRET"
    --set-string "env[1].valueFrom.secretKeyRef.key=$WEB_SEARCH_API_KEY_SECRET_KEY"
  )
else
  python3 - "$WORK/config.yaml" <<'PY'
import sys

import yaml

def without_web_search(value):
    if isinstance(value, list):
        return [without_web_search(item) for item in value
                if not (isinstance(item, dict) and item.get("filter") == "openai_web_search_dispatch")]
    if isinstance(value, dict):
        return {key: without_web_search(item) for key, item in value.items()}
    return value

with open(sys.argv[1]) as source:
    config = without_web_search(yaml.safe_load(source))
with open(sys.argv[1], "w") as target:
    yaml.safe_dump(config, target, sort_keys=False)
PY
fi

# Helm 4 requires post-renderers to be typed plugins (postrenderer/v1) and
# rejects an executable path ("plugin ... not found"); Helm 3 only accepts an
# executable path. Support both: install the bundled plugin for Helm 4, fall
# back to the script path for Helm 3.
POST_RENDER_PLUGIN=praxis-post-render
POST_RENDER_SCRIPT="$ROOT/scripts/helm-plugins/$POST_RENDER_PLUGIN/post-render.py"
if helm version --short | grep -qE '^v?[4-9]'; then
  helm plugin list | awk '{print $1}' | grep -qx "$POST_RENDER_PLUGIN" ||
    helm plugin install "${POST_RENDER_SCRIPT%/*}"
  POST_RENDERER_ARGS=(--post-renderer "$POST_RENDER_PLUGIN")
else
  POST_RENDERER_ARGS=(--post-renderer "$POST_RENDER_SCRIPT")
fi

if [[ $DRY_RUN == true ]]; then
  # Render-only mode: print the manifests deploy.sh would apply (with the
  # effective config, web-search filter applied or not) and exit before any
  # cluster mutation. Used by the render contract test
  # (.github/scripts/render-check.sh, `make render-check`).
  helm template "$RELEASE" \
    oci://ghcr.io/praxis-proxy/charts/praxis-gateway --version 0.2.1 \
    --namespace "$NAMESPACE" \
    -f "$ROOT/configs/common-values.yaml" -f "$CONFIG_DIR/values.yaml" -f "$VALUES_FILE" \
    --set-string "fullnameOverride=$RELEASE" \
    --set-string "env[0].valueFrom.secretKeyRef.name=$API_KEY_SECRET" \
    --set-string "env[0].valueFrom.secretKeyRef.key=$API_KEY_SECRET_KEY" \
    "${SEARCH_ARGS[@]}" "${IMAGE_ARGS[@]}" \
    --set-file "config.inline=$WORK/config.yaml" \
    "${POST_RENDERER_ARGS[@]}"
  exit 0
fi

oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
if [[ $ENABLE_WEB_SEARCH == true &&
  -z $(oc -n "$NAMESPACE" get secret "$WEB_SEARCH_API_KEY_SECRET" --ignore-not-found \
    -o jsonpath="{.data.${WEB_SEARCH_API_KEY_SECRET_KEY//./\\.}}") ]]; then
  echo "Secret $WEB_SEARCH_API_KEY_SECRET with nonempty key $WEB_SEARCH_API_KEY_SECRET_KEY is required in $NAMESPACE" >&2
  exit 1
fi

oc apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${RELEASE}-ingress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: praxis-gateway
      app.kubernetes.io/instance: "${RELEASE}"
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${RELEASE}-ogx
  namespace: ${OGX_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: "${OGX_APP_LABEL}"
      app.kubernetes.io/instance: "${OGX_INSTANCE_LABEL}"
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: "${NAMESPACE}"
          podSelector:
            matchLabels:
              app.kubernetes.io/name: praxis-gateway
              app.kubernetes.io/instance: "${RELEASE}"
      ports:
        - protocol: TCP
          port: ${OGX_PORT}
YAML

helm upgrade --install "$RELEASE" \
  oci://ghcr.io/praxis-proxy/charts/praxis-gateway --version 0.2.1 \
  --namespace "$NAMESPACE" \
  -f "$ROOT/configs/common-values.yaml" -f "$CONFIG_DIR/values.yaml" -f "$VALUES_FILE" \
  --set-string "fullnameOverride=$RELEASE" \
  --set-string "env[0].valueFrom.secretKeyRef.name=$API_KEY_SECRET" \
  --set-string "env[0].valueFrom.secretKeyRef.key=$API_KEY_SECRET_KEY" \
  "${SEARCH_ARGS[@]}" "${IMAGE_ARGS[@]}" \
  --set-file "config.inline=$WORK/config.yaml" \
  "${POST_RENDERER_ARGS[@]}" --wait --timeout 5m
