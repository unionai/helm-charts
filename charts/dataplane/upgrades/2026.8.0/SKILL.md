---
name: upgrade-dataplane-2026.8.0
description: Upgrade a self-managed Union dataplane from 2026.7.2 to 2026.8.0. Use when upgrading, planning, or verifying this specific chart version hop, or when jumping across a version range that includes 2026.8.0. Covers required values changes, silent default changes, verification, and rollback.
---

# Dataplane 2026.7.2 to 2026.8.0

A chart-only release: `appVersion` stays at `2026.7.2`, so no component images change. What
changes is configuration. The legacy executor deployment is removed, several values keys
are retired, and a set of defaults that used to live in the per-cloud overlay files moved
into the base chart.

| | |
|---|---|
| **Impact** | Breaking — inert values keys, no error raised |
| **Downtime** | None expected; the executor pod is removed and controllers restart |
| **Estimated time** | 15 minutes, plus verification |
| **Rollback** | Supported — `helm rollback`, no CRD or schema changes in this hop |

If you skip the required changes below, `helm upgrade` still succeeds. Custom task-log
links stop rendering, and any tuning you applied to the executor is silently discarded.

> Upgrading across several versions? Read every skill in `charts/dataplane/upgrades/`
> between your current version and your target, oldest first. Each covers one hop.

---

## 1. Before you upgrade

No CRD changes in this hop, and no chart dependency bumps. Capture your current state:

```bash
NS=<YOUR_NAMESPACE>          # namespace the dataplane release lives in
REL=<YOUR_RELEASE_NAME>      # e.g. unionai-dataplane

helm get values "$REL" -n "$NS" -o yaml > values-backup-$(date +%Y%m%d-%H%M).yaml
helm list -n "$NS"
kubectl get pods -n "$NS" --field-selector=status.phase!=Running
```

Start from a clean baseline. If pods are already unhealthy, resolve that first — otherwise
you cannot tell afterwards whether the upgrade caused it.

---

## 2. Required values changes

Helm does not validate values against a schema. **A key the chart no longer reads is
accepted and silently ignored** — no warning, no error, no clue in the diff of running
pods.

| Old key | New key | Migration |
|---|---|---|
| `executor.task_logs` | `leaseworker.task_logs` | Move the block. Same structure, same rendered output. |
| `executor.*` (all other keys) | — | Removed. Resources, scheduling, `raw_config`, `idl2Executor` are no longer read. |
| `executor.raw_config.namespace_mapping` | — | Namespace template override removed. Use the top-level `namespace_mapping`. |
| `global.CONTROLPLANE_GRPC_ENDPOINT` | — | Removed. The endpoint derives from `global.CONTROLPLANE_HOST`. |
| `global.QUEUE_GRPC_ENDPOINT` | — | Removed. The task-pod endpoint is injected from `config.union.connection`. |

`executor.task_logs` is the one that bites. It still takes precedence *if set*, so your
links keep working on this version — but every other `executor.*` key is already inert, and
the compatibility shim will not last. Move it now:

```yaml
# Before
executor:
  task_logs:
    plugins:
      logs:
        templates: [...]

# After
leaseworker:
  task_logs:
    plugins:
      logs:
        templates: [...]
```

### Check your file

```bash
grep -nE '^\s*(executor:|CONTROLPLANE_GRPC_ENDPOINT|QUEUE_GRPC_ENDPOINT)' <YOUR_VALUES>.yaml
```

Any hit is a key this release no longer reads. Expect no output once migrated.

> If your values file contains a template reference to the removed `queueEndpoint` helper —
> most often as a task-pod `default-env-vars` entry named `_U_EP_OVERRIDE` — the chart
> **fails to render** rather than ignoring it. Remove that entry before upgrading.
> ```bash
> grep -n '_U_EP_OVERRIDE\|queueEndpoint' <YOUR_VALUES>.yaml
> ```

---

## 3. Default values that change

Several defaults moved from the per-cloud overlay files (`values.aws.yaml`,
`values.gcp.yaml`, `values.azure.yaml`) into the base chart. Where an overlay and the base
previously disagreed, the base default now wins everywhere.

| Key | Old default | New default | To keep current behavior |
|---|---|---|---|
| `config.catalog.catalog-cache.use-admin-auth` | `false` on GCP, `true` on AWS/Azure | `true` everywhere | GCP only: set it back to `false` |
| `storage.enableMultiContainer` | `false` in base, `true` in every overlay | `true` in base | No change if you use an overlay |
| `config.union.auth.enable` | overlay-set | `true` in base | No change; a dataplane authenticates to its control plane by default |
| `secrets.admin.clientId` | standalone placeholder | derives from `global.AUTH_CLIENT_ID` | Set `global.AUTH_CLIENT_ID` if you had not |
| `monitoring.kubeControllerManager/Scheduler/Etcd/Proxy.enabled` | `true` | `false` | Leave as-is — see below |
| `monitoring.defaultRules.rules.*` | `true` | `false` | Leave as-is — see below |
| fluentbit ServiceAccount name | `fluentbit-system` | `union-system` | See below |

**The monitoring flips are a fix, not a regression.** A dataplane cannot scrape the
Kubernetes control-plane components, so those ServiceMonitors were producing false
`TargetDown` alerts. Turning them off removes noise. Only re-enable if you had deliberately
pointed them somewhere reachable.

**The fluentbit ServiceAccount rename needs action only if something outside the cluster
references it by name** — most commonly a cloud IAM trust policy or workload-identity
binding scoped to `fluentbit-system`. Update that binding to `union-system` before
upgrading, or log forwarding loses its credentials.

```bash
kubectl get sa -n "$NS" | grep -E 'fluentbit-system|union-system'
```

### `apps.enabled` supersedes `serving.enabled`

`apps.enabled` is the new toggle for app-serving components. Resolution order is
`apps.enabled`, then `serving.enabled`, then `true`.

| If you set | Result |
|---|---|
| `apps.enabled` | Wins |
| `serving.enabled` only | Still honored; a deprecation notice renders in the operator ConfigMap |
| Neither | Enabled |

At default values nothing changes. One real difference: under Zero Trust,
`apps.enabled: false` now also drops the vendored Knative components, which
`serving.enabled: false` used to leave running. If you disabled serving to reclaim
resources, you get more back on this version.

---

## 4. Image references

Every image the chart renders now spells out its registry host. An unqualified repository
resolves against an implicit Docker Hub default, which clusters with an allowed-registry
admission policy reject with `ErrImagePull`.

| Component | Old | New |
|---|---|---|
| Helm hook Jobs | `bitnami/kubectl:latest`, hardcoded in the template | `docker.io/alpine/k8s:1.32.3`, via the new `image.kubectl` key |
| `flytepropellerwebhook.legacyWebhookCleanup.image.repository` | `alpine/k8s` | `docker.io/alpine/k8s` |
| `fluentbit.testFramework.image.repository` | `busybox` (subchart default) | `docker.io/library/busybox` |

The hook image also moves off `bitnami/kubectl`, which upstream pruned down to `latest`
only — there was no longer a pinnable tag. Both Helm hooks now share one image.

**If you mirror images or run air-gapped, mirror these before upgrading.** The kubectl
image is used by pre-upgrade and pre-delete Helm hook Jobs, so a missing image shows up as
an upgrade that hangs rather than one that fails cleanly. The Helm hook Jobs now honor
`image.kubectl` instead of hardcoding the image, so a single override covers both:

```yaml
image:
  kubectl:
    repository: <YOUR_MIRROR>/alpine/k8s
    tag: "1.32.3"
```

---

## 5. Run the upgrade

```bash
helm repo update unionai

helm upgrade "$REL" unionai/dataplane \
  --version 2026.8.0 \
  -n "$NS" \
  -f <YOUR_VALUES>.yaml \
  --dry-run
```

Review the dry-run, then drop `--dry-run`.

> If you layer an overlay on top of a base values file, the **last** `-f` wins. Pass the
> base first and the overlay after it.

---

## 6. Verify

```bash
helm list -n "$NS" -o json | jq -r '.[] | select(.name=="'"$REL"'") | .chart'
# expect: dataplane-2026.8.0

kubectl get pods -n "$NS" --field-selector=status.phase!=Running
# expect: no resources found

kubectl get deploy -n "$NS" -o json \
  | jq -r '.items[] | select(.status.readyReplicas != .status.replicas) | .metadata.name'
# expect: no output
```

**Confirm the executor is gone.** These five objects are removed by this release:

```bash
kubectl get deploy,svc,cm,sa -n "$NS" | grep -i executor
# expect: no output
```

| Removed | Kind |
|---|---|
| `executor` | Deployment |
| `executor` | ConfigMap |
| `union-operator-executor` | Service |
| `union-executor` | ClusterRole or Role |
| `union-executor` | ClusterRoleBinding or RoleBinding |

The RBAC objects are cluster-scoped on a standard install and namespace-scoped in
low-privilege mode. No new objects are added.

**Check your own monitoring for references to what was removed.** The executor Service was
a scrape target; anything pointed at it now has a dead target. The metric
`union:dp:executor:active_actions` is replaced by `union:dp:leaseworker:active_actions`.
Update dashboards and alerts that use the old name.

**If you migrated task-log links**, run a workflow and confirm your custom links appear on
the task in the UI. This is the check that catches a mis-nested `leaseworker.task_logs`.

Finally, run one workflow end to end and confirm it reaches success.

---

## 7. Rollback

```bash
helm rollback "$REL" -n "$NS"
kubectl get pods -n "$NS" -w
```

Safe on this hop — no CRD changes, no schema migrations, no persistent state changes. The
executor Deployment is recreated on rollback.

The one thing `helm rollback` does not undo is the fluentbit ServiceAccount rename's
external side: if you repointed a cloud IAM binding to `union-system`, point it back.

---

## Also in this release

No action required for any of these.

- **`global.UNION_CONTROL_PLANE_HOST` and the top-level `host` are deprecated** in favor of
  `global.CONTROLPLANE_HOST`. All three still work. Precedence is `global.CONTROLPLANE_HOST`,
  then `host`, then `global.UNION_CONTROL_PLANE_HOST`. They will be removed in a future
  release — migrating now costs one line.
- **`taskPodTemplate.workingDir`** sets the working directory for task pods directly, rather
  than requiring you to override the whole pod template to change one field. Useful for
  images with a read-only root filesystem.
- **The embedded-secret init container image is now documented as overridable** under
  `config.core.webhook.embeddedSecretManagerConfig.fileMountInitContainer.image`. Its
  upstream default lives on a public registry that air-gapped clusters cannot reach.
  Comment-only change; nothing renders differently.
- **`config.operator.billableUsageCollector.enabled` is removed.** It had no effect.
  Billing is controlled by `config.operator.billing.model`.
- **Removed dead keys**: `prometheus.prometheusOperator` (targeted a key the upstream
  Prometheus chart does not have) and empty `flytepropeller` stubs.

---

## If something does not match

Open an issue on `unionai/helm-charts`, or contact Union support with your chart version,
the output of the verification commands above, and the relevant pod logs.
