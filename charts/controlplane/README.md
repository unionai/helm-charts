# controlplane

![Version: 2025.10.0](https://img.shields.io/badge/Version-2025.10.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2025.10.0](https://img.shields.io/badge/AppVersion-2025.10.0-informational?style=flat-square)

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

| Repository | Name | Version | Optional | Notes |
|------------|------|---------|----------|-------|
| https://helm.flyte.org | flyte-core(flyte) | v1.16.0-b2 | No | Required |
| https://kubernetes.github.io/ingress-nginx | ingress-nginx | 4.12.3 | Yes | Only if `ingress-nginx.enabled: true` |
| https://scylla-operator-charts.storage.googleapis.com/stable | scylla-operator | v1.18.1 | Yes | Only if `scylla.enabled: true` |
| https://scylla-operator-charts.storage.googleapis.com/stable | scylla | v1.18.1 | Yes | Only if `scylla.enabled: true` |

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

### Self-Hosted Intra-Cluster Deployment (AWS)

For deploying Union control plane in the **same Kubernetes cluster** as your Union dataplane, see the dedicated guide:

**[Self-Hosted Intra-Cluster Deployment Guide (AWS)](SELFHOSTED_INTRA_CLUSTER_AWS.md)**

This deployment model is ideal for:

- Fully self-hosted Union deployments
- Single-cluster architectures with co-located control plane and dataplane
- Environments requiring simplified networking and reduced costs
- Deployments with strict data sovereignty requirements

The intra-cluster guide covers:

- TLS certificate generation for intra-cluster communication
- Single-tenant mode configuration
- Service discovery between control plane and dataplane
- Complete end-to-end setup for both control plane and dataplane

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
