#!/usr/bin/env python3
"""Enforce RBAC invariants on the rendered dataplane chart.

Six invariants, all evaluated against the committed renders in
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

  ns_role_cluster_bound_when_restricted
                         An ns-read or ns-write bucket role may not be
                         referenced by a ClusterRoleBinding IN A RENDER THAT
                         HAS OPTED OUT of cluster-wide bindings. Those buckets
                         hold namespaced resource types; when an operator sets
                         rbac.clusterWideBindings: false they have asked for
                         reach to be named per namespace, and a surviving
                         ClusterRoleBinding silently returns cluster-wide reach
                         -- for ns-read that is every Secret in the cluster.

                         It is NOT an error by default: task namespaces are
                         created at runtime, so the chart cannot enumerate them
                         and the cluster-wide binding is load-bearing. Making
                         this unconditional is what broke multi-namespace
                         dataplanes in d37f4a9f.

  low_priv_union_cluster_role
                         A union-authored, non-hook ClusterRole may not render
                         under low_privilege: true. Has NO baseline: a
                         cluster-scoped grant that cannot survive namespacing
                         means the COMPONENT must be gated, not its rules
                         degraded into something inert.

  ns_role_missing_from_bind_list
                         Every rendered ns-read / ns-write bucket ClusterRole
                         must appear in the resourceNames of some union-
                         authored `bind` grant on `clusterroles` (the grant
                         clusterresourcesync holds so it can create
                         RoleBindings referencing those roles without an
                         escalation check failure). Has NO baseline: the `bind`
                         list is DERIVED (dataplane.rbac.bucketRoleNames,
                         itself derived from dataplane.rbac.identities), so if
                         it and the roleName helper it derives from ever fall
                         out of step -- e.g. a future refactor of the identity
                         helpers -- the drift is invisible at render time and
                         surfaces only as a runtime `Forbidden` when a
                         provisioner tries to bind a role that exists but was
                         never named. This is the dangerous direction: the
                         reverse (a resourceNames entry naming a role that
                         never renders) is an inert no-op, because nothing can
                         bind a role that does not exist, and is deliberately
                         NOT checked here.

                         Scoped to union-authored roles only (is_union_role):
                         evaluated unscoped, this would also match vendored
                         subcharts' own `bind` rules (knative-serving-operator
                         ships one), which name their own ClusterRoles and
                         have nothing to do with this chart's ns-* buckets.

                         Only fires in a render that has a union `bind` grant
                         at all (clusterresourcesync enabled and not
                         singleNamespace); a render with no such grant asserts
                         nothing about which roles a provisioner can bind, so
                         there is nothing to check.

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
import itertools
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATED_DIR = REPO_ROOT / "tests" / "generated"
VALUES_DIR = REPO_ROOT / "tests" / "values"
CHARTS_DIR = REPO_ROOT / "charts"
BASELINE_PATH = REPO_ROOT / "tests" / "rbac-baseline.yaml"

READ_VERBS = {"get", "list", "watch"}

CLUSTER_WRITE = "cluster_write"
LOW_PRIV_CLUSTER_ROLE = "low_priv_cluster_role"
DEAD_CLUSTER_RULE = "dead_cluster_rule"
NS_ROLE_CLUSTER_BOUND_WHEN_RESTRICTED = "ns_role_cluster_bound_when_restricted"
LOW_PRIV_UNION_CLUSTER_ROLE = "low_priv_union_cluster_role"
NS_ROLE_MISSING_FROM_BIND_LIST = "ns_role_missing_from_bind_list"

# Invariants with NO baseline: a violation here is always a bug, never an
# accepted tradeoff, so it cannot be pinned via tests/rbac-baseline.yaml.
# --write-baseline strips these out before writing, and the normal check
# reports them as FORBIDDEN regardless of what the baseline says.
HARD_FAIL_INVARIANTS = frozenset({LOW_PRIV_UNION_CLUSTER_ROLE, NS_ROLE_MISSING_FROM_BIND_LIST})

# The `bind` grant this chart emits so clusterresourcesync can create
# RoleBindings referencing union ns-* ClusterRoles (see
# clusterresourcesync/serviceaccount.yaml). Matching on resource + verb, not
# apiGroup, mirrors is_write_rule/dead_cluster_resources elsewhere in this
# script: a rule's apiGroups list is not consulted for matching purposes.
BIND_RESOURCE = "clusterroles"
BIND_VERB = "bind"

# Bucket suffixes the scope x verb RBAC emitter can produce
# (dataplane.rbac.roleName: {release-namespace}-{identity}-{bucket}).
# NAMESPACED_BUCKET_SUFFIXES denotes namespaced resource types, for the
# cluster-binding-when-restricted check. BUCKET_SUFFIXES is all four, for the
# low-privilege union-role check below.
NAMESPACED_BUCKET_SUFFIXES = ("-ns-read", "-ns-write")
BUCKET_SUFFIXES = NAMESPACED_BUCKET_SUFFIXES + ("-cluster-read", "-cluster-write")

# Union-authored RBAC object name prefixes, for the hard-fail low-privilege
# check, covering the handful of union objects that do NOT go through the
# bucket emitter above and so carry no bucket suffix (clusterresourcesync's
# ServiceAccount and its ClusterRoleBinding to system:auth-delegator name
# themselves with a literal "union-" prefix baked into the template, not
# derived from .Release.Namespace).
#
# This is deliberately NOT how bucket roles are recognized: a bucket role's
# name is {release-namespace}-{identity}-{bucket}, and the release namespace
# is an operator-chosen value this checker cannot predict. A fixed prefix
# like "union-" would only match a bucket role by accident of the fixture's
# release namespace happening to be named "union" -- every other release
# namespace would render e.g. "acme-union-ns-read", silently turning this
# hard-fail check into a no-op for every real deployment. See is_union_role,
# which matches bucket roles by SUFFIX instead, and falls back to this prefix
# list only for non-bucket objects.
#
# CURATED and deliberately not exhaustive, matching the
# CLUSTER_SCOPED_RESOURCE_BASES precedent: a missing prefix is a false
# negative, not a false positive, so growing this list is always safe. Third-
# party ClusterRoles (knative, fluent-bit, the monitoring stack) keep the
# pinnable low_priv_cluster_role ratchet instead.
UNION_ROLE_NAME_PREFIXES = (
    "union-",
)

# Objects carrying this annotation live and die with a Helm hook rather than
# with the release. A pre-upgrade hook's ClusterRole does not render on a fresh
# install and is deleted on hook success or failure, so its grant is bounded in
# TIME rather than in scope. That is a materially different risk from a standing
# cluster-wide grant, so hook objects are exempt from the hard-fail check and
# fall back to the pinnable ratchet. Keying on the annotation rather than a name
# list states the actual reason and covers any future hook automatically.
HELM_HOOK_ANNOTATION = "helm.sh/hook"

# Invariants whose baseline entry carries a `grant` fingerprint, so a pinned
# violation cannot be WIDENED without failing the check. cluster_write pins who
# holds the grant and how much it confers; dead_cluster_rule pins exactly which
# cluster-scoped resources the Role names, so adding another one to an
# already-pinned Role is a new failure rather than a silent no-op.
#
# low_priv_cluster_role deliberately carries none: there the violation is that
# the ClusterRole EXISTS at all under low_privilege, not what it contains, so a
# rules fingerprint would pin data the invariant does not assert and would churn
# the baseline on unrelated rule edits.
FINGERPRINTED_INVARIANTS = frozenset({CLUSTER_WRITE, DEAD_CLUSTER_RULE})

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
#
# These are BASE names. Matching splits a rule's resource on the first "/" and
# compares the base, because a subresource is scoped exactly like its parent:
# `nodes/metrics` is as cluster-scoped as `nodes`. Enumerating a fixed suffix
# list instead would under-report -- `nodes/metrics` is live in this chart's
# `union-operator-prometheus-rbac` Role today and matched no such list. Splitting
# on the base cannot over-report either: a subresource of a namespaced parent
# (`ingresses/status`) keeps a namespaced base and is correctly ignored.
CLUSTER_SCOPED_RESOURCE_BASES = frozenset(
    (
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
    return {
        name
        for name in resources
        if name.split("/", 1)[0] in CLUSTER_SCOPED_RESOURCE_BASES
    }


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


def fixture_layered_values(stem):
    """Values files tests/run.sh layers under the fixture, outermost first.

    run.sh passes the files named in the fixture's `# helm-values:` header
    BEFORE the fixture itself, so the fixture wins on conflict. Reading only
    the fixture would therefore miss a key that a layered file sets and the
    fixture does not -- charts/dataplane/examples/values-legacy.yaml sets
    low_privilege: false today, so a future fixture pointing at it would be
    rendered full-privilege while this script assumed low-privilege, and every
    ClusterRole in that render would report as a bogus low_priv_cluster_role.
    """
    values_path = VALUES_DIR / f"{stem}.yaml"
    if not values_path.exists():
        return []

    chart = stem.split(".", 1)[0]
    paths = []
    with values_path.open() as handle:
        for line in itertools.islice(handle, 10):
            if not line.startswith("# helm-values:"):
                continue
            for name in line.split(":", 1)[1].split(","):
                layered = CHARTS_DIR / chart / name.strip()
                if layered.is_file():
                    paths.append(layered)
    paths.append(values_path)
    return paths


def fixture_is_low_privilege(stem):
    """Resolve low_privilege for a snapshot. The chart default is true.

    Truthiness matches Go templates rather than normalizing: every
    `.Values.low_privilege` gate in the chart is read for raw truthiness, so a
    STRING "false" is true there and must be true here too. Python's bool()
    agrees with Go on the cases that matter (bool, "", "false", 0). If the
    chart ever normalizes the value -- which needs a values.schema.json and a
    sweep of all twelve gates, not a one-line change -- this must follow.
    """
    value = True
    for path in fixture_layered_values(stem):
        with path.open() as handle:
            values = yaml.safe_load(handle) or {}
        if "low_privilege" in values:
            value = values["low_privilege"]
    return bool(value)


def is_namespaced_bucket_role(name):
    """True if this role name denotes an ns-read or ns-write bucket."""
    return name.endswith(NAMESPACED_BUCKET_SUFFIXES)


def is_union_role(name):
    """True if this RBAC object is authored by this chart rather than a subchart.

    Two signals: a bucket role's name ends in one of BUCKET_SUFFIXES
    regardless of release namespace (the chart controls the identity and
    bucket segments, not the operator), and UNION_ROLE_NAME_PREFIXES catches
    the handful of union objects that do not go through the bucket emitter.
    """
    return name.endswith(BUCKET_SUFFIXES) or name.startswith(UNION_ROLE_NAME_PREFIXES)


def is_hook_object(doc):
    """True if this object's lifetime is bounded by a Helm hook, not the release."""
    annotations = (doc.get("metadata") or {}).get("annotations") or {}
    return HELM_HOOK_ANNOTATION in annotations


def restricts_cluster_bindings(docs):
    """True if the render shows evidence that at least one ns-* role is meant
    to be confined to named namespaces rather than bound cluster-wide.

    Evidence is PER-ROLE: a role counts as confined when some RoleBinding
    reaches it and NO ClusterRoleBinding also reaches it. Under the default
    posture, dataplane.rbac.emitBucket always pairs the two -- every
    namespaced bucket role gets both a RoleBinding (into each task namespace)
    and a ClusterRoleBinding -- so a role appearing confined this way cannot
    happen by accident of the default configuration; it only happens once
    rbac.clusterWideBindings: false has removed that role's ClusterRoleBinding
    while its RoleBindings stayed.

    The signal returned is RENDER-WIDE ("does at least one role show this
    evidence"), deliberately not evaluated only for the specific role
    find_violations' loop is asking about. A role with both a RoleBinding and
    a ClusterRoleBinding looks unremarkable in isolation -- that is exactly
    what the default posture looks like -- so the only way to tell that
    render apart from one where THIS role's ClusterRoleBinding leaked despite
    an opt-out is to find at least one OTHER role in the same render that
    stayed properly confined. That is the render's proof it rejected
    cluster-wide reach; a role that still has a ClusterRoleBinding alongside
    it is the anomaly.

    Conservative by construction: when in doubt it reports False, so the
    invariant simply does not fire. A false negative here is a missed
    warning; a false positive would fail CI on the default configuration --
    which is why this asks "does at least one role show confinement"
    rather than "do ALL roles show confinement": requiring unanimity would
    let a single leaked ClusterRoleBinding erase the very evidence needed to
    catch it, which is the failure mode this replaces (see d37f4a9f and the
    unconditional predecessor of this check). The blind spot that remains: a
    regression that hits every ns-* role at once -- rbac.clusterWideBindings
    itself being ignored outright, rather than one role's binding bypassing
    it -- renders indistinguishably from the default posture and is not
    caught here.
    """
    ns_bound = set()
    cluster_bound = set()
    for d in docs:
        ref = (d.get("roleRef") or {}).get("name", "")
        if not is_namespaced_bucket_role(ref):
            continue
        if d.get("kind") == "ClusterRoleBinding":
            cluster_bound.add(ref)
        elif d.get("kind") == "RoleBinding":
            ns_bound.add(ref)
    return bool(ns_bound - cluster_bound)


def find_union_bind_resource_names(docs):
    """Return (resourceNames, found) for the union-authored `bind` grant(s).

    `found` is True iff at least one union-authored role carries a `bind`
    grant on `clusterroles` -- distinct from the resourceNames set being
    empty, which would otherwise be indistinguishable from "no grant renders
    in this snapshot at all" and silently skip the check it is meant to gate.

    Scoped to is_union_role(name) roles only: unscoped, this would also match
    vendored subcharts' own `bind` rules on their own ClusterRoles (notably
    knative-serving-operator), which have nothing to do with this chart's
    ns-* buckets and would report as false failures for every role that grant
    doesn't happen to name.
    """
    names = set()
    found = False
    for doc in docs:
        if doc.get("kind") not in ("Role", "ClusterRole"):
            continue
        role_name = (doc.get("metadata") or {}).get("name")
        if not role_name or not is_union_role(role_name):
            continue
        for rule in doc.get("rules") or []:
            if BIND_VERB not in (rule.get("verbs") or []):
                continue
            if BIND_RESOURCE not in (rule.get("resources") or []):
                continue
            found = True
            names.update(rule.get("resourceNames") or [])
    return names, found


def find_ns_roles_missing_from_bind_list(docs):
    """Return sorted names of rendered ns-* bucket ClusterRoles absent from
    the union `bind` grant's resourceNames, for the dangerous direction only.

    The dangerous direction is a rendered role the bind list does NOT name --
    a provisioner cannot create a RoleBinding for it and gets a runtime
    Forbidden with nothing wrong in the render. The reverse (a resourceNames
    entry naming a role that never renders) is an inert no-op and is
    deliberately not checked: nothing can bind a role that does not exist.

    Only ClusterRoles are checked -- ns-* buckets render as namespaced Roles
    under low_privilege: true, where clusterresourcesync itself never renders
    (gating framework case 1), so there is no bind grant to check against in
    that mode in the first place.

    Returns an empty list (not a failure) when this snapshot carries no union
    `bind` grant at all -- see find_union_bind_resource_names's `found`.
    """
    bind_names, found = find_union_bind_resource_names(docs)
    if not found:
        return []
    missing = []
    for doc in docs:
        if doc.get("kind") != "ClusterRole":
            continue
        name = (doc.get("metadata") or {}).get("name")
        if not name or not is_namespaced_bucket_role(name):
            continue
        if name not in bind_names:
            missing.append(name)
    return sorted(missing)


def find_violations(docs, low_privilege):
    """Return {(name, invariant): grant} for one rendered snapshot.

    `grant` is a fingerprint tuple for the invariants in
    FINGERPRINTED_INVARIANTS and None otherwise -- see that constant for why
    low_priv_cluster_role is excluded.
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
            if is_union_role(name) and not is_hook_object(role):
                violations[(name, LOW_PRIV_UNION_CLUSTER_ROLE)] = None
            else:
                violations[(name, LOW_PRIV_CLUSTER_ROLE)] = None
        if kind == "Role":
            dead = tuple(find_dead_cluster_rules(role))
            if dead:
                violations[(name, DEAD_CLUSTER_RULE)] = dead

    restricted = restricts_cluster_bindings(docs)

    for name in find_ns_roles_missing_from_bind_list(docs):
        violations[(name, NS_ROLE_MISSING_FROM_BIND_LIST)] = None

    for binding in bindings:
        role_ref = binding.get("roleRef") or {}
        ref_name = role_ref.get("name")
        if not ref_name:
            continue
        if is_namespaced_bucket_role(ref_name) and restricted:
            violations[(ref_name, NS_ROLE_CLUSTER_BOUND_WHEN_RESTRICTED)] = None
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

        if invariant in FINGERPRINTED_INVARIANTS:
            if not grant or not isinstance(grant, list):
                errors.append(
                    f"{label}: {invariant} entries need a non-empty grant "
                    f"fingerprint -- run --write-baseline to generate it"
                )
                grant = None
            else:
                grant = tuple(sorted(str(line) for line in grant))
        elif grant is not None:
            errors.append(
                f"{label}: {invariant} entries do not carry a grant fingerprint"
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
#     grant:                      cluster_write + dead_cluster_rule; see below
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
# grant -- REQUIRED on cluster_write and dead_cluster_rule entries, forbidden
# on low_priv_cluster_role. It fingerprints WHAT was pinned, not just the name
# it was pinned under. Without it the baseline would pin only THAT a role is
# over-privileged, so a pinned violation could be widened freely and stay green.
# A grant that no longer matches the render is a GRANT CHANGED failure
# reporting the exact lines added and removed. It is machine-generated: never
# hand-edit it to make the check pass; rerun --write-baseline and review the
# diff, or delete the entry if the phase removed the grant.
#
#   cluster_write      which ClusterRoleBindings reference the role, which
#                      subjects they bind, and which write-bearing rules the
#                      binding confers (aggregation resolved). Widening is a
#                      new subject, a second binding or an added `escalate`.
#   dead_cluster_rule  the exact cluster-scoped resources and nonResourceURLs
#                      the namespaced Role names. Widening is one more dead
#                      resource on a Role already pinned for this invariant.
#
# low_priv_cluster_role and ns_role_cluster_bound_when_restricted carry no
# grant on purpose: there the violation is that the object EXISTS (or the
# binding survives) at all, not what it contains, so a rules fingerprint would
# pin data the invariant does not assert.
#
# low_priv_union_cluster_role and ns_role_missing_from_bind_list NEVER appear
# in this file: they have no baseline and cannot be pinned. See
# scripts/check_rbac.py's module docstring.
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
#   ns_role_cluster_bound_when_restricted
#                          this ns-read or ns-write bucket role is referenced
#                          by a ClusterRoleBinding in a render that opted out
#                          of cluster-wide bindings (rbac.clusterWideBindings:
#                          false) -- see scripts/check_rbac.py
#   ns_role_missing_from_bind_list
#                          this ns-read or ns-write bucket ClusterRole is not
#                          named in the union `bind` grant's resourceNames --
#                          see scripts/check_rbac.py
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

    # HARD_FAIL_INVARIANTS have NO baseline: pull their keys out before any
    # baseline comparison so they can never be pinned via --write-baseline, and
    # so a hand-added baseline entry for one always reads as STALE (nothing in
    # the trimmed violations set can ever match it) rather than as accepted.
    hard_failures = sorted(
        key for key in violations if key[2] in HARD_FAIL_INVARIANTS
    )
    violations = {
        key: grant
        for key, grant in violations.items()
        if key[2] not in HARD_FAIL_INVARIANTS
    }

    for snapshot, name, invariant in hard_failures:
        print(f"FORBIDDEN      {invariant:22} {name}  [{snapshot}]", file=sys.stderr)
    if any(invariant == LOW_PRIV_UNION_CLUSTER_ROLE for _, _, invariant in hard_failures):
        print(
            "\nA union-authored ClusterRole rendered under low_privilege: true.\n"
            "This invariant has NO baseline: a cluster-scoped grant that cannot\n"
            "survive namespacing means the COMPONENT must be gated, not its rules\n"
            "degraded. See the gating framework in the RBAC scope-split spec.\n"
            "Helm hook objects are exempt -- their lifetime is bounded by the hook.",
            file=sys.stderr,
        )
    if any(invariant == NS_ROLE_MISSING_FROM_BIND_LIST for _, _, invariant in hard_failures):
        print(
            "\nA rendered ns-read / ns-write bucket ClusterRole is not named in the\n"
            "union `bind` grant's resourceNames. This invariant has NO baseline: the\n"
            "bind list is DERIVED from the same identity/roleName helpers that render\n"
            "the roles, so this can only mean the two fell out of step -- a\n"
            "provisioner will get a runtime Forbidden trying to bind this role, with\n"
            "nothing wrong in the render to point at. See\n"
            "dataplane.rbac.bucketRoleNames in _rbac.tpl and\n"
            "clusterresourcesync/serviceaccount.yaml.",
            file=sys.stderr,
        )

    if args.write_baseline:
        entries = write_baseline(violations, baseline)
        print(
            f"Wrote {len(entries)} entries covering {len(violations)} pinned "
            f"(snapshot, name, invariant) triples to "
            f"{BASELINE_PATH.relative_to(REPO_ROOT)}"
        )
        return 1 if hard_failures else 0

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
            # Not a fingerprinted invariant, or the entry is already reported
            # as malformed above. Nothing to compare.
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
            "An `added` line WIDENS a violation that was pinned as-is -- for "
            "cluster_write\na new subject, a new binding or a new write verb "
            "reaching cluster scope; for\ndead_cluster_rule one more "
            "cluster-scoped resource on the Role. Justify it in\nreview before "
            "re-running --write-baseline; do not hand-edit the grant.\n"
            "A `removed` line means the violation shrank, which is the goal: "
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

    if errors or new or changed or stale or hard_failures:
        return 1

    snapshots = {snapshot for snapshot, _, _ in violations}
    print(
        f"RBAC check passed: {len(violations)} pinned violations across "
        f"{len(snapshots)} snapshots, none new."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
