# grafana-dataplane — Grafana as a Flyte App

Runs Grafana inside a dataplane cluster and serves the **shipped** v1/v2 + Karpenter dataplane
dashboards over that cluster's Prometheus. Grafana runs anonymous with no login; the auth
boundary is the zero-trust app-serving edge (`requires_auth=True`). One app = one cluster's
Prometheus — no cross-cluster query fan-out, no public Prometheus exposure.

## Layout

```
apps/grafana-dataplane/
  app.py                       # flyte AppEnvironment `grafana` + flyte.serve
  sync_dashboards.py           # syncs dashboards from charts/dataplane (source of truth)
  grafana/
    provisioning/
      dashboards/dashboards.yaml            # file provider -> /var/lib/grafana/dashboards
      datasources/mode-in-cluster.yaml      # DATASOURCE_MODE variants (one is baked as
      datasources/mode-amp.yaml             #   datasources.yaml, chosen at serve time)
      datasources/mode-azure.yaml
    dashboards/                             # SYNCED from the chart — do not edit by hand
```

## Dashboards stay in sync with the chart

`grafana/dashboards/*.json` are generated from `charts/dataplane` by `sync_dashboards.py`, with
`__NAMESPACE__` replaced by the union-services namespace (default `dataplane`) exactly as helm's
dashboard-configmap does. The app therefore serves byte-identical dashboards to what the chart
ships. CI enforces this:

```bash
make sync-app-dashboards     # regenerate grafana/dashboards/ from charts/dataplane
make check-app-dashboards    # fail if grafana/dashboards/ drifts from the chart (runs in `make test`)
```

Edit dashboards in `charts/dataplane`, then `make sync-app-dashboards` and commit both.

## Prometheus datasource — auth modes

`DATASOURCE_MODE` picks how the single Prometheus datasource authenticates. The pod's cloud
identity is the **worker namespace's `default` ServiceAccount** (WIF on GKE, IRSA on EKS,
Workload Identity on AKS) — no secrets mounted.

| `DATASOURCE_MODE`          | `DS_PROM_URL` (`PROMETHEUS_URL`)                              | Auth                               |
| ---------------------------- | ----------------------------------------------------------------- | ---------------------------------- |
| `in-cluster` *(default)* | `http://prometheus-operated.<ns>.svc:9090`                      | none (proxy)                       |
| `gmp-frontend`             | in-cluster GMP frontend proxy URL                                 | none; frontend uses pod WIF → GMP |
| `amp`                      | `https://aps-workspaces.<region>.amazonaws.com/workspaces/<id>` | SigV4, pod IRSA (`AWS_REGION`)   |
| `azure`                    | Azure Monitor workspace query endpoint                            | Azure Workload Identity            |

`<ns>` is `dataplane` for a separate DP, `controlplane` for an intracluster (CP+DP) deploy.
Grafana's Prometheus datasource has no native Google OAuth, so GMP goes through its frontend
proxy — which reduces to the unauthenticated in-cluster mode.

## Serve

```bash
eval "$(/opt/homebrew/opt/micromamba/bin/mamba shell activate default)"
export FLYTECTL_CONFIG=/…/cloud/gen/cli-config/uctl/<env>.v2.yaml

make sync-app-dashboards            # ensure grafana/dashboards/ is current
export PROMETHEUS_URL=http://prometheus-operated.dataplane.svc.cluster.local:9090
# export DATASOURCE_MODE=amp AWS_REGION=us-east-2   # for AMP; azure/gmp-frontend analogous
# export APP_NAME=grafana                           # deployed app name (default: grafana)
# export APP_SUBDOMAIN=grafana                      # stable subdomain; empty -> platform default

# Flags BEFORE the file; app env var is `grafana`. Omit --follow (log tail errors; deploy is fine).
flyte serve --project <proj> --domain <domain> app.py grafana
```

## Access & least privilege

Grafana is anonymous behind the app edge; the edge authorizes *who* can open the app, not
what they can do inside, so every visitor shares one role. The default is **Viewer**
(`GF_ANON_ROLE`) — least privilege, and it keeps the datasource un-editable (no proxy
re-point / SSRF). Set `GF_ANON_ROLE=Admin` only if you accept that any identity able to
authenticate to your Union host gets Admin (Explore, datasource edits) here.

## Deferred hardening

Pod-level egress NetworkPolicy (Prometheus-only, block IMDS `169.254.169.254`) and shared
multi-org DP scoping. Lock the pod egress down before any shared-tenancy use.
