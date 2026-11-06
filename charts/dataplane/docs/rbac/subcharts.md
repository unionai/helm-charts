# Third-party subchart RBAC

This page lists what each dependency subchart is allowed to read, and why. For app serving,
which is not a subchart, see [app-serving.md](app-serving.md).

Prometheus holds the same grant in either mode. kube-state-metrics' grant follows the
namespaces it collects from. `singleNamespace: true` holds those to the release namespace,
and `singleNamespace: false` lets you widen them ([below](#what-the-flag-cant-reach)).
Neither writes, and neither reads secrets.

## Why we write prometheus and kube-state-metrics RBAC ourselves

The subcharts' own RBAC grants their upstream discovery profile, which is cluster-wide reads
of pods, services, endpoints, configmaps and every kube-state-metrics resource, whatever the
chart's scrape jobs use. So both subcharts are pinned to `rbac.create: false`.
`templates/prometheus/rbac.yaml` writes the grant instead, holding each to what this chart's
configuration asks for, the same in either scope mode. `templates/prometheus/validate.yaml`
stops the render if either subchart's RBAC is switched back on.

The kube-state-metrics rules come from the `collectors` list, so every collector in the list
has a rule. The render fails on a collector the chart has no mapping for.

### What the flag can't reach

Two kube-state-metrics values become command-line flags on its Deployment. The subchart
renders the Deployment, so none of this chart's templates can branch on them:

- **`collectors`** becomes `--resources`, which sets what kube-state-metrics asks the API
  server for.
- **`namespaces` and `releaseNamespace`** become `--namespaces`, which sets the namespaces it
  asks about. That is the named ones plus the release namespace when `releaseNamespace` is
  set, with duplicates removed. When both are empty the subchart drops the flag, and
  kube-state-metrics reads every namespace.

The defaults are six collectors, with the namespaced ones collecting in the release
namespace only, in either mode. The chart reads both values and grants exactly what they ask
for. That is a Role in each named namespace, or a ClusterRole when kube-state-metrics reads
every namespace. `singleNamespace: true` refuses any namespace other than the release
namespace. The cluster-scoped collectors, `nodes` and `namespaces`, get their own read-only
cluster role in either mode, so the six match what the managed dataplanes collect.

`examples/values.full-privilege.yaml` drops `--namespaces` so that task pods in project
namespaces are collected too, and the grant widens to a ClusterRole with it. Without that
file, `singleNamespace: false` still collects namespaced resources only in the release
namespace. Task pod utilization does not depend on this, because `container_*` comes from the
cadvisor job, which is node-scoped and namespace-blind. Pod requests and limits do depend on
it.

## What each subchart gets

| Subchart | Default | `singleNamespace: true` | `singleNamespace: false` |
|---|---|---|---|
| prometheus | on | namespaced Roles for discovery, plus a read-only cluster role for nodes, the kubelet proxy and `/metrics` (ours) | same |
| kube-state-metrics | on | a Role where it collects namespaced resources, plus a read-only cluster role for `nodes` and `namespaces`; 6 collectors | same; a ClusterRole for the namespaced collectors when it collects every namespace |
| fluent-bit | on (off on GCP) | none | none |
| dcgm-exporter | off | none | none |
| ingress-nginx | off | namespaced Role + IngressClass ClusterRole | same |
| opencost | off | cluster-wide read | same |
| metrics-server | off | cluster read + `kube-system` write | same |

Only the first two follow `singleNamespace`. The rest are fixed in either mode.

The deprecated knative-operator and kube-prometheus-stack subcharts are out of scope here.

## Per-subchart notes

### prometheus

The grant is the same in either mode and read-only, and it is exactly what
the scrape jobs discover:

- `list` and `watch` on endpoints, services and pods in the release namespace
  (`union-operator-prometheus-rbac`)
- `list` and `watch` on endpoints in `default`, for the API server
  (`<ns>-prometheus-apiserver-discovery`)
- in `<ns>-prometheus-cluster-read`:
  - `list` and `watch` on nodes for cadvisor discovery
  - `get` on `nodes/proxy` to reach the kubelet through the API server
  - `get` on `/metrics` for the API server

It never reads secrets or configmaps and never writes.

A namespaced Role cannot carry a cluster-scoped resource. Naming one there is legal but never
matches, which is how `kubernetes-cadvisor` returned 403 responses for three months. The node reads
live in the cluster role instead, so the cadvisor job runs in both modes, as does the API
server job. The cadvisor job is the only source of `container_cpu_usage_seconds_total` and
`container_memory_working_set_bytes`.

The cluster-scoped names carry the release namespace, so two dataplanes in one cluster get
separate objects.

A job added under `prometheus.extraScrapeConfigs` that discovers outside the release
namespace, or outside `default` for endpoints, is not covered. That is because Helm cannot parse it
to work out what it needs. Grant its discovery reads yourself, in that namespace.

### kube-state-metrics

By default it runs six of its 28 collectors, read-only with `list`
and `watch`. The six are `namespaces`, `nodes`, `pods`, `deployments`, `daemonsets` and
`resourcequotas`. They are the set the managed dataplanes collect and the series the control
plane's metrics gateway accepts. Dropping the other 22 also drops `secrets`. Omitting `nodes`
and `namespaces` costs `kube_node_*` and `kube_namespace_labels`. The latter is the join key
for most pod-level aggregates, so pod-level dashboards degrade instead of only losing node
panels.

The binding names kube-state-metrics' real ServiceAccount, derived from the subchart's own
naming rules for every release name.

Don't add `metricRelabelings` here, because nothing in the dependency tree reads it. The
filter that runs is the scrape job's `metric_relabel_configs` in
`prometheus.extraScrapeConfigs`.

Because both subcharts are pinned to `rbac.create: false`, the RBAC half of their own
features never renders, and `rbac.extraRules` is dropped. `kubeRBACProxy`,
`customResourceState` and `autosharding` would fare worse. The feature would still render, as
a proxy sidecar, custom-resource config or sharded StatefulSet. The permissions it needs
would be missing, namely token and subject-access-review `create`, the configured CRD reads,
and pod and statefulset reads.

All four are unsupported, and `templates/prometheus/validate.yaml` refuses each at render
time, naming what it needs. Without the refusal each would deploy a kube-state-metrics that
starts, stays ready, and returns none of the series you asked for. `$ksmRules` in `templates/prometheus/rbac.yaml` maps one collector to one apiGroup/resource
pair at `list, watch`, so it cannot express arbitrary `extraRules`, or `create` on
tokenreviews and subjectaccessreviews. `kubeRBACProxy` also serves authenticated HTTPS, which
the chart's kube-state-metrics scrape job, using plain HTTP without a bearer token, could no
longer reach. Supporting any of them means extending `rbac.yaml` and the scrape config
together.

### fluent-bit

fluent-bit calls the Kubernetes API nowhere in this chart. The subchart's
cluster-wide read on namespaces and pods serves a `kubernetes` filter, and this chart
configures none. Pod, namespace and container names come from the log file path, which is
the object key.

Three keys change this: `fluentbit.additionalFilters`, when you paste in a `kubernetes`
filter, `fluentbit.rbac.nodeAccess` and `fluentbit.rbac.eventsAccess`. Setting any of them
also requires setting `fluentbit.rbac.create: true` by hand, because nothing derives it.
Set on their own, the last two render nothing, and the `kubernetes` filter then runs
unauthorized.

### dcgm-exporter

dcgm-exporter uses no Kubernetes API. GPU-to-pod mapping reads the kubelet
podresources socket and the metrics CSV is a volume mount, so the pod does not mount a
service account token.

Three keys change that, and each grants cluster-wide read on pods and resourceslices. They
are `kubernetes.enablePodLabels`, `kubernetes.enablePodUID` and `kubernetesDRA.enabled`.
Setting `kubernetes.rbac.create: false` covers only the first two, because
`kubernetesDRA.enabled` grants the ClusterRole regardless.

Prometheus looks for dcgm-exporter in the release namespace, where the subchart deploys it,
so an instance managed elsewhere, such as by the NVIDIA GPU operator, is not scraped.

### ingress-nginx

The controller is confined to the release namespace in both modes, which
is where all of this chart's endpoints live. Unscoped, it reads secrets, configmaps, pods,
endpoints and nodes across the whole cluster. It reads secrets because TLS certificates can
be referenced from an Ingress anywhere. Scoped, that becomes a namespaced Role. The only
cluster-scoped object left is the IngressClass, which has no namespaced form.

The controller ignores an Ingress outside the release namespace and logs no error or
warning. To serve one from another namespace, set both `rbac.scope` and
`controller.scope.enabled` back to `false`. They must move together. The subchart errors on
`rbac.scope` alone, and `templates/ingress-nginx/validate.yaml` catches the reverse, which is
otherwise silent. That check applies only when the subchart creates the controller's RBAC.
At `rbac.create: false` the subchart renders no controller Role or ClusterRole, and the
scope of whatever you supply is yours to get right. The admission-webhook patch job carries
its own RBAC under `controller.admissionWebhooks.patch.rbac.create`. That key is off by
default here and does not affect what the controller can read.

Those checks read the scope values. `controller.extraArgs.watch-namespace` also reaches
`--watch-namespace`, appended after the scope-derived one, so it wins, and no check inspects
it. Under scoped RBAC it leaves the controller silently not reconciling Ingresses, which is
what the guard exists to prevent. As with `rbac.create: false` above, you keep a raw
passthrough consistent yourself. Use `controller.scope.namespace`, which is checked.

### opencost

opencost holds cluster-wide `get`, `list` and `watch` whenever it is enabled, in
either scope mode. It prices the whole cluster, so a namespaced grant would leave it nothing
to price, and the subchart offers no key to narrow it. `singleNamespace` does not govern it.
`tests/values/dataplane.opencost.yaml` pins the grant, so a subchart bump that widens it
shows up in review.

### metrics-server

The chart leaves it as-is, because it is cluster-scoped by design. It
needs an APIService, the `system:auth-delegator` binding and a RoleBinding in `kube-system`,
and the RoleBinding cannot be overridden. An install identity confined to the release
namespace therefore gets a 403 from `helm upgrade`. `rbac.create: false` leaves it unable to
authenticate. The subchart also grants `configmaps` and `namespaces` beyond upstream's own
v0.7.2 manifest, and narrowing that would mean forking it.
