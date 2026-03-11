---
title: Dataplane chart
variants: -flyte -byoc +selfmanaged -serverless
weight: 1
---

Deploys the Union dataplane components to onboard a kubernetes cluster to the Union Cloud.

## Chart info

| | |
|---|---|
| **Chart version** | 2026.3.4 |
| **App version** | 2026.3.2 |
| **Kubernetes version** | `>= 1.28.0-0` |

## Requirements

Kubernetes: `>= 1.28.0-0`

| Repository | Name | Version |
|------------|------|---------|
| https://fluent.github.io/helm-charts | fluentbit(fluent-bit) | 0.48.9 |
| https://kubernetes-sigs.github.io/metrics-server/ | metrics-server(metrics-server) | 3.12.2 |
| https://kubernetes.github.io/ingress-nginx | ingress-nginx | 4.12.3 |
| https://nvidia.github.io/dcgm-exporter/helm-charts | dcgm-exporter | 4.7.1 |
| https://opencost.github.io/opencost-helm-chart | opencost | 1.42.0 |
| https://prometheus-community.github.io/helm-charts | prometheus(kube-prometheus-stack) | 72.9.1 |
| https://unionai.github.io/helm-charts | knative-operator(knative-operator) | 2025.5.0 |
## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| additionalPodAnnotations | object | `{}` | Define additional pod annotations for all of the Union pods. |
| additionalPodEnvVars | object | `{}` | Define additional pod environment variables for all of the Union pods. |
| additionalPodLabels | object | `{}` | Define additional pod labels for all of the Union pods. |
| additionalPodSpec | object | `{}` | Define additional PodSpec values for all of the Union pods. |
| clusterName | string | `"{{ .Values.global.CLUSTER_NAME }}"` | Cluster name should be shared with Union for proper functionality. |
| clusterresourcesync | object | see [values.yaml](values.yaml) | clusterresourcesync contains the configuration information for the syncresources service. |
| clusterresourcesync.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| clusterresourcesync.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| clusterresourcesync.affinity | object | `{}` | affinity configurations for the syncresources pods |
| clusterresourcesync.config | object | see [values.yaml](values.yaml) | Syncresources service configuration |
| clusterresourcesync.config.clusterResourcesPrivate | object | `{"app":{"isServerless":false}}` | Additional configuration for the cluster resources service |
| clusterresourcesync.config.clusterResourcesPrivate.app | object | `{"isServerless":false}` | Configuration of app serving services. |
| clusterresourcesync.config.cluster_resources.clusterName | string | `"{{ include \"getClusterName\" . }}"` | The name of the cluster.  This should always be the same as the cluster name in the config. |
| clusterresourcesync.config.cluster_resources.refreshInterval | string | `"5m"` | How frequently to sync the cluster resources |
| clusterresourcesync.config.cluster_resources.standaloneDeployment | bool | `true` | Start the cluster resource manager in standalone mode. |
| clusterresourcesync.config.cluster_resources.templatePath | string | `"/etc/flyte/clusterresource/templates"` | The path to the project the templates used to configure project resource quotas. |
| clusterresourcesync.config.union | object | see [values.yaml](values.yaml) | Connection information for the sync resources service to connect to the Union control plane. |
| clusterresourcesync.config.union.connection.host | string | `"dns:///{{ tpl .Values.host . }}"` | Host to connect to |
| clusterresourcesync.enabled | bool | `true` | Enable or disable the syncresources service |
| clusterresourcesync.nodeName | string | `""` | nodeName constraints for the syncresources pods |
| clusterresourcesync.nodeSelector | object | `{}` | nodeSelector constraints for the syncresources pods |
| clusterresourcesync.podAnnotations | object | `{}` | Additional pod annotations for the syncresources service |
| clusterresourcesync.podEnv | object | `{}` | Additional pod environment variables for the syncresources service |
| clusterresourcesync.resources | object | `{"limits":{"cpu":"1","memory":"500Mi"},"requests":{"cpu":"500m","memory":"100Mi"}}` | Kubernetes resource configuration for the syncresources service |
| clusterresourcesync.serviceAccount | object | `{"annotations":{},"name":""}` | Override service account values for the syncresources service |
| clusterresourcesync.serviceAccount.annotations | object | `{}` | Additional annotations for the syncresources service account |
| clusterresourcesync.serviceAccount.name | string | `""` | Override the service account name for the syncresources service |
| clusterresourcesync.templates | list | see [values.yaml](values.yaml) | The templates that are used to create and/or update kubernetes resources for Union projects. |
| clusterresourcesync.templates[0] | object | `{"key":"a_namespace","value":"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {{ namespace }}\n  labels:\n    union.ai/namespace-type: flyte\nspec:\n  finalizers:\n  - kubernetes\n"}` | Template for namespaces resources |
| clusterresourcesync.templates[1] | object | `{"key":"b_default_service_account","value":"apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: default\n  namespace: {{ namespace }}\n  annotations:\n    {{ defaultUserRoleKey }}: {{ defaultUserRoleValue }}\n"}` | Patch default service account |
| clusterresourcesync.tolerations | list | `[]` | tolerations for the syncresources pods |
| clusterresourcesync.topologySpreadConstraints | object | `{}` | topologySpreadConstraints for the syncresources pods |
| commonServiceAccount | object | `{"annotations":{},"enabled":true,"name":"union-system"}` | When enabled, creates a single shared ServiceAccount for all components (operator, executor, proxy, webhook, fluentbit) instead of individual ones. Automatically enabled when singleNamespace mode is active. |
| config | object | see [values.yaml](values.yaml) | Global configuration settings for all Union services. |
| config.admin | object | see [values.yaml](values.yaml) | Admin Client configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/subworkflow/launchplan#AdminConfig) |
| config.catalog | object | `{"catalog-cache":{"cache-endpoint":"dns:///{{ tpl .Values.host . }}","endpoint":"dns:///{{ tpl .Values.host . }}","insecure":false,"type":"cacheservicev2","use-admin-auth":true}}` | Catalog Client configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/catalog#Config) Additional advanced Catalog configuration [here](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/pluginmachinery/catalog#Config) |
| config.configOverrides | object | `{"cache":{"identity":{"enabled":false}}}` | Override any configuration settings. |
| config.copilot | object | `{"plugins":{"k8s":{"co-pilot":{"image":"{{ .Values.image.flytecopilot.repository }}:{{ .Values.image.flytecopilot.tag }}","name":"flyte-copilot-","start-timeout":"30s"}}}}` | Copilot configuration |
| config.copilot.plugins.k8s.co-pilot | object | `{"image":"{{ .Values.image.flytecopilot.repository }}:{{ .Values.image.flytecopilot.tag }}","name":"flyte-copilot-","start-timeout":"30s"}` | Structure documented [here](https://pkg.go.dev/github.com/lyft/flyteplugins@v0.5.28/go/tasks/pluginmachinery/flytek8s/config#FlyteCoPilotConfig) |
| config.core | object | see [values.yaml](values.yaml) | Core propeller configuration |
| config.core.propeller | object | see [values.yaml](values.yaml) | follows the structure specified [here](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/config). |
| config.domain | object | `{"domains":[{"id":"development","name":"development"},{"id":"staging","name":"staging"},{"id":"production","name":"production"}]}` | Domains configuration for Union projects. This enables the specified number of domains across all projects in Union. |
| config.enabled_plugins.tasks | object | see [values.yaml](values.yaml) | Tasks specific configuration [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/config#GetConfig) |
| config.enabled_plugins.tasks.task-plugins | object | see [values.yaml](values.yaml) | Plugins configuration, [structure](https://pkg.go.dev/github.com/flyteorg/flytepropeller/pkg/controller/nodes/task/config#TaskPluginConfig) |
| config.enabled_plugins.tasks.task-plugins.enabled-plugins | list | `["container","sidecar","k8s-array","echo","fast-task","connector-service"]` | [Enabled Plugins](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/config#Config). Enable sagemaker*, athena if you install the backend plugins |
| config.k8s | object | `{"plugins":{"k8s":{"default-cpus":"100m","default-env-vars":[],"default-memory":"100Mi","default-pod-template-name":"task-template"}}}` | Kubernetes specific Flyte configuration |
| config.k8s.plugins.k8s | object | `{"default-cpus":"100m","default-env-vars":[],"default-memory":"100Mi","default-pod-template-name":"task-template"}` | Configuration section for all K8s specific plugins [Configuration structure](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/pluginmachinery/flytek8s/config) |
| config.logger | object | `{"level":4,"show-source":true}` | Logging configuration |
| config.operator | object | see [values.yaml](values.yaml) | Configuration for the Union operator service |
| config.operator.apps | object | `{"enabled":"{{ .Values.serving.enabled }}"}` | Enable app serving |
| config.operator.billing | object | `{"model":"Legacy"}` | Billing model: None, Legacy, or ResourceUsage. |
| config.operator.clusterData | object | see [values.yaml](values.yaml) | Dataplane cluster configuration. |
| config.operator.clusterData.appId | string | `"{{ tpl .Values.secrets.admin.clientId . }}"` | The client id used to authenticate to the control plane.  This will be provided by Union. |
| config.operator.clusterData.bucketName | string | `"{{ tpl .Values.storage.bucketName . }}"` | The bucket name for object storage. |
| config.operator.clusterData.bucketRegion | string | `"{{ tpl .Values.storage.region . }}"` | The bucket region for object storage. |
| config.operator.clusterData.cloudHostName | string | `"{{ tpl .Values.host . }}"` | The hose name for control plane access. This will be provided by Union. |
| config.operator.clusterData.gcpProjectId | string | `"{{ tpl .Values.storage.gcp.projectId . }}"` | For GCP only, the project id for object storage. |
| config.operator.clusterData.metadataBucketPrefix | string | `"{{ include \"storage.metadata-prefix\" . }}"` | The prefix for constructing object storage URLs. |
| config.operator.clusterId | object | `{"organization":"{{ tpl .Values.orgName . }}"}` | Set the cluster information for the operator service |
| config.operator.clusterId.organization | string | `"{{ tpl .Values.orgName . }}"` | The organization name for the cluster.  This should match your organization name that you were provided. |
| config.operator.collectUsages | object | `{"enabled":true}` | Configuration for the usage reporting service. |
| config.operator.collectUsages.enabled | bool | `true` | Enable usage collection in the operator service. |
| config.operator.dependenciesHeartbeat | object | see [values.yaml](values.yaml) | Heartbeat check configuration. |
| config.operator.dependenciesHeartbeat.executor | object | `{"endpoint":"{{ include \"executor.health.url\" . }}"}` | Define the propeller health check endpoint. |
| config.operator.dependenciesHeartbeat.prometheus | object | `{"endpoint":"{{ include \"prometheus.health.url\" . }}"}` | Define the prometheus health check endpoint. |
| config.operator.dependenciesHeartbeat.propeller | object | `{"endpoint":"{{ include \"propeller.health.url\" . }}"}` | Define the propeller health check endpoint. |
| config.operator.dependenciesHeartbeat.proxy | object | `{"endpoint":"{{ include \"proxy.health.url\" . }}"}` | Define the operator proxy health check endpoint. |
| config.operator.enableTunnelService | bool | `true` | Enable the cloudflare tunnel service for secure communication with the control plane. |
| config.operator.enabled | bool | `true` | Enables the operator service |
| config.operator.syncClusterConfig | object | `{"enabled":false}` | Sync the configuration from the control plane. This will overwrite any configuration values set as part of the deploy. |
| config.proxy | object | see [values.yaml](values.yaml) | Configuration for the operator proxy service. |
| config.proxy.smConfig | object | `{"enabled":"{{ .Values.proxy.secretManager.enabled }}","k8sConfig":{"namespace":"{{ include \"proxy.secretsNamespace\" . }}"},"type":"{{ .Values.proxy.secretManager.type }}"}` | Secret manager configuration |
| config.proxy.smConfig.enabled | string | `"{{ .Values.proxy.secretManager.enabled }}"` | Enable or disable secret manager support for the Union dataplane. |
| config.proxy.smConfig.k8sConfig | object | `{"namespace":"{{ include \"proxy.secretsNamespace\" . }}"}` | Kubernetes specific secret manager configuration. |
| config.proxy.smConfig.type | string | `"{{ .Values.proxy.secretManager.type }}"` | The type of secret manager to use. |
| config.resource_manager | object | `{"propeller":{"resourcemanager":{"type":"noop"}}}` | Resource manager configuration |
| config.resource_manager.propeller | object | `{"resourcemanager":{"type":"noop"}}` | resource manager configuration |
| config.sharedService | object | `{"features":{"gatewayV2":true},"port":8081}` | Section that configures shared union services |
| config.task_logs | object | see [values.yaml](values.yaml) | Section that configures how the Task logs are displayed on the UI. This has to be changed based on your actual logging provider. Refer to [structure](https://pkg.go.dev/github.com/lyft/flyteplugins/go/tasks/logs#LogConfig) to understand how to configure various logging engines |
| config.task_logs.plugins.logs.cloudwatch-enabled | bool | `false` | One option is to enable cloudwatch logging for EKS, update the region and log group accordingly |
| config.task_resource_defaults | object | `{"task_resources":{"defaults":{"cpu":"100m","memory":"500Mi"},"limits":{"cpu":4096,"gpu":256,"memory":"2Ti"}}}` | Task default resources configuration Refer to the full [structure](https://pkg.go.dev/github.com/lyft/flyteadmin@v0.3.37/pkg/runtime/interfaces#TaskResourceConfiguration). |
| config.task_resource_defaults.task_resources | object | `{"defaults":{"cpu":"100m","memory":"500Mi"},"limits":{"cpu":4096,"gpu":256,"memory":"2Ti"}}` | Task default resources parameters |
| config.union.connection | object | `{"host":"dns:///{{ tpl .Values.host . }}"}` | Connection information to the union control plane. |
| config.union.connection.host | string | `"dns:///{{ tpl .Values.host . }}"` | Host to connect to |
| cost.enabled | bool | `true` | Enable or disable the cost service resources.  This does not include the opencost or other compatible monitoring services. |
| cost.serviceMonitor.matchLabels | object | `{"app.kubernetes.io/name":"opencost"}` | Match labels for the ServiceMonitor. |
| cost.serviceMonitor.name | string | `"cost"` | The name of the ServiceMonitor. |
| databricks | object | `{"enabled":false,"plugin_config":{}}` | Databricks integration configuration |
| dcgm-exporter | object | see [values.yaml](values.yaml) | Dcgm exporter configuration |
| dcgm-exporter.enabled | bool | `false` | Enable or disable the dcgm exporter |
| dcgm-exporter.serviceMonitor | object | `{"honorLabels":true}` | It's common practice to taint and label  to not run dcgm exporter on all nodes, so we can use node selectors and    tolerations to ensure it only runs on GPU nodes. affinity: {} nodeSelector: {} tolerations: [] |
| executor | object | see [values.yaml](values.yaml) | Executor service configuration for running fast tasks and eager workflows. |
| executor.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| executor.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| executor.config | object | see [values.yaml](values.yaml) | Core executor configuration. |
| executor.config.cluster | string | `"{{ tpl .Values.clusterName . }}"` | Cluster name for the executor. Should match .Values.clusterName. |
| executor.config.evaluatorCount | int | `64` | Number of evaluator goroutines for processing workflow nodes. |
| executor.config.maxActions | int | `2000` | Maximum number of concurrent actions the executor can handle. |
| executor.config.organization | string | `"{{ tpl .Values.orgName . }}"` | Organization name for the executor. Should match .Values.orgName. |
| executor.config.unionAuth | object | `{"injectSecret":true,"secretName":"EAGER_API_KEY"}` | Authentication configuration for eager workflows. |
| executor.config.unionAuth.injectSecret | bool | `true` | Inject an API key secret into eager workflow pods. |
| executor.config.unionAuth.secretName | string | `"EAGER_API_KEY"` | Name of the environment variable containing the API key secret. |
| executor.config.workerName | string | `"worker1"` | Name of this executor worker instance. |
| executor.enabled | bool | `true` | Enable or disable the executor service. |
| executor.idl2Executor | bool | `true` | Use IDL v2 executor protocol. |
| executor.plugins | object | see [values.yaml](values.yaml) | Plugin configuration for the executor. |
| executor.plugins.fasttask | object | see [values.yaml](values.yaml) | Fast task plugin configuration. Enables in-process task execution for reduced overhead. |
| executor.plugins.ioutils | object | `{"remoteFileOutputPaths":{"deckFilename":"report.html"}}` | IO utilities configuration. |
| executor.plugins.ioutils.remoteFileOutputPaths.deckFilename | string | `"report.html"` | Filename for Flyte Deck HTML reports. |
| executor.plugins.k8s | object | `{"disable-inject-owner-references":true}` | Kubernetes plugin configuration for the executor. |
| executor.plugins.k8s.disable-inject-owner-references | bool | `true` | Disable injecting owner references on task pods (executor manages lifecycle independently). |
| executor.podEnv | list | `[]` | Appends additional environment variables to the executor container's spec. |
| executor.podLabels | object | `{"app":"executor","app.kubernetes.io/instance":"{{ .Release.Name }}","app.kubernetes.io/name":"executor"}` | Labels to apply to executor pods. |
| executor.propeller | object | `{"node-config":{"disable-input-file-writes":true}}` | Propeller node configuration overrides for the executor. |
| executor.propeller.node-config.disable-input-file-writes | bool | `true` | Disable writing input files to disk (uses remote storage instead). |
| executor.raw_config | object | `{}` | Raw configuration to merge into the executor config. Allows arbitrary overrides. |
| executor.resources | object | `{"limits":{"cpu":4,"memory":"8Gi"},"requests":{"cpu":1,"memory":"1Gi"}}` | Resource requests and limits for the executor deployment. |
| executor.selector | object | `{"matchLabels":{"app":"executor"}}` | Label selector for the executor deployment. |
| executor.serviceAccount | object | `{"annotations":{}}` | Service account configuration for the executor. |
| executor.serviceAccount.annotations | object | `{}` | Annotations to add to the executor service account. |
| executor.sharedService | object | `{"metrics":{"scope":"executor:"},"security":{"allowCors":true,"allowLocalhostAccess":true,"allowedHeaders":["Content-Type"],"allowedOrigins":["*"],"secure":false,"useAuth":false}}` | Shared service configuration for the executor gRPC/HTTP server. |
| executor.sharedService.metrics | object | `{"scope":"executor:"}` | Metrics configuration for the executor. |
| executor.sharedService.metrics.scope | string | `"executor:"` | Prometheus metrics prefix scope. |
| executor.sharedService.security | object | `{"allowCors":true,"allowLocalhostAccess":true,"allowedHeaders":["Content-Type"],"allowedOrigins":["*"],"secure":false,"useAuth":false}` | Security configuration for the executor API. |
| executor.sharedService.security.allowCors | bool | `true` | Enable CORS support. |
| executor.sharedService.security.allowLocalhostAccess | bool | `true` | Allow localhost access without authentication. |
| executor.sharedService.security.secure | bool | `false` | Enable TLS for the executor API. |
| executor.sharedService.security.useAuth | bool | `false` | Require authentication for the executor API. |
| executor.task_logs | object | `{"plugins":{"logs":{"cloudwatch-enabled":false,"dynamic-log-links":[{"vscode":{"displayName":"VS Code Debugger","linkType":"ide","templateUris":["/dataplane/pod/v1/generated_name/6060/task/{{`{{.executionProject}}`}}/{{`{{.executionDomain}}`}}/{{`{{.executionName}}`}}/{{`{{.nodeID}}`}}/{{`{{.taskRetryAttempt}}`}}/{{.Values.clusterName}}/{{`{{.namespace}}`}}/{{`{{.taskProject}}`}}/{{`{{.taskDomain}}`}}/{{`{{.taskID}}`}}/{{`{{.taskVersion}}`}}/{{`{{.generatedName}}`}}/"]}},{"wandb-execution-id":{"displayName":"Weights & Biases","linkType":"dashboard","templateUris":["{{`{{ .taskConfig.host }}`}}/{{`{{ .taskConfig.entity }}`}}/{{`{{ .taskConfig.project }}`}}/runs/{{`{{ .podName }}`}}"]}},{"wandb-custom-id":{"displayName":"Weights & Biases","linkType":"dashboard","templateUris":["{{`{{ .taskConfig.host }}`}}/{{`{{ .taskConfig.entity }}`}}/{{`{{ .taskConfig.project }}`}}/runs/{{`{{ .taskConfig.id }}`}}"]}},{"comet-ml-execution-id":{"displayName":"Comet","linkType":"dashboard","templateUris":"{{`{{ .taskConfig.host }}`}}/{{`{{ .taskConfig.workspace }}`}}/{{`{{ .taskConfig.project_name }}`}}/{{`{{ .executionName }}`}}{{`{{ .nodeId }}`}}{{`{{ .taskRetryAttempt }}`}}{{`{{ .taskConfig.link_suffix }}`}}"}},{"comet-ml-custom-id":{"displayName":"Comet","linkType":"dashboard","templateUris":"{{`{{ .taskConfig.host }}`}}/{{`{{ .taskConfig.workspace }}`}}/{{`{{ .taskConfig.project_name }}`}}/{{`{{ .taskConfig.experiment_key }}`}}"}},{"neptune-scale-run":{"displayName":"Neptune Run","linkType":"dashboard","templateUris":["https://scale.neptune.ai/{{`{{ .taskConfig.project }}`}}/-/run/?customId={{`{{ .podName }}`}}"]}},{"neptune-scale-custom-id":{"displayName":"Neptune Run","linkType":"dashboard","templateUris":["https://scale.neptune.ai/{{`{{ .taskConfig.project }}`}}/-/run/?customId={{`{{ .taskConfig.id }}`}}"]}}],"kubernetes-enabled":false}}}` | Task log configuration for the executor. |
| executor.task_logs.plugins.logs.cloudwatch-enabled | bool | `false` | One option is to enable cloudwatch logging for EKS, update the region and log group accordingly |
| executor.task_logs.plugins.logs.kubernetes-enabled | bool | `false` | Enable Kubernetes-native log fetching. |
| extraObjects | list | `[]` | Extra Kubernetes objects to deploy with the helm chart. Each entry is a raw Kubernetes manifest. |
| fluentbit | object | `{"enabled":true,"env":[],"existingConfigMap":"fluentbit-system","serviceAccount":{"annotations":{},"create":false,"name":"fluentbit-system"},"tolerations":[{"operator":"Exists"}]}` | Configuration for fluentbit used for the persistent logging feature. FluentBit runs as a DaemonSet and ships container logs to the persisted-logs/ path in the configured object store. The fluentbit-system service account must have write access to the storage bucket. Grant access using cloud-native identity federation:   AWS (IRSA):     annotations:       eks.amazonaws.com/role-arn: "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>"   Azure (Workload Identity):     annotations:       azure.workload.identity/client-id: "<CLIENT_ID>"   GCP (Workload Identity):     annotations:       iam.gke.io/gcp-service-account: "<GSA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com" See https://www.union.ai/docs/v1/selfmanaged/deployment/configuration/persistent-logs/ |
| flyteagent | object | `{"enabled":false,"plugin_config":{}}` | Flyteagent configuration |
| flyteconnector | object | see [values.yaml](values.yaml) | Flyte connector deployment configuration. Connectors provide external service integrations (e.g., Databricks, SageMaker, Snowflake) for Flyte tasks. |
| flyteconnector.additionalContainers | list | `[]` | Appends additional containers to the deployment spec. May include template values. |
| flyteconnector.additionalEnvs | list | `[]` | Appends additional envs to the deployment spec. May include template values |
| flyteconnector.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| flyteconnector.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| flyteconnector.affinity | object | `{}` | affinity for flyteconnector deployment |
| flyteconnector.autoscaling | object | `{"maxReplicas":5,"minReplicas":2,"targetCPUUtilizationPercentage":80,"targetMemoryUtilizationPercentage":80}` | Horizontal pod autoscaler configuration for flyteconnector. |
| flyteconnector.autoscaling.maxReplicas | int | `5` | Maximum number of flyteconnector replicas. |
| flyteconnector.autoscaling.minReplicas | int | `2` | Minimum number of flyteconnector replicas. |
| flyteconnector.autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization percentage for scaling. |
| flyteconnector.autoscaling.targetMemoryUtilizationPercentage | int | `80` | Target memory utilization percentage for scaling. |
| flyteconnector.configPath | string | `"/etc/flyteconnector/config/*.yaml"` | Default glob string for searching configuration files |
| flyteconnector.enabled | bool | `true` | Enable or disable the flyteconnector deployment. |
| flyteconnector.extraArgs | object | `{}` | Appends extra command line arguments to the main command |
| flyteconnector.image | object | `{"pullPolicy":"IfNotPresent","repository":"ghcr.io/flyteorg/flyte-connectors","tag":"py3.13-2.0.0b50.dev3-g695bb1db3.d20260122"}` | Container image configuration for flyteconnector. |
| flyteconnector.image.pullPolicy | string | `"IfNotPresent"` | Docker image pull policy. |
| flyteconnector.image.repository | string | `"ghcr.io/flyteorg/flyte-connectors"` | Docker image for flyteconnector deployment. |
| flyteconnector.image.tag | string | `"py3.13-2.0.0b50.dev3-g695bb1db3.d20260122"` | Docker image tag for flyteconnector. |
| flyteconnector.nodeSelector | object | `{}` | nodeSelector for flyteconnector deployment |
| flyteconnector.podAnnotations | object | `{}` | Annotations for flyteconnector pods |
| flyteconnector.ports | object | `{"containerPort":8000,"name":"grpc"}` | gRPC port configuration for flyteconnector. |
| flyteconnector.ports.containerPort | int | `8000` | Container port for the gRPC service. |
| flyteconnector.ports.name | string | `"grpc"` | Port name. |
| flyteconnector.priorityClassName | string | `""` | Sets priorityClassName for datacatalog pod(s). |
| flyteconnector.prometheusPort | object | `{"containerPort":9090,"name":"metric"}` | Prometheus metrics port configuration. |
| flyteconnector.prometheusPort.containerPort | int | `9090` | Container port for Prometheus metrics. |
| flyteconnector.prometheusPort.name | string | `"metric"` | Port name. |
| flyteconnector.replicaCount | int | `2` | Replicas count for flyteconnector deployment |
| flyteconnector.resources | object | `{"limits":{"cpu":"1.5","ephemeral-storage":"100Mi","memory":"1500Mi"},"requests":{"cpu":"1","ephemeral-storage":"100Mi","memory":"1000Mi"}}` | Default resources requests and limits for flyteconnector deployment |
| flyteconnector.service | object | `{"clusterIP":"None","type":"ClusterIP"}` | Service settings for flyteconnector |
| flyteconnector.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecrets":[]}` | Configuration for service accounts for flyteconnector |
| flyteconnector.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to flyteconnector pods |
| flyteconnector.serviceAccount.create | bool | `true` | Should a service account be created for flyteconnector |
| flyteconnector.serviceAccount.imagePullSecrets | list | `[]` | ImagePullSecrets to automatically assign to the service account |
| flyteconnector.tolerations | list | `[]` | tolerations for flyteconnector deployment |
| flytepropeller | object | see [values.yaml](values.yaml) | Flytepropeller configuration. Propeller is the workflow execution engine that processes registered workflows by evaluating node dependencies and launching task pods. |
| flytepropeller.additionalContainers | object | `{}` | Additional sidecar containers to add to the propeller pod. |
| flytepropeller.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| flytepropeller.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| flytepropeller.affinity | object | `{}` | affinity for Flytepropeller deployment. |
| flytepropeller.cacheSizeMbs | int | `0` | Maximum size in MiB for the in-memory blob cache. 0 disables caching. |
| flytepropeller.configPath | string | `"/etc/flyte/config/*.yaml"` | Default regex string for searching configuration files. |
| flytepropeller.enabled | bool | `true` | Enable or disable the Flytepropeller deployment. |
| flytepropeller.extraArgs | object | `{}` | Extra arguments to pass to propeller. |
| flytepropeller.nodeName | string | `""` | nodeName constraints for Flytepropeller deployment. |
| flytepropeller.nodeSelector | object | `{}` | nodeSelector for Flytepropeller deployment. |
| flytepropeller.podAnnotations | object | `{}` | Annotations for Flytepropeller pods. |
| flytepropeller.podEnv | object | `{}` | Additional environment variables for propeller pods. |
| flytepropeller.podLabels | object | `{}` | Labels for the Flytepropeller pods. |
| flytepropeller.priorityClassName | string | `"system-cluster-critical"` | PriorityClassName for Flytepropeller pods. Set to "system-cluster-critical" to ensure propeller is scheduled even under resource pressure. |
| flytepropeller.replicaCount | int | `1` | Replicas count for Flytepropeller deployment. |
| flytepropeller.resources | object | `{"limits":{"cpu":"3","memory":"3Gi"},"requests":{"cpu":"1","memory":"1Gi"}}` | Default resources requests and limits for Flytepropeller deployment. |
| flytepropeller.secretName | string | `"union-secret-auth"` | Name of the Kubernetes secret containing authentication credentials. |
| flytepropeller.service | object | `{"additionalPorts":[{"name":"fasttask","port":15605,"protocol":"TCP","targetPort":15605}],"enabled":true}` | Service configuration for propeller. |
| flytepropeller.service.additionalPorts | list | `[{"name":"fasttask","port":15605,"protocol":"TCP","targetPort":15605}]` | Additional ports to expose on the propeller service. |
| flytepropeller.service.enabled | bool | `true` | Enable the propeller Kubernetes service. |
| flytepropeller.serviceAccount | object | `{"annotations":{},"imagePullSecrets":[]}` | Configuration for service accounts for FlytePropeller. |
| flytepropeller.serviceAccount.annotations | object | `{}` | Annotations for ServiceAccount attached to FlytePropeller pods. |
| flytepropeller.serviceAccount.imagePullSecrets | list | `[]` | ImagePullSecrets to automatically assign to the service account. |
| flytepropeller.terminationMessagePolicy | string | `""` | Override the termination message policy for propeller pods. |
| flytepropeller.tolerations | list | `[]` | tolerations for Flytepropeller deployment. |
| flytepropeller.topologySpreadConstraints | object | `{}` | topologySpreadConstraints for Flytepropeller deployment. |
| flytepropellerwebhook | object | see [values.yaml](values.yaml) | Configuration for the Flytepropeller webhook |
| flytepropellerwebhook.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| flytepropellerwebhook.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| flytepropellerwebhook.affinity | object | `{}` | affinity for webhook deployment |
| flytepropellerwebhook.certificate | object | `{"certManager":{"issuerRef":{}},"duration":"8760h","external":{"caCert":"","tlsCrt":"","tlsKey":""},"provider":"helm","renewBefore":"720h"}` | Configuration for webhook certificates |
| flytepropellerwebhook.certificate.certManager | object | `{"issuerRef":{}}` | cert-manager configuration (only used when provider is "certManager") |
| flytepropellerwebhook.certificate.certManager.issuerRef | object | `{}` | Issuer reference for cert-manager. If not set, a self-signed issuer will be created. |
| flytepropellerwebhook.certificate.duration | string | `"8760h"` | Duration of the certificate (only used with certManager provider) |
| flytepropellerwebhook.certificate.external | object | `{"caCert":"","tlsCrt":"","tlsKey":""}` | External certificate configuration (only used when provider is "external") |
| flytepropellerwebhook.certificate.external.caCert | string | `""` | Base64-encoded CA certificate (PEM format) |
| flytepropellerwebhook.certificate.external.tlsCrt | string | `""` | Base64-encoded TLS certificate (PEM format) |
| flytepropellerwebhook.certificate.external.tlsKey | string | `""` | Base64-encoded TLS private key (PEM format) |
| flytepropellerwebhook.certificate.provider | string | `"helm"` | `flytepropeller webhook init-certs` to populate an empty secret, then the webhook uses those certs. |
| flytepropellerwebhook.certificate.renewBefore | string | `"720h"` | Renew before duration (only used with certManager provider) |
| flytepropellerwebhook.enabled | bool | `true` | enable or disable secrets webhook |
| flytepropellerwebhook.managedConfig | bool | `true` | Enable Helm-managed MutatingWebhookConfiguration (if false, the webhook will create its own) |
| flytepropellerwebhook.nodeName | string | `""` | nodeName constraints for webhook deployment |
| flytepropellerwebhook.nodeSelector | object | `{}` | nodeSelector for webhook deployment |
| flytepropellerwebhook.podAnnotations | object | `{}` | Annotations for webhook pods |
| flytepropellerwebhook.podEnv | object | `{}` | Additional webhook container environment variables |
| flytepropellerwebhook.podLabels | object | `{}` | Labels for webhook pods |
| flytepropellerwebhook.priorityClassName | string | `""` | Sets priorityClassName for webhook pod |
| flytepropellerwebhook.replicaCount | int | `1` | Replicas |
| flytepropellerwebhook.securityContext | object | `{"fsGroup":65534,"fsGroupChangePolicy":"Always","runAsNonRoot":true,"runAsUser":1001,"seLinuxOptions":null}` | Sets securityContext for webhook pod(s). |
| flytepropellerwebhook.service | object | `{"annotations":{"projectcontour.io/upstream-protocol.h2c":"grpc"},"port":443,"targetPort":9443,"type":"ClusterIP"}` | Service settings for the webhook |
| flytepropellerwebhook.service.port | int | `443` | HTTPS port for the webhook service |
| flytepropellerwebhook.service.targetPort | int | `9443` | Target port for the webhook service (container port) |
| flytepropellerwebhook.serviceAccount | object | `{"imagePullSecrets":[]}` | Configuration for service accounts for the webhook |
| flytepropellerwebhook.serviceAccount.imagePullSecrets | list | `[]` | ImagePullSecrets to automatically assign to the service account |
| flytepropellerwebhook.tolerations | list | `[]` | tolerations for webhook deployment |
| flytepropellerwebhook.topologySpreadConstraints | object | `{}` | topologySpreadConstraints for webhook deployment |
| flytepropellerwebhook.webhook | object | see [values.yaml](values.yaml) | Configuration for the webhook MutatingWebhookConfiguration and certificates |
| flytepropellerwebhook.webhook.configurationName | string | `"union-pod-webhook-{{ tpl .Values.orgName . }}"` | Name of the MutatingWebhookConfiguration resource |
| flytepropellerwebhook.webhook.failurePolicy | string | `"Fail"` | Failure policy for the webhook (Fail or Ignore) |
| flytepropellerwebhook.webhook.reinvocationPolicy | string | `"Never"` | Reinvocation policy for the webhook |
| flytepropellerwebhook.webhook.timeoutSeconds | int | `30` | Timeout in seconds for the webhook |
| flytepropellerwebhook.webhook.webhooks | object | see [values.yaml](values.yaml) | Webhook configurations to create |
| flytepropellerwebhook.webhook.webhooks.managedImage | object | see [values.yaml](values.yaml) | Managed image webhook configuration (requires Union operator support) |
| flytepropellerwebhook.webhook.webhooks.managedImage.name | string | `"managed-image-webhook.union.ai"` | Name of the webhook |
| flytepropellerwebhook.webhook.webhooks.managedImage.objectSelector | object | `{"matchExpressions":[{"key":"organization","operator":"Exists"},{"key":"project","operator":"Exists"},{"key":"domain","operator":"Exists"}],"matchLabels":{"organization":"{{ tpl .Values.orgName . }}"}}` | Object selector for the webhook (matchExpressions) |
| flytepropellerwebhook.webhook.webhooks.managedImage.path | string | `"/mutate--v1-pod/managed-image"` | Path for the webhook |
| flytepropellerwebhook.webhook.webhooks.secrets | object | `{"enabled":true,"name":"flyte-pod-webhook.flyte.org","objectSelector":{"matchLabels":{"inject-flyte-secrets":"true","organization":"{{ tpl .Values.orgName . }}"}},"path":"/mutate--v1-pod/secrets"}` | Secrets injection webhook configuration |
| flytepropellerwebhook.webhook.webhooks.secrets.name | string | `"flyte-pod-webhook.flyte.org"` | Name of the webhook |
| flytepropellerwebhook.webhook.webhooks.secrets.objectSelector | object | `{"matchLabels":{"inject-flyte-secrets":"true","organization":"{{ tpl .Values.orgName . }}"}}` | Object selector for the webhook |
| flytepropellerwebhook.webhook.webhooks.secrets.path | string | `"/mutate--v1-pod/secrets"` | Path for the webhook |
| fullnameOverride | string | `""` | Override the chart fullname. |
| global.CLIENT_ID | string | `""` | Client ID for dataplane authentication. Provided by Union team. |
| global.CLUSTER_NAME | string | `""` | Unique cluster identifier. Format: Lowercase alphanumeric with hyphens. Example: "prod-us-east-1". Must be unique within your organization. |
| global.FAST_REGISTRATION_BUCKET | string | `""` | S3 bucket for code uploads. Example: "my-union-fast-registration-bucket". Can be same as metadata bucket or separate. |
| global.METADATA_BUCKET | string | `""` | S3 bucket for workflow metadata. Example: "my-union-metadata-bucket". Bucket must exist before deployment. |
| global.ORG_NAME | string | `""` | Organization name. Format: RFC 1123 compliant (lowercase alphanumeric and hyphens). Example: "acme-corp". Provided by Union team. |
| global.UNION_CONTROL_PLANE_HOST | string | `""` | Union control plane hostname. Format: "hostname" (no protocol prefix for standard BYOC). Example: "mycompany.unionai.cloud". Provided by Union team for BYOC deployments. |
| host | string | `"{{ .Values.global.UNION_CONTROL_PLANE_HOST }}"` | Set the control plane host for your Union dataplane installation.  This will be provided by Union. |
| image | object | see [values.yaml](values.yaml) | Container image configuration for Union services. |
| image.flytecopilot | object | `{"pullPolicy":"IfNotPresent","repository":"cr.flyte.org/flyteorg/flytecopilot","tag":"v1.14.1"}` | Flytecopilot sidecar image configuration. Copilot handles data I/O for task pods. |
| image.flytecopilot.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.flytecopilot.repository | string | `"cr.flyte.org/flyteorg/flytecopilot"` | Image repository. |
| image.flytecopilot.tag | string | `"v1.14.1"` | Image tag. |
| image.kubeStateMetrics | object | `{"pullPolicy":"IfNotPresent","repository":"registry.k8s.io/kube-state-metrics/kube-state-metrics","tag":"v2.11.0"}` | Kube-state-metrics image configuration. |
| image.kubeStateMetrics.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.kubeStateMetrics.repository | string | `"registry.k8s.io/kube-state-metrics/kube-state-metrics"` | Image repository. |
| image.kubeStateMetrics.tag | string | `"v2.11.0"` | Image tag. |
| image.union | object | `{"pullPolicy":"IfNotPresent","repository":"public.ecr.aws/p0i0a9q8/unionoperator","tag":""}` | Image repository for the operator and union services. |
| image.union.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.union.repository | string | `"public.ecr.aws/p0i0a9q8/unionoperator"` | Image repository. |
| image.union.tag | string | `""` | Image tag. Defaults to the chart appVersion if empty. |
| imageBuilder | object | see [values.yaml](values.yaml) | Image builder configuration for building container images from Flyte ImageSpec. |
| imageBuilder.authenticationType | string | `"noop"` | How build-image task and operator proxy will attempt to authenticate to the container registry. Supported values: "noop" (no auth), "google" (docker-credential-gcr), "aws" (docker-credential-ecr-login), "azure" (az acr login, requires Azure Workload Identity). |
| imageBuilder.buildkit | object | see [values.yaml](values.yaml) | BuildKit daemon configuration for container image builds. |
| imageBuilder.buildkit.additionalVolumeMounts | list | `[]` | Additional volume mounts to add to the buildkit container. |
| imageBuilder.buildkit.additionalVolumes | list | `[]` | Additional volumes to add to the buildkit pod. |
| imageBuilder.buildkit.autoscaling | object | `{"enabled":false,"maxReplicas":2,"minReplicas":1,"targetCPUUtilizationPercentage":60}` | Buildkit HPA configuration. |
| imageBuilder.buildkit.autoscaling.enabled | bool | `false` | Enable HPA for buildkit. |
| imageBuilder.buildkit.autoscaling.maxReplicas | int | `2` | Maximum number of buildkit replicas. |
| imageBuilder.buildkit.autoscaling.minReplicas | int | `1` | Minimum number of buildkit replicas. |
| imageBuilder.buildkit.autoscaling.targetCPUUtilizationPercentage | int | `60` | Target CPU utilization for scaling. Set lower than usual to promote faster scale out and reduce queue times for build requests. |
| imageBuilder.buildkit.deploymentStrategy | string | `"Recreate"` | Deployment strategy for buildkit deployment. |
| imageBuilder.buildkit.enabled | bool | `true` | Enable buildkit service within this release. |
| imageBuilder.buildkit.fullnameOverride | string | `""` | The name to use for the buildkit deployment, service, configmap, etc. |
| imageBuilder.buildkit.image | object | `{"pullPolicy":"IfNotPresent","repository":"moby/buildkit","tag":"buildx-stable-1"}` | Buildkit container image configuration. |
| imageBuilder.buildkit.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| imageBuilder.buildkit.image.repository | string | `"moby/buildkit"` | Image repository. |
| imageBuilder.buildkit.image.tag | string | `"buildx-stable-1"` | Image tag. When rootless mode is enabled, "-rootless" is appended automatically (e.g. "buildx-stable-1" becomes "buildx-stable-1-rootless") unless the tag already contains "rootless". |
| imageBuilder.buildkit.log | object | `{"debug":false,"format":"text"}` | Logging configuration for buildkit. |
| imageBuilder.buildkit.log.debug | bool | `false` | Enable debug logging. |
| imageBuilder.buildkit.log.format | string | `"text"` | Log format ("text" or "json"). |
| imageBuilder.buildkit.nodeSelector | object | `{}` | Node selector for buildkit pods. |
| imageBuilder.buildkit.oci | object | `{"maxParallelism":0}` | OCI worker configuration for buildkit. |
| imageBuilder.buildkit.oci.maxParallelism | int | `0` | Maximum number of concurrent builds. 0 means unbounded. |
| imageBuilder.buildkit.pdb | object | `{"minAvailable":1}` | Pod disruption budget for buildkit. |
| imageBuilder.buildkit.pdb.minAvailable | int | `1` | Minimum available pods. |
| imageBuilder.buildkit.podAnnotations | object | `{}` | Annotations for buildkit pods. |
| imageBuilder.buildkit.podEnv | list | `[]` | Appends additional environment variables to the buildkit container's spec. |
| imageBuilder.buildkit.replicaCount | int | `1` | Replicas count for Buildkit deployment. |
| imageBuilder.buildkit.resources | object | `{"requests":{"cpu":1,"ephemeral-storage":"20Gi","memory":"1Gi"}}` | Resource requests and limits for the buildkit container. |
| imageBuilder.buildkit.rootless | bool | `true` | Run buildkit in rootless mode (non-privileged). Uses the moby/buildkit rootless image variant which bundles RootlessKit to set up user namespaces. Requires kernel >= 5.11 with unprivileged user namespace support. |
| imageBuilder.buildkit.service | object | `{"annotations":{},"loadbalancerIp":"","port":1234,"type":"ClusterIP"}` | Service configuration for buildkit. |
| imageBuilder.buildkit.service.annotations | object | `{}` | Service annotations. |
| imageBuilder.buildkit.service.loadbalancerIp | string | `""` | Static IP address for load balancer (only used with LoadBalancer type). |
| imageBuilder.buildkit.service.port | int | `1234` | Service port. |
| imageBuilder.buildkit.service.type | string | `"ClusterIP"` | Service type. |
| imageBuilder.buildkit.serviceAccount | object | `{"annotations":{},"create":true,"imagePullSecret":"","name":"union-imagebuilder"}` | Service account configuration for buildkit |
| imageBuilder.buildkit.tolerations | list | `[]` | Tolerations for buildkit pods. |
| imageBuilder.buildkitUri | string | `""` | The URI of the buildkitd service. Used for externally managed buildkitd services. Leaving empty and setting imageBuilder.buildkit.enabled to true will create a buildkitd service. E.g. "tcp://buildkitd.buildkit.svc.cluster.local:1234" |
| imageBuilder.defaultRepository | string | `"registry.depot.dev"` | Note, the build-image task will fail unless "registry" is specified or a default repository is provided. |
| imageBuilder.enabled | bool | `true` | Enable or disable the image builder feature. |
| imageBuilder.targetConfigMapName | string | `"build-image-config"` | The config map build-image container task attempts to reference. Should not change unless coordinated with Union technical support. |
| ingress | object | `{"dataproxy":{"annotations":{},"class":"","hostOverride":"","tls":{}},"enabled":false,"host":"","serving":{"annotations":{},"class":"","hostOverride":"","tls":{}}}` | Ingress configuration for exposing dataplane services externally. Enable this when not using Cloudflare tunnels for service access. |
| ingress-nginx | object | see [values.yaml](values.yaml) | Ingress-nginx subchart configuration. Disabled by default; enable if you need an ingress controller for dataplane services instead of Cloudflare tunnels. |
| ingress-nginx.enabled | bool | `false` | Enable or disable the ingress-nginx controller subchart. |
| ingress.dataproxy | object | `{"annotations":{},"class":"","hostOverride":"","tls":{}}` | Dataproxy specific ingress configuration. |
| ingress.dataproxy.annotations | object | `{}` | Annotations to apply to the ingress resource. |
| ingress.dataproxy.class | string | `""` | Ingress class name. |
| ingress.dataproxy.hostOverride | string | `""` | Override the ingress host. Can reference Kubernetes service DNS, e.g. dataproxy-service.{{ .Release.Namespace }}.svc.cluster.local |
| ingress.dataproxy.tls | object | `{}` | Ingress TLS configuration. |
| ingress.enabled | bool | `false` | Enable or disable ingress resources. |
| ingress.host | string | `""` | Default host for ingress rules. Omitted if empty. |
| ingress.serving | object | `{"annotations":{},"class":"","hostOverride":"","tls":{}}` | Serving specific ingress configuration. |
| ingress.serving.annotations | object | `{}` | Annotations to apply to the ingress resource. |
| ingress.serving.class | string | `""` | Ingress class name. |
| ingress.serving.hostOverride | string | `""` | (Optional) Host override for serving ingress rule. Defaults to *.apps.{{ .Values.host }}. |
| ingress.serving.tls | object | `{}` | Ingress TLS configuration. |
| knative-operator | object | `{"crds":{"install":true},"enabled":true}` | Knative operator subchart. Required for app serving. |
| knative-operator.crds | object | `{"install":true}` | Install Knative CRDs. |
| knative-operator.enabled | bool | `true` | Enable or disable the Knative operator. Must be enabled when serving.enabled is true. |
| low_privilege | bool | `false` | Scopes the deployment, permissions and actions created into a single namespace and avoids any deployments that would  require additional permissions on the cluster. This limits the functionality though. |
| metrics-server | object | `{"enabled":false}` | Enable or disable the metrics-server subchart. Only needed if your cluster does not already have a metrics server. |
| monitoring | object | `{"enabled":true}` | Global monitoring toggle. When disabled, skips creation of ServiceMonitor and related monitoring resources. |
| monitoring.enabled | bool | `true` | Enable or disable monitoring resource creation. |
| nameOverride | string | `""` | Override the chart name. |
| namespace_mapping | object | `{}` | Namespace mapping template for mapping Union runs to Kubernetes namespaces. This is the canonical source of truth. All dataplane services (propeller, clusterresourcesync, operator, executor) will inherit this value unless explicitly overridden in their service-specific config sections (config.namespace_config, config.operator.org, executor.raw_config). |
| namespaces | object | `{"enabled":true}` | Namespace management configuration. |
| namespaces.enabled | bool | `true` | Automatically create the release namespace if it does not exist. |
| nodeobserver | object | see [values.yaml](values.yaml) | Node observer DaemonSet configuration. Monitors node health and critical DaemonSet availability to detect infrastructure issues affecting workflow execution. |
| nodeobserver.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| nodeobserver.additionalVolumes | list | `[]` | Appends additional volumes to the daemonset spec. May include template values. |
| nodeobserver.affinity | object | `{}` | affinity configurations for the pods associated with nodeobserver services |
| nodeobserver.config | object | `{"criticalDaemonSets":[]}` | Nodeobserver configuration. |
| nodeobserver.config.criticalDaemonSets | list | `[]` | List of critical DaemonSets to monitor. Nodeobserver will report nodes as unhealthy if these DaemonSets are not running. |
| nodeobserver.enabled | bool | `false` | Enable or disable nodeobserver. |
| nodeobserver.nodeName | string | `""` | nodeName constraints for the pods associated with nodeobserver services |
| nodeobserver.nodeSelector | object | `{}` | nodeSelector constraints for the pods associated with nodeobserver services |
| nodeobserver.podAnnotations | object | `{}` | Additional pod annotations for the nodeobserver services |
| nodeobserver.podEnv | list | `[{"name":"KUBE_NODE_NAME","valueFrom":{"fieldRef":{"fieldPath":"spec.nodeName"}}},{"name":"LOG_LEVEL","value":"4"}]` | Additional pod environment variables for the nodeobserver services |
| nodeobserver.podSecurityContext | object | `{}` | Pod-level security context for the nodeobserver. |
| nodeobserver.resources | object | `{"limits":{"cpu":"1","memory":"500Mi"},"requests":{"cpu":"500m","memory":"100Mi"}}` | Kubernetes resource configuration for the nodeobserver service |
| nodeobserver.securityContext | object | `{"capabilities":{"add":["SYS_ADMIN"]},"privileged":true,"runAsNonRoot":false,"runAsUser":0}` | Container-level security context for the nodeobserver. Requires privileged access for node-level inspection. |
| nodeobserver.serviceAccount | object | `{"annotations":{},"name":""}` | Service account configuration for the nodeobserver. |
| nodeobserver.serviceAccount.annotations | object | `{}` | Annotations for the nodeobserver service account. |
| nodeobserver.serviceAccount.name | string | `""` | Override the service account name for the nodeobserver. |
| nodeobserver.tolerations | list | `[{"effect":"NoSchedule","operator":"Exists"}]` | tolerations for the pods associated with nodeobserver services |
| nodeobserver.topologySpreadConstraints | object | `{}` | topologySpreadConstraints for the pods associated with nodeobserver services |
| objectStore | object | `{"service":{"grpcPort":8089,"httpPort":8080}}` | Union Object Store service configuration. Provides an internal API for accessing object storage. |
| objectStore.service | object | `{"grpcPort":8089,"httpPort":8080}` | Service port configuration. |
| objectStore.service.grpcPort | int | `8089` | gRPC port for the object store service. |
| objectStore.service.httpPort | int | `8080` | HTTP port for the object store service. |
| opencost | object | see [values.yaml](values.yaml) | OpenCost subchart configuration for cost allocation and monitoring. |
| opencost.enabled | bool | `true` | Enable or disable the opencost installation. |
| opencost.opencost | object | see [values.yaml](values.yaml) | OpenCost application configuration. |
| operator | object | see [values.yaml](values.yaml) | Union operator deployment configuration. The operator manages cluster lifecycle, usage reporting, heartbeat checks, and tunnel connectivity to the Union control plane. |
| operator.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| operator.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| operator.affinity | object | `{}` | affinity configurations for the operator pods. |
| operator.autoscaling | object | `{"enabled":false}` | Horizontal pod autoscaler configuration for the operator. |
| operator.autoscaling.enabled | bool | `false` | Enable HPA for the operator deployment. |
| operator.enableTunnelService | bool | `true` | Enable the Cloudflare tunnel service for secure control plane connectivity. |
| operator.imagePullSecrets | list | `[]` | Image pull secrets for the operator deployment. |
| operator.nodeName | string | `""` | nodeName constraints for the operator pods. |
| operator.nodeSelector | object | `{}` | nodeSelector constraints for the operator pods. |
| operator.podAnnotations | object | `{}` | Annotations for operator pods. |
| operator.podEnv | object | `{}` | Additional environment variables for operator pods. |
| operator.podLabels | object | `{}` | Labels for operator pods. |
| operator.podSecurityContext | object | `{}` | Pod-level security context for the operator. |
| operator.priorityClassName | string | `""` | PriorityClassName for operator pods. |
| operator.replicas | int | `1` | Number of operator replicas. |
| operator.resources | object | `{"limits":{"cpu":"2","memory":"3Gi"},"requests":{"cpu":"1","memory":"1Gi"}}` | Resource requests and limits for the operator deployment. |
| operator.secretName | string | `"union-secret-auth"` | Name of the Kubernetes secret containing authentication credentials. |
| operator.securityContext | object | `{}` | Container-level security context for the operator. |
| operator.serviceAccount | object | `{"annotations":{},"create":true,"name":"operator-system"}` | Service account configuration for the operator. |
| operator.serviceAccount.annotations | object | `{}` | Annotations for the operator service account (e.g., for cloud IAM role binding). |
| operator.serviceAccount.create | bool | `true` | Create a dedicated service account for the operator. |
| operator.serviceAccount.name | string | `"operator-system"` | Name of the operator service account. |
| operator.tolerations | list | `[]` | tolerations for the operator pods. |
| operator.topologySpreadConstraints | object | `{}` | topologySpreadConstraints for the operator pods. |
| orgName | string | `"{{ .Values.global.ORG_NAME }}"` | Organization name should be provided by Union. |
| prometheus | object | see [values.yaml](values.yaml) | Prometheus configuration (kube-prometheus-stack subchart). This section configures kube-prometheus-stack for monitoring the Union dataplane. By default, most Kubernetes component monitoring is disabled to reduce resource usage. Enable specific components as needed for your observability requirements. |
| prometheus.additionalPrometheusRulesMap | object | `{}` | Additional Prometheus recording or alerting rules. |
| prometheus.alertmanager | object | `{"enabled":false}` | Alertmanager configuration. |
| prometheus.alertmanager.enabled | bool | `false` | Enable or disable the Alertmanager deployment. |
| prometheus.crds | object | `{"enabled":true}` | Prometheus Operator CRD configuration. |
| prometheus.crds.enabled | bool | `true` | Install Prometheus Operator CRDs. |
| prometheus.defaultRules | object | see [values.yaml](values.yaml) | Default Prometheus alerting and recording rules. |
| prometheus.defaultRules.create | bool | `false` | Create default alerting and recording rules. |
| prometheus.defaultRules.rules | object | see [values.yaml](values.yaml) | Individual Prometheus rule group toggles. |
| prometheus.defaultRules.rules.kubeApiserverAvailability | bool | `false` | API Server availability alerts (e.g., KubeAPIDown, KubeAPITerminatedRequests) |
| prometheus.defaultRules.rules.kubeApiserverBurnrate | bool | `false` | API Server burn rate alerts for SLO monitoring |
| prometheus.defaultRules.rules.kubeApiserverHistogram | bool | `false` | API Server latency histogram recording rules |
| prometheus.defaultRules.rules.kubeApiserverSlos | bool | `false` | API Server SLO (Service Level Objective) rules |
| prometheus.defaultRules.rules.kubeControllerManager | bool | `false` | Uncomment to enable: SLO-based alerting for API server performance kubeApiserverSlos: true |
| prometheus.enabled | bool | `true` | Enable or disable the kube-prometheus-stack deployment. |
| prometheus.grafana | object | see [values.yaml](values.yaml) | Grafana configuration for visualization dashboards. |
| prometheus.grafana.additionalDataSources | list | `[]` | Additional data sources (e.g., Loki for logs) |
| prometheus.grafana.admin | object | `{"existingSecret":"","passwordKey":"admin-password","userKey":"admin-user"}` | Use existing secret for admin credentials (recommended for production) |
| prometheus.grafana.adminPassword | string | `"union-dataplane"` | Default admin password (change in production!). |
| prometheus.grafana.adminUser | string | `"admin"` | Default admin username (change in production!). |
| prometheus.grafana.dashboardsConfigMaps | object | `{}` | Custom dashboards can be configured with additional ConfigMaps Format: <configmap-name>: <folder-name> |
| prometheus.grafana.enabled | bool | `false` | Enable or disable the Grafana deployment. |
| prometheus.grafana.ingress | object | `{"enabled":false}` | Ingress configuration for external Grafana access |
| prometheus.ingress | object | `{"annotations":{},"enabled":false,"hosts":[]}` | Prometheus ingress configuration for external access to the Prometheus UI. |
| prometheus.ingress.annotations | object | `{}` | Annotations for the Prometheus ingress resource. |
| prometheus.ingress.enabled | bool | `false` | Enable or disable ingress for Prometheus. |
| prometheus.ingress.hosts | list | `[]` | Hosts for the Prometheus ingress resource. |
| prometheus.kube-state-metrics | object | `{"metricRelabelings":[{"action":"keep","regex":"kube_pod_container_resource_(limits|requests)|kube_pod_status_phase|kube_node_(labels|status_allocatable|status_condition|status_capacity)|kube_namespace_labels|kube_pod_container_status_(waiting|terminated|last_terminated).*_reason|kube_daemonset_status_number_unavailable|kube_deployment_status_replicas_unavailable|kube_resourcequota|kube_pod_info|kube_node_info|kube_pod_container_status_restarts_total","separator":";","sourceLabels":["__name__"]},{"action":"drop","regex":"kube_pod_status_phase;(Succeeded|Failed)","separator":";","sourceLabels":["__name__","phase"]},{"action":"replace","regex":"(.*)","sourceLabels":["node"],"targetLabel":"nodename"},{"action":"replace","regex":"(.+)","sourceLabels":["label_node_group_name"],"targetLabel":"label_node_pool_name"}],"namespaceOverride":"kube-system"}` | Kube-state-metrics subchart configuration. Provides Kubernetes object metrics to Prometheus. |
| prometheus.kubeApiServer | object | `{"enabled":false}` | -------------------------------------------------------------------------- Enable kubeApiServer to collect metrics from the Kubernetes API server. This provides insights into API request latencies, error rates, and throughput. Note: Requires appropriate RBAC permissions and network access to the API server. |
| prometheus.nodeExporter | object | `{"enabled":false}` | Node exporter configuration for collecting host-level metrics. |
| prometheus.nodeExporter.enabled | bool | `false` | Enable or disable the node exporter DaemonSet. |
| prometheus.prometheus | object | see [values.yaml](values.yaml) | Prometheus server configuration. |
| prometheus.prometheus-node-exporter | object | `{"namespaceOverride":"kube-system"}` | Prometheus node-exporter subchart configuration. |
| prometheus.prometheus.enabled | bool | `true` | Enable the Prometheus server. |
| prometheus.prometheus.prometheusSpec | object | see [values.yaml](values.yaml) | Prometheus server spec configuration. |
| prometheus.prometheus.prometheusSpec.maximumStartupDurationSeconds | int | `900` | Maximum time in seconds for Prometheus startup before it is considered failed. |
| prometheus.prometheus.prometheusSpec.resources | object | `{"limits":{"cpu":"3","memory":"3500Mi"},"requests":{"cpu":"1","memory":"1Gi"}}` | Resource requests and limits for the Prometheus server. |
| prometheus.prometheus.prometheusSpec.retention | string | `"3d"` | How long to retain metrics data. |
| prometheus.prometheus.prometheusSpec.routePrefix | string | `"/prometheus/"` | URL path prefix for the Prometheus web UI. |
| prometheus.prometheusOperator | object | `{"fullnameOverride":"prometheus-operator"}` | Prometheus Operator configuration. |
| proxy | object | see [values.yaml](values.yaml) | Union operator proxy configuration. The proxy serves as the dataplane's API gateway, handling data uploads/downloads, secret management, and image building requests. |
| proxy.additionalVolumeMounts | list | `[]` | Appends additional volume mounts to the main container's spec. May include template values. |
| proxy.additionalVolumes | list | `[]` | Appends additional volumes to the deployment spec. May include template values. |
| proxy.affinity | object | `{}` | affinity configurations for the proxy pods. |
| proxy.autoscaling | object | `{"enabled":false,"maxReplicas":10,"minReplicas":1,"targetCPUUtilizationPercentage":80}` | Horizontal pod autoscaler configuration for the proxy. |
| proxy.autoscaling.enabled | bool | `false` | Enable HPA for the proxy deployment. |
| proxy.autoscaling.maxReplicas | int | `10` | Maximum number of proxy replicas. |
| proxy.autoscaling.minReplicas | int | `1` | Minimum number of proxy replicas. |
| proxy.autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization percentage for scaling. |
| proxy.enableTunnelService | bool | `true` | Enable the Cloudflare tunnel service for secure control plane connectivity. |
| proxy.imagePullSecrets | list | `[]` | Image pull secrets for the proxy deployment. |
| proxy.nodeName | string | `""` | nodeName constraint for the proxy pods. |
| proxy.nodeSelector | object | `{}` | nodeSelector constraints for the proxy pods. |
| proxy.podAnnotations | object | `{}` | Annotations for proxy pods. |
| proxy.podEnv | object | `{}` | Additional environment variables for proxy pods. |
| proxy.podLabels | object | `{}` | Labels for proxy pods. |
| proxy.podSecurityContext | object | `{}` | Pod-level security context for the proxy. |
| proxy.priorityClassName | string | `""` | PriorityClassName for proxy pods. |
| proxy.replicas | int | `1` | Number of proxy replicas. |
| proxy.resources | object | `{"limits":{"cpu":"3","memory":"3Gi"},"requests":{"cpu":"500m","memory":"500Mi"}}` | Resource requests and limits for the proxy container. |
| proxy.secretManager | object | `{"enabled":true,"namespace":"","type":"K8s"}` | Secret manager configuration for the proxy. Manages user-defined secrets for workflows. |
| proxy.secretManager.enabled | bool | `true` | Enable secret manager support for storing and injecting workflow secrets. |
| proxy.secretManager.namespace | string | `""` | Set the namespace for union managed secrets created through the native Kubernetes secret manager. If the namespace is not set, the release namespace will be used. |
| proxy.secretManager.type | string | `"K8s"` | The type of secret manager to use. Supported: "K8s" (native Kubernetes secrets). |
| proxy.secretName | string | `"union-secret-auth"` | Name of the Kubernetes secret containing authentication credentials. |
| proxy.securityContext | object | `{}` | Container-level security context for the proxy. |
| proxy.serviceAccount | object | `{"annotations":{},"create":true,"name":"proxy-system"}` | Service account configuration for the proxy. |
| proxy.serviceAccount.annotations | object | `{}` | Annotations for the proxy service account (e.g., for cloud IAM role binding). |
| proxy.serviceAccount.create | bool | `true` | Create a dedicated service account for the proxy. |
| proxy.serviceAccount.name | string | `"proxy-system"` | Name of the proxy service account. |
| proxy.tolerations | list | `[]` | tolerations for the proxy pods. |
| proxy.topologySpreadConstraints | object | `{}` | topologySpreadConstraints for the proxy pods. |
| proxy.tunnel_resources | object | `{"limits":{"cpu":"3","memory":"3Gi"},"requests":{"cpu":"500m","memory":"500Mi"}}` | Resource requests and limits for the Cloudflare tunnel sidecar container. |
| resourcequota | object | `{"create":false}` | Create global resource quotas for the cluster. |
| scheduling | object | `{"affinity":{},"nodeName":"","nodeSelector":{},"tolerations":[],"topologySpreadConstraints":{}}` | Global kubernetes scheduling constraints that will be applied to the pods.  Application specific constraints will always take precedence. |
| scheduling.affinity | object | `{}` | See https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node |
| scheduling.nodeSelector | object | `{}` | See https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node |
| scheduling.tolerations | list | `[]` | See https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration |
| scheduling.topologySpreadConstraints | object | `{}` | See https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints |
| secrets | object | `{"admin":{"clientId":"dataplane-operator","clientSecret":"","create":true,"enable":true}}` | Connection secrets for the Union control plane services. |
| secrets.admin.clientId | string | `"dataplane-operator"` | The client id used to authenticate to the control plane.  This will be provided by Union. |
| secrets.admin.clientSecret | string | `""` | The client secret used to authenticate to the control plane.  This will be provided by Union. |
| secrets.admin.create | bool | `true` | Create the secret resource containing the client id and secret.  If set to false the user is responsible for creating the secret before the installation. |
| secrets.admin.enable | bool | `true` | Enable or disable the admin secret.  This is used to authenticate to the control plane. |
| serving | object | see [values.yaml](values.yaml) | Configure app serving and knative. |
| serving.auth | object | `{"enabled":true}` | Union authentication and authorization configuration. |
| serving.auth.enabled | bool | `true` | Disabling is common if not leveraging Union Cloud SSO. |
| serving.enabled | bool | `false` | Enables the serving components. Installs Knative Serving. Knative-Operator must be running in the cluster for this to work. Enables app serving in operator. |
| serving.extraConfig | object | `{"deployment":{"registries-skipping-tag-resolving":"managed.cr.union.ai"}}` | Additional configuration for Knative serving |
| serving.metrics | bool | `true` | Enables scraping of metrics from the serving component |
| serving.replicas | int | `2` | The number of replicas to create for all components for high availability. |
| serving.resources | object | see [values.yaml](values.yaml) | Resources for serving components. |
| sparkoperator | object | `{"enabled":false,"plugin_config":{}}` | Spark operator integration configuration. |
| sparkoperator.enabled | bool | `false` | Enable or disable the Spark operator integration. |
| sparkoperator.plugin_config | object | `{}` | Plugin configuration for the Spark operator. |
| storage | object | see [values.yaml](values.yaml) | Object storage configuration used by all Union services. |
| storage.accessKey | string | `""` | The access key used for object storage. |
| storage.authType | string | `"accesskey"` | The authentication type.  Currently supports "accesskey" and "iam". |
| storage.bucketName | string | `"{{ .Values.global.METADATA_BUCKET }}"` | The bucket name used for object storage. |
| storage.cache | object | `{"maxSizeMBs":0,"targetGCPercent":70}` | Cache configuration for objects retrieved from object storage. |
| storage.custom | object | `{}` | Define custom configurations for the object storage.  Only used if the provider is set to "custom". |
| storage.disableSSL | bool | `false` | Disable SSL for object storage.  This should only used for local/sandbox installations. |
| storage.endpoint | string | `""` | Define or override the endpoint used for the object storage service. |
| storage.fastRegistrationBucketName | string | `"{{ .Values.global.FAST_REGISTRATION_BUCKET }}"` | The bucket name used for fast registration uploads. |
| storage.fastRegistrationURL | string | `""` | Override the URL for signed fast registration uploads.  This is only used for local/sandbox installations. |
| storage.gcp | object | `{"projectId":""}` | Define GCP specific configuration for object storage. |
| storage.injectPodEnvVars | bool | `true` | Injects the object storage access information into the pod environment variables.  Needed for providers that only support access and secret key based authentication. |
| storage.limits | object | `{"maxDownloadMBs":1024}` | Internal service limits for object storage access. |
| storage.metadataPrefix | string | `""` | Example for Azure: "abfs://my-container@mystorageaccount.dfs.core.windows.net" |
| storage.provider | string | `"compat"` | The storage provider to use.  Currently supports "compat", "aws", "oci", and "custom". |
| storage.region | string | `"us-east-1"` | The bucket region used for object storage. |
| storage.s3ForcePathStyle | bool | `true` | Use path style instead of domain style urls to access the object storage service. |
| storage.secretKey | string | `""` | The secret key used for object storage. |
| userRoleAnnotationKey | string | `"eks.amazonaws.com/role-arn"` | This is the annotation key that is added to service accounts.  Used with GCP and AWS. |
| userRoleAnnotationValue | string | `"arn:aws:iam::ACCOUNT_ID:role/flyte_project_role"` | This is the value of the annotation key that is added to service accounts. Used with GCP and AWS. |
