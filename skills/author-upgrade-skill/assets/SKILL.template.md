---
name: upgrade-dataplane-<TO_VERSION>
description: Upgrade a self-managed Union dataplane from <FROM_VERSION> to <TO_VERSION>. Use when upgrading, planning, or verifying this specific chart version hop, or when jumping across a version range that includes <TO_VERSION>. Covers required actions, silent default changes, verification, and rollback.
---

# Dataplane <FROM_VERSION> to <TO_VERSION>

<!-- One sentence: what this release is, in the customer's terms. -->

| | |
|---|---|
| **Impact** | <Breaking / Behavior change / Additive> |
| **Downtime** | <none / brief control-loop restart / describe> |
| **Estimated time** | <N minutes, excluding verification> |
| **Rollback** | <supported / see caveats below> |

<!-- If Breaking, one sentence saying what breaks if the required actions are skipped. -->

> Upgrading across several versions? Read every skill in
> `charts/dataplane/upgrades/` between your current version and your target, oldest
> first. Each covers one hop and they compose.

---

## 1. Before you upgrade

<!-- Class 6. If nothing, write "No prerequisites for this release." and keep the heading. -->

Capture your current state first — you need it for rollback and for the diff in step 2.

```bash
NS=<YOUR_NAMESPACE>          # the namespace the dataplane release lives in
REL=<YOUR_RELEASE_NAME>      # e.g. unionai-dataplane

helm get values "$REL" -n "$NS" -o yaml > values-backup-$(date +%Y%m%d-%H%M).yaml
helm list -n "$NS"
kubectl get pods -n "$NS" --field-selector=status.phase!=Running
```

<!-- Then the ordered prerequisite commands. CRDs first if applicable:
kubectl apply --server-side --force-conflicts -f charts/dataplane/crds/
-->

---

## 2. Required values changes

<!-- Class 2 — the ones that break. Omit the whole section only if genuinely none. -->

These keys changed name or were removed. **A key the chart no longer reads is silently
ignored** — Helm will not warn you, and the feature it configured stops working.

| Old key | New key | Migration |
|---|---|---|
| | | |

<!-- For any change of nesting level, show both shapes explicitly:

Before:
```yaml
old_key:
  nested: value
```

After:
```yaml
new_parent:
  nested: value
```
-->

### Check your file

```bash
# Flags keys this release no longer reads
grep -nE '<OLD_KEY_PATTERN>' <YOUR_VALUES>.yaml
```

---

## 3. Default values that change

<!-- Class 1 and Class 4. The most-used table in the document. -->

These change even though you never set them. The last column is what to add to your values
file if you want today's behavior to continue.

| Key | Old default | New default | To keep current behavior |
|---|---|---|---|
| | | | |

<!-- Class 4 (computed defaults) get their own subsection with the resolution table:

### `<key>` now depends on `<controlling key>`

| If `<controlling key>` is | `<key>` resolves to |
|---|---|
| `true` | `<A>` |
| `false` | `<B>` |
-->

---

## 4. Image references

<!-- Class 8. Omit if no image defaults changed. -->

| Image | Old | New |
|---|---|---|
| | | |

If your cluster restricts registries, runs air-gapped, or pulls through a mirror, mirror
these before upgrading. Some are used only by Helm hooks and test pods, so a missing image
shows up as an upgrade that hangs rather than one that fails cleanly.

---

## 5. Run the upgrade

```bash
helm repo update unionai

helm upgrade "$REL" unionai/dataplane \
  --version <TO_VERSION> \
  -n "$NS" \
  -f <YOUR_VALUES>.yaml \
  --dry-run
```

Review the dry-run output, then drop `--dry-run`.

> If you layer an overlay file, the **last** `-f` wins. Pass your base values first and
> the overlay after it.

---

## 6. Verify

<!-- Every check states its expected output. -->

```bash
helm list -n "$NS" -o json | jq -r '.[] | select(.name=="'"$REL"'") | .chart'
# expect: dataplane-<TO_VERSION>

kubectl get pods -n "$NS" --field-selector=status.phase!=Running
# expect: no resources found

kubectl get deploy -n "$NS" -o json \
  | jq -r '.items[] | select(.status.readyReplicas != .status.replicas) | .metadata.name'
# expect: no output
```

<!-- Then release-specific checks. Class 5 removals: confirm the object is gone and
     nothing still references it. Class 5 additions: confirm it came up. -->

Finally, run one workflow end to end and confirm it reaches success.

---

## 7. Rollback

```bash
helm rollback "$REL" -n "$NS"
kubectl get pods -n "$NS" -w
```

<!-- State any caveat honestly. CRDs are not rolled back by Helm; a newer CRD is normally
     compatible with the older chart, but say so explicitly rather than leaving it implied.
     Note anything that is genuinely one-way. -->

---

## Optional for this release

<!-- Class 7. Nothing here is required. If nothing, delete the section. -->

<!-- Per feature: one or two sentences, the values snippet, and any cross-cluster
     prerequisite. If a feature is only fully effective once enabled everywhere in a
     tenant, say so — partial enablement that looks complete is worse than off. -->

---

## Also in this release

<!-- Class 3 deprecations and non-actionable notes. Keep to a short list. -->

- <old key> is deprecated in favor of <new key>; both still work. No action required.

---

## If something does not match

Open an issue on `unionai/helm-charts`, or contact Union support with your chart version,
the output of the verification commands above, and the relevant pod logs.
