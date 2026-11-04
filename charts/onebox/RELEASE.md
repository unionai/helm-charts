# onebox — Release Notes

## Unreleased

- `caBundle`: a private CA bundle trusted by onebox, the console and every task
  pod (S3, database, identity provider, registry).
- `extraVolumes`/`extraVolumeMounts` for the onebox container, and
  `taskPods.extraEnv`/`extraVolumes`/`extraVolumeMounts` for task pods, through
  a PodTemplate every task pod starts from.

## 2026.11.1

`version` and `appVersion` move to `2026.11.1`. The chart can now run everything
the install guide set up by hand:

- **Apps** (`serving.knative.install`, on with `serving.enabled`): Knative Serving
  1.23, the same version the dataplane's zero-trust gateway runs, in the release
  namespace. Its CRDs are in `crds/` (`crds/onebox/scripts/sync.sh` copies them
  from the dataplane chart; `--skip-crds` installs apply them from
  `crds/dataplane/`).
- **Image builder** (`imageBuilder.bundled.enabled`): an in-cluster registry
  (NodePort 30000) and BuildKit, with `imageBuilder.buildkitURI`, `repository`
  and `lookupURL` filled in where not set. `lookupURL` points at the bundled
  registry only when `repository` is the bundled one.
- **Metrics** (`prometheus.enabled`): a bundled Prometheus (prometheus-community
  `prometheus` 25.30.2, with kube-state-metrics), with `metrics.prometheusURL`
  filled in from its Service, `forceNamespace` included.

## 2026.11.0

`version` and `appVersion` move to `2026.10.5`. The onebox image now sets
`controlPlane.deploymentType: onebox` in its built-in defaults, and applies the console
dashboards' `actions (org, created_at)` index as part of that type's migrations
(unionai/cloud#19713). Existing onebox databases already have the index; the upgrade
records it under a new version as a no-op.

## 2026.9.7

First release. Union in one pod: the v2 control plane, the in-process data
plane worker, the pod webhook and the console, against one Postgres database
and one object store, served on one port. Identity comes from headers set by
an authenticating proxy in front; role based authorization (embedded
userclouds-lite) is optional. Task pods call back on an in-cluster
port where they act as a built-in app (`authz.tasksRole`); no credentials are
injected into them. Namespaced least-privilege RBAC (extend with
`rbac.extraRules` for plugin task types), a NetworkPolicy that is on whenever
authz is, and an optional proxy shared secret; `database.sslMode` defaults to
`require`. The chart and the software it deploys are under the Union License
(`LICENSE`, with Union's copyright in `NOTICE`).
