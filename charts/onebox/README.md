# onebox

Union in one pod. One Deployment runs:

- **onebox**: the v2 control plane (runs, actions, leasor, dataproxy, cluster,
  identity, authorizer, projects), the data plane worker that launches task
  pods, the pod mutating webhook (secret injection), and, with authorization
  on, an embedded userclouds-lite.
- **console**: the web UI, served by onebox under `/v2`.

Everything is on **one port**: the console, the Connect/gRPC API and the REST
routes. There is no ingress, no Envoy, no Redis and no ScyllaDB to install.
You bring a **Postgres** database and an **object store** bucket.

## Install

```shell
kubectl create namespace union
kubectl -n union create secret generic onebox-db --from-literal=password='<db password>'

helm repo add unionai https://unionai.github.io/helm-charts
helm install onebox unionai/onebox -n union \
  --set database.host=<postgres host> \
  --set database.user=<user> --set database.name=<database> \
  --set database.existingSecret=onebox-db \
  --set storage.type=s3 --set storage.bucket=<bucket> --set storage.region=<region>
```

Then:

```shell
kubectl -n union port-forward svc/onebox 8080:80
open http://localhost:8080/v2
```

Point the SDK at the same address (`dns:///localhost:8080`, insecure) or at
whatever you expose the Service through.

Install onebox in a namespace of its own: task pods, their secrets and the
plugin objects they create all live in the release namespace. It needs
nothing outside it, apart from creating its own MutatingWebhookConfiguration,
which only selects pods in that namespace.

### Storage

| `storage.type` | Credentials |
|---|---|
| `s3` | IRSA / pod identity (`serviceAccount.annotations`), or `authType: accesskey` with `existingSecret` holding `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. S3-compatible stores (MinIO, R2, Ceph) set `endpoint`. |
| `gcs` | Workload identity (`serviceAccount.annotations`); `gcpProjectId`. |
| `azure` | Workload identity; `azureAccount`. |

Task pods run as `tasks.serviceAccountName` (default `default`); give it the
same bucket access.

## Who is calling: identity headers

onebox does not authenticate anyone. Put an authenticating proxy in front of
the Service (oauth2-proxy, an OIDC-aware ingress controller, an AWS ALB,
Cloudflare Access, ...) and have it forward who the user is in headers:

| Value | Headers (first non-empty wins) |
|---|---|
| `identity.subjectHeaders` | `X-Auth-Request-User`, `X-Forwarded-User` |
| `identity.emailHeaders` | `X-Auth-Request-Email`, `X-Forwarded-Email` |
| `identity.nameHeaders` | `X-Auth-Request-Preferred-Username`, `X-Forwarded-Preferred-Username` |
| `identity.groupsHeaders` | `X-Auth-Request-Groups`, `X-Forwarded-Groups` |
| `identity.claimsJWTHeaders` | none by default; e.g. `X-Amzn-Oidc-Data`, `Cf-Access-Jwt-Assertion` |

There is nothing to switch on: a request with these headers is that user; a
request without them is `anonymous`. onebox drops any identity header a client
sets itself, but it trusts these. **Only expose the Service through the
proxy.**

Make the trust explicit:

- **Shared secret** (recommended): have the proxy add a static header, set
  `identity.proxySecret.existingSecret` (key `secret`, header
  `X-Onebox-Proxy-Secret` by default). Identity headers on requests without
  it are ignored.
- **NetworkPolicy** (on by default with authz; needs an enforcing CNI): set
  `networkPolicy.proxyFrom` to the proxy's pods/namespace and the API port
  only accepts the proxy; task pods keep the tasks and fast task ports.
- `identity.claimsJWTHeaders` are decoded, not verified. Use them only
  together with one of the above.

The in-cluster tasks port (8082) never trusts proxy headers: every request
there acts as onebox's built-in tasks app (see Authorization).

With oauth2-proxy, run it with `--set-xauthrequest` and
`--pass-user-headers`, upstream `http://onebox.<namespace>.svc`, and set
`identity.logoutRedirect=/oauth2/sign_out`.

### User profiles

With `profiles.enabled` (the default), onebox remembers the name and email the
proxy reports for each user and shows them wherever users appear: run
attribution, the members page, user pickers.

## Authorization

Off by default: every request is allowed.

```yaml
authz:
  enabled: true
  adminUsers: [alice@example.com]   # subjects as the proxy reports them
  defaultRole: viewer               # admin, contributor or viewer
```

On:

- requests without identity headers are refused;
- users get `defaultRole` the first time they are seen; `adminUsers` are admins;
- task pods call onebox on the in-cluster tasks port (8082), where every
  request acts as a built-in app with role `authz.tasksRole` (contributor), so
  tasks can launch and track child actions without credentials in the pod.
  Anything that can reach that port gets that role. The chart turns on a
  NetworkPolicy that limits it to pods in the release namespace; with a CNI
  that does not enforce NetworkPolicy, any pod in the cluster can reach it.
  If tasks run in other namespaces too, add them with
  `networkPolicy.tasksFrom` (e.g. a `namespaceSelector` on a label you put on
  those namespaces).

## GitOps (ArgoCD)

The chart generates internal credentials once and keeps them with `lookup`.
Tools that render without cluster access regenerate them on every sync, which
rolls the pod each time. Create the Secret yourself:

```shell
kubectl -n union create secret generic onebox-internal \
  --from-literal=userclouds-client-secret="$(openssl rand -hex 32)"
```

and set `internalSecret.existingSecret=onebox-internal`.

## Not included (yet)

- Apps / serving (needs Knative), image builder (needs BuildKit), artifacts.
- More than one replica, or more than one data plane cluster.

## Ports

| Port | Who calls it |
|---|---|
| 80 → 8080 | Everyone: console, API, REST. Behind the proxy. |
| 8082 | Task pods; requests act as the built-in tasks app. In-cluster only. |
| 9443 | The Kubernetes API server (pod webhook). |
| 15606 | Reusable-container workers. In-cluster only. |
