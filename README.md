# Union Helm Charts

## Dataplane

### Assumptions
* You have a union organization that has already been created.
* You have a running kubernetes cluster and object storage provided by a vendor or an S3 compatible platform (such as [Minio](https://min.io).  Some sample terraform configurations are available in the [providers](providers) directory.

### Installation

* [Install Helm 3](https://helm.sh/docs/intro/install/)
* Install [union](https://docs.union.ai/byoc/api-reference/union-cli) and [uctl](https://docs.union.ai/byoc/api-reference/uctl-cli/).
* Install the Union.ai helm charts.
```shell
helm repo add unionai https://unionai.github.io/helm-charts/
helm repo update
```

* Generate a new client and client secret to communicate with your Union control plane by creating a new `AppSpec` configuration and using the `create app` command from `uctl`.

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
EOF
uctl config init --host=<cloud.host>
uctl create app --appSpecFile dataplane-operator.yaml
```
* The output will emit the ID, name, and a secret that will be used by the union services to communicate with your control plane.

```shell
Initializing app config from file dataplane-operator.yaml
 -------------------- -------------------- ------------------------------------------------------------------ ---------
| CLIENT ID          | CLIENT NAME        | SECRET                                                           | CREATED |
 -------------------- -------------------- ------------------------------------------------------------------ ---------
| dataplane-operator | dataplane-operator | secretxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |         |
 -------------------- -------------------- ------------------------------------------------------------------ ---------
1 rows
```
* Save the secret that is displayed.  Union does not store the credentials and it cannot be retrieved later.
* Optionally configure any values that are relevant to your installation.  A full list of values can be found here: [charts/dataplane/README.md](charts/dataplane/README.md).  At a minimum you will need to provide the following values in a file or as an argument on the command line:
  * `host`: The admin host used to communicate with your Union.ai organization's control plane.  You will have been provided this value when union has created your control plane.
  * `clusterName`: An arbitrary and unique identifier for your cluster.
  * `orgName`: The name of your Union.ai organization.
  * `provider`: The cloud provider your cluster is running in.  Acceptable values include `aws`, `gcp`, `azure`, `oci`, and `metal` (for self-managed or on-prem clusters).
  * `storage`: Several storage parameters exist for configuration.  By default the `authType` of `accesskey` is used and requires `storage.accessKey` and `storage.secretKey` to be set.  A full list of storage parameters can be found here: [charts/dataplane/README.md](charts/dataplane/README.md)
  * `secrets`: You have the option of creating the admin client secrets by setting `secrets.admin.create` to `true` and providing both the `clientId` and the `clientSecret` either in the values file or as command line arguments.
  * Optionally configure the resource `limits` and `requests` for the different services.  By default these will be set minimally, will vary depending on usage, and follow the kubernetes `ResourceRequirements` specification.
    * `clusterresourcesync.resources`
    * `flytepropeller.resources`
    * `flytepropellerwebhook.resources`
    * `operator.resources`
    * `proxy.resources`
* Install the dataplane.

```shell
helm upgrade --install unionai-dataplane-crds unionai/dataplane-crds
helm upgrade --install unionai-dataplane unionai/dataplane \
    --create-namespace \
    --namespace union \
    --set host="<control-plane.endpoint>" \
    --set clusterName="<cluster.name>" \
    --set orgName="<organization.name>" \
    --set provider="<cloud.provider>" \
    --set secrets.admin.create=true \
    --set secrets.admin.clientId="<client.id>" \
    --set secrets.admin.clientSecret="<client.secret>" \
    --values "<values.yaml>"
```

**Note: By default, Fluentbit and the [Grafana Loki](https://grafana.com/docs/loki/latest/setup/install/helm/) service backed by S3 (or compatible) storage is used to collect logs from containers running in the cluster.  To disable it set `loki.enable=false` on the command line or in the values file.**

Once deployed you can check to see if the cluster has been successfully registered to the control plane by running the `get cluster` command in `uctl`

```shell
uctl get cluster
 ----------- ------- --------------- -----------
| NAME      | ORG   | STATE         | HEALTH    |
 ----------- ------- --------------- -----------
| <cluster> | <org> | STATE_ENABLED | HEALTHY   |
 ----------- ------- --------------- -----------
1 rows
```

