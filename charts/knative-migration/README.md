# knative-migration

One-shot cleanup of `knative-operator` residue on Union dataplane clusters
after the `dataplane` chart migrates from operator-managed `KnativeServing`
to directly-rendered Knative Serving + Kourier manifests (the "zero trust"
gateway).

## When to run it

Run this chart **before** upgrading the `dataplane` chart to a version that
has `gateway.enabled: true` and no longer renders the `KnativeServing` CR. If
you skip the migration:

- The `dataplane` upgrade tries to prune the orphaned `KnativeServing` CR.
- The operator finalizer (`knativeservings.operator.knative.dev`) blocks the
  delete.
- The operator itself is being torn down in the same upgrade, so nothing
  releases the finalizer.
- The upgrade hangs indefinitely.

Running this chart first strips the finalizer, removes the CR (including
all its operator-managed Deployments, Services, ConfigMaps, HPAs, and PDBs
via foreground-cascade delete), and deletes the operator's CRDs and
ClusterRole/ClusterRoleBindings.

## What it does

Renders four resources (a `Job` plus a dedicated `ServiceAccount`,
`ClusterRole`, and `ClusterRoleBinding`). The Job runs up to four
idempotent steps:

1. Strips the stuck finalizer on `KnativeServing/<knativeServingName>` (the
   default name `union-operator-serving` matches what the dataplane chart
   creates), then deletes the CR with `--cascade=foreground`. Polls for up
   to 12 minutes (360 × 2 s) for all dependents to be reaped.
2. **(helm-install path only, opt-in via `adoption.enabled: true`)** Stamps
   Helm release ownership metadata onto the 12 Knative Serving CRDs left
   behind by the operator (`certificates.networking.internal.knative.dev`,
   `routes.serving.knative.dev`, etc.). Required when the dataplane chart
   will be applied via `helm install` / `helm upgrade` (or any wrapper:
   Helmfile, Terraform `helm_release`). See [Adoption](#adoption) below.
3. Deletes the `knativeservings.operator.knative.dev` and
   `knativeeventings.operator.knative.dev` CRDs.
4. Deletes 7 `knative-*-operator*` ClusterRoles and 7 ClusterRoleBindings
   (6 with names matching the ClusterRoles, plus the asymmetric webhook
   pair: ClusterRole `knative-operator-webhook` and ClusterRoleBinding
   `operator-webhook` — note the `knative-` prefix on the role only).

Every step is idempotent; re-running on an already-clean cluster is a
no-op. RBAC is narrowed by `resourceNames` so the Job cannot delete or
patch arbitrary resources — only the named operator CRDs, the 12 Knative
Serving CRDs (when adoption is enabled), and the ClusterRoles /
ClusterRoleBindings listed above. Note that those names are upstream
Knative-shared: this chart assumes the target cluster has only the
Union-managed Knative install. Running it on a cluster that also hosts
an independent Knative Serving or Eventing installation will remove
resources that install depends on.

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
phase, not after — the orphaned `KnativeServing` finalizer would deadlock
Sync's prune of the CR, so PostSync hooks would never run.

```yaml
annotations:
  argocd.argoproj.io/hook: PreSync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded,BeforeHookCreation
```

### Plain resources

```bash
helm install unionai-knative-migration unionai/knative-migration \
  --namespace union \
  --wait
```

The Job runs once; the SA and RBAC remain until you `helm uninstall`. The
Job pod's logs are kept for 5 minutes after success
(`ttlSecondsAfterFinished: 300`).

## Verifying

Tail the Job's logs:

```bash
kubectl logs -n union \
  -l app.kubernetes.io/instance=unionai-knative-migration,app.kubernetes.io/name=knative-migration
```

Confirm the operator residue is gone:

```bash
# CRDs
kubectl get crd knativeservings.operator.knative.dev knativeeventings.operator.knative.dev 2>&1 \
  | grep -i 'not found'

# ClusterRoles
for n in knative-serving-operator knative-serving-operator-aggregated \
         knative-serving-operator-aggregated-stable knative-eventing-operator \
         knative-eventing-operator-aggregated knative-eventing-operator-aggregated-stable \
         knative-operator-webhook; do
  kubectl get clusterrole "$n" 2>&1 | grep -i 'not found'
done

# ClusterRoleBindings (note the webhook entry is `operator-webhook`, not
# `knative-operator-webhook`)
for n in knative-serving-operator knative-serving-operator-aggregated \
         knative-serving-operator-aggregated-stable knative-eventing-operator \
         knative-eventing-operator-aggregated knative-eventing-operator-aggregated-stable \
         operator-webhook; do
  kubectl get clusterrolebinding "$n" 2>&1 | grep -i 'not found'
done
```

Each command should report `NotFound`.

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
| `knativeServingName` | `union-operator-serving` | `KnativeServing` CR to unstick (release-namespaced). |
| `adoption.enabled` | `false` | Stamp Helm ownership metadata onto the 12 Knative Serving CRDs. Enable only for helm-install paths; see [Adoption](#adoption). |
| `adoption.targetRelease` | `""` | Required when `adoption.enabled: true`. Helm release name used for `helm install/upgrade dataplane`. |
| `adoption.targetNamespace` | `""` | Required when `adoption.enabled: true`. Namespace of the dataplane release. |
| `job.backoffLimit` | `3` | |
| `job.activeDeadlineSeconds` | `900` | 15 min. Sized to absorb foreground-cascade GC of the CR's dependents (the activator pod's `terminationGracePeriodSeconds: 600` is the long pole). |
| `job.ttlSecondsAfterFinished` | `300` | Keeps Pod logs for 5 min after success. |
| `resources` | small (10m CPU / 32Mi req) | Pod resources. |
| `nodeSelector` / `tolerations` / `affinity` | empty | Standard placement. |
| `nameOverride` / `fullnameOverride` | empty | Helm convention. |

## Troubleshooting

**Job pod fails with `forbidden`.** The cluster's RBAC is preventing the
chart's ClusterRole from being created. Verify the user installing the
chart has permission to create cluster-scoped RBAC.

**Job hangs at step 1 (foreground-cascade-delete the CR).** A pod owned by
the `KnativeServing` is failing to terminate within
`terminationGracePeriodSeconds`. Check pod events on `activator`,
`autoscaler`, etc. The Job's `activeDeadlineSeconds: 900` will eventually
fail the Job; increase the value if your cluster legitimately needs longer
to reap pods.

**Job hangs at step 1 after a previous run was interrupted.** Step 1 is
idempotent across retries: the patch removes the operator finalizer by
index, so it preserves `foregroundDeletion` (added by the API server when
`delete_wait` issues `--cascade=foreground`) and any finalizers added by
unrelated controllers. If the operator finalizer is absent on retry, the
patch is skipped and `delete_wait` polls until GC reaps the remaining
dependents. If another controller added its own finalizer, `delete_wait`
will block on it — investigate that controller, not this Job.

**Re-running.** All three cleanup steps are idempotent. Re-running on a
clean cluster is a no-op; re-running after an interrupted previous run
resumes from wherever it left off.
