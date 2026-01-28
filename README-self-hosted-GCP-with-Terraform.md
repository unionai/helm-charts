# Self-Hosted Union on GCP using Terraform

This step-by-step tutorial aims to deploy a Union self-hosted (both control
plane and data plane) on GCP using Union's reference Terraform modules.

> The customer is free to use any other infrastructure mechanism, be that their
> own Terraform modules or other means, as long as their choice of system
> produces the same output as the Terraform modules.
>
> This is critical because the instructions herein assume those resources exist
> and configured as such. You are welcome to perform all tasks manually and
> observe the full manual step-by-step defined in the respective [Control Plane
> GCP][manual-cp-gcp] and [Data Plane GCP][manual-dp-gcp] guides.

## Resources Needed

- **VPC**: networking details to run Union
- **GKE**: where Union will run. It can be the same cluster or distinct
  clusters.
- **Cloud SQL (postgres)**: a database for CP to store job and run information.
- **Workload Identities**: used to allow the GKE cluster to assime the IAM roles
  and acquire privileges to perform operations, i.e., access GCS
- **IAM service accounts**: the accounts used to perform privileged operations,
  i.e., writing state to GCS
- **ScyllaDB**: a high-performant NoSQL store for dynamic state

## Deploying Infrastructure Resources

To deploy the infrastructure resources we will use the Terraform modules you
received. They are:

- `infra`: Creates all control and data plane infrastructure resources
  - `infra_ext`: An adapter to plug into existing infrastructure without
    creating them. This is used to make your VPC and GKE compatible with the
    modules below.
- `controlplane`: Creates all the control plane resources
- `dataplane`: Creates all the dataplane resources

### Resources created by the Terraform modules

- **VPC**: networking details to run Union
- **GKE**: where Union will run. It can be the same cluster or distinct
  clusters, depending on the value of the variable
  `dedicated_dataplane_cluster`. If `true`, two clusters will be created (or
  referenced), and if `false` the same cluster is shared between CP and DP.
- **Cloud SQL (postgres)**: a database for CP to store job and run information.
- **Workload Identities**: used to allow the GKE cluster to assime the IAM roles
  and acquire privileges to perform operations, i.e., access GCS
- **IAM service accounts**: the accounts used to perform privileged operations,
  i.e., writing state to GCS

### Deployment Instructions

1. Unpack the Terraform modules
2. Choose from the examples, either `create-infra` or `already-created-infra`,
   depending whether you want the module to create the VPC and GKE or not.
   - Update the values within with your specific project details
   - If to share the same cluster by CP and DP, set `dedicated_dataplane_cluster
     = false`, otherwise set to `dedicated_dataplane_cluster = true`.
3. `terraform init` to pull the required providers
4. `terraform plan` and review the objects to be created
5. `terraform apply` to make it so

At the end of this run you will have:

- VPC created (optional)
- GKE created (optional)
- Postgres in Cloud SQL
- Postgres account information (loaded as secret in GKE)
- Self-signed certificates for the Control Plane (loaded as secret in GKE)
- Workload identities for Data Plane backend

## Deploying Union

### Deploying Control Plane

As you used the Terraform module (or performed your own steps that produced the
same objects), we will be skipping all the manual steps listed in the [Control
Plane GCP][manual-cp-gcp] page, and move straight into `helm install`.

#### Gathering Infra Details

> We will make Terraform output the values file eventually. For now, please find
> these values from the output of the Terraform execution (or call `terraform
> output`)

Mostly you will concentrate on the `global` section of the values file:

| Value                     | Description                               | Source                                                                 |
| ------------------------- | ----------------------------------------- | ---------------------------------------------------------------------- |
| `GCP_REGION`              | The region the Control Plane is installed | `main.tf > module > infra > region`                                    |
| `DB_HOST`                 | The IP address of the Postgres database   | `terraform output controlplane > db > host`                            |
| `BUCKET_NAME`             | Bucket used for system functions          | `terraform output controlplane > gcs > flyte > id`                     |
| `ARTIFACTS_BUCKET_NAME`   | Bucket to store artifacts                 | `terraform output controlplane > gcs > artifacts > id`                 |
| `ARTIFACT_IAM_ROLE_ARN`   | The IAM role to access artifacts          | `terraform output controlplane > service_accounts > artifacts > email` |
| `FLYTEADMIN_IAM_ROLE_ARN` | The IAM role to access system storage     | `terraform output controlplane > service_accounts > flyte > email`     |
| `UNION_ORG`               | The name of the Union organization        | `main.tf > locals > union_org`                                         |
| `GOOGLE_PROJECT_ID`       | The name of the GCP project               | `main.tf > locals > project_id`                                        |

We will ignore for now, but will come back to it later, after we install the
Data Plane:

| Value                | Description                             | Source                                           |
| -------------------- | --------------------------------------- | ------------------------------------------------ |
| `DATAPLANE_ENDPOINT` | The ingress endpoint for the data plane | Data Plane `EXTERNAL_IP` for its ingress service |

> If you are using DNS entries for the ingress endpoints, and you know in
> advance the Data Plane ingress DNS, you can specify them now and skip updating
> this later.

#### CP Deployment Instructions

0. Ensure your current cluster is pointing to where you want to install the
   Control Plane, i.e., execute `gcloud container clusters get-credentials` or
   whichevever mechanism you use to make your cluster the default.

1. Unpack the Helm charts

2. Make a copy of the [GCP CP Self-Hosted values.yaml][gcp-cp-values]
   - If you received a reference values from Union personnel, use that instead.

3. Update the `values.yaml` from step 2 with your project and environment
   specific information

4. Load the Registry access secret to the cluster:

        kubectl create secret docker-registry union-registry-secret \
            --docker-server=registry.unionai.cloud \
            --docker-username='<username>' \
            --docker-password='<password>' \
            -n union-cp

5. `helm install` the Control Plane module

        cd charts/controlplane
        helm upgrade --install unionai-controlplane . \
            --namespace union-cp \
            --create-namespace \
            --values your-values.yaml \
            --timeout 15m

6. Wait for a little bit: get a coffee, maybe a short walk?

#### CP Deployment Verification

Confirm all services are running:

    kubectl get pod -n union-cp

You should get something like this:

    NAME                                             READY   STATUS    RESTARTS   AGE
    authorizer-6f8f655467-l44mt                      1/1     Running   0          33h
    cacheservice-6979466f8c-6rn5g                    1/1     Running   0          33h
    cluster-c5597448-prvbq                           1/1     Running   0          33h
    controlplane-nginx-controller-857b568794-twfkr   1/1     Running   0          33h
    dataproxy-6d484b7c45-rbgw9                       1/1     Running   0          11h
    executions-5d4fb97788-wgg6w                      1/1     Running   0          33h
    flyteadmin-74fbf5bbd9-x6lb5                      1/1     Running   0          33h
    flyteconsole-d6859d494-wnrxl                     1/1     Running   0          33h
    queue-78f8fb75f4-22qp8                           1/1     Running   0          33h
    run-scheduler-54667b6d96-w5z8p                   1/1     Running   0          33h
    scylla-dc1-rack1-0                               4/4     Running   0          33h
    scylla-dc1-rack1-1                               4/4     Running   0          33h
    scylla-dc1-rack1-2                               4/4     Running   0          33h
    unionconsole-55d946668-nlf7x                     1/1     Running   0          33h
    usage-5ddf757d6d-cjlr8                           1/1     Running   0          33h

At this point the control plane setup is complete.

### Deploying Data Plane

The process to deploy the data plane is very similar to the Control Plane.

#### DP Gathering Infra Details

  | Value                             | Description                                            | Source                                                                  |
  | --------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------- |
  | `CLUSTER_NAME`                    | Name of the Data Plane                                 | `terraform output dataplane > union > cluster_name`                     |
  | `ORG_NAME`                        | Union organization                                     | `terraform output dataplane > union > org`                              |
  | `METADATA_BUCKET`                 | System bucket                                          | `terraform output dataplane > gcs > metadata > name`                    |
  | `FAST_REGISTRATION_BUCKET`        | Fast registration bucket (can be the same of metadata) | `terraform output dataplane > gcs > fast_registration > name`           |
  | `GCP_REGION`                      | The region the Data Plane is installed                 | `main.tf > module > infra > region`                                     |
  | `GOOGLE_PROJECT_ID`               | The name of the GCP project                            | `main.tf > locals > project_id`                                         |
  | `BACKEND_IAM_ROLE_ARN`            | The role backend services will run                     | `terraform output dataplane > gcp > service_accounts > backend > email` |
  | `WORKER_IAM_ROLE_ARN`             | The role workers will run                              | `terraform output dataplane > gcp > service_accounts > worker > email`  |
  | `CONTROLPLANE_INTRA_CLUSTER_HOST` |                                                        | On CP GKE `get svc controlplane-nginx-controller` pick `EXTERNAL_IP`    |
  | `QUEUE_SERVICE_HOST`              |                                                        | On CP GKE `get svc queue` pick `EXTERNAL_IP`                            |
  | `FLYTEADMIN_ENDPOINT`             |                                                        | On CP GKE `get svc flyteadmin` pick `EXTERNAL_IP`                       |
  | `CACHESERVICE_ENDPOINT`           |                                                        | On CP GKE `get svc cacheservice` pick `EXTERNAL_IP`                     |

#### DP Deployment Instructions

0. Ensure your current cluster is pointing to where you want to install the
   Data Plane. _If you are not sharing the same cluster, note this should point
   to the **data plane** cluster now._

1. Make a copy of the [GCP DP Self-Hosted values.yaml][gcp-dp-values]
   - If you received a reference values from Union personnel, use that instead.

2. Update the `values.yaml` from step 1 with your project and environment
   specific information

3. `helm install` the Control Plane module

        cd charts/dataplane
        helm upgrade --install unionai-dataplane . \
            --namespace union \
            --create-namespace \
            --values your-values.yaml \
            --timeout 10m \
            --wait

    > It is important to deploy in the `union` namespace, so do not skip the `-n
    > union` argument. The Workflow Identity IAM is configured to that
    > namespace, and changing it just here will make things fail.

4. Wait for a little bit: time for now coffee or walk?

#### DP Deployment Verification

Confirm all services are running:

    kubectl get pod -n union

You should see something like this:

    NAME                                          READY   STATUS    RESTARTS  AGE
    dataplane-nginx-controller-859754bb66-zxjgs   1/1     Running   0         12h
    executor-6b9fbfb46d-bczbs                     1/1     Running   0         12h
    flytepropeller-54b98486b4-59qnw               1/1     Running   0         12h
    flytepropeller-webhook-6fc47cd8fd-rf7nt       1/1     Running   0         12h
    prometheus-operator-5cff9b5487-rb7nn          1/1     Running   0         12h
    prometheus-union-operator-prometheus-0        2/2     Running   0         12h
    syncresources-56d976c8-7s28f                  1/1     Running   0         12h
    union-operator-d8746c9f9-6c6lz                1/1     Running   0         12h
    union-operator-proxy-5fd674b9dd-jp8vb         1/1     Running   0         12h
    unionai-dataplane-fluentbit-572gt             1/1     Running   0         12h
    unionai-dataplane-fluentbit-n4tbd             1/1     Running   0         12h
    unionai-dataplane-fluentbit-qhknp             1/1     Running   0         12h

#### Binding DP to CP

> This step is only needed if you're not using DNS entries for the Data Plane
> ingress, or if you do but cannot predict it before installing the control
> plane.

The Control Plane needs to reach out to the Data Plane to send work to it.
Therefore, we need to "teach" the Control Plane where to find the Data Plane.
That's accomplished by the Helm variable `DATAPLANE_ENDPOINT` in the Control
Plane Helm chart.

1. Find the IP address (or DNS entry) for the ingress of the Data Plane, and
   pick the `EXTERNAL_IP`:

        kubectl get svc dataplane-nginx-controller

2. Update the variable in your `values.yaml` for the Control Plane

3. Make sure you switch your Kubernetes context to point to the Control Plane
   GKE.

4. Run an upgrade of the Helm chart to propagate the value (by running the same
   command as to install the Control Plane):

        cd charts/controlplane
        helm upgrade --install unionai-controlplane . \
            --namespace union-cp \
            --create-namespace \
            --values your-values.yaml \
            --timeout 15m

Once this complete you're done! Both the control plane and data plane are
successfully setup.

[manual-cp-gcp]: https://github.com/unionai/helm-charts/blob/nelson/nav-gcp/charts/controlplane/SELFHOSTED_INTRA_CLUSTER_GCP.md
[manual-dp-gcp]: https://github.com/unionai/helm-charts/blob/nelson/nav-gcp/charts/dataplane/SELFHOSTED_INTRA_CLUSTER_GCP.md
[gcp-cp-values]: https://github.com/unionai/helm-charts/blob/nelson/nav-gcp/charts/controlplane/values.gcp.selfhosted-intracluster.yaml
[gcp-dp-values]: https://github.com/unionai/helm-charts/blob/nelson/nav-gcp/charts/dataplane/values.gcp.selfhosted-intracluster.yaml
