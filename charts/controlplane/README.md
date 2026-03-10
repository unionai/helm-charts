# controlplane

![Version: 2026.2.7](https://img.shields.io/badge/Version-2026.2.7-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2026.2.12](https://img.shields.io/badge/AppVersion-2026.2.12-informational?style=flat-square)
Deploys the Union controlplane components to onboard a kubernetes cluster to the Union Cloud.

## Prerequisites

Before installing the Union controlplane chart, you need to install the required dependencies and CRDs.

### 1. Add Helm Repositories

```bash
# Add Union.ai Helm repository
helm repo add unionai https://unionai.github.io/helm-charts/

# Add Flyte Helm repository
helm repo add flyte https://helm.flyte.org

# Add Ingress NGINX Helm repository (if using ingress-nginx)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# Add ScyllaDB Helm repository (if using ScyllaDB)
helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable

# Update repositories
helm repo update
```

### 2. Install Scylla CRDs (Required for Queue Service)

**Both ScyllaDB and Postgres are required** for the Union control plane:
- **ScyllaDB**: Used exclusively by the queue service for high-performance message queueing
- **Postgres**: Used by all other control plane services for metadata and state management

Scylla CRDs are required if you plan to leave scylla enabled (`scylla.enabled: true`). Helm CRD management is not consistent and commonly depends on what devops tool is used to manage the Helm chart.

We've included a script if you want to manually install the CRDs:

```bash
cd helm-charts/charts/controlplane
./scripts/install-scylla-crds.sh
```

Scylla CRDs are not required if you manage ScyllaDB outside of the Helm chart.

## Requirements

Kubernetes: `>= 1.28.0-0`

| Repository | Name | Version |
|------------|------|---------|
| https://helm.flyte.org | flyte(flyte-core) | v1.16.1 |
| https://kubernetes.github.io/ingress-nginx | ingress-nginx | 4.12.3 |
| https://scylla-operator-charts.storage.googleapis.com/stable | scylla | v1.18.1 |
| https://scylla-operator-charts.storage.googleapis.com/stable | scylla-operator | v1.18.1 |

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

## Quick Start

Choose your cloud provider to get started:

- [AWS (Amazon Web Services)](#quick-start-aws)
- GCP (Google Cloud Platform) - *Coming soon*
- Azure (Microsoft Azure) - *Coming soon*

---

### Quick Start: AWS

For AWS deployments, we provide reference configuration files that make it easy to get started.

#### Prerequisites (AWS)

Before you begin, ensure you have:

1. **AWS EKS cluster** (Kubernetes >= 1.28.0)
2. **PostgreSQL database** (RDS or self-hosted)
3. **S3 buckets** for control plane metadata and artifacts
4. **IAM roles** configured with IRSA for control plane services
5. **Helm 3.18+** installed locally

#### Step 1: Download Configuration Template

```bash
# Download the AWS reference values file
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/controlplane/values.aws.yaml
```

#### Step 2: Fill in Required Values

Edit `values.aws.yaml` by setting all `global` values and replace all empty `""` values marked with `# TODO`.

#### Step 3: Create Database Password Secret

```bash
kubectl create namespace union-cp
kubectl create secret generic union-controlplane-secrets \
  --from-literal=pass.txt='YOUR_DB_PASSWORD' \
  -n union-cp
```

#### Step 4: Install Control Plane

```bash
helm repo add unionai https://unionai.github.io/helm-charts/
helm repo update

helm upgrade --install unionai-controlplane unionai/controlplane \
  --namespace union-cp \
  --values values.aws.yaml \
  --timeout 15m \
  --wait
```

#### Step 5: Verify Installation

Check that all control plane components are running:

```bash
# Check pod status
kubectl get pods -n union-cp

# Verify services are available
kubectl get svc -n union-cp

# Check flyteadmin logs
kubectl logs -n union-cp deploy/flyteadmin --tail=50
```

Expected output: All pods should be in `Running` state.

For detailed configuration options and alternative deployment models, see the sections below.

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

### Installation with Ingress NGINX

If you need ingress support:

```yaml
ingress-nginx:
  enabled: true

ingress:
  className: "controlplane"
  secretService: true
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
- **Ingress**: Enable and configure ingress under `ingress-nginx` section

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| argo.enabled | bool | `false` |  |
| artifacts.enabled | bool | `false` |  |
| autoscaling.enabled | bool | `true` |  |
| autoscaling.maxReplicas | int | `1` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| autoscaling.targetMemoryUtilizationPercentage | int | `80` |  |
| configMap.authorizer.internalCommunicationConfig.enabled | bool | `false` |  |
| configMap.authorizer.type | string | `"Noop"` |  |
| configMap.cache.identity.enabled | bool | `false` |  |
| configMap.connection.environment | string | `"staging"` |  |
| configMap.connection.region | string | `"{{ .Values.global.AWS_REGION }}"` |  |
| configMap.connection.rootTenantURLPattern | string | `"dns:///{{ .Values.global.UNION_HOST }}"` |  |
| configMap.logger.level | int | `6` |  |
| configMap.otel.type | string | `"noop"` |  |
| configMap.union.auth.enable | bool | `false` |  |
| configMap.union.internalConnectionConfig.enabled | bool | `true` |  |
| configMap.union.internalConnectionConfig.urlPattern | string | `"_SERVICE_.{{ .Release.Namespace }}.svc.cluster.local:80"` |  |
| console.affinity | object | `{}` |  |
| console.env | list | `[]` |  |
| console.envFrom | list | `[]` |  |
| console.fullnameOverride | string | `"unionconsole"` |  |
| console.image.pullPolicy | string | `"IfNotPresent"` |  |
| console.image.repository | string | `"{{ .Values.global.IMAGE_REPOSITORY_PREFIX }}/unionconsole"` |  |
| console.image.tag | string | `"{{ .Chart.AppVersion }}"` |  |
| console.nameOverride | string | `""` |  |
| console.nodeSelector | object | `{}` |  |
| console.podAnnotations."kubectl.kubernetes.io/default-container" | string | `"unionconsole"` |  |
| console.podLabels | object | `{}` |  |
| console.podSecurityContext.fsGroupChangePolicy | string | `"OnRootMismatch"` |  |
| console.podSecurityContext.runAsNonRoot | bool | `true` |  |
| console.podSecurityContext.runAsUser | int | `1000` |  |
| console.podSecurityContext.seLinuxOptions.type | string | `"spc_t"` |  |
| console.replicaCount | int | `1` |  |
| console.resources.limits.cpu | string | `"500m"` |  |
| console.resources.limits.memory | string | `"512Mi"` |  |
| console.resources.requests.cpu | string | `"250m"` |  |
| console.resources.requests.memory | string | `"250Mi"` |  |
| console.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| console.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| console.service.annotations | object | `{}` |  |
| console.service.metricsPort | int | `8081` |  |
| console.service.port | int | `80` |  |
| console.service.targetPort | int | `8080` |  |
| console.service.type | string | `"ClusterIP"` |  |
| console.serviceAccount.annotations | object | `{}` |  |
| console.serviceAccount.create | bool | `true` |  |
| console.serviceAccount.name | string | `""` |  |
| console.strategy.rollingUpdate.maxSurge | int | `1` |  |
| console.strategy.rollingUpdate.maxUnavailable | int | `1` |  |
| console.strategy.type | string | `"RollingUpdate"` |  |
| console.tolerations | list | `[]` |  |
| controlplane.enabled | bool | `true` |  |
| dataproxy.prometheus.enabled | bool | `false` |  |
| dbPass | string | `""` | -------------------------------------------------------------------------- Note: Most configuration now comes from globals above. Database host, name, user, buckets, and region are all configured via globals. It's recommended to create a Kubernetes secret and reference it via globals.KUBERNETES_SECRET_NAME rather than storing the password here |
| defaults | object | `{"dbSecretName":"{{ .Values.global.KUBERNETES_SECRET_NAME }}","secretName":"{{ .Values.global.KUBERNETES_SECRET_NAME }}"}` | Default config for Union services (excluding flyte subchart) |
| env[0].name | string | `"GOMEMLIMIT"` |  |
| env[0].valueFrom.resourceFieldRef.divisor | string | `"1"` |  |
| env[0].valueFrom.resourceFieldRef.resource | string | `"limits.memory"` |  |
| env[1].name | string | `"GOMAXPROCS"` |  |
| env[1].valueFrom.resourceFieldRef.divisor | string | `"1"` |  |
| env[1].valueFrom.resourceFieldRef.resource | string | `"limits.cpu"` |  |
| externalSecrets.refreshInterval | string | `"1h"` |  |
| externalSecrets.refs | object | `{}` |  |
| extraObjects | list | `[]` |  |
| flyte.bucketName | string | `"{{ .Values.global.BUCKET_NAME }}"` |  |
| flyte.cacheservice.additionalContainers | list | `[]` | Appends additional containers to the deployment spec. May include template values. |
| flyte.cacheservice.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| flyte.cacheservice.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| flyte.cacheservice.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels."app.kubernetes.io/name" | string | `"cacheservice"` |  |
| flyte.cacheservice.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey | string | `"kubernetes.io/hostname"` |  |
| flyte.cacheservice.configPath | string | `"/etc/cacheservice/config/*.yaml"` |  |
| flyte.cacheservice.enabled | bool | `true` |  |
| flyte.cacheservice.extraArgs | object | `{}` | Appends extra command line arguments to the main command |
| flyte.cacheservice.image.pullPolicy | string | `"IfNotPresent"` |  |
| flyte.cacheservice.image.repository | string | `"643379628101.dkr.ecr.us-east-1.amazonaws.com/union-cp/services"` |  |
| flyte.cacheservice.image.tag | string | `""` |  |
| flyte.cacheservice.nodeSelector | object | `{}` | nodeSelector for Cacheservice deployment |
| flyte.cacheservice.podAnnotations | object | `{}` | Annotations for Cacheservice pods |
| flyte.cacheservice.podEnv | object | `{}` | Additional Cacheservice container environment variables |
| flyte.cacheservice.podLabels | object | `{}` | Labels for Cacheservice pods |
| flyte.cacheservice.priorityClassName | string | `""` | Sets priorityClassName for cacheservice pod(s). |
| flyte.cacheservice.replicaCount | int | `1` |  |
| flyte.cacheservice.resources.limits.cpu | int | `1` |  |
| flyte.cacheservice.resources.limits.ephemeral-storage | string | `"200Mi"` |  |
| flyte.cacheservice.resources.requests.cpu | string | `"500m"` |  |
| flyte.cacheservice.resources.requests.ephemeral-storage | string | `"200Mi"` |  |
| flyte.cacheservice.resources.requests.memory | string | `"200Mi"` |  |
| flyte.cacheservice.securityContext | object | `{"fsGroup":1001,"fsGroupChangePolicy":"OnRootMismatch","runAsNonRoot":true,"runAsUser":1001,"seLinuxOptions":{"type":"spc_t"}}` | Sets securityContext for cacheservice pod(s). |
| flyte.cacheservice.service.annotations | object | `{}` |  |
| flyte.cacheservice.service.type | string | `"ClusterIP"` |  |
| flyte.cacheservice.serviceAccount.annotations | object | `{}` | Set the role arn for the cacheservice service account which has access to the S3 bucket |
| flyte.cacheservice.serviceAccount.create | bool | `true` | If the service account is created by you, make this false |
| flyte.cacheservice.tolerations | list | `[]` | tolerations for Cacheservice deployment |
| flyte.cloudEvents.enable | bool | `false` |  |
| flyte.cluster_resource_manager.enabled | bool | `false` |  |
| flyte.common.databaseSecret.name | string | `"union-controlplane-secrets"` | Specify name of K8s Secret which contains Database password. Leave it empty if you don't need this Secret flyte-org/flyte flyte-core helm chart _helpers.tpl does not render templates. Therefore we have to explicitly set the value here. Ref: https://github.com/flyteorg/flyte/pull/6711 TODO (DIRECTLY CONFIGURE): Match value to global.KUBERNETES_SECRET_NAME |
| flyte.common.databaseSecret.secretManifest | object | `{}` | Leave it empty if your secret already exists |
| flyte.common.ingress.enabled | bool | `false` |  |
| flyte.configmap.admin.clientId | string | `nil` |  |
| flyte.configmap.admin.clientSecretLocation | string | `nil` |  |
| flyte.configmap.admin.endpoint | string | `"flyteadmin.{{ .Release.Namespace }}.svc.cluster.local:81"` |  |
| flyte.configmap.admin.insecure | bool | `true` |  |
| flyte.configmap.adminServer.admin.endpoint | string | `"dns:///{{ .Values.global.UNION_HOST }}"` |  |
| flyte.configmap.adminServer.admin.insecure | bool | `false` |  |
| flyte.configmap.adminServer.authorizer.internalCommunicationConfig.enabled | bool | `false` |  |
| flyte.configmap.adminServer.authorizer.type | string | `"Noop"` |  |
| flyte.configmap.adminServer.cloudEvents.enable | bool | `false` |  |
| flyte.configmap.adminServer.connection.environment | string | `"staging"` |  |
| flyte.configmap.adminServer.connection.region | string | `"{{ .Values.global.AWS_REGION }}"` |  |
| flyte.configmap.adminServer.connection.rootTenantURLPattern | string | `"dns:///{{ .Values.global.UNION_HOST }}"` |  |
| flyte.configmap.adminServer.flyteadmin.metricsKeys[0] | string | `"phase"` |  |
| flyte.configmap.adminServer.flyteadmin.testing | string | `nil` |  |
| flyte.configmap.adminServer.flyteadmin.useOffloadedInputs | bool | `true` |  |
| flyte.configmap.adminServer.flyteadmin.useOffloadedWorkflowClosure | bool | `true` |  |
| flyte.configmap.adminServer.otel.type | string | `"noop"` |  |
| flyte.configmap.adminServer.private.app.cacheProviderConfig.kind | string | `"bypass"` |  |
| flyte.configmap.adminServer.private.app.populateUserFields | bool | `false` |  |
| flyte.configmap.adminServer.server.security.useAuth | bool | `false` |  |
| flyte.configmap.adminServer.sharedService.connectPort | int | `8089` |  |
| flyte.configmap.adminServer.sharedService.httpPort | int | `8088` |  |
| flyte.configmap.adminServer.sharedService.port | int | `8089` |  |
| flyte.configmap.adminServer.union.internalConnectionConfig.enabled | bool | `true` |  |
| flyte.configmap.adminServer.union.internalConnectionConfig.urlPattern | string | `"{{ printf \"_SERVICE_.%s.svc.cluster.local:80\" .Release.Namespace }}"` |  |
| flyte.configmap.cacheserviceServer.authorizer.internalCommunicationConfig.enabled | bool | `false` |  |
| flyte.configmap.cacheserviceServer.authorizer.type | string | `"Noop"` |  |
| flyte.configmap.cacheserviceServer.cache-server.grpcPort | int | `8089` |  |
| flyte.configmap.cacheserviceServer.cache-server.grpcServerReflection | bool | `true` |  |
| flyte.configmap.cacheserviceServer.cache-server.httpPort | int | `8080` |  |
| flyte.configmap.cacheserviceServer.cacheservice.heartbeat-grace-period-multiplier | int | `3` |  |
| flyte.configmap.cacheserviceServer.cacheservice.max-reservation-heartbeat | string | `"30s"` |  |
| flyte.configmap.cacheserviceServer.cacheservice.metrics-scope | string | `"flyte"` |  |
| flyte.configmap.cacheserviceServer.cacheservice.profiler-port | int | `10254` |  |
| flyte.configmap.cacheserviceServer.cacheservice.storage-prefix | string | `"cached_outputs"` |  |
| flyte.configmap.cacheserviceServer.otel.type | string | `"noop"` |  |
| flyte.configmap.cacheserviceServer.private.app.cacheProviderConfig.kind | string | `"bypass"` |  |
| flyte.configmap.cacheserviceServer.union.internalConnectionConfig.enabled | bool | `true` |  |
| flyte.configmap.cacheserviceServer.union.internalConnectionConfig.urlPattern | string | `"{{ printf \"_SERVICE_.%s.svc.cluster.local:80\" .Release.Namespace }}"` |  |
| flyte.configmap.logger.level | string | `nil` |  |
| flyte.configmap.sharedService.connectPort | int | `8089` |  |
| flyte.configmap.sharedService.httpPort | int | `8088` |  |
| flyte.configmap.sharedService.port | int | `8089` |  |
| flyte.datacatalog.autoscaling.enabled | bool | `true` | Enable autoscaling for datacatalog |
| flyte.datacatalog.enabled | bool | `false` |  |
| flyte.datacatalog.image.pullPolicy | string | `"IfNotPresent"` |  |
| flyte.datacatalog.image.repository | string | `"643379628101.dkr.ecr.us-east-1.amazonaws.com/union-cp/datacatalog"` |  |
| flyte.datacatalog.image.tag | string | `""` |  |
| flyte.datacatalog.replicaCount | int | `1` |  |
| flyte.datacatalog.resources.limits.cpu | int | `1` |  |
| flyte.datacatalog.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| flyte.datacatalog.resources.limits.memory | string | `"1Gi"` |  |
| flyte.datacatalog.resources.requests.cpu | string | `"10m"` |  |
| flyte.datacatalog.resources.requests.ephemeral-storage | string | `"50Mi"` |  |
| flyte.datacatalog.resources.requests.memory | string | `"50Mi"` |  |
| flyte.datacatalog.service.type | string | `"ClusterIP"` |  |
| flyte.datacatalog.serviceAccount.annotations | object | `{}` | Set the role arn for the datacatlog service account which has access to the S3 bucket |
| flyte.datacatalog.strategy.rollingUpdate.maxSurge | int | `1` |  |
| flyte.datacatalog.strategy.rollingUpdate.maxUnavailable | int | `1` |  |
| flyte.datacatalog.strategy.type | string | `"RollingUpdate"` |  |
| flyte.db.admin.database.connMaxLifeTime | string | `"120s"` |  |
| flyte.db.admin.database.dbname | string | `"flyteadmin"` | Use a specific DB name for flyteadmin |
| flyte.db.admin.database.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| flyte.db.admin.database.maxIdleConnections | int | `10` |  |
| flyte.db.admin.database.maxOpenConnections | int | `80` |  |
| flyte.db.admin.database.passwordPath | string | `"/etc/db/pass.txt"` |  |
| flyte.db.admin.database.port | int | `5432` |  |
| flyte.db.admin.database.username | string | `"{{ .Values.global.DB_USER }}"` | Create a user called flyteadmin |
| flyte.db.cacheservice.database.connMaxLifeTime | string | `"120s"` |  |
| flyte.db.cacheservice.database.dbname | string | `"cacheservice"` | Use a specific DB name for cacheservice |
| flyte.db.cacheservice.database.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| flyte.db.cacheservice.database.maxIdleConnections | int | `10` |  |
| flyte.db.cacheservice.database.maxOpenConnections | int | `20` |  |
| flyte.db.cacheservice.database.passwordPath | string | `"/etc/db/pass.txt"` |  |
| flyte.db.cacheservice.database.port | int | `5432` |  |
| flyte.db.cacheservice.database.username | string | `"{{ .Values.global.DB_USER }}"` | Create a user called flyteadmin |
| flyte.db.checks | bool | `false` |  |
| flyte.db.datacatalog.database.connMaxLifeTime | string | `"120s"` |  |
| flyte.db.datacatalog.database.dbname | string | `"datacatalog"` | Use a specific DB name for datacatalog |
| flyte.db.datacatalog.database.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| flyte.db.datacatalog.database.maxIdleConnections | int | `10` |  |
| flyte.db.datacatalog.database.maxOpenConnections | int | `20` |  |
| flyte.db.datacatalog.database.passwordPath | string | `"/etc/db/pass.txt"` |  |
| flyte.db.datacatalog.database.port | int | `5432` |  |
| flyte.db.datacatalog.database.username | string | `"{{ .Values.global.DB_USER }}"` | Create a user called flyteadmin |
| flyte.dbHost | string | `"{{ .Values.global.DB_HOST }}"` |  |
| flyte.dbName | string | `"{{ .Values.global.DB_NAME }}"` |  |
| flyte.dbUser | string | `"{{ .Values.global.DB_USER }}"` |  |
| flyte.flyteadmin.autoscaling.enabled | bool | `true` |  |
| flyte.flyteadmin.image | object | `{"pullPolicy":"IfNotPresent","repository":"643379628101.dkr.ecr.us-east-1.amazonaws.com/union-cp/services","tag":""}` | Set the image used for flyteadmin |
| flyte.flyteadmin.initialProjects[0] | string | `"union-health-monitoring"` |  |
| flyte.flyteadmin.initialProjects[1] | string | `"flytesnacks"` |  |
| flyte.flyteadmin.livenessProbe | string | `"httpGet:\n  path: /healthcheck\n  port: 8088\ninitialDelaySeconds: 20\ntimeoutSeconds: 1\nperiodSeconds: 5\nsuccessThreshold: 1\nfailureThreshold: 3"` |  |
| flyte.flyteadmin.podAnnotations."kubectl.kubernetes.io/default-container" | string | `"flyteadmin"` |  |
| flyte.flyteadmin.readinessProbe | string | `"httpGet:\n  path: /healthcheck\n  port: 8088\ninitialDelaySeconds: 15\ntimeoutSeconds: 1\nperiodSeconds: 10\nsuccessThreshold: 1\nfailureThreshold: 3"` |  |
| flyte.flyteadmin.replicaCount | int | `1` |  |
| flyte.flyteadmin.resources.limits.cpu | int | `2` |  |
| flyte.flyteadmin.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| flyte.flyteadmin.resources.limits.memory | string | `"3Gi"` |  |
| flyte.flyteadmin.resources.requests.cpu | string | `"50m"` |  |
| flyte.flyteadmin.resources.requests.ephemeral-storage | string | `"200Mi"` |  |
| flyte.flyteadmin.resources.requests.memory | string | `"500Mi"` |  |
| flyte.flyteadmin.serviceAccount.annotations | object | `{}` | Set the role arn for the flyteadmin service account which has access to the S3 bucket |
| flyte.flyteadmin.strategy.rollingUpdate.maxSurge | int | `1` |  |
| flyte.flyteadmin.strategy.rollingUpdate.maxUnavailable | int | `1` |  |
| flyte.flyteadmin.strategy.type | string | `"RollingUpdate"` |  |
| flyte.flyteconsole.enabled | bool | `true` |  |
| flyte.flyteconsole.ga.enabled | bool | `true` |  |
| flyte.flyteconsole.ga.tracking_id | string | `""` |  |
| flyte.flyteconsole.image.repository | string | `"643379628101.dkr.ecr.us-east-1.amazonaws.com/union-cp/flyteconsole"` |  |
| flyte.flyteconsole.image.tag | string | `""` |  |
| flyte.flyteconsole.podAnnotations."linkerd.io/inject" | string | `"disabled"` |  |
| flyte.flyteconsole.podAnnotations."prometheus.io/scrape" | string | `"false"` |  |
| flyte.flyteconsole.podEnv | object | `{}` |  |
| flyte.flyteconsole.replicaCount | int | `1` |  |
| flyte.flyteconsole.resources.limits.cpu | string | `"250m"` |  |
| flyte.flyteconsole.resources.limits.ephemeral-storage | string | `"200Mi"` |  |
| flyte.flyteconsole.resources.limits.memory | string | `"250Mi"` |  |
| flyte.flyteconsole.resources.requests.cpu | string | `"10m"` |  |
| flyte.flyteconsole.resources.requests.ephemeral-storage | string | `"20Mi"` |  |
| flyte.flyteconsole.resources.requests.memory | string | `"50Mi"` |  |
| flyte.flyteconsole.service.annotations."external-dns.alpha.kubernetes.io/hostname" | string | `"flyte.example.com"` |  |
| flyte.flyteconsole.service.annotations."service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout" | string | `"600"` |  |
| flyte.flyteconsole.service.type | string | `"ClusterIP"` |  |
| flyte.flyteconsole.serviceAccount.create | bool | `true` |  |
| flyte.flyteconsole.serviceMonitor.enabled | bool | `false` |  |
| flyte.flytepropeller.enabled | bool | `false` |  |
| flyte.flytescheduler.image.pullPolicy | string | `"IfNotPresent"` |  |
| flyte.flytescheduler.image.repository | string | `"643379628101.dkr.ecr.us-east-1.amazonaws.com/union-cp/flytescheduler"` |  |
| flyte.flytescheduler.image.tag | string | `""` |  |
| flyte.region | string | `"{{ .Values.global.AWS_REGION }}"` |  |
| flyte.storage.bucketName | string | `"{{ .Values.global.BUCKET_NAME }}"` | bucketName defines the storage bucket flyte will use. Required for all types except for sandbox. |
| flyte.storage.cache.maxSizeMBs | int | `1024` |  |
| flyte.storage.s3.region | string | `"{{ .Values.global.AWS_REGION }}"` |  |
| flyte.storage.type | string | `"s3"` | Sets the storage type. Supported values are sandbox, s3, gcs and custom. |
| flyte.webhook.enabled | bool | `false` |  |
| flyte.workflow_notifications.enabled | bool | `false` |  |
| flyte.workflow_scheduler.enabled | bool | `false` |  |
| flyte.workflow_scheduler.type | string | `"native"` |  |
| fullnameOverride | string | `"controlplane"` |  |
| global.ARTIFACTS_BUCKET_NAME | string | `""` |  |
| global.AWS_REGION | string | `""` |  |
| global.BUCKET_NAME | string | `""` |  |
| global.DB_HOST | string | `""` |  |
| global.DB_NAME | string | `""` |  |
| global.DB_USER | string | `""` |  |
| global.IMAGE_REPOSITORY_PREFIX | string | `"643379628101.dkr.ecr.us-east-1.amazonaws.com/union-cp"` |  |
| global.KUBERNETES_SECRET_NAME | string | `""` |  |
| global.UNION_HOST | string | `""` |  |
| image | object | `{"pullPolicy":"IfNotPresent","repository":"{{ .Values.global.IMAGE_REPOSITORY_PREFIX }}/services","tag":"{{ .Chart.AppVersion }}"}` | Set the image used for control plane services |
| imagePullSecrets | string | `nil` |  |
| ingress-nginx.controller.admissionWebhooks.enabled | bool | `true` |  |
| ingress-nginx.controller.allowSnippetAnnotations | bool | `true` |  |
| ingress-nginx.controller.config.annotations-risk-level | string | `"Critical"` |  |
| ingress-nginx.controller.config.grpc-connect-timeout | string | `"1200"` |  |
| ingress-nginx.controller.config.grpc-read-timeout | string | `"604800"` |  |
| ingress-nginx.controller.config.grpc-send-timeout | string | `"604800"` |  |
| ingress-nginx.controller.config.proxy-connect-timeout | string | `"60"` |  |
| ingress-nginx.controller.config.proxy-read-timeout | string | `"3600"` |  |
| ingress-nginx.controller.config.proxy-send-timeout | string | `"3600"` |  |
| ingress-nginx.controller.ingressClassResource.controllerValue | string | `"union.ai/controlplane"` |  |
| ingress-nginx.controller.ingressClassResource.default | bool | `false` |  |
| ingress-nginx.controller.ingressClassResource.enabled | bool | `true` |  |
| ingress-nginx.controller.ingressClassResource.name | string | `"controlplane"` |  |
| ingress-nginx.enabled | bool | `false` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/app-root" | string | `"/v2"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/force-ssl-redirect" | string | `"false"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/limit-rps" | string | `"100"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-body-size" | string | `"6m"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffer-size" | string | `"32k"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffers" | string | `"4 32k"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-cookie-domain" | string | `"~^ .$host"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/server-snippet" | string | `"client_header_timeout 604800;\nclient_body_timeout 604800;\n# Increasing the default configuration from\n#        client_header_buffer_size       1k;\n#        large_client_header_buffers     4 8k;\n# to default of 16k and 32k for large buffer sizes. These sizes are chosen as a short term mediation until we can collect data to reason\n# about expected header sizs (PE-1101).\n# Historically, we have seen is with the previous 8k max buffer size , the auth endpoint of /me would throw 400 Bad request and due to this ingress controller\n# threw a 500 as it doesn't expect this status code on auth request expected range :  200 <= authcall.status(i.e status of /me call) <=300\n# Code link for ref : https://github.com/nginx/nginx/blob/e734df6664e70f118ca3140bcef6d4f1750fa8fa/src/http/modules/ngx_http_auth_request_module.c#L170-L179\n# Now the main reason we have seen 400 bad request is large size of the cookies which contribute to the header size.\n# We should keep reducing the size of what headers are being sent meanwhile we increase this size to mitigate the long header issue.\nclient_header_buffer_size 16k;\nlarge_client_header_buffers 64 32k;\n"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/service-upstream" | string | `"true"` |  |
| ingress.className | string | `"controlplane"` |  |
| ingress.enableProtectedConsoleIngress | bool | `false` |  |
| ingress.host | string | `""` |  |
| ingress.protectedConsoleIngressAnnotations."nginx.ingress.kubernetes.io/auth-cache-key" | string | `"$http_flyte_authorization$http_cookie"` |  |
| ingress.protectedConsoleIngressAnnotations."nginx.org/websocket-services" | string | `"dataproxy-service"` |  |
| ingress.protectedIngressAnnotations."nginx.org/websocket-services" | string | `"dataproxy-service"` |  |
| ingress.protectedIngressAnnotationsGrpc | string | `nil` |  |
| ingress.protectedIngressAnnotationsWithoutSignin."nginx.org/websocket-services" | string | `"dataproxy-service"` |  |
| ingress.secretService | bool | `true` |  |
| ingress.separateGrpcIngress | bool | `true` |  |
| ingress.separateGrpcIngressAnnotations."nginx.ingress.kubernetes.io/backend-protocol" | string | `"GRPC"` |  |
| nameOverride | string | `""` |  |
| objectstore.controlPlane.enabled | bool | `false` |  |
| podAnnotations."linkerd.io/inject" | string | `"disabled"` |  |
| podAnnotations."prometheus.io/path" | string | `"/metrics"` |  |
| podAnnotations."prometheus.io/port" | string | `"10254"` |  |
| podMonitor.custom.enabled | bool | `false` |  |
| podMonitor.custom.metricRelabelings | list | `[]` |  |
| postgres-exporter.enabled | bool | `false` |  |
| postgres-exporter.fullnameOverride | string | `"postgres-exporter"` |  |
| postgres-exporter.serviceMonitor.enabled | bool | `false` |  |
| postgres-exporter.serviceMonitor.labels.instance | string | `"union"` |  |
| probe.enabled | bool | `false` |  |
| replicaCount | int | `1` |  |
| resources.limits.cpu | string | `"500m"` |  |
| resources.limits.memory | string | `"512Mi"` |  |
| resources.requests.cpu | string | `"250m"` |  |
| resources.requests.memory | string | `"250Mi"` |  |
| scylla-operator.fullnameOverride | string | `"scylla-operator"` |  |
| scylla-operator.webhook.enabled | bool | `true` |  |
| scylla.datacenter | string | `"dc1"` |  |
| scylla.developerMode | bool | `true` |  |
| scylla.enabled | bool | `true` |  |
| scylla.fullnameOverride | string | `"scylla"` |  |
| scylla.racks[0].agentResources.requests.cpu | string | `"50m"` |  |
| scylla.racks[0].agentResources.requests.memory | string | `"10M"` |  |
| scylla.racks[0].members | int | `3` |  |
| scylla.racks[0].name | string | `"rack1"` |  |
| scylla.racks[0].placement.nodeAffinity | object | `{}` |  |
| scylla.racks[0].placement.tolerations | list | `[]` |  |
| scylla.racks[0].resources.limits.cpu | int | `2` |  |
| scylla.racks[0].resources.limits.memory | string | `"4Gi"` |  |
| scylla.racks[0].resources.requests.cpu | int | `1` |  |
| scylla.racks[0].resources.requests.memory | string | `"2Gi"` |  |
| scylla.racks[0].storage.capacity | string | `"100Gi"` |  |
| scylla.racks[0].storage.storageClassName | string | `"scylladb"` |  |
| scylla.scyllaImage.tag | string | `"2025.1.5"` |  |
| scylla.storageClass.allowVolumeExpansion | bool | `true` |  |
| scylla.storageClass.create | bool | `true` |  |
| scylla.storageClass.name | string | `"scylladb"` |  |
| scylla.storageClass.parameters.fsType | string | `"ext4"` |  |
| scylla.storageClass.parameters.type | string | `"gp2"` |  |
| scylla.storageClass.provisioner | string | `"ebs.csi.eks.amazonaws.com"` |  |
| scylla.storageClass.reclaimPolicy | string | `"Delete"` |  |
| scylla.storageClass.volumeBindingMode | string | `"WaitForFirstConsumer"` |  |
| scylla.sysctls[0] | string | `"fs.aio-max-nr=30000000"` |  |
| secrets | object | `{}` |  |
| service.connectport | int | `83` |  |
| service.debugport | int | `82` |  |
| service.grpcport | int | `80` |  |
| service.httpport | int | `81` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceProfile.enabled | bool | `false` |  |
| services.artifacts.args[0] | string | `"artifacts"` |  |
| services.artifacts.args[1] | string | `"serve"` |  |
| services.artifacts.args[2] | string | `"--config"` |  |
| services.artifacts.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.artifacts.configMap.artifactsConfig.app.adminClient.hackFlagUntilCellIsolation | bool | `true` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactBlobStoreConfig.container | string | `"{{ .Values.global.ARTIFACTS_BUCKET_NAME }}"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactBlobStoreConfig.stow.config.auth_type | string | `"iam"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactBlobStoreConfig.stow.config.region | string | `"{{ .Values.global.AWS_REGION }}"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactBlobStoreConfig.stow.kind | string | `"s3"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactBlobStoreConfig.type | string | `"stow"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.connMaxLifeTime | string | `"1m"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.maxIdleConnections | int | `20` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.maxOpenConnections | int | `30` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.dbname | string | `"{{ .Values.global.DB_NAME }}"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.options | string | `"sslmode=disable"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.passwordPath | string | `"/etc/db/pass.txt"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.port | int | `5432` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.readReplicaHost | string | `"{{ .Values.global.DB_HOST }}"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactDatabaseConfig.postgres.username | string | `"{{ .Values.global.DB_USER }}"` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactServerConfig.httpPort | int | `8089` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactServerConfig.port | int | `8080` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactServerConfig.respectUserOrgsForServerless | bool | `true` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.executionMaxRetryCount | int | `3` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.executionSchedulerQuerySize | int | `20` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.executionSchedulers | int | `1` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.executionSchedulersWait | int | `10` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.triggerProcessorQuerySize | int | `100` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.triggerProcessors | int | `1` |  |
| services.artifacts.configMap.artifactsConfig.app.artifactTriggerConfig.triggerProcessorsWait | int | `10` |  |
| services.artifacts.configMap.db.connectionPool.maxConnectionLifetime | string | `"1m"` |  |
| services.artifacts.configMap.db.connectionPool.maxIdleConnections | int | `20` |  |
| services.artifacts.configMap.db.connectionPool.maxOpenConnections | int | `20` |  |
| services.artifacts.configMap.db.dbname | string | `"{{ .Values.global.DB_NAME }}"` |  |
| services.artifacts.configMap.db.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| services.artifacts.configMap.db.options | string | `"sslmode=disable"` |  |
| services.artifacts.configMap.db.passwordPath | string | `"/etc/db/pass.txt"` |  |
| services.artifacts.configMap.db.port | int | `5432` |  |
| services.artifacts.configMap.db.username | string | `"{{ .Values.global.DB_USER }}"` |  |
| services.artifacts.configMap.sharedService.metrics.scope | string | `"artifacts:"` |  |
| services.artifacts.disabled | bool | `true` |  |
| services.artifacts.fullnameOverride | string | `"artifacts"` |  |
| services.artifacts.initContainers[0].args[0] | string | `"artifacts"` |  |
| services.artifacts.initContainers[0].args[1] | string | `"migrate"` |  |
| services.artifacts.initContainers[0].args[2] | string | `"--config"` |  |
| services.artifacts.initContainers[0].args[3] | string | `"/etc/config/*.yaml"` |  |
| services.artifacts.initContainers[0].name | string | `"migrate"` |  |
| services.authorizer.args[0] | string | `"authorizer"` |  |
| services.authorizer.args[1] | string | `"serve"` |  |
| services.authorizer.args[2] | string | `"--config"` |  |
| services.authorizer.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.authorizer.configMap.sharedService.connectPort | int | `8081` |  |
| services.authorizer.configMap.sharedService.metrics.scope | string | `"authorizer:"` |  |
| services.authorizer.fullnameOverride | string | `"authorizer"` |  |
| services.cluster.args[0] | string | `"cloudcluster"` |  |
| services.cluster.args[1] | string | `"serve"` |  |
| services.cluster.args[2] | string | `"--config"` |  |
| services.cluster.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.cluster.configMap.cloudProvider.provider | string | `"Mock"` |  |
| services.cluster.configMap.cluster.cloudflare.active | bool | `false` |  |
| services.cluster.configMap.db.connectionPool.maxConnectionLifetime | string | `"1m"` |  |
| services.cluster.configMap.db.connectionPool.maxIdleConnections | int | `20` |  |
| services.cluster.configMap.db.connectionPool.maxOpenConnections | int | `20` |  |
| services.cluster.configMap.db.dbname | string | `"{{ .Values.global.DB_NAME }}"` |  |
| services.cluster.configMap.db.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| services.cluster.configMap.db.passwordPath | string | `"/etc/db/pass.txt"` |  |
| services.cluster.configMap.db.port | int | `5432` |  |
| services.cluster.configMap.db.username | string | `"{{ .Values.global.DB_USER }}"` |  |
| services.cluster.configMap.sharedService.metrics.scope | string | `"cluster:"` |  |
| services.cluster.fullnameOverride | string | `"cluster"` |  |
| services.cluster.initContainers[0].args[0] | string | `"cloudcluster"` |  |
| services.cluster.initContainers[0].args[1] | string | `"migrate"` |  |
| services.cluster.initContainers[0].args[2] | string | `"--config"` |  |
| services.cluster.initContainers[0].args[3] | string | `"/etc/config/*.yaml"` |  |
| services.cluster.initContainers[0].name | string | `"migrate"` |  |
| services.dataproxy.args[0] | string | `"dataproxy"` |  |
| services.dataproxy.args[1] | string | `"serve"` |  |
| services.dataproxy.args[2] | string | `"--config"` |  |
| services.dataproxy.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.dataproxy.configMap.dataproxy.clusterSelector.type | string | `"local"` |  |
| services.dataproxy.configMap.dataproxy.secureTunnelTenantURLPattern | string | `"http://ingress-nginx-internal.ingress-nginx.svc.cluster.local:80"` |  |
| services.dataproxy.configMap.sharedService.metrics.scope | string | `"dataproxy:"` |  |
| services.dataproxy.fullnameOverride | string | `"dataproxy"` |  |
| services.executions.args[0] | string | `"cloudpropeller"` |  |
| services.executions.args[1] | string | `"serve"` |  |
| services.executions.args[2] | string | `"--config"` |  |
| services.executions.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.executions.configMap.cloudEventsProcessor.cloudProvider | string | `"Local"` |  |
| services.executions.configMap.db.connectionPool.maxConnectionLifetime | string | `"1m"` |  |
| services.executions.configMap.db.connectionPool.maxIdleConnections | int | `20` |  |
| services.executions.configMap.db.connectionPool.maxOpenConnections | int | `20` |  |
| services.executions.configMap.db.dbname | string | `"{{ .Values.global.DB_NAME }}"` |  |
| services.executions.configMap.db.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| services.executions.configMap.db.passwordPath | string | `"/etc/db/pass.txt"` |  |
| services.executions.configMap.db.port | int | `5432` |  |
| services.executions.configMap.db.username | string | `"{{ .Values.global.DB_USER }}"` |  |
| services.executions.configMap.executions.apps | object | `{"enrichIdentities":false,"publicURLPattern":"https://%s.apps.{{ .Values.global.UNION_HOST }}"}` | Skip TLS verification for self-signed certs. Should be true only for local testing. insecureSkipVerify: true|false |
| services.executions.configMap.executions.llm.enabled | bool | `false` |  |
| services.executions.configMap.executions.task.enabled | bool | `true` |  |
| services.executions.configMap.executions.task.enrichIdentities | bool | `false` |  |
| services.executions.configMap.sharedService.metrics.scope | string | `"executions:"` |  |
| services.executions.configMap.workspace.enable | bool | `false` |  |
| services.executions.fullnameOverride | string | `"executions"` |  |
| services.executions.initContainers[0].args[0] | string | `"cloudpropeller"` |  |
| services.executions.initContainers[0].args[1] | string | `"migrate"` |  |
| services.executions.initContainers[0].args[2] | string | `"--config"` |  |
| services.executions.initContainers[0].args[3] | string | `"/etc/config/*.yaml"` |  |
| services.executions.initContainers[0].name | string | `"migrate"` |  |
| services.queue.args[0] | string | `"queue"` |  |
| services.queue.args[1] | string | `"serve"` |  |
| services.queue.args[2] | string | `"--config"` |  |
| services.queue.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.queue.autoscaling.enabled | bool | `false` |  |
| services.queue.configMap.queue.db.hosts[0] | string | `"{{ .Values.scylla.fullnameOverride }}-client.{{ .Release.Namespace }}.svc.cluster.local"` |  |
| services.queue.configMap.queue.db.threadCount | int | `64` |  |
| services.queue.configMap.queue.db.type | string | `"cql"` |  |
| services.queue.configMap.queue.eventer.recordActionThreadCount | int | `16` |  |
| services.queue.configMap.queue.eventer.type | string | `"runservice"` |  |
| services.queue.configMap.queue.eventer.updateActionStatusThreadCount | int | `16` |  |
| services.queue.configMap.sharedService.metrics.scope | string | `"queue:"` |  |
| services.queue.fullnameOverride | string | `"queue"` |  |
| services.queue.initContainers[0].args[0] | string | `"queue"` |  |
| services.queue.initContainers[0].args[1] | string | `"migrate"` |  |
| services.queue.initContainers[0].args[2] | string | `"--config"` |  |
| services.queue.initContainers[0].args[3] | string | `"/etc/config/*.yaml"` |  |
| services.queue.initContainers[0].name | string | `"migrate"` |  |
| services.queue.replicaCount | int | `1` |  |
| services.run-scheduler.args[0] | string | `"cloudpropeller"` |  |
| services.run-scheduler.args[1] | string | `"scheduler"` |  |
| services.run-scheduler.args[2] | string | `"start"` |  |
| services.run-scheduler.args[3] | string | `"--config"` |  |
| services.run-scheduler.args[4] | string | `"/etc/config/*.yaml"` |  |
| services.run-scheduler.configMap.db.connectionPool.maxConnectionLifetime | string | `"1m"` |  |
| services.run-scheduler.configMap.db.connectionPool.maxIdleConnections | int | `20` |  |
| services.run-scheduler.configMap.db.connectionPool.maxOpenConnections | int | `20` |  |
| services.run-scheduler.configMap.db.dbname | string | `"{{ .Values.global.DB_NAME }}"` |  |
| services.run-scheduler.configMap.db.host | string | `"{{ .Values.global.DB_HOST }}"` |  |
| services.run-scheduler.configMap.db.passwordPath | string | `"/etc/db/pass.txt"` |  |
| services.run-scheduler.configMap.db.port | int | `5432` |  |
| services.run-scheduler.configMap.db.username | string | `"{{ .Values.global.DB_USER }}"` |  |
| services.run-scheduler.configMap.sharedService.metrics.scope | string | `"run-scheduler:"` |  |
| services.run-scheduler.fullnameOverride | string | `"run-scheduler"` |  |
| services.run-scheduler.initContainers[0].args[0] | string | `"cloudpropeller"` |  |
| services.run-scheduler.initContainers[0].args[1] | string | `"migrate"` |  |
| services.run-scheduler.initContainers[0].args[2] | string | `"--config"` |  |
| services.run-scheduler.initContainers[0].args[3] | string | `"/etc/config/*.yaml"` |  |
| services.run-scheduler.initContainers[0].name | string | `"migrate"` |  |
| services.usage.args[0] | string | `"usage"` |  |
| services.usage.args[1] | string | `"serve"` |  |
| services.usage.args[2] | string | `"--config"` |  |
| services.usage.args[3] | string | `"/etc/config/*.yaml"` |  |
| services.usage.configMap.billing.enable | bool | `false` |  |
| services.usage.configMap.cloudProvider.provider | string | `"Mock"` |  |
| services.usage.configMap.sharedService.metrics.scope | string | `"usage:"` |  |
| services.usage.configMap.usage.taskMetrics.agentQuery.mappings.dgx_job.queries.EXECUTION_METRIC_ALLOCATED_CPU_AVG | string | `"CPU_ALLOCATION:MEAN"` |  |
| services.usage.configMap.usage.taskMetrics.agentQuery.mappings.dgx_job.queries.EXECUTION_METRIC_ALLOCATED_MEMORY_BYTES_AVG | string | `"MEM_ALLOCATION:MEAN"` |  |
| services.usage.configMap.usage.taskMetrics.agentQuery.mappings.dgx_job.queries.EXECUTION_METRIC_CPU_UTILIZATION | string | `"CPU_UTILIZATION:MEAN"` |  |
| services.usage.configMap.usage.taskMetrics.agentQuery.mappings.dgx_job.queries.EXECUTION_METRIC_GPU_UTILIZATION | string | `"GPU_UTILIZATION:MEAN"` |  |
| services.usage.configMap.usage.taskMetrics.agentQuery.mappings.dgx_job.queries.EXECUTION_METRIC_MEMORY_UTILIZATION | string | `"MEM_UTILIZATION:MEAN"` |  |
| services.usage.configMap.usage.taskMetrics.metricDelayToleranceDuration | string | `"0s"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_ALLOCATED_CPU_AVG | string | `"max by (namespace, pod) (\n  (\n    sum by (namespace, pod) (irate(container_cpu_usage_seconds_total{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",image!=\"\"}[5m])) >\n    sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"cpu\"})\n  )\n  or\n  sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"cpu\"})\n) *\non (namespace, pod) group_left max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_ALLOCATED_MEMORY_BYTES_AVG | string | `"max by (namespace, pod) (\n  (\n    sum by (namespace, pod) (container_memory_working_set_bytes{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",image!=\"\"}) >\n    sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"memory\"})\n  )\n  or\n  sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"memory\"})\n) *\non (namespace, pod) group_left max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_APP_REPLICA_COUNT | string | `"sum (kube_pod_status_phase{phase=~\"Running|Pending\", namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\", pod=~\"{{ \"{{\" }}.AppName{{ \"}}\" }}.*\"} == 1) or vector(0)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_APP_REQUESTS | string | `"sum(rate((\n  envoy_cluster_upstream_rq_xx{\n    job=\"serving-envoy\",\n    project=~\"{{ \"{{\" }}.Project{{ \"}}\" }}\",\n    domain=~\"{{ \"{{\" }}.Domain{{ \"}}\" }}\",\n    name=~\"{{ \"{{\" }}.AppName{{ \"}}\" }}\",\n    name!=\"\"}\n)[5m:])) by (project, domain, name, envoy_response_code_class)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_APP_RESPONSE_TIME_P50 | string | `"histogram_quantile(0.5, sum(rate((\n  envoy_cluster_upstream_rq_time_bucket{\n    job=\"serving-envoy\",\n    project=~\"${{ \"{{\" }}.Project{{ \"}}\" }}\",\n    domain=~\"{{ \"{{\" }}.Domain{{ \"}}\" }}\",\n    name=~\"{{ \"{{\" }}.AppName{{ \"}}\" }}\",\n    name!=\"\"}\n)[5m:])) by (project, domain, name, le))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_APP_RESPONSE_TIME_P90 | string | `"histogram_quantile(0.90, sum(rate((\n  envoy_cluster_upstream_rq_time_bucket{\n    job=\"serving-envoy\",\n    project=~\"${{ \"{{\" }}.Project{{ \"}}\" }}\",\n    domain=~\"{{ \"{{\" }}.Domain{{ \"}}\" }}\",\n    name=~\"{{ \"{{\" }}.AppName{{ \"}}\" }}\",\n    name!=\"\"}\n)[5m:])) by (project, domain, name, le))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_APP_RESPONSE_TIME_P95 | string | `"histogram_quantile(0.95, sum(rate((\n  envoy_cluster_upstream_rq_time_bucket{\n    job=\"serving-envoy\",\n    project=~\"${{ \"{{\" }}.Project{{ \"}}\" }}\",\n    domain=~\"{{ \"{{\" }}.Domain{{ \"}}\" }}\",\n    name=~\"{{ \"{{\" }}.AppName{{ \"}}\" }}\",\n    name!=\"\"}\n)[5m:])) by (project, domain, name, le))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_CPU_UTILIZATION | string | `"(sum by (namespace, pod) (irate(container_cpu_usage_seconds_total{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",image!=\"\"}[5m])) /\n  sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"cpu\"})) *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_GPU_FRAME_BUFFER_UTILIZATION | string | `"(sum by (namespace, pod, gpu) (DCGM_FI_DEV_FB_USED{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"}) /\n  sum by (namespace, pod, gpu) (DCGM_FI_DEV_FB_USED{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"} + DCGM_FI_DEV_FB_FREE{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"})) *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_GPU_MEMORY_UTILIZATION | string | `"sum by (gpu) (DCGM_FI_DEV_MEM_COPY_UTIL{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)) / 100.0\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_GPU_SM_ACTIVE | string | `"sum by (gpu) (DCGM_FI_PROF_SM_ACTIVE{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_GPU_SM_OCCUPANCY | string | `"sum by (gpu) (DCGM_FI_PROF_SM_OCCUPANCY{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_GPU_UTILIZATION | string | `"sum by (gpu) (DCGM_FI_DEV_GPU_UTIL{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)) / 100.0\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_LIMIT_CPU | string | `"sum by (namespace, pod) (kube_pod_container_resource_limits{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"cpu\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_LIMIT_MEMORY_BYTES | string | `"sum by (namespace, pod) (kube_pod_container_resource_limits{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"memory\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_MEMORY_UTILIZATION | string | `"(sum by (namespace, pod) (container_memory_working_set_bytes{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",image!=\"\"}) /\n  sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"memory\"})) *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1)\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_REQUEST_CPU | string | `"sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"cpu\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_REQUEST_MEMORY_BYTES | string | `"sum by (namespace, pod) (kube_pod_container_resource_requests{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",resource=\"memory\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_USED_CPU_AVG | string | `"sum by (namespace, pod) (irate(container_cpu_usage_seconds_total{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",image!=\"\"}[5m]) *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.taskMetrics.promQuery.queries.EXECUTION_METRIC_USED_MEMORY_BYTES_AVG | string | `"sum by (namespace, pod) (container_memory_working_set_bytes{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",image!=\"\"} *\non (namespace, pod) group_left() max by (namespace, pod) (kube_pod_status_phase{namespace=\"{{ \"{{\" }}.Namespace{{ \"}}\" }}\",pod=~\"{{ \"{{\" }}.PodName{{ \"}}\" }}\",phase=~\"Pending|Running\"} == 1))\n"` |  |
| services.usage.configMap.usage.workers | int | `10` |  |
| services.usage.fullnameOverride | string | `"usage"` |  |
| services.usage.resources.limits.cpu | int | `3` |  |
| services.usage.resources.limits.memory | string | `"512Mi"` |  |
| services.usage.resources.requests.cpu | string | `"500m"` |  |
| services.usage.resources.requests.memory | string | `"250Mi"` |  |
| spreadConstraints.enabled | bool | `false` |  |
| strategy.rollingUpdate.maxSurge | int | `1` |  |
| strategy.rollingUpdate.maxUnavailable | int | `1` |  |
| strategy.type | string | `"RollingUpdate"` |  |
| unionv2.enabled | bool | `false` |  |

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

Reference guides are also available in this repository:
- [AWS](SELFHOSTED_INTRA_CLUSTER_AWS.md)
- [GCP](SELFHOSTED_INTRA_CLUSTER_GCP.md)

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
