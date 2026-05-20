"""build-image ContainerTask definition, registered automatically by the
controlplane chart's post-install / post-upgrade Helm hook Job
(see templates/image-builder-bootstrap/).

Two env vars are required at registration time:
  APP_VERSION              — image tag for build-image + frontend-v2
                             (set by the Job from .Chart.AppVersion).
  UNION_IMAGE_NAME_PREFIX  — registry prefix where the build-image +
                             frontend-v2 images live
                             (set by the Job from values.imageBuilder.bootstrap
                             .unionImageNamePrefix).

Per-namespace defaults consumed at task execution time come from the
`build-image-config` ConfigMap that the union-operator BuildImageConfigSyncer
auto-creates in every namespace labelled `union.ai/namespace-type: flyte`.
"""
import os

from kubernetes.client import (
    V1PodSpec,
    V1Container,
    V1EnvVar,
    V1VolumeMount,
    V1EnvVarSource,
    V1ObjectFieldSelector,
    V1ConfigMapKeySelector,
    V1Volume,
    V1ProjectedVolumeSource,
    V1VolumeProjection,
    V1ServiceAccountTokenProjection,
    V1ConfigMapVolumeSource,
    V1KeyToPath,
)

import flyte
from flyte.extras import ContainerTask


_DEFAULT_CONFIGMAP_NAME = "build-image-config"
_STORAGE_YAML_KEY = "storage.yaml"
_CONFIG_DIR = "/etc/union/config"

config_map_name = os.getenv("CONFIG_MAP_NAME", _DEFAULT_CONFIGMAP_NAME)
log_level = os.getenv("LOG_LEVEL", "5")

union_image_name_prefix = os.getenv("UNION_IMAGE_NAME_PREFIX")
if not union_image_name_prefix:
    raise ValueError("UNION_IMAGE_NAME_PREFIX environment variable must be set")

app_version = os.getenv("APP_VERSION")
if not app_version:
    raise ValueError("APP_VERSION environment variable must be set")

build_image_task = ContainerTask(
    name="build-image",
    cache=flyte.Cache(behavior="auto"),
    image=f"{union_image_name_prefix}/build-image:{app_version}",
    inputs={"spec": str, "context": str, "target_image": str},
    outputs={"fully_qualified_image": str},
    pod_template=flyte.PodTemplate(
        primary_container_name="main",
        pod_spec=V1PodSpec(
            containers=[
                V1Container(
                    name="main",
                    image_pull_policy="Always",
                    termination_message_policy="FallbackToLogsOnError",
                    volume_mounts=[
                        V1VolumeMount(
                            mount_path="/var/run/secrets/union/registry",
                            name="registry-token",
                            read_only=True,
                        ),
                        V1VolumeMount(
                            name="config-volume",
                            mount_path=f"{_CONFIG_DIR}/{_STORAGE_YAML_KEY}",
                            sub_path=_STORAGE_YAML_KEY,
                        ),
                    ],
                    env=[
                        V1EnvVar(
                            name="ORGANIZATION",
                            value_from=V1EnvVarSource(
                                field_ref=V1ObjectFieldSelector(
                                    field_path="metadata.labels['organization']"
                                )
                            ),
                        ),
                        V1EnvVar(
                            name="UNION_BUILDKIT_URI",
                            value_from=V1EnvVarSource(
                                config_map_key_ref=V1ConfigMapKeySelector(
                                    name=config_map_name,
                                    key="buildkit-uri",
                                )
                            ),
                        ),
                        V1EnvVar(
                            name="UNION_DEFAULT_REPOSITORY",
                            value_from=V1EnvVarSource(
                                config_map_key_ref=V1ConfigMapKeySelector(
                                    name=config_map_name,
                                    key="default-repository",
                                )
                            ),
                        ),
                        V1EnvVar(
                            name="UNION_REGISTRY_AUTHENTICATION_TYPE",
                            value_from=V1EnvVarSource(
                                config_map_key_ref=V1ConfigMapKeySelector(
                                    name=config_map_name,
                                    key="authentication-type",
                                )
                            ),
                        ),
                        V1EnvVar(
                            name="UNION_IMAGE_NAME_PREFIX",
                            value=union_image_name_prefix,
                        ),
                        V1EnvVar(
                            name="FLYTE_INTERNAL_OPTIMIZE_IMAGE",
                            value_from=V1EnvVarSource(
                                config_map_key_ref=V1ConfigMapKeySelector(
                                    name=config_map_name,
                                    key="enable-image-optimization",
                                    optional=True,
                                )
                            ),
                        ),
                    ],
                ),
            ],
            volumes=[
                V1Volume(
                    name="registry-token",
                    projected=V1ProjectedVolumeSource(
                        sources=[
                            V1VolumeProjection(
                                service_account_token=V1ServiceAccountTokenProjection(
                                    audience="registry",
                                    expiration_seconds=7200,
                                    path="token",
                                )
                            )
                        ]
                    ),
                ),
                V1Volume(
                    name="config-volume",
                    config_map=V1ConfigMapVolumeSource(
                        name=config_map_name,
                        items=[
                            V1KeyToPath(
                                key=_STORAGE_YAML_KEY,
                                path=_STORAGE_YAML_KEY,
                            )
                        ],
                    ),
                ),
            ],
        ),
    ),
    command=[
        "imagebuild",
        "--logger.formatter.type=text",
        f"--logger.level={log_level}",
        "--context",
        "{{.inputs.context}}",
        "--frontend",
        f"{union_image_name_prefix}/frontend-v2:{app_version}",
        "--remote-outputs-prefix",
        "{{.outputPrefix}}",
        "--spec",
        "{{.inputs.spec}}",
        "--target-image",
        "{{.inputs.target_image}}",
        "--optimize",
    ],
)

build_image_task_env = flyte.TaskEnvironment.from_task(
    "build_image_task", build_image_task
)
