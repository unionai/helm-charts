#!/usr/bin/env python3
"""Audit single-namespace dataplane renders against the cluster-scope allowlist.

tests/test-rbac-guards.sh owns the allowlist and calls this once. It renders every
dataplane fixture whose values resolve to singleNamespace, audits each render plus the
pre-rendered files passed with --render, and prints one `ok`/`FAILED` line per render in
the guard script's format.

What a render must satisfy:

- Every ClusterRole bound by a ClusterRoleBinding is audited rule by rule. Each
  (apiGroup, resource, verb, resourceName) tuple it grants must be on the allowlist
  under that role's name. A role the render binds but does not define, or one built by
  aggregation, cannot be audited and fails.
- A write -- any verb other than get, list or watch -- must be pinned by resourceNames,
  unless the allowlist marks that exact tuple as an unpinned exception.
- Roles and RoleBindings sit in the release namespace, unless named in the allowlist's
  `outside-namespace` lines.
- Bindings rendered by a subchart named in a `subchart` line are skipped: their RBAC is
  the subchart's own and singleNamespace does not govern it.

Across all renders, every allowlist entry must be exercised at least once, so an entry
whose grant has gone does not linger and quietly authorize its return.
"""

import argparse
import re
import shlex
import subprocess
import sys
from pathlib import Path

import yaml

READ_VERBS = {"get", "list", "watch"}
KINDS = {"read", "pinned-write", "unpinned-write"}


def parse_allowlist(path):
    entries = {}
    subcharts = set()
    outside = set()
    for lineno, raw in enumerate(Path(path).read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if fields[0] == "subchart":
            subcharts.add(fields[1])
            continue
        if fields[0] == "outside-namespace":
            outside.add(fields[1])
            continue
        if len(fields) not in (5, 6) or fields[1] not in KINDS:
            sys.exit(f"allowlist line {lineno} is malformed: {raw!r}")
        role, kind, group, resource, verbs = fields[:5]
        names = fields[5].split(",") if len(fields) == 6 else [None]
        group = "" if group == "core" else group
        for verb in verbs.split(","):
            is_write = verb not in READ_VERBS
            if (kind == "read") == is_write:
                sys.exit(f"allowlist line {lineno}: verb {verb!r} does not match kind {kind!r}")
            if kind == "pinned-write" and names == [None]:
                sys.exit(f"allowlist line {lineno}: a pinned-write entry must name its objects")
            for name in names:
                entries[(role, group, resource, verb, name)] = kind
    return entries, subcharts, outside


def documents(text):
    """Yield (source template, document) for every top-level manifest in a render."""
    for chunk in re.split(r"^---\s*$", text, flags=re.M):
        doc = yaml.safe_load(chunk)
        if isinstance(doc, dict) and "kind" in doc:
            match = re.search(r"^# Source: (\S+)", chunk, flags=re.M)
            yield (match.group(1) if match else ""), doc


def subchart_of(source):
    match = re.match(r"[^/]+/charts/([^/]+)/", source)
    return match.group(1) if match else None


def tuples(rule):
    names = rule.get("resourceNames") or [None]
    if rule.get("nonResourceURLs"):
        for url in rule["nonResourceURLs"]:
            for verb in rule.get("verbs") or []:
                yield ("-", url, verb, None)
        return
    for group in rule.get("apiGroups") or []:
        for resource in rule.get("resources") or []:
            for verb in rule.get("verbs") or []:
                for name in names:
                    yield (group, resource, verb, name)


def audit(text, namespace, allow, subcharts, outside, used):
    problems = []
    docs = list(documents(text))
    roles = {d["metadata"]["name"]: d for _, d in docs if d["kind"] == "ClusterRole"}
    for source, doc in docs:
        kind, name = doc["kind"], doc["metadata"]["name"]
        if subchart_of(source) in subcharts:
            continue
        if kind in ("Role", "RoleBinding"):
            ns = doc["metadata"].get("namespace", namespace)
            if ns != namespace and name not in outside:
                problems.append(f"{kind}/{name} is in namespace {ns}, not the release namespace")
            continue
        if kind != "ClusterRoleBinding":
            continue
        ref = doc["roleRef"]["name"]
        role = roles.get(ref)
        if role is None:
            problems.append(
                f"ClusterRoleBinding/{name} binds ClusterRole/{ref}, which the render does not define"
            )
            continue
        if role.get("aggregationRule"):
            problems.append(f"ClusterRole/{ref} is aggregated, so its grant cannot be audited here")
            continue
        for rule in role.get("rules") or []:
            for group, resource, verb, rname in tuples(rule):
                key = (ref, group, resource, verb, rname)
                pinned = f" named {rname}" if rname else ""
                what = f"{verb} {resource}{pinned} ({group or 'core'})"
                entry = allow.get(key)
                if entry is None:
                    problems.append(
                        f"ClusterRole/{ref} grants {what}, which is not on the allowlist"
                    )
                    continue
                used.add(key)
                if verb not in READ_VERBS and rname is None and entry != "unpinned-write":
                    problems.append(
                        f"ClusterRole/{ref} grants {what}, a cluster-scoped write with no resourceNames"
                    )
    return problems


def layered_flags(fixture, chart):
    head = fixture.read_text().splitlines()[:10]
    flags = []
    for line in head:
        if line.startswith("# helm-values:"):
            for name in line.split(":", 1)[1].split(","):
                flags += ["--values", str(chart / name.strip())]
    extra = []
    for line in head:
        if line.startswith("# helm-args:"):
            extra = shlex.split(line.split(":", 1)[1])
    # Scope is resolved from the values files alone, so a fixture that sets it through
    # helm-args would be audited, or skipped, on the wrong answer.
    if any(key in arg for arg in extra for key in ("singleNamespace", "low_privilege")):
        sys.exit(
            f"{fixture.name} sets scope in # helm-args:, which this audit cannot resolve; set it in the values instead"
        )
    return flags, extra


def single_namespace(files):
    """Resolve scope the way the chart's singleNamespace define does, over layered files."""
    merged = {}
    for path in files:
        values = yaml.safe_load(Path(path).read_text()) or {}
        for key in ("singleNamespace", "low_privilege"):
            if key in values:
                merged[key] = values[key]
    if merged.get("singleNamespace") is not None:
        return merged["singleNamespace"]
    if merged.get("low_privilege") is not None:
        return merged["low_privilege"]
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allowlist", required=True)
    parser.add_argument("--chart", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--render", action="append", default=[], metavar="LABEL=FILE")
    args = parser.parse_args()

    allow, subcharts, outside = parse_allowlist(args.allowlist)
    used = set()
    renders = []
    for fixture in sorted(args.fixtures.glob("dataplane.*.yaml")):
        flags, extra = layered_flags(fixture, args.chart)
        layered = [flags[i + 1] for i in range(0, len(flags), 2)] + [str(fixture)]
        if not single_namespace(layered):
            continue
        cmd = [
            "helm",
            "template",
            str(args.chart),
            "--namespace",
            args.namespace,
            "--kube-version",
            "1.32.0",
            *flags,
            *extra,
            "--values",
            str(fixture),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        renders.append((f"fixture {fixture.name}", result.stdout, result.returncode, result.stderr))
    for spec in args.render:
        label, _, path = spec.partition("=")
        renders.append((label, Path(path).read_text(), 0, ""))

    failed = False
    for label, text, code, err in renders:
        if code != 0:
            problems = [f"render failed: {err.strip().splitlines()[-1] if err.strip() else code}"]
        else:
            problems = audit(text, args.namespace, allow, subcharts, outside, used)
        if problems:
            failed = True
            print(f"  FAILED   {label}")
            for p in problems:
                print(f"           {p}")
        else:
            print(f"  ok       {label}")

    stale = sorted(k for k in allow if k not in used)
    if stale:
        failed = True
        print("  FAILED   every allowlist entry is exercised by some single-namespace render")
        for role, group, resource, verb, name in stale:
            pinned = f" named {name}" if name else ""
            print(f"           unused: {role} {verb} {resource}{pinned} ({group or 'core'})")
    else:
        print("  ok       every allowlist entry is exercised by some single-namespace render")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
