# Change taxonomy

Eight classes. Every substantive change in a release diff belongs to one. The class
determines where it lands in the generated skill and how loudly it is stated.

Each class below gives: what it is, why it is dangerous, how to detect it, and a real
release where it landed. The examples are drawn from shipped `dataplane` releases and are
safe to reference in output — they are all visible in this public repository.

---

## Class 1 — Silent default flip

**What** A key the customer never set changes its default value.

**Why it hurts** Nothing errors. `helm upgrade` succeeds, every pod goes Running, and
behavior changes underneath. This is the single most common cause of "the upgrade worked
but something is different now."

**Detect**
```bash
git diff $FROM $TO -- charts/dataplane/values.yaml 'charts/dataplane/values.*.yaml' \
  | grep -E '^[+-]\s+[a-zA-Z_.-]+:\s+\S'
```
Look for a key path that exists on both sides with a different scalar. Check the per-cloud
overlays too — a base default can flip while an overlay already pinned the other value, so
the effective change differs by cloud.

**Real examples**
| Release | Key | Old | New |
|---|---|---|---|
| 2026.6.9 | `config.authorizer.type` | `noop` | `Authorizer` |
| 2026.7.0 | `operator.config.billing.model` | `Shadow` | `ResourceUsage` |
| 2026.8.0 | `storage.enableMultiContainer` | `false` | `true` |

The authorizer flip is the archetype: three words of diff, and the dataplane goes from
performing no authorization to enforcing it against the control plane. A cluster whose
control-plane identity is not configured for it fails closed on first request.

**In output** Always a table with four columns: key, old default, new default, what to set
to preserve today's behavior. Never bury this in prose.

---

## Class 2 — Key removed or renamed

**What** A values key stops being read. Either deleted outright or replaced by a
differently-named one.

**Why it hurts** Helm does not validate values against a schema. An unknown key is
accepted and ignored. The customer's carefully-written config becomes decoration, and
they find out weeks later when they notice a feature was never working.

**Detect** Extract top-level and nested key paths from both versions and set-difference
them. Then confirm the old path has no remaining reader:
```bash
git grep -n 'Values\.executor' $TO -- charts/dataplane/templates | head
```
No hits means genuinely inert. Hits mean it is Class 3 (still honored) instead.

**Real examples**
| Release | Removed / renamed | Notes |
|---|---|---|
| 2026.8.0 | `executor:` → `leaseworker:` | whole block renamed; the old block is inert |
| 2026.8.0 | `namespace_config`, `namespace_mapping` | removed from the operator config |
| 2026.8.0 | `global.CONTROLPLANE_GRPC_ENDPOINT`, `global.QUEUE_GRPC_ENDPOINT` | removed; endpoint now derived from the host |
| 2026.8.0 | `executor.raw_config.namespace_mapping` override | no longer honored |

The `namespace_config` removal is the cautionary tale worth keeping in mind while you
write: a customer had custom task-log links nested under a key the chart did not read.
They rendered nothing, silently, for months. No error, no warning, no clue in the release
notes — the links simply never appeared in the UI.

**In output** A table with the old key, the new key (or "removed"), and the exact
migration. If the value has to move to a different nesting level, show both shapes. A
reader must be able to transform their file without guessing.

---

## Class 3 — Deprecated but still honored

**What** An old key is superseded but kept working as a fallback.

**Why it matters** Not urgent — but it becomes Class 2 in some future release, and a
customer who never learned about the rename gets no warning then either. Listing it now
is what buys them a graceful migration.

**Detect** The new values.yaml comments the old key as deprecated, and the template still
reads it — often through a precedence helper.

**Real example** 2026.8.0: `global.UNION_CONTROL_PLANE_HOST` deprecated in favor of
`global.CONTROLPLANE_HOST`; the top-level `host:` key likewise demoted to a fallback.
Precedence resolves through a chart helper, so all three still work.

**In output** A short "deprecated, still works" list. State the precedence order if more
than one fallback exists. Explicitly say no action is required yet.

---

## Class 4 — Static default becomes computed

**What** A fixed default is replaced by a template expression whose result depends on
another value.

**Why it hurts** The effective value now varies per cluster. Two customers on the same
chart version get different behavior, and neither can tell what they will get by reading
the default alone.

**Detect** A default that changes from a literal to a `{{ ... }}` expression.

**Real examples**
| Release | Key | Became |
|---|---|---|
| 2026.8.3 | `operator.config.billing.model` | `{{ ternary "ResourceUsage" "None" .Values.operator.enableTunnelService }}` |
| 2026.8.0 | webhook `enabled` | derived from an `apps.enabled` helper rather than `serving.enabled` |

**In output** State the controlling key and give the resolution table — "if X is true you
get A, otherwise B". Give the customer a command to check which branch they land on,
usually a targeted `helm template` piped through a manifest lookup.

---

## Class 5 — Workload added or removed

**What** Deployments, Services, ServiceAccounts, ClusterRoles, ConfigMaps, PriorityClasses
appear or disappear from rendered output.

**Why it matters** Removals leave orphaned monitoring, alerts, PDBs, and quota
reservations pointing at things that no longer exist. Additions consume resource headroom
and may trip admission policies that were never exercised before.

**Detect** Render diff. See `render-profiles.md`. This class is invisible in a values diff
when the workload is gated behind a helper rather than a values key.

**Real example** 2026.8.0 removed `Deployment/executor`, `ConfigMap/executor`,
`Service/union-operator-executor`, `ClusterRole/union-executor`, and its bindings; it added
`PriorityClass/union-leaseworker` and `PriorityClass/union-flytepropeller`. A customer
scraping the executor Service for metrics lost that target with no warning.

**In output** Two short lists — added, removed. For removals, prompt the reader to check
their own monitoring and policy for references. For additions, note resource requests when
they are non-trivial.

---

## Class 6 — Prerequisite or ordering requirement

**What** Something must happen outside `helm upgrade`, or in a specific order relative
to it.

**Why it hurts** `helm upgrade` fails partway, or worse, succeeds against CRDs that do not
support the new objects. Helm does not manage CRD upgrades for already-installed CRDs.

**Detect**
```bash
git diff --stat $FROM $TO -- charts/dataplane-crds
git diff $FROM $TO -- charts/dataplane/Chart.yaml   # dependencies: block
```
Any CRD change, or any subchart bump that itself ships CRDs.

**Real example** Enabling app serving requires the Knative CRDs to be present first — the
serving certificate object is a Knative kind, not a cert-manager one, so the chart cannot
render it until the CRDs exist.

**In output** The very first section after the summary, as an ordered list of commands.
Server-side apply for CRDs:
```bash
kubectl apply --server-side --force-conflicts -f charts/dataplane/crds/
```

---

## Class 7 — New opt-in feature

**What** Purely additive. Nothing breaks if the customer ignores it.

**Why it needs care** Mixing opt-in features into required actions is how a guide becomes
scary and gets skipped. Customers need to be able to see, in one glance, the minimum they
must do.

**Real examples** Zero Trust enablement, app serving, the API-key auth path.

**In output** A clearly separated "optional, not required for this upgrade" section, after
verification. One or two sentences each plus the values snippet. If the feature has a
cross-cluster prerequisite — for instance, one that is only fully in effect once every
cluster in the tenant has it enabled — say so, because a partially-enabled feature that
looks enabled is worse than one that is off.

---

## Class 8 — Image reference change

**What** A default `repository:` or `tag:` changes, including fully qualifying a
previously-bare image name.

**Why it hurts** Clusters with an allowed-registry admission policy, an air-gapped
environment, or a private mirror fail closed with `ErrImagePull` — often on a Helm hook or
test pod that only runs during the upgrade itself, so the upgrade hangs rather than
failing cleanly.

**Detect**
```bash
git diff $FROM $TO -- charts/dataplane/values.yaml 'charts/dataplane/values.*.yaml' \
  | grep -E '^[+-].*(repository|image|tag):'
```

**Real example** 2026.8.0 qualified `alpine/k8s` to `docker.io/alpine/k8s` and pinned the
Helm-test busybox to `docker.io/library/busybox`, precisely because a bare name resolves
against an implicit Docker Hub default that registry-pinning clusters reject.

**In output** A list of every changed image reference with old and new value, and an
explicit note for air-gapped and registry-policy clusters to mirror the new references
before upgrading.

---

## Assigning severity

The generated skill's summary line takes the highest severity present:

| Severity | Triggered by |
|---|---|
| **Breaking** | Class 2, or Class 6 with a hard prerequisite |
| **Behavior change** | Class 1, Class 4, Class 5 removals, Class 8 |
| **Additive** | Class 3, Class 7, Class 5 additions only |

Never soften this. A customer who trusts an "additive" label and skips the guide is the
outcome this whole effort exists to prevent.
