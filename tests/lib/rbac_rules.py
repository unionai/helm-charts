#!/usr/bin/env python3
"""Print RBAC rules from a rendered manifest, one normalized line per grant.

tests/test-rbac-guards.sh calls this to pin a rule together with its resourceNames,
which its awk helpers do not read. Two modes, both reading the render on stdin:

  rules <role>     every rule of the Role or ClusterRole named <role>, one line per
                   (apiGroup, resource) pair: `<group> <resource> <verbs> <names>`.
                   group is `core` for "", verbs and names are sorted and
                   comma-joined, and names is `-` when the rule has none. Prints
                   `<NO-SUCH-ROLE>` when no role has that name.
  wildcards        every rule outside the pooled work-ns role that names `*` in
                   apiGroups or a resource containing `*`, one line per rule:
                   `<kind>/<name> apiGroups=<...> resources=<...> verbs=<...>`.
"""

import sys

import yaml


def roles(docs):
    for doc in docs:
        if isinstance(doc, dict) and doc.get("kind") in ("Role", "ClusterRole"):
            yield doc


def main():
    mode = sys.argv[1]
    docs = list(yaml.safe_load_all(sys.stdin))
    if mode == "rules":
        want = sys.argv[2]
        found = False
        lines = set()
        for doc in roles(docs):
            if doc["metadata"]["name"] != want:
                continue
            found = True
            for rule in doc.get("rules") or []:
                verbs = ",".join(sorted(rule.get("verbs") or []))
                names = ",".join(sorted(rule.get("resourceNames") or [])) or "-"
                for group in rule.get("apiGroups") or []:
                    for resource in rule.get("resources") or []:
                        lines.add(f"{group or 'core'} {resource} {verbs} {names}")
        if not found:
            print("<NO-SUCH-ROLE>")
        for line in sorted(lines):
            print(line)
    elif mode == "wildcards":
        work_ns = sys.argv[2]
        for doc in roles(docs):
            name = doc["metadata"]["name"]
            if name == work_ns:
                continue
            for rule in doc.get("rules") or []:
                groups = rule.get("apiGroups") or []
                resources = rule.get("resources") or []
                if "*" in groups or any("*" in r for r in resources):
                    print(
                        f"{doc['kind']}/{name} apiGroups={','.join(groups)} "
                        f"resources={','.join(resources)} "
                        f"verbs={','.join(sorted(rule.get('verbs') or []))}"
                    )
    else:
        sys.exit(f"unknown mode {mode!r}")


if __name__ == "__main__":
    main()
