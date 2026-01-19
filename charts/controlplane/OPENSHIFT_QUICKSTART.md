# OpenShift Control Plane Quick Start Guide

## Using Existing PostgreSQL and S3-Compatible Storage (Recommended)

This is the **default configuration** in `values.openshift.selfhosted-intracluster.yaml`.

### Prerequisites

You must have:
- ✅ PostgreSQL instance accessible from OpenShift cluster
- ✅ S3-compatible storage (MinIO, S3, etc.) accessible from OpenShift cluster
- ✅ Required databases created in PostgreSQL
- ✅ Required buckets created in S3-compatible storage

### Required PostgreSQL Databases

Create these databases before installation:

```sql
CREATE DATABASE unionai;
CREATE DATABASE flyteadmin;
CREATE DATABASE datacatalog;
CREATE DATABASE cacheservice;
```

### Required S3-Compatible Storage Buckets

Create these buckets before installation:
- `union-controlplane-metadata`
- `union-controlplane-artifacts`

### Configuration

Edit `values.openshift.selfhosted-intracluster.yaml`:

```yaml
# Disable chart-managed PostgreSQL and MinIO (default)
postgresql:
  enabled: false

minio:
  enabled: false

# Configure connection to existing services
global:
  # PostgreSQL connection
  DB_HOST: "postgresql.databases.svc.cluster.local"
  DB_PORT: 5432
  DB_NAME: "unionai"
  DB_USER: "unionai"

  # S3-compatible storage connection
  STORAGE_ENDPOINT: "minio.storage.svc.cluster.local:9000"
  STORAGE_ACCESS_KEY: "minio-admin"
  STORAGE_SECRET_KEY: "minio-password"
  BUCKET_NAME: "union-controlplane-metadata"
  ARTIFACTS_BUCKET_NAME: "union-controlplane-artifacts"

  # Other required settings...
  UNION_ORG: "my-organization"
  # ... etc
```

### Installation

```bash
# 1. Create namespace
oc create namespace union-cp

# 2. Create TLS certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout controlplane-tls.key \
  -out controlplane-tls.crt \
  -subj "/CN=controlplane-nginx-controller.union-cp.svc.cluster.local"

oc create secret tls controlplane-tls-cert \
  --key controlplane-tls.key \
  --cert controlplane-tls.crt \
  -n union-cp

# 3. Create database password secret
oc create secret generic union-controlplane-secrets \
  --from-literal=pass.txt='YOUR_POSTGRESQL_PASSWORD' \
  -n union-cp

# 4. Update helm dependencies
helm dependency update charts/controlplane

# 5. Install control plane
helm install unionai-controlplane charts/controlplane \
  -n union-cp \
  -f charts/controlplane/values.openshift.selfhosted-intracluster.yaml
```

## Using Chart-Deployed PostgreSQL and MinIO

If you don't have existing PostgreSQL/S3-compatible storage or want the chart to manage them.

### Configuration

Edit `values.openshift.selfhosted-intracluster.yaml`:

```yaml
# Enable chart-managed PostgreSQL and MinIO
postgresql:
  enabled: true  # CHANGE to true
  global:
    postgresql:
      auth:
        username: unionai
        password: "STRONG_PASSWORD_HERE"  # CHANGE
        database: unionai
  primary:
    persistence:
      size: 100Gi
      storageClass: "ocs-storagecluster-ceph-rbd"  # Your storage class

minio:
  enabled: true  # CHANGE to true
  auth:
    rootUser: "minio-admin"
    rootPassword: "STRONG_PASSWORD_HERE"  # CHANGE
  persistence:
    size: 500Gi
    storageClass: "ocs-storagecluster-ceph-rbd"  # Your storage class

# Leave these empty - they'll be auto-configured
global:
  DB_HOST: ""  # Auto-configured
  STORAGE_ENDPOINT: ""  # Auto-configured
  STORAGE_CLASS: "ocs-storagecluster-ceph-rbd"  # Set your storage class

  # Still need to configure these
  UNION_ORG: "my-organization"
  # ... etc
```

### Installation

Same as above, but the chart will deploy PostgreSQL and MinIO for you.

## Comparison

| Feature | Existing (Default) | Chart-Deployed |
|---------|-------------------|----------------|
| PostgreSQL | Use yours | Chart deploys |
| S3-compatible Storage | Use yours (MinIO/S3/etc.) | Chart deploys MinIO |
| Storage Requirements | None | ~600GB PVs |
| Setup Complexity | Manual DB/bucket creation | Automatic |
| High Availability | Your responsibility | Optional via chart |
| Best For | Production with existing infra | Quick starts, dev/test |

## Required Configuration Variables

Regardless of deployment mode, you **must** configure these:

```yaml
global:
  # Core settings
  UNION_ORG: ""  # Your organization name
  FLYTEADMIN_ENDPOINT: "flyteadmin.union-cp.svc.cluster.local:81"
  CONTROLPLANE_INTRA_CLUSTER_HOST: "controlplane-nginx-controller.union-cp.svc.cluster.local"
  DATAPLANE_ENDPOINT: "http://dataplane-nginx-controller.union.svc.cluster.local:80"

  # TLS settings
  TLS_SECRET_NAMESPACE: "union-cp"
  TLS_SECRET_NAME: "controlplane-tls-cert"

  # Database settings (if using existing)
  DB_HOST: "postgresql.databases.svc.cluster.local"  # Your PostgreSQL
  DB_USER: "unionai"
  DB_NAME: "unionai"

  # S3-compatible storage settings (if using existing)
  STORAGE_ENDPOINT: "minio.storage.svc.cluster.local:9000"  # Your storage endpoint
  STORAGE_ACCESS_KEY: "minio-admin"  # Your access key
  STORAGE_SECRET_KEY: "minio-password"  # Your secret key
  BUCKET_NAME: "union-controlplane-metadata"
  ARTIFACTS_BUCKET_NAME: "union-controlplane-artifacts"
```

Also update NGINX TLS secret:

```yaml
ingress-nginx:
  controller:
    extraArgs:
      default-ssl-certificate: 'union-cp/controlplane-tls-cert'  # Update this
```

## Verification

After installation:

```bash
# Check all pods are running
oc get pods -n union-cp

# Test PostgreSQL connectivity
oc exec -n union-cp deploy/flyteadmin -- \
  psql -h YOUR_POSTGRES_HOST -U unionai -d unionai -c 'SELECT version();'

# Test S3-compatible storage connectivity
oc exec -n union-cp deploy/flyteadmin -- \
  curl -v http://YOUR_STORAGE_HOST:9000/minio/health/live

# Test internal control plane routing
oc exec -n union-cp deploy/flyteadmin -- \
  curl -k https://controlplane-nginx-controller.union-cp.svc.cluster.local
```

## Troubleshooting

### Database connection failed

```bash
# Check database password secret
oc get secret union-controlplane-secrets -n union-cp -o jsonpath='{.data.pass\.txt}' | base64 -d

# Test connectivity from a pod
oc run -n union-cp test-db --image=postgres:14 --rm -it -- \
  psql -h YOUR_DB_HOST -U unionai -d unionai
```

### S3-compatible storage connection failed

```bash
# Test storage endpoint
oc exec -n union-cp deploy/flyteadmin -- \
  curl -v http://YOUR_STORAGE_HOST:9000/minio/health/live

# Check storage credentials
echo "Access Key: STORAGE_ACCESS_KEY"
echo "Secret Key: STORAGE_SECRET_KEY"
```

## Next Steps

1. ✅ Verify control plane is running
2. ✅ Test database and S3-compatible storage connectivity
3. ➡️ Deploy dataplane (see dataplane documentation)
4. ➡️ Configure user authentication
5. ➡️ Run test workflows

## Documentation

- [Full OpenShift Deployment Guide](SELFHOSTED_INTRA_CLUSTER_OPENSHIFT.md)
- [AWS Deployment Guide](SELFHOSTED_INTRA_CLUSTER_AWS.md) (for comparison)
- [Main README](README.md)
