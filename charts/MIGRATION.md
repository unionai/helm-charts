# Chart Migration Notes

Tracking the migration story for the helm-charts cloud overlays. New entries at the top.

---

## controlplane — `services.identity.apiKeyOverrides` map → list (per-cluster seeded API keys)

### What changed

`services.identity.apiKeyOverrides` changes from a **map keyed by system-key name** to a
**list** of entries, each identified by `key` + optional `clusterName`. This lets one control
plane seed a *different* OAuth client per dataplane for the same system key — the map shape
allowed only one entry per key.

Before (map):

```yaml
services:
  identity:
    apiKeyOverrides:
      EAGER_API_KEY:
        existingSecret:
          name: eager-client-creds
```

After (list):

```yaml
services:
  identity:
    apiKeyOverrides:
      - key: EAGER_API_KEY            # cluster-nameless default (serves any dataplane)
        existingSecret:
          name: eager-client-creds
      - key: EAGER_API_KEY            # optional per-cluster override
        clusterName: dp-1
        existingSecret:
          name: eager-dp1-creds
```

`clusterName` is optional. An entry without it is the **cluster-nameless default** that serves
any dataplane lacking its own entry (identical to the old single-entry behavior). A
cluster-scoped entry takes precedence for that dataplane. This mirrors the backend
`identity.config.ApiKeyOverride`, which keys on `(org, key, clusterName)` and, on `CreateKey`,
prefers a cluster-scoped override then falls back to the nameless one — required because the
operator sends `cluster_name` on every mint (FAB-241), so a nameless entry must still serve
cluster-named requests.

Mount paths are now per-entry: `/etc/secrets/apikey/<KEY>` for a nameless entry and
`/etc/secrets/apikey/<KEY>-<clusterName>` for a cluster-scoped one.

### Migration

| Audience | Action |
|---|---|
| Not using `apiKeyOverrides` (default `[]`) | None. |
| Selfhosted with a single seeded key | Convert the one map entry to a one-element list (prefix `- key: <NAME>`; the `existingSecret` block is unchanged). Behavior is identical. Cloud-managed overlays regenerate this automatically from `union_extension/{aws,gcp}` — re-apply terraform after bumping to this chart. |
| Selfhosted wanting per-cluster keys | Add one list entry per cluster with a distinct `clusterName` + `existingSecret`; optionally keep one nameless entry as the fallback. Seed one Secret per cluster out-of-band. |

**Breaking:** an env whose control-plane `values.yaml` still carries the map shape renders an
empty/invalid override list against this chart. Regenerate the env overlay (terraform re-apply
for selfmanaged) in lockstep with the chart bump.

### References

- helm-charts PR: <link tbd>
- cloud `union_extension` (terraform emits the list) + `identity` (`ClusterName` override parameter) PR: <link tbd>

---

## controlplane — `actionsLeasor.enabled` toggle (queue/executor deprecation)

### What changed

New top-level chart value `actionsLeasor.enabled` (default `false`). When `true`, the `unionai.configMap` helper patches the executions service ConfigMap so that:

- `useActionsServiceForOrgs: [<global.UNION_ORG>]` — the deployment's own org routes `CreateRun` through the v2 actions service.
- `rejectLegacySDKVersions: true` — sub-2.0.4 SDK `CreateRun` is hard-rejected.

### Deprecation timeline

| Date | Phase | Customer-visible effect |
|---|---|---|
| 2026-06-30 | **Deprecation announced** | Queue + executor services formally marked deprecated. SDK <2.0.4 keeps working via the legacy queue path. `actionsLeasor.enabled` default remains `false`. Customers should plan to upgrade SDKs and (optionally) opt into the v2-actions path. |
| 2026-07-31 | **Complete switch-over** | Chart default flips to `actionsLeasor.enabled: true`. Queue + executor templates/services are removed. SDK <2.0.4 `CreateRun` hard-fails. `actionsLeasor` knob retained for one more minor release for compatibility, then removed. |

### Migration

| Audience | Action |
|---|---|
| Managed multi-tenant CP | None today. Track the 2026-06-30 announcement; coordinate SDK upgrade with customer base before 2026-07-31. |
| Selfhosted single-tenant | Set `actionsLeasor: { enabled: true }` in `values-overrides.yaml` (or via cloud-side `var.actions_leasor_enabled = true` on `union_extension/{aws,gcp}`). Confirm all in-use SDKs are >=2.0.4. After 2026-07-31, drop the override — it becomes the default. |
| BYOC | Coordinate SDK upgrade with operator. The chart default flip on 2026-07-31 will turn off the legacy path for any deployment that hasn't already migrated. |

### After 2026-07-31

- `actionsLeasor.enabled: true` becomes the default; queue + executor templates are removed.
- Env overlays that set `actionsLeasor.enabled: true` explicitly can drop the override.
- The `unionai.configMap` injection block in `templates/_helpers.tpl` becomes unconditional (or moves into values.yaml as plain defaults) and the toggle itself is dropped.

---

## dataplane 2026.6.2 — DP→CP connection wiring centralized + TLS-by-default

### What changed

**1. The DP→CP connection wiring moves to a single shared expression.**

A new `charts/dataplane/templates/_connection.tpl` exposes three helpers that all CP-pointed consumers (`config.admin.admin`, `config.catalog.catalog-cache`, `config.union.connection`, `clusterresourcesync.config.union.connection`, task-pod `_U_EP_OVERRIDE`) now reference:

| Helper | Returns |
|---|---|
| `dataplane.cp.host` | Bare hostname. Coalesces `global.CONTROLPLANE_HOST` (selfmanaged convention) with `Values.host` (legacy / BYOK convention). |
| `dataplane.cp.endpoint` | gRPC dial endpoint. Defaults to `dns:///<host>:443`; respects `global.CONTROLPLANE_GRPC_ENDPOINT` override. |
| `dataplane.cp.queueEndpoint` | Task-pod queue endpoint. Cascades `global.QUEUE_GRPC_ENDPOINT` → `global.CONTROLPLANE_GRPC_ENDPOINT` → default. |

Existing deployments don't need any values change — the helpers coalesce both old and new globals, so `host:` (legacy) and `global.CONTROLPLANE_HOST` (new) both work without modification.

**2. The endpoint string now includes an explicit `:443` port.**

| Before | After |
|---|---|
| `dns:///<host>` (no port) | `dns:///<host>:443` |

Functionally equivalent — gRPC's TLS dialer defaults to port 443 when none is given. Anything pointing the DP at a non-443 CP endpoint via `global.CONTROLPLANE_GRPC_ENDPOINT` is unaffected (the override wins).

**3. TLS-by-default on cloud overlays.**

| Field (consumer) | Before | After |
|---|---|---|
| `config.admin.admin.insecure` | `true` (cloud overlays) | `false` |
| `config.admin.admin.insecureSkipVerify` | (commented out, default `false`) | explicit `false` |
| `config.catalog.catalog-cache.insecure` | `true` (cloud overlays) | `false` |
| `config.catalog.catalog-cache.insecure-skip-verify` | (absent) | explicit `false` |
| `config.union.connection.insecureSkipVerify` | (commented out, default `false`) | explicit `false` |
| `clusterresourcesync.config.union.connection.insecureSkipVerify` | `true` (cloud overlays) | `false` |
| `_U_INSECURE` (task-pod env var) | `"true"` | `"false"` |
| `_U_INSECURE_SKIP_VERIFY` (task-pod env var) | `"false"` | `"false"` |

The new out-of-box posture is "TLS with chain verification." Right for managed control planes with valid (publicly-signed or trusted-CA) certs.

### Who needs to act

- **Managed CP, valid cert:** no action. TLS-by-default just works.
- **BYOK / Union-managed CP, valid cert:** no action. Helpers fall back to `Values.host` (legacy) and the new defaults work.
- **Self-signed CP cert (most selfmanaged staging environments):** override the four `insecureSkipVerify` consumers AND `_U_INSECURE_SKIP_VERIFY` task-pod env var to `true` at the env-values layer. Without this, every DP→CP call fails TLS chain validation with `x509: certificate signed by unknown authority`.
- **Plain-HTTP CP (rare):** override `insecure: true` on the affected consumers. The chart no longer ships this as a default for any cloud overlay.

Reference env-values overlay shape for a self-signed-cert deployment:

```yaml
config:
  admin:
    admin:
      insecureSkipVerify: true
  catalog:
    catalog-cache:
      insecure-skip-verify: true
  union:
    connection:
      insecureSkipVerify: true
  k8s:
    plugins:
      k8s:
        default-env-vars:
          - _U_INSECURE_SKIP_VERIFY: "true"

clusterresourcesync:
  config:
    union:
      connection:
        insecureSkipVerify: true
```

### Symptoms if you skip the migration

- `union-syncresources` controller crashloops with `failed to fetch auth metadata: ... frame too large, note that the frame header looked like an HTTP/1.1 header` (was: `insecure: true` against TLS port 443).
- Or, once TLS is reached but the cert isn't trusted: `x509: certificate signed by unknown authority` on every DP→CP call. Set `insecureSkipVerify: true` if the cert is self-signed.
- Task pods schedule but fail to dial the CP queue with the same TLS errors.
- Downstream effect: project-domain namespaces (e.g. `development`) are never created in the DP cluster; task scheduling fails with `namespaces "development" not found`.

---

## 2026.X.Y — Cloud overlay consolidation + canonical host indirection

### What changed

**1. Per-cloud overlay filenames are now canonical.**

| Before (deprecated, kept as shim) | After (canonical) |
|---|---|
| `charts/controlplane/values.aws.selfhosted-intracluster.yaml` | `charts/controlplane/values.aws.yaml` |
| `charts/controlplane/values.gcp.selfhosted-intracluster.yaml` | `charts/controlplane/values.gcp.yaml` |
| `charts/dataplane/values.aws.selfhosted-intracluster.yaml` | `charts/dataplane/values.aws.yaml` |
| `charts/dataplane/values.gcp.selfhosted-intracluster.yaml` | `charts/dataplane/values.gcp.yaml` |

The `*.selfhosted-intracluster.yaml` files are **deleted** in this release. The cloud-side `union_extension` terraform modules now fetch the canonical filename directly (coordinated cloud-side PR — see References). External consumers fetching the old filename via HTTP will receive 404; migrate to the new filename.

**2. The old `values.{aws,gcp}.yaml` contents moved to `examples/*.legacy.yaml`.**

| Before | After |
|---|---|
| `charts/controlplane/values.{aws,gcp}.yaml` (pre-consolidation contents) | `charts/controlplane/examples/values.{aws,gcp}.legacy.yaml` |
| `charts/dataplane/values.{aws,gcp}.yaml` (pre-consolidation contents) | `charts/dataplane/examples/values.{aws,gcp}.legacy.yaml` |

The legacy files are preserved purely as **historical reference** for anyone diffing against pre-consolidation deployments. They are not maintained, not tested, and should not be used as a starting point for new deployments. All deployment modes (selfmanaged, selfhosted, BYOC) consume the consolidated canonical `values.{cloud}.yaml`; mode-specific overrides happen at the env layer (terraform `union_extension` for selfmanaged, Union deploy tooling for BYOC, etc.).

The chart no longer has any concept of "BYOC overlay" vs "selfmanaged overlay" vs "selfhosted overlay" — one canonical per cloud is the only supported shape. See [CONVENTIONS.md](./CONVENTIONS.md).

**3. The canonical overlays now use unified host indirection** — `CONTROLPLANE_HOST` (DP→CP) and `DATAPLANE_HOST` (CP→DP).

The four legacy DP→CP endpoint variables collapse into one canonical name:

| Legacy variable (still supported, falls back to canonical) | Canonical |
|---|---|
| `global.CONTROLPLANE_INTRA_CLUSTER_HOST` | `global.CONTROLPLANE_HOST` |
| `global.QUEUE_SERVICE_HOST` | `global.CONTROLPLANE_HOST` |
| `global.FLYTEADMIN_ENDPOINT` | `global.CONTROLPLANE_HOST` |
| `global.CACHESERVICE_ENDPOINT` | `global.CONTROLPLANE_HOST` |

And the CP→DP rename:

| Legacy variable (still supported, falls back to canonical) | Canonical |
|---|---|
| `global.DATAPLANE_ENDPOINT` | `global.DATAPLANE_HOST` |

Each consumption site uses `{{ default .Values.global.<CANONICAL> .Values.global.<LEGACY> }}` so existing env overlays setting the legacy names take precedence and keep working unchanged.

### Why

The four DP-side endpoint variables (`CONTROLPLANE_INTRA_CLUSTER_HOST`, `QUEUE_SERVICE_HOST`, `FLYTEADMIN_ENDPOINT`, `CACHESERVICE_ENDPOINT`) were redundant aliases — the CP-side nginx ingress already routes ALL CP service calls by gRPC protobuf path through a single canonical hostname. They also conflated *topology* with *hostname*: the "selfhosted-intracluster" framing implied a separate overlay was needed for each topology, when in practice the same overlay serves intracluster, multi-cluster-same-VPC, and BYOC public — the topology distinction is made by cloud-provider Service annotations and DNS (env-layer concerns), not by chart values.

### Topology support, same overlay

The canonical overlay is mode-agnostic. It describes the general case — a split CP/DP topology where CP and DP can live in different clusters. Three topology patterns layer cleanly on top, all driven by env-layer overrides (terraform `union_extension`, Union BYOC tooling, etc.):

```yaml
# Intracluster (CP + DP in the same cluster) — see examples/values.{cloud}.intracluster.yaml
# CP and DP nginx Services stay ClusterIP. CONTROLPLANE_GRPC_ENDPOINT and
# DATAPLANE_HOST resolve to in-cluster svc.cluster.local FQDNs.

# Multi-cluster same VPC (DP in its own cluster, internal LB)
# DP nginx-controller becomes a LoadBalancer with cloud-specific internal
# annotations:
#   AWS:   service.beta.kubernetes.io/aws-load-balancer-scheme: internal
#   GCP:   networking.gke.io/load-balancer-type: Internal
#   Azure: service.beta.kubernetes.io/azure-load-balancer-internal: "true"
# DNS (private hosted zone) maps the internal hostname to the LB.
# CONTROLPLANE_GRPC_ENDPOINT resolves to the internal-DNS host.

# Multi-cluster cross-VPC (DP in its own cluster, public LB or peered)
# DP nginx-controller is a LoadBalancer (public or internal-peered).
# CONTROLPLANE_GRPC_ENDPOINT resolves to whatever hostname the DP cluster
# can reach the CP at (public DNS, private DNS via peering, etc.).
```

Service annotations + DNS are owned by the env layer, not by the chart. The chart's only knowledge of topology is the value of `CONTROLPLANE_HOST` / `CONTROLPLANE_GRPC_ENDPOINT` / `DATAPLANE_HOST` globals, which the env layer fills in.

### Migration paths

**If you fetch `values.{cloud}.selfhosted-intracluster.yaml` (cloud-side terraform, scripts, CI):**
The file has been deleted. Update your fetch URL to the new canonical `values.{cloud}.yaml` and layer `examples/values.{cloud}.intracluster.yaml` on top if you still want intra-cluster routing.

**If you fetch `values.{cloud}.yaml` (pre-consolidation contents):**
The content has changed. The new canonical defaults are mode-agnostic and don't bake in any topology assumption.

1. **You're running intracluster (CP + DP in the same cluster)** — layer `examples/values.{cloud}.intracluster.yaml` on top.
2. **You're running multi-cluster** — supply `CONTROLPLANE_HOST` / `CONTROLPLANE_GRPC_ENDPOINT` / `DATAPLANE_HOST` overrides via your env overlay (terraform `union_extension` does this automatically for selfmanaged).
3. **You're unsure what you were doing** — `diff` the old file (now at `examples/values.{cloud}.legacy.yaml`) against the new canonical file to see exactly which defaults changed for you.

**If you set any of the four deprecated DP variables in env overlays:**
They continue to work. Move to `CONTROLPLANE_HOST` when convenient — the chart will derive everything from it. The cloud `union_extension` module will drop the legacy assignments in a follow-up release.

**If you set `DATAPLANE_ENDPOINT` in env overlays:**
Same — continues to work, alias for `DATAPLANE_HOST`.

**If you set `QUEUE_GRPC_ENDPOINT`:**
Still required for the auth-less queue path used by user task pods. Long-term plan: deprecate once propeller injects OAuth credentials into task pods, then queue traffic flows through `CONTROLPLANE_GRPC_ENDPOINT` like everything else. No action needed today.

### Timeline

- **2026.X.Y** (this release): canonical overlays land + shim files deleted (coordinated with cloud `union_extension` URL flip). Legacy DP / CP host variables remain as deprecated fall-through values.
- **2026.X+1.Y** or later: legacy host variables (CONTROLPLANE_INTRA_CLUSTER_HOST, FLYTEADMIN_ENDPOINT, CACHESERVICE_ENDPOINT, QUEUE_SERVICE_HOST, DATAPLANE_ENDPOINT) deleted once env-side terraform stops setting them.

### References

- helm-charts PR: <link tbd>
- cloud `union_extension` URL flip + DNS/LB topology support PR: <link tbd>
- unionai-docs topology guide: <link tbd>
