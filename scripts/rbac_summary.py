#!/usr/bin/env python3
"""Summarise each dataplane snapshot's RBAC to roughly fifty reviewable lines.

The snapshots in tests/generated/ run to thousands of lines, so an RBAC change
is easy to miss in review. Each summary shows who has what access, where, through
which binding kind, and which chart wrote it. The primary review signal is the
committed summary changing in a pull request.

Three things are asserted outright, because each of them has already shipped a
bug that a diff alone did not stop:

  - every ServiceAccount subject in a binding resolves to a ServiceAccount in the
    same render. kube-state-metrics spent three months bound to a name that never
    existed, visible in 24 committed summaries the whole time.
  - the set of cluster-scoped RBAC objects written by dependency subcharts matches
    ALLOWED_THIRD_PARTY_CLUSTER_SCOPED below. A subchart bump that adds a
    ClusterRole fails here instead of shipping unremarked.
  - no namespaced Role names a cluster-scoped resource. templates/_rbac.tpl
    already fails on this for union components, but only for rules routed through
    dataplane.rbac.emitSlot; templates/prometheus/rbac.yaml sat outside it and
    carried a dead `nodes` grant for months. Checking the rendered output catches
    it whatever emitted it.

RoleBindings the chart ships as strings inside the clusterresource-template
ConfigMap are applied by clusterresourcesync, not Helm. They are parsed out and
reported as *provisioned-at-runtime*.

Usage:
  scripts/rbac_summary.py --write    regenerate tests/rbac-summary/
  scripts/rbac_summary.py --check    fail if the summaries are stale or a check trips
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

# Resources a namespaced Role can name but never match. The API server accepts
# such a rule and silently never applies it, so it reads as a granted permission
# and behaves as a denied one. If this list is incomplete a dead rule is missed;
# nothing here invents a failure.
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

# `namespaces` is the one cluster-scoped resource a namespaced Role partly
# conveys: a Role in namespace X does authorize `get namespaces/X`, because the
# namespace is its own scoping object. Verified against a live cluster. Only the
# collection verbs are dead, so it is checked separately rather than listed above.
NAMESPACE_LIVE_VERBS = frozenset({"get"})

# Cluster-scoped RBAC written by dependency subcharts, as `<chart> <Kind> <name>`.
# Renders use helm's default release name, so the names are literal.
#
# This is an exact set: an object appearing that is not listed fails, and a listed
# object that no fixture renders any more fails as stale. Both directions matter —
# the point is that the disposition recorded in charts/dataplane/values.yaml under
# `thirdPartyRbac` and what the charts actually emit cannot drift apart quietly.
ALLOWED_THIRD_PARTY_CLUSTER_SCOPED = frozenset(
    {
        # Read-only scrape permissions. Cluster scope is forced by the cadvisor
        # job, which discovers with `role: node` and fetches through the node proxy.
        "prometheus ClusterRole union-operator-prometheus",
        "prometheus ClusterRoleBinding union-operator-prometheus",
        # Six collectors, list/watch only. `nodes` and `namespaces` are
        # cluster-scoped, so a namespaced Role cannot serve them.
        "kube-state-metrics ClusterRole release-name-kube-state-metrics",
        "kube-state-metrics ClusterRoleBinding release-name-kube-state-metrics",
        # opencost prices the whole cluster; read-only, and no key narrows it.
        "opencost ClusterRole release-name-opencost",
        "opencost ClusterRoleBinding release-name-opencost",
        # metrics-server is structurally cluster-scoped: rbac.create: false leaves
        # it unable to authenticate.
        "metrics-server ClusterRole system:metrics-server-aggregated-reader",
        "metrics-server ClusterRole system:release-name-metrics-server",
        "metrics-server ClusterRoleBinding release-name-metrics-server:system:auth-delegator",
        "metrics-server ClusterRoleBinding system:release-name-metrics-server",
        # knative-operator: deprecated, superseded by the vendored gateway.
        "knative-operator ClusterRole knative-eventing-operator",
        "knative-operator ClusterRole knative-eventing-operator-aggregated",
        "knative-operator ClusterRole knative-eventing-operator-aggregated-stable",
        "knative-operator ClusterRole knative-operator-webhook",
        "knative-operator ClusterRole knative-serving-operator",
        "knative-operator ClusterRole knative-serving-operator-aggregated",
        "knative-operator ClusterRole knative-serving-operator-aggregated-stable",
        "knative-operator ClusterRoleBinding knative-eventing-operator",
        "knative-operator ClusterRoleBinding knative-eventing-operator-aggregated",
        "knative-operator ClusterRoleBinding knative-eventing-operator-aggregated-stable",
        "knative-operator ClusterRoleBinding knative-serving-operator",
        "knative-operator ClusterRoleBinding knative-serving-operator-aggregated",
        "knative-operator ClusterRoleBinding knative-serving-operator-aggregated-stable",
        "knative-operator ClusterRoleBinding operator-webhook",
        # kube-prometheus-stack, off in every values layer and deprecating. Its
        # operator holds cluster-wide `secrets: '*'` and no values key removes it.
        "monitoring ClusterRole monitoring-admission",
        "monitoring ClusterRole monitoring-operator",
        "monitoring ClusterRole monitoring-prometheus",
        "monitoring ClusterRoleBinding monitoring-admission",
        "monitoring ClusterRoleBinding monitoring-operator",
        "monitoring ClusterRoleBinding monitoring-prometheus",
        "kube-state-metrics ClusterRole monitoring-kube-state-metrics",
        "kube-state-metrics ClusterRoleBinding monitoring-kube-state-metrics",
        "grafana ClusterRole release-name-grafana-clusterrole",
        "grafana ClusterRoleBinding release-name-grafana-clusterrolebinding",
    }
)

# ServiceAccount subjects that are expected not to resolve inside the render, as
# `<namespace>/<name>`. Empty: every subject the chart binds today is a
# ServiceAccount the same render creates. Anything added here needs a reason —
# an unresolvable subject is a binding that grants nothing.
ALLOWED_EXTERNAL_SUBJECTS = frozenset()

# Namespaced Roles allowed to carry a cluster-scoped resource, as
# `<chart> <role> <resource>`. Each entry is a rule that is dead as rendered and
# that we are not in a position to remove.
ALLOWED_DEAD_ROLE_RULES = {
    # ingress-nginx puts `ingressclasses` in the namespaced Role its own
    # rbac.scope: true produces. Upstream's file, not reachable from values, so
    # the alternative to accepting it is forking the subchart. The controller is
    # given --controller-class and --ingress-class explicitly, so it does not
    # depend on discovering the IngressClass object to know what it serves.
    "ingress-nginx dataplane-nginx ingressclasses",
}

CLUSTER = "*cluster-wide*"

# Marks a binding clusterresourcesync applies per project/domain namespace. Not a
# legal namespace name, so it cannot be mistaken for one.
PROVISIONED = "*provisioned-at-runtime*"

# clusterresourcesync's placeholders, passed through literally by the chart.
# `{{ x }}` is not valid YAML in a value position, so swap it for a scalar first.
TEMPLATE_PLACEHOLDER = re.compile(r"\{\{\s*(.*?)\s*\}\}")
NAMESPACE_TOKEN = "__union_rbac_summary_namespace__"
OTHER_TOKEN = "__union_rbac_summary_placeholder__"


UNION = "union"


def owning_chart(source):
    """The chart that wrote an object, from helm's `# Source:` path.

    `dataplane/templates/...` is ours. `dataplane/charts/<c>/templates/...` is the
    subchart's; the last `charts/<c>` segment wins, so a grandchild like
    prometheus' bundled kube-state-metrics is attributed to itself rather than to
    its parent.
    """
    if not source:
        return None
    parts = source.split("/")
    nested = [i for i, part in enumerate(parts) if part == "charts"]
    if nested and nested[-1] + 1 < len(parts):
        return parts[nested[-1] + 1]
    return UNION


def load(path):
    """Documents paired with the chart that wrote each one.

    helm emits `# Source:` once per template file, so a file rendering several
    documents repeats it only at the top; each document takes the most recent one
    at or above its first line. The comment is always at column 0, which keeps
    the same string appearing inside an embedded ConfigMap from being mistaken
    for it.
    """
    text = open(path).read()

    source_at_line, current = [], None
    for line in text.split("\n"):
        if line.startswith("# Source:"):
            current = line[len("# Source:") :].strip()
        source_at_line.append(current)

    out = []
    for node, value in zip(yaml.compose_all(text), yaml.safe_load_all(text)):
        if not isinstance(value, dict):
            continue
        line = min(node.start_mark.line, len(source_at_line) - 1)
        out.append((value, owning_chart(source_at_line[line])))
    return out


def _substitute_placeholders(text):
    """Make a clusterresource-template entry parseable, keeping `{{ namespace }}` findable."""

    def swap(match):
        return NAMESPACE_TOKEN if match.group(1) == "namespace" else OTHER_TOKEN

    return TEMPLATE_PLACEHOLDER.sub(swap, text)


def embedded_bindings(docs):
    """RoleBindings carried as strings inside a ConfigMap, applied by clusterresourcesync rather than Helm."""
    out = []
    for d, _chart in docs:
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
            out.append((parsed, UNION))
    return out


def dead_resources(rule):
    """Resources in a namespaced Role's rule that the API server will never match."""
    resources = rule.get("resources") or []
    if "*" in resources:
        return []
    verbs = set(rule.get("verbs") or [])
    dead = [r for r in resources if r.split("/", 1)[0] in CLUSTER_SCOPED]
    # A Role in namespace X does authorize `get namespaces/X`; only the verbs that
    # range over the collection are dead.
    if "namespaces" in resources and verbs - NAMESPACE_LIVE_VERBS:
        dead.append("namespaces")
    return sorted(dead)


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
    if namespaced:
        dead = dead_resources(rule)
        if dead:
            marker = f" (dead: {','.join(dead)})"

    line = f"{shown_groups}/{shown_resources}: {shown_verbs}"
    if names:
        line += f" [names: {','.join(names)}]"
    return line + marker


def collect(path):
    """Return {subject: {role: {"kind":..., "chart":..., "scopes":[...], "rules":[...]}}}."""
    docs = load(path)

    roles = {}
    for d, chart in docs:
        kind = d.get("kind")
        if kind not in ("Role", "ClusterRole"):
            continue
        meta = d.get("metadata") or {}
        roles[(kind, meta.get("name"), meta.get("namespace"))] = (
            d.get("rules") or [],
            chart,
        )

    bindings = [
        (d, chart)
        for d, chart in docs
        if d.get("kind") in ("RoleBinding", "ClusterRoleBinding")
    ] + embedded_bindings(docs)

    out = {}
    for d, binding_chart in bindings:
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        ref = d.get("roleRef") or {}
        ref_kind, ref_name = ref.get("kind"), ref.get("name")
        if not ref_name:
            continue

        if kind == "ClusterRoleBinding":
            scope = CLUSTER
            role = roles.get(("ClusterRole", ref_name, None))
        else:
            # An unqualified RoleBinding lands in the release namespace; fixtures
            # render with --namespace union.
            scope = (meta.get("namespace") or "union").strip()
            if scope == NAMESPACE_TOKEN:
                scope = PROVISIONED
            if ref_kind == "Role":
                role = roles.get(("Role", ref_name, scope))
            else:
                role = roles.get(("ClusterRole", ref_name, None))
        rules, role_chart = role if role else (None, None)

        for subject in d.get("subjects") or []:
            if subject.get("kind") != "ServiceAccount":
                continue
            sa_ns = (subject.get("namespace") or "union").strip()
            if sa_ns == NAMESPACE_TOKEN:
                sa_ns = PROVISIONED
            who = f"{sa_ns}/{subject['name']}"
            entry = out.setdefault(who, {}).setdefault(
                ref_name,
                {
                    "kind": "Role" if ref_kind == "Role" else "ClusterRole",
                    "chart": role_chart or binding_chart,
                    "scopes": set(),
                    "rules": None,
                },
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
            chart = entry["chart"] or "?"
            lines.append(
                f"  {role}  [{entry['kind']} via {via}, from {chart}]  -> {where}"
            )
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


def unresolved_subjects(docs):
    """Binding subjects naming a ServiceAccount no document in the render creates.

    Such a binding grants nothing. Nothing reports it — not helm, not the API
    server, not ArgoCD — and the component simply behaves as if unauthorized.
    Bindings inside the clusterresource-template ConfigMap are skipped: their
    namespace is a placeholder resolved by clusterresourcesync at apply time.
    """
    accounts = {
        ((d["metadata"].get("namespace") or "union").strip(), d["metadata"]["name"])
        for d, _ in docs
        if d.get("kind") == "ServiceAccount" and d.get("metadata", {}).get("name")
    }
    out = set()
    for d, _ in docs:
        if d.get("kind") not in ("RoleBinding", "ClusterRoleBinding"):
            continue
        for subject in d.get("subjects") or []:
            if subject.get("kind") != "ServiceAccount":
                continue
            key = ((subject.get("namespace") or "union").strip(), subject["name"])
            if key in accounts or f"{key[0]}/{key[1]}" in ALLOWED_EXTERNAL_SUBJECTS:
                continue
            out.add(f"{key[0]}/{key[1]} <- {d['kind']}/{d['metadata']['name']}")
    return out


def third_party_cluster_scoped(docs):
    """`<chart> <Kind> <name>` for every cluster-scoped RBAC object a subchart wrote."""
    return {
        f"{chart} {d['kind']} {d['metadata']['name']}"
        for d, chart in docs
        if d.get("kind") in ("ClusterRole", "ClusterRoleBinding")
        and chart not in (None, UNION)
    }


def dead_role_rules(docs):
    """`<chart> <role> <resource>` for cluster-scoped resources named in a Role."""
    out = set()
    for d, chart in docs:
        if d.get("kind") != "Role":
            continue
        name = d.get("metadata", {}).get("name")
        for rule in d.get("rules") or []:
            for resource in dead_resources(rule):
                entry = f"{chart} {name} {resource}"
                if entry not in ALLOWED_DEAD_ROLE_RULES:
                    out.add(entry)
            if rule.get("nonResourceURLs"):
                out.add(f"{chart} {name} url:{','.join(rule['nonResourceURLs'])}")
    return out


def run_checks():
    """The three assertions. Returns a list of failure paragraphs."""
    phantom, dead, seen_cluster_scoped = {}, {}, set()
    for path in sorted(glob.glob(PATTERN)):
        stem = os.path.basename(path)[: -len(".yaml")]
        docs = load(path)
        seen_cluster_scoped |= third_party_cluster_scoped(docs)
        for item in unresolved_subjects(docs):
            phantom.setdefault(item, []).append(stem)
        for item in dead_role_rules(docs):
            dead.setdefault(item, []).append(stem)

    failures = []

    if phantom:
        body = "\n".join(
            f"  {item}   ({len(f)} fixture(s), e.g. {f[0]})"
            for item, f in sorted(phantom.items())
        )
        failures.append(
            "Binding subjects that resolve to no ServiceAccount in the same render:\n"
            f"{body}\n"
            "Such a binding grants nothing and reports nothing. Fix the name, or --\n"
            "if the ServiceAccount really is created outside this chart -- add it to\n"
            "ALLOWED_EXTERNAL_SUBJECTS in scripts/rbac_summary.py with a reason."
        )

    unexpected = sorted(seen_cluster_scoped - ALLOWED_THIRD_PARTY_CLUSTER_SCOPED)
    if unexpected:
        failures.append(
            "Cluster-scoped RBAC from a dependency subchart that is not on the\n"
            "allowlist:\n" + "\n".join(f"  {item}" for item in unexpected) + "\n"
            "Either narrow it through the subchart's values -- see `thirdPartyRbac`\n"
            "in charts/dataplane/values.yaml for what each one is permitted to hold --\n"
            "or add it to ALLOWED_THIRD_PARTY_CLUSTER_SCOPED with the reason it is\n"
            "acceptable, and record the disposition in values.yaml too."
        )

    missing = sorted(ALLOWED_THIRD_PARTY_CLUSTER_SCOPED - seen_cluster_scoped)
    if missing:
        failures.append(
            "ALLOWED_THIRD_PARTY_CLUSTER_SCOPED lists objects no fixture renders any\n"
            "more:\n" + "\n".join(f"  {item}" for item in missing) + "\n"
            "If the grant is gone, drop the entry. If a fixture that covered it was\n"
            "removed, restore the coverage -- an allowlist nothing exercises is not a\n"
            "control."
        )

    if dead:
        body = "\n".join(
            f"  {item}   ({len(f)} fixture(s), e.g. {f[0]})"
            for item, f in sorted(dead.items())
        )
        failures.append(
            "Namespaced Roles naming cluster-scoped resources:\n"
            f"{body}\n"
            "The API server accepts these rules and never matches them, so the grant\n"
            "reads as present and behaves as absent. Move the rule to a ClusterRole,\n"
            "or drop it."
        )

    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="regenerate the summaries")
    ap.add_argument(
        "--check",
        action="store_true",
        help="fail if the summaries are stale or a check trips",
    )
    args = ap.parse_args()

    current = summaries()
    if not current:
        print("no dataplane snapshots in tests/generated/ -- run `make generate-expected` first")
        return 1

    os.makedirs(SUMMARY_DIR, exist_ok=True)

    failures = run_checks()

    if args.write:
        # Write first, then report. A failing check still leaves usable summaries
        # to look at, which is usually where the answer is.
        for name in os.listdir(SUMMARY_DIR):
            if name.endswith(".txt") and name[: -len(".txt")] not in current:
                os.remove(os.path.join(SUMMARY_DIR, name))
        for stem, body in current.items():
            with open(os.path.join(SUMMARY_DIR, f"{stem}.txt"), "w") as handle:
                handle.write(body)
        print(f"wrote {len(current)} RBAC summaries to tests/rbac-summary/")
        for failure in failures:
            print(f"\n{failure}")
        return 1 if failures else 0

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
        print(f"tests/rbac-summary/{stem}.txt has no matching snapshot in tests/generated/")

    if stale or orphaned:
        print(
            f"\n{len(stale)} RBAC summary/summaries stale, {len(orphaned)} orphaned.\n"
            "The rendered RBAC changed. Read the diff above -- seeing it is the point of\n"
            "this artifact -- then run `make rbac-summary` and commit the updated summaries\n"
            "together with the change that moved them, so the change is reviewable."
        )

    for failure in failures:
        print(f"\n{failure}")

    if stale or orphaned or failures:
        return 1

    print(
        f"RBAC summaries match the rendered chart across {len(current)} snapshots, "
        "and all subjects resolve"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
