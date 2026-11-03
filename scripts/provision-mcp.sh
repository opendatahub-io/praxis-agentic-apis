#!/usr/bin/env bash
# T2.2: Provision the OpenShift MCP server for the mcp tier of the E2E
# harness. Applies infra/mcp/openshift/mcpserver.yaml into the gateway
# namespace, waits until the MCPServer is ready, and prints the
# MCP_SERVER_URL the gateway must be deployed with.
#
# Usage:
#   NAMESPACE=praxis-standalone scripts/provision-mcp.sh
#
# Inputs (env):
#   NAMESPACE       where to run the MCP server (default praxis-standalone;
#                   the gateway reaches it via the printed URL)
#   OPERATOR_WAIT   seconds to wait for the mcplifecycleoperator to appear
#                   after enabling its DSC component (default 600)
#   READY_WAIT      seconds to wait for the MCPServer to become ready
#                   (default 300)
#
# API-version handling: the manifest targets mcp.x-k8s.io/v1beta1 (condition
# Verified, spec.network.ingressFrom). RHOAI 3.6 EA clusters serve v1alpha1
# (conditions Accepted/Ready, no spec.network); for those the manifest is
# converted on the fly — apiVersion rewritten, spec.network dropped — and the
# Ready condition is awaited instead.
#
# If the MCPServer CRD is absent the script enables the DSC component
# (mcplifecycleoperator: Managed) and waits for the CRD. Any failure exits
# nonzero; callers (tests/e2e.sh) fall back to the everything test server.
#
# Output (stdout): the URL the gateway needs, e.g.
#   http://openshift-mcp.praxis-standalone.svc.cluster.local:8080/mcp
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

NAMESPACE=${NAMESPACE:-praxis-standalone}
OPERATOR_WAIT=${OPERATOR_WAIT:-600}
READY_WAIT=${READY_WAIT:-300}

command -v oc >/dev/null
command -v python3 >/dev/null
python3 -c 'import yaml'
oc whoami >/dev/null

crd=mcpservers.mcp.x-k8s.io
if ! oc get crd "$crd" >/dev/null 2>&1; then
  echo "MCPServer CRD not found; enabling DSC component mcplifecycleoperator" >&2
  oc patch dsc default-dsc --type merge \
    -p '{"spec":{"components":{"mcplifecycleoperator":{"managementState":"Managed"}}}}' >&2
  for ((i = 0; i < OPERATOR_WAIT; i += 10)); do
    oc get crd "$crd" >/dev/null 2>&1 && break
    sleep 10
  done
  oc get crd "$crd" >/dev/null 2>&1 || {
    echo "mcplifecycleoperator did not come up within ${OPERATOR_WAIT}s" >&2
    exit 1
  }
fi

oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >&2

if oc get crd "$crd" -o jsonpath='{.spec.versions[*].name}' | grep -qw v1beta1; then
  oc apply -f "$ROOT/infra/mcp/openshift/mcpserver.yaml" -n "$NAMESPACE" >&2
  condition=Verified
else
  # Convert the v1beta1 manifest to the served v1alpha1: rewrite apiVersion
  # and drop spec.network (not in v1alpha1; the operator applies its own
  # network policy).
  python3 - "$ROOT/infra/mcp/openshift/mcpserver.yaml" <<'PY' | oc apply -n "$NAMESPACE" -f - >&2
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for doc in docs:
    if doc.get("kind") == "MCPServer":
        doc["apiVersion"] = "mcp.x-k8s.io/v1alpha1"
        doc["spec"].pop("network", None)
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
PY
  condition=Ready
fi

oc wait --for=condition="$condition" "mcpserver/openshift-mcp" -n "$NAMESPACE" \
  --timeout="${READY_WAIT}s" >&2

# Prefer the operator-reported address; fall back to the well-known service.
url=$(oc -n "$NAMESPACE" get mcpserver openshift-mcp \
  -o jsonpath='{.status.address.url}' 2>/dev/null || true)
echo "${url:-http://openshift-mcp:8080/mcp}"
