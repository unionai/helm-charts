# Chart Migration Notes

Tracking the migration story for the helm-charts cloud overlays. New entries at the top.

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
