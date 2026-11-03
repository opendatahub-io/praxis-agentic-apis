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
DATABASE_HOST=${DATABASE_HOST:-}
DATABASE_PORT=${DATABASE_PORT:-5432}
DATABASE_NAME=${DATABASE_NAME:-praxis}
DATABASE_USER=${DATABASE_USER:-praxis}
DATABASE_SECRET=${DATABASE_SECRET:-$RELEASE-postgres}
DATABASE_SECRET_KEY=${DATABASE_SECRET_KEY:-POSTGRESQL_PASSWORD}
if [[ -z $DATABASE_HOST ]]; then
  export DATABASE_SSL_MODE=${DATABASE_SSL_MODE:-disable}
else
  export DATABASE_SSL_MODE=${DATABASE_SSL_MODE:-verify-full}
fi

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
[[ $DATABASE_SSL_MODE =~ ^(disable|prefer|require|verify-ca|verify-full)$ ]] || {
  echo 'DATABASE_SSL_MODE must be disable, prefer, require, verify-ca, or verify-full' >&2
  exit 1
}
[[ $DRY_RUN == true || $DRY_RUN == false ]] || {
  echo 'DRY_RUN must be true or false' >&2
  exit 1
}
[[ -r "$CONFIG_FILE" && -r "$CONFIG_DIR/values.yaml" && -r "$VALUES_FILE" ]]
WORK=$(mktemp -d)
trap 'rm -f "$WORK/config.yaml"; rmdir "$WORK"' EXIT

[[ $DRY_RUN == true ]] || oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
if [[ $DRY_RUN == false && $ENABLE_WEB_SEARCH == true &&
  -z $(oc -n "$NAMESPACE" get secret "$WEB_SEARCH_API_KEY_SECRET" --ignore-not-found \
    -o jsonpath="{.data.${WEB_SEARCH_API_KEY_SECRET_KEY//./\\.}}") ]]; then
  echo "Secret $WEB_SEARCH_API_KEY_SECRET with nonempty key $WEB_SEARCH_API_KEY_SECRET_KEY is required in $NAMESPACE" >&2
  exit 1
fi

secret_value() {
  oc -n "$NAMESPACE" get secret "$1" --ignore-not-found -o jsonpath="{.data.${2//./\\.}}" | base64 -d
}

ENV_ARGS=()
ENV_INDEX=1
if [[ $ENABLE_WEB_SEARCH == true ]]; then
  ENV_ARGS+=(
    --set-string "env[$ENV_INDEX].name=WEB_SEARCH_API_KEY"
    --set-string "env[$ENV_INDEX].valueFrom.secretKeyRef.name=$WEB_SEARCH_API_KEY_SECRET"
    --set-string "env[$ENV_INDEX].valueFrom.secretKeyRef.key=$WEB_SEARCH_API_KEY_SECRET_KEY"
  )
  ENV_INDEX=$((ENV_INDEX + 1))
fi

export DATABASE_URL=
if [[ -z $DATABASE_HOST ]]; then
  # In-repo PostgreSQL: keep an existing Secret, since the data directory was
  # initialized with its credentials.
  DATABASE_SECRET=$RELEASE-postgres
  DATABASE_SECRET_KEY=POSTGRESQL_PASSWORD
  if [[ $DRY_RUN == true ]]; then
    # Render-only: render what a fresh install would apply, so keep the
    # default user/database and the would-be in-repo service host.
    DATABASE_HOST=$RELEASE-postgres.$NAMESPACE.svc.cluster.local
  else
    if [[ -z $(secret_value "$DATABASE_SECRET" POSTGRESQL_PASSWORD) ]]; then
      oc -n "$NAMESPACE" create secret generic "$DATABASE_SECRET" \
        --from-literal=POSTGRESQL_USER="$DATABASE_USER" \
        --from-literal=POSTGRESQL_DATABASE="$DATABASE_NAME" \
        --from-file=POSTGRESQL_PASSWORD=<(python3 -c 'import secrets; print(secrets.token_hex(24), end="")')
    fi
    DATABASE_USER=$(secret_value "$DATABASE_SECRET" POSTGRESQL_USER)
    DATABASE_NAME=$(secret_value "$DATABASE_SECRET" POSTGRESQL_DATABASE)
    DATABASE_HOST=$RELEASE-postgres.$NAMESPACE.svc.cluster.local
    RELEASE=$RELEASE DATABASE_PORT=$DATABASE_PORT \
      envsubst "\${RELEASE} \${DATABASE_PORT}" <"$ROOT/infra/postgres/postgres.yaml" |
      oc -n "$NAMESPACE" apply -f -
    oc -n "$NAMESPACE" rollout status "deployment/$RELEASE-postgres" --timeout=5m
  fi
elif [[ $DRY_RUN == false && -z $(secret_value "$DATABASE_SECRET" "$DATABASE_SECRET_KEY") ]]; then
  echo "Secret $DATABASE_SECRET with nonempty key $DATABASE_SECRET_KEY is required in $NAMESPACE" >&2
  exit 1
fi
DATABASE_URL=$(python3 -c 'import sys, urllib.parse as u
user, host, port, name = sys.argv[1:]
print(f"postgres://{u.quote(user, safe=str())}@{host}:{port}/{u.quote(name, safe=str())}")' \
  "$DATABASE_USER" "$DATABASE_HOST" "$DATABASE_PORT" "$DATABASE_NAME")
ENV_ARGS+=(
  --set-string "env[$ENV_INDEX].name=PGPASSWORD"
  --set-string "env[$ENV_INDEX].valueFrom.secretKeyRef.name=$DATABASE_SECRET"
  --set-string "env[$ENV_INDEX].valueFrom.secretKeyRef.key=$DATABASE_SECRET_KEY"
)

envsubst "\${OGX_ENDPOINT} \${INFERENCE_HOST} \${INFERENCE_PORT} \${MCP_SERVER_URL} \${DATABASE_URL} \${DATABASE_SSL_MODE}" \
  <"$CONFIG_FILE" >"$WORK/config.yaml"
python3 - "$WORK/config.yaml" "$ENABLE_WEB_SEARCH" <<'PY'
import sys

import yaml

path, web_search = sys.argv[1:]

def render(value):
    if isinstance(value, list):
        return [render(item) for item in value
                if not (web_search == "false" and isinstance(item, dict)
                        and item.get("filter") == "openai_web_search_dispatch")]
    if isinstance(value, dict):
        return {key: render(item) for key, item in value.items()}
    return value

with open(path) as source:
    config = render(yaml.safe_load(source))
with open(path, "w") as target:
    yaml.safe_dump(config, target, sort_keys=False)
PY

if [[ $DRY_RUN == true ]]; then
  # Render-only mode: print the manifests deploy.sh would apply (with the
  # effective config, web-search filter applied or not) and exit before any
  # cluster mutation (no namespace, secrets, PostgreSQL, or NetworkPolicies).
  # Used by the render contract test (.github/scripts/render-check.sh,
  # `make render-check`).
  helm template "$RELEASE" \
    oci://ghcr.io/praxis-proxy/charts/praxis-gateway --version 0.2.1 \
    --namespace "$NAMESPACE" \
    -f "$ROOT/configs/common-values.yaml" -f "$CONFIG_DIR/values.yaml" -f "$VALUES_FILE" \
    --set-string "fullnameOverride=$RELEASE" \
    --set-string "env[0].valueFrom.secretKeyRef.name=$API_KEY_SECRET" \
    --set-string "env[0].valueFrom.secretKeyRef.key=$API_KEY_SECRET_KEY" \
    "${ENV_ARGS[@]}" "${IMAGE_ARGS[@]}" \
    --set-file "config.inline=$WORK/config.yaml"
  exit 0
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
  "${ENV_ARGS[@]}" "${IMAGE_ARGS[@]}" \
  --set-file "config.inline=$WORK/config.yaml" \
  --wait --timeout 5m
