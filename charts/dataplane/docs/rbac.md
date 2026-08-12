# Third-party subchart RBAC

What each dependency subchart is allowed to hold, and why. Every disposition here is a
values key on the subchart, so the grant tracks the subchart across version bumps — with
one deliberate exception, `prometheus` and `kube-state-metrics`, explained below.

## The rule

`low_privilege: true` — the chart default — scopes the deployment to a single namespace
and avoids anything needing cluster-wide permissions. Third-party components follow:
`prometheus` and `kube-state-metrics` hold namespaced Roles in the release namespace and
lose the metrics that can only be collected cluster-wide. Those tradeoffs are listed on the
`low_privilege` key in `values.yaml`; the short version is no Task-Level Monitoring, no
`kube_node_*`, and reduced cost accuracy.

`low_privilege: false` trades that back: third-party observability components may hold
cluster-scoped **read**. They may never hold writes, `secrets`, or any rule that doesn't
trace to a metric or feature in use.

**The flag is the only thing you set.** Nothing has to be layered alongside it.

## Why prometheus and kube-state-metrics RBAC is authored here

Helm values are static, so a subchart value cannot be derived from `.Values.low_privilege`.
Leaving RBAC to those two subcharts would mean a second values file that has to be layered
in lockstep with the flag, and forgetting it fails in whichever direction you were not
paying attention to. So both subcharts are pinned to `rbac.create: false` permanently and
`templates/prometheus/rbac.yaml` renders the grant instead — a template can branch, a value
cannot. `templates/prometheus/validate.yaml` fails the render if either subchart's RBAC is
switched back on, which would add a second grant the flag no longer governs.

Kube-state-metrics rules are derived from the `collectors` list rather than hardcoded, so a
new collector cannot silently end up unauthorized — an unmapped one fails the render.

**One value still can't follow the flag: `collectors` itself.** It becomes `--resources` on
the kube-state-metrics Deployment, which the subchart renders, so it is the same list in
both modes. Under `low_privilege` the `nodes` and `namespaces` collectors are therefore
requested but not granted. Measured on a live cluster: KSM stays ready with no restarts,
`/livez` and `/readyz` return 200, `/metrics` returns 200 and serves the other four
collectors normally. The denied pair is reported two ways —

```
kube_state_metrics_list_total{resource="*v1.Node",result="error"} 10
```

— and a client-go reflector error in the logs, roughly 6 lines per minute, permanently.
That log volume is the accepted cost of a single flag. Note the counter is on KSM's
telemetry port, which this chart neither exposes on the Service nor admits through the
scrape job's keep-list, so it is visible in logs but not collected.

## Disposition

| Subchart | Default | Grant at `low_privilege: true` | Grant at `low_privilege: false` |
|---|---|---|---|
| prometheus | on | namespaced Role (chart-authored) | ClusterRole (chart-authored) |
| kube-state-metrics | on | namespaced Role, 4 of 6 collectors granted | ClusterRole, all 6 |
| fluent-bit | on (off on GCP) | none | none |
| dcgm-exporter | off | none | none |
| ingress-nginx | off | namespaced Role | namespaced Role |
| opencost | off | cluster read-only | cluster read-only |
| metrics-server | off | cluster read + `kube-system` write | same |
| kube-prometheus-stack | off | cluster-wide `secrets: '*'` | same |

The last three are accepted as-is in either mode — no values key narrows them without
breaking them, and all three are off by default.

Out of scope: the vendored Knative Serving / Kourier gateway under `templates/gateway/`
(union-authored manifests, not subchart config), and the deprecated knative-operator.

## Notes

**prometheus.** The rules are the subchart's own: `get`/`list`/`watch` on services,
endpoints, pods, ingresses, configmaps and endpointslices, plus — at `low_privilege: false`
only — nodes, nodes/proxy, nodes/metrics and `get` on the `/metrics` nonResourceURL. No
secrets, no writes, in either mode.

Cluster-scoped resources are dropped from the namespaced Role rather than carried over.
Naming them there is accepted by the API server and never matches, which is how
`kubernetes-cadvisor` spent three months returning `403`s. For the same reason the
`kubernetes-cadvisor` scrape job is not rendered under `low_privilege`: it discovers with
`role: node` and fetches through `/api/v1/nodes/<name>/proxy/metrics/cadvisor`, both
cluster-scoped, and it is the only source of `container_cpu_usage_seconds_total` and
`container_memory_working_set_bytes`. Those panels read "no data" in low-privilege mode, by
design.

Verified on a live cluster: with only the namespaced Role, prometheus discovers and scrapes
every own-namespace target — 4/4 `up`, zero RBAC errors in its log. `own_namespace` service
discovery needs nothing cluster-scoped.

At `low_privilege: false` the ClusterRole name is a fixed string, so **one dataplane per
cluster** is the supported model. A second install in another namespace fails on Helm
ownership rather than quietly adopting the first release's binding.

**kube-state-metrics.** Six of 28 collectors (`pods`, `deployments`, `daemonsets`,
`resourcequotas`, `nodes`, `namespaces`), `list`/`watch` only, chosen to match the series
the control plane's metrics gateway admits. Dropping the other 22 also drops `secrets`.

Under `low_privilege` the last two are not granted, costing `kube_node_*` and
`kube_namespace_labels` — the latter is the join key for most pod-level aggregates, so
pod-level dashboards degrade rather than simply losing node panels.

The binding always names KSM's own ServiceAccount, computed from the subchart's own naming
rules. The hand-written binding this replaced named one that did not exist, for every
release name, and produced no `kube_*` series for three months.

`releaseNamespace: true` scopes collection to the release namespace in both modes. Under
`low_privilege` that is the work namespace, so it covers everything; at
`low_privilege: false` task pods live elsewhere and are not collected.

Don't add `metricRelabelings` here — no chart in the dependency tree reads it. The filter
that runs is the scrape job's `metric_relabel_configs` in `prometheus.extraScrapeConfigs`.

**fluent-bit.** Never calls the Kubernetes API in this chart. The subchart's cluster-wide
read on namespaces and pods exists to serve a `[FILTER] Name kubernetes` stanza, and this
chart has never configured one: `existingConfigMap` replaces the subchart's config, and
the union config renders only `fluentbit.additionalFilters` (empty by default). Pod,
namespace and container names come from the log file path via the tail input's
`Tag_Regex`, and that tag *is* the object key through `s3_key_format` — the metadata is in
the path, not in the record.

Three keys reverse this, and any of them means `rbac.create` goes back to `true`:
`fluentbit.additionalFilters` (if you paste in a `kubernetes` filter),
`fluentbit.rbac.nodeAccess`, `fluentbit.rbac.eventsAccess`.

**dcgm-exporter.** GPU-to-pod mapping reads the kubelet podresources socket and the
metrics CSV is a volume mount, so the pod renders `automountServiceAccountToken: false`
and the namespaced Role it emits is inert twice over.

Three keys reverse that, each creating a cluster-wide ClusterRole over pods and
resourceslices and switching the ServiceAccount token back on:
`kubernetes.enablePodLabels`, `kubernetes.enablePodUID`, `kubernetesDRA.enabled`. Note
`kubernetes.rbac.create: false` is only a partial opt-out — it gates the first two, but
`kubernetesDRA.enabled` grants the ClusterRole outside that conjunct.

Prometheus discovers dcgm-exporter in the release namespace, which is where the subchart
deploys it. One managed elsewhere — by the NVIDIA GPU operator, say — isn't scraped.

**ingress-nginx.** Unscoped, the controller runs behind a ClusterRoleBinding granting
cluster-wide read on secrets, configmaps, pods, endpoints and nodes — secrets because TLS
certificates are referenced from Ingress objects anywhere in the cluster. Scoped, that
becomes a namespaced Role; the only cluster-scoped object left is the IngressClass, which
has no namespaced form.

The cost: an Ingress outside the release namespace is never reconciled, with no error and
no warning — the controller simply doesn't see it. Both Ingresses this chart creates are
release-namespace-pinned. To serve one from another namespace, set `rbac.scope` and
`controller.scope.enabled` both back to `false`.

Those two keys must always move together. The subchart errors on `rbac.scope` without
`controller.scope.enabled`; the reverse was the silent one — a controller confined by
`--watch-namespace` still holding the full cluster-wide grant — and
`templates/ingress-nginx/validate.yaml` closes it.

**opencost.** Accepted as-is. OpenCost prices the whole cluster, and nodes and
persistentvolumes are cluster-scoped. Read-only throughout. `rbac.enabled: false` is not a
clean off switch: it gates `clusterrolebinding.yaml` only, so the ClusterRole is still
created and left orphaned — inert, but present.

**metrics-server.** Accepted as-is; structurally cluster-scoped. It needs the APIService,
the `system:auth-delegator` ClusterRoleBinding, and a RoleBinding whose namespace is the
hardcoded literal `kube-system` with no override — so an operator confined to the release
namespace gets a hard 403 from `helm upgrade`. `rbac.create: false` leaves the component
unable to authenticate at all. The chart also grants `configmaps` and `namespaces` beyond
upstream's own v0.7.2 manifest; narrowing that would mean forking the subchart.

**kube-prometheus-stack.** Accepted risk. Its operator holds cluster-wide `secrets: '*'`,
`delete` and `deletecollection` included. `global.rbac.create: false` produces a failing
install with two of three cluster-wide Secret readers still standing, and
`prometheusOperator.enabled: false` removes the operator while leaving its Prometheus CR,
PrometheusRules and ServiceMonitors unreconciled. Accepted because the component is off in
every values layer and on its way out — the supported path is the standalone `prometheus`
subchart.
