# onebox — Release Notes

## 2026.10.5

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
