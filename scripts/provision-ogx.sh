#!/usr/bin/env bash
# T2.0: Provision OGX on the cluster via ogx-showroom, switch it to
# praxis-fronted mode, and print the OGX_* environment scripts/deploy.sh
# consumes. No cluster mutation happens before OGX is verified healthy
# (showroom test.sh hello), so a broken provision never leaves a
# half-switched OGX behind.
#
# Usage:
#   SHOWROOM_DIR=/path/to/ogx-showroom scripts/provision-ogx.sh
#   eval "$(SHOWROOM_DIR=... scripts/provision-ogx.sh)"   # export OGX_* vars
#
# Inputs (env):
#   SHOWROOM_DIR      ogx-showroom checkout (setup.sh/provision.sh/values-local.yaml)
#   OGX_NAMESPACE     default redhat-ods-applications
#   OGX_NAME          OGXServer CR + deployment name (default ogx-distribution)
#   OGX_SERVICE       service name (default ogx-distribution-service)
#   OGX_PORT          service port (default 8321)
#   SKIP_HELLO_TEST   true: skip the showroom hello health check
#
# Output (stdout): `export OGX_ENDPOINT=...` lines — source with eval, or read
# as plain key=value pairs. All verbose output goes to stderr. The praxisMode
# patch switches OGX auth to upstream_header and restricts ingress to
# praxis-gateway pods (default peer: app.kubernetes.io/name=praxis-gateway in
# the praxis-standalone namespace); it pairs with a spec.baseConfig ConfigMap
# extracted from the distribution image (see step 4) because the operator's
# OCI-label fetch cannot authenticate against registry.redhat.io.
set -euo pipefail

SHOWROOM_DIR=${SHOWROOM_DIR:?SHOWROOM_DIR must point to an ogx-showroom checkout}
OGX_NAMESPACE=${OGX_NAMESPACE:-redhat-ods-applications}
OGX_NAME=${OGX_NAME:-ogx-distribution}
OGX_SERVICE=${OGX_SERVICE:-ogx-distribution-service}
OGX_PORT=${OGX_PORT:-8321}
SKIP_HELLO_TEST=${SKIP_HELLO_TEST:-false}

[[ -x $SHOWROOM_DIR/setup.sh && -x $SHOWROOM_DIR/provision.sh ]] || {
  echo "$SHOWROOM_DIR is not an ogx-showroom checkout (setup.sh/provision.sh missing)" >&2
  exit 1
}
[[ $SKIP_HELLO_TEST == true || $SKIP_HELLO_TEST == false ]] || {
  echo 'SKIP_HELLO_TEST must be true or false' >&2
  exit 1
}
for tool in oc helm; do
  command -v "$tool" >/dev/null
done
oc whoami >/dev/null

# 1. Stand up the RHOAI operator + full OGX stack (PostgreSQL, Milvus, MinIO,
#    etcd, Keycloak, telemetry, ogx-distribution) via the showroom charts.
#    All verbose output goes to stderr: stdout carries only the export lines.
"$SHOWROOM_DIR/setup.sh" >&2
"$SHOWROOM_DIR/provision.sh" >&2

# 2. Verify OGX is functional before switching modes. The showroom hello
#    demos authenticate the legacy way, so this only works while OGX is NOT
#    yet in praxis mode: skip it on re-runs over an already-switched CR (the
#    operator's HealthCheck condition and the waits below cover that case).
#    Run from the showroom checkout: its test.sh drives demos via `uv run`,
#    which resolves the project (and its pyyaml dependency) from the working
#    directory.
praxis_already=$(oc -n "$OGX_NAMESPACE" get "ogxserver/$OGX_NAME" \
  -o jsonpath='{.spec.praxisMode.enabled}' 2>/dev/null || true)
if [[ $SKIP_HELLO_TEST != true && $praxis_already != true ]]; then
  (cd "$SHOWROOM_DIR" && ./test.sh hello) >&2
else
  echo "Skipping hello check (OGX already in praxis mode or SKIP_HELLO_TEST=true)" >&2
fi

# 3. Remove the external Route: OGX is internal-only from here on
#    (praxis-gateway fronts it). The operator only removes its own Ingress,
#    not this helm-managed Route, so it must go via the chart.
helm upgrade ogx-rhoai "$SHOWROOM_DIR/charts/ogx-rhoai" \
  -n "$OGX_NAMESPACE" \
  -f "$SHOWROOM_DIR/values-local.yaml" \
  --set route.enabled=false \
  --wait --timeout 5m >&2

# 4. Provide the base config for praxis-mode config generation. Praxis mode
#    makes the operator regenerate the runtime config (switching auth to
#    upstream_header); its default source is the distribution image's OCI
#    labels, which registry.redhat.io serves only to authenticated clients
#    (the operator fetches anonymously -> HTTP 401, phase Failed). The
#    spec.baseConfig ConfigMap takes precedence over OCI label resolution and
#    keeps the generation pipeline in play. The image ships the same config
#    (pre-env-substitution) at /opt/app-root/config.yaml; extract it from the
#    running pod so it is always version-matched.
BASE_CONFIGMAP="$OGX_NAME-base-config"
base_config=$(mktemp)
oc -n "$OGX_NAMESPACE" exec "deployment/$OGX_NAME" -- cat /opt/app-root/config.yaml \
  >"$base_config"
oc -n "$OGX_NAMESPACE" create configmap "$BASE_CONFIGMAP" \
  --from-file=config.yaml="$base_config" --dry-run=client -o yaml \
  | oc -n "$OGX_NAMESPACE" apply -f - >&2
rm -f "$base_config"
oc -n "$OGX_NAMESPACE" label configmap "$BASE_CONFIGMAP" ogx.io/watch=true --overwrite >&2

# 5. Switch OGX to praxis-fronted mode via the OGXServer CRD: auth switches
#    to upstream_header (identity injected by praxis-gateway) and ingress is
#    restricted by NetworkPolicy to the praxis-gateway pods.
oc -n "$OGX_NAMESPACE" patch "ogxserver/$OGX_NAME" --type merge \
  -p "{\"spec\":{\"baseConfig\":{\"name\":\"$BASE_CONFIGMAP\",\"key\":\"config.yaml\"},\"praxisMode\":{\"enabled\":true}}}" >&2

# 6. Wait for the operator to reconcile the new mode and roll out.
oc -n "$OGX_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Ready \
  "ogxserver/$OGX_NAME" --timeout=300s >&2
oc -n "$OGX_NAMESPACE" rollout status "deployment/$OGX_NAME" --timeout=300s >&2

# 7. Discover the endpoint and verify OGX is actually reachable on-cluster
#    (service exists and has ready endpoints).
oc -n "$OGX_NAMESPACE" get "svc/$OGX_SERVICE" >/dev/null
endpoints=$(oc -n "$OGX_NAMESPACE" get endpoints "$OGX_SERVICE" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
[[ -n $endpoints ]] || {
  echo "No ready endpoints behind $OGX_SERVICE:$OGX_PORT" >&2
  exit 1
}
echo "OGX endpoints: $endpoints" >&2

OGX_ENDPOINT="$OGX_SERVICE.$OGX_NAMESPACE.svc.cluster.local:$OGX_PORT"
echo "export OGX_ENDPOINT='$OGX_ENDPOINT'"
echo "export OGX_NAMESPACE='$OGX_NAMESPACE'"
echo "export OGX_SERVICE='$OGX_SERVICE'"
echo "export OGX_PORT='$OGX_PORT'"
