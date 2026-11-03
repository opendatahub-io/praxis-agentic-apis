# CI

CI for the praxis-agentic-apis developer preview: stand up the full stack
(OGX via [ogx-showroom](https://github.com/opendatahub-io/ogx-showroom) +
praxis-gateway from this repo) on the shared ROSA cluster, run the tests and
the shop-outage demo, and always tear everything down again.

## Pipeline overview

| Workflow | Trigger | What it runs | Cluster | Secrets |
|---|---|---|---|---|
| `mvp.yml` (walking skeleton) | `workflow_dispatch` | showroom OGX provision → `scripts/deploy.sh` → `tests/smoke.sh` → teardown | shared ROSA | yes (Environment `cluster-e2e`) |
| `static.yml` *(planned)* | `pull_request`, push to `main` | shellcheck, yaml-lint, helm render checks | none | **no** |
| `pr.yml` *(planned)* | `pull_request` | free tier only (static + secret-free smoke) | none | **no** |
| `nightly.yml` *(planned)* | `schedule`, `workflow_dispatch` | full suite (`LEVEL=full tests/e2e.sh`) incl. demo | shared ROSA | yes (Environment `cluster-e2e`) |

## Trust boundaries (trigger security)

- `pull_request` runs the **free tier only** — lint, render checks, secret-free
  smoke. Safe for forks; **no secrets are exposed** to PR code.
- Secret-bearing runs (cluster + LiteMaaS + MCP + demo) are triggered only by
  `workflow_dispatch` and `schedule` on trusted refs.
- Secret-bearing jobs run in the protected GitHub Environment **`cluster-e2e`**
  (required reviewers), so even a manual dispatch needs an approval.
- All workflows use `permissions: {}` by default, pin every action by full
  commit SHA, and set `timeout-minutes`.

## Shared-cluster serialization

CI shares the ROSA cluster with ogx-showroom's own CI. Two locks apply:

1. **Repo-local** — each cluster-touching job sets
   `concurrency: { group: openshift-cluster-1, cancel-in-progress: false }`.
   GitHub `concurrency` groups are **repo-scoped**, so this only serializes
   praxis-vs-praxis runs.
2. **Cross-repo (the authoritative mutex)** — the pre-flight clean-cluster wait
   ([`.github/scripts/preflight-cluster-clean.sh`](../.github/scripts/preflight-cluster-clean.sh))
   polls until the cluster carries no leftovers from a previous run of either
   repo: showroom's `rhoai-catalog` CatalogSource + `redhat-ods-operator`
   namespace, and praxis's own namespace (default `praxis-standalone`) +
   `praxis-gateway` Helm release. It waits up to 5 minutes, then fails the
   job. `mvp.yml` runs it after the showroom setup step, before provisioning;
   every future job that touches the cluster must do the same, and must
   clean up in `if: always()` steps so the next job finds a clean cluster.

Tooling: cluster jobs get `oc`/`uv`/`helm` and `oc-login` from the
ogx-showroom composite action; secret-free jobs (e.g. the planned `static.yml`
helm render check) install only what they need (e.g. `azure/setup-helm`).

## OGX-via-showroom composition

praxis-agentic-apis does not install OGX. CI composes the two repos
(the pattern is `mvp.yml`):

1. `uses: opendatahub-io/ogx-showroom@<full-sha>` — the showroom composite
   action provides tool install, `oc-login`, `values-local.yaml` generation and
   the pre-flight wait; its `scripts_dir` output locates
   `setup.sh`/`provision.sh`/`test.sh`.
2. `"$scripts_dir/setup.sh" && "$scripts_dir/provision.sh"` — OGX comes up.
3. `"$scripts_dir/test.sh" hello` — health gate **before** switching OGX to
   unauthenticated praxis mode (`--set ogx.auth.enabled=false
   --set route.enabled=false`).
4. `scripts/deploy.sh` — praxis-gateway is installed in front of OGX.
5. tests + demo.
6. `if: always()` teardown: `scripts/cleanup.sh`, namespace deletion, then
   showroom `unprovision.sh` + `cleanup.sh` — each step tracked independently
   so one failure cannot skip the rest.

Showroom is expected to expose a provision-only reusable workflow
(`workflow_dispatch`-style `provision-ogx.yml`) later; CI will migrate to
`uses: opendatahub-io/ogx-showroom/.github/workflows/provision-ogx.yml@<sha>`
when it lands. Until then we consume the composite action pinned by SHA.

## Secrets and variables

Secrets live in the protected Environment `cluster-e2e` where possible (never
echoed; never written to artifacts — debug capture is stdout-only so the
console's automatic redaction applies).

| Kind | Name | Used for |
|---|---|---|
| secret | `OC_SERVER` | shared ROSA API URL (`oc-login`) |
| secret | `OC_TOKEN` | shared ROSA token |
| secret | `LITEMAAS_API_KEY` | LiteMaaS inference/embedding backend |
| secret | `SHOWROOM_PULL_SECRET` | cluster pull secret (showroom provisioning) |
| secret | `BRAVE_API_KEY` | web-search tier of the test suite |
| var | `LITEMAAS_URL` | LiteMaaS base URL |
| var | `LITEMAAS_INFERENCE_MODEL` | inference model id |
| var | `LITEMAAS_EMBEDDING_MODEL` | embedding model id |
| var | `VECTOR_STORE_PROVIDER` | OGX vector store (`milvus-remote`) |

Runtime credentials (OGX coordinates, MCP URLs) are read from the cluster at
test time rather than baked into the workflow.

## Image pinning

The praxis-ai image is pinned by digest in `configs/common-values.yaml`.
`scripts/deploy.sh` accepts overrides via `PRAXIS_IMAGE_REPO` / `_TAG` /
`_DIGEST` (validated), and the `mvp.yml` dispatch input `praxis_image` threads
through to them — a passed tag is resolved to a digest with `skopeo inspect`
when available. This lets CI move between image sources (custom quay push →
`ghcr.io/praxis-proxy/ai-experimental` once published) without workflow edits.

The OGX side is pinned via the showroom action's `ogx_image` input when a
specific OGX build must be tested.

## Running the gates locally

The static gates are Makefile targets, so developers run the exact commands
CI runs ([static.yml](../.github/workflows/static.yml)):

```console
$ make tools   # one-time: install pinned yamllint + ruff (pip) and actionlint
$ make lint    # shellcheck + yamllint + actionlint + ruff
$ make render  # chart render dry-run (needs helm; no cluster writes)
```

Tool versions are pinned in the `Makefile` (single source of truth — the
workflow installs from there too). `make render` mirrors `scripts/deploy.sh`'s
render path (envsubst → `helm template` → post-renderer) with cluster-neutral
defaults and asserts the output is valid, non-empty YAML; override the
`OGX_ENDPOINT` / `INFERENCE_HOST` / `INFERENCE_PORT` / `MCP_SERVER_URL` make
variables to render other backends.

## Debugging failed runs

On failure, jobs capture OpenShift state (events, resources, pod logs for the
praxis namespace and `redhat-ods-applications`) in an `if: always()` step.
Output is **stdout-only**: the Actions console auto-redacts secret values;
workflow artifacts are not redacted and must never contain them.
