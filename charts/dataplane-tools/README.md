# dataplane-tools

Auxiliary, Knative-served tooling deployed **into a data plane cluster** for
observability and debugging:

| Service | What it is | Default host |
|---|---|---|
| `grafana` | Grafana dashboards over the data plane's in-cluster Prometheus (anonymous behind the auth edge) | `grafana.<appsDomain>` |
| `prometheusMcp` | MCP server exposing the cluster's Prometheus to agents | `prometheus-mcp.<appsDomain>` |
| `k8sMcp` | MCP server exposing the data plane's kube API (read-only) to agents | `k8s-mcp.<appsDomain>` |

Each service renders as a **Knative Service** (scale-to-zero via KPA) plus a
**Knative DomainMapping** that publishes it at `<subdomain>.<appsDomain>` — a
single label under the data plane's existing `*.apps.<dp>.<domain>` wildcard cert
and DNS, routed through the vendored Kourier gateway and its `union-authn`
`ext_authz` edge.

## Long-term home

These are, conceptually, **per-data-plane Apps**. The durable home for them is
likely **Union Apps** — the app-serving control plane (App records, leasing,
per-DP `public_url`, the same `union-authn` `ext_authz` edge) — rather than a
standalone chart. This chart is the near-term delivery of the same substrate
(Knative + gateway) while that path matures; expect it to be folded into Union
Apps and eventually retired.

## Requirements

- **Knative Serving + the vendored gateway** on the data plane (dataplane chart,
  `gateway.enabled=true`). Every resource here is gated on the
  `serving.knative.dev` CRDs actually being served
  (`.Capabilities.APIVersions.Has`) — on a cluster without Knative the chart
  renders nothing rather than failing.
- **`appsDomain`** — the data plane's apps wildcard (`apps.<dp>.<domain>`),
  supplied per-environment by terraform. Required to expose any service.

## Auth

Services inherit the gateway's `union-authn` `ext_authz` edge by being routed
through it — there is no per-service auth toggle. A human reaches Grafana via the
browser OIDC client; an agent reaches an MCP server with a Union-minted token.

## Images

The MCP `image` defaults reference community servers so the chart deploys out of
the box. **Pin a digest and/or mirror them to your registry before production.**

## Rendering / testing

Because the resources are capability-gated, `helm template` must be told which
CRDs exist:

```sh
helm template dataplane-tools charts/dataplane-tools \
  --api-versions serving.knative.dev/v1 \
  --api-versions serving.knative.dev/v1beta1 \
  --set appsDomain=apps.dp-1.example.com
```

Without `--api-versions` the Knative paths are skipped (the documented no-op
behavior on a non-Knative cluster).
