# Union Helm Charts

## Dataplane

### Assumptions
* You have a Union organization that has already been created and you know the URL of your control plane host.
* You have a Kubernetes cluster, running one of the most recent three minor K8s versions. [Learn more](https://kubernetes.io/releases/version-skew-policy/)
* Object storage provided by a vendor or an S3 compatible platform (such as [Minio](https://min.io).

> Some sample Terraform configurations are available in the [providers](providers) directory.

## Prerequisites
* Install [Helm 3](https://helm.sh/docs/intro/install/)
* Install [union](https://docs.union.ai/byoc/api-reference/union-cli) and [uctl](https://docs.union.ai/byoc/api-reference/uctl-cli/).

## Deploy the Union operator

1. Add the Union.ai Helm repo:
```shell
helm repo add unionai https://unionai.github.io/helm-charts/
helm repo update
```

2. Generate a new client and client secret to communicate with your Union control plane by creating a new `AppSpec` configuration and using the `create app` command from `uctl`.

```shell
cat > dataplane-operator.yaml << EOF
clientId: dataplane-operator
clientName: dataplane-operator
grantTypes:
- AUTHORIZATION_CODE
- CLIENT_CREDENTIALS
redirectUris:
- http://localhost:8080/authorization-code/callback
responseTypes:
- CODE
tokenEndpointAuthMethod: CLIENT_SECRET_BASIC
consentMethod: "CONSENT_METHOD_TRUSTED"
EOF
```
3. Initialize the client configuration to poin to your control plane endpoint provided by Union:

```shell
uctl config init --host=<cloud.host>
```
4. Create the`AppSec` configuration:

```shell
uctl create app --appSpecFile dataplane-operator.yaml
```
* The output will emit the client ID, name, and a secret that will be used by the Union operator to communicate with your control plane:

```shell
Initializing app config from file dataplane-operator.yaml
 -------------------- -------------------- ------------------------------------------------------------------ ---------
| CLIENT ID          | CLIENT NAME        | SECRET                                                           | CREATED |
 -------------------- -------------------- ------------------------------------------------------------------ ---------
| dataplane-operator | dataplane-operator | secretxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |         |
 -------------------- -------------------- ------------------------------------------------------------------ ---------
1 rows
```
5.  **Save the secret that is displayed.  Union does not store the credentials and it cannot be retrieved later.**
6.  Create a values file that include, at a minimum, the following fields:

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
  region: <CLOUD_REGION> #not needed for on-prem deployments
secrets:
  admin:
    create: true
    # Insert values from step 4
    clientSecret: <MY_CLIENT_SECRET> #you can also provide this as a command-line argument
    clientId: "dataplane-operator"
```
7. Optionally configure the resource `limits` and `requests` for the different services.  By default these will be set minimally, will vary depending on usage, and follow the Kubernetes `ResourceRequirements` specification.
    * `clusterresourcesync.resources`
    * `flytepropeller.resources`
    * `flytepropellerwebhook.resources`
    * `operator.resources`
    * `proxy.resources`

8. Install the Union operator and CRDs:
```shell
helm upgrade --install unionai-dataplane-crds unionai/dataplane-crds
helm upgrade --install unionai-dataplane unionai/dataplane \
    --create-namespace \
    --namespace union \
    --values <YOUR_VALUES_FILE>
```

9. Once deployed you can check to see if the cluster has been successfully registered to the control plane:

```shell
uctl get cluster
 ----------- ------- --------------- -----------
| NAME      | ORG   | STATE         | HEALTH    |
 ----------- ------- --------------- -----------
| <cluster> | <org> | STATE_ENABLED | HEALTHY   |
 ----------- ------- --------------- -----------
1 rows
```
