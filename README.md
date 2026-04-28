# Union Helm Charts

## Dataplane

### Assumptions
* You have a Union organization that has already been created and you know the URL of your control plane host.
* The Union provided client ID and secret.
* You have a Kubernetes cluster, running one of the most recent three minor K8s versions. [Learn more](https://kubernetes.io/releases/version-skew-policy/)
* Object storage provided by a vendor or an S3 compatible platform (such as [Minio](https://min.io).

> Some sample Terraform configurations are available in the [providers](providers) directory.

## Prerequisites

* Install Helm 3.19

```bash
brew install helm
# Or if our version is lagging behind brew
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh --version v4.0.0
```

> Helm 3.19 is required to match version specific pinned in Github workflows.

* Install [union](https://docs.union.ai/byoc/api-reference/union-cli) and [uctl](https://docs.union.ai/byoc/api-reference/uctl-cli/).

## Deploy the Union operator

1. Add the Union.ai Helm repo:
```shell
helm repo add unionai https://unionai.github.io/helm-charts/
helm repo update
```

2. Create a values file that include, at a minimum, the following fields:

```yaml
host: <YOUR_UNION_CONTROL_PLANE_URL>
clusterName: <MY_CLUSTER> #arbitrary and unique cluster identifier
orgName: <MY_ORG> #Name of your Union.ai organization
provider: aws #The cloud provider your cluster is running in.  Acceptable values include `aws`, `gcp`, `azure`, `oci`, and `metal` (for self-managed or on-prem clusters).
storage:
  endpoint: <STORAGE_ENDPOINT> #This is the S3 API endpoint provided by your cloud vendor.
  accessKey: <S3_ACCESS_KEY>
  secretKey: <S3_SECRET_KEY>
  bucketName: <S3_BUCKET_NAME>
  fastRegistrationBucketName: <S3_BUCKET_NAME> #it can be the same as bucketName
  region: <CLOUD_REGION> # not needed for on-prem deployments
secrets:
  admin:
    create: true
    # Insert values from step 4
    clientSecret: <UNION_CLIENT_SECRET> #you can also provide this as a command-line argument
    clientId: "<UNION_CLIENT_ID>"
```
3. Optionally configure the resource `limits` and `requests` for the different services.  By default these will be set minimally, will vary depending on usage, and follow the Kubernetes `ResourceRequirements` specification.
    * `clusterresourcesync.resources`
    * `flytepropeller.resources`
    * `flytepropellerwebhook.resources`
    * `operator.resources`
    * `proxy.resources`

4. Install the Union operator and CRDs:
```shell
helm upgrade --install unionai-dataplane-crds unionai/dataplane-crds
helm upgrade --install unionai-dataplane unionai/dataplane \
    --create-namespace \
    --namespace union \
    --values <YOUR_VALUES_FILE>
```

5. Once deployed you can check to see if the cluster has been successfully registered to the control plane:

```shell
uctl get cluster
 ----------- ------- --------------- -----------
| NAME      | ORG   | STATE         | HEALTH    |
 ----------- ------- --------------- -----------
| <cluster> | <org> | STATE_ENABLED | HEALTHY   |
 ----------- ------- --------------- -----------
1 rows
```

## Debugging Chart Changes

Use `scripts/render-and-diff.sh` to render Helm templates at two git refs and structurally compare the output. This mirrors ArgoCD's exact values layering so you can verify what will change before deploying.

```bash
# Compare a release tag against main (uses tests/values/controlplane.aws.yaml by default)
./scripts/render-and-diff.sh controlplane-2026.4.7 main

# With your environment's terraform-generated values
./scripts/render-and-diff.sh controlplane-2026.4.7 main \
  --values /path/to/control-plane/values.yaml \
  --values /path/to/control-plane/values-union.yaml \
  --values /path/to/gitops/values.yaml

# Compare dataplane chart
./scripts/render-and-diff.sh dataplane-2026.4.7 main --chart dataplane

# Full text diff instead of structural
./scripts/render-and-diff.sh controlplane-2026.4.7 main --text

# Diff all resource types, not just ConfigMaps
./scripts/render-and-diff.sh controlplane-2026.4.7 main --all
```

The structural diff (`scripts/compare-manifests.py`) parses multi-document YAML, matches resources by `(kind, name)`, and deep-diffs ConfigMap data reporting full key paths — so you see exactly which config values changed rather than sifting through whitespace and annotation noise.

Requires: `helm`, `python3`, `PyYAML` (`pip install pyyaml`).
