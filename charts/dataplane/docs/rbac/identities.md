# Identities

At the `commonServiceAccount.enabled: true` default, one ServiceAccount, `union-system`, is
the subject of nearly every binding the chart emits. Those bindings include the operator,
proxy, leaseworker, pod webhook, image builder and dataproxy grants, and the Knative
control-plane grants as well.

Net cluster capability is the same either way, and the difference is concentration, meaning
how many grants one account holds. Setting `commonServiceAccount.enabled: false` gives each
component its own account:

| Component | Dedicated name |
|---|---|
| operator | `operator-system` |
| operator proxy | `proxy-system` |
| leaseworker | `leaseworker` |
| pod webhook | `union-webhook-system` |
| buildkit | `union-imagebuilder` |
| flyteconnector | `flyteconnector` |
| dataproxy | `dataproxy-system` (zero trust only) |
| Knative controller / webhook / autoscaler / activator | `knative-controller`, `knative-webhook`, `knative-autoscaler`, `knative-activator` (app serving under zero trust only) |
| Kourier controller | `net-kourier` (same) |

Each new name needs a cloud-side workload-identity binding before those workloads can
authenticate. That is an IRSA trust-policy subject on AWS, a
`roles/iam.workloadIdentityUser` member on GCP, or an Azure federated credential. If you set
the flag first, the pods keep running but cannot reach cloud storage.

`nodeobserver`, `clusterresourcesync`, `flytepropeller` and `node-bootstrap` ignore the
flag and always hold dedicated accounts. Those are `nodeobserver-system`,
`union-clustersync-system`, `flytepropeller-system` and `union-node-bootstrap` respectively.

**`fluentbit`** is the exception. Its account name comes from the subchart key
`fluentbit.serviceAccount.name`, which this chart pins to `union-system`. That pin wins over
the per-component fallback, so fluentbit runs as `union-system` unless you also set that key
to a dedicated name.

It declares no Kubernetes permissions, because `fluentbit.rbac.create` is `false` and it
calls no Kubernetes API with this chart's config. It can still hold permissions through its
account. At the `commonServiceAccount.enabled: true` default it holds everything bound to
`union-system`, including the pooled `work-ns` role. That matters more here than elsewhere,
because fluentbit is a DaemonSet on every node.

Splitting identities removes those grants, and renaming does not. At
`commonServiceAccount.enabled: false` the slot bindings name the dedicated accounts, so
the `union-system` account fluentbit still gets is the subject of no binding and holds no
grants. To isolate fluentbit while keeping the shared account, set that key to a dedicated
name and provision the account yourself.

## Knative ServiceAccount naming

Two naming details are easy to misread in a render:

- **`net-kourier`** keeps its literal name, while its ClusterRole is
  `union-knative-kourier-cluster-read`. The role name follows the chart's slot convention,
  and the account name is upstream's, preserved on purpose.
- **The `controller` account** was shared before per-component identities, and ran the
  controller, the webhook and both autoscalers. Under per-component identities it becomes
  `knative-controller`, `knative-webhook` and `knative-autoscaler`.
  - Any external rule, policy or trust relationship keyed on `controller` must become three,
    or it stops matching the webhook and the autoscalers.
  - `autoscaler-hpa` shares the autoscaler's account, because it is the same reconciler
    under a different PodAutoscaler class.
