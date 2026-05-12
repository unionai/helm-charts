## Union Self Managed deployment – Supported Environment & Responsibilities

### 1. Purpose 
Define **what a “supported environment” is** for the `unionai/dataplane` Helm chart and **where the line is** between what **Union** manages and what **the customer** manages.

**Key boundary**:  
  > - If it’s configurable via the documented `unionai/dataplane` Helm chart values, Union owns it.  
  > - If it requires changes to the Kubernetes cluster, cloud provider configuration, or other infrastructure outside the chart, the customer owns it.

---

### 2. High‑Level Requirements

A supported self‑hosted dataplane deployment meets **all** of the following:

- **Union control plane**
  - A Union organization and control plane have already been created.
  - The control plane URL (`host`) is known and reachable from the cluster.

- **Kubernetes cluster**
  - A functioning Kubernetes cluster running **one of the most recent three minor K8s versions** (per the Kubernetes version skew policy), with:
    - A supported provider (`provider: aws | gcp | azure | oci | metal`).
    - DNS, networking, and load balancers operating in a **standard, supported configuration**, meaning:
      - **DNS**: CoreDNS (or the vendor’s DNS service) is healthy and pods can resolve internal service names (for example `*.svc.cluster.local`) and required external hostnames (Union control plane, object storage, container registries).
      - **Networking**: Pods can reach each other via ClusterIP Services, nodes can reach pods, and pods/nodes have outbound internet (or proxy) access required to talk to the Union control plane and configured storage/registries, using a supported CNI plugin.
      - **Load balancers / ingress**: The cloud provider’s load balancer or Ingress controller is installed and working so that Kubernetes `Service` / `Ingress` resources of the documented types (for example `LoadBalancer`, `ClusterIP`) result in reachable endpoints.
  - The cluster is either:
    - A managed K8s service (EKS, GKE, AKS, OKE), or
    - A **well‑maintained on‑prem / “metal” cluster** (see details below).

- **Object storage**
  - S3 or S3‑compatible object storage (for example AWS S3, Cloudflare R2, or another S3‑compatible platform) with:
    - API endpoint (`storage.endpoint`),
    - Credentials (`storage.accessKey`, `storage.secretKey`) or equivalent IAM,
    - Buckets for metadata and fast registration (`bucketName`, `fastRegistrationBucketName`),
    - Region (where applicable).

- **Tooling**
  - **Helm 3.19+** (as required in the Helm chart README).
  - `union` and `uctl` CLIs installed and configured.

- **Operational ownership**
  - The customer has an **identified individual or team responsible for the Kubernetes fleet and cloud account(s)**.
  - The customer has an **active support contract with their cloud provider or Kubernetes distribution vendor** (for example, AWS Enterprise Support, GCP Support, EKS/GKE/AKS/OKE support, or equivalent on‑prem distro support).

---

### 3. On‑Prem or non-major cloud K8s clusters (`metal`)

For `provider: metal` or any non‑managed cluster, a **well‑maintained cluster** means:

- **Version & lifecycle**
  - Running a Kubernetes version within the **latest three minor** releases.
  - A defined process to **regularly upgrade Kubernetes** and core system components (etcd, control plane, CNI, CSI).

- **Reliability**
  - HA control plane and etcd (or equivalent vendor‑provided HA).
  - Monitoring and alerting for:
    - Node health,
    - Control plane components,
    - etcd storage,
    - Cluster resource saturation.

- **Security & patching**
  - Regular OS/kernel and container runtime patches on worker nodes.
  - Defined process for rotating credentials, certificates and keys.

- **Networking**
  - Stable CNI and network policies aligning with upstream Kubernetes behavior.
  - Reliable outbound connectivity from nodes to:
    - The Union control plane URL,
    - The configured object storage endpoint,
    - Any other required third‑party endpoints (for example registries).

- **Storage**
  - Sufficient local storage for container image cache
  - Appropriate IOPS/throughput for metadata, task logs and optional data services (for example if used alongside Prometheus).
  - Retention policy is optional but is generally recommended to set it to be higher than the cluster's [`max-cache-age`](https://www.union.ai/docs/v1/flyte/deployment/configuration-reference/flytepropeller-config/#max-cache-age-configduration) (unset by default).

- **Support**
  - An **internal platform/Kubernetes team** or a **vendor** responsible for:
    - Investigating and resolving infrastructure/Kubernetes issues,
    - Applying upgrades and configuration changes when required by Union’s recommendations.

If these characteristics are not present, the environment is **not considered a supported target** for self‑service dataplane Helm deployments.

---

### 4. Responsibilities – Union vs. Customer

#### 4.1 Summary

- **Union owns**:
  - The **dataplane Helm charts** (`unionai/dataplane`, `unionai/dataplane-crds`) and their templates.
  - The **documented `values.yaml` schema** and default configurations.
  - Guidance and support for **anything that can be configured through those Helm values**.
  - Compatibility guarantees described in release notes (for example supported Kubernetes versions, documented providers and topologies).

- **Customer owns**:
  - The **Kubernetes cluster and cloud account**: creation, upgrades, security, and day‑to‑day operations.
  - **Cloud provider configuration**: IAM, VPCs/VNets, subnets, security groups/NSGs, firewalls, load balancers, DNS, TLS termination.
  - **Object storage infrastructure**: buckets, lifecycle policies, access controls.
  - **Deploying and operating the Helm release**:
    - Running `helm upgrade --install …`,
    - Managing CI/CD pipelines that deploy chart upgrades,
    - Providing values files that reflect their environment.

#### 4.2 Responsibility Matrix

| **Area**                            | **Union (via Helm chart)**                                              | **Customer (cluster / cloud owner)**                                                       |
|-------------------------------------|-------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| Kubernetes control plane & nodes    | Defines resource requests/limits and tolerations within workloads      | Provisions and maintains clusters, node pools, OS images, runtime, and upgrades           |
| Cloud networking & security         | Exposes ports/Services as documented                                   | VPC/VNet design, subnets, routing, security groups/NSGs, firewall rules, VPN/peering, WAF |
| Object storage                      | Uses configured `storage.*` settings from values                       | Creates and manages buckets, endpoints, credentials, IAM policies                         |
| Helm release & templates            | Maintains chart templates & default values; documents supported values | Runs Helm commands and CI/CD, provides environment‑specific values files                  |
| Union dataplane workloads           | Deploys operator, CRDs, controllers, webhooks, etc. via the chart      | Provides cluster capacity and connectivity so workloads can run                           |
| Monitoring & logging configuration  | Provides hooks/values for log URLs, dashboards, metrics scraping, etc. | Operates the underlying logging/metrics stack and storage                                 |
| Disaster recovery                   | Documents dataplane assumptions for restorable state                   | Implements backup/restore for cluster, storage, and any data services                     |
| Vendor / cloud issues               | N/A                                                                     | Works directly with cloud or distro support to resolve underlying vendor issues           |

> **If a problem arises in the Kubernetes platform or cloud provider (for example broken CNI, failing load balancer, storage outage, DNS misconfiguration, unknown cloud error), the customer’s K8s/cloud team and vendor support are responsible for investigation and remediation.**

---

### 5. Supported Configuration Scope (Helm)

#### 5.1 What is “in scope” for Union

Union provides support for:

- **Helm install & upgrade flow**:
  - `unionai/dataplane-crds` and `unionai/dataplane` charts from the official repo.
  - Values that are documented in the README, chart `values.yaml`, and official examples.

- **Behavior configurable via values**:
  - `host`, `clusterName`, `orgName`, `provider`, `storage.*`, `secrets.*`.
  - Resource `requests`/`limits` for Union services (for example `operator.resources`, `proxy.resources`, etc.).
  - Features, toggles, and options that were added explicitly through:
    - Chart documentation,
    - Release notes,
    - Pull requests that expose new values.

- **Chart‑owned Kubernetes objects**:
  - Deployments, StatefulSets, Services, CRDs and related resources created by the charts.
  - Issues where:
    - The cluster meets the environment requirements above, **and**
    - The chart is deployed unchanged with supported values.

#### 5.2 What is “out of scope” (requires SOW or is unsupported)

Union does **not** support the following as part of the standard Helm chart deployment:

- **Template or chart modifications**
  - Editing the chart templates, adding new templates, or maintaining a fork.
  - Kustomize overlays or custom manifests that significantly patch chart‑owned resources.

- **Undocumented/unintended values**
  - Values that are not part of `values.yaml` or documented in README/examples.
  - Relying on behavior that depends on internal implementation details rather than documented contracts.

- **Infrastructure or vendor issues**
  - Diagnosing problems with:
    - Cloud networking, load balancers, or DNS.
    - Underlying storage systems or disk/volume provisioning.
    - Kubernetes control plane components, CNIs, or CSIs.
  - Serving as the primary interface between the customer and their cloud/vendor support.

- **Custom third‑party integrations**
  - Installing and operating additional software in the cluster (for example service meshes, sidecar‑based logging agents, additional operators), unless explicitly documented as supported.

These items may be addressed through:

- A **paid professional services engagement**, and/or
- A **product feature request** that, once implemented, becomes exposed, documented, and supported as additional Helm values.

---

### 6. Customer Operational Readiness

To be eligible for a supported deployment, the customer must:

- **Have an identified K8s/cloud owner**
  - A named **team or individual** responsible for:
    - Making configuration changes in the cloud provider and Kubernetes cluster,
    - Responding to environment‑level incidents,
    - Carrying out required upgrades and remediations recommended by Union.

- **Have active vendor support**
  - An **active support contract** with their:
    - Cloud provider (AWS, GCP, Azure, OCI), or
    - Kubernetes distro vendor (for on‑prem or metal clusters),
  - So that infrastructure/vendor issues can be escalated and resolved outside of Union.

- **Accept the responsibility boundary**
  - Acknowledge that:
    - **Union** supports everything that can be configured in the Helm chart through documented values.
    - **The customer** supports the Kubernetes fleet, cloud provider configuration, and infrastructure on which that chart runs.

---
[Learn more about the Union Self Managed architecture ](https://www.union.ai/docs/v1/selfmanaged/deployment/architecture/overview/)   
Thank you for reading :) 
