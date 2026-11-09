# onebox — Release Notes

## 2026.11.4

`version` moves `2026.11.3` → `2026.11.4` and `appVersion` moves `2026.11.2` →
`2026.11.4`, picking up the new images. No onebox template or values changes;
lockstep release with the `controlplane` / `dataplane` charts.

## 2026.11.3

`version` moves `2026.11.2` → `2026.11.3`; `appVersion` stays `2026.11.2`.

### License, private CA, app isolation and image builder from GHCR (#669)

- `license`: a license key from a Secret (`existingSecret`), `enforce` to make
  an install without a valid key read-only, `issueURL` where users get one, and
  `trustedKeys` for a self-hosted issuer. Rendered only when set, and needs an
  onebox image with licensing.
- `caBundle`: a private CA bundle trusted by onebox, the console and every task
  pod (S3, database, identity provider, registry).
- `extraVolumes`/`extraVolumeMounts` for the onebox container, and
  `taskPods.extraEnv`/`extraVolumes`/`extraVolumeMounts` for task pods, through
  a PodTemplate every task pod starts from.
- `serving.appHostOnly`: path-based apps on a host of their own, which serves
  only apps, so app scripts run on a different origin from the console.
- The apps gateway removes the caller's bearer token once it has authorized
  them (`UNION_AUTH_STRIPCALLERCREDENTIALS`), so apps never receive it.
- The image builder's task images default to `ghcr.io/unionai/imagebuilder`
  at the chart's appVersion (`imageBuilder.taskImages.tag` defaults to it)
  instead of a pinned canary build on public ECR, whose anonymous pulls are
  rate limited.

The license values, `serving.appHostOnly` and the gateway's token removal need
onebox images from a release with unionai/cloud#19283 and #19820, newer than
2026.11.2.

## 2026.11.2

`version` and `appVersion` move `2026.11.1` → `2026.11.2`.

### Serve under a path of a shared host (#664)

`basePath` serves onebox under a path of a host something else owns, e.g.
`basePath: /onebox` for `https://platform.example.com/onebox/`. The console runs at
`/onebox/v2`; the API, `/login` and `/logout` sit under `/onebox`. The value is passed
to the console as `UNION_BASE_PATH` and validated as lowercase DNS-label segments; an
invalid value (`/One`) fails the render.

Apps can share the host with a path-based `serving.publicURLPattern`
(`https://platform.example.com/onebox/apps/%s/`); `serving.stripAppPathPrefix` removes
the app's path for servers that only serve at `/`. NOTES show the prefixed console and
SDK endpoint, and the README covers the proxy contract (forward `/onebox/` with the
path unchanged, WebSockets, no buffering) and the shared-origin caveat for path-based
apps. Without `basePath`, rendering is unchanged.

Requires onebox and onebox-console images that include unionai/cloud#19740 and
unionai/cloud#19741, and flyte-sdk with flyteorg/flyte-sdk#1739.

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
