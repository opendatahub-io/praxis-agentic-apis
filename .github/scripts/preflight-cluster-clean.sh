#!/usr/bin/env bash
# Pre-flight clean-cluster wait.
#
# Cross-repo mutex for the shared ROSA cluster: GitHub Actions `concurrency`
# groups are repo-scoped, so they cannot serialize runs of praxis-agentic-apis
# against runs of ogx-showroom (or anything else). This script is the
# authoritative lock: it waits until the cluster carries no leftovers from a
# previous run of either repo:
#
#   ogx-showroom:  rhoai-catalog CatalogSource + redhat-ods-operator namespace
#   praxis:        NAMESPACE and the praxis-gateway Helm release inside it
#
# Usage (env-driven):
#   NAMESPACE=praxis-standalone RELEASE=praxis-gateway MAX_WAIT=300 INTERVAL=30 \
#     .github/scripts/preflight-cluster-clean.sh
#
# Exits 0 as soon as the cluster is clean, 1 on timeout.

set -euo pipefail

NAMESPACE="${NAMESPACE:-praxis-standalone}"
RELEASE="${RELEASE:-praxis-gateway}"
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-30}"

elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  clean=true

  # ogx-showroom leftovers
  if oc get catalogsource rhoai-catalog -n openshift-marketplace >/dev/null 2>&1; then
    echo "⏳ rhoai-catalog exists - waiting for cleanup..."
    clean=false
  fi
  if oc get namespace redhat-ods-operator >/dev/null 2>&1; then
    echo "⏳ redhat-ods-operator namespace exists - waiting for cleanup..."
    clean=false
  fi

  # praxis leftovers
  if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "⏳ namespace $NAMESPACE exists - waiting for cleanup..."
    clean=false
  elif helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "⏳ helm release $RELEASE exists in $NAMESPACE - waiting for cleanup..."
    clean=false
  fi

  if [ "$clean" = true ]; then
    echo "✓ Cluster is clean and ready"
    exit 0
  fi

  echo "Cluster not clean. Waiting $INTERVAL seconds... (elapsed: ${elapsed}s / ${MAX_WAIT}s)"
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

echo "ERROR: Timeout waiting for cluster to be clean after ${MAX_WAIT}s" >&2
echo "Cluster may still be in use by another job or have orphaned resources" >&2
exit 1
