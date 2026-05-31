# Union Helm Charts

Helm charts for deploying Union.ai onto Kubernetes:

- **[`charts/controlplane`](./charts/controlplane/)** — Union control plane (flyteadmin, identity, executions, queue, scheduler, etc.).
- **[`charts/dataplane`](./charts/dataplane/)** — Union dataplane (union-operator / propeller) that onboards a Kubernetes cluster to a Union control plane.
- **[`charts/dataplane-crds`](./charts/dataplane-crds/)** — **deprecated**. Use vendored CRDs at [`crds/`](./crds/) instead.

## Documentation by deployment mode

| Mode | Where to start | What this repo covers |
|---|---|---|
| **Self-managed dataplane** (Union-managed control plane, you run the DP) | [docs.union.ai → Self-managed deployment](https://www.union.ai/docs/v2/union/deployment/selfmanaged/) | Per-cloud `prepare-infra` and `deploy-dataplane` pages walk through the full path; this repo's [`charts/dataplane/README.md`](./charts/dataplane/) covers the Helm install. |
| **Selfhosted** (you run both control plane and dataplane) | Reach out to [support@union.ai](mailto:support@union.ai) | Production selfhosted setup has meaningful operational requirements (cluster prerequisites, ingress + TLS, OIDC, multi-cluster routing). Support will scope the rollout with you. Chart-level install reference: [`charts/controlplane/README.md`](./charts/controlplane/) and [`charts/dataplane/README.md`](./charts/dataplane/). |
| **BYOC** (Union runs everything) | [docs.union.ai → BYOC](https://www.union.ai/docs/v2/union/deployment/byoc/) | Customers don't operate the chart directly; Union deploy tooling installs it. |

## Chart conventions

- [`charts/CONVENTIONS.md`](./charts/CONVENTIONS.md) — overlay file naming, what's actively tested vs. an example.
- [`charts/MIGRATION.md`](./charts/MIGRATION.md) — recent breaking-ish chart changes and how to migrate.

## Local development

Sample Terraform configurations for spinning up substrate to test against live in [`providers/`](./providers).

Helm version: 3.18+ (CI pins 3.19). Snapshot tests: `make test`.
