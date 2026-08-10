# Self-hosted Union on OpenShift setup and validation guide

## Purpose

This guide is for platform, security, identity, and operations teams preparing an OpenShift environment for self-hosted Union.

It explains the configuration inputs Union needs, which items are required, which capabilities are optional, and what is lost when optional capabilities are not enabled. The checklists later in the page are for readiness and acceptance validation after the environment is configured.

Read this together with the delivered Helm chart package, release notes, environment-specific values files, and local change-management procedures.

## Deployment Assumptions

The target deployment is self-hosted Union on OpenShift.

- The platform owner supplies and operates the OpenShift cluster, network, identity provider, storage services, container registry, monitoring stack, and operational controls.
- Union is deployed into approved namespaces for the control plane and dataplane.
- The default deployment model keeps control plane to dataplane service communication inside the cluster.
- The identity provider must support the OIDC/OAuth flows required by browser login, CLI login, and service-to-service authentication.
- The container registry path must support both Union image distribution and user workflow image storage.
- Object storage must be available through an approved provider and endpoint.
- Production environments should use an externally managed, authenticated OSS ScyllaDB deployment for the Union queue backend. In-cluster ScyllaDB is acceptable for test and validation environments only.
- Connected, disconnected, and air-gapped operating models require separate validation of image distribution, chart distribution, and egress assumptions.

## Required Configuration

### OpenShift Platform

The platform owner must provide the OpenShift cluster version, cluster name, control plane namespace, dataplane namespace, and deployment permissions for the approved namespaces.

Union needs namespace-scoped permissions for workloads, services, secrets, roles, role bindings, routes or ingress resources, and persistent volume claims. Some chart components also require CRDs and cluster-scoped RBAC, especially when optional components such as Knative, ScyllaDB operator, or monitoring CRDs are enabled.

OpenShift security settings must be decided before install. Record the namespace UID range, fsGroup, SELinux level, and approved SecurityContextConstraints or equivalent policy. The environment values file should set pod security contexts to match the approved namespace policy.

### DNS, Routes, And TLS

The platform owner must provide the public Union console hostname, DNS ownership path, OpenShift Route or ingress model, TLS certificate source, and certificate renewal owner.

The console hostname is used for browser login, CLI login redirects, TLS certificate subject names, and end-user access. Internal service DNS is used by Union control plane and dataplane components for in-cluster traffic.

TLS can terminate at an OpenShift Route, ingress controller, cert-manager-managed certificate, or another approved boundary. The chosen model must cover the final public hostname and must be compatible with CLI and browser OIDC redirects.

### Identity And Authentication

The identity owner must provide OIDC/OAuth configuration for browser login, CLI login, and service-to-service authentication.

Required identity inputs:

- OIDC issuer URL.
- Browser client ID and redirect URIs for the Union console.
- CLI client ID and loopback redirect URI policy.
- Service-to-service client ID and token URL for Union internal calls.
- Required scopes and claims mapping.
- Secret delivery path for confidential client secrets.

Union uses separate clients because browser login, CLI login, and service-to-service calls have different OAuth flows and different security requirements. Secrets must be delivered through approved secret management, not committed to values files.

### Authorization

Plan for UserClouds-based RBAC unless Union and the deployment owner agree to a different authorization mode.

If UserClouds is enabled, the deployment owner must provide or approve the database, cache, identity claim mapping, and operational ownership. If it is deferred, fine-grained RBAC behavior is reduced and acceptance criteria must reflect that limitation.

### PostgreSQL

The database owner must provide PostgreSQL host, database name, username, TLS mode if required, network reachability from the Union control plane namespace, and a Kubernetes secret reference or external secret sync path for the password.

PostgreSQL backs Union control plane relational state. The database owner is responsible for sizing, backup, restore, patching, high availability, retention, and credential rotation unless a different ownership model is agreed in writing.

### Object Storage

The storage owner must provide object storage buckets or prefixes for metadata, artifacts, fast registration, logs, and any approved cache locations.

Required storage inputs:

- Provider and endpoint.
- Bucket or path names.
- Region or site identifier, if applicable.
- TLS and path-style or virtual-hosted-style behavior, if applicable.
- Access model for Union system pods and workflow pods.
- Retention, encryption, lifecycle, and backup expectations.

Union uses object storage for workflow inputs and outputs, task metadata, artifact access, fast registration uploads, and log retrieval paths. If a single bucket is used for multiple purposes, separate prefixes and retention policy should still be documented.

### ScyllaDB Queue Backend

The deployment owner must select the ScyllaDB mode before deployment.

For production, use externally managed OSS ScyllaDB with authentication enabled. For test and validation, embedded in-cluster ScyllaDB can be used if the deployment owner approves the persistent storage, replica count, storage class, and operational ownership.

If ScyllaDB is not available, Union queue-backed functionality cannot be considered production-ready for this deployment.

### Container Registry And Image Access

The registry owner must provide a registry path or approved mirror for Union images and workflow images.

Required registry inputs:

- Registry hostname and repository layout.
- Pull access for Union system workloads.
- Write access for user-built workflow images when image builder is enabled.
- Image scanning, admission policy, signing, and promotion requirements.
- Image import process for disconnected or air-gapped environments.

If the registry cannot provide write access for the image builder, users can still run workflows with externally built images, but Union cannot build and publish those images for them.

### Secrets Management

The security owner must decide how Kubernetes secrets are created, synchronized, rotated, and audited.

The values files should contain placeholders or references only. They should not contain client secrets, database passwords, registry passwords, pull secret JSON, cloud keys, bearer tokens, or API keys.

If external secret sync is not enabled, the deployment owner must create the required Kubernetes secrets before installation and own the rotation procedure.

### Observability

The operations owner must provide the monitoring, logging, alert routing, and retention model for production.

The target observability stack must provide metrics, logs, traces if required, alert routing, and retention. Fluent Bit or an approved equivalent must make workflow and system logs available for troubleshooting. Alerts must route into the incident process, not only into a local dashboard.

If the bundled monitoring stack is disabled, the operations owner must ensure the external stack discovers Union metrics, records service-level indicators, retains logs, and routes alerts.

## Required Inputs Checklist

- [ ] OpenShift version, cluster name, and environment name.
- [ ] Control plane namespace and dataplane namespace.
- [ ] Namespace UID range, fsGroup, SELinux level, and approved SCC model.
- [ ] Public Union hostname and DNS owner.
- [ ] OpenShift Route or ingress model and TLS certificate source.
- [ ] PostgreSQL host, database, username, TLS mode, and secret reference.
- [ ] Object storage provider, endpoints, buckets or prefixes, and access model.
- [ ] ScyllaDB mode, endpoint, authentication model, and owner.
- [ ] Registry hostname, repository layout, pull access, and write access if image builder is enabled.
- [ ] OIDC issuer, browser client, CLI client, service-to-service client, token URL, scopes, and redirect URIs.
- [ ] Secret management mechanism and rotation owner.
- [ ] Monitoring, logging, alerting, and retention owner.
- [ ] Air-gapped or disconnected image and chart distribution requirements, if in scope for this phase.

## Optional Capabilities And Tradeoffs

These features are optional at the chart level, but some may be required for the target user experience.

**Image builder**

- Target status: required when users need Union to build and publish workflow images.
- Requires: registry write access, builder service account permissions, build cache decision, OpenShift-compatible security policy, and approved image scanning/promotion path.
- For OpenShift, use the dataplane `values.openshift.yaml` overlay so BuildKit runs in rootless mode with a dedicated service account and an SCC that does not allow privileged containers.
- If disabled: users must build and push workflow images outside Union, then reference those prebuilt images in workflow registration.

**App serving and Knative**

- Target status: optional unless Union-hosted apps or serving endpoints are in scope for acceptance.
- Requires: Knative operator, serving CRDs, route exposure model, TLS behavior, and resource ownership.
- If disabled: workflows and scheduled jobs can still run, but Union app serving endpoints are unavailable.

**Embedded in-cluster ScyllaDB**

- Target status: allowed for test and validation only.
- Requires: persistent volumes, storage class, replica sizing, and acceptance of in-cluster operations.
- If disabled: provide external authenticated ScyllaDB. If neither embedded nor external ScyllaDB is available, the Union queue backend is not ready.

**External secret sync**

- Target status: optional mechanism, but some secret-management mechanism is required.
- Requires: approved secret backend, Kubernetes Secret creation policy, refresh interval, and rotation process.
- If disabled: the deployment owner must manually create and rotate the required Kubernetes secrets before install and before every credential rotation.

**Bundled monitoring and Grafana**

- Target status: optional when an external observability stack is used.
- Requires: Prometheus Operator CRDs and accepted dashboard/alert ownership if enabled.
- If disabled: the operations owner must scrape Union metrics, collect logs, configure dashboards, and route alerts through external tools.

**DCGM exporter**

- Target status: optional unless GPU workload telemetry is required for acceptance.
- Requires: compatible GPU nodes and NVIDIA exporter support.
- If disabled: GPU-level metrics are reduced or unavailable in Union observability.

**OpenCost**

- Target status: optional.
- Requires: cost allocation model and scraping integration.
- If disabled: cost reporting and allocation detail are reduced or unavailable.

**Disconnected or air-gapped install**

- Target status: required only when disconnected or air-gapped operation is in scope.
- Requires: image mirror, chart distribution process, offline upgrade procedure, and no-egress observability plan.
- If disabled for the current phase: installation may assume approved network paths or pre-synchronized mirrors, but it does not validate the air-gapped operating model.

## Values Review

Review the environment-specific values files before installation. Redacted copies may be shared for support only if policy permits.

Control plane values to review:

- [ ] `global.UNION_HOST` points to the final Union hostname.
- [ ] `global.UNION_ORG` matches the agreed organization name.
- [ ] PostgreSQL host, database, user, and secret reference are correct.
- [ ] Object storage buckets or prefixes are correct for metadata and artifacts.
- [ ] OIDC browser, CLI, and service-to-service configuration matches the configured identity applications.
- [ ] TLS and Route or ingress settings match the approved OpenShift exposure model.
- [ ] Pod security contexts match the control plane namespace UID, fsGroup, and SELinux level.
- [ ] Registry, image repository, image tags, and pull secret references are approved.
- [ ] ScyllaDB mode is correct for the environment.
- [ ] Optional monitoring settings match the observability ownership decision.

Dataplane values to review:

- [ ] Dataplane name and namespace are correct.
- [ ] Internal control plane endpoint, queue endpoint, cache endpoint, and Flyte Admin endpoint are correct.
- [ ] Metadata and fast-registration object storage locations are correct.
- [ ] Service-to-service OAuth client and secret reference are correct.
- [ ] Workflow service account annotations and default workload identity behavior are approved.
- [ ] Runtime pod security contexts match the dataplane namespace policy.
- [ ] Fluent Bit or approved log collection settings are correct.
- [ ] Image builder settings match registry write access and OpenShift SCC policy.
- [ ] App serving and Knative settings match the acceptance scope.

Release values to review:

- [ ] Chart versions are pinned to released versions.
- [ ] Image versions are pinned or resolved from the release package.
- [ ] Dependency versions are reviewed against the release notes.
- [ ] Values files contain placeholders or secret references, not raw secrets.
- [ ] Any deviations from the release baseline are documented before deployment.

## Union-Validated Release Baseline

This section records the release-only baseline Union has validated for the OpenShift chart path. It intentionally omits internal branch names, commit SHAs, account identifiers, hostnames, and secret paths.

Baseline date: 2026-05-19.

Platform baseline:

- OpenShift: 4.17.
- Kubernetes chart floor: v1.28.0-0 or newer.
- Deployment class: self-hosted Union on OpenShift.

Union chart releases:

- Controlplane chart: 2026.5.5, app version 2026.5.5.
- Dataplane chart: 2026.5.5, app version 2026.5.5.
- Dataplane CRDs chart: 2026.5.5, app version 2026.5.5.
- Knative operator chart: 2026.4.6, app version 1.16.0.
- Knative operator CRDs chart: 2026.4.5, app version 1.16.0.

Dependency releases in the validated package:

- flyte-core: v1.16.1.
- ingress-nginx: 4.12.3.
- scylla-operator: v1.18.1.
- scylla: v1.18.1.
- kube-prometheus-stack: 80.8.0.
- prometheus: 25.27.0.
- prometheus-operator-crds: 27.0.0.
- metrics-server: 3.12.2.
- fluent-bit: 0.48.9.
- opencost: 1.42.0.
- dcgm-exporter: 4.7.1.
- envoy-gateway: v1.6.4.

This baseline does not validate unreleased chart snapshots, branch references, modified dependency versions, or environment-specific overrides that are not reviewed with Union.

## Pre-Deployment Readiness Checklist

Platform:

- [ ] OpenShift cluster is healthy and within the approved version range.
- [ ] Control plane and dataplane namespaces exist or are approved for creation.
- [ ] Deployment identity can install the required Helm releases, CRDs, RBAC, secrets, services, routes or ingress resources, and PVCs.
- [ ] Namespace UID ranges, fsGroup values, SELinux levels, and SCC approvals are documented.
- [ ] Persistent volume provisioning works in the approved namespaces.

Networking and TLS:

- [ ] Public DNS resolves to the approved OpenShift Route or ingress path.
- [ ] TLS certificate covers the final Union hostname.
- [ ] Internal service DNS resolves between Union namespaces.
- [ ] Network policy permits required traffic among Union services, PostgreSQL, object storage, registry, identity provider, and observability endpoints.

Security and identity:

- [ ] Identity provider applications are created for browser, CLI, and service-to-service authentication.
- [ ] Redirect URIs include the final Union hostname and approved CLI callback URI.
- [ ] Token issuer, token URL, client IDs, scopes, and claims mapping are reviewed by identity owners.
- [ ] Secret creation, synchronization, and rotation ownership is approved.
- [ ] No raw secrets are committed to source control or stored in this page.

Storage and data services:

- [ ] PostgreSQL is reachable from the control plane namespace.
- [ ] PostgreSQL backup, restore, patching, and credential rotation owners are assigned.
- [ ] Object storage buckets or prefixes exist and have approved lifecycle, encryption, retention, and access policies.
- [ ] ScyllaDB mode is selected and tested for the environment tier.
- [ ] Registry pull and optional write paths are available from the approved namespaces.

Operations:

- [ ] Monitoring, logging, alerting, and incident-response ownership is assigned.
- [ ] Upgrade and rollback expectations are documented.
- [ ] Acceptance criteria and deployment window are agreed.

## Post-Deployment Validation Checklist

Platform health:

- [ ] OpenShift cluster operators remain healthy after install.
- [ ] Union control plane workloads are ready.
- [ ] Union dataplane workloads are ready.
- [ ] PVCs are bound to the expected storage class.
- [ ] No image pull failures remain for Union system images.
- [ ] No unresolved OpenShift security policy denials remain for Union workloads.

Console and identity:

- [ ] Union console loads at the final hostname.
- [ ] TLS certificate is valid for the final hostname.
- [ ] Browser login works through the approved identity provider.
- [ ] CLI login works through the approved identity provider.
- [ ] Service-to-service token flow works between dataplane and control plane components.

Storage and data access:

- [ ] Control plane services can reach PostgreSQL.
- [ ] Control plane and dataplane services can access required object storage locations.
- [ ] ScyllaDB is reachable and authenticated according to the selected mode.
- [ ] Task logs are visible through the approved logging path.

Workflow validation:

- [ ] A simple workflow registers and runs successfully.
- [ ] A workflow using cache behavior runs twice and shows the expected cache behavior.
- [ ] A workflow using a custom prebuilt image runs successfully.
- [ ] Workflow service accounts receive the expected permissions or identity.
- [ ] Scheduled workflows or launch plans run if they are in acceptance scope.

Optional capability validation:

- [ ] If image builder is enabled, an approved test build can build and push to the registry.
- [ ] If rootless BuildKit is enabled, `scripts/validate_rootless_buildkit.sh` passes against the dataplane namespace.
- [ ] If app serving is enabled, an approved app can be deployed and reached through the approved route.
- [ ] If bundled monitoring is enabled, dashboards and alert rules are visible to the approved operators.
- [ ] If GPU telemetry is enabled, GPU metrics appear for a GPU test workload.
- [ ] If air-gapped validation is in scope, image, chart, telemetry, and upgrade workflows operate without external egress.

## Rootless BuildKit Validation

The dataplane OpenShift overlay configures BuildKit for the non-privileged path. It enables the rootless BuildKit image variant, runs the container as UID/GID 1000, uses the rootless user socket, adds the rootless worker flag, and binds the BuildKit service on TCP port 1234 for the build-image task.

Runtime prerequisites:

- The dataplane namespace must allow the chart-rendered BuildKit SCC or an equivalent pre-created SCC.
- The BuildKit service account must be allowed to use that SCC.
- The BuildKit SCC and pod must allow privilege escalation for the rootless UID/GID mapping path while still disallowing privileged containers.
- The BuildKit pod template should pin the resolved SCC with `openshift.io/required-scc` so admission uses the SCC that the chart binds to the BuildKit service account.
- The cluster policy must allow unconfined seccomp for this BuildKit pod.
- The registry must allow writes to the configured workflow image repository.
- The deployed image set must include the BuildKit rootless image and any required registry credentials or pull secrets.

Known limitations:

- This path does not use privileged container mode. It depends on rootless BuildKit behavior and may not support every Dockerfile pattern that requires process sandboxing or privileged kernel features.
- The smoke test can prove BuildKit can build and push one simple image, but the final acceptance check is still an approved Union image-builder workflow that uses the same registry and project/domain configuration as users.
- Disconnected and air-gapped environments must validate image mirroring, chart distribution, registry writes, and upgrade flow separately.

Render-time validation:

```bash
helm template charts/dataplane \
  --namespace union \
  --kube-version 1.32.0 \
  --values charts/dataplane/values.aws.yaml \
  --values charts/dataplane/values.openshift.yaml \
  --values charts/dataplane/examples/values-test-certs.yaml \
  --values tests/values/dataplane.openshift.yaml
```

Cluster validation:

```bash
KUBECTL_BIN=oc \
NAMESPACE=union \
scripts/validate_rootless_buildkit.sh
```

The script verifies the rootless BuildKit deployment shape, the dedicated service account, `allowPrivilegeEscalation: true`, `hostUsers: false`, required SCC pinning, SCC `use` permission, and the admitted pod SCC before checking BuildKit workers.

Build-and-push smoke test:

```bash
KUBECTL_BIN=oc \
NAMESPACE=union \
TARGET_IMAGE=harbor.example.com/union/rootless-buildkit-smoke:$(date +%Y%m%d%H%M%S) \
scripts/validate_rootless_buildkit.sh
```

After the smoke test passes, run an approved Union workflow that invokes the registered `build-image` task and pushes to the same registry path. The controlplane chart registers that task through the image-builder bootstrap job when `imageBuilder.bootstrap.enabled` is true.

## Acceptance Criteria

The environment is ready for handoff when these items are true:

- [ ] Platform owner accepts cluster, namespace, storage, registry, DNS, Route or ingress, and TLS readiness.
- [ ] Security owner accepts identity, secret management, workload identity, image policy, and SCC posture.
- [ ] Operations owner accepts backup, restore, monitoring, logging, alerting, and incident ownership.
- [ ] Union and the deployment owner agree that required post-deployment validation passed.
- [ ] Known limitations and deferred optional capabilities are documented.
- [ ] Upgrade and support process is documented.

## Support Package For Issues

When opening a support request, provide a redacted package where permitted by policy:

- OpenShift version and environment tier.
- Union chart versions and image versions.
- Redacted control plane and dataplane values files.
- Namespace names and relevant security context settings.
- High-level workload readiness status for Union namespaces.
- Relevant Kubernetes events for failing workloads.
- Redacted logs for the failing Union component.
- Route or ingress status for hostname or TLS issues.
- PVC status and storage class details for storage issues.
- Registry and image pull or push status for image issues.
- Identity provider metadata and redacted client configuration for login or service authentication issues.

## Open Decisions To Close

- [ ] Final control plane namespace.
- [ ] Final dataplane namespace.
- [ ] Final Union hostname and TLS model.
- [ ] Final identity provider app details.
- [ ] Final object storage provider, endpoint, and bucket or prefix layout.
- [ ] Final PostgreSQL service and backup owner.
- [ ] Final ScyllaDB endpoint, authentication mode, and operations owner.
- [ ] Final registry repository layout and image builder write policy.
- [ ] Final app serving and Knative acceptance scope.
- [ ] Final monitoring, logging, alert routing, and retention integration.
- [ ] Final disconnected or air-gapped distribution process for the follow-on phase.
