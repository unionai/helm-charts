# Self-Hosted Intra-Cluster Deployment Guide (AWS)

This guide covers deploying Union dataplane in the **same Kubernetes cluster** as your Union control plane (co-located deployment). This is ideal for fully self-hosted Union deployments where both control plane and dataplane run in your infrastructure.

**Important**: This guide covers dataplane-specific configuration. For control plane setup in the same cluster, see the [Control Plane Intra-Cluster Guide](../controlplane/SELFHOSTED_INTRA_CLUSTER_AWS.md).

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
   - **If not yet deployed**: Follow the [Control Plane Intra-Cluster Guide](../controlplane/SELFHOSTED_INTRA_CLUSTER_AWS.md) first
   - **If already running**: Note the namespace (typically `union-cp`) and service endpoints
3. **Network connectivity** between dataplane and control plane namespaces (verify network policies)
4. **S3 buckets** for metadata storage (same as standard deployment)
5. **IAM roles** configured with IRSA (same as standard deployment)

## Installation Steps

### Step 1: Install Dataplane CRDs

```bash
helm upgrade --install unionai-dataplane-crds unionai/dataplane-crds \
  --namespace union \
  --create-namespace
```

### Step 2: Create Harbor Image Pull Secret

Union hosts dataplane images in a private Harbor registry. You will receive Harbor credentials (username and password) from the Union team for your organization.

Create the Harbor secret in the `union` namespace:

```bash
# Create namespace if it doesn't exist
kubectl create namespace union

# Create Harbor image pull secret
# Replace <HARBOR_USERNAME> and <HARBOR_PASSWORD> with credentials provided by Union
kubectl create secret docker-registry harbor-secret \
  --docker-server="registry.unionai.cloud" \
  --docker-username="<HARBOR_USERNAME>" \
  --docker-password="<HARBOR_PASSWORD>" \
  -n union
```

**Example** (for a customer named "acme-corp"):
```bash
kubectl create secret docker-registry harbor-secret \
  --docker-server="registry.unionai.cloud" \
  --docker-username="robot\$acme-corp" \
  --docker-password="LkkciLfd8fUCsaEKrN4x5VeOxh8RNIvn" \
  -n union
```

**Important notes:**
- The Harbor username typically follows the format `robot$<org-name>`
- Note the backslash escape (`\$`) before the `$` character in the username
- This secret allows Kubernetes to pull dataplane images from Union's private registry
- Contact Union support if you haven't received your Harbor credentials

### Step 3: Download Values Files

Download the required values files from the Union Helm charts repository:

```bash
# Download AWS infrastructure configuration
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/dataplane/values.aws.selfhosted-intracluster.yaml

# Download registry configuration for Harbor
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/dataplane/values.registry.yaml
```

Create your environment-specific overrides file `values.aws.selfhosted-customer.yaml` with your configuration (see example below).

### Step 4: Install Dataplane

Install the dataplane using layered values files:

```bash
helm upgrade --install unionai-dataplane unionai/dataplane \
  --namespace union \
  --create-namespace \
  -f values.aws.selfhosted-intracluster.yaml \
  -f values.registry.yaml \
  -f values.aws.selfhosted-customer.yaml \
  --timeout 10m \
  --wait
```

**Values file layers (applied in order):**

1. **`values.aws.selfhosted-intracluster.yaml`** - AWS infrastructure defaults (storage, networking, intra-cluster communication)
2. **`values.registry.yaml`** - Harbor registry and image pull secrets
3. **`values.aws.selfhosted-customer.yaml`** - Your environment-specific overrides (see example below)

**Example customer overrides file (`values.aws.selfhosted-customer.yaml`):**

```yaml
global:
  CLUSTER_NAME: "prod-us-east-1"
  ORG_NAME: "my-company"
  METADATA_BUCKET: "my-company-dp-metadata"
  FAST_REGISTRATION_BUCKET: "my-company-dp-metadata"
  AWS_REGION: "us-east-1"
  BACKEND_IAM_ROLE_ARN: "arn:aws:iam::123456789012:role/union-backend"
  WORKER_IAM_ROLE_ARN: "arn:aws:iam::123456789012:role/union-worker"
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

- If using self-signed certificates, ensure `insecureSkipVerify: true` is set in `values.aws.selfhosted-intracluster.yaml`
- Check the `_U_INSECURE_SKIP_VERIFY` environment variable in task pods
- Verify control plane is using self-signed certs: `kubectl get secret -n union-cp`

### Dataplane cannot authenticate to control plane

- Verify `auth.enable: false` is set in the intra-cluster config
- Check that `secrets.admin.create: false` is set (no OAuth credentials needed)
- Ensure control plane is configured to accept unauthenticated intra-cluster requests

## Reference Configuration Files

- [values.aws.yaml](values.aws.yaml) - Standard AWS configuration (for hosted control plane deployments)
- [values.aws.selfhosted-intracluster.yaml](values.aws.selfhosted-intracluster.yaml) - Self-contained intra-cluster configuration

## Additional Resources

- [Main Installation Guide](README.md) - Standard BYOC deployment
- [Control Plane Installation Guide](../controlplane/README.md) - Control plane setup
- [Union Documentation](https://docs.union.ai) - Full documentation
