# Dataplane Helm Chart Audit Plan

## Objective

Audit the Union dataplane Helm chart by:

1. **Rendering all meaningful combinations of values** (including `onprem-values-nopropeller.yaml` as the baseline).
2. **Flagging security issues** (secrets in ConfigMaps, weak defaults, overly permissive settings).
3. **Flagging behavioral / correctness issues** (invalid combinations, misleading names, missing validations).

---

## 1. Scope

### 1.1 Chart and baseline

- **Chart**: `charts/dataplane/`
- **Baseline values**: `onprem-values-nopropeller.yaml` (from byok-testing; will be copied or referenced for tests).
- **Existing test values**: `tests/values/dataplane.*.yaml` and `charts/dataplane/values.*.yaml` (AWS, GCP, Azure, OCI, low-priv, etc.).

### 1.2 Out of scope (for this audit)

- Control plane chart.
- Sandbox chart.
- Terraform / provider code in repo (can be referenced for “intended” patterns only).

---

## 2. Value Combinations to Exercise

Systematically vary the following to ensure templates render and behave correctly and to catch security/behavior issues.

### 2.1 Major toggles (component on/off)

| Key | Values to test | Notes |
|-----|----------------|--------|
| `flytepropeller.enabled` | `true`, `false` | Drives propeller + webhook ConfigMap; when `false`, webhook-only path still exists. |
| `flytepropellerwebhook.enabled` | `true`, `false` | When propeller disabled, webhook can still be enabled (standalone webhook config). |
| `executor.enabled` | `true`, `false` | Node executor deployment and webhook; avoid duplicate webhook when propeller enabled. |
| `clusterresourcesync.enabled` | `true`, `false` | Sync resources deployment and config. |
| `fluentbit.enabled` | `true`, `false` | Subchart; DaemonSet and storage access. |
| `prometheus.enabled` | `true`, `false` | Subchart (kube-prometheus-stack). |
| `opencost.enabled` | `true`, `false` | Subchart. |
| `dcgm-exporter.enabled` | `true`, `false` | Subchart. |
| `knative-operator.enabled` | `true`, `false` | Subchart + CRDs. |
| `serving.enabled` | `true`, `false` | Depends on knative-operator. |
| `imageBuilder.enabled` | `true`, `false` | BuildKit and image builder deployment. |
| `nodeobserver.enabled` | `true`, `false` | DaemonSet with privileged / SYS_ADMIN. |
| `ingress.enabled` | `true`, `false` | Ingress resources. |
| `ingress-nginx.enabled` | `true`, `false` | Nginx ingress controller subchart. |
| `low_privilege` | `true`, `false` | Scopes RBAC/namespace. |
| `secrets.admin.enable` | `true`, `false` | Auth secret and volume mounts. |
| `secrets.admin.create` | `true`, `false` | Create vs external secret. |

### 2.2 Storage provider and auth

| Key | Values to test | Notes |
|-----|----------------|--------|
| `storage.provider` | `compat`, `aws`, `gcs`, `oci`, `azure`, `custom` | Each branch in `_storage.tpl`; `custom` uses `storage.custom`. |
| `storage.authType` | `accesskey`, `iam` | For `provider: aws` only; affects whether accessKey/secretKey are rendered. |
| `storage.disableSSL` | `true`, `false` | Rendered into config. |
| `storage.metadataPrefix` | `""`, non-empty | Overrides provider-based prefix. |
| `storage.injectPodEnvVars` | `true`, `false` | Injects storage env into pods (see helpers). |

### 2.3 Proxy and secret manager

| Key | Values to test | Notes |
|-----|----------------|--------|
| `proxy.secretManager.enabled` | `true`, `false` | |
| `proxy.secretManager.type` | `K8s`, other | When `K8s`, `serviceaccount-proxy-secret.yaml` creates RBAC for proxy secret namespace. |
| `proxy.secretManager.namespace` | `""`, explicit namespace | Defaults to release namespace. |

### 2.4 Optional / high-impact values

- `global.*` set vs top-level overrides (`host`, `clusterName`, `orgName`, `storage.bucketName`, etc.): ensure both styles work (legacy onprem vs global-based).
- `config.enabled_plugins`, `config.operator.syncClusterConfig`, `config.operator.enableTunnelService`.
- `flytepropellerwebhook.securityContext` (non-root, etc.).
- `executor.sharedService.security`: `secure`, `useAuth`, `allowCors`, `allowedOrigins` (default `*`).
- Grafana default password and `admin.existingSecret`.
- Resource requests/limits (sanity check: no invalid or empty values when components enabled).

---

## 3. Security Audit Checklist

### 3.1 Secrets and credentials

- [ ] **Storage credentials in ConfigMaps**  
  `storage.accessKey` and `storage.secretKey` are rendered into ConfigMaps via `include "storage"` in:
  - `operator/configmap.yaml`
  - `propeller/configmap.yaml` (when `flytepropeller.enabled`)
  - `nodeexecutor/configmap.yaml` (when `executor.enabled`)  
  **Action**: Flag as HIGH – recommend external secrets or env-from-Secret for accesskey auth; document risk when using accesskey.

- [ ] **Admin client secret**  
  `secrets.admin.clientSecret` is used to create Kubernetes Secret `union-secret-auth` (correct).  
  **Action**: Confirm no accidental inclusion in ConfigMaps or logs; recommend `create: false` + External Secrets in production.

- [ ] **FluentBit env**  
  Baseline has `fluentbit.env` with literal AWS keys (minio). When `fluentbit.enabled: true` and env contains secrets, flag as MEDIUM – prefer workload identity / IRSA.

- [ ] **Grafana**  
  Default `adminPassword: union-dataplane`. Flag as MEDIUM – recommend `admin.existingSecret` in production.

### 3.2 RBAC and least privilege

- [ ] **Operator and proxy ServiceAccounts**  
  Review `operator/serviceaccount.yaml` (and proxy) for cluster-scoped permissions; ensure no broader-than-necessary access when `low_privilege: false`.

- [ ] **Proxy secret manager RBAC**  
  When `proxy.secretManager.enabled` and `type: K8s`, Role/RoleBinding for `proxy.secretManager.namespace` – confirm scope is minimal.

- [ ] **Nodeobserver**  
  Runs privileged, `SYS_ADMIN`; document as intentional and ensure only deployed when needed.

### 3.3 Network and API security

- [ ] **Executor sharedService**  
  Defaults: `secure: false`, `useAuth: false`, `allowCors: true`, `allowedOrigins: ["*"]`. Flag as MEDIUM – lock down in production (auth, CORS, TLS).

- [ ] **Ingress**  
  When `ingress.enabled: true`, check TLS and auth annotations are recommended in docs.

### 3.4 Pod and container security

- [ ] **securityContext / podSecurityContext**  
  Audit defaults for operator, proxy, propeller, webhook, executor, imagebuilder, nodeobserver – ensure runAsNonRoot / readOnlyRootFilesystem where feasible.

- [ ] **flytepropellerwebhook**  
  Chart sets `runAsNonRoot: true`, `runAsUser: 1001` – good; ensure no regressions when other values overridden.

---

## 4. Behavioral / Correctness Checklist

### 4.1 Naming and consistency

- [ ] **onprem-values-nopropeller.yaml**  
  File name suggests “no propeller”, but file contains `flytepropeller.enabled: true`. Flag as BUG or DOC – align name with intent or fix value.

- [ ] **global vs top-level**  
  Chart supports both `global.UNION_CONTROL_PLANE_HOST` and top-level `host`. Ensure docs and examples clarify when to use which; verify rendering with only top-level (e.g. onprem) and only global (e.g. tests/values/dataplane.aws.yaml).

### 4.2 Invalid or dangerous combinations

- [ ] **flytepropeller.enabled = false and flytepropellerwebhook.enabled = true**  
  Renders “webhook-only” ConfigMap; confirm no missing dependencies (e.g. cert generation, service).

- [ ] **executor.enabled = true and flytepropeller.enabled = true**  
  Webhook is rendered once (propeller path); nodeexecutor webhook template has `if not .Values.flytepropeller.enabled` to avoid duplicate. Confirm no duplicate ValidatingWebhookConfiguration.

- [ ] **serving.enabled = true and knative-operator.enabled = false**  
  Should fail or be documented as invalid (serving depends on knative-operator).

- [ ] **storage.provider = gcs**  
  Requires `storage.gcp.projectId`; template uses `required`. Verify error message and that no partial render leaks.

- [ ] **storage.provider = custom**  
  Uses `storage.custom`; empty custom may produce invalid YAML – test and optionally add validation or docs.

### 4.3 Subchart conditions

- [ ] **prometheus.enabled = false**  
  No kube-prometheus-stack; references to `prometheus.health.url` or similar in operator config – ensure they tolerate missing Prometheus.

- [ ] **opencost.enabled = true**  
  opencost points at Prometheus URL; if prometheus disabled, opencost config may be invalid – verify.

### 4.4 Resource and scheduling

- [ ] **proxy.resources**  
  Baseline has `limits.memory: 1Gi` and `requests.memory: 1Gi`; requests equal to limits is valid but ensure no typo (e.g. limit &lt; request elsewhere).

- [ ] **Resource requests/limits**  
  For each component that is enabled, ensure at least one of requests/limits is set so scheduler and limit enforcement work; flag empty or zero where inappropriate.

---

## 5. Execution Plan

### Phase 1: Setup and baseline render

1. Copy or symlink `onprem-values-nopropeller.yaml` into `tests/values/` (e.g. `dataplane.onprem-nopropeller.yaml`) and ensure it passes `helm template` with chart dependencies (see `tests/run.sh`).
2. Resolve dependency on `global` if baseline uses only top-level keys: either add a minimal `global:` block or confirm chart defaults use top-level overrides correctly.
3. Run `helm template` for baseline and save output to `tests/generated/` (or a dedicated audit dir). Run `kubeconform` (or equivalent) on generated manifests.

### Phase 2: Matrix rendering

1. Implement a small script or Make target that:
   - Takes the baseline values file.
   - For each “dimension” in §2, overrides one key at a time (or a small subset of combinations) and runs `helm template`.
   - Captures success/failure and any template errors.
2. Prioritize:
   - All storage provider + authType combinations.
   - flytepropeller on/off × executor on/off × flytepropellerwebhook on/off.
   - secrets.admin.enable × secrets.admin.create.
   - proxy.secretManager.enabled × type.
3. Optionally run against a real minikube cluster with a few selected value sets (e.g. baseline, AWS-style, minimal components) to validate install/upgrade.

### Phase 3: Security and behavior review

1. For each rendered manifest set (at least baseline + a few variants):
   - Grep for `access_key`, `secret_key`, `client_secret`, `password` in ConfigMaps and Ingress annotations.
   - Review ServiceAccount and Role/ClusterRole for overly broad permissions.
   - Review securityContext and allowCors / allowedOrigins in config.
2. Document findings in a table: Finding | Severity | Value combination | Recommendation.

### Phase 4: Report and remediation

1. Produce `DATAPLANE_AUDIT_REPORT.md` with:
   - Summary of value combinations tested.
   - Security findings (with severity) and recommendations.
   - Behavioral/correctness findings and recommended fixes or docs.
   - Any chart changes suggested (e.g. optional use of Secret for storage credentials, or validation for provider/custom).
2. Create issues or PRs for:
   - High-severity security (e.g. credentials in ConfigMaps).
   - Inconsistencies (e.g. onprem filename vs flytepropeller.enabled).
   - Invalid combinations (serving without knative, etc.) with validation or docs.

---

## 6. Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Audit plan** | This document. |
| **Rendered matrix** | Optional artifact: list of value files × render status (pass/fail). |
| **Audit report** | `DATAPLANE_AUDIT_REPORT.md` with findings, severity, and recommendations. |
| **Fix suggestions** | Chart or docs PRs: e.g. secret ref for storage, validation, naming fix, security defaults. |

---

## 7. References

- Chart: `charts/dataplane/` (values.yaml, Chart.yaml, templates).
- Storage logic: `charts/dataplane/templates/_storage.tpl`.
- Helpers: `charts/dataplane/templates/_helpers.tpl` (e.g. `proxy.secretsNamespace`, storage inject).
- Tests: `tests/run.sh`, `tests/values/dataplane.*.yaml`, `tests/generated/`.
- Baseline: `onprem-values-nopropeller.yaml` (byok-testing or provided path).
