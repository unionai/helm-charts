# Vendored CRDs

Each subdirectory here vendors the CRDs from a single upstream Helm chart that
the `controlplane` (and sometimes `dataplane`) chart depends on. These CRDs
are installed by *dedicated* ArgoCD `Application`s rather than as part of the
control-plane / data-plane apps.

## Why

Several of our subchart dependencies ship CustomResourceDefinitions whose
embedded OpenAPI v3 schemas exceed 256 KiB. When ArgoCD's controller falls
back to a client-side apply for these CRDs (the SSA-fallback paths inside
gitops-engine that the application-level `ServerSideApply=true` syncOption
does not cover), it attempts to write the desired spec into
`kubectl.kubernetes.io/last-applied-configuration`. That annotation hits
Kubernetes' hard per-annotation limit of 262144 bytes and the apply fails
with `metadata.annotations: Too long: may not be more than 262144 bytes`,
which surfaces as `Last sync ❌` on the control-plane app and stalls
selfHeal indefinitely.

Installing these CRDs via **server-side apply** sidesteps the limit
entirely — SSA tracks ownership via `metadata.managedFields` rather than
`last-applied-configuration`, so the 256 KiB cap is never approached.
The customer-facing install instructions use
`kubectl apply --server-side --force-conflicts -f crds/<name>/` for this
reason.

See `kubectl.kubernetes.io/last-applied-configuration` annotation-size
issues in [argoproj/argo-cd](https://github.com/argoproj/argo-cd) for
background on the failure mode.

## What lives here

| Directory                  | Source                                              | Used by                   |
|----------------------------|-----------------------------------------------------|---------------------------|
| `kube-prometheus-stack/`   | `prometheus-community/kube-prometheus-stack`        | `controlplane`, `dataplane` |
| `scylla-operator/`         | `scylla/scylla-operator`                            | `controlplane`            |
| `envoy-gateway/`           | `oci://docker.io/envoyproxy/gateway-helm`           | `controlplane`            |
| `dataplane/`               | `knative/serving` release (12 serving CRDs) + Union-maintained FlyteWorkflow CRD; full mirror of `charts/dataplane/crds/` | `dataplane` chart (always): FlyteWorkflow CRD + Knative Serving CRDs (needed by both the zero-trust gateway and the legacy knative-operator path). Replaces `charts/dataplane-crds`. |
| `knative-operator/`        | `knative/operator` release (2 `operator.knative.dev` CRDs only); mirror of `charts/knative-operator/crds/` | `knative-operator` subchart (legacy / non-zero-trust path). Knative serving CRDs live in `dataplane/` and are pulled from there, not duplicated here. Delete this dir + the subchart when zero-trust becomes the only mode. Replaces `charts/knative-operator-crds`. |

The corresponding parent chart's subchart `crds/` directory is NOT rendered
by ArgoCD — the parent ApplicationSet sets `helm.skipCrds: true` on its
source so the same CRDs aren't applied twice.

## Layout of each `crds/<name>/` directory

```
crds/<name>/
  VERSION                   # upstream chart version this dir tracks (omit for chart-mirrored dirs)
  scripts/
    sync.sh                 # (re-)populate crd-*.yaml — from upstream OR from a chart-dir mirror source
    check.sh                # CI gate: cross-validate + detect drift
  crd-*.yaml                # vendored CRDs with an "AUTO-GENERATED — do not edit" header
```

Each directory falls into one of two subtypes — all have `scripts/sync.sh`
+ `scripts/check.sh` and are picked up uniformly by `make vendor-crds` /
`make check-vendored-crds`:

**Upstream-only** (KPS / scylla / envoy-gateway): `sync.sh` pulls from the
upstream chart at the version declared in `charts/controlplane/Chart.yaml`,
writes that version to `VERSION`, and emits `crd-*.yaml` into this dir.
Hand edits are overwritten on the next sync; patch downstream (kustomize on
the ArgoCD source, or a helm post-render), not `crd-*.yaml` directly.

**Chart-mirrored, upstream-tracked** (`dataplane/`, `knative-operator/`):
`sync.sh` pulls from upstream at the version pinned in `VERSION`, writes
upstream-sourced CRDs to the corresponding chart's `crds/` dir
(`charts/dataplane/crds/` or `charts/knative-operator/crds/`) AND mirrors
EVERY file in that chart dir (including Union-maintained CRDs not pulled
from upstream — e.g. `crd-flyteworkflows.yaml`) into this dir for SSA
install via a dedicated ArgoCD `Application` (when the customer runs
`helm install --skip-crds`). The chart dir is the single source of truth
for "what CRDs does this chart need"; this mirror is its byte-identical
SSA-install copy.

## Adding a new vendored CRD set

1. Pick a directory name that matches the upstream chart (e.g.
   `cert-manager-crds` → `crds/cert-manager/`).
2. Create the directory with `VERSION` + `scripts/sync.sh` + `scripts/check.sh`.
   Copy the structure of an existing dir; the only chart-specific parts are
   the upstream repo, the path within the chart where CRDs live (`crds/`,
   `charts/crds/crds/`, etc.), and the dep name used to read the version
   from `charts/controlplane/Chart.yaml`.
3. Run `make vendor-crds` — your new `sync.sh` is picked up automatically
   (the Makefile iterates `crds/*/`, no edits required).
4. Add a new ArgoCD ApplicationSet in `unionai/cloud`
   (`infra/argocd/deploy/manifests/appset-selfmanaged-<name>-crds.yaml`)
   pointing at the new directory.
5. Set `helm.skipCrds: true` on whichever parent ApplicationSet currently
   renders these CRDs, so the same resources aren't applied twice.

## Day-to-day

```bash
# Bump a parent chart's dep version, then refresh vendored CRDs:
vim charts/controlplane/Chart.yaml         # bump kube-prometheus-stack dep
vim charts/dataplane/Chart.yaml            # same bump
make vendor-crds                           # re-pulls upstream + updates VERSION

# Verify everything is in sync (also run by CI):
make check-vendored-crds
```

`check.sh` fails the build if any of:
- the parent-chart dep version disagrees between controlplane and dataplane (upstream-tracked dirs only)
- `crds/<name>/VERSION` disagrees with the parent-chart dep version (upstream-tracked dirs only)
- the vendored `crd-*.yaml` files differ from a fresh `sync.sh` re-run (all dirs)
