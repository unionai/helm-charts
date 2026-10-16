# onebox — Release Notes

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
`require`.
