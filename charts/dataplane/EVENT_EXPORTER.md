# Pod Event Exporter

The event exporter surfaces Kubernetes Events as Prometheus metrics so you can see them in
Grafana dashboards and trigger AlertManager alerts. This solves the most common "silent failure"
pattern: a Pod stuck in Pending or CrashLoopBackOff where container logs are empty but the
Pod's event stream (visible via `kubectl describe pod`) shows the real cause — a failed volume
mount, an image pull error, a scheduling failure, etc.

## How it works

Kubernetes writes a `v1/Event` object every time something notable happens to a resource.
These are the same events shown at the bottom of `kubectl describe pod <name>`:

```
Events:
  Type     Reason       Message
  ----     ------       -------
  Warning  FailedMount  MountVolume.SetUp failed for volume "data": ...
  Warning  BackOff      Back-off pulling image "..."
```

The exporter (`kubernetes-event-exporter`) opens a cluster-wide watch on all `v1/Event` objects
and increments the Prometheus counter `kubernetes_event_count` for each one. Prometheus scrapes
those counters; Grafana and AlertManager consume them.

## Enable

Add to your dataplane values:

```yaml
eventExporter:
  enabled: true
```

The Prometheus scrape job is added automatically when Union's static Prometheus is also enabled
(`prometheus.enabled: true`). If you run your own Prometheus stack, point it at the exporter
Service (see [Bring Your Own Prometheus](#bring-your-own-prometheus) below).

To also get the Grafana dashboard, enable dashboards alongside the exporter:

```yaml
eventExporter:
  enabled: true

monitoring:
  dashboards:
    enabled: true
```

This creates a `grafana_dashboard: "1"` ConfigMap that Grafana's sidecar auto-discovers and
loads as the **Union - Pod Events** dashboard.

## Metric reference

| Metric | Type | Description |
|--------|------|-------------|
| `kubernetes_event_count` | Counter | Incremented once per observed event |

Labels on `kubernetes_event_count`:

| Label | Example values | Notes |
|-------|---------------|-------|
| `namespace` | `user-project-dev` | Namespace of the affected resource |
| `reason` | `FailedMount`, `OOMKilling`, `BackOff`, `FailedScheduling` | Event reason field |
| `type` | `Warning`, `Normal` | Kubernetes event type |
| `involved_object_kind` | `Pod`, `Node`, `PersistentVolumeClaim` | Kind of the affected resource |
| `involved_object_name` | `my-task-pod-abc123` | Name of the affected resource |
| `source_component` | `kubelet`, `kube-scheduler` | Component that emitted the event |
| `name` | `my-task-pod-abc123.abc` | Event object name |

**Important:** `kubernetes_event_count` is a counter. Use `rate()` or `increase()` in queries,
not the raw value. Series are retained for `metricsTTL` (default 24h) after the last event.

**Important:** Kubernetes Events have a default TTL of 1 hour in most clusters. The exporter
captures events in real-time via a watch. If the exporter pod was not running when an event
fired, that event is not backfilled. For failures that keep retrying (e.g. `FailedMount` is
re-emitted on every kubelet retry), this is not a problem in practice.

## Common PromQL queries

**Warning events in the last hour by reason:**
```promql
sum by (reason)(increase(kubernetes_event_count{type="Warning"}[1h]))
```

**FailedMount events per pod:**
```promql
sum by (involved_object_name, namespace)(increase(kubernetes_event_count{reason="FailedMount"}[1h]))
```

**OOMKill rate:**
```promql
rate(kubernetes_event_count{reason="OOMKilling"}[5m])
```

**All Warning events for a specific namespace:**
```promql
sum by (reason, involved_object_name)(
  increase(kubernetes_event_count{type="Warning", namespace="my-project-dev"}[1h])
)
```

## AlertManager rules

These rules work with both the static Prometheus (`alerts.enabled: true`) and the
kube-prometheus-stack (`monitoring.enabled: true`). Add them to your alerting configuration:

**Volume mount failure alert:**
```yaml
- alert: PodFailedMount
  expr: |
    increase(kubernetes_event_count{reason="FailedMount"}[5m]) > 0
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Pod {{ $labels.involved_object_name }} failing to mount a volume"
    description: >
      Pod {{ $labels.involved_object_name }} in {{ $labels.namespace }} has
      generated FailedMount events. The pod is likely stuck in Pending.
      Check: kubectl describe pod {{ $labels.involved_object_name }} -n {{ $labels.namespace }}
```

**OOMKill alert:**
```yaml
- alert: PodOOMKilled
  expr: |
    increase(kubernetes_event_count{reason="OOMKilling"}[5m]) > 0
  labels:
    severity: warning
  annotations:
    summary: "Pod {{ $labels.involved_object_name }} OOM killed"
    description: >
      Pod {{ $labels.involved_object_name }} in {{ $labels.namespace }} was
      OOM killed. Consider increasing its memory limit.
```

**Image pull failure alert:**
```yaml
- alert: PodImagePullBackOff
  expr: |
    increase(kubernetes_event_count{reason=~"Failed|ErrImagePull|ImagePullBackOff"}[5m]) > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Pod {{ $labels.involved_object_name }} cannot pull its image"
```

## Grafana dashboard

When both `eventExporter.enabled: true` and `monitoring.dashboards.enabled: true`, the chart
deploys a **Union - Pod Events** dashboard ConfigMap with label `grafana_dashboard: "1"`.
Grafana's sidecar auto-discovers and loads it.

The dashboard includes:

- **Stats row:** Warning Events (24h), FailedMount (24h), OOMKilling (24h), BackOff (24h)
- **Time series:** Warning event rate broken out by reason over the selected time window
- **Table:** Top 20 warning events ranked by count — shows Namespace, Pod/Object, Reason,
  Source, and Count with color-coded severity

A **Namespace** dropdown lets you filter to a specific namespace or view all.

## Filter events by type or reason

By default the exporter forwards all events to Prometheus. To reduce cardinality, restrict
routes to Warning events only:

```yaml
eventExporter:
  enabled: true
  routes:
    - match:
        - type: Warning
      receiver: "prometheus"
```

To capture only Pod-related Warning events:

```yaml
eventExporter:
  enabled: true
  routes:
    - match:
        - type: Warning
          involvedObject:
            kind: Pod
      receiver: "prometheus"
```

## Bring your own Prometheus

If you run a Prometheus outside this chart, point it at the exporter Service. The Service is
annotated for auto-discovery:

```
prometheus.io/scrape: "true"
prometheus.io/port:   "2112"
prometheus.io/path:   "/metrics"
```

If your Prometheus uses `ServiceMonitor` CRDs, the Service labels
(`app.kubernetes.io/component: event-exporter`) are sufficient to write a selector.

## Tune retention

How long per-label series are kept after the last observed event (default 24h):

```yaml
eventExporter:
  metricsTTL: 48h
```

Reduce this if you have high pod churn and want to limit Prometheus cardinality.

## All values

```yaml
eventExporter:
  enabled: false
  image:
    repository: ghcr.io/opsgenie/kubernetes-event-exporter
    tag: v1.7
  logLevel: error          # error | warn | info | debug
  metricsPort: 2112
  metricsTTL: 24h
  routes: []               # empty = forward all events to Prometheus
  resources:
    limits:
      cpu: "100m"
      memory: "128Mi"
    requests:
      cpu: "10m"
      memory: "64Mi"
  serviceAccount:
    annotations: {}        # IRSA / Workload Identity annotations if needed
  nodeSelector: {}
  tolerations: []
  affinity: {}
```
