#!/usr/bin/env python3
"""Enforce RBAC invariants on the rendered dataplane chart.

Two invariants, both evaluated against the committed renders in
tests/generated/ (which `make helm-test` already proves match a fresh render):

  cluster_write          No ClusterRoleBinding may reference a role that
                         contains write verbs. A ClusterRole is inert on its
                         own; only a ClusterRoleBinding makes it cluster-wide.

  low_priv_cluster_role  No ClusterRole objects may render when the fixture
                         sets low_privilege true (the chart default).

Known violations are pinned in tests/rbac-baseline.yaml, keyed by the triple
(snapshot, role name, invariant). A pinned entry allows the violation in the
snapshots it names and nowhere else, so reintroducing a cluster-wide grant in a
render that did not have it is still caught even when the same role name is
legitimately pinned elsewhere.

The check fails on any of:

  new violation     it occurs in a snapshot it is not pinned for;
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
justified by hand.
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

TODO_REASON = "TODO: justify or remove this entry"

# aggregationRule.clusterRoleSelectors[] keys this script knows how to evaluate.
# Anything else (matchExpressions today) makes the selector unresolvable.
RESOLVABLE_SELECTOR_KEYS = {"matchLabels"}


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


def effective_rules(role, roles_by_name):
    """Return (rules, unresolved) for a role, resolving its aggregationRule.

    An aggregating ClusterRole carries no rules of its own -- the API server
    fills them in from every ClusterRole matching its selectors. Ignoring that
    would let a write-bearing role reach cluster scope through an aggregation
    shell, so the selectors are resolved against the rest of the render. This
    path is live: `knative-serving-admin` has zero rules of its own and fifteen
    aggregated ones, several of them writes.

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
    aggregation = role.get("aggregationRule") or {}
    for selector in aggregation.get("clusterRoleSelectors") or []:
        selector = selector or {}
        match_labels = selector.get("matchLabels") or {}
        if set(selector) - RESOLVABLE_SELECTOR_KEYS or not match_labels:
            unresolved = True
            continue
        for candidate in roles_by_name.values():
            if candidate is role or candidate.get("kind") != "ClusterRole":
                continue
            candidate_labels = (candidate.get("metadata") or {}).get("labels") or {}
            if labels_match(match_labels, candidate_labels):
                rules.extend(candidate.get("rules") or [])
    return rules, unresolved


def fixture_is_low_privilege(stem):
    """Read low_privilege from the fixture. The chart default is true."""
    values_path = VALUES_DIR / f"{stem}.yaml"
    if not values_path.exists():
        return True
    with values_path.open() as handle:
        values = yaml.safe_load(handle) or {}
    return bool(values.get("low_privilege", True))


def find_violations(docs, low_privilege):
    """Return {role_name: {invariant, ...}} for one rendered snapshot."""
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

    def record(name, invariant):
        violations.setdefault(name, set()).add(invariant)

    if low_privilege:
        for (kind, name) in roles_by_name:
            if kind == "ClusterRole":
                record(name, LOW_PRIV_CLUSTER_ROLE)

    for binding in bindings:
        role_ref = binding.get("roleRef") or {}
        ref_name = role_ref.get("name")
        if not ref_name:
            continue
        role = roles_by_name.get((role_ref.get("kind"), ref_name))
        if role is None:
            # A roleRef we cannot resolve is a built-in cluster role (for
            # example system:auth-delegator). We cannot read its rules, so we
            # cannot prove it is read-only. Treat it as a violation requiring
            # an explicit baseline entry.
            record(ref_name, CLUSTER_WRITE)
            continue
        rules, unresolved = effective_rules(role, roles_by_name)
        # `unresolved` first: an aggregation selector we cannot evaluate means
        # the rule set is unknown, so the role is presumed write-bearing.
        if unresolved or any(is_write_rule(rule) for rule in rules):
            record(ref_name, CLUSTER_WRITE)

    return violations


def collect_all_violations():
    """Return {(snapshot, name, invariant)} across every dataplane snapshot."""
    violations = set()
    for path in sorted(GENERATED_DIR.glob("dataplane*.yaml")):
        stem = path.stem
        docs = list(load_documents(path))
        found = find_violations(docs, fixture_is_low_privilege(stem))
        for name, invariants in found.items():
            for invariant in invariants:
                violations.add((stem, name, invariant))
    return violations


def load_baseline():
    """Return ({(snapshot, name, invariant): reason}, [schema error, ...])."""
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
        label = f"allowed[{index}] {name or '<no name>'} / {invariant or '<no invariant>'}"

        if not name or not invariant or not snapshots:
            errors.append(f"{label}: needs a name, an invariant and a non-empty snapshots list")
            continue
        if not reason or reason.startswith("TODO"):
            errors.append(
                f"{label}: reason is missing, empty or still the TODO placeholder"
            )
        for snapshot in snapshots:
            key = (snapshot, name, invariant)
            if key in baseline:
                errors.append(f"{label}: pinned twice for snapshot {snapshot}")
            baseline[key] = reason

    return baseline, errors


HEADER = """\
# Pinned RBAC violations. Generated by scripts/check_rbac.py
# --write-baseline, then edited by hand to add a reason per entry.
#
# Every hardening phase DELETES entries from this file. Adding an
# entry means accepting a cluster-wide privilege, so it needs a
# written justification in review.
#
# Schema -- one entry per (name, invariant, reason):
#
#   - name: union-executor        the RBAC object the violation is about
#     invariant: cluster_write    exactly one invariant per entry
#     reason: ...                 why this is accepted, and which phase owns it
#     snapshots:                  tests/generated/<snapshot>.yaml renders it
#     - dataplane.namespace-multi is pinned in -- and ONLY those
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
# invariants:
#   cluster_write          a ClusterRoleBinding references this role and it
#                          contains write verbs -- or its aggregationRule
#                          uses a selector form the checker cannot evaluate,
#                          in which case it fails closed and reports here
#   low_priv_cluster_role  this ClusterRole renders when
#                          low_privilege is true
"""


def write_baseline(violations, existing):
    """Rewrite the baseline, carrying existing reasons forward by key."""
    grouped = {}
    for snapshot, name, invariant in violations:
        reason = existing.get((snapshot, name, invariant)) or TODO_REASON
        grouped.setdefault((name, invariant, reason), []).append(snapshot)

    entries = [
        {
            "name": name,
            "invariant": invariant,
            "reason": reason,
            "snapshots": sorted(snapshots),
        }
        for (name, invariant, reason), snapshots in sorted(
            grouped.items(), key=lambda item: (item[0][0], item[0][1], sorted(item[1]))
        )
    ]

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

    new = sorted(violations - set(baseline), key=sort_key)
    stale = sorted(set(baseline) - violations, key=sort_key)

    for message in errors:
        print(f"BASELINE ERROR {message}", file=sys.stderr)

    for snapshot, name, invariant in new:
        print(f"NEW VIOLATION  {invariant:22} {name}  [{snapshot}]", file=sys.stderr)

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

    if stale:
        print(
            "\nRBAC check failed: baseline entries above no longer occur.\n"
            "Delete them from tests/rbac-baseline.yaml -- this is the expected\n"
            "outcome of a hardening phase.",
            file=sys.stderr,
        )

    if errors or new or stale:
        return 1

    snapshots = {snapshot for snapshot, _, _ in violations}
    print(
        f"RBAC check passed: {len(violations)} pinned violations across "
        f"{len(snapshots)} snapshots, none new."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
