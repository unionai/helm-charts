# dataplane-crds (DEPRECATED)

> **Deprecated.** This chart is retained for back-compat while consumers
> migrate. New deployments should use the vendored-CRD directories instead:
>
> - `crds/dataplane/` — `flyteworkflows.flyte.lyft.com` + Knative Serving
>   CRDs (FlyteWorkflow previously rendered by this chart's
>   `templates/flyteworkflow.yaml`).
> - `crds/kube-prometheus-stack/` — prometheus-operator CRDs (previously
>   pulled in by this chart's `prometheus-operator-crds` dependency).

The vendored directories ship per-CRD YAML with the
`argocd.argoproj.io/sync-options: ServerSideApply=true` annotation injected,
which avoids the 256 KiB `last-applied-configuration` overflow that ArgoCD's
client-side apply hits on large operator CRDs.

## Migration Guide (Decommissioning this chart)

If you currently manage a `helm_release` for `dataplane-crds` in Terraform or Helm:

1. **Adopt CRDs via Server-Side Apply**:
   Before removing the chart release, apply the CRDs directly using server-side apply:
   ```bash
   kubectl apply --server-side --force-conflicts -f crds/dataplane/
   kubectl apply --server-side --force-conflicts -f crds/kube-prometheus-stack/
   ```
2. **Remove the Helm Release**:
   - In Terraform: Remove the `helm_release` resource for `dataplane-crds` (or use `terraform state rm` if you want to ensure Helm's uninstall hook doesn't touch cluster resources).
   - In plain Helm: `helm uninstall <release-name> -n <namespace>`. Standard Kubernetes CRDs are retained when deleting a Helm release, but server-side apply ensures the desired CRD manifests remain actively managed.
3. **Future Upgrades**:
   On future dataplane chart bumps, keep CRDs updated by server-side applying manifests directly from `crds/dataplane/` at the matching git tag.

## Values (deprecated chart)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| crds.flyte | bool | `true` |  |
