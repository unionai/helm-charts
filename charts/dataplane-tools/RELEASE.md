# dataplane-tools — Release Notes

## 2026.8.1

Initial chart. Deploys Grafana plus Prometheus and Kubernetes MCP servers into a
data plane as scale-to-zero Knative Services, each exposed at
`<subdomain>.<appsDomain>` via a Knative DomainMapping behind the vendored Kourier
+ `union-authn` gateway. Every Knative resource is gated on the
`serving.knative.dev` CRDs being served (`.Capabilities.APIVersions.Has`), so the
chart is a no-op on non-Knative clusters. Ships a read-only ClusterRole (secrets
excluded) for the Kubernetes MCP server.
