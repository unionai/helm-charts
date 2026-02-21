# Self-Hosted Intra-Cluster Deployment Guide (GCP)

This guide covers deploying Union control plane in the **same Kubernetes cluster** as your Union dataplane (co-located deployment). This is ideal for fully self-hosted Union deployments where both control plane and dataplane run in your infrastructure.

## Overview

In an intra-cluster deployment, the control plane and dataplane communicate using Kubernetes internal networking rather than external endpoints. This architecture simplifies networking, reduces costs, and provides complete data sovereignty.

**Important**: This guide assumes you will also deploy the dataplane in the same cluster. See the [Dataplane Intra-Cluster Guide](../dataplane/SELFHOST_INTRA_CLUSTER_GCP.md) for dataplane-specific configuration.

## Benefits of Intra-Cluster Deployment

- **Simplified networking**: All communication stays within the cluster
- **No external dependencies**: No internet connectivity required for control plane ↔ dataplane communication
- **Cost-effective**: Reduced network egress costs
- **Self-signed certificates**: Can use self-signed certs for intra-cluster TLS
- **Single-tenant mode**: Simplified security model with explicit organization configuration
- **Full data sovereignty**: All data and control remains in your infrastructure

## When to Use This Deployment Model

Choose intra-cluster deployment when:

- You want full control over both control plane and dataplane
- You're running in a single Kubernetes cluster
- You don't need Union's managed control plane services
- You want to minimize network egress costs
- You have strict data locality requirements

Choose standard hosted deployment when:

- Using Union's managed control plane (Union Cloud)
- Control plane and dataplane are in separate clusters
- You need Union's managed services and support

## Prerequisites

### Infrastructure Requirements

1. **Kubernetes cluster** (>= 1.28.0) with sufficient resources for both control plane and dataplane
   - Recommended: At least 6 nodes with 8 CPU / 16GB RAM each
   - Storage: Ability to create Persistent Volumes for Prometheus and ScyllaDB (if embedded)

2. **PostgreSQL database**:
   - Version: PostgreSQL 12+
   - Can be Cloud SQL or self-hosted in the cluster
   - Required for all control plane services

3. **ScyllaDB** (for queue service):
   - Can be deployed via the Helm chart (embedded) or externally managed
   - Required for high-performance message queueing

4. **GCS buckets**:
   - One for control plane metadata
   - One for artifacts storage (can be same bucket)

5. **GCP service accounts** configured with Workload Identity:
   - Control plane services (with GCS access)
   - Artifacts service (with GCS access)

### Required Tools

- `kubectl` configured to access your cluster
- `helm` 3.18+
- `openssl` or `cert-manager` for TLS certificate generation

### Network Requirements

- Network connectivity between control plane and dataplane namespaces (verify network policies)
- No external ingress required (optional for external access)

## Installation Steps

### Step 1: Install Prerequisites

#### Install ScyllaDB CRDs (if using embedded ScyllaDB)

```bash
cd helm-charts/charts/controlplane
./scripts/install-scylla-crds.sh
```

#### Add Helm Repositories

```bash
helm repo add unionai https://unionai.github.io/helm-charts/
helm repo add flyte https://helm.flyte.org
helm repo update
```

### Step 2: Create Registry Image Pull Secret

Union hosts control plane images in a private registry. You will receive registry credentials (username and password) from the Union team for your organization.

Create the registry secret in the `union-cp` namespace:

```bash
# Create namespace if it doesn't exist
kubectl create namespace union-cp

# Create registry image pull secret
# Replace <REGISTRY_USERNAME> and <REGISTRY_PASSWORD> with credentials provided by Union
kubectl create secret docker-registry union-registry-secret \
  --docker-server="registry.unionai.cloud" \
  --docker-username="<REGISTRY_USERNAME>" \
  --docker-password="<REGISTRY_PASSWORD>" \
  -n union-cp
```

**Example** (for a customer named "acme-corp"):
```bash
kubectl create secret docker-registry union-registry-secret \
  --docker-server="registry.unionai.cloud" \
  --docker-username="robot\$acme-corp" \
  --docker-password="LkkciLfd8fUCsaEKrN4x5VeOxh8RNIvn" \
  -n union-cp
```

**Important notes:**
- The registry username typically follows the format `robot$<org-name>`
- Note the backslash escape (`\$`) before the `$` character in the username
- This secret allows Kubernetes to pull control plane images from Union's private registry
- Contact Union support if you haven't received your registry credentials

### Step 3: Generate TLS Certificates

Since intra-cluster communication uses gRPC over HTTP/2, TLS is required for NGINX ingress.

**Option A: Using OpenSSL (self-signed)**

```bash
# Create a self-signed certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout controlplane-tls.key \
  -out controlplane-tls.crt \
  -subj "/CN=controlplane-nginx-controller.union-cp.svc.cluster.local"

# Create Kubernetes secret
kubectl create namespace union-cp
kubectl create secret tls controlplane-tls-cert \
  --key controlplane-tls.key \
  --cert controlplane-tls.crt \
  -n union-cp
```

**Option B: Using cert-manager (recommended for production)**

See the example in `values.gcp.selfhosted-intracluster.yaml` under the `extraObjects` section.

### Step 4: Configure Values File

Download and configure the intra-cluster values file:

```bash
# Download the self-contained intra-cluster configuration file
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/controlplane/values.gcp.selfhosted-intracluster.yaml
```

Edit `values.gcp.selfhosted-intracluster.yaml` by setting all `global` values and replace all empty `""` values. This file is self-contained and includes all necessary GCP and intra-cluster configuration.

### Step 5: Create Database Password Secret

The control plane uses a Kubernetes secret named `union-controlplane-secrets` to store the PostgreSQL database password and other service-specific secrets.

```bash
# Create secret with database password
kubectl create secret generic union-controlplane-secrets \
  --from-literal=pass.txt='YOUR_DB_PASSWORD' \
  -n union-cp
```

**Important notes:**
- The secret name `union-controlplane-secrets` is fixed and should not be changed
- This is the same name configured in `global.KUBERNETES_SECRET_NAME`
- The secret must contain a key named `pass.txt` with the database password

### Step 6: Download Values Files

Download the required values files from the Union Helm charts repository:

```bash
# Download GCP infrastructure configuration
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/controlplane/values.gcp.selfhosted-intracluster.yaml

# Download registry configuration
curl -O https://raw.githubusercontent.com/unionai/helm-charts/main/charts/controlplane/values.registry.yaml
```

Create your environment-specific overrides file `values.gcp.selfhosted-customer.yaml` with your configuration (see example below).

### Step 7: Install Control Plane

Install the control plane using layered values files:

```bash
helm upgrade --install unionai-controlplane unionai/controlplane \
  --namespace union-cp \
  --create-namespace \
  -f values.gcp.selfhosted-intracluster.yaml \
  -f values.registry.yaml \
  -f values.gcp.selfhosted-customer.yaml \
  --timeout 15m \
  --wait
```

**Values file layers (applied in order):**

1. **`values.gcp.selfhosted-intracluster.yaml`** - GCP infrastructure defaults (DB, storage, networking)
2. **`values.registry.yaml`** - Registry configuration and image pull secrets
3. **`values.gcp.selfhosted-customer.yaml`** - Your environment-specific overrides (see example below)

**Example customer overrides file (`values.gcp.selfhosted-customer.yaml`):**

```yaml
global:
  GCP_REGION: "us-central1"
  DB_HOST: "10.247.0.3"
  DB_NAME: "unionai"
  DB_USER: "unionai"
  BUCKET_NAME: "my-company-cp-flyte"
  ARTIFACTS_BUCKET_NAME: "my-company-cp-artifacts"
  ARTIFACT_IAM_ROLE_ARN: "artifacts@my-project.iam.gserviceaccount.com"
  FLYTEADMIN_IAM_ROLE_ARN: "flyteadmin@my-project.iam.gserviceaccount.com"
  UNION_ORG: "my-company"
  GOOGLE_PROJECT_ID: "my-gcp-project"
  # Authentication (see Authentication section below)
  OIDC_BASE_URL: "https://your-idp.example.com/oauth2/default"
  OIDC_CLIENT_ID: "<browser-login-client-id>"
  CLI_CLIENT_ID: "<cli-client-id>"
  INTERNAL_CLIENT_ID: "<service-to-service-client-id>"
  AUTH_TOKEN_URL: "https://your-idp.example.com/oauth2/default/v1/token"
```

**Important notes:**

- Uses **published chart** (`unionai/controlplane`) from Helm repository
- Layered approach separates infrastructure config, registry config, and customer overrides
- Easier to maintain and update - change images in one file, infrastructure in another

### Step 8: Verify Control Plane Installation

```bash
# Check pod status
kubectl get pods -n union-cp

# Verify services are running
kubectl get svc -n union-cp

# Check flyteadmin is accessible
kubectl logs -n union-cp deploy/flyteadmin --tail=50

# Test internal connectivity
kubectl exec -n union-cp deploy/flyteadmin -- \
  curl -k https://controlplane-nginx-controller.union-cp.svc.cluster.local
```

Expected: All pods should be in `Running` state, and internal connectivity should succeed.

### Step 8: Deploy Dataplane

After the control plane is running, deploy the dataplane following the [Dataplane Intra-Cluster Guide](../dataplane/SELFHOST_INTRA_CLUSTER_GCP.md).

The dataplane will connect to the control plane using the service endpoints configured in Step 4.

## Key Configuration Details

### Single-Tenant Mode

Intra-cluster deployments uses an experimental single-tenant mode with an explicit organization. Refer to [values.gcp.selfhosted-intracluster.yaml](./values.gcp.selfhosted-intracluster.yaml) for example configuration.

```yaml
global:
  # Update here to your organization designation
  UNION_ORG: ""

  # There are references to .Values.global.UNION_ORG where the
  # override is configured.
```

### TLS Requirements

gRPC requires TLS for HTTP/2 with NGINX. Refer to [values.gcp.selfhosted-intracluster.yaml](./values.gcp.selfhosted-intracluster.yaml) for example configuration.

```yaml
global:
  # Configure namespace and name of the Kubernetes TLS secret.
  TLS_SECRET_NAMESPACE: ""
  TLS_SECRET_NAME: ""

ingress-nginx:
  controller:
    extraArgs:
      # NOTE: This has to be explicitly set.
      default-ssl-certificate: "<TLS_SECRET_NAMESPACE>/<TLS_SECRET_NAME>"
```

### Service Discovery

Control plane services discover each other via Kubernetes DNS:

- **Flyteadmin**: `flyteadmin.union-cp.svc.cluster.local:81`
- **NGINX Ingress**: `controlplane-nginx-controller.union-cp.svc.cluster.local`
- **Dataplane** (for dataproxy): `dataplane-nginx-controller.union.svc.cluster.local`

## Authentication (OIDC/OAuth2)

Union supports OIDC-based authentication for self-hosted deployments. When enabled, all API calls (browser, CLI, and service-to-service) are authenticated via an external OAuth2/OIDC provider.

### Overview

Authentication uses an external OAuth2/OIDC-compliant identity provider. You will need to create **three OAuth2 client applications** in your identity provider:

| Client | Flow | Type | Purpose |
|--------|------|------|---------|
| Browser login | Authorization Code | Confidential | Console/web UI authentication |
| CLI | Authorization Code + PKCE | Public | `flytectl` / `uctl` CLI authentication |
| Service-to-service | Client Credentials | Confidential | Internal service authentication |

### OIDC Provider Requirements

Your OIDC provider must support:

1. **OpenID Connect Discovery** — `/.well-known/openid-configuration` endpoint
2. **Authorization Code flow** — for browser and CLI login
3. **Client Credentials flow** — for service-to-service tokens
4. **PKCE** (Proof Key for Code Exchange) — for the CLI public client
5. **Custom scopes** — ability to create an `all` scope (or equivalent)

### Step-by-Step Configuration

#### 1. Create OAuth2 Applications

Create three applications in your identity provider:

**Browser Login App (Confidential):**
- Grant type: Authorization Code
- Redirect URI: `https://<your-domain>/callback` (or the control plane ingress host)
- Scopes: `openid`, `profile`, `offline_access`
- Note the **Client ID** → used as `OIDC_CLIENT_ID`

**CLI App (Public):**
- Grant type: Authorization Code + PKCE
- Redirect URI: `http://localhost:53593/callback`
- Scopes: `all`
- Note the **Client ID** → used as `CLI_CLIENT_ID`

**Service-to-Service App (Confidential):**
- Grant type: Client Credentials
- Scopes: `all`
- Note the **Client ID** → used as `INTERNAL_CLIENT_ID`
- Note the **Client Secret** → stored in Kubernetes secrets

#### 2. Set Authentication Globals

Add the following to your customer overrides file:

```yaml
global:
  # ... existing globals ...
  OIDC_BASE_URL: "https://your-idp.example.com/oauth2/default"
  OIDC_CLIENT_ID: "<browser-login-client-id>"
  CLI_CLIENT_ID: "<cli-client-id>"
  INTERNAL_CLIENT_ID: "<service-to-service-client-id>"
  AUTH_TOKEN_URL: "https://your-idp.example.com/oauth2/default/v1/token"
```

#### 3. Create Kubernetes Secrets

The control plane needs the service-to-service client secret in two Kubernetes secrets:

```bash
# Secret for flyteadmin (mounted at /etc/secrets/)
kubectl create secret generic flyte-admin-secrets \
  --from-literal=client_secret='<SERVICE_CLIENT_SECRET>' \
  -n union-cp

# Secret for flyte-scheduler (mounted at /etc/secrets/)
kubectl create secret generic flyte-secret-auth \
  --from-literal=client_secret='<SERVICE_CLIENT_SECRET>' \
  -n union-cp
```

Union control plane services (executions, cluster, usage, etc.) mount secrets at `/etc/secrets/union/`. Create or update the main service secret:

```bash
# If using the union-controlplane-secrets secret, add client_secret key:
kubectl create secret generic union-controlplane-secrets \
  --from-literal=pass.txt='<DB_PASSWORD>' \
  --from-literal=client_secret='<SERVICE_CLIENT_SECRET>' \
  -n union-cp --dry-run=client -o yaml | kubectl apply -f -
```

**Tip:** For production, use External Secrets Operator or a similar tool to sync secrets from your cloud provider's secret manager (AWS Secrets Manager, GCP Secret Manager, Azure Key Vault).

#### 4. Enable Authentication in FlyteAdmin

To activate the OIDC login endpoints (`/login`, `/callback`, `/me`), add the following to your customer overrides:

```yaml
flyte:
  configmap:
    adminServer:
      server:
        security:
          useAuth: true
```

This enables nginx auth-subrequest validation on protected ingress routes.

### Verifying Authentication

After deploying with auth enabled:

```bash
# Check flyteadmin logs for auth initialization
kubectl logs -n union-cp deploy/flyteadmin | grep -i auth

# Test the /me endpoint (should return 401 without a token)
kubectl exec -n union-cp deploy/flyteadmin -- \
  curl -s -o /dev/null -w "%{http_code}" https://controlplane-nginx-controller.union-cp.svc.cluster.local/me -k

# Test CLI login
uctl config init --host https://<your-domain>
uctl get project
```

## Architecture Diagram

```mermaid
graph TB
    subgraph cluster["Kubernetes Cluster (GKE)"]
        subgraph cp["Namespace: union-cp (Control Plane)"]
            cpingress["NGINX Ingress<br/>(TLS/HTTP2)<br/>ClusterIP"]
            flyteadmin["Flyteadmin<br/>Service"]
            identity["Identity<br/>Service"]
            executions["Executions<br/>Service"]

            cpingress --> flyteadmin
            cpingress --> identity
            cpingress --> executions
        end

        subgraph dp["Namespace: union (Dataplane)"]
            dpingress["NGINX Ingress<br/>ClusterIP"]
            operator["Operator"]
            propeller["Propeller"]
            clusterresource["Cluster Resource<br/>Sync"]

            dpingress --> operator
            dpingress --> propeller
            dpingress --> clusterresource
        end

        subgraph external["External Resources"]
            cloudsql["PostgreSQL<br/>(Cloud SQL)"]
            gcs["GCS Buckets<br/>(Metadata & Artifacts)"]
        end

        %% Intra-cluster communication
        dpingress -.->|"Internal DNS<br/>dns:///controlplane-nginx-controller<br/>.union-cp.svc.cluster.local"| cpingress
        cpingress -.->|"Internal DNS<br/>dns:///dataplane-nginx-controller<br/>.union.svc.cluster.local"| dpingress

        %% External connections
        flyteadmin --> cloudsql
        identity --> cloudsql
        executions --> cloudsql
        flyteadmin --> gcs
        operator --> gcs
    end

    classDef cpStyle fill:#e1f5ff,stroke:#0066cc,stroke-width:2px
    classDef dpStyle fill:#fff4e1,stroke:#ff9900,stroke-width:2px
    classDef externalStyle fill:#f0f0f0,stroke:#666,stroke-width:2px

    class cpingress,flyteadmin,identity,executions cpStyle
    class dpingress,operator,propeller,clusterresource dpStyle
    class cloudsql,gcs externalStyle
```

**Key Points:**

- **Blue (Control Plane)**: Services in `union-cp` namespace
- **Orange (Dataplane)**: Services in `union` namespace
- **Gray (External)**: GCP-managed resources (Cloud SQL, GCS)
- **Dotted Lines**: Intra-cluster communication via Kubernetes DNS
- **Solid Lines**: Service dependencies within namespaces

## Troubleshooting

### Control plane pods not starting

```bash
# Check pod events
kubectl describe pod -n union-cp <pod-name>

# Check for resource constraints
kubectl top nodes

# Verify secrets exist
kubectl get secret -n union-cp
```

### TLS/Certificate errors

```bash
# Verify TLS secret exists
kubectl get secret controlplane-tls-cert -n union-cp

# Check certificate details
kubectl get secret controlplane-tls-cert -n union-cp -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Check NGINX ingress logs
kubectl logs -n union-cp deploy/controlplane-nginx-controller
```

### Database connection failures

- Verify database credentials in the secret:

  ```bash
  kubectl get secret union-controlplane-secrets -n union-cp -o jsonpath='{.data.pass\.txt}' | base64 -d
  ```

- Check network connectivity to PostgreSQL:

  ```bash
  kubectl run -n union-cp test-db --image=postgres:14 --rm -it -- \
    psql -h <DB_HOST> -U <DB_USER> -d <DB_NAME>
  ```

### Dataplane cannot connect to control plane

- Verify control plane service endpoints:

  ```bash
  kubectl get svc -n union-cp | grep -E 'flyteadmin|nginx-controller'
  ```

- Test DNS resolution from dataplane namespace:

  ```bash
  kubectl run -n union test-dns --image=busybox --rm -it -- \
    nslookup controlplane-nginx-controller.union-cp.svc.cluster.local
  ```

- Check network policies:

  ```bash
  kubectl get networkpolicies -n union-cp
  kubectl get networkpolicies -n union
  ```

### Workload Identity issues

- Verify service account annotations:

  ```bash
  kubectl get sa -n union-cp -o yaml | grep iam.gke.io/gcp-service-account
  ```

- Check IAM bindings:

  ```bash
  gcloud iam service-accounts get-iam-policy <SERVICE_ACCOUNT_EMAIL>
  ```

- Verify pod can authenticate:

  ```bash
  kubectl exec -n union-cp deploy/flyteadmin -- \
    curl -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
  ```

## Reference Configuration Files

- [values.gcp.yaml](values.gcp.yaml) - Standard GCP configuration (for hosted control plane deployments)
- [values.gcp.selfhosted-intracluster.yaml](values.gcp.selfhosted-intracluster.yaml) - Self-contained intra-cluster configuration

## Next Steps

1. **Deploy Dataplane**: Follow the [Dataplane Intra-Cluster Guide](../dataplane/SELFHOST_INTRA_CLUSTER_GCP.md)
2. **Enable Authentication**: Follow the [Authentication (OIDC/OAuth2)](#authentication-oidcoauth2) section above
3. **Test Workflows**: Run a test workflow to verify the complete stack
4. **Set Up Monitoring**: Configure Prometheus and Grafana for observability

## Additional Resources

- [Main Installation Guide](README.md) - Standard control plane deployment
- [Dataplane Installation Guide](../dataplane/README.md) - Dataplane setup
- [Dataplane Intra-Cluster Guide](../dataplane/SELFHOST_INTRA_CLUSTER_GCP.md) - Dataplane intra-cluster setup
- [Union Documentation](https://docs.union.ai) - Full documentation
- [ScyllaDB Operator Documentation](https://operator.docs.scylladb.com/)
- [GKE Workload Identity Documentation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
