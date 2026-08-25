---
name: author-upgrade-skill
description: Generate the customer-facing upgrade skill for a newly cut dataplane chart release. Use when tagging or preparing a helm-charts dataplane release, when asked to "write the upgrade skill/guide for <version>", when release notes need to become actionable migration steps, or when backfilling upgrade skills for past versions. Produces charts/dataplane/upgrades/<version>/{SKILL.md,changes.yaml} and refreshes UPGRADING.md.
---

# Author an upgrade skill for a dataplane release

You are producing the artifact a **customer** hands their own coding agent when they
need to upgrade their self-managed Union dataplane. It must also stand alone as a
runbook for someone who reads it by hand.

Two hard constraints govern everything below:

1. **Reviewable in five minutes.** Target 200 lines, hard cap 300. If a release genuinely
   has more to say, cut narrative, not findings.
2. **Nothing internal leaks.** The output lands in a public repo. Read
   `references/disclosure-policy.md` before you write a single line of output, and run
   `assets/scan-disclosure.sh` before you finish. This is not optional.

## Why this exists

Two things already describe a release, and neither is what a customer needs.

**GitHub release notes** are `git log --pretty="- %s (%h)"`. A release can carry 46 commits
and 900 changed lines of `values.yaml`; commit subjects surface none of what matters.

**`charts/dataplane/RELEASE.md`** is the opposite problem. It is hand-written, high-fidelity,
and substantively thorough — but it is written *by* a Union engineer *for* Union engineers.
It explains mechanism rather than action, carries almost no runnable commands, and includes
notes that mean nothing to a customer ("the metrics glossary needs a matching update",
"regenerate with terraform apply"). A customer cannot execute it.

Neither reliably catches the class of change that actually hurts: **a values key that stops
being read produces no error.** Helm accepts it, the chart ignores it, and the feature
quietly stops working — sometimes for months before anyone notices.

Your job is threefold, once per release, so that no customer has to do it:

1. **Distill** — turn explanation into commands with expected outputs.
2. **Verify** — cross-check against the actual diff, and catch what the author left out.
3. **Retarget** — move it from an internal audience to a customer one.

## Inputs

| Input | How to get it |
|---|---|
| `TO` — version being released | `grep '^version:' charts/dataplane/Chart.yaml`, or the tag just cut |
| `FROM` — previous release | `git tag -l 'dataplane-*' --sort=-v:refname \| grep -E '^dataplane-[0-9]' \| grep -v "$TO" \| head -1` |

One skill covers exactly one hop: `FROM → TO`. Customers jumping several versions read
every skill in the range; do not try to make one skill span multiple releases. Keeping
hops atomic is what makes range-merging work.

If the tags do not exist yet (pre-tag authoring), diff the release branch against the
previous tag instead and note the version as unreleased.

## Procedure

### 1. Read what the release author already wrote

```bash
git show "$TO":charts/dataplane/RELEASE.md | sed -n "/^## ${TO#dataplane-}/,/^## [0-9]/p"
gh release view "$TO" --json body -q .body    # usually just the commit log
```

`RELEASE.md` is your best single source and the closest thing to ground truth on intent —
it tells you *why* a change was made, which a diff never can. Read its section for this
version before anything else.

Treat it as a strong hypothesis, not as the finding set:

- **It can omit.** Steps 2–5 exist to catch that. Diff every release even when RELEASE.md
  looks complete, and say in your report whether the diff agreed with it.
- **It is written for an internal audience.** References to internal tooling, other Union
  repositories, provisioning pipelines, or follow-up work do not belong in your output.
  Translate them into what a customer running `helm upgrade` should do, or drop them.
  `references/disclosure-policy.md` governs this and is binding.
- **It explains rather than instructs.** Your output is commands and expected outputs.
  Converting prose into runnable steps is most of the work.

If RELEASE.md has no section for this version, say so in your report and work from the
diff alone.

### 2. Establish the diff surface

```bash
FROM=dataplane-2026.8.2   # adjust
TO=dataplane-2026.8.3

git diff --stat $FROM $TO -- charts/dataplane charts/dataplane-crds
git log --oneline $FROM..$TO -- charts/dataplane charts/dataplane-crds
git diff $FROM $TO -- charts/dataplane/values.yaml
git diff $FROM $TO -- 'charts/dataplane/values.*.yaml'
git diff $FROM $TO -- charts/dataplane/Chart.yaml charts/dataplane-crds/Chart.yaml
git diff --stat $FROM $TO -- charts/dataplane/templates
```

Read the values diffs in full. They are small per-hop (typically 20–300 lines) and they
are where the dangerous changes live. Skim the template diff for added/removed files.

### 3. Classify every change

Read `references/change-taxonomy.md`. It defines eight classes, gives the detection
recipe for each, and cites a real past release where that class caused a customer
incident. Walk the diff and assign every substantive change to a class.

Two classes are the reason this skill exists — spend your time here:

- **Class 2 (key removed/renamed)** — silently inert config. Confirm by grepping the
  whole template tree for the old key path and finding no reader.
- **Class 1 (silent default flip)** — a key the customer never set changes meaning.

Ignore pure comment churn, whitespace, and doc-only edits. They inflate the diff and
belong to no class.

### 4. Verify against rendered output

A values diff tells you what changed in the chart. A render diff tells you what changes
**on a cluster**. Do both — they catch different things, and the render diff is what
proves a workload actually appeared or disappeared.

Follow `references/render-profiles.md`. In short: render both versions against each
synthetic profile in `assets/profiles/`, reduce to a sorted `Kind/name` list, and diff.

```bash
./skills/author-upgrade-skill/assets/render-diff.sh $FROM $TO
```

**Use the synthetic profiles only.** Never render against a real customer values file,
even one you have locally — see the disclosure policy. The profiles are built to cover
the real configuration axes (cloud, apps on/off, zero-trust on/off, low-privilege) without
carrying anyone's identity.

### 5. Check for prerequisites and ordering

- CRDs: `git diff --stat $FROM $TO -- charts/dataplane-crds` and the `dataplane-crds`
  Chart.yaml version. Any CRD change means a server-side apply **before** `helm upgrade`.
- Subchart bumps: diff the `dependencies:` block in `charts/dataplane/Chart.yaml`. A
  major bump in an upstream chart (prometheus, fluent-bit, opencost, knative-operator)
  can carry its own breaking changes — link upstream's notes rather than restating them.
- Image references: any change to a `repository:` or `tag:` default. Clusters with an
  allowed-registry admission policy fail closed on these.

### 6. Consult the platform source for semantics — but never cite it

Some changes are only meaningful if you know what the component does with the value.
`config.authorizer.type: noop → Authorizer` is three words of diff and a complete change
in authorization posture.

If a Union platform checkout is available locally, read it to understand the semantics.
Then **restate the consequence in customer-facing terms only**: what behavior changes,
what breaks if unprepared, what to check afterwards. Never quote internal source, name
internal services beyond what the chart already names, or cite a file path outside this
repository. `references/disclosure-policy.md` is binding.

If you cannot establish what a change does, say so plainly in the output —
"contact Union support before upgrading if you rely on X" is a legitimate and honest
finding. Do not guess at semantics.

### 7. Write the two output files

Fill `assets/SKILL.template.md` → `charts/dataplane/upgrades/<TO>/SKILL.md`.
Fill `assets/changes.template.yaml` → `charts/dataplane/upgrades/<TO>/changes.yaml`.

`references/template-guide.md` covers how to fill each section, the tone, and what to
leave out. Read it — the failure mode for generated guides is hedging and padding, and
that guide is specific about avoiding both.

`changes.yaml` is the machine-readable twin. It exists so an agent handling a multi-version
jump can merge N releases without reading N prose documents: it can see that a key
deprecated in one release was removed in a later one, and skip the intermediate advice.
Keep the two files consistent — every entry in one has a counterpart in the other.

### 8. Refresh the index

Add a row for `<TO>` to `charts/dataplane/UPGRADING.md`, newest first. Set the impact
column from the highest-severity class present in this release.

### 9. Run the disclosure gate

```bash
./skills/author-upgrade-skill/assets/scan-disclosure.sh charts/dataplane/upgrades/<TO>
```

The script greps for the mechanical patterns — org slugs, account and subscription IDs,
internal hostnames, ticket identifiers, internal repo paths. **A clean scan is necessary,
not sufficient.** After it passes, reread both files yourself against the judgment rules
in `references/disclosure-policy.md`, which catch what a grep cannot: a change described
in terms that only make sense if you know a specific customer's setup, or a rationale
that reveals an unannounced roadmap.

If anything trips, fix the output. Never weaken the scan to make it pass.

### 10. Self-check before handing back

- [ ] Every required action is a command the customer can run, not a description of one
- [ ] Every "verify" step names the exact expected output, not "check it looks right"
- [ ] Silent default flips state the old value, the new value, and what to set to keep today's behavior
- [ ] Opt-in features are visibly separated from required actions
- [ ] Rollback section is present and accurate for this specific hop
- [ ] Under 300 lines
- [ ] Disclosure scan clean, plus your own read-through
- [ ] `changes.yaml` and `SKILL.md` agree

Report to the human reviewer: the version hop, the count of changes per class, whether the
diff agreed with RELEASE.md (and what it added), anything you could not establish the
semantics of, and the line count.

## Backfilling past releases

Same procedure, iterated over consecutive tag pairs oldest-first. Backfill only as far
as the oldest version still running in the field. Mark backfilled skills with
`backfilled: true` in `changes.yaml` — they were written without the release context
the author had, and a reviewer should weight them accordingly.
