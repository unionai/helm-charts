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

> [!CAUTION]
> **Do not run `helm uninstall` or `terraform destroy` without following the steps below.**
> Because `templates/flyteworkflow.yaml` rendered the `FlyteWorkflow` CRD as an ordinary template (rather than inside Helm's `crds/` directory), **a standard `helm uninstall` or Terraform resource destruction will delete the `flyteworkflows.flyte.lyft.com` CRD and every existing FlyteWorkflow object across the cluster**.
> Server-side apply does not remove the CRD from Helm's stored release manifest. You must decouple the release safely before removing it.

### Step 1: Adopt CRDs via Server-Side Apply
Apply the current CRD manifests directly using server-side apply:
```bash
kubectl apply --server-side --force-conflicts -f crds/dataplane/
kubectl apply --server-side --force-conflicts -f crds/kube-prometheus-stack/
```

### Step 2: Decouple and remove the Helm release

#### If using Terraform (`helm_release`)
Do **NOT** destroy the resource. Detach the resource from Terraform state so Terraform forgets it without deleting cluster resources:
```bash
terraform state rm helm_release.dataplane_crds
```
Then safely remove the `resource "helm_release" "dataplane_crds"` configuration block from your `.tf` files.

#### If using plain Helm
Before uninstalling, annotate the `FlyteWorkflow` CRD with `helm.sh/resource-policy: keep` so Helm retains it when the release is deleted:
```bash
kubectl annotate crd flyteworkflows.flyte.lyft.com helm.sh/resource-policy=keep --overwrite
helm uninstall <release-name> -n <namespace>
```

### Step 3: Ongoing maintenance
On future dataplane chart bumps, keep CRDs updated by server-side applying manifests directly from `crds/dataplane/` at the matching git tag.

## Values (deprecated chart)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| crds.flyte | bool | `true` |  |
