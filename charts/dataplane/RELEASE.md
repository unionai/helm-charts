# dataplane — Release Notes

## Unreleased

### Configuration changes (helm-charts)

- **Cloud overlays are now cloud-only** ([#497](https://github.com/unionai/helm-charts/pull/497)). The per-cloud dataplane overlays (`values.{aws,gcp,azure}.yaml`) previously carried deployment-topology and Union-platform config, duplicated across clouds and — in places — silently lost to the Terraform config-subtree shallow-merge (e.g. catalog-cache `use-admin-auth` ran `false` on GCP but `true` on AWS/Azure for the same managed-CP env). They now hold **only** cloud-specific config: provider, object storage, IAM / Workload-Identity annotations, region + task-log wiring, and the cloud globals a user fills in. Everything else is a base `values.yaml` chart default, set per-topology by the `union_extension` Terraform. Each overlay now opens with a PURPOSE header documenting the cloud-only contract. Specifics:
  - **`ingress` / `ingress-nginx`** — config moved to base (`enabled: false`); Terraform enables both only for a co-located control plane (selfhosted). **Managed-CP data planes no longer deploy the idle nginx controller** or its dataproxy/serving Ingress resources.
  - **Operator / CRS / catalog auth** (`config.union.auth.enable`, `clusterresourcesync…auth`, catalog-cache `use-admin-auth`) default **enabled** in base; Terraform disables them only for a selfhosted control plane with no IdP configured.
  - **`secrets.admin.create`** — base stays `true`; Terraform sets `false` (selfmanaged/selfhosted provision `union-secret-auth` via an ExternalSecret).
  - **`controlplaneNamespace`** — base `""`; Terraform sets `union-cp` only for selfhosted-intracluster (cross-namespace secretsWatcher RBAC).
  - **`serving.auth.enabled`, `dcgm-exporter.enabled`** — base defaults; per-cloud overrides dropped (dcgm keeps only its cloud-specific node affinity).
  - **fluentbit ServiceAccount** name now follows base `union-system` (the AWS IRSA role trust follows the same Terraform variable).
  - **Billing** — the inert `config.operator.billableUsageCollector.enabled` key is removed; billing collection is controlled by `config.operator.billing.model`, which Terraform sets to `None` for selfhosted control planes.
  - Removed dead/redundant keys: base restatements, `prometheus.prometheusOperator` (targets a key the community prometheus chart doesn't have), empty `flytepropeller` stubs, and the redundant task-pod `_U_EP_OVERRIDE` / `_U_INSECURE` `default-env-vars` (the leaseworker + executor already inject these from `config.union.connection`).

### Migration / action required

- **Managed-CP data planes drop the (idle) nginx ingress + its Ingress resources.** They fronted CP→DP traffic only for a co-located control plane; managed-CP data planes reach the control plane outbound, so the controller was deployed but received no traffic. No action. Selfhosted (co-located CP) deployments keep nginx via Terraform.
- **fluentbit ServiceAccount renamed** to `union-system` (from `fluentbit-system`) on AWS; the IRSA role trust is updated in lockstep. No action unless you bound external policy to the old SA name.

## 2026.7.2

Bumps `version` + `appVersion` to `2026.7.2`. `appVersion` moves from `2026.7.0` to
`2026.7.2`, so this release points at new data-plane (operator / executor / propeller /
dataproxy) images (notes below are the diff against the last stable release, `2026.7.1`,
whose `appVersion` was still `2026.7.0`).

### Configuration changes (helm-charts)

- **AWS storage overlay migrated to the stow backend** ([#493](https://github.com/unionai/helm-charts/pull/493)) — **fixes an executor crashloop**. The `provider: aws` branch of `_storage.tpl` emitted the legacy `type: s3` native connection block. flytestdlib's multi-scheme DataStore refactor ([flyteorg/flyte#7555](https://github.com/flyteorg/flyte/pull/7555)) routes every storage `Type` through stow and dropped the `type: s3` shorthand, so a `type: s3` config with no `stow.kind` panics `unsupported stow.kind []` at executor startup. AWS was the last provider not on stow (`gcs`/`azure`/`compat` already were). Now emits `type: stow` + `stow.kind: s3` driven by `authType` (IRSA and `accesskey` both render correctly). **AWS data planes should adopt this chart in lockstep with the `2026.7.2` executor image.**
- **Corrected Azure/GCP overlay defaults** ([#490](https://github.com/unionai/helm-charts/pull/490)):
  - *Namespace mapping (Azure + GCP).* GKE Workload Identity and Azure federated credentials have no wildcard subject support, so task namespaces must be a bounded set. The overlays pin `namespace_mapping.template` to `{{ domain }}`. On Azure this was previously nested under a `namespace_config` key the propeller ConfigMap never reads, so it was silently ignored and Azure fell through to the unbounded `{{project}}-{{domain}}` default. Moved to the correct top-level `namespace_mapping` key, gated on `not singleNamespace`.
  - *Azure operator secret backend.* The Azure overlay routed the operator's secret manager to Key Vault, but the flyte pod webhook reads the embedded K8s secret. Azure now defaults to the embedded K8s secret manager, matching AWS/GCP.
- **Single-namespace mapping pinned to the release namespace** ([#496](https://github.com/unionai/helm-charts/pull/496)) — **fixes task pods forbidden in single-namespace mode.** Under `low_privilege` / `namespaces.enabled: false` the `union-system` ServiceAccount has namespace-scoped RBAC, so task pods must land in the release namespace. The `nodeexecutor` ConfigMap emitted `namespace_mapping` twice when both `low_privilege` and a `namespace_mapping.template` were set — YAML last-key-wins made `{{ domain }}` win, so executor-routed task pods were created in the domain namespace and failed `pods is forbidden … in the namespace <domain>` (the operator had the same class of bug). A shared `dataplane.namespaceTemplate` helper is now the single source of truth for executor, leaseworker, and operator; under singleNamespace the executor overwrites `namespace_mapping` so the RBAC constraint always wins. Also removes the unused `config.namespace_config` / `config.namespace_mapping` keys, consolidating onto the canonical top-level `namespace_mapping`.
- **Eager API key minted per cluster** ([#486](https://github.com/unionai/helm-charts/pull/486)) — the dataplane now includes its cluster name when minting the eager API key, the chart half of per-data-plane operator + eager OAuth clients. Pairs with the control-plane `apiKeyOverrides` list ([controlplane #491](https://github.com/unionai/helm-charts/pull/491)) and requires the `2026.7.2` images.

### Platform (data-plane images — `appVersion 2026.7.2`)

The `appVersion` bump carries the data-plane images the chart changes above depend on:

- **Stow storage backend.** The executor routes all object storage through the stow backend ([flyteorg/flyte#7555](https://github.com/flyteorg/flyte/pull/7555)); a `type: s3` config with no `stow.kind` panics `unsupported stow.kind []` at startup, which is why the AWS overlay now emits `type: stow` + `stow.kind: s3` ([#493](https://github.com/unionai/helm-charts/pull/493)). Bump chart + image together.
- **Per-cluster eager API key.** The operator mints the eager API key using the data plane's cluster name ([#486](https://github.com/unionai/helm-charts/pull/486)), matching the control-plane per-cluster `apiKeyOverrides` entries.

Otherwise the `2026.7.2` tag is a routine data-plane image roll (bug fixes and improvements); nothing else in this chart release depends on it.

### Migration / action required

- **AWS data planes: adopt in lockstep with the executor image** ([#493](https://github.com/unionai/helm-charts/pull/493)). Once the executor rolls to a `2026.7.2` image (post-flyte#7555), an older chart still emitting `type: s3` crashloops the executor. Bump chart + image together. No action for GCP/Azure/OCI.
- **Per-cluster eager API key** ([#486](https://github.com/unionai/helm-charts/pull/486)) is coupled to the control-plane `apiKeyOverrides` list shape ([#491](https://github.com/unionai/helm-charts/pull/491)) and the `2026.7.2` images — bump control plane and data plane together.
- **Azure namespace mapping** ([#490](https://github.com/unionai/helm-charts/pull/490)): if you previously worked around the ignored `namespace_config` key with a manual override, drop it — the overlay now sets `namespace_mapping` correctly under multi-namespace (`low_privilege=false`) mode.
- **Namespace-mapping key consolidation** ([#496](https://github.com/unionai/helm-charts/pull/496)): the removed `config.namespace_config` / `config.namespace_mapping` keys were never generated by Terraform (only test fixtures used them); if you set them by hand, move to the top-level `namespace_mapping`. Behavior-preserving for multi-namespace deployments; single-namespace deployments now correctly place task pods in the release namespace.

## 2026.7.1

Chart-only patch release on top of `2026.7.0`; `appVersion` stayed `2026.7.0`. Highlights: zero-trust mode GA for BYOC data planes with a ready-to-use `examples/values.zero-trust.yaml` overlay; single canonical `operator.enableTunnelService` toggle; consolidated control-plane host resolution (fails fast if unset); chart-managed PriorityClasses for leaseworker/flytepropeller. See [PR #483](https://github.com/unionai/helm-charts/pull/483).

## 2026.7.0

First stable `2026.7.0`; `version` + `appVersion` bumped to `2026.7.0`. Highlights: dataplane self-registration — each data plane reports a bare `host` + TLS posture in `Status.connection_config` on every heartbeat so the control plane can route to it directly (opt-in via `updateStatus.connectionConfig.enabled`); billing defaults to v2 usage-based collection. See [PR #472](https://github.com/unionai/helm-charts/pull/472).

## 2026.6.9

### Changes

- Zero trust metrics push (#447) (5e59a4d)
- Selfmanaged controlplane: apiKeyOverrides, dataproxy connection host, operator eager-key toggle (#455) (8bd680d)

## 2026.6.7

### Changes

- Release/2026.6.7 (#451) (d472cd8)
- fix(dataplane): avoid emitting bare `{}` for empty custom storage config (#450) (bece749)
- Enable custom storage provider to include credentials from secret (#449) (eab4240)
- feat(dataplane): add opt-in FUSE device-plugin DaemonSet (#443) (1ca2c1a)
- feat(dataplane/serving): enable knative containerspec-addcapabilities (#448) (bcffc59)
- Fix/aks fluentbit (#442) (a1c3054)
- FAB-395: ci: add dataplane integration test on k3d with RustFS (#429) (82eca90)

## 2026.6.6

> **No chart-template or values changes.** This release advances the bundled `unionoperator` image tag and otherwise carries only the standard chart label / `helm.sh/chart` bumps.

### Highlights

- **Bundled `unionoperator` image tag advances `2026.6.3 → 2026.6.6`** (chart `appVersion` follows). Server-side, the operator gains support for offloaded trigger inputs; nothing to configure on the chart side.
- **Releases `2026.6.4` and `2026.6.5` were skipped** in the publish sequence — going straight from `2026.6.3` to `2026.6.6` is intentional.

### Helm chart changes (since `dataplane-2026.6.3`)

- Chart `version` + `appVersion` bumped to `2026.6.6`. No template, helper, or values changes.
- Snapshot fixtures regenerated. The only deltas are the `helm.sh/chart` / `app.kubernetes.io/version` labels and the `unionoperator` image tag.

### Image changes (appVersion `2026.6.3` → `2026.6.6`)

- `public.ecr.aws/p0i0a9q8/unionoperator:2026.6.3` → `:2026.6.6` across every appVersion-tied dataplane workload (leaseworker, executor, operator-proxy, build-image, etc.).

### Migration notes

No migrations required. Routine `helm upgrade` from `dataplane-2026.6.3` carries no values changes.

## 2026.6.3

### Highlights

- **Knative serving pre-delete hook removed (potentially breaking on un-migrated installs).** `templates/serving/pre-delete-hook.yaml` is deleted — its orderly-uninstall responsibility is now owned by the `knative-migration` chart. Customers who already adopted `knative-migration` see no change; customers still on the bundled hook should adopt `knative-migration` before `helm uninstall` to avoid leaving Knative serving objects behind. See **Migration notes**.
- **Two unused leaseworker config values removed.** Dead values dropped from `charts/dataplane/values.yaml`; matching plumbing on the controlplane side ships in the `controlplane-2026.6.3` Actions/Leasor work.
- **Bundled `unionoperator` image tag advances `2026.6.2 → 2026.6.3`** (chart `appVersion` follows). Standard monthly release-train bump.

### Helm chart changes (since `dataplane-2026.6.2`)

- Chart `version` + `appVersion` bumped to `2026.6.3`.
- Deleted `templates/serving/pre-delete-hook.yaml` (~60 lines); responsibility moves to the `knative-migration` chart.
- Snapshot fixtures regenerated (~63 lines removed per dataplane snapshot — the bytes of the deleted hook resource).
- `charts/dataplane/values.yaml`: two unused leaseworker config values removed; 4 small net additions for the new run-service options threaded through from controlplane (no default behaviour change on the dataplane side).

### Image changes (appVersion `2026.6.2` → `2026.6.3`)

- `public.ecr.aws/p0i0a9q8/unionoperator:2026.6.2` → `:2026.6.3` across every appVersion-tied dataplane workload (leaseworker, executor, operator-proxy, build-image, etc.).

### Migration notes

- **Adopt `knative-migration` before uninstall.** With the pre-delete hook gone, `helm uninstall <dataplane-release>` no longer cleans up Knative serving objects on its own. If you've been relying on the bundled hook, switch to the `knative-migration` chart (same repo) for orderly Knative lifecycle before the next uninstall.
- **No action required for ongoing upgrades.** Fresh installs and routine `helm upgrade`s are unaffected.

## 2026.6.2

### Highlights

- **DP→CP TLS defaults flipped to TLS-on across FIVE consumer paths (potentially breaking for self-signed envs).** Pre-6.2, the `values.aws.yaml` / `values.gcp.yaml` overlays each carried duplicate connection blocks that re-declared the consumer with TLS-skip enabled. As of 6.2 those overlay blocks are gone — every consumer falls through to the base `values.yaml`, which defaults to TLS-on. The five paths, with their **exact** bool-key spellings (three different schemas — they are NOT interchangeable):

  | Path | Bool key(s) — exact spelling | Pre-6.2 effective | Post-6.2 default |
  |---|---|---|---|
  | `clusterresourcesync.config.union.connection` | `insecureSkipVerify` *(camelCase)* | `true` *(overlay)* | `false` *(base)* |
  | `config.admin.admin` | `insecure`, `insecureSkipVerify` *(camelCase)* | `insecure: true` *(overlay)* | `insecure: false`, `insecureSkipVerify: false` |
  | `config.catalog.catalog-cache` | `insecure`, **`insecure-skip-verify`** *(hyphenated — different schema!)* | `insecure: true` *(overlay)* | `insecure: false`, `insecure-skip-verify: false` |
  | `config.union.connection` | `insecureSkipVerify` *(camelCase)* | `true` *(overlay)* | `false` *(base)* |
  | `config.k8s.plugins.k8s.default-env-vars` (task pods) | env-var pair `_U_INSECURE`, `_U_INSECURE_SKIP_VERIFY` | `_U_INSECURE: true` *(overlay)* | `_U_INSECURE: false` *(overlay rewritten)* |

  Default host expression for all five now resolves through the new `dataplane.cp.endpoint` / `dataplane.cp.queueEndpoint` helpers to `dns:///<CONTROLPLANE_HOST>:443` (TLS-terminating nginx port). See **Migration notes** for the exact opt-back snippet for self-signed CP certs.

- **Storage credentials from a Kubernetes Secret.** New `storage.credentialsSecretRef.name` value lets you mount AWS-S3-compatible access/secret keys from a pre-existing Secret instead of putting them in plaintext values. No-op if you keep credentials inline.

- **Opt-in Zero Trust overlay.** A new `values.zero-trust.yaml` overlay enables Zero Trust networking for the dataplane in one layer.

- **`knative-operator` subchart now sourced from the public Helm repo** (`https://unionai.github.io/helm-charts`, pinned to `2026.6.0`). The temporary `file://../knative-operator` pin is removed, and Knative CRDs are bundled directly under `charts/dataplane/crds/` so a default `helm install` (no `--skip-crds`) installs them automatically — fixes the prior `KnativeServing` "resource mapping not found" failure on fresh installs.

### Helm chart changes (since `dataplane-2026.6.1`)

- Chart `version` + `appVersion` bumped to `2026.6.2`.
- `dependencies.knative-operator.repository` switched from `file://../knative-operator` to `https://unionai.github.io/helm-charts`; pinned to `2026.6.0`.
- 13 Knative CRDs bundled under `charts/dataplane/crds/` (Helm 3 `crds/` auto-install path). Byte-identical to the vendored mirror at `crds/knative-operator/` used by the `--skip-crds` server-side-apply path.
- New `templates/_connection.tpl` helper (`dataplane.cp.host`, `dataplane.cp.endpoint`, `dataplane.cp.queueEndpoint`) — collapses the previously-duplicated `dns:///{{ tpl .Values.host . }}` host expression into a single helper and coalesces a new `global.CONTROLPLANE_HOST` with the legacy `Values.host` for backwards compatibility. The bool TLS fields are NOT folded into a helper — bool YAML coercion through helm template strings is fragile across the three different Go config schemas (see Highlights), so each consumer writes the bool literal inline.
- Base `values.yaml` — explicit TLS-on at each consumer:
    - `clusterresourcesync.config.union.connection.insecureSkipVerify: false` *(was commented out)*
    - `config.admin.admin.insecure: false`, `config.admin.admin.insecureSkipVerify: false`
    - `config.catalog.catalog-cache.insecure: false`, `config.catalog.catalog-cache.insecure-skip-verify: false` *(hyphenated)*
    - `config.union.connection.insecureSkipVerify: false` *(was commented out)*
- `values.aws.yaml`, `values.gcp.yaml`:
    - Dropped redundant `config.admin.admin.{endpoint,insecure}` block.
    - Dropped redundant `config.catalog.catalog-cache.{type,cache-endpoint,endpoint,insecure}` block.
    - Dropped redundant `config.union.connection.{host,insecureSkipVerify}` block.
    - Dropped redundant `clusterresourcesync.config.union.connection.{host,insecureSkipVerify}` block.
    - Cloud overlays now carry only the cloud-specific bits (auth client id, catalog `use-admin-auth: false`, task-pod env vars).
    - Task-pod env vars rewritten: `_U_EP_OVERRIDE` now uses the `dataplane.cp.queueEndpoint` helper; `_U_INSECURE: false` (was `true`); `_U_INSECURE_SKIP_VERIFY: false` (unchanged).
- New `values.zero-trust.yaml` overlay for opt-in Zero Trust networking.
- New `storage.credentialsSecretRef.name` value; storage helpers wire it through to the operator and execution paths (build-image, reusable containers covered).
- Configurable webhook headless template revived (now that the matching cloud-side support has landed).
- Reverted the in-flight `proxy.smConfig.webhookHostTemplate` default from 6.1 (`#420` → `#421`).

### Images to vendor (delta vs `dataplane-2026.6.1`)

Two image-surface changes for vendoring customers:

**1. `knative-operator` subchart moved from a local bundled copy to the public Helm repo.**

| Was | Now |
|---|---|
| `repository: file://../knative-operator`, `version: 2026.4.6` | `repository: https://unionai.github.io/helm-charts`, `version: 2026.6.0` |

The operator image + its `kube-rbac-proxy` sidecar are now pulled per the upstream subchart's `values.yaml`. After upgrade, re-resolve the subchart's image set:

```bash
helm dependency update charts/dataplane
helm template charts/dataplane | grep -E '^\s+image:' | sort -u
```

**2. Six Knative-serving images are now pinned by digest directly in dataplane templates.**

Previously these were rendered by the operator at reconcile time off a `KnativeServing` CR — they were running in your cluster but not part of the chart's declared image surface. As of 6.2 they're baked into `templates/gateway/*.yaml` with explicit digests. Vendoring customers who scan the chart for image refs (rather than scraping live clusters) should add all six to the mirror set:

| Component | Image (digest-pinned) |
|---|---|
| activator | `gcr.io/knative-releases/knative.dev/serving/cmd/activator@sha256:24c19cbee078925b91cd2e85082b581d53b218b410c083b1005dc06dc549b1d3` |
| autoscaler | `gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler@sha256:5e9236452d89363957d4e7e249d57740a8fcd946aed23f8518d94962bf440250` |
| autoscaler-hpa | `gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler-hpa@sha256:64166849fc5fd9b03ab2c1ebca72e70b826cf30e731b1fa3cdf725cdd30d6210` |
| controller | `gcr.io/knative-releases/knative.dev/serving/cmd/controller@sha256:5fb22b052e6bc98a1a6bbb68c0282ddb50744702acee6d83110302bc990666e9` |
| webhook | `gcr.io/knative-releases/knative.dev/serving/cmd/webhook@sha256:0fb5a4245aa4737d443658754464cd0a076de959fe14623fb9e9d31318ccce24` |
| queue (sidecar — referenced in `configmap-deployment.yaml` and `misc.yaml`) | `gcr.io/knative-releases/knative.dev/serving/cmd/queue@sha256:c61042001b1f21c5d06bdee9b42b5e4524e4370e09d4f46347226f06db29ba0f` |

Mirror by exact digest — the chart references them by digest, not tag, so a tag-only mirror is not sufficient.

The `unionoperator`, `envoy`, and other first-party templated images (`flytecopilot`, `kube-state-metrics`, sidecar helpers) are unchanged in this release apart from the `appVersion` retag to `:2026.6.2`.

### Migration notes

#### TLS-mode flip is the load-bearing change

If your dataplane connects to a control plane over a **publicly-trusted CA cert** (every Union-managed deployment, and any selfmanaged deployment behind ingress fronted by cert-manager / Let's Encrypt / a real CA), no action is needed — the new TLS-on defaults match what the connection actually needs.

If your control plane terminates with a **self-signed cert** (typical for self-hosted environments before the cert-manager / external-CA step), you need to opt back into TLS-skip at the env-overlay layer. Symptom of missing this:

```
rpc error: code = Unavailable desc = connection error: desc =
"error reading server preface: ... x509: certificate signed by unknown authority"
```

**Watch the three field-name dialects.** If you mass-find-and-replace one spelling across your values file, exactly one consumer will silently not honour it. Use the snippet below verbatim:

```yaml
# Opt back into TLS-skip on every DP→CP consumer.
# Use only with self-signed CP certs the dataplane pods cannot trust;
# leave at defaults (false) when CP is fronted by a publicly-trusted CA.

# 1. ClusterResourceSync → CP
clusterresourcesync:
  config:
    union:
      connection:
        insecureSkipVerify: true        # camelCase

# 2. Flyteadmin client
# 3. Catalog client (catalog-cache)
# 4. Union services client
config:
  admin:
    admin:
      # insecure: true                  # uncomment only if dropping TLS entirely (plaintext)
      insecureSkipVerify: true          # camelCase

  catalog:
    catalog-cache:
      # insecure: true                  # uncomment only if dropping TLS entirely
      insecure-skip-verify: true        # HYPHENATED — cacheservice schema, NOT camelCase

  union:
    connection:
      insecureSkipVerify: true          # camelCase

  # 5. Task-pod env vars (queue endpoint from inside user pods)
  k8s:
    plugins:
      k8s:
        default-env-vars:
          # _U_INSECURE drops TLS entirely; _U_INSECURE_SKIP_VERIFY keeps TLS but skips cert validation.
          # For a self-signed CP cert behind nginx:443 you want the second, not the first.
          - _U_INSECURE: false                # set true only if the queue endpoint is plaintext HTTP/h2c
          - _U_INSECURE_SKIP_VERIFY: true     # TLS on, cert validation off — matches the other 4 consumers
```

Two things worth being explicit about:

- **`insecure` vs `insecureSkipVerify` are different knobs.** `insecure: true` drops TLS entirely (plaintext gRPC/HTTP). `insecureSkipVerify: true` keeps TLS but accepts any presented cert. For a self-signed CP cert behind nginx-on-443 you want the latter — flipping `insecure: true` will produce `http2: server sent GOAWAY and closed the connection` against a TLS port.
- **Task pods speak a separate dialect** (`_U_INSECURE` / `_U_INSECURE_SKIP_VERIFY` env vars), because the SDK reads env, not the helm config schema. These two are still set in the cloud overlays — they did NOT move to base. Override at the env-overlay layer the same way the cloud overlays do.

Selfmanaged Terraform-driven envs pick this up automatically via the companion cloud-side change; hand-rolled overlays need to set the snippet above explicitly.

#### Knative install path

Fresh installs are now the default `helm install` (CRDs in `charts/dataplane/crds/`). The documented production path stays `helm install --skip-crds` + `kubectl apply --server-side -f crds/knative-operator/` (avoids the 256 KiB `last-applied-configuration` annotation overflow and is forward-compatible with Helm 4). No action required on upgrades — Helm's `crds/` directory is install-only.

#### Storage credentials

No migration required. Keep credentials inline as `storage.accessKey` / `storage.secretKey` if you prefer, or move them to a Secret and set `storage.credentialsSecretRef.name`.

#### Zero Trust

Opt-in. Include `values.zero-trust.yaml` in your overlay set if you want it.

## 2026.6.1

> Chart-only release: `appVersion` stays at `2026.6.0`. No image changes — see `dataplane-2026.6.0` for the image notes.

### Highlights

- **Per-cloud overlay consolidation (potentially breaking for external consumers).** The `values.{aws,gcp}.selfhosted-intracluster.yaml` overlays are **deleted**; their contents become the canonical `values.{aws,gcp}.yaml`. One canonical overlay per cloud now serves every topology — topology is decided by env-layer Service annotations and DNS, not by chart values. See **Migration notes** and `charts/MIGRATION.md`.
- **DP→CP endpoint variables collapsed into a single canonical `CONTROLPLANE_HOST`.** Existing env overlays that set the legacy names (`CONTROLPLANE_INTRA_CLUSTER_HOST`, `QUEUE_SERVICE_HOST`, `FLYTEADMIN_ENDPOINT`, `CACHESERVICE_ENDPOINT`) keep working unchanged via `default`-based fallback.
- **FlyteWorkflow CRD is now bundled in the chart's `crds/`** so `helm install` auto-applies it, while a byte-identical mirror at `crds/flyte-v1/` stays available for the server-side-apply / ArgoCD install path.

### Helm chart changes (since `dataplane-2026.6.0`)

- Chart `version` bumped to `2026.6.1`; `appVersion` unchanged (`2026.6.0`) — this is a chart-only release.
- Deleted `values.aws.selfhosted-intracluster.yaml` / `values.gcp.selfhosted-intracluster.yaml`; canonical `values.{aws,gcp}.yaml` now carry the (mode-agnostic) intracluster content. Pre-consolidation contents preserved at `examples/values.{aws,gcp}.legacy.yaml`; intracluster overrides at `examples/values.{aws,gcp}.intracluster.yaml`.
- Introduced `global.CONTROLPLANE_HOST`; the four legacy DP→CP endpoint vars fall through to it.
- FlyteWorkflow CRD bundled at `charts/dataplane/crds/crd-flyteworkflows.yaml` (Helm 3 `crds/` auto-install) and mirrored byte-for-byte to `crds/flyte-v1/` (CI-gated). The deprecated `charts/dataplane-crds/` path is unchanged.
- Fixed a permanent ArgoCD **OutOfSync** on the FlyteWorkflow CRD by dropping a trailing empty `properties:` key that Kubernetes strips server-side at admission.
- Added `metrics-manifest.yaml` + `make generate-metrics-manifest` to track metric/dashboard/rule changes in PR diffs (tooling only — no runtime change).

### Migration notes

**Read `charts/MIGRATION.md` for the full story.** Summary:

- **If you fetch `values.{cloud}.selfhosted-intracluster.yaml` over HTTP**: that filename now returns 404. Switch to canonical `values.{cloud}.yaml` and layer `examples/values.{cloud}.intracluster.yaml` on top for intra-cluster routing.
- **Legacy host variables still work** via `{{ default <canonical> <legacy> }}` fallback. Move to `CONTROLPLANE_HOST` when convenient.

**FlyteWorkflow CRD install path.** Two equally-supported options:

- **Recommended (selfhosted / intra-cluster):** `helm install … --skip-crds` and apply the CRD yourself — `kubectl apply --server-side -f crds/flyte-v1/` (or point ArgoCD at `crds/flyte-v1/`). Full lifecycle is owned by whoever runs the apply.
- **One-shot:** `helm install …` (no `--skip-crds`) installs the bundled CRD on first install. Note Helm's `crds/` directory is **install-only** — `helm upgrade` will never modify the CRD.

The OutOfSync fix is automatic; no action required beyond re-syncing once.

## 2026.6.0

### Highlights

- **Billing / usage collection now works in low-privilege mode.** A new `config.operator.cloudProvider` value lets you set the cluster's cloud provider explicitly (used for GPU accelerator labelling and usage attribution) instead of relying on node-label auto-detection, which is unavailable when the operator runs with reduced RBAC.

### Helm chart changes (since `dataplane-2026.5.9`)

- Chart version + `appVersion` bumped to `2026.6.0`.
- New `config.operator.cloudProvider` value (defaults to the top-level `provider`). Selects the GPU accelerator node label for usage attribution and tags billable usage. When empty and the operator is **not** in low-privilege mode, it still falls back to detecting the provider from node labels.

### Image changes (appVersion `2026.5.9` → `2026.6.0`)

- Operator `kube-rbac-proxy` sidecar now pulls the public `quay.io/brancz/kube-rbac-proxy` image. If you mirror images into a private registry, add this repository to your mirror set.

### Migration notes

No dataplane-specific migrations required for this release.

Low-privilege deployments pick up usage collection automatically. If your cluster's provider can't be inferred (e.g. you run with reduced RBAC), set `config.operator.cloudProvider` to `aws`, `gcp`, `azure`, `oci`, or `metal`.

_Pre-releases (2026.6.10-alpha.*) are omitted; 2026.6.10 shipped as 2026.7.0._
