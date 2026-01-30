# OpenShift install

## Requirements

- S3-compatible store, i.e., SeaweedFS
  - Endpoint URL (resolvable and accessible from within the cluster)
  - Access key ID + secret
  - Account must have access to both buckets provided

- Postgres server
  - Host name or IP address (resolvable and accessible from within the cluster)
  - User for Union access, i.e., `unionai`
  - User is administrator on the server (Union will create/maintain multiple databases)
  - Server accepts connections without SSL originated at the cluster

- ScyllaDB server
  - Account for Union access, i.e., `unionai`
  - User is administrator on the server (Union will create/maintain multiple tables)

### Requirements Deployment Options (suggestions)

The customer can install each component using any of the multiple existing methods.
We are listing some here just as non-inclusive examples:

- S3-compatible store
  - Cloud-native stores (S3, GCS, etc) are great options given their many-9s reliability
  - SeaweedFS provides instructions on how to install on a Kubernetes cluster
  - MinIO has multiple deployment strategies and SaaS offering

- Postgres server
  - Deploy the server directly on a set of machines (Postgres is part of multiple Linux distributions)
  - Deploy the server on a cloud provider managed offering (if running on a cloud provider)
  - Use an "operator" to deploy and manage the server in a Kubernetes cluster (in the same or a different cluster)

- ScyllaDB
  - Subscribe to Scylla Cloud for a SaaS/managed offering
  - Use an "operator" to deploy ScyllaDB on a Kubernetes cluster
  - Deploy Scylla "bare metal"

For all the requirements, a few things to keep in mind:

- If using DNS, they must be resolvable from the clusters where control plane and data plane run
- Services must be reachable from the clusters where control plane and data plane run
- Minimize latency: deploy the requirements (databases, object store) as close to the service as possible
  - Example: avoid deploying them on different cloud providers, or far away regions
  - Same project/account and region are best

### Temporary Workarounds

- Postgresl without SSL enforcement
- Helm chart provided directly (instead of using the official Helm repository)
- Secret passed via the Helm chart (landing in a config map instead of a secret)

## Installation Steps

1. Prepare Control Plane helm
   - Unzip the Helm chart somewhere
   - Go to `<helm>/charts/controlplane`
   - Clone sample~values-openshift.yaml:

     ```shell
     cp sample~values-openshift.yaml values-controlplane.yaml
     ```

2. Update `values-controlplane.yaml` with your specific environment

3. Adjust OpenShift security policies:
   - Make your cluster context default `kubectl cluster-info` points to it
   - Run `openshift_policies.sh` to configure the necessary policies for OpenShift

4. Create a pull secret to enable downloading the control plane's private images:

   ```shell
   kubectl create secret docker-registry union-registry-secret \
        --docker-server='registry.unionai.cloud' \
        --docker-username='<username>' \
        --docker-password='<password>' \
        -n union-cp
   ```

   Registry account (username, password) provided by Union.

5. Create `unionai` database

6. Store the Postgres password for the user specified in the YAML

   ```shell
   kubectl patch secret union-controlplane-secrets \
        -p '{"stringData":{"pass.txt":"<your-password>"}}'
   ```

7. Store the ScyllaDB password for the user specified in the YAML

   ```shell
   kubectl patch secret union-controlplane-secrets \
        -p '{"stringData":{"scylla.txt":"<your-password>"}}'
   ```

8. Install the Control Plane:

   ```shell
   helm upgrade --install unionai-controlplane . \
        --namespace union-cp \
        --create-namespace \
        -f values.openshift.selfhosted-intracluster.yaml \
        -f values.registry.yaml \
        -f values-controlplane.yaml \
        --timeout 15m \
        --wait
   ```
