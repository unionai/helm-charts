# dataplane

![Version: 2025.1.0](https://img.shields.io/badge/Version-2025.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2025.1.0](https://img.shields.io/badge/AppVersion-2025.1.0-informational?style=flat-square)

Deploys the Union dataplane components to onboard a kubernetes cluster to the Union Cloud.

## Requirements

Kubernetes: `>= 1.28.0`

| Repository | Name | Version |
|------------|------|---------|
| https://prometheus-community.github.io/helm-charts | prometheus(kube-prometheus-stack) | 68.2.2 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| additionalPodAnnotations | object | `{}` |  |
| additionalPodEnvVars | object | `{}` |  |
| additionalPodLabels | object | `{}` |  |
| clusterName | string | `""` |  |
| clusterresourcesync.config.clusterResourcesPrivate.app.isSelfServe | bool | `false` |  |
| clusterresourcesync.config.cluster_resources.clusterName | string | `"{{ include \"getClusterName\" . }}"` |  |
| clusterresourcesync.config.cluster_resources.customData[0].production[0].projectQuotaCpu.value | string | `"4096"` |  |
| clusterresourcesync.config.cluster_resources.customData[0].production[1].projectQuotaMemory.value | string | `"2Ti"` |  |
| clusterresourcesync.config.cluster_resources.customData[0].production[2].projectQuotaNvidiaGpu.value | string | `"256"` |  |
| clusterresourcesync.config.cluster_resources.customData[0].production[3].defaultUserRoleKey.value | string | `"{{ tpl .Values.userRoleAnnotationKey . }}"` |  |
| clusterresourcesync.config.cluster_resources.customData[0].production[4].defaultUserRoleValue.value | string | `"{{ tpl .Values.userRoleAnnotationValue . }}"` |  |
| clusterresourcesync.config.cluster_resources.customData[1].staging[0].projectQuotaCpu.value | string | `"4096"` |  |
| clusterresourcesync.config.cluster_resources.customData[1].staging[1].projectQuotaMemory.value | string | `"2Ti"` |  |
| clusterresourcesync.config.cluster_resources.customData[1].staging[2].projectQuotaNvidiaGpu.value | string | `"256"` |  |
| clusterresourcesync.config.cluster_resources.customData[1].staging[3].defaultUserRoleKey.value | string | `"{{ tpl .Values.userRoleAnnotationKey . }}"` |  |
| clusterresourcesync.config.cluster_resources.customData[1].staging[4].defaultUserRoleValue.value | string | `"{{ tpl .Values.userRoleAnnotationValue . }}"` |  |
| clusterresourcesync.config.cluster_resources.customData[2].development[0].projectQuotaCpu.value | string | `"4096"` |  |
| clusterresourcesync.config.cluster_resources.customData[2].development[1].projectQuotaMemory.value | string | `"2Ti"` |  |
| clusterresourcesync.config.cluster_resources.customData[2].development[2].projectQuotaNvidiaGpu.value | string | `"256"` |  |
| clusterresourcesync.config.cluster_resources.customData[2].development[3].defaultUserRoleKey.value | string | `"{{ tpl .Values.userRoleAnnotationKey . }}"` |  |
| clusterresourcesync.config.cluster_resources.customData[2].development[4].defaultUserRoleValue.value | string | `"{{ tpl .Values.userRoleAnnotationValue . }}"` |  |
| clusterresourcesync.config.cluster_resources.standaloneDeployment | bool | `true` |  |
| clusterresourcesync.config.union.auth.authorizationMetadataKey | string | `"flyte-authorization"` |  |
| clusterresourcesync.config.union.auth.clientId | string | `"{{ tpl .Values.secrets.admin.clientId . }}"` |  |
| clusterresourcesync.config.union.auth.clientSecretLocation | string | `"/etc/union/secret/client_secret"` |  |
| clusterresourcesync.config.union.auth.tokenRefreshWindow | string | `"5m"` |  |
| clusterresourcesync.config.union.auth.type | string | `"ClientSecret"` |  |
| clusterresourcesync.config.union.connection.host | string | `"dns:///{{ tpl .Values.host . }}"` |  |
| clusterresourcesync.enabled | bool | `true` |  |
| clusterresourcesync.nodeSelector | object | `{}` |  |
| clusterresourcesync.podAnnotations | object | `{}` |  |
| clusterresourcesync.podEnv | object | `{}` |  |
| clusterresourcesync.resources.limits.cpu | string | `"1"` |  |
| clusterresourcesync.resources.limits.memory | string | `"500Mi"` |  |
| clusterresourcesync.resources.requests.cpu | string | `"500m"` |  |
| clusterresourcesync.resources.requests.memory | string | `"100Mi"` |  |
| clusterresourcesync.secretName | string | `"union-base"` |  |
| clusterresourcesync.serviceAccountName | string | `""` |  |
| clusterresourcesync.templates[0] | object | `{"key":"a_namespace.yaml","value":"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {{ namespace }}\n  labels:\n    union.ai/namespace-type: flyte\nspec:\n  finalizers:\n  - kubernetes\n"}` | Template for namespaces resources |
| clusterresourcesync.templates[1] | object | `{"key":"b_default_service_account.yaml","value":"apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: default\n  namespace: {{ namespace }}\n  annotations:\n    {{ defaultUserRoleKey }}: {{ defaultUserRoleValue }}\n"}` | Patch default service account |
| clusterresourcesync.templates[2].key | string | `"c_project_resource_quota.yaml"` |  |
| clusterresourcesync.templates[2].value | string | `"apiVersion: v1\nkind: ResourceQuota\nmetadata:\n  name: project-quota\n  namespace: {{ namespace }}\nspec:\n  hard:\n    limits.cpu: {{ projectQuotaCpu }}\n    limits.memory: {{ projectQuotaMemory }}\n    requests.nvidia.com/gpu: {{ projectQuotaNvidiaGpu }}\n"` |  |
| clusterresourcesync.unionCallbackEnabled | bool | `true` |  |
| config.admin | object | `{"admin":{"clientId":"{{ tpl .Values.secrets.admin.clientId . }}","clientSecretLocation":"/etc/union/secret/client_secret","endpoint":"dns:///{{ tpl .Values.host . }}","insecure":false},"event":{"capacity":1000,"rate":500,"type":"admin"}}` | Admin Client configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/subworkflow/launchplan#AdminConfig) |
| config.authorizer.type | string | `"noop"` |  |
| config.catalog | object | `{"catalog-cache":{"endpoint":"datacatalog:89","insecure":true,"type":"datacatalog"}}` | Catalog Client configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/catalog#Config) Additional advanced Catalog configuration [here](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/pluginmachinery/catalog#Config) |
| config.catalog_cache | object | `{}` |  |
| config.clusters.clusterConfigs | list | `[]` |  |
| config.clusters.labelClusterMap | object | `{}` |  |
| config.copilot | object | `{"plugins":{"k8s":{"co-pilot":{"image":"{{ .Values.image.flytecopilot.repository }}:{{ .Values.image.flytecopilot.tag }}","name":"flyte-copilot-","start-timeout":"30s"}}}}` | Copilot configuration |
| config.copilot.plugins.k8s.co-pilot | object | `{"image":"{{ .Values.image.flytecopilot.repository }}:{{ .Values.image.flytecopilot.tag }}","name":"flyte-copilot-","start-timeout":"30s"}` | Structure documented [here](https://pkg.go.dev/github.com/lyft/flyteplugins@v0.5.28/go/tasks/pluginmachinery/flytek8s/config#FlyteCoPilotConfig) |
| config.core | object | `{"propeller":{"downstream-eval-duration":"30s","enable-admin-launcher":true,"leader-election":{"enabled":true,"lease-duration":"15s","lock-config-map":{"name":"propeller-leader","namespace":"union"},"renew-deadline":"10s","retry-period":"2s"},"limit-namespace":"all","literal-offloading-config":{"enabled":true},"max-workflow-retries":30,"metadata-prefix":"metadata/propeller","metrics-prefix":"flyte","prof-port":10254,"queue":{"batch-size":-1,"batching-interval":"2s","queue":{"base-delay":"5s","capacity":1000,"max-delay":"120s","rate":100,"type":"maxof"},"sub-queue":{"capacity":100,"rate":10,"type":"bucket"},"type":"batch"},"rawoutput-prefix":"s3://{{ .Values.storage.bucketName }}","workers":4,"workflow-reeval-duration":"30s"},"webhook":{"certDir":"/etc/webhook/certs","serviceName":"flyte-pod-webhook"}}` | Core propeller configuration |
| config.core.propeller | object | `{"downstream-eval-duration":"30s","enable-admin-launcher":true,"leader-election":{"enabled":true,"lease-duration":"15s","lock-config-map":{"name":"propeller-leader","namespace":"union"},"renew-deadline":"10s","retry-period":"2s"},"limit-namespace":"all","literal-offloading-config":{"enabled":true},"max-workflow-retries":30,"metadata-prefix":"metadata/propeller","metrics-prefix":"flyte","prof-port":10254,"queue":{"batch-size":-1,"batching-interval":"2s","queue":{"base-delay":"5s","capacity":1000,"max-delay":"120s","rate":100,"type":"maxof"},"sub-queue":{"capacity":100,"rate":10,"type":"bucket"},"type":"batch"},"rawoutput-prefix":"s3://{{ .Values.storage.bucketName }}","workers":4,"workflow-reeval-duration":"30s"}` | follows the structure specified [here](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/config). |
| config.datacatalogServer | object | `{"application":{"grpcPort":8089,"grpcServerReflection":true,"httpPort":8080},"datacatalog":{"heartbeat-grace-period-multiplier":3,"max-reservation-heartbeat":"30s","metrics-scope":"datacatalog","profiler-port":10254,"storage-prefix":"metadata/datacatalog"}}` | Datacatalog server config |
| config.domain | object | `{"domains":[{"id":"development","name":"development"},{"id":"staging","name":"staging"},{"id":"production","name":"production"}]}` | Domains configuration for Flyte projects. This enables the specified number of domains across all projects in Flyte. |
| config.enabled_plugins.tasks | object | `{"task-plugins":{"default-for-task-types":{"container":"container","container_array":"k8s-array","sidecar":"sidecar"},"enabled-plugins":["container","sidecar","k8s-array","agent-service","echo"]}}` | Tasks specific configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/config#GetConfig) |
| config.enabled_plugins.tasks.task-plugins | object | `{"default-for-task-types":{"container":"container","container_array":"k8s-array","sidecar":"sidecar"},"enabled-plugins":["container","sidecar","k8s-array","agent-service","echo"]}` | Plugins configuration, [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/config#TaskPluginConfig) |
| config.enabled_plugins.tasks.task-plugins.enabled-plugins | list | `["container","sidecar","k8s-array","agent-service","echo"]` | [Enabled Plugins](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/config#Config). Enable sagemaker*, athena if you install the backend plugins |
| config.k8s | object | `{"plugins":{"k8s":{"default-cpus":"100m","default-env-vars":[],"default-memory":"100Mi"}}}` | Kubernetes specific Flyte configuration |
| config.k8s.plugins.k8s | object | `{"default-cpus":"100m","default-env-vars":[],"default-memory":"100Mi"}` | Configuration section for all K8s specific plugins [Configuration structure](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/pluginmachinery/flytek8s/config) |
| config.logger.level | int | `4` |  |
| config.logger.show-source | bool | `true` |  |
| config.operator.apps.enabled | bool | `false` |  |
| config.operator.clusterData.appId | string | `"{{ .Values.secrets.admin.clientId }}"` |  |
| config.operator.clusterData.bucketName | string | `"{{ .Values.storage.bucketName }}"` |  |
| config.operator.clusterData.bucketRegion | string | `"{{ .Values.storage.region }}"` |  |
| config.operator.clusterData.cloudHostName | string | `"{{ .Values.host }}"` |  |
| config.operator.clusterData.gcpProjectId | string | `"{{ .Values.storage.gcp.projectId }}"` |  |
| config.operator.clusterData.metadataBucketPrefix | string | `"s3://"` |  |
| config.operator.clusterData.storageType | string | `"{{ .Values.provider }}"` |  |
| config.operator.clusterData.userRole | string | `"{{ tpl (.Values.userRoleAnnotationValue | toString) $ }}"` |  |
| config.operator.clusterData.userRoleKey | string | `"{{ tpl (.Values.userRoleAnnotationKey | toString) $ }}"` |  |
| config.operator.clusterId.organization | string | `"{{ .Values.orgName }}"` |  |
| config.operator.collectUsages.enabled | bool | `true` |  |
| config.operator.customStorageConfig | string | `""` |  |
| config.operator.dependenciesHeartbeat.prometheus.endpoint | string | `"{{ include \"prometheus.health.url\" . }}"` |  |
| config.operator.dependenciesHeartbeat.propeller.endpoint | string | `"{{ include \"propeller.health.url\" . }}"` |  |
| config.operator.dependenciesHeartbeat.proxy.endpoint | string | `"{{ include \"proxy.health.url\" . }}"` |  |
| config.operator.enableTunnelService | bool | `true` |  |
| config.operator.enabled | bool | `true` |  |
| config.operator.syncClusterConfig.enabled | bool | `false` |  |
| config.qubole | object | `{}` |  |
| config.remoteData.remoteData.region | string | `"us-east-1"` |  |
| config.remoteData.remoteData.scheme | string | `"local"` |  |
| config.remoteData.remoteData.signedUrls.durationMinutes | int | `3` |  |
| config.resource_manager | object | `{"propeller":{"resourcemanager":{"type":"noop"}}}` | Resource manager configuration |
| config.resource_manager.propeller | object | `{"resourcemanager":{"type":"noop"}}` | resource manager configuration |
| config.schedulerConfig.scheduler.metricsScope | string | `"flyte:"` |  |
| config.schedulerConfig.scheduler.profilerPort | int | `10254` |  |
| config.task_logs | object | `{"plugins":{"logs":{"cloudwatch-enabled":false,"kubernetes-enabled":false}}}` | Section that configures how the Task logs are displayed on the UI. This has to be changed based on your actual logging provider. Refer to [structure](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/logs#LogConfig) to understand how to configure various logging engines |
| config.task_logs.plugins.logs.cloudwatch-enabled | bool | `false` | One option is to enable cloudwatch logging for EKS, update the region and log group accordingly |
| config.task_resource_defaults | object | `{"task_resources":{"defaults":{"cpu":"100m","memory":"500Mi"},"limits":{"cpu":2,"gpu":1,"memory":"1Gi"}}}` | Task default resources configuration Refer to the full [structure](https://pkg.go.dev/github.com/lyft/flyteadmin@v0.3.37/pkg/runtime/interfaces#TaskResourceConfiguration). |
| config.task_resource_defaults.task_resources | object | `{"defaults":{"cpu":"100m","memory":"500Mi"},"limits":{"cpu":2,"gpu":1,"memory":"1Gi"}}` | Task default resources parameters |
| config.union.auth.authorizationMetadataKey | string | `"flyte-authorization"` |  |
| config.union.auth.clientId | string | `"{{ .Values.secrets.admin.clientId }}"` |  |
| config.union.auth.clientSecretLocation | string | `"/etc/union/secret/client_secret"` |  |
| config.union.auth.tokenRefreshWindow | string | `"5m"` |  |
| config.union.auth.type | string | `"ClientSecret"` |  |
| config.union.connection.host | string | `"dns:///{{ .Values.host }}"` |  |
| databricks.enabled | bool | `false` |  |
| databricks.plugin_config | object | `{}` |  |
| dcgmExporter.affinity | object | `{}` |  |
| dcgmExporter.arguments[0] | string | `"-f"` |  |
| dcgmExporter.arguments[1] | string | `"/etc/dcgm-exporter/dcp-metrics-included.csv"` |  |
| dcgmExporter.extraHostVolumes[0].hostPath | string | `"/home/kubernetes/bin/nvidia"` |  |
| dcgmExporter.extraHostVolumes[0].name | string | `"nvidia-install-dir-host"` |  |
| dcgmExporter.extraVolumeMounts[0].mountPath | string | `"/usr/local/nvidia"` |  |
| dcgmExporter.extraVolumeMounts[0].name | string | `"nvidia-install-dir-host"` |  |
| dcgmExporter.extraVolumeMounts[0].readOnly | bool | `true` |  |
| dcgmExporter.kubeletPath | string | `"/var/lib/kubelet/pod-resources"` |  |
| dcgmExporter.podSecurityContext | object | `{}` |  |
| dcgmExporter.resources.limits.cpu | string | `"100m"` |  |
| dcgmExporter.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| dcgmExporter.resources.limits.memory | string | `"400Mi"` |  |
| dcgmExporter.resources.requests.cpu | string | `"100m"` |  |
| dcgmExporter.resources.requests.ephemeral-storage | string | `"500Mi"` |  |
| dcgmExporter.resources.requests.memory | string | `"128Mi"` |  |
| dcgmExporter.securityContext.capabilities.add[0] | string | `"SYS_ADMIN"` |  |
| dcgmExporter.securityContext.privileged | bool | `true` |  |
| dcgmExporter.securityContext.runAsNonRoot | bool | `false` |  |
| dcgmExporter.securityContext.runAsUser | int | `0` |  |
| dcgmExporter.serviceAccount.annotations | object | `{}` |  |
| dcgmExporter.serviceAccount.create | bool | `true` |  |
| dcgmExporter.serviceAccount.name | string | `"dcgm-exporter-system"` |  |
| dcgmExporter.tolerations | object | `{}` |  |
| flyteagent.enabled | bool | `false` |  |
| flyteagent.plugin_config | object | `{}` |  |
| flytepropeller.additionalContainers | object | `{}` |  |
| flytepropeller.additionalVolumeMounts | object | `{}` |  |
| flytepropeller.additionalVolumes | object | `{}` |  |
| flytepropeller.affinity | object | `{}` | affinity for Flytepropeller deployment |
| flytepropeller.cacheSizeMbs | int | `0` |  |
| flytepropeller.configPath | string | `"/etc/flyte/config/*.yaml"` | Default regex string for searching configuration files |
| flytepropeller.enabled | bool | `true` |  |
| flytepropeller.extraArgs | object | `{}` | extra arguments to pass to propeller. |
| flytepropeller.nodeSelector | object | `{}` | nodeSelector for Flytepropeller deployment |
| flytepropeller.podAnnotations | object | `{}` | Annotations for Flytepropeller pods |
| flytepropeller.podEnv | object | `{}` |  |
| flytepropeller.podLabels | object | `{}` | Labels for the Flytepropeller pods |
| flytepropeller.priorityClassName | string | `"system-cluster-critical"` |  |
| flytepropeller.replicaCount | int | `1` | Replicas count for Flytepropeller deployment |
| flytepropeller.resources | object | `{"limits":{"cpu":"1","ephemeral-storage":"500Mi","memory":"2Gi"},"requests":{"cpu":"1","ephemeral-storage":"500Mi","memory":"2Gi"}}` | Default resources requests and limits for Flytepropeller deployment |
| flytepropeller.service.additionalPorts[0].name | string | `"fasttask"` |  |
| flytepropeller.service.additionalPorts[0].port | int | `15605` |  |
| flytepropeller.service.additionalPorts[0].protocol | string | `"TCP"` |  |
| flytepropeller.service.additionalPorts[0].targetPort | int | `15605` |  |
| flytepropeller.service.enabled | bool | `true` |  |
| flytepropeller.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for FlytePropeller |
| flytepropeller.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to FlytePropeller pods |
| flytepropeller.serviceAccount.create | bool | `true` | Should a service account be created for FlytePropeller |
| flytepropeller.serviceAccount.imagePullSecrets | list | `[]` | ImapgePullSecrets to automatically assign to the service account |
| flytepropeller.terminationMessagePolicy | string | `""` |  |
| flytepropeller.tolerations | list | `[]` | tolerations for Flytepropeller deployment |
| flytepropellerwebhook.autoscaling.enabled | bool | `false` |  |
| flytepropellerwebhook.autoscaling.maxReplicas | int | `10` |  |
| flytepropellerwebhook.autoscaling.metrics[0].resource.name | string | `"cpu"` |  |
| flytepropellerwebhook.autoscaling.metrics[0].resource.target.averageUtilization | int | `80` |  |
| flytepropellerwebhook.autoscaling.metrics[0].resource.target.type | string | `"Utilization"` |  |
| flytepropellerwebhook.autoscaling.metrics[0].type | string | `"Resource"` |  |
| flytepropellerwebhook.autoscaling.metrics[1].resource.name | string | `"memory"` |  |
| flytepropellerwebhook.autoscaling.metrics[1].resource.target.averageUtilization | int | `80` |  |
| flytepropellerwebhook.autoscaling.metrics[1].resource.target.type | string | `"Utilization"` |  |
| flytepropellerwebhook.autoscaling.metrics[1].type | string | `"Resource"` |  |
| flytepropellerwebhook.autoscaling.minReplicas | int | `1` |  |
| flytepropellerwebhook.enabled | bool | `true` | enable or disable secrets webhook |
| flytepropellerwebhook.nodeSelector | object | `{}` | nodeSelector for webhook deployment |
| flytepropellerwebhook.podAnnotations | object | `{}` | Annotations for webhook pods |
| flytepropellerwebhook.podEnv | object | `{}` | Additional webhook container environment variables |
| flytepropellerwebhook.podLabels | object | `{}` | Labels for webhook pods |
| flytepropellerwebhook.priorityClassName | string | `""` | Sets priorityClassName for webhook pod |
| flytepropellerwebhook.replicaCount | int | `1` | Replicas |
| flytepropellerwebhook.resources.requests.cpu | string | `"200m"` |  |
| flytepropellerwebhook.resources.requests.ephemeral-storage | string | `"500Mi"` |  |
| flytepropellerwebhook.resources.requests.memory | string | `"500Mi"` |  |
| flytepropellerwebhook.securityContext | object | `{"fsGroup":65534,"fsGroupChangePolicy":"Always","runAsNonRoot":true,"runAsUser":1001,"seLinuxOptions":{"type":"spc_t"}}` | Sets securityContext for webhook pod(s). |
| flytepropellerwebhook.service | object | `{"annotations":{"projectcontour.io/upstream-protocol.h2c":"grpc"},"type":"ClusterIP"}` | Service settings for the webhook |
| flytepropellerwebhook.serviceAccount | object | `{"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for the webhook |
| flytepropellerwebhook.serviceAccount.create | bool | `true` | Should a service account be created for the webhook |
| flytepropellerwebhook.serviceAccount.imagePullSecrets | list | `[]` | ImagePullSecrets to automatically assign to the service account |
| fullnameOverride | string | `""` |  |
| host | string | `"foo.unionai.cloud"` |  |
| image.dcgmExporter.pullPolicy | string | `"IfNotPresent"` |  |
| image.dcgmExporter.repository | string | `"nvcr.io/nvidia/k8s/dcgm-exporter"` |  |
| image.dcgmExporter.tag | string | `"3.1.7-3.1.4-ubuntu20.04"` |  |
| image.flytecopilot.pullPolicy | string | `"IfNotPresent"` |  |
| image.flytecopilot.repository | string | `"cr.flyte.org/flyteorg/flytecopilot"` |  |
| image.flytecopilot.tag | string | `"v1.14.1"` |  |
| image.kubeStateMetrics.pullPolicy | string | `"IfNotPresent"` |  |
| image.kubeStateMetrics.repository | string | `"registry.k8s.io/kube-state-metrics/kube-state-metrics"` |  |
| image.kubeStateMetrics.tag | string | `"v2.11.0"` |  |
| image.tunnel.pullPolicy | string | `"IfNotPresent"` |  |
| image.tunnel.repository | string | `"cloudflare/cloudflared"` |  |
| image.tunnel.tag | string | `"2024.6.1"` |  |
| image.union.pullPolicy | string | `"IfNotPresent"` |  |
| image.union.repository | string | `"public.ecr.aws/p0i0a9q8/unionoperator"` |  |
| image.union.tag | string | `"2025.01.0"` |  |
| integration.databricks | bool | `false` |  |
| integration.ray | bool | `false` |  |
| integration.spark | bool | `false` |  |
| monitoring.dcgmExporter.enabled | bool | `false` |  |
| monitoring.kubeStateMetrics.enabled | bool | `false` |  |
| monitoring.prometheus.enabled | bool | `true` |  |
| nameOverride | string | `""` |  |
| objectStore.service.grpcPort | int | `8089` |  |
| objectStore.service.httpPort | int | `8080` |  |
| operator.affinity | object | `{}` |  |
| operator.autoscaling.enabled | bool | `false` |  |
| operator.autoscaling.maxReplicas | int | `20` |  |
| operator.autoscaling.minReplicas | int | `1` |  |
| operator.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| operator.enableTunnelService | bool | `true` |  |
| operator.imagePullSecrets | object | `{}` |  |
| operator.nodeSelector | object | `{}` |  |
| operator.podAnnotations | object | `{}` |  |
| operator.podEnv | object | `{}` |  |
| operator.podLabels | object | `{}` |  |
| operator.podSecurityContext | object | `{}` |  |
| operator.priorityClassName | string | `""` |  |
| operator.replicas | int | `1` |  |
| operator.resources.limits.cpu | string | `"1"` |  |
| operator.resources.limits.memory | string | `"500Mi"` |  |
| operator.resources.requests.cpu | string | `"500m"` |  |
| operator.resources.requests.memory | string | `"100Mi"` |  |
| operator.secretName | string | `"union-secret-auth"` |  |
| operator.securityContext | object | `{}` |  |
| operator.serviceAccount.create | bool | `true` |  |
| operator.serviceAccount.name | string | `"operator-system"` |  |
| operator.tolerations | list | `[]` |  |
| orgName | string | `""` |  |
| prometheus.additionalPrometheusRulesMap | object | `{}` |  |
| prometheus.alertmanager.enabled | bool | `false` |  |
| prometheus.crds.enabled | bool | `true` |  |
| prometheus.defaultRules.create | bool | `false` |  |
| prometheus.defaultRules.rules.alertmanager | bool | `false` |  |
| prometheus.defaultRules.rules.configReloaders | bool | `false` |  |
| prometheus.defaultRules.rules.etcd | bool | `false` |  |
| prometheus.defaultRules.rules.general | bool | `false` |  |
| prometheus.defaultRules.rules.k8sContainerCpuUsageSecondsTotal | bool | `false` |  |
| prometheus.defaultRules.rules.k8sContainerMemoryCache | bool | `false` |  |
| prometheus.defaultRules.rules.k8sContainerMemoryRss | bool | `false` |  |
| prometheus.defaultRules.rules.k8sContainerMemorySwap | bool | `false` |  |
| prometheus.defaultRules.rules.k8sContainerMemoryWorkingSetBytes | bool | `false` |  |
| prometheus.defaultRules.rules.k8sContainerResource | bool | `false` |  |
| prometheus.defaultRules.rules.k8sPodOwner | bool | `false` |  |
| prometheus.defaultRules.rules.kubeApiserverAvailability | bool | `false` |  |
| prometheus.defaultRules.rules.kubeApiserverBurnrate | bool | `false` |  |
| prometheus.defaultRules.rules.kubeApiserverHistogram | bool | `false` |  |
| prometheus.defaultRules.rules.kubeApiserverSlos | bool | `false` |  |
| prometheus.defaultRules.rules.kubeControllerManager | bool | `false` |  |
| prometheus.defaultRules.rules.kubePrometheusGeneral | bool | `false` |  |
| prometheus.defaultRules.rules.kubePrometheusNodeRecording | bool | `false` |  |
| prometheus.defaultRules.rules.kubeProxy | bool | `false` |  |
| prometheus.defaultRules.rules.kubeSchedulerAlerting | bool | `false` |  |
| prometheus.defaultRules.rules.kubeSchedulerRecording | bool | `false` |  |
| prometheus.defaultRules.rules.kubeStateMetrics | bool | `false` |  |
| prometheus.defaultRules.rules.kubelet | bool | `false` |  |
| prometheus.defaultRules.rules.kubernetesApps | bool | `false` |  |
| prometheus.defaultRules.rules.kubernetesResources | bool | `false` |  |
| prometheus.defaultRules.rules.kubernetesStorage | bool | `false` |  |
| prometheus.defaultRules.rules.kubernetesSystem | bool | `false` |  |
| prometheus.defaultRules.rules.network | bool | `false` |  |
| prometheus.defaultRules.rules.node | bool | `false` |  |
| prometheus.defaultRules.rules.nodeExporterAlerting | bool | `false` |  |
| prometheus.defaultRules.rules.nodeExporterRecording | bool | `false` |  |
| prometheus.defaultRules.rules.prometheus | bool | `false` |  |
| prometheus.defaultRules.rules.prometheusOperator | bool | `false` |  |
| prometheus.defaultRules.rules.windows | bool | `false` |  |
| prometheus.fullnameOverride | string | `"union"` |  |
| prometheus.grafana.enabled | bool | `false` |  |
| prometheus.ingress.annotations | object | `{}` |  |
| prometheus.ingress.enabled | bool | `false` |  |
| prometheus.ingress.hosts | list | `[]` |  |
| prometheus.kube-state-metrics.namespaceOverride | string | `"kube-system"` |  |
| prometheus.nameOverride | string | `""` |  |
| prometheus.namespaceOverride | string | `"union"` |  |
| prometheus.nodeExporter.enabled | bool | `false` |  |
| prometheus.prometheus-node-exporter.namespaceOverride | string | `"kube-system"` |  |
| prometheus.prometheus.enabled | bool | `true` |  |
| prometheus.prometheus.prometheusSpec.resources.resources.limits.cpu | string | `"1"` |  |
| prometheus.prometheus.prometheusSpec.resources.resources.limits.memory | string | `"2Gi"` |  |
| prometheus.prometheus.prometheusSpec.resources.resources.requests.cpu | string | `"1"` |  |
| prometheus.prometheus.prometheusSpec.resources.resources.requests.memory | string | `"2Gi"` |  |
| prometheus.prometheusOperator.fullnameOverride | string | `"prometheus-operator"` |  |
| provider | string | `"metal"` |  |
| proxy.affinity | object | `{}` |  |
| proxy.autoscaling.enabled | bool | `false` |  |
| proxy.autoscaling.maxReplicas | int | `10` |  |
| proxy.autoscaling.minReplicas | int | `1` |  |
| proxy.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| proxy.enableTunnelService | bool | `true` |  |
| proxy.imagePullSecrets | object | `{}` |  |
| proxy.nodeSelector | object | `{}` |  |
| proxy.podAnnotations | object | `{}` |  |
| proxy.podEnv | object | `{}` |  |
| proxy.podLabels | object | `{}` |  |
| proxy.podSecurityContext | object | `{}` |  |
| proxy.priorityClassName | string | `""` |  |
| proxy.replicas | int | `1` |  |
| proxy.resources.limits.cpu | string | `"1"` |  |
| proxy.resources.limits.memory | string | `"500Mi"` |  |
| proxy.resources.requests.cpu | string | `"500m"` |  |
| proxy.resources.requests.memory | string | `"100Mi"` |  |
| proxy.secretName | string | `"union-secret-auth"` |  |
| proxy.securityContext | object | `{}` |  |
| proxy.serviceAccount.create | bool | `true` |  |
| proxy.serviceAccount.name | string | `"proxy-system"` |  |
| proxy.tolerations | list | `[]` |  |
| resourcequota.create | bool | `false` |  |
| secrets.admin.clientId | string | `"dataplane-operator"` |  |
| secrets.admin.clientSecret | string | `""` |  |
| secrets.admin.create | bool | `true` |  |
| sparkoperator.enabled | bool | `false` |  |
| sparkoperator.plugin_config | object | `{}` |  |
| storage.accessKey | string | `""` |  |
| storage.authType | string | `"accesskey"` |  |
| storage.bucketName | string | `""` |  |
| storage.cache.maxSizeMBs | int | `0` |  |
| storage.cache.targetGCPercent | int | `70` |  |
| storage.custom | object | `{}` |  |
| storage.disableSSL | bool | `false` |  |
| storage.enableMultiContainer | bool | `false` |  |
| storage.endpoint | string | `""` |  |
| storage.fastRegistrationBucketName | string | `""` |  |
| storage.gcp.projectId | string | `""` |  |
| storage.injectPodEnvVars | bool | `true` |  |
| storage.limits.maxDownloadMBs | int | `10` |  |
| storage.provider | string | `"compat"` |  |
| storage.region | string | `"us-east-1"` |  |
| storage.secretKey | string | `""` |  |
| userRoleAnnotationKey | string | `"eks.amazonaws.com/role-arn"` |  |
| userRoleAnnotationValue | string | `"arn:aws:iam::ACCOUNT_ID:role/flyte_project_role"` |  |

