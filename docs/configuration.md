# Configuration

Set these environment variables before running `scripts/deploy.sh`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NAMESPACE` | `praxis-standalone` | Praxis namespace |
| `RELEASE` | `praxis-gateway` | Helm release, Deployment, and Service name |
| `CONFIG_DIR` | Repository `configs/openai-ogx` | Configuration directory |
| `CONFIG_FILE` | `${CONFIG_DIR}/config.yaml` | Praxis pipeline configuration |
| `VALUES_FILE` | `${CONFIG_DIR}/values.yaml` | Helm values override file |
| `API_KEY_SECRET` | `openai` | Namespace-local backend credential Secret |
| `API_KEY_SECRET_KEY` | `OPENAI_API_KEY` | Key within that Secret |
| `ENABLE_WEB_SEARCH` | `false` | Enable Brave web search (`true` or `false`) |
| `WEB_SEARCH_API_KEY_SECRET` | `brave-search` | Namespace-local Brave credential Secret; required only when web search is enabled |
| `WEB_SEARCH_API_KEY_SECRET_KEY` | `WEB_SEARCH_API_KEY` | Key within the Brave Secret |
| `INFERENCE_HOST` | `api.openai.com` | HTTPS backend hostname and TLS SNI |
| `INFERENCE_PORT` | `443` | HTTPS backend port |
| `MCP_SERVER_URL` | `http://mcp-test:3001/mcp` | MCP server for the `mcp-server` connector; set `http://openshift-mcp:8080/mcp` for the OpenShift MCP server |
| `DATABASE_HOST` | Empty (deploy in-repo PostgreSQL) | External PostgreSQL hostname; when empty, the installer deploys `infra/postgres` |
| `DATABASE_PORT` | `5432` | PostgreSQL port |
| `DATABASE_NAME` | `praxis` | PostgreSQL database; must be dedicated to Praxis |
| `DATABASE_USER` | `praxis` | PostgreSQL user |
| `DATABASE_SECRET` | `${RELEASE}-postgres` | Namespace-local Secret holding the PostgreSQL password; external databases only |
| `DATABASE_SECRET_KEY` | `POSTGRESQL_PASSWORD` | Key within that Secret; external databases only |
| `DATABASE_SSL_MODE` | `disable` in-repo, `verify-full` external | PostgreSQL TLS mode: `disable`, `prefer`, `require`, `verify-ca`, or `verify-full` |
| `OGX_NAMESPACE` | `redhat-ods-applications` | Existing OGX namespace |
| `OGX_SERVICE` | `ogx-distribution-service` | Existing OGX Service |
| `OGX_PORT` | `8321` | OGX HTTP and NetworkPolicy port |
| `OGX_ENDPOINT` | `${OGX_SERVICE}.${OGX_NAMESPACE}.svc.cluster.local:${OGX_PORT}` | OGX host:port override |
| `OGX_APP_LABEL` | `ogx` | OGX pod selector's `app` value |
| `OGX_INSTANCE_LABEL` | `ogx-distribution` | OGX pod selector's `app.kubernetes.io/instance` value |
| `PRAXIS_IMAGE_REPO` | unset | Override `image.repository`; unset uses `configs/common-values.yaml` |
| `PRAXIS_IMAGE_TAG` | unset | Override `image.tag`; clears the pinned digest so the tag takes effect |
| `PRAXIS_IMAGE_DIGEST` | unset | Override `image.digest` (takes precedence over `PRAXIS_IMAGE_TAG`) |

`INFERENCE_HOST` must be a hostname, without scheme or path. The default pipeline
uses HTTPS and `/v1/chat/completions`; other transports or API paths require an
alternate config. `OGX_ENDPOINT` does not change the NetworkPolicy target, so
keep its namespace, pod labels, and port consistent with your OGX deployment.

## Multiple configurations

Each configuration directory contains a pipeline `config.yaml` and matching
Helm `values.yaml`. The default is `configs/openai-ogx`. Shared Helm defaults,
including the image pin, probes, and resources, live in `configs/common-values.yaml`.

From the repository root, select a configuration directory:

```bash
CONFIG_DIR=configs/openai-ogx bash ./scripts/deploy.sh
```

Add future configurations as sibling directories. Individual file overrides are
also supported:

```bash
CONFIG_FILE=/path/to/pipeline.yaml \
VALUES_FILE=/path/to/overrides.yaml \
bash ./scripts/deploy.sh
```

Relative directory and file paths resolve from your current working directory.
Helm values are loaded in order: `configs/common-values.yaml`, the selected
directory's `values.yaml`, then `VALUES_FILE`. Later values take precedence.
`CONFIG_FILE` replaces the selected directory's pipeline. The installer sets the
resource name to `RELEASE` and overrides the first environment entry's Secret
reference; retain `OPENAI_API_KEY` as that entry when overriding `env`. The
installer appends `WEB_SEARCH_API_KEY` (when web search is enabled) and then
`PGPASSWORD` (when using PostgreSQL) after it, so keep `env` to that one entry.

Pipeline files can use `${OGX_ENDPOINT}`, `${INFERENCE_HOST}`,
`${INFERENCE_PORT}`, `${MCP_SERVER_URL}`, `${DATABASE_URL}`, and
`${DATABASE_SSL_MODE}`. Only these placeholders are substituted before
deployment; other dollar signs are preserved.
Keep credentials in Secrets, not config files.
Alternate configs must retain the API listener on `0.0.0.0:8080`, admin listener on
`127.0.0.1:9901`, and the `openai_conversations` and `openai_responses_store` filters
to use the existing access, probes, tests, and storage setup unchanged. OGX remains a
prerequisite for the installer.

## Web search

`ENABLE_WEB_SEARCH=true` retains the default pipeline's
`openai_web_search_dispatch` filter and injects `WEB_SEARCH_API_KEY` from the
selected Kubernetes Secret. The installer fails if the Secret or a nonempty key
is missing. The shared key is used only for Brave provider callouts.

When disabled, the installer removes web-search dispatch filters and does not
add the search credential environment entry. No Brave Secret is needed. Custom
pipelines must include the dispatcher to support search when enabled. Don't add
`WEB_SEARCH_API_KEY` to `env` in values files.

See the [setup instructions](../README.md#optional-web-search) for Secret creation.
Requests use `tools: [{"type":"web_search"}]`; use
`tool_choice: {"type":"web_search"}` to require an initial search, and
`include: ["web_search_call.action.sources"]` to return source URLs. Search runs
before MCP and file-search dispatch inside the existing iterative router.

## Chart and image

- Source: https://github.com/praxis-proxy/grid
- Chart: `oci://ghcr.io/praxis-proxy/charts/praxis-gateway`, version `0.2.1`
- Image: `ghcr.io/praxis-proxy/ai:latest-experimental` (praxis-ai `0.9.0-experimental`,
  revision `e8882954`), pinned in `configs/common-values.yaml` to
  `sha256:458ab783a75809c7c091aff25f6c67034380d574022cde2d8b0c3b3cbe22e48c`

The image digest takes precedence over the tag. To select another image, set its
repository and digest in your values override file. Stable `ghcr.io/praxis-proxy/ai`
images from 0.8.0 exclude the experimental Responses and agentic loop filters this config
uses; use a `-experimental` tag or build with
`--build-arg PRAXIS_AI_FEATURES=full,openai-all,store-postgres`.

The installer passes the pipeline as standard Helm values and does not use a
post-renderer, so Helm 3 and Helm 4 are both supported.

## Storage and upgrades

Responses and Conversations are stored in PostgreSQL, so they survive
pod restarts, upgrades, and uninstalls. Praxis creates and validates its tables at
startup; the database must be empty or already hold the current Praxis schema.
Schema upgrades are recreate-only: when a Praxis release changes the schema, back
up and recreate the database (see the Praxis AI
[schema upgrade guide](https://github.com/praxis-proxy/ai/blob/main/docs/store/schema-migration.md)).

A custom image must include the `store-postgres` feature.

### In-repo PostgreSQL

With `DATABASE_HOST` unset, the installer deploys `infra/postgres/postgres.yaml` in
`$NAMESPACE` before Praxis: a single-replica PostgreSQL 16 Deployment, a 1 GiB
PersistentVolumeClaim, a Service, and a NetworkPolicy admitting only this release's
Praxis pods on port 5432. On first deploy it creates the Secret `${RELEASE}-postgres`
with keys `POSTGRESQL_USER`, `POSTGRESQL_DATABASE` (from `DATABASE_USER` and
`DATABASE_NAME`), and a random `POSTGRESQL_PASSWORD`. An existing Secret is reused
unchanged. Traffic stays in the namespace and is not encrypted (`DATABASE_SSL_MODE=disable`).

This is a preview database: no backups, high availability, or tuning.
`scripts/cleanup.sh` removes the PostgreSQL Deployment, Service, and
NetworkPolicy but keeps the PVC and Secret, so reinstalling restores the stored
state. Run `PURGE_DATABASE=true bash ./scripts/cleanup.sh` to delete them as well.

### External PostgreSQL

Set `DATABASE_HOST` to use an existing server. Create a namespace-local Secret with
the password first; the installer fails if it is missing:

```bash
read -rsp 'PostgreSQL password: ' PGPASSWORD
printf '\n'
oc -n "$NAMESPACE" create secret generic praxis-postgres \
  --from-file=POSTGRESQL_PASSWORD=<(printf %s "$PGPASSWORD") \
  --dry-run=client -o yaml | oc apply --server-side -f -
unset PGPASSWORD

DATABASE_HOST=db.example.com DATABASE_SECRET=praxis-postgres \
DATABASE_NAME=praxis DATABASE_USER=praxis \
bash ./scripts/deploy.sh
```

Use a database dedicated to Praxis. The password reaches Praxis only as the
`PGPASSWORD` environment variable; the rendered `database_url` holds no
credentials. TLS defaults to `verify-full` against the image's system trust
store. Server certificates from a private CA, and client-certificate
authentication, need a custom pipeline using `ssl_root_cert`/`ssl_client_cert`
plus a values override mounting the files. The default pipeline sets
`allow_private_database_url: true` so cluster DNS names and private addresses
are accepted. The installer does not add egress policies.

Changing a Secret requires a pod restart to load the new value:

```bash
oc -n "$NAMESPACE" rollout restart "deployment/$RELEASE"
```
