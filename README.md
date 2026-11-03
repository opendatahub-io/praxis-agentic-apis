# Standalone Praxis

Demonstration of the Responses API, Conversations, and agentic tool loop
using standalone Praxis. Inference uses an OpenAI-compatible HTTPS Chat
Completions backend. Files, Vector Stores, and hosted file search
require an existing OGX deployment.
Optional hosted web search uses Brave Search. Responses and Conversations
are stored in PostgreSQL, deployed alongside Praxis by default.

This is an **unauthenticated, single-user preview, not for production**. All
requests share the fixed owner `praxis-standalone`. The API is accessible from
pods in its namespace or through port-forwarding. No public Route is configured.

## Prerequisites

- A Kubernetes/OpenShift cluster with the intended context selected in `oc`.
- Bash, Helm, `oc`, Python 3 with PyYAML, and `envsubst` (GNU gettext).
- An inference backend API key and a model supporting tool calls.
- OGX with Files/Vector Stores, an embedding model, and a vector store provider.
- Permission to install in the target namespace and manage NetworkPolicies in
  both the target and OGX namespaces.
- A default StorageClass for the in-repo PostgreSQL volume, or an existing
  PostgreSQL database (see [storage](docs/configuration.md#storage-and-upgrades)).

OGX and inference backends are not installed by this repository.

## Install

Run these commands from the repository root. Select deployment settings before
creating the Secret; exported settings also apply to deployment and tests:

```bash
export NAMESPACE=praxis-standalone
export RELEASE=praxis-gateway
export API_KEY_SECRET=openai
export API_KEY_SECRET_KEY=OPENAI_API_KEY
```

Read the backend key interactively, or supply it through your secret manager.
Create the namespace first so the Secret can be created before deployment.
The installer also ensures the namespace exists. This creates or refreshes the
Secret without writing the key to a local file:

```bash
set +x
read -rsp 'Backend API key: ' OPENAI_API_KEY
printf '\n'
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc -n "$NAMESPACE" create secret generic "$API_KEY_SECRET" \
  --from-file="$API_KEY_SECRET_KEY"=<(printf %s "$OPENAI_API_KEY") \
  --dry-run=client -o yaml | oc apply --server-side -f -
unset OPENAI_API_KEY

bash ./scripts/deploy.sh
```

The installer ensures the Praxis namespace exists, deploys PostgreSQL from
`infra/postgres/` (generating its credential Secret `${RELEASE}-postgres` on first
run), then creates or updates NetworkPolicies before installing the published
Helm chart:
- `${RELEASE}-ingress` allows only same-namespace pods to reach this release's
  Praxis pods on port 8080. Egress is unchanged; port-forwarding remains available.
- `${RELEASE}-ogx` permits this release's pods to reach the selected OGX pods
  on `OGX_PORT` in the OGX namespace.
- `${RELEASE}-postgres` allows only this release's Praxis pods to reach
  PostgreSQL on port 5432.

Existing policies are not edited; their allowed traffic remains allowed. Adding
an ingress policy can restrict previously unisolated pods, so review the target
labels first. Namespace isolation is not authentication: all allowed callers
share the same Praxis identity and data.

See [configuration](docs/configuration.md) for deployment settings, selecting
multiple configs, the pinned chart/image, and storage/upgrade behavior,
including using an external PostgreSQL (`DATABASE_HOST`) or SQLite
(`STORE_BACKEND=sqlite`).

The default config is `configs/openai-ogx/`, with shared Helm defaults in
`configs/common-values.yaml`. Select another directory with `CONFIG_DIR`:

```bash
CONFIG_DIR=configs/openai-ogx bash ./scripts/deploy.sh
```

### Optional web search

Web search is disabled by default. To enable it, create a namespace-local Secret
with your Brave Search API key, then deploy with `ENABLE_WEB_SEARCH=true`:

```bash
export WEB_SEARCH_API_KEY_SECRET=brave-search
export WEB_SEARCH_API_KEY_SECRET_KEY=WEB_SEARCH_API_KEY
set +x
read -rsp 'Brave Search API key: ' WEB_SEARCH_API_KEY
printf '\n'
oc -n "$NAMESPACE" create secret generic "$WEB_SEARCH_API_KEY_SECRET" \
  --from-file="$WEB_SEARCH_API_KEY_SECRET_KEY"=<(printf %s "$WEB_SEARCH_API_KEY") \
  --dry-run=client -o yaml | oc apply --server-side -f -
unset WEB_SEARCH_API_KEY

ENABLE_WEB_SEARCH=true bash ./scripts/deploy.sh
```

All callers share this key and its billing account. Requests opt into search with
`tools: [{"type":"web_search"}]`. Praxis executes Brave searches and feeds results
back to the model through the agentic loop. To disable search, redeploy without
`ENABLE_WEB_SEARCH=true`; the Secret is left in place.

### MCP server

Praxis has one MCP connector, `mcp-server`, pointing at `MCP_SERVER_URL`.
Requests use
`tools: [{"type":"mcp","server_label":"<label>","connector_id":"mcp-server","require_approval":"never"}]`.
Deploy one of these servers in `$NAMESPACE`:

- Test server (default URL), used by `tests/mcp.sh`:

  ```bash
  oc -n "$NAMESPACE" apply -f infra/mcp/everything/deployment.yaml
  bash ./scripts/deploy.sh
  ```

- OpenShift MCP Server from the RHOAI MCP catalogue, deployed through the MCP
  Lifecycle Operator (requires the `mcplifecycleoperator` DataScienceCluster
  component to be `Managed`):

  ```bash
  oc -n "$NAMESPACE" apply -f infra/mcp/openshift/mcpserver.yaml
  oc -n "$NAMESPACE" wait mcpserver/openshift-mcp --for=condition=Verified --timeout=300s
  MCP_SERVER_URL=http://openshift-mcp:8080/mcp bash ./scripts/deploy.sh
  ```

  It uses the `core` toolset with `enabled_tools` limited to read tools plus
  `pods_delete`, and a ServiceAccount bound to `view` in `$NAMESPACE` only, so it
  can read pods, logs, events, and resources there but not Secrets or other
  namespaces. `view` does not allow deleting pods; a namespace needs an extra
  Role for that, as the [shop-outage demo](demos/shop-outage/README.md) adds.
  Its NetworkPolicy admits only Praxis pods and the operator in
  `redhat-ods-applications`. Anyone who can reach Praxis can use these tools.
  `require_approval` is chosen by the caller, so it is not an access control;
  RBAC is.

## Verify and access

```bash
oc -n "$NAMESPACE" rollout status "deployment/$RELEASE"
oc -n "$NAMESPACE" port-forward "deployment/$RELEASE" 8080:8080
```

In another terminal:

```bash
curl -fsS http://127.0.0.1:8080/v1/conversations \
  -H 'Content-Type: application/json' -d '{}'
```

Delete test conversations through `DELETE /v1/conversations/<id>` when finished.
Stop port-forward with Ctrl-C. View logs with:

```bash
oc -n "$NAMESPACE" logs "deployment/$RELEASE"
```

## Test

Requires `curl` and `jq` in addition to the deployment tools. Run the smoke test
first; it checks health and Conversation create/update/read/delete without
inference calls:

```bash
bash ./tests/smoke.sh
```

The functional tests make four paid Responses requests, normally six inference
calls, plus OGX indexing and search. Set model/provider names to match your
existing backends:

```bash
MODEL=gpt-6-luna \
EMBEDDING_MODEL=vllm-embedding/Nomic-embed-text-v2-moe \
VECTOR_STORE_PROVIDER=milvus-remote \
bash ./tests/responses.sh
```

The shown names are also the defaults. Both tests use `NAMESPACE` and `RELEASE`
from the environment and automatically start localhost-only port-forwards:

| Local port | Pod port | Purpose |
| --- | --- | --- |
| `18080` | `8080` | Praxis API requests |
| `19901` | `9901` | Admin `/healthy` check |

These are temporary local tunnels, not public endpoints. Run the tests separately
and keep those local ports free. They do not use the manual port-forward on 8080.
The functional test checks Conversations,
buffered/streaming Responses, stored response retrieval, previous-response
history, Files, Vector Store indexing/search, and hosted file-search loops.
It requests `reasoning.effort=none`; use a model accepting that option.

With web search enabled, run the separate paid test:

```bash
MODEL=gpt-6-luna bash ./tests/web-search.sh
```

It makes two Responses requests, normally four inference calls, plus Brave
searches. It checks buffered/streaming search loops, returned source URLs, and
stored response retrieval. It uses the same local ports as the other tests.

To validate that state survives a Praxis restart, run the persistence test. It
makes one paid Responses request in a Conversation, runs `oc rollout restart`
on the Praxis Deployment, waits for the old pod to be deleted, then checks that
the Conversation, its items, and the stored Response are unchanged:

```bash
MODEL=gpt-6-luna bash ./tests/persistence.sh
```

It fails with `STORE_BACKEND=sqlite`, which loses state when the pod is replaced.

Tests delete resources they create and stop port-forwarding on exit, including
on failure. Check cleanup errors for resources needing manual deletion. Request
and response artifacts remain in `.cache/` and should not be committed.

## Uninstall

Use the same `NAMESPACE`, `RELEASE`, and `OGX_NAMESPACE` settings and cluster
context as installation:

```bash
bash ./scripts/cleanup.sh
```

This removes the Helm release, its OGX NetworkPolicy, and the in-repo
PostgreSQL Deployment, Service, and NetworkPolicy. It is safe to rerun when
resources are already absent. The PostgreSQL volume and its Secret are kept, so
reinstalling restores stored Responses and Conversations; to delete them too:

```bash
PURGE_DATABASE=true bash ./scripts/cleanup.sh
```

The namespace, credential Secrets, existing OGX deployment, external databases,
and local `.cache/` artifacts remain in place. Files and Vector Stores stored in OGX are not deleted.
