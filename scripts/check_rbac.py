#!/usr/bin/env python3
"""Enforce RBAC invariants on the rendered dataplane chart.

Three invariants, all evaluated against the committed renders in
tests/generated/ (which `make helm-test` already proves match a fresh render):

  cluster_write          No ClusterRoleBinding may reference a role that
                         contains write verbs. A ClusterRole is inert on its
                         own; only a ClusterRoleBinding makes it cluster-wide.

  low_priv_cluster_role  No ClusterRole objects may render when the fixture
                         sets low_privilege true (the chart default).

  dead_cluster_rule      A namespaced Role may not name a cluster-scoped
                         resource and may not carry nonResourceURLs. The API
                         server silently ignores such a rule, so the grant is
                         dead: the manifest applies cleanly and the workload
                         gets Forbidden at runtime. Design spec 2.4 tabulates
                         today's instances; recording them in prose did not
                         stop another one being written, so this makes it
                         mechanical.

Known violations are pinned in tests/rbac-baseline.yaml, keyed by the triple
(snapshot, role name, invariant). A pinned entry allows the violation in the
snapshots it names and nowhere else, so reintroducing a cluster-wide grant in a
render that did not have it is still caught even when the same role name is
legitimately pinned elsewhere.

A `cluster_write` entry additionally pins a `grant` fingerprint: the
ClusterRoleBindings that reference the role, their subjects, and the
write-bearing rules the binding confers. Without it the baseline would pin only
THAT a role is over-privileged, not HOW over-privileged or WHO holds it, and a
pinned grant could be widened without limit -- a new subject, a new binding, a
new `escalate` verb -- while the check stayed green. The fingerprint is stored
as readable, sorted lines rather than a hash so a mismatch can report what
changed instead of "the hash moved".

The check fails on any of:

  new violation     it occurs in a snapshot it is not pinned for;
  grant changed     a pinned cluster_write grant no longer matches the render
                    -- the grant was widened (or narrowed) without review;
  stale baseline    it is pinned but no longer occurs -- the expected outcome
                    of a hardening phase, which must delete what it fixed;
  missing reason    an entry whose reason is absent, empty, or still the
                    generated "TODO" placeholder. Every pinned cluster-wide
                    privilege carries a written justification or the build is
                    red.

Usage:
    python3 scripts/check_rbac.py
    python3 scripts/check_rbac.py --write-baseline

--write-baseline rewrites the file from the current renders. It carries every
existing reason forward by key and stamps the TODO placeholder only on
genuinely new entries, so regenerating never destroys a hand-written
justification -- and the normal check stays red until each new entry is
justified by hand. Grant fingerprints are always regenerated: they describe the
render, not the reviewer's intent, so there is nothing in them to preserve.
"""

import argparse
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATED_DIR = REPO_ROOT / "tests" / "generated"
VALUES_DIR = REPO_ROOT / "tests" / "values"
BASELINE_PATH = REPO_ROOT / "tests" / "rbac-baseline.yaml"

READ_VERBS = {"get", "list", "watch"}

CLUSTER_WRITE = "cluster_write"
LOW_PRIV_CLUSTER_ROLE = "low_priv_cluster_role"
DEAD_CLUSTER_RULE = "dead_cluster_rule"

TODO_REASON = "TODO: justify or remove this entry"

# aggregationRule.clusterRoleSelectors[] keys this script knows how to evaluate.
# Anything else (matchExpressions today) makes the selector unresolvable.
RESOLVABLE_SELECTOR_KEYS = {"matchLabels"}

# Cluster-scoped resource names, for the dead_cluster_rule invariant. This is a
# CURATED list, deliberately NOT exhaustive: it covers every cluster-scoped type
# this chart's Roles actually name today (design spec 2.4) plus the types a
# future rule is most likely to reach for. A cluster-scoped resource missing
# from this set is a false negative, not a false positive, so growing the list
# is always safe. Matching is on the resource name only -- the apiGroup is not
# consulted -- because no namespaced resource in this chart shares a name with a
# cluster-scoped one.
CLUSTER_SCOPED_RESOURCES = frozenset(
    base + suffix
    for base in (
        "nodes",
        "namespaces",
        "persistentvolumes",
        "customresourcedefinitions",
        "mutatingwebhookconfigurations",
        "validatingwebhookconfigurations",
        "clusterroles",
        "clusterrolebindings",
        "priorityclasses",
        "storageclasses",
        "csidrivers",
        "csinodes",
        "volumeattachments",
        "apiservices",
        "ingressclasses",
        "runtimeclasses",
        "certificatesigningrequests",
    )
    for suffix in ("", "/status", "/proxy")
)


def load_documents(path):
    """Parse a multi-document YAML file, skipping empty and non-mapping docs."""
    with path.open() as handle:
        for doc in yaml.safe_load_all(handle):
            if isinstance(doc, dict):
                yield doc


def is_write_rule(rule):
    """A rule is a write if it grants any verb outside get/list/watch."""
    return bool(set(rule.get("verbs") or []) - READ_VERBS)


def labels_match(selector, labels):
    """True if every key/value in the matchLabels selector is present."""
    return all(labels.get(key) == value for key, value in selector.items())


def role_key(role):
    """The (kind, name) identity a role is stored under in roles_by_name."""
    return role.get("kind"), (role.get("metadata") or {}).get("name")


def effective_rules(role, roles_by_name, _visiting=frozenset()):
    """Return (rules, unresolved) for a role, resolving its aggregationRule.

    An aggregating ClusterRole carries no rules of its own -- the API server
    fills them in from every ClusterRole matching its selectors. Ignoring that
    would let a write-bearing role reach cluster scope through an aggregation
    shell, so the selectors are resolved against the rest of the render. This
    path is live: `knative-serving-admin` has zero rules of its own and fifteen
    aggregated ones, several of them writes.

    Resolution is RECURSIVE and propagates `unresolved`. A matched candidate may
    itself be an aggregation shell, so folding in its literal `rules` and
    stopping there fails open: a shell with no rules of its own that aggregates
    unevaluably would contribute an empty rule list and read as harmless. The
    `_visiting` set breaks aggregation cycles -- a self-referential or mutually
    referential pair terminates and reports unresolved rather than recursing
    forever.

    Only `matchLabels` selectors can be evaluated here. knative-operator's four
    `*-aggregated` shells select with `matchExpressions`, which this script
    does not implement -- and an empty selector matches every ClusterRole in
    the cluster, including ones this chart never renders. For those the second
    element of the return is True and the caller MUST fail closed: an
    unevaluated selector means the rule set is unknown, not empty. The tuple
    return exists precisely so no caller can read an empty rule list as proof
    of harmlessness.

    Only ClusterRoles are aggregation candidates -- the API server never
    aggregates namespaced Roles -- so a Role carrying a matching label (for
    example `knative-serving-activator`) is deliberately not folded in.
    """
    rules = list(role.get("rules") or [])
    unresolved = False
    visiting = _visiting | {role_key(role)}
    aggregation = role.get("aggregationRule") or {}
    for selector in aggregation.get("clusterRoleSelectors") or []:
        selector = selector or {}
        match_labels = selector.get("matchLabels") or {}
        if set(selector) - RESOLVABLE_SELECTOR_KEYS or not match_labels:
            unresolved = True
            continue
        for key, candidate in roles_by_name.items():
            if key[0] != "ClusterRole":
                continue
            candidate_labels = (candidate.get("metadata") or {}).get("labels") or {}
            if not labels_match(match_labels, candidate_labels):
                continue
            if key in visiting:
                # Aggregation cycle (including a role selecting itself). The
                # API server's real expansion is not modelled here, so fail
                # closed rather than guessing at a fixed point.
                unresolved = True
                continue
            sub_rules, sub_unresolved = effective_rules(
                candidate, roles_by_name, visiting
            )
            rules.extend(sub_rules)
            unresolved = unresolved or sub_unresolved
    return rules, unresolved


def dead_cluster_resources(rule):
    """Cluster-scoped resources named by a rule, for the dead-rule invariant.

    `resources: ['*']` is EXEMPT. Per design spec 5, a wildcard write inside a
    namespaced Role is namespace-admin, which is the accepted operating model
    for these components, and narrowing wildcards is an explicit non-goal. The
    wildcard does technically also cover cluster-scoped types that the API will
    ignore, but flagging it would pin every wildcard Role in the chart into the
    baseline to say nothing actionable.
    """
    resources = set(rule.get("resources") or [])
    if "*" in resources:
        return set()
    return {name for name in resources if name in CLUSTER_SCOPED_RESOURCES}


def find_dead_cluster_rules(role):
    """Return sorted descriptions of a Role's dead cluster-scoped grants."""
    findings = set()
    for rule in role.get("rules") or []:
        for resource in dead_cluster_resources(rule):
            findings.add(resource)
        if rule.get("nonResourceURLs"):
            for url in rule["nonResourceURLs"]:
                findings.add(f"nonResourceURL {url}")
    return sorted(findings)


def rule_fingerprint(rule):
    """One canonical line for a write-bearing rule, or None if it is read-only.

    Every list is sorted, so reordering a rule's apiGroups or verbs in a
    template does not churn the baseline. Absent fields are omitted to keep the
    line readable, and the core API group renders as `""` rather than as
    nothing so it is not confusable with an omitted field. `verbs` lists only
    the NON-read verbs, since those are what make the grant a write.
    """
    verbs = sorted(set(rule.get("verbs") or []) - READ_VERBS)
    if not verbs:
        return None
    parts = []
    for field in ("apiGroups", "resources", "resourceNames", "nonResourceURLs"):
        values = rule.get(field) or []
        if values:
            rendered = ",".join(value or '""' for value in sorted(values))
            parts.append(f"{field}=[{rendered}]")
    parts.append(f"verbs=[{','.join(verbs)}]")
    return "write " + " ".join(parts)


def grant_fingerprint(ref_name, role, roles_by_name, bindings):
    """Canonical, diffable description of one cluster-wide grant.

    Covers WHO holds it (the referencing ClusterRoleBindings and their
    subjects) and HOW MUCH it confers (the write-bearing effective rules,
    aggregation included). Pinning only the role name would let a pinned grant
    be widened -- new subject, new binding, new verb -- with no new violation.
    """
    referencing = [
        binding
        for binding in bindings
        if (binding.get("roleRef") or {}).get("name") == ref_name
    ]

    lines = set()
    for binding in referencing:
        name = (binding.get("metadata") or {}).get("name") or "<unnamed>"
        lines.add(f"binding {name}")
        for subject in binding.get("subjects") or []:
            kind = subject.get("kind") or "<no kind>"
            subject_name = subject.get("name") or "<no name>"
            namespace = subject.get("namespace")
            if namespace:
                lines.add(f"subject {kind}/{namespace}/{subject_name}")
            else:
                lines.add(f"subject {kind}/{subject_name}")

    if role is None:
        # A built-in cluster role (system:auth-delegator). Its rules live in the
        # API server, not this render, so the binding and its subjects are the
        # whole of what this repo controls -- and all of what can be pinned.
        lines.add("rules <unknown: roleRef is not rendered by this chart>")
    else:
        rules, unresolved = effective_rules(role, roles_by_name)
        if unresolved:
            lines.add("rules <unknown: unevaluable aggregationRule selector>")
        for rule in rules:
            line = rule_fingerprint(rule)
            if line:
                lines.add(line)

    return tuple(sorted(lines))


def fixture_is_low_privilege(stem):
    """Read low_privilege from the fixture. The chart default is true."""
    values_path = VALUES_DIR / f"{stem}.yaml"
    if not values_path.exists():
        return True
    with values_path.open() as handle:
        values = yaml.safe_load(handle) or {}
    return bool(values.get("low_privilege", True))


def find_violations(docs, low_privilege):
    """Return {(name, invariant): grant} for one rendered snapshot.

    `grant` is the fingerprint tuple for cluster_write and None otherwise; only
    cluster_write describes a cluster-wide grant that can be widened.
    """
    roles_by_name = {}
    bindings = []
    for doc in docs:
        kind = doc.get("kind")
        name = (doc.get("metadata") or {}).get("name")
        if not name:
            continue
        if kind in ("ClusterRole", "Role"):
            roles_by_name[(kind, name)] = doc
        elif kind == "ClusterRoleBinding":
            bindings.append(doc)

    violations = {}

    for (kind, name), role in roles_by_name.items():
        if low_privilege and kind == "ClusterRole":
            violations[(name, LOW_PRIV_CLUSTER_ROLE)] = None
        if kind == "Role" and find_dead_cluster_rules(role):
            violations[(name, DEAD_CLUSTER_RULE)] = None

    for binding in bindings:
        role_ref = binding.get("roleRef") or {}
        ref_name = role_ref.get("name")
        if not ref_name:
            continue
        # A roleRef we cannot resolve is a built-in cluster role (for example
        # system:auth-delegator). We cannot read its rules, so we cannot prove
        # it is read-only. Treat it as a violation requiring a baseline entry.
        role = roles_by_name.get((role_ref.get("kind"), ref_name))
        if role is None:
            violations[(ref_name, CLUSTER_WRITE)] = grant_fingerprint(
                ref_name, None, roles_by_name, bindings
            )
            continue
        rules, unresolved = effective_rules(role, roles_by_name)
        # `unresolved` first: an aggregation selector we cannot evaluate means
        # the rule set is unknown, so the role is presumed write-bearing.
        if unresolved or any(is_write_rule(rule) for rule in rules):
            violations[(ref_name, CLUSTER_WRITE)] = grant_fingerprint(
                ref_name, role, roles_by_name, bindings
            )

    return violations


def collect_all_violations():
    """Return {(snapshot, name, invariant): grant} across every snapshot."""
    violations = {}
    for path in sorted(GENERATED_DIR.glob("dataplane*.yaml")):
        stem = path.stem
        docs = list(load_documents(path))
        found = find_violations(docs, fixture_is_low_privilege(stem))
        for (name, invariant), grant in found.items():
            violations[(stem, name, invariant)] = grant
    return violations


def load_baseline():
    """Return ({(snapshot, name, invariant): (reason, grant)}, [error, ...])."""
    if not BASELINE_PATH.exists():
        return {}, []
    with BASELINE_PATH.open() as handle:
        data = yaml.safe_load(handle) or {}

    baseline = {}
    errors = []
    for index, entry in enumerate(data.get("allowed") or []):
        entry = entry or {}
        name = entry.get("name")
        invariant = entry.get("invariant")
        snapshots = entry.get("snapshots") or []
        reason = (entry.get("reason") or "").strip()
        grant = entry.get("grant")
        label = f"allowed[{index}] {name or '<no name>'} / {invariant or '<no invariant>'}"

        if not name or not invariant or not snapshots:
            errors.append(f"{label}: needs a name, an invariant and a non-empty snapshots list")
            continue
        if not reason or reason.startswith("TODO"):
            errors.append(
                f"{label}: reason is missing, empty or still the TODO placeholder"
            )

        if invariant == CLUSTER_WRITE:
            if not grant or not isinstance(grant, list):
                errors.append(
                    f"{label}: cluster_write entries need a non-empty grant "
                    f"fingerprint -- run --write-baseline to generate it"
                )
                grant = None
            else:
                grant = tuple(sorted(str(line) for line in grant))
        elif grant is not None:
            errors.append(
                f"{label}: only cluster_write entries carry a grant fingerprint"
            )
            grant = None

        for snapshot in snapshots:
            key = (snapshot, name, invariant)
            if key in baseline:
                errors.append(f"{label}: pinned twice for snapshot {snapshot}")
            baseline[key] = (reason, grant)

    return baseline, errors


HEADER = """\
# Pinned RBAC violations. Generated by scripts/check_rbac.py
# --write-baseline, then edited by hand to add a reason per entry.
#
# Every hardening phase DELETES entries from this file. Adding an
# entry means accepting a cluster-wide privilege, so it needs a
# written justification in review.
#
# Schema -- one entry per (name, invariant, reason, grant):
#
#   - name: union-executor        the RBAC object the violation is about
#     invariant: cluster_write    exactly one invariant per entry
#     reason: ...                 why this is accepted, and which phase owns it
#     snapshots:                  tests/generated/<snapshot>.yaml renders it
#     - dataplane.namespace-multi is pinned in -- and ONLY those
#     grant:                      cluster_write only; see below
#     - binding union-executor
#
# The pinned key is the triple (snapshot, name, invariant). An entry allows
# the violation in the snapshots it lists and nowhere else, so the same name
# appearing in an unlisted render is a NEW VIOLATION. Split an entry into two
# (same name and invariant, disjoint snapshot lists) when the snapshots need
# different reasons.
#
# The check FAILS if any entry's reason is missing, empty, or still starts
# with "TODO". --write-baseline carries existing reasons forward by key and
# stamps the placeholder only on genuinely new entries, so regenerating this
# file never silently discards a justification.
#
# grant -- REQUIRED on cluster_write entries, forbidden on the others. It
# fingerprints the grant itself, not just its name: which ClusterRoleBindings
# reference the role, which subjects they bind, and which write-bearing rules
# the binding confers (aggregation resolved). Without it the baseline would
# pin only THAT a role is over-privileged, so a pinned grant could be widened
# freely -- a new subject, a second binding, an added `escalate` -- and stay
# green. A grant that no longer matches the render is a GRANT CHANGED failure
# reporting the exact lines added and removed. It is machine-generated: never
# hand-edit it to make the check pass; rerun --write-baseline and review the
# diff, or delete the entry if the phase removed the grant.
#
# invariants:
#   cluster_write          a ClusterRoleBinding references this role and it
#                          contains write verbs -- or its aggregationRule
#                          uses a selector form the checker cannot evaluate,
#                          in which case it fails closed and reports here
#   low_priv_cluster_role  this ClusterRole renders when
#                          low_privilege is true
#   dead_cluster_rule      this namespaced Role names a cluster-scoped
#                          resource (or a nonResourceURL). The API server
#                          ignores the rule, so the grant is dead and the
#                          workload gets Forbidden at runtime. resources:
#                          ['*'] is exempt -- see design spec 5
"""


def write_baseline(violations, existing):
    """Rewrite the baseline, carrying existing reasons forward by key."""
    grouped = {}
    for key, grant in violations.items():
        snapshot, name, invariant = key
        reason = (existing.get(key) or (None, None))[0] or TODO_REASON
        grouped.setdefault((name, invariant, reason, grant), []).append(snapshot)

    entries = []
    for (name, invariant, reason, grant), snapshots in sorted(
        grouped.items(), key=lambda item: (item[0][0], item[0][1], sorted(item[1]))
    ):
        entry = {
            "name": name,
            "invariant": invariant,
            "reason": reason,
            "snapshots": sorted(snapshots),
        }
        if grant:
            entry["grant"] = list(grant)
        entries.append(entry)

    with BASELINE_PATH.open("w") as handle:
        handle.write(HEADER)
        # width is deliberately large: a reason wrapped across lines is far
        # harder to hand-edit, and hand-editing is this file's whole point.
        yaml.safe_dump(
            {"allowed": entries},
            handle,
            default_flow_style=False,
            sort_keys=False,
            width=4096,
        )

    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="overwrite tests/rbac-baseline.yaml with the current violations, "
        "preserving the reason already written for every existing entry",
    )
    args = parser.parse_args()

    violations = collect_all_violations()
    baseline, errors = load_baseline()

    if args.write_baseline:
        entries = write_baseline(violations, baseline)
        print(
            f"Wrote {len(entries)} entries covering {len(violations)} pinned "
            f"(snapshot, name, invariant) triples to "
            f"{BASELINE_PATH.relative_to(REPO_ROOT)}"
        )
        return 0

    def sort_key(key):
        snapshot, name, invariant = key
        return (invariant, name, snapshot)

    new = sorted(set(violations) - set(baseline), key=sort_key)
    stale = sorted(set(baseline) - set(violations), key=sort_key)

    changed = []
    for key in sorted(set(violations) & set(baseline), key=sort_key):
        pinned_grant = baseline[key][1]
        actual_grant = violations[key]
        if actual_grant is None or pinned_grant is None:
            # Not a cluster_write entry, or the entry is already reported as
            # malformed above. Nothing to compare.
            continue
        if pinned_grant != actual_grant:
            changed.append((key, pinned_grant, actual_grant))

    for message in errors:
        print(f"BASELINE ERROR {message}", file=sys.stderr)

    for snapshot, name, invariant in new:
        print(f"NEW VIOLATION  {invariant:22} {name}  [{snapshot}]", file=sys.stderr)

    for (snapshot, name, invariant), pinned_grant, actual_grant in changed:
        print(f"GRANT CHANGED  {invariant:22} {name}  [{snapshot}]", file=sys.stderr)
        for line in sorted(set(actual_grant) - set(pinned_grant)):
            print(f"    added   {line}", file=sys.stderr)
        for line in sorted(set(pinned_grant) - set(actual_grant)):
            print(f"    removed {line}", file=sys.stderr)

    for snapshot, name, invariant in stale:
        print(f"STALE BASELINE {invariant:22} {name}  [{snapshot}]", file=sys.stderr)

    if errors:
        print(
            "\nRBAC check failed: baseline entries above are malformed or "
            "unjustified.\n"
            "Every pinned entry needs a written reason -- replace the TODO "
            "placeholder\nor delete the entry.",
            file=sys.stderr,
        )

    if new:
        print(
            "\nRBAC check failed: new violations above are not pinned for that "
            "snapshot in\ntests/rbac-baseline.yaml.\n"
            "Fix the chart, or add the snapshot to a baseline entry with a "
            "written reason.",
            file=sys.stderr,
        )

    if changed:
        print(
            "\nRBAC check failed: the pinned grants above no longer match the "
            "render.\n"
            "An `added` line WIDENS a cluster-wide grant that was pinned as-is "
            "-- a new\nsubject, a new binding or a new write verb reaches "
            "cluster scope. Justify it\nin review before re-running "
            "--write-baseline; do not hand-edit the grant.\n"
            "A `removed` line means the grant shrank, which is the goal: "
            "re-run\n--write-baseline to re-pin it, or delete the entry if the "
            "violation is gone.",
            file=sys.stderr,
        )

    if stale:
        print(
            "\nRBAC check failed: baseline entries above no longer occur.\n"
            "Delete them from tests/rbac-baseline.yaml -- this is the expected\n"
            "outcome of a hardening phase.",
            file=sys.stderr,
        )

    if errors or new or changed or stale:
        return 1

    snapshots = {snapshot for snapshot, _, _ in violations}
    print(
        f"RBAC check passed: {len(violations)} pinned violations across "
        f"{len(snapshots)} snapshots, none new."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
