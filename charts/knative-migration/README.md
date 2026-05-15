# knative-migration

One-shot Job that prepares a Union dataplane for upgrade to zero-trust mode.

## When to run it

**Before** upgrading the `dataplane` chart to a version with `gateway.enabled: true`. Skipping this step deadlocks the upgrade.

The `knative-operator` must be **healthy** when the Job runs. Confirm with:

```bash
kubectl get deploy -n union knative-operator
```

If the operator is missing or crash-looping, restore it first.

## What it does

The Job runs three idempotent steps:

1. Deletes the `KnativeServing` CR. The operator's finalizer tears down everything it installed.
2. (Helm-install paths only — see [Adoption](#adoption)) Stamps Helm ownership metadata onto the 12 Knative Serving CRDs.
3. Deletes the operator's two CRDs (`knativeservings.operator.knative.dev`, `knativeeventings.operator.knative.dev`).

Re-running on a clean cluster is a no-op.

## Install

The chart does not hard-code hook annotations — choose a mode by setting `annotations:` in your values file.

### Helm post-install / post-upgrade hook

`overrides.yaml`:

```yaml
annotations:
  helm.sh/hook: post-install,post-upgrade
  helm.sh/hook-delete-policy: hook-succeeded,before-hook-creation
  helm.sh/hook-weight: "10"
```

```bash
helm install unionai-knative-migration unionai/knative-migration \
  --namespace union \
  --values overrides.yaml \
  --wait
```

### ArgoCD PreSync hook

```yaml
annotations:
  argocd.argoproj.io/hook: PreSync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation
```

### Plain resources

```bash
helm install unionai-knative-migration unionai/knative-migration \
  --namespace union \
  --wait --wait-for-jobs --timeout 15m
```

`--wait-for-jobs` is required so the install does not return before the Job finishes.

## Adoption

Enable adoption **only** if you apply the `dataplane` chart with `helm install` / `helm upgrade` (or any Helm wrapper like Helmfile or Terraform `helm_release`). Without it, the next `helm upgrade dataplane` fails with `invalid ownership metadata`.

```yaml
adoption:
  enabled: true
  targetRelease: <dataplane release name>
  targetNamespace: <dataplane release namespace>
```

`targetRelease` and `targetNamespace` **must exactly match** the values you use for `helm install/upgrade dataplane`.

Leave `adoption.enabled: false` (the default) for ArgoCD, Pulumi, kustomize, or raw `kubectl apply`.

## Verify

```bash
kubectl logs -n union -l app.kubernetes.io/name=knative-migration

kubectl get knativeserving -n union
# expected: No resources found

kubectl get crd knativeservings.operator.knative.dev knativeeventings.operator.knative.dev
# expected: NotFound
```

## Values

| Key | Default | Purpose |
|---|---|---|
| `image.repository` | `alpine/kubectl` | Runner image. |
| `image.tag` | `1.33.4` | Runner image tag. |
| `image.pullPolicy` | `IfNotPresent` | |
| `labels` | `{}` | Common labels on all resources. |
| `annotations` | `{}` | Populate to declare install mode (Helm hook, Argo hook, or plain). |
| `knativeServingName` | `union-operator-serving` | `KnativeServing` CR to delete. |
| `adoption.enabled` | `false` | Stamp Helm ownership onto Knative Serving CRDs. See [Adoption](#adoption). |
| `adoption.targetRelease` | `""` | Required when `adoption.enabled: true`. |
| `adoption.targetNamespace` | `""` | Required when `adoption.enabled: true`. |
| `job.backoffLimit` | `3` | |
| `job.activeDeadlineSeconds` | `900` | Job timeout (15 min). |
| `job.ttlSecondsAfterFinished` | `300` | |
| `resources` | `10m CPU / 32Mi mem` | Pod resources. |
| `nodeSelector` / `tolerations` / `affinity` | empty | Standard placement. |

## Troubleshooting

**Job times out on `kubectl delete knativeserving`.** The operator is unhealthy and its finalizer never ran. Restore the operator (`helm rollback` to the previous revision) and retry.

**`helm upgrade dataplane` fails with `invalid ownership metadata`.** Re-run this chart with `adoption.enabled: true` and the correct `adoption.targetRelease` / `adoption.targetNamespace`, then retry the upgrade.

## Uninstall

```bash
helm uninstall unionai-knative-migration --namespace union
```

(Helm hook and Argo PreSync modes clean up automatically.)
