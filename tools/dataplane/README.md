# tools/dataplane — dataplane dev & CI toolkit

User-facing tooling to **stand up a Union dataplane on a cluster and run functional tests
it**. Deploying a dataplane is a user capability, not a CI secret — so this lives
outside `.github/`, and CI calls *into* it (not the other way around).

Two classes of script, split by audience:

| Class | Home | What |
| --- | --- | --- |
| **User-facing (this dir)** | `tools/dataplane/` | reusable deploy + test logic anyone can run locally |
| **CI-only** | `.github/` | the workflows + CI-specific debug collection that *call* this toolkit |

## Contents

| Path | What |
| --- | --- |
| `install.sh` | shared cluster-side deploy ops: `crds` \| `deps` \| `health` (single source of truth for both the k3d repro and the cloud CI legs) |
| `k3d/up.sh` `k3d/down.sh` `k3d/rustfs.yaml` | stand up / tear down an ephemeral local k3d dataplane (see `k3d/README.md`) |
| `.github/ci-scripts/integration_ops.py` | control-plane ops: `setup-routing` \| `run-functional-tests` \| `wait-healthy` \| `teardown` |

## `install.sh`

Run from the repo root; paths are repo-relative.

```bash
tools/dataplane/install.sh crds   charts/dataplane/crds          # or: crds/dataplane crds/scylla-operator ...
tools/dataplane/install.sh deps   charts/dataplane               # or: charts/controlplane charts/dataplane
tools/dataplane/install.sh health union                          # rollout + crashloop poll per namespace
```

`crds` / `deps` are byte-for-byte what `up.sh` and `integration-checks.yaml` did
inline — extracting them kills the drift between two copies of the helm-repo list.
`health` is the cloud legs' crashloop poll, now available to k3d too.

## Local k3d quickstart

```bash
tools/dataplane/k3d/up.sh --from-aws-secret selfmanaged/canary/helm-charts-ci/sm-k3d-dp-1/operator --functional
tools/dataplane/k3d/down.sh
```

See `k3d/README.md` for credential options.

## Migration status

- [x] `crds` + `deps` extracted into `install.sh`; `up.sh` calls them.
- [x] k3d tooling moved out of `hack/` into `tools/dataplane/k3d/`.
- [ ] `integration-checks.yaml` cloud legs call `install.sh crds|deps|health`.
- [ ] `up.sh` adopts `install.sh health`.
- [ ] `helm upgrade --install` wrapper (`install` subcommand) — values/args stay caller-specific.

Design: `../../../helm-charts-ci-design.md` (workspace) §7.
