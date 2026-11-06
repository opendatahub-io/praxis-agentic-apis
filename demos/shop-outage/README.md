# Shop outage demo

An SRE assistant diagnoses and fixes a broken online shop through Praxis. It
uses the Responses API with three hosted tools: the OpenShift MCP server,
file search over internal runbooks, and Brave web search.

## Scenario

The `shop` namespace runs three workloads:

- `storefront`: web frontend that generates simulated shopper traffic and
  proxies checkout to `checkout-api`.
- `checkout-api` (2 pods): reads its database password from Secret env vars at
  startup. Its readiness probe checks database auth.
- `orders-db`: fake PostgreSQL that checks passwords against the mounted Secret
  on every connection.

`setup.sh` deploys the workloads, rotates the `orders-db-credentials` password,
and uploads the runbooks and incident reports in `docs/` to an OGX vector
store. `checkout-api` keeps the old password, goes NotReady, and storefront
checkout returns 502. The fix is restarting the `checkout-api` pods.

## Run

Prerequisites: Praxis deployed with web search and the OpenShift MCP server
from `infra/mcp/openshift/mcpserver.yaml`, which enables `pods_delete` (see the
top-level [README](../../README.md)).

```bash
demos/shop-outage/setup.sh
oc -n praxis-standalone port-forward deployment/praxis-gateway --address 127.0.0.1 18080:8080 &
demos/shop-outage/sre-assistant
```

Suggested prompts:

1. `Is my shop website running ok?`
2. `restart the pods` (answer `y` to each approval prompt)
3. `It looks like its fixed, create an incident report using our incident ticket format`

Clean up with `demos/shop-outage/cleanup.sh`.

`setup.sh` grants the MCP server's `mcp-viewer` ServiceAccount `view` and a
`pod-restarter` Role (get, list, delete pods) in the workload namespace. The
approval prompt is client-side: `require_approval` is set by the caller, so
anyone who can reach Praxis can delete pods in that namespace. RBAC is the only
limit.

## Request flow

[flow.html](https://opendatahub-io.github.io/praxis-agentic-apis/demos/shop-outage/flow.html)
is an animated diagram of the three prompts, built with the
[FlowStory](https://github.com/noyitz/flowstory) engine. Click a node for its role and configuration, or a
step to jump to it. The inspector shows the request or response at each hop.

Every client request passes through the Praxis filter chains:

- **ingress**: strips client auth headers, sets the fixed owner
  `praxis-standalone`, and routes `/v1/responses` to the Responses chains.
- **responses**: parses the request and tools, loads the history for
  `previous_response_id` from PostgreSQL, and lists the MCP server's tools as
  `openshift__*` function tools.
- **execution**: runs the agentic loop. Each round sends a Chat Completions
  request to OpenAI. Praxis runs the requested tools (MCP `tools/call`, OGX
  vector store search, Brave search), feeds the results into the next round,
  and streams all events to the client as one Responses stream.

The diagram flows:

1. **"Is my shop website running ok?"**: the model lists pods, reads logs and
   events, and searches the runbooks (finding the matching incident,
   INC-4867). It tries to read the `orders-db-credentials` Secret, which the
   MCP server denies, then searches the web. It reports the root cause and
   proposes restarting `checkout-api`.
2. **"restart the pods"**: `pods_delete` requires approval, so Praxis returns
   an `mcp_approval_request` and stores it. The SRE approves, the client sends
   `mcp_approval_response` with `previous_response_id`, and Praxis runs the
   stored call once. This happens for each pod, then the model verifies that
   both new pods are Ready and checkout succeeds.
3. **"create an incident report"**: the model searches the docs for the
   incident ticket format, re-checks the cluster for evidence, and writes the report.
