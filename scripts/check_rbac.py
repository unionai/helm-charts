#!/usr/bin/env python3
"""Enforce RBAC invariants on the rendered dataplane chart.

Two invariants, both evaluated against the committed renders in
tests/generated/ (which `make helm-test` already proves match a fresh render):

  cluster_write          No ClusterRoleBinding may reference a role that
                         contains write verbs. A ClusterRole is inert on its
                         own; only a ClusterRoleBinding makes it cluster-wide.

  low_priv_cluster_role  No ClusterRole objects may render when the fixture
                         sets low_privilege true (the chart default).

Known violations are pinned in tests/rbac-baseline.yaml. The check fails when a
violation appears that is not in the baseline. Each hardening phase deletes
entries from the baseline; nothing may ever be added without a written reason.

Usage:
    python3 scripts/check_rbac.py
    python3 scripts/check_rbac.py --write-baseline
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
    """Rules a role grants, resolving aggregationRule against the render.

    An aggregating ClusterRole carries no rules of its own -- the API server
    fills them in from every ClusterRole matching its selectors. Ignoring this
    would let a write-bearing role reach cluster scope through an aggregation
    shell, which is exactly how knative-operator is wired.
    """
    rules = list(role.get("rules") or [])
    aggregation = role.get("aggregationRule") or {}
    for selector in aggregation.get("clusterRoleSelectors") or []:
        match_labels = selector.get("matchLabels") or {}
        if not match_labels:
            continue
        for candidate in roles_by_name.values():
            if candidate is role or candidate.get("kind") != "ClusterRole":
                continue
            candidate_labels = (candidate.get("metadata") or {}).get("labels") or {}
            if labels_match(match_labels, candidate_labels):
                rules.extend(candidate.get("rules") or [])
    return rules


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
        if any(is_write_rule(rule) for rule in effective_rules(role, roles_by_name)):
            record(ref_name, CLUSTER_WRITE)

    return violations


def collect_all_violations():
    """Aggregate violations across every dataplane snapshot."""
    combined = {}
    for path in sorted(GENERATED_DIR.glob("dataplane*.yaml")):
        stem = path.stem
        docs = list(load_documents(path))
        found = find_violations(docs, fixture_is_low_privilege(stem))
        for name, invariants in found.items():
            combined.setdefault(name, set()).update(invariants)
    return combined


def load_baseline():
    if not BASELINE_PATH.exists():
        return {}
    with BASELINE_PATH.open() as handle:
        data = yaml.safe_load(handle) or {}
    return {
        entry["name"]: set(entry.get("invariants") or [])
        for entry in data.get("allowed") or []
    }


def write_baseline(violations):
    entries = [
        {
            "name": name,
            "invariants": sorted(invariants),
            "reason": "TODO: justify or remove this entry",
        }
        for name, invariants in sorted(violations.items())
    ]
    header = (
        "# Pinned RBAC violations. Generated by scripts/check_rbac.py\n"
        "# --write-baseline, then edited by hand to add a reason per entry.\n"
        "#\n"
        "# Every hardening phase DELETES entries from this file. Adding an\n"
        "# entry means accepting a cluster-wide privilege, so it needs a\n"
        "# written justification in review.\n"
        "#\n"
        "# invariants:\n"
        "#   cluster_write          a ClusterRoleBinding references this role\n"
        "#                          and it contains write verbs\n"
        "#   low_priv_cluster_role  this ClusterRole renders when\n"
        "#                          low_privilege is true\n"
    )
    with BASELINE_PATH.open("w") as handle:
        handle.write(header)
        yaml.safe_dump({"allowed": entries}, handle, default_flow_style=False, sort_keys=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="overwrite tests/rbac-baseline.yaml with the current violations",
    )
    args = parser.parse_args()

    violations = collect_all_violations()

    if args.write_baseline:
        write_baseline(violations)
        print(f"Wrote {len(violations)} entries to {BASELINE_PATH.relative_to(REPO_ROOT)}")
        return 0

    baseline = load_baseline()

    new = {}
    for name, invariants in violations.items():
        unexpected = invariants - baseline.get(name, set())
        if unexpected:
            new[name] = unexpected

    stale = {}
    for name, invariants in baseline.items():
        resolved = invariants - violations.get(name, set())
        if resolved:
            stale[name] = resolved

    for name, invariants in sorted(new.items()):
        for invariant in sorted(invariants):
            print(f"NEW VIOLATION  {invariant:22} {name}", file=sys.stderr)

    for name, invariants in sorted(stale.items()):
        for invariant in sorted(invariants):
            print(f"STALE BASELINE {invariant:22} {name}", file=sys.stderr)

    if new:
        print(
            "\nRBAC check failed: new violations above are not in "
            "tests/rbac-baseline.yaml.\n"
            "Fix the chart, or add a baseline entry with a written reason.",
            file=sys.stderr,
        )
        return 1

    if stale:
        print(
            "\nRBAC check failed: baseline entries above no longer occur.\n"
            "Delete them from tests/rbac-baseline.yaml -- this is the expected\n"
            "outcome of a hardening phase.",
            file=sys.stderr,
        )
        return 1

    print(f"RBAC check passed: {len(violations)} known violations, none new.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
