# controlplane

![Version: 2025.10.0](https://img.shields.io/badge/Version-2025.10.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2025.10.0](https://img.shields.io/badge/AppVersion-2025.10.0-informational?style=flat-square)

Deploys the Union control plane onto a Kubernetes cluster.

> **Selfhosted production deployments** carry meaningful operational requirements (cluster prerequisites, ingress + TLS, OIDC/OAuth2, multi-cluster routing). Reach out to [support@union.ai](mailto:support@union.ai) before standing up a production selfhosted control plane — we'll help you scope cluster sizing, IdP integration, and the rollout plan.

This README covers the Helm install only. Chart conventions: [`CONVENTIONS.md`](../CONVENTIONS.md). Recent migrations: [`MIGRATION.md`](../MIGRATION.md).

## Prerequisites

### 1. Add Helm repositories

```bash
helm repo add unionai https://unionai.github.io/helm-charts/
helm repo add flyte https://helm.flyte.org
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx   # if INGRESS_PROVIDER=nginx
helm repo add envoy-gateway oci://docker.io/envoyproxy                   # if INGRESS_PROVIDER=envoy
helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable  # if scylla.enabled=true
helm repo update
```

### 2. Install required CRDs

CRDs are installed separately from the chart via server-side apply. This
avoids the 256 KiB `kubectl.kubernetes.io/last-applied-configuration`
annotation overflow that affects large OpenAPI v3 schemas (notably
prometheus-operator + Gateway API). The Helm install below uses
`--skip-crds` so Helm doesn't try to manage these.

```bash
# From a checkout of unionai/helm-charts
git clone https://github.com/unionai/helm-charts.git
cd helm-charts

# Required when monitoring.enabled=true (chart default).
kubectl apply --server-side --force-conflicts -f crds/kube-prometheus-stack/

# Required when scylla.enabled=true (chart default — ScyllaDB powers the
# queue service). Skip if you manage scylla-operator + scylla CRDs
# externally.
kubectl apply --server-side --force-conflicts -f crds/scylla-operator/

# Required when INGRESS_PROVIDER=envoy or both. SKIP if your cluster
# already has Gateway API CRDs from another source — this directory
# bundles both standard Gateway API and envoy-specific CRDs.
kubectl apply --server-side --force-conflicts -f crds/envoy-gateway/
```

`--force-conflicts` is needed only on the first install (or when adopting
CRDs previously owned by a Helm-installed copy) so SSA can transfer field
ownership.

### Database architecture

The control plane needs **both** databases:

- **Postgres** — all services except queue (identity, executions, monolith, …). Provide externally and reference via `dbHost`/`dbName`/`dbUser`/db secret.
- **ScyllaDB** — queue service only. Can be embedded (chart-managed, default) or external (`scylla.enabled: false` + `scylla.externalHost`).

## Requirements

Kubernetes: `>= 1.28.0-0`

| Repository | Name | Version | Optional | Notes |
|------------|------|---------|----------|-------|
| https://helm.flyte.org | flyte-core(flyte) | v1.16.0-b2 | No | Required |
| https://kubernetes.github.io/ingress-nginx | ingress-nginx | 4.12.3 | Yes | Only if `ingress-nginx.enabled: true` |
| oci://docker.io/envoyproxy | gateway-helm(envoy-gateway) | v1.6.4 | Yes | Only if `envoy-gateway.enabled: true`; for selfmanaged deployments install via ArgoCD ApplicationSet instead |
| https://scylla-operator-charts.storage.googleapis.com/stable | scylla-operator | v1.18.1 | Yes | Only if `scylla.enabled: true` |
| https://scylla-operator-charts.storage.googleapis.com/stable | scylla | v1.18.1 | Yes | Only if `scylla.enabled: true` |
| https://prometheus-community.github.io/helm-charts | monitoring(kube-prometheus-stack) | 80.8.0 | Yes | Only if `monitoring.enabled: true` |

## Optional Components

### ScyllaDB Manager (Backup and Restore)

**ScyllaDB Manager is NOT included as a subchart** to avoid cross-namespace deployment complexity. If you need backup, repair, or monitoring features for ScyllaDB, you can install scylla-manager separately.

#### When to Install ScyllaDB Manager

Install scylla-manager if you need:
- Automated backups of your ScyllaDB cluster
- Repair scheduling and management
- Health checks and monitoring
- Multi-datacenter cluster management

#### Installing ScyllaDB Manager

1. **Install scylla-manager in the same namespace as your ScyllaDB cluster:**

```bash
# Add the ScyllaDB Helm repository if not already added
helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable
helm repo update

# Install scylla-manager (without its own ScyllaDB cluster)
# Point it to your existing ScyllaDB cluster
helm install scylla-manager scylla/scylla-manager \
  --namespace union-cp \
  --set scylla.enabled=false \
  --set manager.database.hosts="{scylla-client.union-cp.svc.cluster.local}"
```

2. **Configure backups and schedules:**

Refer to the [ScyllaDB Manager documentation](https://operator.docs.scylladb.com/stable/manager) for detailed configuration options.

## Quick start

### 1. Configure values

Pick the cloud overlay for your environment (`aws` or `gcp`) and fill in
the `global.*` placeholders + the `flyte.configmap.adminServer.auth` block
for your IdP:

```bash
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/controlplane/values.aws.yaml
# Edit values.aws.yaml — every empty "" global needs a value; set the
# adminServer.auth fields for your OIDC issuer (Okta, Entra ID, etc.)
```

### 2. Create the DB password secret

```bash
kubectl create namespace union-cp
kubectl create secret generic union-controlplane-secrets \
  --from-literal=pass.txt='<DB_PASSWORD>' \
  -n union-cp
```

### 3. Install the chart

```bash
helm upgrade --install unionai-controlplane unionai/controlplane \
  --namespace union-cp \
  --values values.aws.yaml \
  --skip-crds \
  --timeout 15m --wait
```

### 4. Verify

```bash
kubectl get pods -n union-cp
kubectl logs -n union-cp deploy/flyteadmin --tail=50
```

All pods should be `Running` and `flyteadmin` should be serving requests.

---

## AWS Pod Identity Webhook Annotation Prefix

The AWS pod identity webhook mutates pods by reading a service account annotation named `<annotation-prefix>/role-arn`. EKS uses `eks.amazonaws.com` by default, so the AWS values file defaults to `eks.amazonaws.com/role-arn`.

If your cluster operator installed the webhook with a custom `--annotation-prefix`, override each control plane service account annotation key that uses AWS IAM:

```yaml
flyte:
  flyteadmin:
    serviceAccount:
      annotations:
        customer.example.com/role-arn: "arn:aws:iam::123456789012:role/union-flyteadmin"
  datacatalog:
    serviceAccount:
      annotations:
        customer.example.com/role-arn: "arn:aws:iam::123456789012:role/union-flyteadmin"
  cacheservice:
    serviceAccount:
      annotations:
        customer.example.com/role-arn: "arn:aws:iam::123456789012:role/union-flyteadmin"

services:
  artifacts:
    serviceAccount:
      annotations:
        customer.example.com/role-arn: "arn:aws:iam::123456789012:role/union-artifacts"
```

When this is layered on top of an AWS preset values file, Helm may still render the default `eks.amazonaws.com/role-arn` annotation. That extra annotation is ignored by a webhook configured with a different prefix; the custom `<prefix>/role-arn` annotation is the one that controls mutation.

The IAM role trust policies must still trust the Kubernetes service account subjects used by the rendered service accounts.

---

## Installation

### Database Architecture

The Union control plane requires **both** database systems:

1. **Postgres**: Required for all control plane services (identity, executions, monolith, etc.)
   - Configure via `dbHost`, `dbName`, `dbUser`, and database secret
   - Must be provided (external or in-cluster)

2. **ScyllaDB**: Required exclusively for the queue service
   - Configure via `scylla` section
   - Can be embedded (via chart) or external

### Basic Installation (with External ScyllaDB)

Create a `values.yaml` file with your configuration:

```yaml
# Postgres configuration (required)
dbHost: "your-postgres-host"
dbName: "your-db-name"
dbUser: "your-db-user"
dbPass: "your-db-password"

# S3 storage configuration
bucketName: "your-s3-bucket"
artifactsBucketName: "your-artifacts-bucket"
region: "us-east-2"

# Use external ScyllaDB for queue service
scylla:
  enabled: false
  externalHost: "your-scylla-host"
  externalPort: 9042
```

Install the chart:

```bash
helm upgrade --install union-controlplane unionai/controlplane \
  --create-namespace \
  --namespace union-cp \
  --values values.yaml
```

### Installation with Embedded ScyllaDB

If you want to use the embedded ScyllaDB cluster for the queue service, ensure the ScyllaDB Operator is installed (see Prerequisites), then create a `values.yaml`:

```yaml
# Postgres configuration (required for all services except queue)
dbHost: "your-postgres-host"
dbName: "your-db-name"
dbUser: "your-db-user"
dbPass: "your-db-password"

# Embedded ScyllaDB for queue service
scylla:
  enabled: true
  datacenter: dc1
  racks:
    - name: rack1
      members: 3
      storage:
        capacity: 100Gi
        storageClassName: ""  # Use default storage class
      resources:
        limits:
          cpu: 2
          memory: 4Gi
        requests:
          cpu: 1
          memory: 2Gi
  version: 5.4.0
  developerMode: false  # Set to true for development/testing

# S3 storage configuration
bucketName: "your-s3-bucket"
artifactsBucketName: "your-artifacts-bucket"
region: "us-east-2"
```

Install the chart:

```bash
helm upgrade --install union-controlplane unionai/controlplane \
  --create-namespace \
  --namespace union-cp \
  --values values.yaml
```

### Ingress Controller

The chart supports two ingress controllers, selected via `global.INGRESS_PROVIDER`:

| Value | Behavior |
|-------|----------|
| `nginx` | Only nginx Ingress objects rendered (default) |
| `envoy` | Only Envoy Gateway API resources rendered (HTTPRoute/GRPCRoute/Gateway) |
| `both` | Both sets rendered simultaneously — use during migration |

#### Installation with Ingress NGINX

```yaml
global:
  INGRESS_PROVIDER: nginx

ingress-nginx:
  enabled: true
```

#### Installation with Envoy Gateway

Envoy Gateway can be installed as a sub-chart (managed deployments) or as a separate Helm release via ArgoCD (selfmanaged deployments — see [Self-Hosted Guides](#alternative-deployment-models)).

For sub-chart installation:

```yaml
global:
  INGRESS_PROVIDER: envoy

envoy-gateway:
  enabled: true  # installs gateway-helm as a sub-chart

envoyGateway:
  gatewayClassName: envoy  # must match the GatewayClass created by the EG install
```

## Verification

After installation, verify the deployment:

```bash
# Check pod status
kubectl get pods -n union-cp

# Check services
kubectl get svc -n union-cp

# If using ScyllaDB, check ScyllaDB cluster status
kubectl get scyllaclusters -n union-cp
```

## Configuration

For detailed configuration options, see the [values.yaml](values.yaml) file or use the following command to see all available values:

```bash
helm show values unionai/controlplane
```

### Key Configuration Options

- **Postgres Configuration** (Required): Set `dbHost`, `dbName`, `dbUser`, and `dbPass` for the primary database used by all control plane services except the queue service
- **ScyllaDB Configuration** (Required): Configure `scylla` section for the queue service database. Set `scylla.enabled: true` for embedded cluster or provide `scylla.externalHost` for external ScyllaDB
- **Object Storage**: Configure `bucketName`, `artifactsBucketName`, and `region` for S3-compatible storage
- **Ingress**: Set `global.INGRESS_PROVIDER` to `nginx`, `envoy`, or `both`. Enable the relevant controller (`ingress-nginx.enabled` or `envoy-gateway.enabled`) and configure `envoyGateway.gatewayClassName` when using Envoy Gateway

---

## Monitoring & Observability

The controlplane chart includes an optional [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) instance for monitoring controlplane service health. It is **disabled by default**.

### Enabling monitoring

```yaml
monitoring:
  enabled: true
```

This deploys:

- **Prometheus** — scrapes controlplane service health metrics (7-day retention)
- **Grafana** — pre-configured with kube-prometheus-stack dashboards
- **kube-state-metrics** — Kubernetes object state metrics
- **node-exporter** — host-level metrics
- **ServiceMonitors** — auto-configured to scrape all controlplane services

To access Grafana, port-forward to the service:

```bash
kubectl port-forward svc/union-cp-monitoring-grafana -n union-cp 3000:80
```

### Forwarding metrics to an external destination

Configure the monitoring Prometheus to forward metrics using `remoteWrite`:

```yaml
monitoring:
  prometheus:
    prometheusSpec:
      remoteWrite:
        - url: "https://your-prometheus-endpoint/api/v1/write"
```

To run in agent mode (forward-only, no local TSDB):

```yaml
monitoring:
  prometheus:
    agentMode: true
    prometheusSpec:
      remoteWrite:
        - url: "https://your-prometheus-endpoint/api/v1/write"
```

### Using your own Prometheus

Disable the built-in monitoring stack and scrape controlplane services from your own Prometheus:

```yaml
monitoring:
  enabled: false
```

Controlplane services expose metrics with the label `platform.union.ai/prometheus-group: "union-services"`. Create a ServiceMonitor targeting this label:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: union-controlplane
spec:
  selector:
    matchLabels:
      platform.union.ai/prometheus-group: "union-services"
  namespaceSelector:
    matchNames:
      - union-cp
  endpoints:
    - port: debug
      path: /metrics
      interval: 1m
```

If you are running both the dataplane and controlplane in the same cluster, your existing Prometheus can discover all Union services by using a `NotIn` selector that excludes the internal `union-features` group:

```yaml
serviceMonitorSelector:
  matchExpressions:
    - key: platform.union.ai/prometheus-group
      operator: NotIn
      values: ["union-features"]
```

This matches all ServiceMonitors where the label is absent or has any value other than `union-features`, which safely includes both controlplane and dataplane service monitors.

### Alertmanager

Alertmanager is disabled by default. Enable it with:

```yaml
monitoring:
  alertmanager:
    enabled: true
    config:
      route:
        receiver: "default"
      receivers:
        - name: "default"
          # Configure Slack, PagerDuty, email, webhook, etc.
```

---

## Upgrading

To upgrade the controlplane chart:

```bash
helm upgrade union-controlplane unionai/controlplane \
  --namespace union-cp \
  --values values.yaml
```

**Important**: When upgrading, ensure that:
1. CRDs are updated if necessary
2. ScyllaDB Operator is compatible with the new chart version
3. Review the changelog for breaking changes

## Uninstallation

To uninstall the controlplane:

```bash
helm uninstall union-controlplane --namespace union-cp
```

**Note**: This will not remove:
- PersistentVolumeClaims (PVCs) created by ScyllaDB
- CRDs installed separately
- The namespace

To completely clean up:

```bash
# Delete PVCs
kubectl delete pvc -n union-cp --all

# Delete namespace
kubectl delete namespace union-cp
```

## Alternative Deployment Models

### Self-Hosted Intra-Cluster Deployment

For deploying Union control plane in the **same Kubernetes cluster** as your Union dataplane, see the [Self-hosted deployment guide](https://docs.union.ai/selfmanaged/deployment/selfhosted-deployment/) on the Union documentation site.

For intra-cluster topologies, layer `examples/values.{cloud}.intracluster.yaml` on top of the canonical `values.{cloud}.yaml` overlay. See [`MIGRATION.md`](../MIGRATION.md) for details about the cloud overlay consolidation.

---

## Troubleshooting

### ScyllaDB Pods Not Starting

If ScyllaDB pods are not starting:

1. Verify the ScyllaDB Operator is running:
   ```bash
   kubectl get pods -n scylla-operator
   ```

2. Check ScyllaDB cluster status:
   ```bash
   kubectl describe scyllacluster -n union-cp
   ```

3. Ensure sufficient resources are available in your cluster

### Database Connection Issues

If controlplane services cannot connect to the database:

1. Verify database credentials in your values file
2. Check network policies and firewall rules
3. Verify the database is accessible from the cluster

### CRD Not Found Errors

If you see CRD-related errors:

1. Ensure Flyte CRDs are installed (see Prerequisites)
2. Verify CRDs exist:
   ```bash
   kubectl get crds | grep flyte
   kubectl get crds | grep scylla
   ```

## Additional Resources

- [Union Documentation](https://docs.union.ai/)
- [ScyllaDB Operator Documentation](https://operator.docs.scylladb.com/)
- [Flyte Documentation](https://docs.flyte.org/)
