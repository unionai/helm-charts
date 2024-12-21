# union-operator

![Version: 2024.12.2](https://img.shields.io/badge/Version-2024.12.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2024.12.2](https://img.shields.io/badge/AppVersion-2024.12.2-informational?style=flat-square)

Deploys Union Operator to onboard a k8s cluster to Union Cloud

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| file://../flyte-core | union(flyte-core) | 2024.12.2 |
| https://opencost.github.io/opencost-helm-chart | opencost | 1.42.0 |
| https://prometheus-community.github.io/helm-charts | kube-prometheus-stack | 59.1.0 |

### SANDBOX INSTALLATION:
- [Install helm 3](https://helm.sh/docs/intro/install/)
- Install Union Operator:

```bash
helm repo add unionai https://unionai.github.io/unionoperator/
helm repo update
helm install -n union-operator -f values.yaml --create-namespace union-operator unionai/union-operator
```

Customize your installation by changing settings in a new file `values.yaml`.

Then apply your changes:
```bash
helm upgrade -f values.yaml union-operator unionai/union-operator -n union-operator
```

### CONFIGURATION NOTES:

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| dgxagent.additionalContainers | list | `[]` | Appends additional containers to the deployment spec. May include template values. |
| dgxagent.additionalEnvs | list | `[]` | Appends additional envs to the deployment spec. May include template values |
| dgxagent.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| dgxagent.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| dgxagent.affinity | object | `{}` | affinity for flyteagent deployment |
| dgxagent.autoscaling.maxReplicas | int | `5` |  |
| dgxagent.autoscaling.minReplicas | int | `2` |  |
| dgxagent.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| dgxagent.autoscaling.targetMemoryUtilizationPercentage | int | `80` |  |
| dgxagent.configPath | string | `"/etc/flyteagent/config/*.yaml"` | Default glob string for searching configuration files |
| dgxagent.enabled | bool | `false` |  |
| dgxagent.extraArgs | object | `{}` | Appends extra command line arguments to the main command |
| dgxagent.image.pullPolicy | string | `"Always"` | Docker image pull policy |
| dgxagent.image.repository | string | `"ghcr.io/unionai/dgx-agent"` | Docker image for flyteagent deployment |
| dgxagent.image.tag | string | `"v1"` | Docker image tag |
| dgxagent.nodeSelector | object | `{}` | nodeSelector for flyteagent deployment |
| dgxagent.podAnnotations | object | `{}` | Annotations for flyteagent pods |
| dgxagent.ports.containerPort | int | `8000` |  |
| dgxagent.ports.name | string | `"agent-grpc"` |  |
| dgxagent.priorityClassName | string | `""` | Sets priorityClassName for datacatalog pod(s). |
| dgxagent.prometheusPort.containerPort | int | `9090` |  |
| dgxagent.prometheusPort.name | string | `"agent-metric"` |  |
| dgxagent.replicaCount | int | `2` | Replicas count for flyteagent deployment |
| dgxagent.resources | object | `{"limits":{"cpu":"1.5","ephemeral-storage":"100Mi","memory":"3000Mi"},"requests":{"cpu":"1","ephemeral-storage":"100Mi","memory":"2000Mi"}}` | Default resources requests and limits for flyteagent deployment |
| dgxagent.service | object | `{"clusterIP":"None","type":"ClusterIP"}` | Service settings for flyteagent |
| dgxagent.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for flyteagent |
| dgxagent.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to flyteagent pods |
| dgxagent.serviceAccount.create | bool | `true` | Should a service account be created for flyteagent |
| dgxagent.serviceAccount.imagePullSecrets | list | `[]` | ImagePullSecrets to automatically assign to the service account |
| dgxagent.tolerations | list | `[]` | tolerations for flyteagent deployment |
| flyteagent.additionalContainers | list | `[]` | Appends additional containers to the deployment spec. May include template values. |
| flyteagent.additionalEnvs | list | `[]` | Appends additional envs to the deployment spec. May include template values |
| flyteagent.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| flyteagent.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| flyteagent.affinity | object | `{}` | affinity for flyteagent deployment |
| flyteagent.autoscaling.maxReplicas | int | `5` |  |
| flyteagent.autoscaling.minReplicas | int | `2` |  |
| flyteagent.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| flyteagent.autoscaling.targetMemoryUtilizationPercentage | int | `80` |  |
| flyteagent.configPath | string | `"/etc/flyteagent/config/*.yaml"` | Default glob string for searching configuration files |
| flyteagent.enabled | bool | `false` |  |
| flyteagent.extraArgs | object | `{}` | Appends extra command line arguments to the main command |
| flyteagent.image.pullPolicy | string | `"IfNotPresent"` | Docker image pull policy |
| flyteagent.image.repository | string | `"ghcr.io/unionai/flyte-conformance-agent"` | Docker image for flyteagent deployment |
| flyteagent.image.tag | string | `"cec690330a330bfd68b4e68215676fb994b32796"` | Docker image tag https://github.com/unionai/flyte-conformance/blob/main/mock_agent/Dockerfile https://github.com/unionai/flyte-conformance/pkgs/container/flyte-conformance-agent |
| flyteagent.nodeSelector | object | `{}` | nodeSelector for flyteagent deployment |
| flyteagent.podAnnotations | object | `{}` | Annotations for flyteagent pods |
| flyteagent.ports.containerPort | int | `8000` |  |
| flyteagent.ports.name | string | `"agent-grpc"` |  |
| flyteagent.priorityClassName | string | `""` | Sets priorityClassName for datacatalog pod(s). |
| flyteagent.prometheusPort.containerPort | int | `9090` |  |
| flyteagent.prometheusPort.name | string | `"agent-metric"` |  |
| flyteagent.replicaCount | int | `2` | Replicas count for flyteagent deployment |
| flyteagent.resources | object | `{"limits":{"cpu":"1.5","ephemeral-storage":"100Mi","memory":"1500Mi"},"requests":{"cpu":"1","ephemeral-storage":"100Mi","memory":"1000Mi"}}` | Default resources requests and limits for flyteagent deployment |
| flyteagent.service | object | `{"clusterIP":"None","type":"ClusterIP"}` | Service settings for flyteagent |
| flyteagent.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for flyteagent |
| flyteagent.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to flyteagent pods |
| flyteagent.serviceAccount.create | bool | `true` | Should a service account be created for flyteagent |
| flyteagent.serviceAccount.imagePullSecrets | list | `[]` | ImagePullSecrets to automatically assign to the service account |
| flyteagent.tolerations | list | `[]` | tolerations for flyteagent deployment |
| kube-prometheus-stack.additionalPrometheusRulesMap | object | `{}` |  |
| kube-prometheus-stack.alertmanager.enabled | bool | `false` |  |
| kube-prometheus-stack.cleanPrometheusOperatorObjectNames | bool | `true` |  |
| kube-prometheus-stack.commonLabels | object | `{}` |  |
| kube-prometheus-stack.coreDns.enabled | bool | `false` |  |
| kube-prometheus-stack.crds.enabled | bool | `false` |  |
| kube-prometheus-stack.defaultRules.create | bool | `false` |  |
| kube-prometheus-stack.fullnameOverride | string | `"metrics"` |  |
| kube-prometheus-stack.global.rbac.create | bool | `false` |  |
| kube-prometheus-stack.grafana.enabled | bool | `false` |  |
| kube-prometheus-stack.kubeApiServer.enabled | bool | `false` |  |
| kube-prometheus-stack.kubeControllerManager.enabled | bool | `false` |  |
| kube-prometheus-stack.kubeEtcd.enabled | bool | `false` |  |
| kube-prometheus-stack.kubeProxy.enabled | bool | `false` |  |
| kube-prometheus-stack.kubeScheduler.enabled | bool | `false` |  |
| kube-prometheus-stack.kubeStateMetrics.enabled | bool | `false` |  |
| kube-prometheus-stack.kubelet.enabled | bool | `false` |  |
| kube-prometheus-stack.kubernetesServiceMonitors.enabled | bool | `false` |  |
| kube-prometheus-stack.nodeExporter.enabled | bool | `true` |  |
| kube-prometheus-stack.nodeExporter.operatingSystems.darwin.enabled | bool | `false` |  |
| kube-prometheus-stack.nodeExporter.operatingSystems.linux.enabled | bool | `true` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[0] | string | `"--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[10] | string | `"--no-collector.filefd"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[11] | string | `"--no-collector.hwmon"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[12] | string | `"--no-collector.infiniband"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[13] | string | `"--no-collector.ipvs"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[14] | string | `"--no-collector.nfs"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[15] | string | `"--no-collector.nfsd"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[16] | string | `"--no-collector.powersupplyclass"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[17] | string | `"--no-collector.rapl"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[18] | string | `"--no-collector.schedstat"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[19] | string | `"--no-collector.sockstat"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[1] | string | `"--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|tmpfs)$"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[20] | string | `"--no-collector.softnet"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[21] | string | `"--no-collector.textfile"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[22] | string | `"--no-collector.thermal_zone"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[23] | string | `"--no-collector.timex"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[24] | string | `"--no-collector.udp_queues"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[25] | string | `"--no-collector.mdadm"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[26] | string | `"--collector.conntrack"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[2] | string | `"--no-collector.arp"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[3] | string | `"--no-collector.bonding"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[4] | string | `"--no-collector.btrfs"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[5] | string | `"--no-collector.cpufreq"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[6] | string | `"--no-collector.edac"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[7] | string | `"--no-collector.ethtool"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[8] | string | `"--no-collector.entropy"` |  |
| kube-prometheus-stack.prometheus-node-exporter.extraArgs[9] | string | `"--no-collector.fibrechannel"` |  |
| kube-prometheus-stack.prometheus-node-exporter.namespaceOverride | string | `"kube-system"` |  |
| kube-prometheus-stack.prometheus-node-exporter.priorityClassName | string | `"system-node-critical"` |  |
| kube-prometheus-stack.prometheus-node-exporter.prometheus.monitor.enabled | bool | `false` |  |
| kube-prometheus-stack.prometheus-node-exporter.prometheus.podMonitor.enabled | bool | `false` |  |
| kube-prometheus-stack.prometheus-node-exporter.resources.limits.cpu | string | `"50m"` |  |
| kube-prometheus-stack.prometheus-node-exporter.resources.limits.memory | string | `"100Mi"` |  |
| kube-prometheus-stack.prometheus-node-exporter.resources.requests.cpu | string | `"10m"` |  |
| kube-prometheus-stack.prometheus-node-exporter.resources.requests.memory | string | `"10Mi"` |  |
| kube-prometheus-stack.prometheus-node-exporter.updateStrategy.rollingUpdate.maxUnavailable | string | `"25%"` |  |
| kube-prometheus-stack.prometheus-node-exporter.updateStrategy.type | string | `"RollingUpdate"` |  |
| kube-prometheus-stack.prometheus.enabled | bool | `false` |  |
| kube-prometheus-stack.prometheusOperator.enabled | bool | `false` |  |
| kueue-resources.enabled | bool | `false` |  |
| minio.affinity | object | `{}` | affinity for Minio deployment |
| minio.image.pullPolicy | string | `"IfNotPresent"` | Docker image pull policy |
| minio.image.repository | string | `"ecr.flyte.org/bitnami/minio"` | Docker image for Minio deployment |
| minio.image.tag | string | `"2021.10.13-debian-10-r0"` | Docker image tag |
| minio.nodeSelector | object | `{}` | nodeSelector for Minio deployment |
| minio.persistence.enabled | bool | `false` |  |
| minio.persistence.persistentVolumeClaimName | string | `""` |  |
| minio.podAnnotations | object | `{}` | Annotations for Minio pods |
| minio.replicaCount | int | `1` | Replicas count for Minio deployment |
| minio.resources | object | `{"limits":{"cpu":"200m","memory":"512Mi"},"requests":{"cpu":"10m","memory":"128Mi"}}` | Default resources requests and limits for Minio deployment |
| minio.resources.limits | object | `{"cpu":"200m","memory":"512Mi"}` | Limits are the maximum set of resources needed for this pod |
| minio.resources.requests | object | `{"cpu":"10m","memory":"128Mi"}` | Requests are the minimum set of resources needed for this pod |
| minio.service | object | `{"annotations":{},"type":"ClusterIP"}` | Service settings for Minio |
| minio.tolerations | list | `[]` | tolerations for Minio deployment |
| opencost.fullnameOverride | string | `"opencost"` |  |
| opencost.opencost.exporter.resources.limits.cpu | string | `"1000m"` |  |
| opencost.opencost.exporter.resources.limits.memory | string | `"2Gi"` |  |
| opencost.opencost.exporter.resources.requests.cpu | string | `"500m"` |  |
| opencost.opencost.exporter.resources.requests.memory | string | `"500Mi"` |  |
| opencost.opencost.prometheus.external.enabled | bool | `false` |  |
| opencost.opencost.prometheus.internal.enabled | bool | `false` |  |
| opencost.opencost.ui.enabled | bool | `false` |  |
| serving.enabled | bool | `false` | Enables the serving component. Installs Knative Serving. Knative-Operator must be running in the cluster for this to work. |
| serving.metrics | bool | `false` | Enables scraping of metrics from the serving component |
| serving.replicas | int | `2` | The number of replicas to create for all components for high availability. |
| taskNamespaceNetworkPolicy.blockIMDS | bool | `true` | Blocks pods in task namespaces from accessing metadata server and from retrieving cloud provider credentials |
| taskNamespaceNetworkPolicy.blockInternalIPs | bool | `true` | Blocks pods in task namespaces from accessing internal IPs other than kube-dns and union-operator namespace |
| taskNamespaceNetworkPolicy.enabled | bool | `false` | Enables a global network policy for task namespaces |
| taskNamespaceNetworkPolicy.selector | string | `"union.ai/namespace-type == \"flyte\""` | Selector for task namespaces |
| union.appId | string | `"<App Id from uctl create app>"` |  |
| union.cacheservice.enabled | bool | `false` |  |
| union.cloudUrl | string | `"<Union Cloud URL>"` |  |
| union.clusterName | string | `""` |  |
| union.cluster_resource_manager.config.clusterResourcesPrivate.app.isSelfServe | bool | `false` |  |
| union.cluster_resource_manager.config.cluster_resources.clusterName | string | `"{{ include \"getClusterName\" . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[0].production[0].projectQuotaCpu.value | string | `"4096"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[0].production[1].projectQuotaMemory.value | string | `"2Ti"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[0].production[2].projectQuotaNvidiaGpu.value | string | `"256"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[0].production[3].defaultUserRoleKey.value | string | `"{{ tpl .Values.userRoleAnnotationKey . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[0].production[4].defaultUserRoleValue.value | string | `"{{ tpl .Values.userRoleAnnotationValue . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[1].staging[0].projectQuotaCpu.value | string | `"4096"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[1].staging[1].projectQuotaMemory.value | string | `"2Ti"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[1].staging[2].projectQuotaNvidiaGpu.value | string | `"256"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[1].staging[3].defaultUserRoleKey.value | string | `"{{ tpl .Values.userRoleAnnotationKey . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[1].staging[4].defaultUserRoleValue.value | string | `"{{ tpl .Values.userRoleAnnotationValue . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[2].development[0].projectQuotaCpu.value | string | `"4096"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[2].development[1].projectQuotaMemory.value | string | `"2Ti"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[2].development[2].projectQuotaNvidiaGpu.value | string | `"256"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[2].development[3].defaultUserRoleKey.value | string | `"{{ tpl .Values.userRoleAnnotationKey . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.customData[2].development[4].defaultUserRoleValue.value | string | `"{{ tpl .Values.userRoleAnnotationValue . }}"` |  |
| union.cluster_resource_manager.config.cluster_resources.standaloneDeployment | bool | `true` |  |
| union.cluster_resource_manager.config.union.auth.authorizationMetadataKey | string | `"flyte-authorization"` |  |
| union.cluster_resource_manager.config.union.auth.clientId | string | `"{{ tpl .Values.appId . }}"` |  |
| union.cluster_resource_manager.config.union.auth.clientSecretLocation | string | `"/etc/union/secret/app_secret"` |  |
| union.cluster_resource_manager.config.union.auth.tokenRefreshWindow | string | `"5m"` |  |
| union.cluster_resource_manager.config.union.auth.type | string | `"ClientSecret"` |  |
| union.cluster_resource_manager.config.union.connection.host | string | `"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}"` |  |
| union.cluster_resource_manager.enabled | bool | `true` |  |
| union.cluster_resource_manager.image.repository | string | `"public.ecr.aws/p0i0a9q8/unionoperator"` |  |
| union.cluster_resource_manager.image.tag | string | `"2024.12.2"` |  |
| union.cluster_resource_manager.podEnv[0].name | string | `"GOMEMLIMIT"` |  |
| union.cluster_resource_manager.podEnv[0].valueFrom.resourceFieldRef.resource | string | `"limits.memory"` |  |
| union.cluster_resource_manager.podEnv[1].name | string | `"GOMAXPROCS"` |  |
| union.cluster_resource_manager.podEnv[1].valueFrom.resourceFieldRef.resource | string | `"limits.cpu"` |  |
| union.cluster_resource_manager.prometheus.enabled | bool | `true` |  |
| union.cluster_resource_manager.resources.limits.cpu | string | `"1"` |  |
| union.cluster_resource_manager.resources.limits.memory | string | `"500Mi"` |  |
| union.cluster_resource_manager.resources.requests.cpu | string | `"500m"` |  |
| union.cluster_resource_manager.resources.requests.memory | string | `"100Mi"` |  |
| union.cluster_resource_manager.rootCommand | string | `"clusterresource"` |  |
| union.cluster_resource_manager.secretName | string | `"union-base"` |  |
| union.cluster_resource_manager.service_account_name | string | `"clustersync-resource"` |  |
| union.cluster_resource_manager.standalone_deploy | bool | `true` |  |
| union.cluster_resource_manager.templates[0] | object | `{"key":"a_namespace.yaml","value":"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {{ namespace }}\n  labels:\n    union.ai/namespace-type: flyte\nspec:\n  finalizers:\n  - kubernetes\n"}` | Template for namespaces resources |
| union.cluster_resource_manager.templates[1] | object | `{"key":"b_default_service_account.yaml","value":"apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: default\n  namespace: {{ namespace }}\n  annotations:\n    {{ defaultUserRoleKey }}: {{ defaultUserRoleValue }}\n"}` | Patch default service account |
| union.cluster_resource_manager.templates[2].key | string | `"c_project_resource_quota.yaml"` |  |
| union.cluster_resource_manager.templates[2].value | string | `"apiVersion: v1\nkind: ResourceQuota\nmetadata:\n  name: project-quota\n  namespace: {{ namespace }}\nspec:\n  hard:\n    limits.cpu: {{ projectQuotaCpu }}\n    limits.memory: {{ projectQuotaMemory }}\n    requests.nvidia.com/gpu: {{ projectQuotaNvidiaGpu }}\n"` |  |
| union.cluster_resource_manager.unionCallbackEnabled | bool | `true` |  |
| union.collectUsages.enabled | bool | `true` |  |
| union.common.ingress.enabled | bool | `false` |  |
| union.computeResourceManager.enabled | bool | `false` |  |
| union.computeResourceManager.type | string | `""` |  |
| union.configmap | object | `{"admin":{"admin":{"clientId":"{{ tpl .Values.appId . }}","clientSecretLocation":"/etc/secrets/client_secret","endpoint":"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}","insecure":false},"event":{"capacity":1000,"rate":500,"type":"admin"}},"catalog":{"catalog-cache":{"cache-endpoint":"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}","endpoint":"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}","insecure":false,"type":"fallback","use-admin-auth":true}},"copilot":{"plugins":{"k8s":{"co-pilot":{"image":"public.ecr.aws/unionai-flyte/flytecopilot:invalid-version","name":"flyte-copilot-","start-timeout":"30s"}}}},"core":{"cache":{"max_size_mbs":1024,"target_gc_percent":70},"manager":{"shard":{"shard-count":3,"type":"Hash"}},"propeller":{"event-config":{"raw-output-policy":"inline"},"gc-interval":"12h","kube-client-config":{"burst":25,"qps":100,"timeout":"30s"},"leader-election":{"enabled":false},"max-workflow-retries":50,"queue":{"batch-size":-1,"batching-interval":"1s","queue":{"base-delay":"0s","capacity":10000,"max-delay":"60s","rate":1000,"type":"maxof"},"sub-queue":{"capacity":10000,"rate":1000,"type":"bucket"},"type":"batch"},"rawoutput-prefix":"{{ tpl .Values.metadataBucketPrefix $ }}","workers":100},"webhook":{"certDir":"/etc/webhook/certs","serviceName":"flyte-pod-webhook"}},"enabled_plugins":{"tasks":{"task-plugins":{"default-for-task-types":{"container":"container","container_array":"k8s-array","sidecar":"sidecar"},"enabled-plugins":["container","echo","sidecar","k8s-array"]}}},"k8s":{"plugins":{"k8s":{"default-cpus":"100m","default-memory":"100Mi"}}},"logger":{"logger":{"level":4,"show-source":true}},"resource_manager":{"propeller":{"resourcemanager":{"type":"noop"}}},"task_logs":{"plugins":{"logs":{"cloudwatch-enabled":false,"kubernetes-enabled":true}}}}` | ----------------------------------------------------------------- CONFIGMAPS SETTINGS |
| union.configmap.admin | object | `{"admin":{"clientId":"{{ tpl .Values.appId . }}","clientSecretLocation":"/etc/secrets/client_secret","endpoint":"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}","insecure":false},"event":{"capacity":1000,"rate":500,"type":"admin"}}` | Admin Client configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/subworkflow/launchplan#AdminConfig) |
| union.configmap.catalog | object | `{"catalog-cache":{"cache-endpoint":"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}","endpoint":"{{- printf \"dns:///%s\" (.Values.cloudUrl | trimPrefix \"dns:///\" | trimPrefix \"http://\" | trimPrefix \"https://\") -}}","insecure":false,"type":"fallback","use-admin-auth":true}}` | Catalog Client configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/catalog#Config) Additional advanced Catalog configuration [here](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/pluginmachinery/catalog#Config) |
| union.configmap.core | object | `{"cache":{"max_size_mbs":1024,"target_gc_percent":70},"manager":{"shard":{"shard-count":3,"type":"Hash"}},"propeller":{"event-config":{"raw-output-policy":"inline"},"gc-interval":"12h","kube-client-config":{"burst":25,"qps":100,"timeout":"30s"},"leader-election":{"enabled":false},"max-workflow-retries":50,"queue":{"batch-size":-1,"batching-interval":"1s","queue":{"base-delay":"0s","capacity":10000,"max-delay":"60s","rate":1000,"type":"maxof"},"sub-queue":{"capacity":10000,"rate":1000,"type":"bucket"},"type":"batch"},"rawoutput-prefix":"{{ tpl .Values.metadataBucketPrefix $ }}","workers":100},"webhook":{"certDir":"/etc/webhook/certs","serviceName":"flyte-pod-webhook"}}` | Core propeller configuration |
| union.configmap.core.propeller | object | `{"event-config":{"raw-output-policy":"inline"},"gc-interval":"12h","kube-client-config":{"burst":25,"qps":100,"timeout":"30s"},"leader-election":{"enabled":false},"max-workflow-retries":50,"queue":{"batch-size":-1,"batching-interval":"1s","queue":{"base-delay":"0s","capacity":10000,"max-delay":"60s","rate":1000,"type":"maxof"},"sub-queue":{"capacity":10000,"rate":1000,"type":"bucket"},"type":"batch"},"rawoutput-prefix":"{{ tpl .Values.metadataBucketPrefix $ }}","workers":100}` | Propeller config specified [here](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/config). These values are chosen to match a mix of [propeller config defaults](https://github.com/flyteorg/flytepropeller/blob/cbfcdf3396346bf83bd8e885d21803a5e53108ee/pkg/controller/config/config.go#L51-L114) (many of which are overridden in the Chart's [values.yaml](https://github.com/flyteorg/flyte/blob/e6fa8120dc0be4c46e789270c89fcfef3f6289f9/charts/flyte-core/values.yaml#L671-L703)), along with cloud-specific settings from [here](https://github.com/flyteorg/flyte/blob/e6fa8120dc0be4c46e789270c89fcfef3f6289f9/charts/flyte-core/values-eks.yaml#L233-L246). |
| union.configmap.enabled_plugins.tasks | object | `{"task-plugins":{"default-for-task-types":{"container":"container","container_array":"k8s-array","sidecar":"sidecar"},"enabled-plugins":["container","echo","sidecar","k8s-array"]}}` | Tasks specific configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/config#GetConfig) |
| union.configmap.enabled_plugins.tasks.task-plugins | object | `{"default-for-task-types":{"container":"container","container_array":"k8s-array","sidecar":"sidecar"},"enabled-plugins":["container","echo","sidecar","k8s-array"]}` | Plugins configuration, [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/config#TaskPluginConfig) |
| union.configmap.enabled_plugins.tasks.task-plugins.enabled-plugins | list | `["container","echo","sidecar","k8s-array"]` | [Enabled Plugins](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/config#Config). Enable sagemaker*, athena if you install the backend plugins |
| union.configmap.k8s | object | `{"plugins":{"k8s":{"default-cpus":"100m","default-memory":"100Mi"}}}` | Kubernetes specific Flyte configuration |
| union.configmap.k8s.plugins.k8s | object | `{"default-cpus":"100m","default-memory":"100Mi"}` | Configuration section for all K8s specific plugins [Configuration structure](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/pluginmachinery/flytek8s/config) |
| union.configmap.logger | object | `{"logger":{"level":4,"show-source":true}}` | Logger configuration |
| union.configmap.resource_manager | object | `{"propeller":{"resourcemanager":{"type":"noop"}}}` | Resource manager configuration |
| union.configmap.resource_manager.propeller | object | `{"resourcemanager":{"type":"noop"}}` | resource manager configuration |
| union.configmap.task_logs | object | `{"plugins":{"logs":{"cloudwatch-enabled":false,"kubernetes-enabled":true}}}` | Section that configures how the Task logs are displayed on the UI. This has to be changed based on your actual logging provider. Refer to [structure](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/logs#LogConfig) to understand how to configure various logging engines |
| union.configmap.task_logs.plugins.logs.cloudwatch-enabled | bool | `false` | One option is to enable cloudwatch logging for EKS, update the region and log group accordingly |
| union.datacatalog.enabled | bool | `false` |  |
| union.enableAppService | bool | `false` | Enable the usage of app service using cloudflare tunnels. |
| union.enableTunnelService | bool | `false` | Enable the usage of tunnel service using cloudflare tunnels. This works only if the union services has this service enabled. |
| union.enabled | bool | `true` | Mark cluster as healthy and ready to accept incoming workflows |
| union.flyteadmin.enabled | bool | `false` |  |
| union.flyteadmin.image.repository | string | `"public.ecr.aws/unionai-flyte/flyteadmin"` |  |
| union.flyteadmin.image.tag | string | `"2024.12.2"` |  |
| union.flyteconsole.enabled | bool | `false` |  |
| union.flytepropeller.affinity | object | `{}` | affinity for Flytepropeller deployment |
| union.flytepropeller.cacheSizeMbs | int | `0` |  |
| union.flytepropeller.client_secret | string | `"foobar"` |  |
| union.flytepropeller.clusterName | string | `"{{ include \"getClusterName\" . }}"` |  |
| union.flytepropeller.configPath | string | `"/etc/flyte/config/*.yaml"` | Default regex string for searching configuration files |
| union.flytepropeller.enabled | bool | `true` |  |
| union.flytepropeller.image.repository | string | `"public.ecr.aws/p0i0a9q8/unionoperator"` |  |
| union.flytepropeller.image.tag | string | `"2024.12.2"` |  |
| union.flytepropeller.nodeSelector | object | `{}` | nodeSelector for Flytepropeller deployment |
| union.flytepropeller.podAnnotations | object | `{}` | Annotations for Flytepropeller pods |
| union.flytepropeller.podEnv[0].name | string | `"GOMEMLIMIT"` |  |
| union.flytepropeller.podEnv[0].valueFrom.resourceFieldRef.resource | string | `"limits.memory"` |  |
| union.flytepropeller.podEnv[1].name | string | `"GOMAXPROCS"` |  |
| union.flytepropeller.podEnv[1].valueFrom.resourceFieldRef.resource | string | `"limits.cpu"` |  |
| union.flytepropeller.priorityClassName | string | `"system-cluster-critical"` |  |
| union.flytepropeller.replicaCount | int | `1` | Replicas count for Flytepropeller deployment |
| union.flytepropeller.resources | object | `{"limits":{"cpu":"4","ephemeral-storage":"500Mi","memory":"8Gi"},"requests":{"cpu":"3000m","ephemeral-storage":"100Mi","memory":"4Gi"}}` | Default resources requests and limits for Flytepropeller deployment |
| union.flytepropeller.service.additionalPorts[0].name | string | `"fasttask"` |  |
| union.flytepropeller.service.additionalPorts[0].port | int | `15605` |  |
| union.flytepropeller.service.additionalPorts[0].protocol | string | `"TCP"` |  |
| union.flytepropeller.service.additionalPorts[0].targetPort | int | `15605` |  |
| union.flytepropeller.service.enabled | bool | `true` |  |
| union.flytepropeller.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for FlytePropeller |
| union.flytepropeller.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to FlytePropeller pods |
| union.flytepropeller.serviceAccount.create | bool | `true` | Should a service account be created for FlytePropeller |
| union.flytepropeller.serviceAccount.imagePullSecrets | list | `[]` | ImapgePullSecrets to automatically assign to the service account |
| union.flytepropeller.tolerations | list | `[]` | tolerations for Flytepropeller deployment |
| union.flytescheduler.enabled | bool | `false` |  |
| union.kubePrometheusStack.enabled | bool | `true` |  |
| union.kubeeventmonitor.affinity | object | `{}` |  |
| union.kubeeventmonitor.autoscaling.enabled | bool | `false` |  |
| union.kubeeventmonitor.autoscaling.maxReplicas | int | `100` |  |
| union.kubeeventmonitor.autoscaling.minReplicas | int | `1` |  |
| union.kubeeventmonitor.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| union.kubeeventmonitor.config.selectors | object | `{}` |  |
| union.kubeeventmonitor.enabled | bool | `false` |  |
| union.kubeeventmonitor.image.pullPolicy | string | `"IfNotPresent"` |  |
| union.kubeeventmonitor.image.repository | string | `"public.ecr.aws/p0i0a9q8/unionoperator"` |  |
| union.kubeeventmonitor.image.tag | string | `"invalid-version"` |  |
| union.kubeeventmonitor.imagePullSecrets | list | `[]` |  |
| union.kubeeventmonitor.livenessProbe | object | `{}` |  |
| union.kubeeventmonitor.logLevel | int | `4` |  |
| union.kubeeventmonitor.name | string | `"kubeeventmonitor"` |  |
| union.kubeeventmonitor.nodeSelector | object | `{}` |  |
| union.kubeeventmonitor.podAnnotations | object | `{}` |  |
| union.kubeeventmonitor.podLabels | object | `{}` |  |
| union.kubeeventmonitor.podSecurityContext | object | `{}` |  |
| union.kubeeventmonitor.prometheus.enabled | bool | `true` |  |
| union.kubeeventmonitor.prometheus.metricsNamespace | string | `"kubeeventmonitor"` |  |
| union.kubeeventmonitor.prometheus.path | string | `"/metrics"` |  |
| union.kubeeventmonitor.prometheus.port | int | `10254` |  |
| union.kubeeventmonitor.readinessProbe | object | `{}` |  |
| union.kubeeventmonitor.replicaCount | int | `1` |  |
| union.kubeeventmonitor.resources.limits | object | `{"cpu":"200m","memory":"256Mi"}` | Limits are the maximum set of resources needed for this pod |
| union.kubeeventmonitor.resources.requests | object | `{"cpu":"10m","memory":"128Mi"}` | Requests are the minimum set of resources needed for this pod |
| union.kubeeventmonitor.securityContext | object | `{}` |  |
| union.kubeeventmonitor.serviceAccount.annotations | object | `{}` |  |
| union.kubeeventmonitor.serviceAccount.automount | bool | `true` |  |
| union.kubeeventmonitor.serviceAccount.create | bool | `true` |  |
| union.kubeeventmonitor.serviceAccount.name | string | `""` |  |
| union.kubeeventmonitor.tolerations | list | `[]` |  |
| union.kubeeventmonitor.volumeMounts | list | `[]` |  |
| union.kubeeventmonitor.volumes | list | `[]` |  |
| union.metadataBucketPrefix | string | `"s3://my-s3-bucket"` |  |
| union.objectStore.autoscaling.enabled | bool | `false` |  |
| union.objectStore.autoscaling.maxReplicas | int | `5` |  |
| union.objectStore.autoscaling.minReplicas | int | `1` |  |
| union.objectStore.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| union.objectStore.bucket | string | `"opencompute-staging-sample-tenant"` |  |
| union.objectStore.enabled | bool | `false` |  |
| union.objectStore.livenessProbe.httpGet.path | string | `"/healthcheck"` |  |
| union.objectStore.livenessProbe.httpGet.port | string | `"debug"` |  |
| union.objectStore.livenessProbe.initialDelaySeconds | int | `3` |  |
| union.objectStore.livenessProbe.periodSeconds | int | `3` |  |
| union.objectStore.maxMessageSizeBytes | int | `104857600` |  |
| union.objectStore.readinessProbe.httpGet.path | string | `"/healthcheck"` |  |
| union.objectStore.readinessProbe.httpGet.port | string | `"debug"` |  |
| union.objectStore.readinessProbe.initialDelaySeconds | int | `3` |  |
| union.objectStore.readinessProbe.periodSeconds | int | `3` |  |
| union.objectStore.redis.host | string | `"clustercfg.objectstore-staging.p7pazr.memorydb.us-east-2.amazonaws.com:6379"` |  |
| union.objectStore.replicaCount | int | `1` |  |
| union.objectStore.resources.limits.cpu | string | `"1"` |  |
| union.objectStore.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| union.objectStore.resources.limits.memory | string | `"1Gi"` |  |
| union.objectStore.resources.requests.cpu | string | `"100m"` |  |
| union.objectStore.resources.requests.ephemeral-storage | string | `"100Mi"` |  |
| union.objectStore.resources.requests.memory | string | `"128Mi"` |  |
| union.objectStore.secrets.create | bool | `false` |  |
| union.objectStore.secrets.mount | bool | `false` |  |
| union.objectStore.secrets.redisAuthToken | string | `""` |  |
| union.objectStore.service.grpcPort | int | `8089` |  |
| union.objectStore.service.httpPort | int | `8080` |  |
| union.objectStore.serviceAccount.annotations | object | `{}` |  |
| union.objectStore.serviceAccount.create | bool | `true` |  |
| union.objectStore.serviceAccount.name | string | `""` |  |
| union.proxy.autoscaling.enabled | bool | `false` |  |
| union.proxy.autoscaling.maxReplicas | int | `100` |  |
| union.proxy.autoscaling.minReplicas | int | `2` |  |
| union.proxy.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| union.proxy.podEnv[0].name | string | `"GOMEMLIMIT"` |  |
| union.proxy.podEnv[0].valueFrom.resourceFieldRef.resource | string | `"limits.memory"` |  |
| union.proxy.podEnv[1].name | string | `"GOMAXPROCS"` |  |
| union.proxy.podEnv[1].valueFrom.resourceFieldRef.resource | string | `"limits.cpu"` |  |
| union.proxy.prof-port | int | `10254` |  |
| union.proxy.replicaCount | int | `2` |  |
| union.proxy.resources.limits.cpu | string | `"1"` |  |
| union.proxy.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| union.proxy.resources.limits.memory | string | `"1Gi"` |  |
| union.proxy.resources.requests.cpu | string | `"100m"` |  |
| union.proxy.resources.requests.ephemeral-storage | string | `"100Mi"` |  |
| union.proxy.resources.requests.memory | string | `"128Mi"` |  |
| union.proxy.service.port | int | `8080` |  |
| union.proxy.serviceAccount.annotations | object | `{}` |  |
| union.proxy.serviceAccount.create | bool | `true` |  |
| union.proxy.serviceAccount.name | string | `""` |  |
| union.resourcequotas.create | bool | `false` |  |
| union.secrets.adminOauthClientCredentials.clientSecret | string | `""` |  |
| union.secrets.adminOauthClientCredentials.secretName | string | `"union-base"` |  |
| union.secrets.create | bool | `false` |  |
| union.sparkoperator | object | `{"enabled":false,"plugin_config":{"plugins":{"spark":{"spark-config-default":[{"spark.driver.cores":"1"},{"spark.executorEnv.HTTP2_DISABLE":"true"},{"spark.hadoop.fs.AbstractFileSystem.s3.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.AbstractFileSystem.s3a.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.AbstractFileSystem.s3n.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.s3.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.hadoop.fs.s3a.acl.default":"BucketOwnerFullControl"},{"spark.hadoop.fs.s3a.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.hadoop.fs.s3n.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.kubernetes.allocation.batch.size":"50"},{"spark.kubernetes.driverEnv.HTTP2_DISABLE":"true"},{"spark.network.timeout":"600s"},{"spark.executorEnv.KUBERNETES_REQUEST_TIMEOUT":100000},{"spark.executorEnv.AWS_METADATA_SERVICE_NUM_ATTEMPTS":20},{"spark.executorEnv.AWS_METADATA_SERVICE_TIMEOUT":5},{"spark.executor.heartbeatInterval":"60s"},{"spark.ui.proxyRedirectUri":"{{.Values.cloudUrl}}"},{"spark.hadoop.fs.s3a.aws.credentials.provider":"com.amazonaws.auth.WebIdentityTokenCredentialsProvider"}]}}}}` | Optional: Spark Plugin using the Spark Operator |
| union.sparkoperator.enabled | bool | `false` | - enable or disable Sparkoperator deployment installation |
| union.sparkoperator.plugin_config | object | `{"plugins":{"spark":{"spark-config-default":[{"spark.driver.cores":"1"},{"spark.executorEnv.HTTP2_DISABLE":"true"},{"spark.hadoop.fs.AbstractFileSystem.s3.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.AbstractFileSystem.s3a.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.AbstractFileSystem.s3n.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.s3.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.hadoop.fs.s3a.acl.default":"BucketOwnerFullControl"},{"spark.hadoop.fs.s3a.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.hadoop.fs.s3n.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.kubernetes.allocation.batch.size":"50"},{"spark.kubernetes.driverEnv.HTTP2_DISABLE":"true"},{"spark.network.timeout":"600s"},{"spark.executorEnv.KUBERNETES_REQUEST_TIMEOUT":100000},{"spark.executorEnv.AWS_METADATA_SERVICE_NUM_ATTEMPTS":20},{"spark.executorEnv.AWS_METADATA_SERVICE_TIMEOUT":5},{"spark.executor.heartbeatInterval":"60s"},{"spark.ui.proxyRedirectUri":"{{.Values.cloudUrl}}"},{"spark.hadoop.fs.s3a.aws.credentials.provider":"com.amazonaws.auth.WebIdentityTokenCredentialsProvider"}]}}}` | Spark plugin configuration |
| union.sparkoperator.plugin_config.plugins.spark.spark-config-default | list | `[{"spark.driver.cores":"1"},{"spark.executorEnv.HTTP2_DISABLE":"true"},{"spark.hadoop.fs.AbstractFileSystem.s3.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.AbstractFileSystem.s3a.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.AbstractFileSystem.s3n.impl":"org.apache.hadoop.fs.s3a.S3A"},{"spark.hadoop.fs.s3.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.hadoop.fs.s3a.acl.default":"BucketOwnerFullControl"},{"spark.hadoop.fs.s3a.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.hadoop.fs.s3n.impl":"org.apache.hadoop.fs.s3a.S3AFileSystem"},{"spark.kubernetes.allocation.batch.size":"50"},{"spark.kubernetes.driverEnv.HTTP2_DISABLE":"true"},{"spark.network.timeout":"600s"},{"spark.executorEnv.KUBERNETES_REQUEST_TIMEOUT":100000},{"spark.executorEnv.AWS_METADATA_SERVICE_NUM_ATTEMPTS":20},{"spark.executorEnv.AWS_METADATA_SERVICE_TIMEOUT":5},{"spark.executor.heartbeatInterval":"60s"},{"spark.ui.proxyRedirectUri":"{{.Values.cloudUrl}}"},{"spark.hadoop.fs.s3a.aws.credentials.provider":"com.amazonaws.auth.WebIdentityTokenCredentialsProvider"}]` | Spark default configuration |
| union.storage.bucketName | string | `"my-s3-bucket-prod"` |  |
| union.storage.custom | object | `{}` | Settings for storage type custom. See https://github:com/graymeta/stow for supported storage providers/settings. |
| union.storage.gcs | string | `nil` | settings for storage type gcs |
| union.storage.s3 | object | `{"region":"us-east-1"}` | settings for storage type s3 |
| union.storage.type | string | `"sandbox"` | Sets the storage type. Supported values are sandbox, s3, gcs and custom. |
| union.syncClusterConfig.enabled | bool | `true` |  |
| union.unionoperator | object | `{"additionalLabels":{},"affinity":{},"autoscaling":{"enabled":false,"maxReplicas":100,"minReplicas":1,"targetCPUUtilizationPercentage":80},"configmapOverrides":{},"fullnameOverride":"","image":{"pullPolicy":"IfNotPresent","repository":"public.ecr.aws/p0i0a9q8/unionoperator","tag":"2024.12.2"},"imagePullSecrets":[],"nameOverride":"","nodeSelector":{},"podAnnotations":{"prometheus.io/path":"/metrics","prometheus.io/port":"10254","prometheus.io/scrape":"true"},"podEnv":[{"name":"GOMEMLIMIT","valueFrom":{"resourceFieldRef":{"resource":"limits.memory"}}},{"name":"GOMAXPROCS","valueFrom":{"resourceFieldRef":{"resource":"limits.cpu"}}}],"podSecurityContext":{},"replicaCount":1,"resources":{"limits":{"cpu":"4","ephemeral-storage":"500Mi","memory":"8Gi"},"requests":{"cpu":"1","ephemeral-storage":"100Mi","memory":"4Gi"}},"secretName":"union-base","securityContext":{},"service":{"port":80,"type":"ClusterIP"},"serviceAccount":{"annotations":{},"automount":true,"create":true,"name":""},"tolerations":[]}` | ---------------------------------------------------- |
| union.unionoperatorMonitoring.dcgmExporter.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key | string | `"ami_type"` |  |
| union.unionoperatorMonitoring.dcgmExporter.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator | string | `"In"` |  |
| union.unionoperatorMonitoring.dcgmExporter.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0] | string | `"AL2_x86_64_GPU"` |  |
| union.unionoperatorMonitoring.dcgmExporter.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[1].matchExpressions[0].key | string | `"cloud.google.com/gke-accelerator"` |  |
| union.unionoperatorMonitoring.dcgmExporter.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[1].matchExpressions[0].operator | string | `"Exists"` |  |
| union.unionoperatorMonitoring.dcgmExporter.arguments[0] | string | `"-f"` |  |
| union.unionoperatorMonitoring.dcgmExporter.arguments[1] | string | `"/etc/dcgm-exporter/dcp-metrics-included.csv"` |  |
| union.unionoperatorMonitoring.dcgmExporter.enabled | bool | `true` |  |
| union.unionoperatorMonitoring.dcgmExporter.extraHostVolumes[0].hostPath | string | `"/home/kubernetes/bin/nvidia"` |  |
| union.unionoperatorMonitoring.dcgmExporter.extraHostVolumes[0].name | string | `"nvidia-install-dir-host"` |  |
| union.unionoperatorMonitoring.dcgmExporter.extraVolumeMounts[0].mountPath | string | `"/usr/local/nvidia"` |  |
| union.unionoperatorMonitoring.dcgmExporter.extraVolumeMounts[0].name | string | `"nvidia-install-dir-host"` |  |
| union.unionoperatorMonitoring.dcgmExporter.extraVolumeMounts[0].readOnly | bool | `true` |  |
| union.unionoperatorMonitoring.dcgmExporter.image.pullPolicy | string | `"IfNotPresent"` |  |
| union.unionoperatorMonitoring.dcgmExporter.image.repository | string | `"nvcr.io/nvidia/k8s/dcgm-exporter"` |  |
| union.unionoperatorMonitoring.dcgmExporter.image.tag | string | `"3.1.7-3.1.4-ubuntu20.04"` |  |
| union.unionoperatorMonitoring.dcgmExporter.kubeletPath | string | `"/var/lib/kubelet/pod-resources"` |  |
| union.unionoperatorMonitoring.dcgmExporter.podSecurityContext | object | `{}` |  |
| union.unionoperatorMonitoring.dcgmExporter.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| union.unionoperatorMonitoring.dcgmExporter.resources.limits.memory | string | `"400Mi"` |  |
| union.unionoperatorMonitoring.dcgmExporter.resources.requests.cpu | string | `"100m"` |  |
| union.unionoperatorMonitoring.dcgmExporter.resources.requests.ephemeral-storage | string | `"500Mi"` |  |
| union.unionoperatorMonitoring.dcgmExporter.resources.requests.memory | string | `"128Mi"` |  |
| union.unionoperatorMonitoring.dcgmExporter.securityContext.capabilities.add[0] | string | `"SYS_ADMIN"` |  |
| union.unionoperatorMonitoring.dcgmExporter.securityContext.privileged | bool | `true` |  |
| union.unionoperatorMonitoring.dcgmExporter.securityContext.runAsNonRoot | bool | `false` |  |
| union.unionoperatorMonitoring.dcgmExporter.securityContext.runAsUser | int | `0` |  |
| union.unionoperatorMonitoring.dcgmExporter.service.address | string | `":9400"` |  |
| union.unionoperatorMonitoring.dcgmExporter.service.port | int | `9400` |  |
| union.unionoperatorMonitoring.dcgmExporter.service.type | string | `"ClusterIP"` |  |
| union.unionoperatorMonitoring.dcgmExporter.serviceAccount.annotations | object | `{}` |  |
| union.unionoperatorMonitoring.dcgmExporter.serviceAccount.create | bool | `true` |  |
| union.unionoperatorMonitoring.dcgmExporter.serviceAccount.name | string | `""` |  |
| union.unionoperatorMonitoring.dcgmExporter.tolerations[0].effect | string | `"NoSchedule"` |  |
| union.unionoperatorMonitoring.dcgmExporter.tolerations[0].key | string | `"flyte.org/node-role"` |  |
| union.unionoperatorMonitoring.dcgmExporter.tolerations[0].operator | string | `"Exists"` |  |
| union.unionoperatorMonitoring.dcgmExporter.tolerations[1].effect | string | `"NoSchedule"` |  |
| union.unionoperatorMonitoring.dcgmExporter.tolerations[1].key | string | `"nvidia.com/gpu"` |  |
| union.unionoperatorMonitoring.dcgmExporter.tolerations[1].operator | string | `"Exists"` |  |
| union.unionoperatorMonitoring.enabled | bool | `false` |  |
| union.unionoperatorMonitoring.extraScrapeConfigs | list | `[]` |  |
| union.unionoperatorMonitoring.fluentbit.kubernetesLabel | string | `"app.kubernetes.io/name=aws-for-fluent-bit"` |  |
| union.unionoperatorMonitoring.fluentbit.namespace | string | `"kube-system"` |  |
| union.unionoperatorMonitoring.flytePropeller.enabled | bool | `false` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.autoscaling.enabled | bool | `false` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.image.pullPolicy | string | `"IfNotPresent"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.image.repository | string | `"registry.k8s.io/kube-state-metrics/kube-state-metrics"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.image.tag | string | `"v2.11.0"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.podSecurityContext | object | `{}` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.replicaCount | int | `1` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.resources.limits.cpu | string | `"4"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.resources.limits.memory | string | `"8Gi"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.resources.requests.cpu | string | `"1"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.resources.requests.ephemeral-storage | string | `"100Mi"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.resources.requests.memory | string | `"500Mi"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.service.port | int | `8080` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.service.type | string | `"ClusterIP"` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.serviceAccount.annotations | object | `{}` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.serviceAccount.create | bool | `true` |  |
| union.unionoperatorMonitoring.kubeStateMetrics.serviceAccount.name | string | `""` |  |
| union.unionoperatorMonitoring.opencost.alpha | bool | `false` |  |
| union.unionoperatorMonitoring.opencost.enabled | bool | `false` |  |
| union.unionoperatorMonitoring.opencost.scrape | bool | `false` |  |
| union.unionoperatorMonitoring.prometheus.autoscaling.enabled | bool | `false` |  |
| union.unionoperatorMonitoring.prometheus.cadvisor.additional_metric_relabel_configs | list | `[]` |  |
| union.unionoperatorMonitoring.prometheus.cadvisor.metricsNameRegex.default | string | `"container_cpu_usage_seconds_total|container_memory_working_set_bytes"` |  |
| union.unionoperatorMonitoring.prometheus.cadvisor.metricsNameRegex.extended | string | `"(container_spec_cpu_quota|container_spec_cpu_period|container_cpu_cfs_throttled_periods_total|container_cpu_cfs_periods_total|container_spec_memory_limit_bytes|container_fs_inodes_free|container_fs_inodes_total)"` |  |
| union.unionoperatorMonitoring.prometheus.externalUrl | string | `"/prometheus/"` |  |
| union.unionoperatorMonitoring.prometheus.image.pullPolicy | string | `"IfNotPresent"` |  |
| union.unionoperatorMonitoring.prometheus.image.repository | string | `"prom/prometheus"` |  |
| union.unionoperatorMonitoring.prometheus.image.tag | string | `"v2.43.0"` |  |
| union.unionoperatorMonitoring.prometheus.podSecurityContext.fsGroup | int | `65534` |  |
| union.unionoperatorMonitoring.prometheus.podSecurityContext.runAsNonRoot | bool | `true` |  |
| union.unionoperatorMonitoring.prometheus.podSecurityContext.runAsUser | int | `65534` |  |
| union.unionoperatorMonitoring.prometheus.replicaCount | int | `1` |  |
| union.unionoperatorMonitoring.prometheus.resources.limits.cpu | string | `"4"` |  |
| union.unionoperatorMonitoring.prometheus.resources.limits.ephemeral-storage | string | `"1Gi"` |  |
| union.unionoperatorMonitoring.prometheus.resources.limits.memory | string | `"8Gi"` |  |
| union.unionoperatorMonitoring.prometheus.resources.requests.cpu | string | `"1"` |  |
| union.unionoperatorMonitoring.prometheus.resources.requests.ephemeral-storage | string | `"500Mi"` |  |
| union.unionoperatorMonitoring.prometheus.resources.requests.memory | string | `"500Mi"` |  |
| union.unionoperatorMonitoring.prometheus.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| union.unionoperatorMonitoring.prometheus.service.port | int | `80` |  |
| union.unionoperatorMonitoring.prometheus.service.type | string | `"ClusterIP"` |  |
| union.unionoperatorMonitoring.prometheus.serviceAccount.annotations | object | `{}` |  |
| union.unionoperatorMonitoring.prometheus.serviceAccount.create | bool | `true` |  |
| union.unionoperatorMonitoring.prometheus.serviceAccount.name | string | `""` |  |
| union.unionoperatorMonitoring.prometheus.storage.className | string | `"gp2"` |  |
| union.unionoperatorMonitoring.prometheus.storage.persistent | bool | `false` |  |
| union.unionoperatorMonitoring.prometheus.storage.retention.size | string | `"400MB"` |  |
| union.unionoperatorMonitoring.prometheus.storage.sizePerReplica | string | `"1Gi"` |  |
| union.unionoperatorMonitoring.prometheus.topologyKey | string | `"topology.kubernetes.io/zone"` |  |
| union.unionoperatorMonitoring.scrapeConfigs.kubeStateMetrics.extraMetricRelabelConfigs | list | `[]` |  |
| union.unionoperatorSparkHistoryServer.affinity | object | `{}` |  |
| union.unionoperatorSparkHistoryServer.autoscaling.enabled | bool | `false` |  |
| union.unionoperatorSparkHistoryServer.autoscaling.maxReplicas | int | `10` |  |
| union.unionoperatorSparkHistoryServer.autoscaling.minReplicas | int | `1` |  |
| union.unionoperatorSparkHistoryServer.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| union.unionoperatorSparkHistoryServer.autoscaling.targetMemoryUtilizationPercentage | int | `80` |  |
| union.unionoperatorSparkHistoryServer.configmapOverrides | object | `{}` |  |
| union.unionoperatorSparkHistoryServer.enabled | bool | `false` |  |
| union.unionoperatorSparkHistoryServer.image.pullPolicy | string | `"IfNotPresent"` |  |
| union.unionoperatorSparkHistoryServer.image.repository | string | `"ghcr.io/flyteorg/flytecookbook"` |  |
| union.unionoperatorSparkHistoryServer.image.tag | string | `"k8s_spark-a3b97943563cfc952b5683525763578685a93694"` |  |
| union.unionoperatorSparkHistoryServer.nodeSelector | object | `{}` |  |
| union.unionoperatorSparkHistoryServer.podSecurityContext | object | `{}` |  |
| union.unionoperatorSparkHistoryServer.proxyHost | string | `""` |  |
| union.unionoperatorSparkHistoryServer.replicaCount | int | `1` |  |
| union.unionoperatorSparkHistoryServer.resources.limits.cpu | string | `"1"` |  |
| union.unionoperatorSparkHistoryServer.resources.limits.ephemeral-storage | string | `"500Mi"` |  |
| union.unionoperatorSparkHistoryServer.resources.limits.memory | string | `"2Gi"` |  |
| union.unionoperatorSparkHistoryServer.resources.requests.cpu | string | `"100m"` |  |
| union.unionoperatorSparkHistoryServer.resources.requests.ephemeral-storage | string | `"100Mi"` |  |
| union.unionoperatorSparkHistoryServer.resources.requests.memory | string | `"500Mi"` |  |
| union.unionoperatorSparkHistoryServer.securityContext.allowPrivilegeEscalation | bool | `true` |  |
| union.unionoperatorSparkHistoryServer.securityContext.runAsUser | int | `0` |  |
| union.unionoperatorSparkHistoryServer.service.port | int | `80` |  |
| union.unionoperatorSparkHistoryServer.service.type | string | `"ClusterIP"` |  |
| union.unionoperatorSparkHistoryServer.serviceAccount.annotations | object | `{}` |  |
| union.unionoperatorSparkHistoryServer.serviceAccount.create | bool | `true` |  |
| union.unionoperatorSparkHistoryServer.serviceAccount.name | string | `""` |  |
| union.unionoperatorSparkHistoryServer.tolerations | list | `[]` |  |
| union.userRoleAnnotationKey | string | `"foo"` |  |
| union.userRoleAnnotationValue | string | `"bar"` |  |
| union.webhook.enabled | bool | `true` | enable or disable secrets webhook |
| union.webhook.podAnnotations | object | `{}` | Annotations for webhook pods |
| union.webhook.podEnv[0].name | string | `"GOMEMLIMIT"` |  |
| union.webhook.podEnv[0].valueFrom.resourceFieldRef.resource | string | `"limits.memory"` |  |
| union.webhook.podEnv[1].name | string | `"GOMAXPROCS"` |  |
| union.webhook.podEnv[1].valueFrom.resourceFieldRef.resource | string | `"limits.cpu"` |  |
| union.webhook.service | object | `{"annotations":{"projectcontour.io/upstream-protocol.h2c":"grpc"},"type":"ClusterIP"}` | Service settings for the webhook |
| union.webhook.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for the webhook |
| union.webhook.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to the webhook |
| union.webhook.serviceAccount.create | bool | `true` | Should a service account be created for the webhook |
| union.webhook.serviceAccount.imagePullSecrets | list | `[]` | ImapgePullSecrets to automatically assign to the service account |
