# Third-party subchart RBAC

What each dependency subchart is allowed to read, and why.

## The rule

`low_privilege: true` — the chart default — keeps everything inside one namespace.
Prometheus and kube-state-metrics get namespaced Roles and lose the metrics that only exist
cluster-wide: no Task-Level Monitoring, no `kube_node_*`, less accurate cost data. The full
list is on the `low_privilege` key in `values.yaml`.

`low_privilege: false` trades that back: the observability components may read cluster-wide.
Read only — never writes, never secrets, and never a rule that isn't backed by a metric or
feature actually in use.

Set the flag; there is nothing else to set.

## Why we write prometheus and kube-state-metrics RBAC ourselves

Helm values are static, so a subchart can't see `low_privilege`. Leaving RBAC to those two
subcharts would mean a second values file that has to move with the flag every time, and
forgetting it fails quietly. So both are pinned to `rbac.create: false` and
`templates/prometheus/rbac.yaml` writes the grant instead — a template can branch, a value
can't. `templates/prometheus/validate.yaml` stops the render if either subchart's RBAC is
switched back on.

The kube-state-metrics rules come from the `collectors` list rather than being hardcoded,
so a new collector can't end up unauthorized — an unmapped one fails the render.

### The one thing the flag can't reach

`collectors` becomes `--resources` on the kube-state-metrics Deployment, which the subchart
renders, so it's the same list in both modes. Under `low_privilege`, `nodes` and
`namespaces` are asked for but not granted.

That's survivable, and measured on a live cluster: kube-state-metrics stays ready with no
restarts, health checks and `/metrics` return 200, and the other four collectors work
normally. The denied pair shows up as an error counter on the telemetry port (which this
chart doesn't scrape) and as about 6 log lines a minute, permanently. That noise is the
price of keeping this to one flag.

## What each subchart gets

| Subchart | Default | `low_privilege: true` | `low_privilege: false` |
|---|---|---|---|
| prometheus | on | namespaced Role (ours) | ClusterRole (ours) |
| kube-state-metrics | on | namespaced Role, 4 of 6 collectors | ClusterRole, all 6 |
| fluent-bit | on (off on GCP) | none | none |
| dcgm-exporter | off | none | none |
| ingress-nginx | off | namespaced Role | namespaced Role |
| metrics-server | off | cluster read + `kube-system` write | same |

Out of scope: the vendored Knative Serving / Kourier gateway under `templates/gateway/`
(our own manifests, not subchart config), and the deprecated knative-operator.

## Notes

**prometheus.** Read-only on services, endpoints, pods, ingresses, configmaps and
endpointslices, plus nodes and the node metrics endpoints at `low_privilege: false`. No
secrets and no writes, either way.

Cluster-scoped resources are dropped from the namespaced Role rather than carried over.
Naming them there is legal but never matches, which is how `kubernetes-cadvisor` spent three
months returning 403s. For the same reason that scrape job isn't rendered under
`low_privilege`: it needs cluster-wide node discovery, and it's the only source of
`container_cpu_usage_seconds_total` and `container_memory_working_set_bytes`. Those panels
read "no data" in low-privilege mode, by design.

Verified on a live cluster: with only the namespaced Role, prometheus finds and scrapes
every target in its own namespace — 4/4 up, no RBAC errors.

At `low_privilege: false` the ClusterRole name is a fixed string, so **one dataplane per
cluster** is the supported model. A second install in another namespace fails on Helm
ownership rather than quietly taking over the first release's binding.

**kube-state-metrics.** Six collectors out of 28 (`pods`, `deployments`, `daemonsets`,
`resourcequotas`, `nodes`, `namespaces`), list/watch only, chosen to match the series the
control plane's metrics gateway accepts. Dropping the other 22 also drops `secrets`.

Under `low_privilege` the last two aren't granted, costing `kube_node_*` and
`kube_namespace_labels`. The latter is the join key for most pod-level aggregates, so
pod-level dashboards degrade rather than simply losing node panels.

The binding names kube-state-metrics' real ServiceAccount, worked out from the subchart's
own naming rules. The hand-written binding it replaced named one that didn't exist, for
every release name, and produced no `kube_*` metrics for three months.

`releaseNamespace: true` limits collection to the release namespace in both modes. Under
`low_privilege` that's the work namespace, so it covers everything; at `low_privilege:
false` task pods live elsewhere and aren't collected.

Don't add `metricRelabelings` here — nothing in the dependency tree reads it. The filter
that actually runs is the scrape job's `metric_relabel_configs` in
`prometheus.extraScrapeConfigs`.

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
`templates/ingress-nginx/validate.yaml` catches the reverse, which is otherwise silent.

**metrics-server.** Left as-is; it's cluster-scoped by design. It needs an APIService, the
`system:auth-delegator` binding, and a RoleBinding in `kube-system` that can't be
overridden — so an operator confined to the release namespace gets a hard 403 from `helm
upgrade`. `rbac.create: false` leaves it unable to authenticate at all. It also grants
`configmaps` and `namespaces` beyond upstream's own v0.7.2 manifest; narrowing that would
mean forking the subchart.
