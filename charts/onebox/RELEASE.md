# onebox — Release Notes

## 2026.9.7

First release. Union in one pod: the v2 control plane, the in-process data
plane worker, the pod webhook and the console, against one Postgres database
and one object store, served on one port. Identity comes from headers set by
an authenticating proxy in front; role based authorization (embedded
userclouds-lite) is optional. Namespaced least-privilege RBAC (extend with
`rbac.extraRules` for plugin task types), optional NetworkPolicy and proxy
shared secret; `database.sslMode` defaults to `require`.
