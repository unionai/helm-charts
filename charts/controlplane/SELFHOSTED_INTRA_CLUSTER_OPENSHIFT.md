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

- ScyllaDB server
  - Account for Union access, i.e., `unionai`
  - User is administrator on the server (Union will create/maintain multiple tables)

### Temporary Workarounds

- ScyllaDB without authentication
- Postgresl without SSL enforcement
- Helm chart provided directly (instead of using the official Helm repository)

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

5. Install the Control Plane:

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
