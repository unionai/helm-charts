# Render profiles and the render diff

A values diff shows what changed in the chart. A render diff shows what changes **on a
cluster**. They catch different things, and you need both.

Specifically, a render diff is the only way to see:

- workloads gated behind a template helper rather than a values key
- RBAC that widened or narrowed
- ConfigMap content that changed because a helper it calls changed
- objects that moved between charts or namespaces
- differences that only appear on one cloud

## The profiles

`assets/profiles/` holds four synthetic values files. They are not anyone's deployment.
They exist to exercise the configuration axes that actually vary in the field:

| Profile | Axes exercised |
|---|---|
| `aws-selfmanaged.yaml` | AWS, IRSA identity, S3 storage, apps off, standard privilege |
| `gcp-selfmanaged.yaml` | GCP, workload identity, GCS storage, apps **on** |
| `azure-selfmanaged.yaml` | Azure, workload identity, blob storage, apps on, zero-trust **on** |
| `minimal.yaml` | Almost everything off — isolates base-chart behavior from subchart noise |

Every value in them is a placeholder. Read `disclosure-policy.md` on why this matters:
never substitute a real customer file, even one sitting in your working directory.

When a release adds a genuinely new axis, add a profile rather than overloading an
existing one. Keep each profile readable — its job is to be obviously non-identifying.

## Running the diff

```bash
./skills/author-upgrade-skill/assets/render-diff.sh dataplane-2026.8.2 dataplane-2026.8.3
```

For each profile it renders both versions, reduces to a sorted `Kind/name` list, and diffs.
Output lands in a temp directory whose path it prints, so you can dig into a specific
object afterwards.

Reading the result:

- `<` lines are **removed** objects → Class 5 removal. Check for orphaned monitoring,
  alerts, PDBs, and network policy that referenced them.
- `>` lines are **added** objects → Class 5 addition. Note resource requests if
  non-trivial; check whether admission policies would reject them.
- **No object-list change but a large content diff** is often Class 1 or Class 4 — a
  default flipped inside a ConfigMap. Diff the object bodies for the profile that showed
  it:

```bash
diff <(helm template ... --version "$FROM_V" | yq 'select(.metadata.name == "NAME")') \
     <(helm template ... --version "$TO_V"   | yq 'select(.metadata.name == "NAME")')
```

## Failure modes worth knowing

**Render fails on one version but not the other.** Usually a newly-required value. That is
itself a finding — it means an existing customer's file will also fail to render, and it
belongs in the guide's required-actions section with the exact key to add.

**Render fails on both.** Your profile is stale relative to the chart. Fix the profile,
not the finding.

**Subchart churn floods the diff.** A dependency bump can rewrite hundreds of objects that
have nothing to do with the Union chart. Confirm against the `dependencies:` block in
`Chart.yaml`, then report it as a subchart bump with a link to upstream's notes rather
than enumerating the objects. Use `minimal.yaml` to see the base chart clearly.

**A diff that appears only on one cloud.** Report it as cloud-scoped. Customers on other
clouds should be able to skip it, and saying so is part of keeping the guide short enough
to read.
