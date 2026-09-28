# Third-party subchart RBAC

What each dependency subchart is allowed to read, and why. [App serving](#app-serving) is
here too — it isn't a subchart, but it's the one component the flag governs by refusing to
render at all.

For Union's own components — the slot model, the work-namespace bindings and the identity
axis — see [rbac-union.md](rbac-union.md). Two points about them are covered here as well,
because they decide what either scope mode is worth: [the work-ns
wildcard](#the-work-ns-wildcard), and [plugin CRD reads at `singleNamespace:
false`](#plugin-crd-reads-at-singlenamespace-false).

## The work-ns wildcard

The pooled `<release-ns>-work-ns` role grants `apiGroups: ['*']`, `resources: ['*']` with
every verb except `deletecollection`. That is deliberate, and it is not the security
boundary.

Any identity that can create a pod in a namespace is already admin of that namespace. The
pod can name any ServiceAccount there and mount any Secret there, so it acts with every
permission those identities hold. Union's components have to create task pods in every work
namespace, so they have that power whatever the rest of the rule list says. Narrowing
work-ns to named resources would make the role harder to read without making it safer.

The boundary is in two other places:

- **Where work-ns is bound.** At `singleNamespace: false` it is bound only in the work
  namespaces, by a RoleBinding the chart or `clusterresourcesync` writes in each one. It is
  never bound in the release namespace, where Union's own Deployments and Secrets live, and
  the chart refuses a `namespaces.static` that lists it. What a component needs in the
  release namespace comes from its own `comp-ns-read` and `comp-ns-write` Roles.
- **The cluster-scoped grants.** These are listed rule by rule in
  [rbac-union.md](rbac-union.md#the-cluster-scoped-write-surface), and in single-namespace
  mode they are held to the allowlist below.

The chart enforces that the all-groups wildcard stays in work-ns: `dataplane.rbac.emitSlot`
refuses `apiGroups: ['*']` in every other slot, and `tests/test-rbac-guards.sh` checks every
rendered role. A resource wildcard inside a named group is allowed outside work-ns only for
the Knative controllers' reads of their own API groups.

**Under `singleNamespace: true` the release namespace is the work namespace.** work-ns is a
Role bound there, so the wildcard applies to Union's own objects too, and any component
bound to it can read Union's own Secrets and change its Deployments. That blast radius is
accepted as the cost of running in one namespace. Use `singleNamespace: false` if the
components that launch tasks must not be able to reach Union's own Secrets and Deployments.

## Plugin CRD reads at `singleNamespace: false`

At `singleNamespace: false` no limit namespace is set, so a CRD-backed task plugin's
informer watches its resource across every namespace. work-ns covers the plugin's calls
inside each work namespace, but a watch across all namespaces is authorized at cluster
scope, which no RoleBinding can grant. List the plugins' CRDs in
`taskPluginClusterReadRules`, and each entry is granted `list` and `watch` cluster-wide to
leaseworker and, when it is enabled, flytepropeller:

```yaml
taskPluginClusterReadRules:
  - apiGroups: [sparkoperator.k8s.io]         # spark
    resources: [sparkapplications]
  - apiGroups: [ray.io]                        # ray, and fastray's idle-cluster reaper
    resources: [rayjobs, rayclusters]
  - apiGroups: [kubernetes.dask.org]           # dask
    resources: [daskjobs]
  - apiGroups: [kubeflow.org]                  # kubeflow
    resources: [pytorchjobs, tfjobs, mpijobs]
  - apiGroups: [jobset.x-k8s.io]               # clustered-task
    resources: [jobsets]
```

The chart does not derive this list from `enabled_plugins`, because it cannot see which
CRDs are installed or what a plugin outside the stock set watches. A wildcard in any field
fails the render, as does any verb other than `get`, `list` or `watch`. So does a built-in
group: the key is for CRDs, and a cluster-wide read of the core group would reach every
Secret. The core group `""`, every group without a dot (a CRD's group always has one), and
`rbac.authorization.k8s.io` and `certificates.k8s.io` are refused. The plugins'
writes (create, delete, patch) stay in work-ns.

Under `singleNamespace: true` the key renders nothing. Plugin informers are confined to the
release namespace there, which work-ns covers, so the key never adds to the single-namespace
allowlist.

## The rule

`singleNamespace: true` — the chart default — runs Union in the release namespace and
confines the observability components to it. Prometheus and kube-state-metrics get
namespaced Roles and lose the metrics that only exist cluster-wide: no Task-Level
Monitoring, no `kube_node_*`, less accurate cost data. The full list is on the
`singleNamespace` key in `values.yaml`. `low_privilege` is the key's older name and still
works as an alias.

`singleNamespace: false` trades that back: the observability components may read
cluster-wide, never write, and never touch secrets.

The flag is not a whole-chart namespace boundary. It scopes Union-authored workload RBAC
along with these two subcharts, and gates [app serving](#app-serving), namespace creation and
priorityclasses — but a short list of cluster-scoped reads remains in single-namespace mode
([below](#what-singlenamespace-still-reads-cluster-wide)), the Helm hook cleanup job creates
a ClusterRole in either mode, and opencost and metrics-server are cluster-scoped when
enabled. See the table below, and the README's RBAC section for what that means for your
install identity.

The flag decides RBAC by itself. It can't decide how much kube-state-metrics collects with
that access — layer `examples/values.full-privilege.yaml` for that, below.

## What singleNamespace still reads cluster-wide

Single-namespace mode is a promise about scope, not a promise of zero cluster-scoped access.
Some reads have no namespaced form, and the chart grants them rather than switch off the
feature that needs them. The list is fixed: `tests/test-rbac-guards.sh` renders every
single-namespace fixture, plus two renders with every optional component on, and fails if a
ClusterRole bound by a ClusterRoleBinding grants anything not on it.

| ClusterRole | Grant | When | Why |
|---|---|---|---|
| `<ns>-operator-cluster-read` | `nodes` list, watch | on by default | The operator's node informer (`operator/cmd/root.go`). It runs unless `config.operator.disableClusterPermissions` is set, whenever any usage collector does, and startup blocks until it syncs. It backs the Legacy/Shadow billing collector and attributes a GPU to the node's accelerator label when the pod spec names none. Nodes are cluster-scoped, so `limitNamespace` cannot confine it. |
| `<ns>-nodeobserver-cluster-read` | `nodes` get, `pods` list | `nodeobserver.enabled` | nodeobserver reads the node it runs on, and lists that node's pods with an empty namespace and a `spec.nodeName` field selector — a cluster-scope request. |
| `dataplane-nginx-ingressclass` | `ingressclasses` get, list, watch | `ingress-nginx.enabled` | A scoped ingress-nginx controller still reads IngressClass, which is cluster-scoped; without it the controller ignores every Ingress this chart renders. |
| `flyte-webhook-cleanup-<ns>` | `mutatingwebhookconfigurations` get, delete, on `flyte-pod-webhook` only | pre-upgrade hook | Deletes the webhook configuration chart versions before 2026.4.7 left behind. |

Writes are held to a stricter rule: a cluster-scoped write must be pinned to named objects.
The cleanup hook's `delete` above is the only pinned write. nodeobserver's `nodes` `update` —
it removes its startup taint from the node it runs on — is the one unpinned exception, since
node names are not known at render time; it is off by default.

Some things single-namespace mode still withholds, because they are not on the list: the
operator's `/metrics` scrape of the API server, which feeds its FlyteWorkflow-count and
etcd-size throttles (they stay off); prometheus' node and cadvisor discovery; and the
leaseworker's Kubernetes event watcher, which watches `events.k8s.io` events in every
namespace even when a limit namespace is set. Until the leaseworker scopes that informer,
task status in this mode is not enriched with Kubernetes events.

`taskPluginClusterReadRules` never adds to this list: its entries are emitted only at
`singleNamespace: false`.

The operator used to avoid the nodes read by forcing `disableClusterPermissions` on and
`collectUsages` off in this mode. It no longer does: both follow their own values. The
operator confines its pod and pod-metrics reads to `limitNamespace` itself
(`usageNamespace` in `operator/cmd/root.go`), so usage collection needs nothing
cluster-wide beyond the nodes read.

Third-party subcharts that ship their own RBAC — kube-prometheus-stack (`monitoring`),
metrics-server, opencost, knative-operator, ingress-nginx's own controller RBAC,
dcgm-exporter and fluent-bit — are outside this list. `singleNamespace` does not govern
them, and all are off by default except fluent-bit, which renders no RBAC here.

## Why we write prometheus and kube-state-metrics RBAC ourselves

Helm values are static, so a subchart can't see `singleNamespace`. Leaving RBAC to those two
subcharts would mean a second values file that has to move with the flag every time, with
nothing at render time to catch it falling out of sync. So both are pinned to `rbac.create: false` and
`templates/prometheus/rbac.yaml` writes the grant instead — a template can branch, a value
can't. `templates/prometheus/validate.yaml` stops the render if either subchart's RBAC is
switched back on.

The kube-state-metrics rules come from the `collectors` list rather than being hardcoded,
so a new collector can't end up unauthorized — an unmapped one fails the render.

### What the flag can't reach

Two kube-state-metrics values become flags on its Deployment, which the subchart renders,
so no template of ours can branch on them:

- **`collectors`** → `--resources`. What it asks the API server for.
- **`namespaces` + `releaseNamespace`** → `--namespaces`. Which namespaces it asks about: the
  named ones, plus the release namespace when `releaseNamespace` is set, deduped. When both
  are empty the flag is dropped entirely, which the subchart reads as *every* namespace.

The defaults are set for the namespaced install, so nothing is requested that can't be
granted: four collectors, release namespace only. Asking for more without the grant doesn't
fail loudly — kube-state-metrics keeps running and logs the denial every few seconds for the
life of the pod. `templates/prometheus/rbac.yaml` refuses to render a cluster-scoped
collector under `singleNamespace` rather than let that start.

`examples/values.full-privilege.yaml` is the other half of `singleNamespace: false`: it adds
the `nodes` and `namespaces` collectors and drops `--namespaces`, so `kube_node_*`,
`kube_namespace_labels` and task pods in project namespaces are all collected. Without it,
`singleNamespace: false` grants the cluster-wide read but still collects like a namespaced
install. Task pod *utilization* doesn't depend on this — `container_*` comes from the
cadvisor job, which is node-scoped and namespace-blind — but requests and limits do.

## What each subchart gets

| Subchart | Default | `singleNamespace: true` | `singleNamespace: false` |
|---|---|---|---|
| prometheus | on | namespaced Role (ours) | ClusterRole (ours) |
| kube-state-metrics | on | namespaced Role, 4 collectors | ClusterRole, 6 with the overlay |
| fluent-bit | on (off on GCP) | none | none |
| dcgm-exporter | off | none | none |
| ingress-nginx | off | namespaced Role + IngressClass ClusterRole | same |
| opencost | off | cluster-wide read | same |
| metrics-server | off | cluster read + `kube-system` write | same |

Only the first two follow the flag. The rest are fixed in either mode.

Out of scope: the deprecated knative-operator and kube-prometheus-stack subcharts.

## App serving

App serving is off by default and requires `singleNamespace: false`.
`templates/gateway/validate.yaml` refuses `apps.enabled: true` alongside `singleNamespace: true`,
naming both exits. Since `singleNamespace` defaults on, `apps.enabled` defaults off — so the
default install is self-consistent and never meets the refusal.

The refusal covers the vendored delivery path — `serving.useVendoredGateway`, i.e.
`apps.enabled` with `gateway.enabled` (the default) — not zero trust specifically. The
vendored Knative stack renders whenever app serving is on and delivered by this chart,
whether or not zero trust is. The deprecated `knative-operator` path (`gateway.enabled:
false`) is out of scope here, as it is everywhere else in this document.

That default lives in the `apps.enabled` helper's missing final branch, not in `values.yaml`.
Writing `apps.enabled: false` there would make the key *set*, and precedence is
`apps.enabled > serving.enabled > false` — so the deprecated `serving.enabled` would stop
being consulted and every install still using it would lose app serving while explicitly
asking for it. `tests/values/dataplane.aws.zero-trust-serving-enabled.yaml` is the golden that
catches that.

It is the one component the flag governs by refusing outright rather than by narrowing a
grant. That is no longer because the grant is unwritable — app serving's RBAC is declared per
binary through this chart's slot framework, like every other component's, and every grant that
can be namespaced is. It is because of what the *images* do:

- **No watch scope.** The deployments take `SYSTEM_NAMESPACE` (where Knative's own config
  lives) and nothing else; upstream ships no namespace-scoped install, and the binaries take
  the shared, unfiltered informers from `knative.dev/pkg` without scoping them to a namespace.
  Those reads go out with an empty namespace, which Kubernetes authorizes as a cluster-scope
  check. Each binary holds only the subset it uses — the webhook watches the two
  webhook-configuration kinds and nothing else, the activator watches Services, Endpoints and
  Revisions, the autoscaler adds Pods, Deployments, leases and HPAs — but **every one of those
  subsets is cluster-scoped**, `net-kourier` adding Ingresses. A namespaced Role
  authorizes none of it, and would leave controller, webhook and activator Ready and denied:
  the same silent shape the prometheus and kube-state-metrics guards exist to prevent, with no
  values key to guard on.

So app serving reads every namespace in the cluster, which `singleNamespace: true` promises
Union's workloads do not: its cluster-scoped reads are a fixed list, and Knative's are not
on it. The webhook configurations make that concrete from the other
direction: every rule is `scope: "*"` with no `namespaceSelector`, so admission intercepts
cluster-wide regardless of what RBAC says.

The refusal is the whole of what the flag does here; it does not shape the grants. What each
binary holds is the same in the only posture it renders in. See the release notes for the
per-component breakdown.

**Why it refuses rather than just dropping the stack.** Silently rendering nothing would be
the cheaper change, and it would be wrong in a familiar way: `apps.enabled` would still be
true with no backend behind it, so the operator would keep advertising app serving and keep
its (namespaced) `serving.knative.dev` grant, and every Knative Service it created would sit
unreconciled with nothing reporting why. Refusing keeps `apps.enabled` meaning one thing, so
the operator's config and Role stay correct by construction rather than by a second helper
that has to be kept in step.

**What `apps.enabled: false` keeps.** The Envoy gateway, dataproxy and tunnel-service ingress
gate on `serving.renderGateway` — `gateway.enabled` with either app serving or zero trust —
so under zero trust they survive `apps.enabled: false` on their own. They hold no
cluster-scoped RBAC, and their static dataplane routes are what zero trust is. So the choice
the guard forces is app serving vs. `singleNamespace`, never zero trust vs. `singleNamespace`.

`tests/values/dataplane.aws.zero-trust{,-overrides,-serving-enabled}.yaml` turn app serving on
and so pin `low_privilege: false`, the alias; `-apps-disabled` leaves scope at the default,
which is what makes it prove `apps.enabled` beats `serving.enabled` — a regression reading it
as true would hit this guard and fail the render rather than quietly matching.
`tests/test-rbac-guards.sh` asserts the refusal itself, which no golden can.

## Notes

**prometheus.** Read-only on services, endpoints, pods, ingresses, configmaps and
endpointslices, plus nodes and the node metrics endpoints at `singleNamespace: false`. It never
reads secrets and never writes, either way.

Cluster-scoped resources are dropped from the namespaced Role rather than carried over.
Naming them there is legal but never matches, which is how `kubernetes-cadvisor` spent three
months returning 403s. For the same reason that scrape job isn't rendered under
`singleNamespace`: it needs cluster-wide node discovery, and it's the only source of
`container_cpu_usage_seconds_total` and `container_memory_working_set_bytes`. Those panels
read "no data" in single-namespace mode, by design.

Verified on a live cluster: with only the namespaced Role, prometheus finds and scrapes
every target in its own namespace — 4/4 up, no RBAC errors.

At `singleNamespace: false` the ClusterRole name is a fixed string, so **one dataplane per
cluster** is the supported model. Nothing enforces it: `helm install` refuses a second
release on ownership, but ArgoCD — the deployment path this chart is built for — applies
shared resources unless the Application sets `FailOnSharedResource=true`. There, the later
sync can rewrite the binding subject to its own namespace without blocking — surfacing at
most a `SharedResourceWarning` condition — and the first release's prometheus stops being
authorized. Treat this as a constraint to respect, not one you'll reliably be stopped at.

The cluster-wide read at `singleNamespace: false` is wider than the rendered scrape jobs use —
every job but `kubernetes-cadvisor` discovers with `own_namespace: true`. That is deliberate.
`singleNamespace: false` is a choice of permission posture, not a permission set derived from
the jobs: Helm can't parse arbitrary `prometheus.extraScrapeConfigs` to work out what a job
added there will need, so the grant tracks the pinned subchart's own read-only discovery
profile instead. Concretely, it's what lets a job added there reach `prometheus.io/scrape`
targets outside the release namespace.

**kube-state-metrics.** Four collectors out of 28 by default (`pods`, `deployments`,
`daemonsets`, `resourcequotas`), list/watch only, chosen to match the series the control
plane's metrics gateway accepts. Dropping the other 24 also drops `secrets`. The
full-privilege overlay adds `nodes` and `namespaces`, which cost `kube_node_*` and
`kube_namespace_labels` when absent — the latter is the join key for most pod-level
aggregates, so pod-level dashboards degrade rather than simply losing node panels.

Grants are derived from whatever `collectors` names, so the two always match: an unmapped
collector fails the render, and so does a cluster-scoped one under `singleNamespace`. See
[What the flag can't reach](#what-the-flag-cant-reach) for the collection scope.

The binding names kube-state-metrics' real ServiceAccount, worked out from the subchart's
own naming rules. The hand-written binding it replaced named a ServiceAccount that didn't
exist, for every release name. No release collected `kube_*` metrics for three months
anywhere the chart's own RBAC ran — until now, that meant every single-namespace install.

Don't add `metricRelabelings` here — nothing in the dependency tree reads it. The filter
that actually runs is the scrape job's `metric_relabel_configs` in
`prometheus.extraScrapeConfigs`.

Because both subcharts are pinned to `rbac.create: false`, the RBAC half of their own
features never renders. `rbac.extraRules` is simply dropped. `kubeRBACProxy`,
`customResourceState` and `autosharding` are worse than dropped: the *feature* still renders
— proxy sidecar, custom-resource config, sharded StatefulSet — while the permissions it needs
(token/subject-access-review `create`, the configured CRD reads, pod/statefulset reads) do
not. You get a running component that cannot do its job, which is the same silent shape this
chart writes RBAC to avoid.

All four are unsupported, and none is a drop-in. `$ksmRules` in
`templates/prometheus/rbac.yaml` maps one collector to one apiGroup/resource pair at
`list, watch`, so it cannot express arbitrary `extraRules` or `create` on tokenreviews and
subjectaccessreviews. `kubeRBACProxy` additionally serves authenticated HTTPS, which the
chart's kube-state-metrics scrape job — plain HTTP, no bearer token — would no longer reach.
Supporting any of them means extending `rbac.yaml` and the scrape config together.

`templates/prometheus/validate.yaml` refuses all four at render time, naming what each one
would need. A failed render is the point: every one of them otherwise deploys a
kube-state-metrics that starts, stays ready, and returns nothing you asked it for.

**fluent-bit.** Never calls the Kubernetes API in this chart. The subchart's cluster-wide
read on namespaces and pods exists to serve a `kubernetes` filter, and this chart has never
configured one — pod, namespace and container names come from the log file path, and that
path *is* the object key.

Three keys reverse this: `fluentbit.additionalFilters` (if you paste in a `kubernetes`
filter), `fluentbit.rbac.nodeAccess`, `fluentbit.rbac.eventsAccess`. Setting any of them
means setting `fluentbit.rbac.create: true` by hand as well — nothing derives it, and on
their own the last two render nothing while the filter runs unauthorized.

**dcgm-exporter.** Doesn't use the API either: GPU-to-pod mapping reads the kubelet
podresources socket and the metrics CSV is a volume mount, so the pod doesn't even mount a
service account token.

Three keys change that, each granting cluster-wide read on pods and resourceslices:
`kubernetes.enablePodLabels`, `kubernetes.enablePodUID`, `kubernetesDRA.enabled`. Setting
`kubernetes.rbac.create: false` only covers the first two — `kubernetesDRA.enabled` grants
the ClusterRole regardless.

Prometheus looks for dcgm-exporter in the release namespace, where the subchart deploys it.
One managed elsewhere — by the NVIDIA GPU operator, say — isn't scraped.

**ingress-nginx.** Confined to the release namespace in both modes, which is where all of
this chart's endpoints live. Unscoped, the controller reads secrets, configmaps, pods,
endpoints and nodes across the whole cluster — secrets because TLS certificates can be
referenced from an Ingress anywhere. Scoped, that becomes a namespaced Role; the only
cluster-scoped object left is the IngressClass, which has no namespaced form.

An Ingress outside the release namespace is never reconciled, with no error and no warning.
To serve one from another namespace, set `rbac.scope` and `controller.scope.enabled` both
back to `false`. They must move together — the subchart errors on `rbac.scope` alone, and
`templates/ingress-nginx/validate.yaml` catches the reverse, which is otherwise silent. That
check only applies when the subchart is creating the controller's RBAC; at `rbac.create:
false` it renders no controller Role or ClusterRole, and the scope of whatever you supply is
yours to get right. (The admission-webhook patch job carries its own RBAC under
`controller.admissionWebhooks.patch.rbac.create` — off by default here, and unrelated to what
the controller can read.)

Those checks read the scope *values*. `controller.extraArgs.watch-namespace` also reaches
`--watch-namespace`, appended after the scope-derived one, so it wins — and nothing inspects
it. Under scoped RBAC that gets you the silent non-reconciliation the guard exists to
prevent. Like `rbac.create: false` above, a raw passthrough is yours to keep consistent; use
`controller.scope.namespace`, which is checked.

**opencost.** Cluster-wide `get`/`list`/`watch` whenever it's enabled, in either scope
mode — it prices the whole cluster, so a namespaced grant would give it nothing to price, and
the subchart offers no key to narrow it. `singleNamespace` does not reach it. `tests/values/
dataplane.opencost.yaml` pins the grant so a subchart bump that widens it shows up in review.

**metrics-server.** Left as-is; it's cluster-scoped by design. It needs an APIService, the
`system:auth-delegator` binding, and a RoleBinding in `kube-system` that can't be
overridden — so an operator confined to the release namespace gets a hard 403 from `helm
upgrade`. `rbac.create: false` leaves it unable to authenticate at all. It also grants
`configmaps` and `namespaces` beyond upstream's own v0.7.2 manifest; narrowing that would
mean forking the subchart.
