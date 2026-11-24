#!/usr/bin/env bash
# T2.2: Provision the OpenShift MCP server for the mcp tier of the E2E
# harness. The MCPServer itself is deployed by the Helm chart
# (openshiftMcp.enabled, default on, URL http://openshift-mcp:8080/mcp);
# this script covers the parts around the install:
#
#   prepare (pre-install)  - ensure the MCP Lifecycle Operator and the
#                            MCPServer CRD are available, then print the
#                            MCP_SERVER_URL the gateway must be deployed with
#   wait (post-install)    - wait until the chart-deployed
#                            mcpserver/openshift-mcp is ready
#
# Usage:
#   NAMESPACE=praxis-standalone scripts/provision-mcp.sh prepare
#   NAMESPACE=praxis-standalone scripts/provision-mcp.sh wait
#
# Inputs (env):
#   NAMESPACE       where the gateway (and its OpenShift MCP) runs
#                   (default praxis-standalone)
#   OPERATOR_WAIT   seconds to wait for the mcplifecycleoperator to appear
#                   after enabling its DSC component (default 600)
#   READY_WAIT      seconds to wait for the MCPServer to become ready
#                   (default 300)
#
# If the MCPServer CRD is absent the script enables the DSC component
# (mcplifecycleoperator: Managed) and waits for the CRD. Any failure exits
# nonzero; callers (tests/e2e.sh) fall back to the everything test server.
#
# API-version handling: v1beta1 MCPServers report condition Verified;
# RHOAI 3.6.0 (GA) clusters serve v1alpha1, whose operators report Ready
# instead — `wait` accepts either.
#
# Output (prepare, stdout): the URL the gateway needs, e.g.
#   http://openshift-mcp:8080/mcp
set -euo pipefail

NAMESPACE=${NAMESPACE:-praxis-standalone}
OPERATOR_WAIT=${OPERATOR_WAIT:-600}
READY_WAIT=${READY_WAIT:-300}

command -v oc >/dev/null
oc whoami >/dev/null

cmd=${1:-}
case "$cmd" in
  prepare | wait) ;;
  *) echo "usage: $0 prepare|wait" >&2; exit 1 ;;
esac

crd=mcpservers.mcp.x-k8s.io

if [[ $cmd == prepare ]]; then
  if ! oc get crd "$crd" >/dev/null 2>&1; then
    echo "MCPServer CRD not found; enabling DSC component mcplifecycleoperator" >&2
    oc patch dsc default-dsc --type merge \
      -p '{"spec":{"components":{"mcplifecycleoperator":{"managementState":"Managed"}}}}' >&2
    for ((i = 0; i < OPERATOR_WAIT; i += 10)); do
      oc get crd "$crd" >/dev/null 2>&1 && break
      sleep 10
    done
    oc get crd "$crd" >/dev/null 2>&1 || {
      echo "MCPServer CRD still missing after ${OPERATOR_WAIT}s" >&2
      exit 1
    }
  fi
  echo "http://openshift-mcp:8080/mcp"
  exit 0
fi

# wait: v1beta1 operators report Verified, v1alpha1 report Ready.
if oc -n "$NAMESPACE" get mcpserver openshift-mcp \
  -o jsonpath='{.status.conditions[*].type}' | grep -qw Ready; then
  condition=Ready
else
  condition=Verified
fi
oc -n "$NAMESPACE" wait --for=condition="$condition" \
  mcpserver/openshift-mcp --timeout="${READY_WAIT}s"
