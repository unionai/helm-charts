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
| `flyte-v1/`                | Union-maintained (no upstream sync)                 | `dataplane` (FlyteWorkflow); replaces `charts/dataplane-crds` |
| `knative-operator/`        | `knative/serving` + `knative/operator` releases     | App Serving; replaces `charts/knative-operator-crds` |

The corresponding parent chart's subchart `crds/` directory is NOT rendered
by ArgoCD — the parent ApplicationSet sets `helm.skipCrds: true` on its
source so the same CRDs aren't applied twice.

## Layout of each `crds/<name>/` directory

```
crds/<name>/
  VERSION                   # upstream chart version this dir tracks (omit for Union-maintained CRDs)
  scripts/                  # omit for Union-maintained CRDs
    sync.sh                 # re-vendor from upstream + bump VERSION
    check.sh                # CI gate: cross-validate + detect drift
  crd-*.yaml                # vendored CRDs with an "AUTO-GENERATED — do not edit" header
```

For upstream-tracked dirs (KPS / scylla / envoy-gateway), `scripts/sync.sh`
is the only thing that should ever write to the `crd-*.yaml` files. Hand
edits will be overwritten on the next sync; if you need to patch a CRD, do
it via a downstream layer (kustomize on the ArgoCD source, or a helm
post-render), not in `crd-*.yaml` directly.

For Union-maintained dirs (e.g. `flyte-v1/`), `crd-*.yaml` is the source of
truth — edit it directly. No `scripts/` is needed; the `make vendor-crds`
loop simply skips dirs that lack a sync script.

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
- the parent-chart dep version disagrees between controlplane and dataplane
- `crds/<name>/VERSION` disagrees with the parent-chart dep version
- the vendored `crd-*.yaml` files differ from a fresh `sync.sh` re-run
