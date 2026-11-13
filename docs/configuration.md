# Configuration

Configure the chart with Helm values (`--set` or `-f values.yaml`). Settings the
pipeline config uses live under `global`, because the praxis-gateway subchart
renders its config from them. Defaults are in
[`charts/praxis-agentic-apis/values.yaml`](../charts/praxis-agentic-apis/values.yaml).

| Value | Default | Purpose |
| --- | --- | --- |
| `global.inference.host` | `api.openai.com` | HTTPS backend hostname and TLS SNI |
| `global.inference.port` | `443` | HTTPS backend port |
| `global.inference.secretName` | `openai` | Secret with the backend key |
| `global.ogx.namespace` | `redhat-ods-applications` | Existing OGX namespace |
| `global.ogx.service` | `ogx-distribution-service` | Existing OGX Service |
| `global.ogx.port` | `8321` | OGX HTTP and NetworkPolicy port |
| `global.ogx.endpoint` | `<service>.<namespace>.svc.cluster.local:<port>` | OGX host:port override |
| `global.ogx.networkPolicy.enabled` | `true` | Create `${RELEASE}-ogx` in the OGX namespace |
| `global.ogx.networkPolicy.podSelector` | `app: ogx`, `app.kubernetes.io/instance: ogx-distribution` | OGX pod labels |
| `global.mcp.serverUrl` | `http://openshift-mcp:8080/mcp` | MCP server for the `mcp-server` connector |
| `openshiftMcp.enabled` | `true` | Deploy OpenShift MCP resources; requires the MCP Lifecycle Operator |
| `openshiftMcp.image` | see values file | Pinned OpenShift MCP server image |
| `openshiftMcp.operatorNamespace` | `redhat-ods-applications` | Operator namespace allowed by MCP ingress policy |
| `global.webSearch.enabled` | `false` | Enable Brave web search |
| `global.webSearch.secretName` | `brave-search` | Secret with the Brave key |
| `global.database.host` | empty (deploy in-chart PostgreSQL) | External PostgreSQL hostname |
| `global.database.port` | `5432` | PostgreSQL port |
| `global.database.name` | `praxis` | PostgreSQL database; must be dedicated to Praxis |
| `global.database.user` | `praxis` | PostgreSQL user |
| `global.database.sslMode` | `disable` in-chart, `verify-full` external | `disable`, `prefer`, `require`, `verify-ca`, or `verify-full` |
| `global.database.secretName` | `${RELEASE}-postgres` | Secret with the PostgreSQL password |
| `postgres.*` | see values file | In-chart PostgreSQL image, volume size, and resources |
| `praxis-gateway.*` | see values file | [praxis-gateway chart](https://github.com/praxis-proxy/grid/tree/main/charts/praxis-gateway) values: image, resources, env, probes, NetworkPolicy, pipeline |

`global.inference.host` must be a hostname, without scheme or path. The default
pipeline uses HTTPS and `/v1/chat/completions`; other transports or API paths
require an alternate pipeline. `global.ogx.endpoint` does not change the
NetworkPolicy target, so keep its namespace, pod labels, and port consistent
with your OGX deployment.

## OpenShift MCP

The chart owns `mcp-viewer` (ServiceAccount), `mcp-viewer-view` (RoleBinding),
`openshift-mcp-server-config` (ConfigMap), and `openshift-mcp` (MCPServer).
The MCP Lifecycle Operator creates the server Deployment, Service, and
NetworkPolicy. Enable the operator before installing the chart; see
[setup](../README.md#mcp-server).

To adopt manually installed resources into this release before upgrading:

```bash
resources=(serviceaccount/mcp-viewer rolebinding/mcp-viewer-view
  configmap/openshift-mcp-server-config mcpserver/openshift-mcp)
oc -n "$NAMESPACE" label "${resources[@]}" \
  app.kubernetes.io/managed-by=Helm --overwrite
oc -n "$NAMESPACE" annotate "${resources[@]}" \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" --overwrite
```

Only adopt resources not owned by another Helm release. Disabling
`openshiftMcp.enabled` or uninstalling the chart removes these resources and
the operator-managed server. To use an external server instead, also set
`global.mcp.serverUrl` to its URL.

## Credentials

Praxis reads credentials from these namespace-local Secrets:

| Env | Secret (value) / key | Notes |
| --- | --- | --- |
| `OPENAI_API_KEY` | `global.inference.secretName` / `OPENAI_API_KEY` | Inference backend key |
| `WEB_SEARCH_API_KEY` | `global.webSearch.secretName` / `WEB_SEARCH_API_KEY` | Optional; used only when web search is enabled |
| `PGPASSWORD` | `global.database.secretName` / `POSTGRESQL_PASSWORD` | Created by the chart for the in-chart PostgreSQL |

Keep credentials in Secrets, not values or pipeline files.

## Alternate pipelines

The pipeline is `praxis-gateway.praxisConfig.byo.inline`, rendered as a Helm
template with `tpl`, so it can reference `.Values.global.*`, `.Release.Name`,
and `.Release.Namespace`. Replace it with a values file:

```bash
helm upgrade --install "$RELEASE" charts/praxis-agentic-apis -n "$NAMESPACE" \
  -f my-pipeline-values.yaml
```

Escape a literal `{{` in the pipeline as `{{ "{{" }}`. Alternate pipelines must
retain the API listener on `0.0.0.0:8080`, admin listener on `127.0.0.1:9901`,
and the `openai_conversations` and `openai_responses_store` filters to use the
existing access, probes, tests, and storage setup unchanged. Include the
`openai_web_search_dispatch` filter, guarded by `global.webSearch.enabled`, to
support search.

## Web search

`global.webSearch.enabled=true` keeps the default pipeline's
`openai_web_search_dispatch` filter, which reads `WEB_SEARCH_API_KEY`. When
disabled, the filter is left out and the optional Brave Secret is not needed.

When enabled, Helm installs and upgrades check that the configured Brave Secret
has a nonempty `WEB_SEARCH_API_KEY`. Offline `helm template` renders do not check
cluster Secrets.

See the [setup instructions](../README.md#optional-web-search) for Secret creation.
Requests use `tools: [{"type":"web_search"}]`; use
`tool_choice: {"type":"web_search"}` to require an initial search, and
`include: ["web_search_call.action.sources"]` to return source URLs. Search runs
before MCP and file-search dispatch inside the existing iterative router.

## Chart and image

- Chart: `charts/praxis-agentic-apis`, depending on `praxis-gateway`
  `0.3.0` from `oci://ghcr.io/praxis-proxy/charts`
- Image: `ghcr.io/praxis-proxy/ai:latest-experimental` (praxis-ai `0.9.0-experimental`,
  revision `e8882954`), pinned in the chart values to
  `sha256:458ab783a75809c7c091aff25f6c67034380d574022cde2d8b0c3b3cbe22e48c`

The image digest takes precedence over the tag. To select another image, set
`praxis-gateway.image.repository` and `praxis-gateway.image.digest`, or set
`praxis-gateway.image.tag` with `praxis-gateway.image.digest=""`. Stable
`ghcr.io/praxis-proxy/ai` images from 0.8.0 exclude the experimental Responses
and agentic loop filters this config uses; use a `-experimental` tag or build with
`--build-arg PRAXIS_AI_FEATURES=full,openai-all,store-postgres`.

## Storage and upgrades

Responses and Conversations are stored in PostgreSQL, so they survive
pod restarts, upgrades, and uninstalls. Praxis creates and validates its tables at
startup; the database must be empty or already hold the current Praxis schema.
Schema upgrades are recreate-only: when a Praxis release changes the schema, back
up and recreate the database (see the Praxis AI
[schema upgrade guide](https://github.com/praxis-proxy/ai/blob/main/docs/store/schema-migration.md)).

A custom image must include the `store-postgres` feature.

### In-chart PostgreSQL

With `global.database.host` empty, the chart deploys a single-replica PostgreSQL 16
Deployment, a 1 GiB PersistentVolumeClaim (`${RELEASE}-postgres`), a Service on
`global.database.port` (default 5432), and a
NetworkPolicy admitting only this release's Praxis pods on port 5432. It creates the
Secret named by `global.database.secretName` (default `${RELEASE}-postgres`) with keys
`POSTGRESQL_USER`, `POSTGRESQL_DATABASE` (from `global.database.user` and
`global.database.name`), and a random `POSTGRESQL_PASSWORD`. The password of an
existing Secret is reused, since the data directory was initialized with it. Traffic
stays in the namespace and is not encrypted (`sslMode` `disable`).

This is a preview database: no backups, high availability, or tuning.
`helm uninstall` removes the PostgreSQL Deployment, Service, and NetworkPolicy
but keeps the PVC and Secret, so reinstalling restores the stored state. See
[uninstall](../README.md#uninstall) to delete them as well.

### External PostgreSQL

Set `global.database.host` to use an existing server. Create a namespace-local
Secret with the password first:

```bash
read -rsp 'PostgreSQL password: ' PGPASSWORD
printf '\n'
oc -n "$NAMESPACE" create secret generic "$RELEASE-postgres" \
  --from-file=POSTGRESQL_PASSWORD=<(printf %s "$PGPASSWORD") \
  --dry-run=client -o yaml | oc apply --server-side -f -
unset PGPASSWORD

helm upgrade --install "$RELEASE" charts/praxis-agentic-apis -n "$NAMESPACE" \
  --set global.database.host=db.example.com \
  --set global.database.name=praxis --set global.database.user=praxis --wait
```

To use another Secret name, set `global.database.secretName`.

Use a database dedicated to Praxis. The password reaches Praxis only as the
`PGPASSWORD` environment variable; the rendered `database_url` holds no
credentials. TLS defaults to `verify-full` against the image's system trust
store. Server certificates from a private CA, and client-certificate
authentication, need a custom pipeline using `ssl_root_cert`/`ssl_client_cert`
plus a values override mounting the files. The default pipeline sets
`allow_private_database_url: true` so cluster DNS names and private addresses
are accepted. The chart does not add egress policies.

Changing a Secret requires a pod restart to load the new value:

```bash
oc -n "$NAMESPACE" rollout restart "deployment/$RELEASE"
```
