# sandbox

![Version: 2025.3.1](https://img.shields.io/badge/Version-2025.3.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2025.2.0](https://img.shields.io/badge/AppVersion-2025.2.0-informational?style=flat-square)

Deploys extras for sandbox testing.

## Requirements

Kubernetes: `>= 1.28.0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| minio.accessKey | string | `"minio"` |  |
| minio.defaultBucket | string | `"union-dp-bucket"` |  |
| minio.enabled | bool | `false` |  |
| minio.image | string | `"quay.io/minio/minio:RELEASE.2025-01-20T14-49-07Z"` |  |
| minio.imagePullPolicy | string | `"IfNotPresent"` |  |
| minio.resources.limits.cpu | string | `"200m"` |  |
| minio.resources.limits.memory | string | `"512Mi"` |  |
| minio.resources.requests.cpu | string | `"10m"` |  |
| minio.resources.requests.memory | string | `"128Mi"` |  |
| minio.secretKey | string | `"miniostorage"` |  |
| minio.service.ports.console.nodePort | int | `30801` |  |
| minio.service.ports.minio.nodePort | int | `30800` |  |
| minio.service.type | string | `"ClusterIP"` |  |
| minio.volumeMounts[0].mountPath | string | `"/data"` |  |
| minio.volumeMounts[0].name | string | `"minio-storage"` |  |
| minio.volumes[0].emptyDir | object | `{}` |  |
| minio.volumes[0].name | string | `"minio-storage"` |  |
