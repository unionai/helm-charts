# ScyllaDB Authentication for Selfhosted Deployments

This guide explains how to enable CQL authentication on the ScyllaDB cluster deployed by the controlplane chart and configure the queue service to authenticate.

## Prerequisites

- ScyllaDB CRDs installed ([`scripts/install-scylla-crds.sh`](../scripts/install-scylla-crds.sh))
- Control plane namespace created (e.g. `union-cp`)
- The service secret already exists with the Postgres `pass.txt` key (see main deployment guide)

## Overview

By default, ScyllaDB runs with `developerMode: true`, which disables authentication entirely. Enabling authentication requires three things:

1. A ConfigMap that tells ScyllaDB to use `PasswordAuthenticator`
2. Changing the default superuser password after first boot
3. Configuring the queue service with the matching credentials

## Step 1: Choose a password

Generate or choose a password for the ScyllaDB `cassandra` superuser:

```bash
# Generate a random 32-character password
SCYLLA_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
echo "$SCYLLA_PASSWORD"  # Save this — you'll need it in steps 2 and 6
```

## Step 2: Add the password to the service secret

Add a `scylla-password` key to the existing service secret (the one referenced by `global.KUBERNETES_SECRET_NAME`, typically `union-controlplane-secrets`):

```bash
kubectl create secret generic union-controlplane-secrets \
  --from-literal=pass.txt='<YOUR_DB_PASSWORD>' \
  --from-literal=scylla-password="$SCYLLA_PASSWORD" \
  -n union-cp --dry-run=client -o yaml | kubectl apply -f -
```

The queue service mounts this secret at `/etc/secrets/union/`. The `scylla-password` key becomes the file `/etc/secrets/union/scylla-password`, which the queue service reads at startup.

## Step 3: Configure Helm values

In your customer overrides file, disable developer mode, reference the auth ConfigMap, and set the queue service credentials:

```yaml
scylla:
  developerMode: false
  racks:
    - name: rack1
      scyllaConfig: scylla-config  # references the ConfigMap created by the chart
      members: 3
      storage:
        capacity: 100Gi
        storageClassName: "scylladb"
      resources:
        limits:
          cpu: 2
          memory: 4Gi
        requests:
          cpu: 1
          memory: 2Gi
      placement:
        nodeAffinity: {}
        tolerations: []

services:
  queue:
    configMap:
      queue:
        db:
          hosts:
            - "scylla-client.union-cp.svc.cluster.local"
          threadCount: 64
          type: cql
          username: "cassandra"
          passwordName: "union/scylla-password"
```

The `passwordName` value `union/scylla-password` tells the queue service to read the password from `/etc/secrets/union/scylla-password` (the secret file prefix `/etc/secrets` is combined with the `passwordName`).

## Step 4: Create the ScyllaDB authentication ConfigMap

The `scyllaConfig: scylla-config` field in the rack definition references a ConfigMap that provides ScyllaDB configuration overrides. Create it to enable `PasswordAuthenticator` and `CassandraAuthorizer`:

```bash
kubectl apply -n union-cp -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: scylla-config
data:
  scylla.yaml: |
    authenticator: PasswordAuthenticator
    authorizer: CassandraAuthorizer
EOF
```

This ConfigMap must exist **before** the ScyllaDB cluster starts. Without it, ScyllaDB uses `AllowAllAuthenticator` regardless of `developerMode`.

## Step 5: Deploy the control plane

```bash
helm upgrade --install unionai-controlplane unionai/controlplane \
  --namespace union-cp \
  -f values.aws.selfhosted-intracluster.yaml \
  -f values.selfhosted-customer.yaml \
  --timeout 15m \
  --wait
```

## Step 6: Change the default superuser password

After the ScyllaDB cluster is healthy, the default `cassandra` superuser has password `cassandra`. You must change it to match the password stored in the secret:

```bash
# Wait for the cluster to be ready
kubectl wait --for=condition=Available scyllacluster/scylla -n union-cp --timeout=300s

# Connect and change the password
kubectl exec -it scylla-dc1-rack1-0 -n union-cp -c scylla -- \
  cqlsh localhost -u cassandra -p cassandra \
  -e "ALTER USER cassandra WITH PASSWORD '$SCYLLA_PASSWORD';"
```

Verify the new password works:

```bash
kubectl exec -it scylla-dc1-rack1-0 -n union-cp -c scylla -- \
  cqlsh localhost -u cassandra -p "$SCYLLA_PASSWORD" \
  -e "DESCRIBE CLUSTER;"
```

## Step 7: Restart the queue service

If the queue service started before the password was changed, restart it so it picks up the working credentials:

```bash
kubectl rollout restart deployment/queue -n union-cp
```

## Verification

Confirm the queue service is connected and authenticated:

```bash
kubectl logs -n union-cp deploy/queue | grep -i "cql\|scylla\|session"
```

The queue service should log a successful session creation without authentication errors.

## Troubleshooting

**Queue service fails with "failed to get cql db password"**
- Verify the secret has the `scylla-password` key: `kubectl get secret union-controlplane-secrets -n union-cp -o jsonpath='{.data.scylla-password}' | base64 -d`
- Verify `passwordName` in the values matches the secret key path (`union/scylla-password`)

**Queue service connects but gets "AuthenticationError"**
- The password in the secret doesn't match the ScyllaDB superuser password. Re-run Step 5 or update the secret.

**ScyllaDB pods crash-loop after disabling developerMode**
- Ensure the `scylla-config` ConfigMap exists and contains valid `scylla.yaml` (see Step 4).
- Check that sysctl `fs.aio-max-nr=30000000` is allowed on your nodes (required outside developer mode).
