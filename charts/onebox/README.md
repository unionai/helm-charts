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
every node, for an endpoint at a node's address. The SDK uploads code and
image build contexts there too, so `flyte run` and `flyte serve` from your
machine need that set as well.

Add apps, remote image builds and metrics, with nothing else to install (see
[Apps](#apps), [Image builder](#image-builder) and [Metrics](#metrics)):

```shell
helm install onebox unionai/onebox -n union --create-namespace \
  --set bundled.enabled=true \
  --set bundled.s3.endpoint=<address browsers and the cluster resolve to the store> \
  --set imageBuilder.enabled=true --set imageBuilder.bundled.enabled=true \
  --set serving.enabled=true \
  --set serving.publicURLPattern='http://%s.apps.127-0-0-1.nip.io:8080' \
  --set serving.gateway.auth.enabled=false \
  --set prometheus.enabled=true
kubectl -n union port-forward svc/onebox 8080:80
```

Apps then answer at `http://<app>.apps.127-0-0-1.nip.io:8080` through the
port-forward.

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

### License key

onebox always enforces its license: without a valid key it is read-only. Reads
work, changes are refused, and runs in flight finish. Account admins add keys in
the console, or mount one from a Secret:

```bash
kubectl -n onebox create secret generic onebox-license --from-literal=license-key=<key>
helm upgrade --install onebox ... --set license.existingSecret=onebox-license
```

The console shows the install ID a key is issued for and links to `issueURL`
with it: by default Union's sign-up, which lands people on their organization's
License Keys page for this install. A rotated key in the Secret is picked up
without a restart. Keys are verified offline against Union's issuer keys, built
into each onebox release.

### A private CA, extra mounts and proxies

`caBundle` names a ConfigMap (or Secret) key holding a PEM bundle that onebox,
the console and every task pod trust: for an S3 endpoint, database, identity
provider or registry signed by a private CA. It replaces the system trust store
(`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `AWS_CA_BUNDLE`, `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH`,
`PIP_CERT`, `CURL_CA_BUNDLE`; the console adds it with `NODE_EXTRA_CA_CERTS`), so
include the public roots if anything is reached over the internet:

```bash
cat /etc/ssl/certs/ca-certificates.crt corp-ca.pem > ca-bundle.pem
kubectl -n onebox create configmap ca-bundle --from-file=ca-bundle.pem
helm upgrade --install onebox ... --set caBundle.configMap=ca-bundle
```

`extraVolumes`/`extraVolumeMounts` add volumes to the onebox container. Task
pods get theirs from `taskPods.extraVolumes`/`extraVolumeMounts`/`extraEnv` (an
outbound proxy's `HTTPS_PROXY`/`NO_PROXY`, a shared dataset): the chart renders
a PodTemplate every task pod starts from (`plugins.k8s.default-pod-template-name`)
whenever any of these, or `caBundle`, is set. A task's own `pod_template` still
applies on top.

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
  defaultRole: viewer               # admin, contributor, viewer or none
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

With `nodeAgent.startupTaint.enabled`, worker nodes are tainted as they
register, as on a Union data plane, until the node agent on them is serving, so
no task lands on a node whose Volumes broker isn't up yet. The node agent's
readiness component removes the taint; it then gets an API token allowed to get
and update nodes. `nodeAgent.startupTaint.nodeLabels` picks the nodes (default
`flyte.org/node-role: worker`). The node webhook fails closed, like a data
plane's: while onebox is down, matching nodes cannot register.

## Not included (yet)

- Artifacts.
- More than one replica, or more than one data plane cluster.

## Metrics

The console's Metrics tab reads task CPU and memory (and GPU) series from a
Prometheus that scrapes cAdvisor and kube-state-metrics (and dcgm-exporter
for GPUs). Set `metrics.prometheusURL` to yours, or set `prometheus.enabled`
and the chart runs the prometheus-community/prometheus chart (server and
kube-state-metrics only; any of its values go under `prometheus`) and points
`metrics.prometheusURL` at it. It keeps `prometheus.server.retention` (3d) on
an emptyDir, so a restart loses history.

## Image builder

`imageBuilder.enabled` builds images remotely (`flyte run --builder remote`,
or images the SDK can't build locally) with a build-image task onebox
registers in the system project. It needs a BuildKit daemon and a registry
nodes can pull from: set `imageBuilder.buildkitURI`, `repository` and
`lookupURL`, or, on a single-user or evaluation cluster, turn on
`imageBuilder.bundled.enabled` and the chart runs both in the release
namespace and fills those in:

- BuildKit, privileged and on the node's network (to push to the registry at
  `localhost`), listening without TLS on `imageBuilder.bundled.buildkit.hostPort`.
- A registry on NodePort `imageBuilder.bundled.registry.nodePort` (30000),
  taking anonymous pushes. BuildKit pushes to and nodes pull from
  `localhost:30000/onebox`, which containerd and BuildKit allow over plain HTTP.
  Images are on an emptyDir unless `imageBuilder.bundled.registry.storage` is
  set.

Anything that reaches them can run builds as root on a node or overwrite
images, so don't use the bundled pair on a shared cluster.

## Ports

| Port | Who calls it |
|---|---|
| 80 → 8080 | Everyone: console, API, REST. Behind the proxy. |
| 8082 | Task pods; requests act as the built-in tasks app. In-cluster only. |
| 9443 | The Kubernetes API server (pod webhook). |
| 15606 | Reusable-container workers. In-cluster only. |
| 8083 | With `serving.enabled`: the apps gateway's union-apps filter (`/me`, authorization). Only the gateway. |

## Apps

With `serving.enabled`, the chart runs everything apps need in the release
namespace: Knative Serving 1.23 (controller, activator, autoscaler, webhook;
the same Knative a Union data plane runs, vendored from the dataplane chart)
and Union's Kourier controller and Envoy gateway. onebox forwards every app
host (`serving.publicURLPattern`) to the gateway. Knative is configured for
Kourier, the pod-spec features Union apps use, and the image builder's
registry (tag resolution skipped). Override any of its `config-*` data under
`serving.knative.config`, and its components (replicas, images, resources,
scheduling) under `serving.knative.components`; by default each runs one
replica with small requests.

Knative's CRDs are in the chart's `crds/`, so Helm installs them (once, even
with serving off; it never upgrades them). `helm install --skip-crds` leaves
them out: apply them yourself from the chart with
`helm pull unionai/onebox --untar && kubectl apply --server-side -f onebox/crds/`.
Knative is cluster-wide (fixed-name ClusterRoles and admission webhooks), so a
cluster runs one. If it already has Knative Serving, set
`serving.knative.install=false`: the chart then adds `config-kourier` to
Knative's namespace (`serving.knativeNamespace`), and you set the
`serving.knative.config` values on Knative's own ConfigMaps
(`config-network`'s `ingress-class`, `config-features`,
`config-deployment`'s `registries-skipping-tag-resolving`).

With `serving.gateway.auth.enabled` (the default), the gateway's union-apps
filter decides who may call each app, asking onebox's gateway port (8083): it
needs `serving.gateway.auth.signInURL` (the proxy's sign-in) and
`authMetadata.externalAuthServerBaseUrl`. onebox's `/me` there returns the
claims of the token in the caller's `Authorization` header without checking
it, so the proxy in front must authenticate app hosts and pass the user's
token on (oauth2-proxy: `--pass-authorization-header`). Apps that allow
anonymous callers need their hosts to bypass the proxy.

With networkPolicy on, only the gateway reaches port 8083, and only onebox and
Kourier's controller reach the gateway's external listener.

## Under a path of a shared host

`basePath` serves onebox under a path of a host something else owns, e.g.
`basePath: /onebox` for `https://platform.example.com/onebox/`: the console at
`/onebox/v2`, the API, `/login` and `/logout` under `/onebox`. The proxy in
front forwards `/onebox/` to the Service **with the path unchanged** (nginx: no
URI on `proxy_pass`), keeps `Host`, sets `X-Forwarded-Proto`, passes WebSocket
upgrades and doesn't buffer responses. Point the SDK and CLI at
`https://platform.example.com/onebox`.

```yaml
basePath: /onebox
serving:
  enabled: true
  publicURLPattern: https://platform.example.com/onebox/apps/%s/
```

Apps can share the host too, each under its own path, with a path-based
`serving.publicURLPattern`. The path must be `<basePath>/apps/%s/`, as above:
everything else under `basePath` is onebox's own (the console, its REST
routes), and onebox refuses to start with apps anywhere they would shadow it.
Requests reach an app with its path intact, and the app finds the path in
`_U_APP_BASE_PATH`: the SDK's FastAPI and Streamlit apps serve under it on
their own; pass it to other servers (Jupyter's `base_url`). For servers that
only serve at `/`, `serving.stripAppPathPrefix: true` removes the path and
sends it as `X-Forwarded-Prefix`.

Path-based apps on the console's host share its origin with the console and
everything else on the host. An app's script can make requests as the user who
opens it, so use them only for apps whose authors you trust as much as the
platform. To keep apps apart without wildcard DNS, give them a host of their
own and set `serving.appHostOnly`:

```yaml
serving:
  publicURLPattern: https://apps.example.com/onebox/apps/%s/
  appHostOnly: true
```

That host then serves apps and nothing else, and the console's host serves no
apps. Point it at the same proxy as onebox. Host-based app URLs keep apps
isolated too. In every mode onebox keeps the user's session cookie, the
proxy's tokens and its shared secret from apps, the apps gateway removes the
caller's bearer token once it has authorized them, and an app cannot set the
session cookie.

Each `basePath` segment must be a lowercase DNS label. It needs onebox and
onebox-console images with base path support.

## License

The onebox chart and the software it deploys are under the Union License: see
[`LICENSE`](LICENSE), with Union's copyright notice in [`NOTICE`](NOTICE). The third-party
notices ship in the onebox image, at `/usr/share/doc/onebox/`.
