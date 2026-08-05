#!/usr/bin/env python3
"""Namespace-aware effective-permission checker for rendered dataplane RBAC.

check_rbac.py answers "does this role object violate a structural invariant".
This answers a different and complementary question: "what can each
ServiceAccount actually DO, and where".

The distinction matters because the two most dangerous RBAC changes are
invisible to a rule-level diff:

  * A ClusterRoleBinding becoming a RoleBinding. The rules are untouched, so a
    rule-level comparison reports no change -- but the grant stops reaching
    every namespace except the binding's own. This is exactly the regression
    that shipped in d37f4a9f and reached review unnoticed.
  * A RoleBinding becoming a ClusterRoleBinding. Same rules, but now
    cluster-wide. For a read bucket that is every Secret in the cluster.

So the unit here is the triple (apiGroup, resource, verb) tagged with the
SCOPE it is reachable in: a concrete namespace, or CLUSTER for cluster-wide.

Wildcards are kept as the literal '*' rather than expanded against a resource
universe -- the render does not know the cluster's API surface, and expanding
would make the comparison depend on which CRDs happen to be installed.
Coverage is therefore checked with a subsumption test rather than set equality.
"""

import argparse
import glob
import json
import os
import sys

import yaml

CLUSTER = "\x00CLUSTER"  # sorts before any real namespace; not a legal ns name
BASELINE = "tests/rbac-effective-baseline.json"
BINDING_KINDS = ("RoleBinding", "ClusterRoleBinding")


def load_docs(path):
    return [d for d in yaml.safe_load_all(open(path)) if isinstance(d, dict)]


def rule_triples(rule):
    """Expand one rule into (apiGroup, resource, verb) triples.

    nonResourceURLs rules are emitted under a synthetic apiGroup so they are
    compared too rather than silently dropped -- the operator's /metrics grant
    was one of these, and losing it should be visible.
    """
    verbs = rule.get("verbs") or []
    urls = rule.get("nonResourceURLs") or []
    if urls:
        return {("\x00NONRESOURCE", u, v) for u in urls for v in verbs}
    groups = rule.get("apiGroups") or [""]
    resources = rule.get("resources") or []
    return {(g, r, v) for g in groups for r in resources for v in verbs}


def collect(path):
    """Map serviceAccount -> scope -> sorted list of triples, for one snapshot."""
    docs = load_docs(path)
    # ClusterRole names are cluster-unique, so they are keyed by name alone.
    # Role names are only unique per-namespace -- two Role objects can share a
    # name across namespaces with different rules -- so Role lookups are
    # additionally keyed by namespace. A RoleBinding's roleRef to a Role always
    # resolves within the binding's own namespace (a ClusterRoleBinding can
    # only reference a ClusterRole, never a Role), which is why the namespace
    # for that key can be taken from the binding once its scope is known.
    cluster_roles = {
        d["metadata"]["name"]: (d.get("rules") or [])
        for d in docs
        if d.get("kind") == "ClusterRole"
    }
    namespaced_roles = {
        (d["metadata"]["name"], d["metadata"].get("namespace") or "union"): (d.get("rules") or [])
        for d in docs
        if d.get("kind") == "Role"
    }

    out = {}
    for d in docs:
        if d.get("kind") not in BINDING_KINDS:
            continue

        if d["kind"] == "ClusterRoleBinding":
            scope = CLUSTER
        else:
            scope = (d["metadata"].get("namespace") or "").strip()
            if not scope:
                # A RoleBinding with no explicit namespace lands in the release
                # namespace at install time. Every fixture renders with
                # --namespace union, so that is what it resolves to.
                scope = "union"

        ref = d.get("roleRef") or {}
        if ref.get("kind") == "ClusterRole":
            rules = cluster_roles.get(ref.get("name"))
        elif ref.get("kind") == "Role":
            rules = namespaced_roles.get((ref.get("name"), scope))
        else:
            rules = None
        if rules is None:
            # Dangling reference, or a built-in ClusterRole this chart does not
            # define (system:auth-delegator). Not this tool's business.
            continue

        triples = set()
        for rule in rules:
            triples |= rule_triples(rule)

        for subject in d.get("subjects") or []:
            if subject.get("kind") != "ServiceAccount":
                continue
            out.setdefault(subject["name"], {}).setdefault(scope, set()).update(triples)

    return {
        sa: {scope: sorted(map(list, triples)) for scope, triples in sorted(scopes.items())}
        for sa, scopes in sorted(out.items())
    }


def collect_all(pattern="tests/generated/dataplane*.yaml"):
    return {os.path.basename(f)[:-5]: collect(f) for f in sorted(glob.glob(pattern))}


def _matches(have, want):
    """True if the triple `have` subsumes `want`, honouring '*' wildcards."""
    return all(h == w or h == "*" for h, w in zip(have, want))


def covers(after_scopes, scope, triple):
    """True if `after_scopes` grants `triple` in `scope` (or cluster-wide)."""
    candidates = list(after_scopes.get(scope, []))
    if scope != CLUSTER:
        candidates += list(after_scopes.get(CLUSTER, []))
    return any(_matches(tuple(h), tuple(triple)) for h in candidates)


def compare(before, after):
    """Yield (snapshot, sa, scope, triple, direction) for every difference."""
    for snap in sorted(set(before) | set(after)):
        b, a = before.get(snap, {}), after.get(snap, {})
        for sa in sorted(set(b) | set(a)):
            b_scopes, a_scopes = b.get(sa, {}), a.get(sa, {})
            for scope, triples in sorted(b_scopes.items()):
                for triple in triples:
                    if not covers(a_scopes, scope, triple):
                        yield snap, sa, scope, triple, "LOST"
            for scope, triples in sorted(a_scopes.items()):
                for triple in triples:
                    if not covers(b_scopes, scope, triple):
                        yield snap, sa, scope, triple, "GAINED"


def fmt(scope):
    return "CLUSTER-WIDE" if scope == CLUSTER else f"ns={scope}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="write the baseline")
    ap.add_argument(
        "--allow-gained",
        action="store_true",
        help="do not fail on newly GAINED grants (use when a task intentionally adds reach)",
    )
    args = ap.parse_args()

    current = collect_all()
    if not current:
        print("no dataplane snapshots found -- run `make generate-expected` first")
        return 1

    if args.write:
        with open(BASELINE, "w") as fh:
            json.dump(current, fh, indent=1, sort_keys=True)
            fh.write("\n")
        sas = sum(len(v) for v in current.values())
        print(f"wrote {BASELINE}: {len(current)} snapshots, {sas} serviceaccount entries")
        return 0

    if not os.path.exists(BASELINE):
        print(f"{BASELINE} missing -- run `make rbac-effective-baseline`")
        return 1

    baseline = json.load(open(BASELINE))
    diffs = list(compare(baseline, current))
    lost = [d for d in diffs if d[4] == "LOST"]
    gained = [d for d in diffs if d[4] == "GAINED"]

    for snap, sa, scope, triple, direction in diffs:
        group, resource, verb = triple
        print(f"{direction:6} {snap:44} sa={sa:26} {fmt(scope):22} {group or '(core)'}/{resource}:{verb}")

    if lost:
        print(
            f"\n{len(lost)} grant(s) LOST. A ServiceAccount can no longer do something it\n"
            "could before, in some namespace. If that is intended, re-baseline with\n"
            "`make rbac-effective-baseline` IN THE SAME COMMIT and say why in the\n"
            "commit message."
        )
    if gained and not args.allow_gained:
        print(f"\n{len(gained)} grant(s) GAINED. Re-baseline in the same commit if intended.")

    if lost or (gained and not args.allow_gained):
        return 1
    print(f"effective permissions unchanged across {len(current)} snapshots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
