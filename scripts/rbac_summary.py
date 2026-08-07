#!/usr/bin/env python3
"""Summarise each dataplane snapshot's RBAC to roughly fifty reviewable lines.

The snapshots in tests/generated/ run to thousands of lines, so an RBAC change
lands as a diff nobody reads. Each summary shows who holds what, where, and
through which binding kind, so resolved reach, dead rules and wildcards are
legible. Nothing is asserted: the review signal is the committed summary
changing in a pull request.

RoleBindings the chart ships as strings inside the clusterresource-template
ConfigMap are applied by clusterresourcesync, not Helm; they are parsed out and
reported with reach *provisioned-at-runtime*.

Usage:
  scripts/rbac_summary.py --write    regenerate tests/rbac-summary/
  scripts/rbac_summary.py --check    fail if the committed summaries are stale
"""

import argparse
import difflib
import glob
import os
import re
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATED = os.path.join(REPO_ROOT, "tests", "generated")
SUMMARY_DIR = os.path.join(REPO_ROOT, "tests", "rbac-summary")
PATTERN = os.path.join(GENERATED, "dataplane*.yaml")

# Used only to annotate a namespaced Role's rules as dead. Incompleteness costs a
# missing annotation, never a failure.
CLUSTER_SCOPED = frozenset(
    {
        "apiservices",
        "certificatesigningrequests",
        "clusterissuers",
        "clusterrolebindings",
        "clusterroles",
        "csidrivers",
        "csinodes",
        "customresourcedefinitions",
        "flowschemas",
        "gatewayclasses",
        "ingressclasses",
        "mutatingwebhookconfigurations",
        "namespaces",
        "nodes",
        "persistentvolumes",
        "priorityclasses",
        "prioritylevelconfigurations",
        "runtimeclasses",
        "storageclasses",
        "validatingadmissionpolicies",
        "validatingwebhookconfigurations",
        "volumeattachments",
    }
)

CLUSTER = "*cluster-wide*"

# Reach of a binding clusterresourcesync applies per project/domain namespace.
# Not a legal namespace name, so it cannot be mistaken for one.
PROVISIONED = "*provisioned-at-runtime*"

# clusterresourcesync's placeholders, passed through literally by the chart.
# `{{ x }}` is not valid YAML in a value position, so swap it for a scalar first.
TEMPLATE_PLACEHOLDER = re.compile(r"\{\{\s*(.*?)\s*\}\}")
NAMESPACE_TOKEN = "__union_rbac_summary_namespace__"
OTHER_TOKEN = "__union_rbac_summary_placeholder__"


def load(path):
    with open(path) as handle:
        return [d for d in yaml.safe_load_all(handle) if isinstance(d, dict)]


def _substitute_placeholders(text):
    """Make a clusterresource-template entry parseable, keeping `{{ namespace }}` findable."""

    def swap(match):
        return NAMESPACE_TOKEN if match.group(1) == "namespace" else OTHER_TOKEN

    return TEMPLATE_PLACEHOLDER.sub(swap, text)


def embedded_bindings(docs):
    """RoleBindings carried as strings inside a ConfigMap, applied by clusterresourcesync rather than Helm."""
    out = []
    for d in docs:
        if d.get("kind") != "ConfigMap":
            continue
        for value in (d.get("data") or {}).values():
            if not isinstance(value, str) or "RoleBinding" not in value:
                continue
            try:
                parsed = yaml.safe_load(_substitute_placeholders(value))
            except Exception:
                continue
            if not isinstance(parsed, dict) or parsed.get("kind") != "RoleBinding":
                continue
            out.append(parsed)
    return out


def rule_line(rule, namespaced):
    """One rule as a single sortable line, with dead cluster-scoped grants marked."""
    groups = rule.get("apiGroups") or [""]
    resources = rule.get("resources") or []
    verbs = sorted(rule.get("verbs") or [])
    names = sorted(rule.get("resourceNames") or [])
    urls = sorted(rule.get("nonResourceURLs") or [])

    if urls:
        # nonResourceURLs are cluster-scoped by nature; a Role carrying them is dead.
        marker = " (dead)" if namespaced else ""
        return f"url {','.join(urls)}: {'*' if verbs == ['*'] else ','.join(verbs)}{marker}"

    shown_groups = "*" if "*" in groups else ",".join(sorted(g or '""' for g in groups))
    shown_resources = "*" if "*" in resources else ",".join(sorted(resources))
    shown_verbs = "*" if verbs == ["*"] else ",".join(verbs)

    marker = ""
    if namespaced and "*" not in resources:
        dead = sorted(r for r in resources if r.split("/", 1)[0] in CLUSTER_SCOPED)
        if dead:
            marker = f" (dead: {','.join(dead)})"

    line = f"{shown_groups}/{shown_resources}: {shown_verbs}"
    if names:
        line += f" [names: {','.join(names)}]"
    return line + marker


def collect(path):
    """Return {subject: {role: {"kind":..., "scopes":[...], "rules":[...]}}}."""
    docs = load(path)

    roles = {}
    for d in docs:
        kind = d.get("kind")
        if kind not in ("Role", "ClusterRole"):
            continue
        meta = d.get("metadata") or {}
        roles[(kind, meta.get("name"), meta.get("namespace"))] = d.get("rules") or []

    bindings = [
        d for d in docs if d.get("kind") in ("RoleBinding", "ClusterRoleBinding")
    ] + embedded_bindings(docs)

    out = {}
    for d in bindings:
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        ref = d.get("roleRef") or {}
        ref_kind, ref_name = ref.get("kind"), ref.get("name")
        if not ref_name:
            continue

        if kind == "ClusterRoleBinding":
            scope = CLUSTER
            rules = roles.get(("ClusterRole", ref_name, None))
        else:
            # An unqualified RoleBinding lands in the release namespace; fixtures
            # render with --namespace union.
            scope = (meta.get("namespace") or "union").strip()
            if scope == NAMESPACE_TOKEN:
                scope = PROVISIONED
            if ref_kind == "Role":
                rules = roles.get(("Role", ref_name, scope))
            else:
                rules = roles.get(("ClusterRole", ref_name, None))

        for subject in d.get("subjects") or []:
            if subject.get("kind") != "ServiceAccount":
                continue
            sa_ns = (subject.get("namespace") or "union").strip()
            if sa_ns == NAMESPACE_TOKEN:
                sa_ns = PROVISIONED
            who = f"{sa_ns}/{subject['name']}"
            entry = out.setdefault(who, {}).setdefault(
                ref_name,
                {"kind": "Role" if ref_kind == "Role" else "ClusterRole", "scopes": set(), "rules": None},
            )
            entry["scopes"].add(scope)
            # roleRefs the chart does not define (system:auth-delegator) have no
            # rules; record the binding anyway so it stays visible.
            if rules is not None and entry["rules"] is None:
                entry["rules"] = sorted(
                    {rule_line(r, namespaced=(ref_kind == "Role")) for r in rules}
                )
    return out


def render(stem, data):
    lines = [f"# {stem}", ""]
    if not data:
        lines.append("(no ServiceAccount-subject RBAC)")
        return "\n".join(lines) + "\n"

    for who in sorted(data):
        lines.append(who)
        for role in sorted(data[who]):
            entry = data[who][role]
            scopes = sorted(entry["scopes"])
            via = "ClusterRoleBinding" if CLUSTER in scopes else "RoleBinding"
            where = (
                "cluster-wide"
                if scopes == [CLUSTER]
                else ",".join(s for s in scopes if s != CLUSTER)
                + (" +cluster-wide" if CLUSTER in scopes else "")
            )
            lines.append(f"  {role}  [{entry['kind']} via {via}]  -> {where}")
            if entry["rules"] is None:
                lines.append("      (rules not defined by this chart)")
            else:
                for rule in entry["rules"]:
                    lines.append(f"      {rule}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def summaries():
    return {
        os.path.basename(f)[: -len(".yaml")]: render(
            os.path.basename(f)[: -len(".yaml")], collect(f)
        )
        for f in sorted(glob.glob(PATTERN))
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="regenerate the summaries")
    ap.add_argument("--check", action="store_true", help="fail if summaries are stale")
    args = ap.parse_args()

    current = summaries()
    if not current:
        print("no dataplane snapshots found -- run `make generate-expected` first")
        return 1

    os.makedirs(SUMMARY_DIR, exist_ok=True)

    if args.write:
        for name in os.listdir(SUMMARY_DIR):
            if name.endswith(".txt") and name[: -len(".txt")] not in current:
                os.remove(os.path.join(SUMMARY_DIR, name))
        for stem, body in current.items():
            with open(os.path.join(SUMMARY_DIR, f"{stem}.txt"), "w") as handle:
                handle.write(body)
        print(f"wrote {len(current)} RBAC summaries to tests/rbac-summary/")
        return 0

    stale = []
    for stem, body in current.items():
        path = os.path.join(SUMMARY_DIR, f"{stem}.txt")
        committed = open(path).read() if os.path.exists(path) else ""
        if committed != body:
            stale.append((stem, committed, body))
    orphaned = [
        n[: -len(".txt")]
        for n in sorted(os.listdir(SUMMARY_DIR))
        if n.endswith(".txt") and n[: -len(".txt")] not in current
    ]

    for stem, committed, body in stale:
        print(f"\n=== {stem} ===")
        for line in difflib.unified_diff(
            committed.splitlines(), body.splitlines(), "committed", "rendered", lineterm="", n=2
        ):
            print(line)
    for stem in orphaned:
        print(f"orphaned summary with no snapshot: {stem}")

    if stale or orphaned:
        print(
            f"\n{len(stale)} RBAC summary/summaries stale, {len(orphaned)} orphaned.\n"
            "The rendered RBAC changed. Read the diff above -- it is the whole point of\n"
            "this artifact -- then run `make rbac-summary` IN THE SAME COMMIT so the\n"
            "change is reviewable."
        )
        return 1

    print(f"RBAC summaries match the rendered chart across {len(current)} snapshots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
