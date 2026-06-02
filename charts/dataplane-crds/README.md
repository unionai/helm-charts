# dataplane-crds (DEPRECATED)

> **Deprecated.** This chart is retained for back-compat while consumers
> migrate. New deployments should use the vendored-CRD directories instead:
>
> - `crds/flyte-v1/` — `flyteworkflows.flyte.lyft.com` (previously rendered
>   by this chart's `templates/flyteworkflow.yaml`).
> - `crds/kube-prometheus-stack/` — prometheus-operator CRDs (previously
>   pulled in by this chart's `prometheus-operator-crds` dependency).

The vendored directories ship per-CRD YAML with the
`argocd.argoproj.io/sync-options: ServerSideApply=true` annotation injected,
which avoids the 256 KiB `last-applied-configuration` overflow that ArgoCD's
client-side apply hits on large operator CRDs.

## Values (deprecated chart)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| crds.flyte | bool | `true` |  |
