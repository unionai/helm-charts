# Local k3d dataplane

Stand up a local [k3d](https://k3d.io) dataplane that mirrors the
`dataplane-integration` CI job — a single-node cluster with an embedded registry,
an in-cluster [RustFS](rustfs.yaml) object store, and the dataplane chart
installed with the [`charts/dataplane/values.k3d.yaml`](../../charts/dataplane/values.k3d.yaml)
overlay. Use it to reproduce and debug the CI environment locally.

CI and this script share the **same** overlay (`charts/dataplane/values.k3d.yaml`)
and RustFS manifest (`hack/k3d/rustfs.yaml`), so they can't drift.

## Prerequisites

`k3d`, `kubectl`, `helm` (**3.17.x** — matches CI; other majors can hit helm's
1 MB release-secret limit on this chart), `docker`, and optionally `mc`
(minio-client, to create the RustFS bucket) and `awscli`+`jq` (for
`--from-aws-secret`).

## Operator credentials

The dataplane operator authenticates to the control plane with a machine-identity
OAuth client (`client_id` + `client_secret`). These are **inputs** — never
committed. `up.sh` writes them into an ephemeral, `0600`, auto-deleted
`values-provision.yaml` (the same shape CI generates) and passes it to helm with
`-f`. They are **not** passed via `helm --set` (numeric Zitadel client IDs would be
coerced to numbers, secrets with `, . =` break `--set`, and the secret would land
on the command line).

Get the creds the same way CI does — the seeded operator secret in AWS Secrets
Manager, e.g. `selfmanaged/canary/helm-charts-ci/sm-k3d-dp-1/operator` (JSON
`{client_id, client_secret}`).

## Usage

```bash
# creds as flags
hack/k3d/up.sh --client-id <id> --client-secret <secret>

# creds from env
OPERATOR_CLIENT_ID=<id> OPERATOR_CLIENT_SECRET=<secret> hack/k3d/up.sh

# creds fetched from AWS (needs awscli + jq)
hack/k3d/up.sh --from-aws-secret selfmanaged/canary/helm-charts-ci/sm-k3d-dp-1/operator

# also run the smoke suite after install
hack/k3d/up.sh --from-aws-secret <name> --smoke

# teardown
hack/k3d/down.sh
```

Overridable defaults (match CI): `--cp-host helm-charts-ci.canary.unionai.cloud`,
`--org helm-charts-ci`, `--cluster-name sm-k3d-dp-1`.

## What `up.sh` does

1. Creates the k3d cluster (`ci-dataplane`) with an embedded HTTP registry.
2. Applies the dataplane CRDs out-of-band (kept out of the helm release).
3. Builds chart dependencies.
4. Deploys RustFS + creates the `union-data` bucket.
5. Writes the ephemeral `values-provision.yaml` from your creds and runs
   `helm upgrade --install union ./charts/dataplane -f values-provision.yaml -f charts/dataplane/values.k3d.yaml`.
6. Waits for the cluster to register healthy on the control plane
   (`ci_dataplane.py wait-healthy`), and optionally runs the smoke suite.

On install failure it dumps not-ready pod status, events, and logs.
