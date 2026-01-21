# Self-Hosted Intra-Cluster Deployment Guide (GCP)

This guide covers deploying Union dataplane in the **same Kubernetes cluster** as your Union control plane (co-located deployment). This is ideal for fully self-hosted Union deployments where both control plane and dataplane run in your infrastructure.

**Important**: This guide covers dataplane-specific configuration. For control plane setup in the same cluster, see the [Control Plane Intra-Cluster Guide](../controlplane/SELFHOSTED_INTRA_CLUSTER_GCP.md).

## Benefits of Intra-Cluster Deployment

- **Simplified networking**: All communication stays within the cluster
- **No external dependencies**: No Cloudflare tunnel or external networking required
- **Cost-effective**: Reduced network egress costs
- **Self-signed certificates**: Can use self-signed certs for intra-cluster TLS
- **Direct service-to-service**: No OAuth/API key authentication needed
- **Full data sovereignty**: All data and control remains in your infrastructure

## When to Use This Deployment Model

Choose intra-cluster deployment when:

- You want full control over both control plane and dataplane
- You're running in a single Kubernetes cluster
- You don't need Union's managed control plane services
- You want to minimize network egress costs
- You have strict data locality requirements

Choose standard BYOC deployment when:

- Using Union's managed control plane (Union Cloud/BYOC)
- Control plane and dataplane are in separate clusters
- You need Union's managed services and support

## Prerequisites

In addition to the standard prerequisites, you need:

1. **Kubernetes cluster** (>= 1.28.0) with sufficient resources for both control plane and dataplane
2. **Union control plane** deployed in the same cluster:
   - **If not yet deployed**: Follow the [Control Plane Intra-Cluster Guide](../controlplane/SELFHOSTED_INTRA_CLUSTER_GCP.md) first
   - **If already running**: Note the namespace (typically `union-cp`) and service endpoints
3. **Network connectivity** between dataplane and control plane namespaces (verify network policies)
4. **GCS buckets** for metadata storage (same as standard deployment)
5. **GCP service accounts** configured with Workload Identity (same as standard deployment)

## Installation Steps

### Step 1: Install Dataplane CRDs

```bash
helm upgrade --install unionai-dataplane-crds unionai/dataplane-crds \
  --namespace union \
  --create-namespace
```

### Step 2: Create Registry Image Pull Secret

Union hosts dataplane images in a private registry. You will receive registry credentials (username and password) from the Union team for your organization.

Create the registry secret in the `union` namespace:

```bash
# Create namespace if it doesn't exist
kubectl create namespace union

# Create registry image pull secret
# Replace <REGISTRY_USERNAME> and <REGISTRY_PASSWORD> with credentials provided by Union
kubectl create secret docker-registry union-registry-secret \
  --docker-server="registry.unionai.cloud" \
  --docker-username="<REGISTRY_USERNAME>" \
  --docker-password="<REGISTRY_PASSWORD>" \
  -n union
```

**Example** (for a customer named "acme-corp"):
```bash
kubectl create secret docker-registry union-registry-secret \
  --docker-server="registry.unionai.cloud" \
  --docker-username="robot\$acme-corp" \
  --docker-password="LkkciLfd8fUCsaEKrN4x5VeOxh8RNIvn" \
  -n union
```

**Important notes:**
- The registry username typically follows the format `robot$<org-name>`
- Note the backslash escape (`\$`) before the `$` character in the username
- This secret allows Kubernetes to pull dataplane images from Union's private registry
- Contact Union support if you haven't received your registry credentials

### Step 3: Download Values Files

Download the required values files from the Union Helm charts repository:

```bash
# Download GCP infrastructure configuration
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/dataplane/values.gcp.selfhosted-intracluster.yaml

# Download registry configuration
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/dataplane/values.registry.yaml
```

Create your environment-specific overrides file `values.gcp.selfhosted-customer.yaml` with your configuration (see example below).

### Step 4: Install Dataplane

Install the dataplane using layered values files:

```bash
helm upgrade --install unionai-dataplane unionai/dataplane \
  --namespace union \
  --create-namespace \
  -f values.gcp.selfhosted-intracluster.yaml \
  -f values.registry.yaml \
  -f values.gcp.selfhosted-customer.yaml \
  --timeout 10m \
  --wait
```

**Values file layers (applied in order):**

1. **`values.gcp.selfhosted-intracluster.yaml`** - GCP infrastructure defaults (storage, networking, intra-cluster communication)
2. **`values.registry.yaml`** - Registry configuration and image pull secrets
3. **`values.gcp.selfhosted-customer.yaml`** - Your environment-specific overrides (see example below)

**Example customer overrides file (`values.gcp.selfhosted-customer.yaml`):**

```yaml
global:
  CLUSTER_NAME: "prod-us-central1"
  ORG_NAME: "my-company"
  METADATA_BUCKET: "my-company-dp-metadata"
  FAST_REGISTRATION_BUCKET: "my-company-dp-metadata"
  GCP_REGION: "us-central1"
  GOOGLE_PROJECT_ID: "my-gcp-project"
  BACKEND_IAM_ROLE_ARN: "union-backend@my-project.iam.gserviceaccount.com"
  WORKER_IAM_ROLE_ARN: "union-worker@my-project.iam.gserviceaccount.com"
  CONTROLPLANE_INTRA_CLUSTER_HOST: "controlplane-nginx-controller.union-cp.svc.cluster.local"
  QUEUE_SERVICE_HOST: "queue.union-cp.svc.cluster.local:80"
  CACHESERVICE_ENDPOINT: "cacheservice.union-cp.svc.cluster.local:89"
```

**Important notes:**

- Uses **published chart** (`unionai/dataplane`) from Helm repository
- Layered approach separates infrastructure config, registry config, and customer overrides
- Easier to maintain and update - change images in one file, infrastructure in another

### Step 5: Verify Intra-Cluster Communication

```bash
# Check that dataplane pods are running
kubectl get pods -n union

# Verify connectivity to control plane
kubectl logs -n union -l app.kubernetes.io/name=operator --tail=50 | grep "connection"

# Check that services can resolve control plane endpoints
kubectl exec -n union deploy/unionai-dataplane-operator -- \
  nslookup controlplane-nginx-controller.union-cp.svc.cluster.local
```

## Key Differences from Standard Deployment

| Feature                | Standard BYOC                                | Intra-Cluster Self-Hosted           |
| ---------------------- | -------------------------------------------- | ----------------------------------- |
| Control plane location | External (Union-managed or separate cluster) | Same Kubernetes cluster             |
| Network path           | Internet or VPN                              | Kubernetes internal networking      |
| Authentication         | OAuth2 with client credentials               | Direct service-to-service (no auth) |
| Cloudflare tunnel      | Required                                     | Disabled                            |
| TLS certificates       | Trusted CA certificates                      | Can use self-signed certificates    |
| API keys               | Required                                     | Not used                            |
| Ingress type           | LoadBalancer (external)                      | ClusterIP (internal)                |

## Troubleshooting

### Cannot resolve control plane services

```bash
# Check DNS resolution from dataplane namespace
kubectl run -n union test-dns --image=busybox --rm -it -- \
  nslookup controlplane-nginx-controller.union-cp.svc.cluster.local

# If resolution fails, verify the service exists
kubectl get svc -n union-cp | grep nginx-controller

# Check if you're using the correct namespace
kubectl get svc --all-namespaces | grep nginx-controller
```

### Connection refused errors

- Verify control plane namespace is correct (default: `union-cp`)
- Check that control plane services are running: `kubectl get svc -n union-cp`
- Ensure control plane pods are ready: `kubectl get pods -n union-cp`
- Verify network policies allow traffic between namespaces:

  ```bash
  kubectl get networkpolicies -n union
  kubectl get networkpolicies -n union-cp
  ```

### Certificate verification errors

- If using self-signed certificates, ensure `insecureSkipVerify: true` is set in `values.gcp.selfhosted-intracluster.yaml`
- Check the `_U_INSECURE_SKIP_VERIFY` environment variable in task pods
- Verify control plane is using self-signed certs: `kubectl get secret -n union-cp`

### Dataplane cannot authenticate to control plane

- Verify `auth.enable: false` is set in the intra-cluster config
- Check that `secrets.admin.create: false` is set (no OAuth credentials needed)
- Ensure control plane is configured to accept unauthenticated intra-cluster requests

### Workload Identity issues

- Verify service account annotations:

  ```bash
  kubectl get sa -n union -o yaml | grep iam.gke.io/gcp-service-account
  ```

- Check IAM bindings for backend and worker service accounts:

  ```bash
  gcloud iam service-accounts get-iam-policy <BACKEND_SERVICE_ACCOUNT_EMAIL>
  gcloud iam service-accounts get-iam-policy <WORKER_SERVICE_ACCOUNT_EMAIL>
  ```

- Verify pod can authenticate:

  ```bash
  kubectl exec -n union deploy/unionai-dataplane-operator -- \
    curl -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
  ```

- Check GCS bucket permissions:

  ```bash
  # From within a dataplane pod
  kubectl exec -n union deploy/unionai-dataplane-operator -- \
    gsutil ls gs://<METADATA_BUCKET>/
  ```

### GCS access issues

- Verify bucket exists:

  ```bash
  gsutil ls -b gs://<METADATA_BUCKET>
  ```

- Check bucket IAM permissions:

  ```bash
  gsutil iam get gs://<METADATA_BUCKET>
  ```

- Ensure service accounts have proper roles:
  - Backend service account needs `roles/storage.objectAdmin` or similar
  - Worker service account needs read/write access to metadata bucket

## Reference Configuration Files

- [values.gcp.yaml](values.gcp.yaml) - Standard GCP configuration (for hosted control plane deployments)
- [values.gcp.selfhosted-intracluster.yaml](values.gcp.selfhosted-intracluster.yaml) - Self-contained intra-cluster configuration

## Additional Resources

- [Main Installation Guide](README.md) - Standard BYOC deployment
- [Control Plane Installation Guide](../controlplane/README.md) - Control plane setup
- [Union Documentation](https://docs.union.ai) - Full documentation
- [GKE Workload Identity Documentation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
