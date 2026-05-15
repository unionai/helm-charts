# knative-migration

One-shot preparation step for migrating a Union dataplane cluster from
operator-managed `KnativeServing` to the directly-rendered Knative Serving
+ Kourier manifests in the `dataplane` chart's zero-trust gateway mode.

## When to run it

Run this chart **before** upgrading the `dataplane` chart to a version that
has `gateway.enabled: true` and no longer renders the `KnativeServing` CR.

The migration is a deletion of the `KnativeServing` CR while the
`knative-operator` is still alive. The operator's finalizer runs and tears
down everything it installed from the KnativeServing manifest — Deployments
(activator, autoscaler, controller, webhook, net-kourier-controller,
3scale-kourier-gateway), their Services, ConfigMaps, HPAs, PDBs, and the
cluster-scoped ClusterRoles, ClusterRoleBindings, and WebhookConfigurations
upstream Knative Serving owns. Doing this **after** the operator is gone
would orphan all of the above; the operator is the only thing that knows
which cluster-scoped resources belong to its CR.

What the operator's finalizer does *not* delete: the 12 Knative Serving
CRDs (`certificates.networking.internal.knative.dev`,
`routes.serving.knative.dev`, etc.) — these are global infrastructure with
no owner reference. This chart adopts them into the dataplane Helm release
in step 2 so the subsequent `helm upgrade dataplane` can claim them
without an `invalid ownership metadata` failure.

## What it does

Renders six resources (a `Job`, plus a dedicated `ServiceAccount`,
namespaced `Role` + `RoleBinding` for the `KnativeServing` CR, and a
`ClusterRole` + `ClusterRoleBinding` for the cluster-scoped cleanup
targets). The namespaced `Role`/`RoleBinding` split keeps the
`KnativeServing` delete permission bound to `.Release.Namespace`, so a
same-named CR in any other namespace cannot be touched by this SA.
The Job runs three idempotent steps:

1. Deletes `KnativeServing/<knativeServingName>` (default
   `union-operator-serving`) with `kubectl delete --wait=true --timeout=720s`.
   The running operator processes the deletion via its finalizer, tearing
   down all Deployments/Services/ConfigMaps/HPAs/PDBs/ClusterRoles/
   ClusterRoleBindings/WebhookConfigurations it installed. `--wait=true`
   blocks until the API server reaps the CR, which only happens after every
   finalizer (including the operator's) completes. The 720s timeout covers
   the activator pod's 600s `terminationGracePeriodSeconds` plus margin.
2. **(helm-install path only, opt-in via `adoption.enabled: true`)** Stamps
   Helm release ownership metadata onto the 12 Knative Serving CRDs left
   behind by the operator. Required when the dataplane chart will be
   applied via `helm install` / `helm upgrade` (or any wrapper: Helmfile,
   Terraform `helm_release`). See [Adoption](#adoption) below. User
   CRs of these types (e.g. Knative Services in domain namespaces) are
   preserved — adoption only mutates CRD metadata, not instances.
3. Deletes the `knativeservings.operator.knative.dev` and
   `knativeeventings.operator.knative.dev` CRDs. The operator's finalizer
   does not delete CRDs, so these are removed explicitly. By this point
   step 1 has confirmed there are no remaining `KnativeServing` instances,
   so the CRDs have nothing left to GC.

The 7 ClusterRoles + 7 ClusterRoleBindings that scope the operator binary
itself (`knative-serving-operator`, `knative-operator-webhook`,
`operator-webhook`, etc.) and the operator Deployments are pruned by Helm
when the `knative-operator` subchart is disabled in the subsequent
`helm upgrade dataplane` — they are part of the dataplane Helm release's
manifest from the prior install, so Helm tracks and removes them. This
chart does not need to enumerate them.

Every step is idempotent; re-running on an already-clean cluster is a
no-op. RBAC is narrowed by `resourceNames` so the Job cannot delete or
patch arbitrary resources — only the named `KnativeServing` CR, the 2
operator CRDs, and the 12 Knative Serving CRDs (when adoption is enabled).
Note that those names are upstream Knative-shared: this chart assumes the
target cluster has only the Union-managed Knative install. Running it on a
cluster that also hosts an independent Knative Serving or Eventing
installation will remove resources that install depends on.

## Failure mode: operator unhealthy at delete time

If the `knative-operator` Deployment is absent or crash-looping when the
Job runs, the operator's finalizer never executes; `kubectl delete --wait`
blocks until the 720s timeout, then exits non-zero. The Job retries via
`backoffLimit` and ultimately fails. This is intentional: silently
proceeding without the operator's cleanup would orphan the runtime
ClusterRoles + WebhookConfigurations the operator installed, which is
exactly what this design avoids.

Pre-flight check before running the chart: verify
`kubectl get deploy -n union knative-operator` shows at least one Ready
replica. If not, restore the operator (`helm rollback` or `helm upgrade`
the previous revision) before invoking the migration.

## Adoption

The dataplane chart's zero-trust mode renders the 12 Knative Serving CRDs
as Helm-managed resources, but on an existing operator-managed cluster
those CRDs already exist — installed imperatively by the
`knative-operator` binary with no Helm metadata. Helm v3's client refuses
to apply CRDs without `meta.helm.sh/release-name` /
`meta.helm.sh/release-namespace` annotations matching the current release,
so a raw `helm upgrade dataplane` after the operator → zero-trust
transition fails with `invalid ownership metadata`.

Set `adoption.enabled: true` to make this Job stamp the required
annotations + the `app.kubernetes.io/managed-by=Helm` label onto each of
the 12 Serving CRDs before the dataplane upgrade runs:

```yaml
adoption:
  enabled: true
  targetRelease: unionai-dataplane    # MUST match `helm install/upgrade dataplane`
  targetNamespace: union              # MUST match the dataplane release namespace
```

`targetRelease` and `targetNamespace` have no defaults and are required
when `adoption.enabled: true` — the chart's template-time `required`
guard fails `helm install knative-migration` if either is missing, so the
error surfaces clearly instead of as a misleading `helm upgrade dataplane`
failure later.

**Do not enable adoption for non-Helm install paths.** ArgoCD (with a
Helm source), Pulumi, kustomize, and raw `kubectl apply` all bypass
Helm's ownership pre-flight — they don't need Helm metadata to apply the
CRDs, and stamping Helm provenance onto resources those tools manage
creates incorrect ownership metadata that can trigger drift-correction
loops in their reconciliation. The default `adoption.enabled: false` is
correct for every non-Helm path.

## Install

The chart does not hard-code hook annotations. Choose a mode by populating
`annotations:` in your values.

### Helm hook (recommended for `helm install` / `helm upgrade` flows)

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

`hook-succeeded,before-hook-creation` ensures the SA, RBAC, and Job all
clean up automatically once the Job succeeds. Re-run via `helm upgrade`.

### ArgoCD `PreSync` hook

For ArgoCD-managed deployments, the migration must run **before** the Sync
phase, not after — the CR deletion must happen while the operator is still
running, and Sync would tear down the operator at the same time as the
gateway resources are applied.

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

`--wait-for-jobs` is required: Helm's `--wait` covers Pods, Services, and
Deployments but not Jobs, so without it the command would return before
the migration finishes and a subsequent `helm upgrade dataplane` would
race the cleanup. The `--timeout 15m` mirrors `job.activeDeadlineSeconds:
900` so Helm's wait window can't expire before the Job's own deadline.

The Job runs once; the SA and RBAC remain until you `helm uninstall`. The
Job pod's logs are kept for 5 minutes after success
(`ttlSecondsAfterFinished: 300`).

## Verifying

Tail the Job's logs:

```bash
kubectl logs -n union \
  -l app.kubernetes.io/instance=unionai-knative-migration,app.kubernetes.io/name=knative-migration
```

Confirm the operator CRDs are gone and the KnativeServing CR is absent:

```bash
kubectl get crd knativeservings.operator.knative.dev knativeeventings.operator.knative.dev 2>&1 \
  | grep -i 'not found'

kubectl get knativeserving -n union 2>&1 | grep -E 'No resources|not found'
```

Both commands should report `NotFound` / `No resources found`.

If `adoption.enabled: true`, confirm the 12 Serving CRDs carry Helm
ownership metadata:

```bash
kubectl get crd services.serving.knative.dev \
  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}'
# expected: <your dataplane release name>
```

## Removal

After all clusters have run the Job successfully:

- **Plain mode**: `helm uninstall unionai-knative-migration --namespace union`.
- **Helm hook mode**: nothing to do — `hook-succeeded` already cleaned up.
- **Argo PreSync mode**: nothing to do — `HookSucceeded` already cleaned up.

## Values

| Key | Default | Purpose |
|---|---|---|
| `image.repository` | `alpine/kubectl` | Runner image. |
| `image.tag` | `1.33.4` | Runner image tag. |
| `image.pullPolicy` | `IfNotPresent` | |
| `labels` | `{}` | Common labels merged into all four resources. |
| `annotations` | `{}` | Common annotations; populate to declare install mode. |
| `knativeServingName` | `union-operator-serving` | `KnativeServing` CR to delete (release-namespaced). |
| `adoption.enabled` | `false` | Stamp Helm ownership metadata onto the 12 Knative Serving CRDs. Enable only for helm-install paths; see [Adoption](#adoption). |
| `adoption.targetRelease` | `""` | Required when `adoption.enabled: true`. Helm release name used for `helm install/upgrade dataplane`. |
| `adoption.targetNamespace` | `""` | Required when `adoption.enabled: true`. Namespace of the dataplane release. |
| `job.backoffLimit` | `3` | |
| `job.activeDeadlineSeconds` | `900` | 15 min. Sized to absorb the operator finalizer's cascade GC of the CR's dependents (the activator pod's `terminationGracePeriodSeconds: 600` is the long pole). |
| `job.ttlSecondsAfterFinished` | `300` | Keeps Pod logs for 5 min after success. |
| `resources` | small (10m CPU / 32Mi req) | Pod resources. |
| `nodeSelector` / `tolerations` / `affinity` | empty | Standard placement. |
| `nameOverride` / `fullnameOverride` | empty | Helm convention. |

## Troubleshooting

**Job pod fails with `forbidden`.** The cluster's RBAC is preventing the
chart's ClusterRole from being created. Verify the user installing the
chart has permission to create cluster-scoped RBAC.

**Job times out at step 1 (`kubectl delete knativeserving --wait`).**
Either the operator is unhealthy (so its finalizer never runs — see
[Failure mode](#failure-mode-operator-unhealthy-at-delete-time)), or a pod
owned by the KnativeServing is failing to terminate within
`terminationGracePeriodSeconds`. Check `kubectl get pods -n union` for
stuck terminating pods on `activator` / `autoscaler` / `controller`, and
`kubectl logs -n union deploy/knative-operator` for finalizer errors.
The Job's `activeDeadlineSeconds: 900` will eventually fail the Job;
investigate before retrying.

**`helm upgrade dataplane` fails with `invalid ownership metadata` on a
Knative Serving CRD.** The migration Job ran without `adoption.enabled:
true`, so the 12 Serving CRDs still lack Helm provenance. Re-run the
chart with `adoption.enabled: true`, `adoption.targetRelease`, and
`adoption.targetNamespace` set, then retry the dataplane upgrade. Step 1
is a no-op on retry (CR already absent).

**Re-running.** All three steps are idempotent. Re-running on a clean
cluster is a no-op.
