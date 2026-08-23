# Union component RBAC

What Union's own components are allowed to do, where, and the one thing this chart
cannot do for you. For the observability subcharts — prometheus, kube-state-metrics,
opencost and the rest — see [rbac.md](rbac.md).

## Three independent axes

Three values keys are easy to confuse, because two of them used to be entangled. They
are independent, and each answers a different question.

| Key | Default | Question it answers |
|---|---|---|
| `low_privilege` | `true` | How wide is the grant? |
| `namespaces.enabled` / `namespaces.static` | `false` / a six-name list | Which work namespaces exist at install time? |
| `commonServiceAccount.enabled` | `true` | How many identities hold the grants? |

**`low_privilege` is the only privilege axis.** It alone decides whether a component's
grant is a namespaced `Role` or a `ClusterRole`. At the `true` default every Union
workload runs in the release namespace, no work namespaces are created by any route,
`namespaces` is not consulted at all, and `clusterresourcesync` is not rendered.

**`namespaces.enabled` pre-seeds namespaces; it does not change privilege.** It creates
the Namespace objects named in `namespaces.static` and, at `low_privilege: false`, their
work-namespace RoleBindings. It changes no role's rules and widens no role's scope — but
those bindings are what make the `work-ns` grant effective in each listed namespace, so it
does decide *where* that grant lands. It is ignored entirely under `low_privilege: true`.

**`commonServiceAccount.enabled` shares identity; it changes no rule.** The set of roles the
chart emits is the same either way; which workload can exercise which is not. See
[Identities](#identities).

Write these as unquoted YAML booleans. A quoted `"false"` is a non-empty string and reads
as true.

## Where grants apply: the six slots

Union's permissions are organized by *where they apply*, not by which component asked for
them. Each component declares its rules into one or more **slots**, and the chart emits
one role per slot from those declarations. Two destinations matter:

- the **components namespace** — the release namespace, holding Union's own Deployments,
  Secrets and ConfigMaps;
- the **work namespaces** — one per project/domain, holding user tasks, apps and image
  builds.

| Slot | Object | Bound by | Verbs | At `low_privilege: true` |
|---|---|---|---|---|
| `comp-ns-read` | `Role` | `RoleBinding`, release ns | allows `get,list,watch` | unchanged |
| `comp-ns-write` | `Role` | `RoleBinding`, release ns | allows `get,list,watch,create,update,patch,delete,deletecollection` | unchanged |
| `work-ns` | `ClusterRole` | `RoleBinding` per work namespace | allows `get,list,watch,create,update,patch,delete,deletecollection` | becomes a `Role` bound in the release namespace |
| `work-ns-cluster-read` | `ClusterRole` | `ClusterRoleBinding` | allows `get,list,watch` | **not emitted** |
| `cluster-read` | `ClusterRole` | `ClusterRoleBinding` | allows `get,list,watch` | unchanged |
| `cluster-write` | `ClusterRole` | `ClusterRoleBinding` | allows `get,list,watch,create,update,patch,delete,deletecollection` | unchanged |

The slots are not the chart's whole RBAC surface, and what sits outside them is outside for
four different reasons: the destination is a namespace the operator names rather than one the
emitter binds in (the proxy's Secret Role, the operator's secrets-watcher Role); the role is a
built-in with no rules of its own to carry (`system:auth-delegator`); the object is a hook
that outlives nothing (the pre-upgrade cleanup); or the verb has no slot (`use` on a named
SecurityContextConstraints, for imagebuilder and the Kourier gateway). Some of these do land
in the release namespace — being outside the model is not the same as being outside the
release namespace. The authoritative list is the header comment in `templates/_rbac.tpl`,
which also warns not to audit by grepping for `kind: Role`; read it before treating a slot
inventory as complete.

Role names are `<release-namespace>-<slot>` for the shared slots and
`<release-namespace>-<component>-<slot>` for the per-component ones. In the usual `union`
release namespace that reads as `union-work-ns`, `union-comp-ns-read`,
`union-operator-work-ns-cluster-read`, and so on. The `union-` prefix is the namespace,
not a brand: two releases in different namespaces get different role names, which is why
the cluster-scoped names are qualified at all.

**`work-ns` is a `ClusterRole` only so its rules are written once.** Every binding the
chart emits for it is a namespaced `RoleBinding`, and a `RoleBinding` that references a
`ClusterRole` confines that role's rules to the binding's own namespace. It grants nothing
in a namespace where no binding exists. Under `low_privilege: false` it is never bound in
the release namespace, so the `work-ns` role itself conveys nothing there — a component that
can create any Pod in a work namespace gets no reach over Union's own Deployments or Secrets
*through that role*.

That is a property of the binding, not of the identity. The same ServiceAccount may hold
release-namespace grants from other roles: at the default `proxy.secretManager` settings the
proxy's account holds `get,list,create,update,delete` on Secrets in the release namespace
(`operator/serviceaccount-proxy-secret.yaml`), and at the shared-identity default that
account is `union-system`. To reason about what an identity can do, enumerate every binding
naming it — not just the slots it declares into.

The two `cluster-*` slots survive `low_privilege: true`. What they carry is cluster-scoped
in both modes — `nodes`, for instance — so narrowing them is not possible and refusing to
render them would only move the failure to runtime. `nodeobserver` is the component this
is visible on: both slots it declares are cluster slots, so it holds `ClusterRoles` even
in the default posture.

`work-ns-cluster-read` is the exception that goes the other way. It exists for components
that watch objects with an empty namespace, which the API server authorizes as a
cluster-scope check that no number of per-namespace RoleBindings can satisfy. Under
`low_privilege` those caches are namespace-scoped instead and the pooled `work-ns` role
already covers them, so the slot emits nothing. Every one of these roles is `list`/`watch`
only, and that is enforced at render time rather than by convention: a slot whose name ends
in `-read` admits only `get`, `list` and `watch`, and the chart refuses to render if a rule
in one names a write verb.

### What a declaration tells you, and what it does not

Every rule in every slot names its own verbs. In a **per-component** slot the declaration
is exact: that component gets a role of its own, carrying those rules and no others.

In a **pooled** slot — `comp-ns-read`, `comp-ns-write` and `work-ns` — it is not: every
declarer is bound to the same role, so a resource that two components both name is granted
to the union of their verbs, not to each component's own list (see "Pooling", below, for
the same property stated at the level of whole rules). A component declaring
`secrets: [get]` alongside another declaring `secrets: [get, update, delete]` holds all
three verbs in every namespace the role is bound in.

So a declaration in a pooled slot states what that component **needs**. Only the rendered
role states what every declarer **gets**. When auditing, read the rendered
`<namespace>-work-ns` role, not the declarations that feed it.

This is the deliberate cost of pooling. The pooled role means one RoleBinding per work
namespace: a namespace created at runtime becomes reachable by every union component in a
single object, rather than in one object per component, any of which could fail
independently and leave the namespace half-reachable.

### Where a `secrets` rule belongs

A cluster slot is a `ClusterRole` plus a `ClusterRoleBinding`, so a `secrets` rule there
reads every Secret in every namespace on the cluster — tenant namespaces included, and the
broadest grant this chart can express. Declare one only when the component's read really is
a namespace-less `LIST` from an unscoped informer, which the API server authorizes at
cluster scope or not at all.

**A namespace being unknown at render time is not a reason to reach for a cluster slot.**
That is what `work-ns` is for: a `ClusterRole` bound per namespace, which authorizes an
ordinary namespaced `Get` in a namespace created long after Helm ran. The distinguishing
test is *how the read is made*, not *where*. `knative-controller`'s image-digest reads used
to sit in `cluster-read` for exactly the "unknown namespace" reason and are now in
`work-ns`, unchanged in what they reach.

Two components hold one and cannot be narrowed today:

| Component | Why | Goes away when |
|---|---|---|
| `webhook` | the pod webhook's controller-runtime Secret cache is scoped only when propeller's `limit-namespace` is set to something other than `all` — and the webhook reads the same config key propeller does, so scoping it would pin propeller's own cluster-wide informer. Scoping the cache also breaks the mirroring it exists for: the secret manager reads the mirrored Secret out of the admitted pod's own namespace through that cache | `config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled: false` drops it today, along with the mirroring |
| `knative-kourier` | net-kourier registers its Secret informer unconditionally in the shipped image, unfiltered by namespace | UN-39 gates it behind `KOURIER_ENABLE_INGRESS_TLS` |

### Pooling

A slot is **pooled** when its grant is conveyed by a `RoleBinding`, and per-component when
it is conveyed by a `ClusterRoleBinding`. A `RoleBinding` is confined to one namespace,
while a mistake in a `ClusterRoleBinding` reaches the whole cluster — which is why the
distinction between pooled and per-component still matters, even though it no longer
decides how verbs are checked: every rule in every slot names its own verbs, checked
against an allowlist that excludes wildcards, `escalate`, `impersonate` and `bind`, and
narrowed to `get`, `list` and `watch` for a slot whose name ends in `-read`.

**A pooled slot is one role bound to every ServiceAccount that declares into it.** The
consequence is worth stating plainly: the pooled role holds the *union* of every declaring
component's rules, so each declarer effectively holds every other declarer's rules in that
destination. Splitting identities does not split this. `leaseworker` and `flytepropeller`
each declare a resource wildcard into `work-ns`, so wherever either is enabled every other
`work-ns` declarer inherits it. At `low_privilege: false` that reach is confined **to work
namespaces**, because that is the only place the role is bound. At `low_privilege: true`
the release namespace *is* the work namespace, so it applies there — over Union's own
objects — which is the trade that mode makes.

## Who creates the work-namespace binding

Under `low_privilege: false`, something must create a `RoleBinding` named
`<release-ns>-work-ns` in each work namespace. There are three routes, and they are not
mutually exclusive:

- **this chart**, when `namespaces.enabled: true` and `namespaces.static` is non-empty —
  one RoleBinding per listed namespace, created at install;
- **`clusterresourcesync`**, when enabled — it creates each work namespace as a project is
  registered, and the chart hands it the RoleBinding as an entry in its
  clusterresource-template ConfigMap, keyed `ab_work_ns_binding.yaml` so it is applied
  immediately after the Namespace itself;
- **your own tooling**, if you provision work namespaces yourself.

`namespaces.static` is a *subset*, not the full set: projects registered after install get
their namespaces from `clusterresourcesync` regardless. So the chart emits the
provisioner's grant in **both** postures. Where both routes cover the same namespace they
produce the identical object.

Whatever creates the binding also needs `bind` on the `<release-ns>-work-ns` ClusterRole.
Kubernetes refuses to let a caller grant permissions it does not hold itself, so creating
the RoleBinding fails without it even when every other permission is in place. The chart
grants `clusterresourcesync` exactly that, pinned by `resourceNames` to the one role — so
it can hand out that role and no other, and never holds the role's own permissions.

### The `union-work-ns` ClusterRole can render present but unbound

**This is the most confusing consequence of the model, and on its own it is not a defect.**

At `low_privilege: false` with `namespaces.enabled: false` — the default full-privilege
posture — the `union-work-ns` ClusterRole renders with **no binding at all**. That is
expected *provided one of the runtime routes above is actually in play*: the per-namespace
RoleBindings are created as `clusterresourcesync` provisions each namespace, and a
`helm template` run cannot show an object that does not exist yet.

It is not expected when no route is. `clusterresourcesync.enabled` also defaults to `false`,
so `low_privilege: false` on its own — with `namespaces.enabled` left at `false` and no
external provisioner — renders exactly the same unbound ClusterRole and never binds it. That
render is indistinguishable from the healthy one, which is why the check below is on the
cluster and not on the manifest.

Three things follow.

**Nothing in a render can prove this worked.** The install renders green, a GitOps
controller reports healthy, and the first sign of trouble is a task execution failing with
`Forbidden`. So after registering a new project, confirm the binding landed:

```bash
kubectl get rolebinding <release-ns>-work-ns -n <work-namespace>

# The subjects are not always union-system — read them off the binding rather
# than assuming, since they differ under commonServiceAccount.enabled: false.
kubectl get rolebinding <release-ns>-work-ns -n <work-namespace> \
  -o jsonpath='{.subjects[*].name}'

kubectl auth can-i create pods -n <work-namespace> \
  --as=system:serviceaccount:<release-ns>:<one of those subjects>
```

If it is missing, check `clusterresourcesync`'s logs for errors applying
`ab_work_ns_binding.yaml`. If you provision namespaces yourself, the object you owe each
one is that RoleBinding, with `roleRef` pointing at the ClusterRole of the same name.

**Its subjects are not every Union identity.** The chart binds only the accounts that
declare into the `work-ns` slot, and which those are depends on what is enabled: under split
identities with apps off it is four, and zero-trust app serving takes it to seven. Never
compose the list by hand. Copy the subject list from a chart-rendered binding (`helm template --set
namespaces.enabled=true`, or the `ab_work_ns_binding.yaml` entry in `clusterresourcesync`'s
ConfigMap) rather than composing it yourself. Adding accounts that do not declare into the
slot hands them the pooled role's full write set in every work namespace — including
`clusterresourcesync`, which is deliberately given `bind` on this role precisely so it can
hand it out *without* holding it.

**A capability audit of this chart is only valid where every pooled slot is bound.** An
audit that walks bindings to work out what an identity can do will report the entire
contents of `union-work-ns` as lost if it runs against a render where that role is unbound
— which is exactly the default full-privilege render. That reads as a catastrophic
regression and is a measurement artifact. Audit against a posture with the bindings
present (`--set namespaces.enabled=true`, or a live cluster after the first sync), and key
capability tuples on `(serviceaccount, scope, apiGroup, resource, verb)` without
collapsing the scope column — a grant held in a *work* namespace does not substitute for
one missing in the *release* namespace.

## The cluster-scoped write surface

Most of what this chart grants is namespaced. The cluster-scoped, state-mutating grants
held by Union identities are these. Their conditions are compatible: a full-privilege
zero-trust install with `clusterresourcesync`, `nodeobserver` and an unmanaged pod-webhook
config renders all five at once, so treat the whole table as the maximum surface rather
than assuming some rows exclude others.

| ClusterRole | Rendered when | Grant |
|---|---|---|
| `flyte-webhook-cleanup-<release-ns>` | always (upgrade hook) | `get`/`delete` on one named `MutatingWebhookConfiguration` |
| `union-clusterresourcesync-cluster-write` | `low_privilege: false` + `clusterresourcesync.enabled` | get/create/update/patch on `namespaces`, `serviceaccounts`, `resourcequotas`, `rolebindings`; `bind` on `<release-ns>-work-ns` |
| `union-nodeobserver-cluster-write` | `nodeobserver.enabled` (either privilege mode) | `update` on `nodes` |
| `union-webhook-cluster-write` | `low_privilege: false` + `flytepropellerwebhook.managedConfig: false` | get/create/update/patch on `mutatingwebhookconfigurations` |
| `union-knative-webhook-cluster-write` | app serving under zero trust | `update` on three named webhook configurations, plus `namespaces/finalizers` on the release namespace |

`clusterresourcesync`'s is the irreducible one: it applies ServiceAccounts and
ResourceQuotas *into a namespace on the sync that creates it*, holding no RoleBinding
there yet, so those rules cannot be namespaced. Its `namespaces` rule gains `delete` only
under `clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace: true`.

**What that row still leaves, stated plainly.** Its `rolebindings` write is cluster-wide —
RBAC has no way to confine a namespaced write to a subset of namespaces — and
`<release-ns>-work-ns` is a resource-wildcard role. So a compromised `clusterresourcesync`
could plant a `<release-ns>-work-ns` RoleBinding in a namespace this release does not own,
giving Union's ServiceAccounts admin over it. **The `bind` pin caps what it can grant
directly, not where that grant leads:** `bind` is `resourceNames`-pinned to that one role, so
no stronger role can be substituted, and there is no `delete` on `namespaces` unless
`cleanupNamespace` is on — it cannot destroy a tenant namespace. But `<release-ns>-work-ns`
carries `pods: create`, and creating a pod in a namespace conveys the permissions of every
ServiceAccount already in it. Bound into a namespace that holds a stronger identity —
`kube-system` on a stock cluster — that is a route past the ceiling the pin appears to set.
Read the pin as closing the direct substitution only.

This is the accepted cost of provisioning namespaces at runtime, not an oversight. There is
one way to not pay it and one way to bound it. **To not pay it,** `clusterresourcesync` has to
be off, with namespace provisioning and project mapping handled by something you trust.
Pre-seeding with `namespaces.enabled: true` and `namespaces.static` is not enough on its own:
static namespaces are a pre-seeded *subset*, so projects registered after install are still
provisioned at runtime and both halves of the grant stay. **To bound it while keeping it,**
constrain the *shape* of what it may create with an admission policy (Kyverno,
OPA/Gatekeeper) restricting its RoleBinding and Namespace writes to your project-namespace
naming convention. Re-cutting the RBAC cannot express that constraint — only an admission
policy can.

That row is also the one you can extend. Anything set in
`clusterresourcesync.clusterRoleRules` — the escape hatch for resource types your own
`templates` or `additionalTemplates` entries create — is appended to that same ClusterRole,
cluster-wide, and the allowlist it passes through permits `create`, `update`, `patch`,
`delete` and `deletecollection`. It refuses a wildcard *verb* — but not a wildcard `apiGroups`
or `resources`, so `apiGroups: ["*"], resources: ["*"], verbs: [get]` renders. Audit that key
alongside this table.

Beyond this table and that key, every cluster-scoped grant held by a Union identity is
**read-only**,
with one apparent exception that is not one: `clusterresourcesync` is also bound to the
built-in `system:auth-delegator` ClusterRole, which conveys `create` on `tokenreviews` and
`subjectaccessreviews`. Those are read-only authorization checks that mutate no state.

Note that `low_privilege` is not a whole-chart namespace boundary in either direction: the
upgrade hook's ClusterRole is created in both modes, as are opencost's and metrics-server's
grants when those subcharts are enabled, and the `knative-operator` subchart — on by
default — ships a cluster-scoped set of its own. A namespace-confined install identity is
not enough to deploy this chart.

## Identities

At the `commonServiceAccount.enabled: true` default, one ServiceAccount —
`union-system` — is the subject of nearly every binding the chart emits. Since app
serving moved onto per-binary identities, that now includes the Knative control-plane
grants, on top of the operator, proxy, leaseworker, pod webhook, image builder and
dataproxy grants it already carried.

Net cluster capability is the same either way; what changes is **concentration**. Setting
`commonServiceAccount.enabled: false` de-concentrates it, giving each component its own
account:

| Component | Dedicated name |
|---|---|
| operator | `operator-system` |
| operator proxy | `proxy-system` |
| leaseworker | `leaseworker` |
| pod webhook | `union-webhook-system` |
| buildkit | `union-imagebuilder` |
| dataproxy | `dataproxy-system` (zero trust only) |
| Knative controller / webhook / autoscaler / activator | `knative-controller`, `knative-webhook`, `knative-autoscaler`, `knative-activator` (app serving under zero trust only) |
| Kourier controller | `net-kourier` (same) |

**Each new name needs a cloud-side workload-identity binding before those workloads can
authenticate** — an IRSA trust-policy subject on AWS, a `roles/iam.workloadIdentityUser`
member on GCP, or an Azure federated credential. Flipping the flag without doing that
first leaves the pods running and unable to reach cloud storage.

`nodeobserver`, `clusterresourcesync` and `flytepropeller` are unaffected by the flag —
they always hold dedicated accounts (`nodeobserver-system`, `union-clustersync-system`,
`flytepropeller-system`), in both settings.

**`fluentbit` is the documented exception.** Its account name comes from the subchart key
`fluentbit.serviceAccount.name`, which this chart pins to `union-system`. That pin wins
over the per-component fallback, so fluentbit keeps running as `union-system` unless you
also set that key to a dedicated name.

It *declares* no Kubernetes permissions — `fluentbit.rbac.create` is `false` and it calls no
Kubernetes API with this chart's config. But declaring none and holding none are different
things. **At the `commonServiceAccount.enabled: true` default it holds everything bound to
`union-system`, including the pooled `work-ns` role.** That matters more here than elsewhere,
because fluentbit is a DaemonSet on every node.

Splitting identities is what breaks that, not renaming: at `commonServiceAccount.enabled:
false` the slot bindings name the dedicated accounts, so the `union-system` ServiceAccount
fluentbit still gets — the pin keeps the name — is the subject of no binding at all and holds
nothing. If you want it isolated while keeping the shared account, set that key to a
dedicated name and provision the account yourself.

### Knative ServiceAccount naming

Two details surprise people reading a render:

- **`net-kourier` keeps its literal name** while its ClusterRole is
  `union-knative-kourier-cluster-read`. The role name follows the chart's slot convention;
  the account name is upstream's and is preserved deliberately.
- **The old shared `controller` account fans out to three accounts**, not one. It ran the
  controller, the webhook and both autoscalers. Under per-component identities those
  become `knative-controller`, `knative-webhook` and `knative-autoscaler` — so any
  external rule, policy or trust relationship keyed on `controller` must become three, or
  it silently stops matching the webhook and the autoscalers. `autoscaler-hpa` shares the
  autoscaler's account: it is the same reconciler under a different PodAutoscaler class.

## Two RBAC subtleties worth knowing

Both are counter-intuitive, and both have produced real defects in this chart.

**RBAC does not derive a subresource from its parent.** Granting `endpoints` does *not*
convey `endpoints/restricted`; the subresource must be named in its own right. On
OpenShift, where writing an Endpoints object naming a pod IP requires `create` on
`endpoints/restricted`, a rule that looks complete fails at runtime. The same applies to
every `<resource>/status` and `<resource>/finalizers`.

**`resourceNames` applies across the cartesian product of a rule's resources.** A single
rule naming two resource kinds and three names claims all six kind/name pairs, not three.
So a rule like

```yaml
- apiGroups: [admissionregistration.k8s.io]
  resources: [mutatingwebhookconfigurations, validatingwebhookconfigurations]
  resourceNames: [a, b, c]
```

claims more than it appears to. Split it into one rule per resource when the names differ
by kind. No Union-authored rule in this chart combines `resourceNames` with more than one
resource; you can check that property of any render with one pass over its `Role` and
`ClusterRole` documents.

## One failure that does not look like RBAC

If task pods fail with `ImagePullBackOff` or `ErrImagePull` on images from a private
registry, suspect a missing work-namespace binding before suspecting the registry.

The pod webhook mirrors image-pull secrets into each work namespace. If it cannot, the
`Forbidden` is swallowed — the pod is admitted without its secret, and the failure surfaces
at image pull with nothing in the pod's events pointing at RBAC. The only trace is in the
webhook's own log:

```bash
kubectl logs -n <release-ns> deploy/union-pod-webhook
```

Selecting a posture is not the same as that posture working. All of these render green and
still produce this failure: `clusterresourcesync` enabled but crash-looping or not yet past
its first sync; your own tooling broken or lagging; `namespaces.static` not containing the
namespace the task actually landed in. Confirm the binding exists in the affected namespace
before looking anywhere else.
