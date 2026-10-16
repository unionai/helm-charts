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
plugin objects they create all live in the release namespace. onebox itself
needs no permissions outside it: the chart installs the pod webhook's
MutatingWebhookConfiguration (which only selects pods in that namespace) and
its serving cert, so `helm uninstall` removes them too. What onebox creates
while running (task pods, apps, secrets) stays until you delete the namespace.
GitOps tools that render without cluster access should set
`webhook.certificate.provider=external`, or the cert changes on every sync.

### Trying it out: bundled database and bucket

`bundled.enabled=true` runs Postgres and an S3-compatible store
(floci) in the release namespace, each on
a PersistentVolumeClaim from the default StorageClass, and points `database`
and `storage` at them:

```shell
helm install onebox unionai/onebox -n union --create-namespace --set bundled.enabled=true
```

It's meant for a proof of value: nothing is backed up or highly available,
and moving such an install to an external database and bucket keeps none of
its data. The claims survive `helm uninstall`. The bucket's address is the
in-cluster Service unless you set `bundled.s3.endpoint`, so downloading
outputs and viewing reports in the console needs that set to an address
browsers can reach too. `bundled.s3.nodePort` also exposes the store on
every node, for an endpoint at a node's address.

### Storage

| `storage.type` | Credentials |
|---|---|
| `s3` | IRSA / pod identity (`serviceAccount.annotations`), or `authType: accesskey` with `existingSecret` holding `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. S3-compatible stores (MinIO, R2, Ceph) set `endpoint`. |
| `gcs` | Workload identity (`serviceAccount.annotations`); `gcpProjectId`. |
| `azure` | Workload identity; `azureAccount`. |

Task pods run in the release namespace as its `default` service account
(unless a task asks for another one). Give that service account the same
bucket access, e.g. annotate it with the same IRSA role or GCP service
account.

## Who is calling: identity headers

onebox does not authenticate anyone. Put an authenticating proxy in front of
the Service (oauth2-proxy, an OIDC-aware ingress controller, an AWS ALB,
Cloudflare Access, ...) and have it forward who the user is in headers:

| Value | Headers (first non-empty wins) |
|---|---|
| `identity.subjectHeaders` | `X-Forwarded-User` |
| `identity.emailHeaders` | `X-Forwarded-Email` |
| `identity.nameHeaders` | `X-Forwarded-Preferred-Username` |
| `identity.groupsHeaders` | `X-Forwarded-Groups` |
| `identity.claimsJWTHeaders` | none by default; e.g. `X-Amzn-Oidc-Data`, `Cf-Access-Jwt-Assertion` |

There is nothing to switch on: a request with these headers is that user; a
request without them is `anonymous`. onebox drops any identity header a client
sets itself, but it trusts these. **Only expose the Service through the
proxy.**

List exactly the headers your proxy sets on every request. A proxy overwrites
only those; any other listed header passes through from the client, who can
then claim to be anyone. The defaults match oauth2-proxy in reverse-proxy mode
(`--pass-user-headers`).

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

With oauth2-proxy, run it with `--pass-user-headers`, upstream
`http://onebox.<namespace>.svc`, and set
`identity.logoutRedirect=/oauth2/sign_out`.

### SDK and CLI login

When the proxy requires a login, the SDK and CLI need a token from your IdP.
Set `authMetadata.externalAuthServerBaseUrl` (and `authMetadata.flyteClient`,
a public PKCE client registered at the IdP): onebox then serves the IdP's
OAuth2 metadata at `/.well-known/oauth-authorization-server` and
`flyteidl2.auth.AuthMetadataService`. Let the proxy pass those two paths
without a login, and have it accept the IdP's bearer tokens (oauth2-proxy:
`--skip-jwt-bearer-tokens` and `--extra-jwt-issuers=<issuer>=<client id>`;
ALB: a JWT-validation rule). The SDK only sends tokens over TLS. If the proxy
terminates TLS itself and sends no `X-Forwarded-Proto`, set
`publicScheme=https`.

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

## Volumes: the node agent

Volumes mount through the uvol mount broker, a CSI node driver, so the chart
runs one DaemonSet beside onebox: `<fullname>-node-agent`, the onebox image
running `onebox nodeagent run` with only the broker on. It is the dataplane's
union-node-agent without node readiness or the GPU fault watcher, and no other
node DaemonSets come with it. Tasks opt in with flyteplugins-union's
`allow_volumes()` pod template.

The agent pod is privileged (it opens `/dev/fuse` and premounts into kubelet's
directory) and gets no API token. It must run on every node a volume-using task
can land on; by default it tolerates every taint. Block Volumes are allowed in
the release namespace (`nodeAgent.block.allow`). Turn it off with
`nodeAgent.enabled=false`, and do not install it on a cluster that already
runs a dataplane broker: both register the `volumes.union.ai` CSI driver.

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
