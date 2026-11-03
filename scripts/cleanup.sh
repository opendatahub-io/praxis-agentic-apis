#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-praxis-standalone}
RELEASE=${RELEASE:-praxis-gateway}
OGX_NAMESPACE=${OGX_NAMESPACE:-redhat-ods-applications}
PURGE_DATABASE=${PURGE_DATABASE:-false}

for tool in helm oc; do
  command -v "$tool" >/dev/null
done
[[ $PURGE_DATABASE == true || $PURGE_DATABASE == false ]] || {
  echo 'PURGE_DATABASE must be true or false' >&2
  exit 1
}

helm uninstall "$RELEASE" --namespace "$NAMESPACE" \
  --ignore-not-found --wait --timeout 5m
oc -n "$OGX_NAMESPACE" delete networkpolicy "${RELEASE}-ogx" --ignore-not-found
# The in-repo PostgreSQL volume and Secret are kept so a reinstall reuses the
# stored Responses and Conversations, unless PURGE_DATABASE=true.
oc -n "$NAMESPACE" delete deployment,service,networkpolicy \
  -l "app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=$RELEASE" \
  --ignore-not-found --wait
if [[ $PURGE_DATABASE == true ]]; then
  oc -n "$NAMESPACE" delete pvc,secret "$RELEASE-postgres" --ignore-not-found
fi
