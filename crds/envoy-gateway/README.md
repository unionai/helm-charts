# envoy-gateway CRDs

Vendored from `oci://docker.io/envoyproxy/gateway-helm`. Version pinned in
[`VERSION`](VERSION); kept in sync with the `gateway-helm` dep in
[`charts/controlplane/Chart.yaml`](../../charts/controlplane/Chart.yaml) by
[`scripts/sync.sh`](scripts/sync.sh) and gated by
[`scripts/check.sh`](scripts/check.sh).

See [`../README.md`](../README.md) for the rationale.

## What's vendored

This directory ships **both** sets of CRDs the gateway-helm chart bundles:

1. **Gateway API standard CRDs** (group `gateway.networking.k8s.io`, plus the
   experimental `gateway.networking.x-k8s.io`) — `Gateway`, `GatewayClass`,
   `HTTPRoute`, `TCPRoute`, `TLSRoute`, `UDPRoute`, `GRPCRoute`,
   `ReferenceGrant`, `BackendTLSPolicy`, plus a few experimental
   `x-k8s.io` types.
2. **Envoy-specific CRDs** (group `gateway.envoyproxy.io`) — `EnvoyProxy`,
   `EnvoyPatchPolicy`, `ClientTrafficPolicy`, `BackendTrafficPolicy`,
   `SecurityPolicy`, `EnvoyExtensionPolicy`, `Backend`, `HTTPRouteFilter`.

If a customer already manages the standard Gateway API CRDs from another
source (another Gateway API implementation in the same cluster), they should
opt out of this ArgoCD Application entirely — installing the same Gateway
API CRDs twice will cause SSA `fieldManager` thrash between owners. See
the customer-facing install docs for the opt-out instructions.

## Refresh

```bash
# from repo root
make vendor-crds
```

This is also run automatically by `make generate-expected`.
