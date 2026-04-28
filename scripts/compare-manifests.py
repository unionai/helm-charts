#!/usr/bin/env python3
"""Structurally compare two Helm-rendered manifest files.

Parses both files as multi-document YAML, matches resources by (kind, name),
and deep-compares the parsed config data inside ConfigMaps. Reports differences
by full key path so nesting errors are immediately visible.

For non-ConfigMap resources, reports added/removed resources.

Usage:
    python3 scripts/compare-manifests.py old.yaml new.yaml
    python3 scripts/compare-manifests.py --all old.yaml new.yaml  # diff all resources, not just ConfigMaps

Examples:
    # Compare a release tag against main
    ./scripts/render-and-diff.sh controlplane-2026.4.7 main --values tests/values/controlplane.aws.yaml

    # Or render manually and compare
    helm template charts/controlplane ... > /tmp/old.yaml
    git checkout main
    helm template charts/controlplane ... > /tmp/new.yaml
    python3 scripts/compare-manifests.py /tmp/old.yaml /tmp/new.yaml
"""
import argparse
import sys

import yaml


def parse_manifests(path):
    """Parse multi-doc YAML into dict keyed by (kind, name)."""
    manifests = {}
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if not doc or not isinstance(doc, dict):
                continue
            kind = doc.get("kind", "?")
            name = doc.get("metadata", {}).get("name", "?")
            manifests[(kind, name)] = doc
    return manifests


def deep_diff(old, new, path=""):
    """Recursively diff two structures, yielding (path, old_val, new_val)."""
    if type(old) != type(new):
        yield (path or "<root>", old, new)
        return

    if isinstance(old, dict):
        all_keys = set(old.keys()) | set(new.keys())
        for key in sorted(all_keys):
            child_path = f"{path}.{key}" if path else key
            if key not in new:
                yield (child_path, old[key], "<REMOVED>")
            elif key not in old:
                yield (child_path, "<ADDED>", new[key])
            else:
                yield from deep_diff(old[key], new[key], child_path)
    elif isinstance(old, list):
        if old != new:
            yield (path or "<root>", old, new)
    else:
        if old != new:
            yield (path or "<root>", old, new)


def parse_configmap_data(configmap):
    """Parse embedded YAML strings in a ConfigMap's data field."""
    data = configmap.get("data", {})
    parsed = {}
    for key, value in data.items():
        if isinstance(value, str):
            try:
                parsed[key] = yaml.safe_load(value)
            except yaml.YAMLError:
                parsed[key] = value
        else:
            parsed[key] = value
    return parsed


# Paths that change on every render and should be ignored
NOISE_PATHS = {"configChecksum", "labels", "annotations", "helm.sh/chart"}

# ConfigMaps containing Grafana dashboard JSON — diff as added/removed only
DASHBOARD_PREFIXES = ("dashboard-", "controlplane-dashboard-")


def is_noise(path):
    return any(n in path for n in NOISE_PATHS)


def is_dashboard_configmap(name):
    return any(name.startswith(p) or name.endswith("-dashboard") for p in DASHBOARD_PREFIXES)


def format_val(val):
    if isinstance(val, (dict, list)):
        return yaml.dump(val, default_flow_style=True).strip()
    return repr(val)


def diff_configmaps(old_manifests, new_manifests):
    """Structurally diff ConfigMaps. Returns number of real differences."""
    configmap_keys = sorted(set(
        k for k in (set(old_manifests) | set(new_manifests)) if k[0] == "ConfigMap"
    ))

    total = 0
    for key in configmap_keys:
        kind, name = key
        old_cm = old_manifests.get(key)
        new_cm = new_manifests.get(key)

        if old_cm is None:
            print(f"\n  + ConfigMap/{name}: NEW")
            total += 1
            continue
        if new_cm is None:
            print(f"\n  - ConfigMap/{name}: REMOVED")
            total += 1
            continue

        # Dashboard ConfigMaps contain huge JSON blobs — just flag changed, don't deep-diff
        if is_dashboard_configmap(name):
            old_data_raw = old_cm.get("data", {})
            new_data_raw = new_cm.get("data", {})
            if old_data_raw != new_data_raw:
                print(f"\n  ConfigMap/{name}: CHANGED (dashboard — use --text for full diff)")
                total += 1
            continue

        old_data = parse_configmap_data(old_cm)
        new_data = parse_configmap_data(new_cm)

        diffs = [(p, o, n) for p, o, n in deep_diff(old_data, new_data) if not is_noise(p)]
        if not diffs:
            continue

        print(f"\n  ConfigMap/{name}: {len(diffs)} difference(s)")
        for path, old_val, new_val in diffs:
            total += 1
            print(f"    {path}:")
            print(f"      old: {format_val(old_val)}")
            print(f"      new: {format_val(new_val)}")

    return total


def diff_all_resources(old_manifests, new_manifests):
    """Report added/removed/changed resources of all kinds. Returns diff count."""
    all_keys = sorted(set(old_manifests) | set(new_manifests))
    total = 0

    for key in all_keys:
        kind, name = key
        if kind == "ConfigMap":
            continue  # handled separately

        old_res = old_manifests.get(key)
        new_res = new_manifests.get(key)

        if old_res is None:
            print(f"\n  + {kind}/{name}: NEW")
            total += 1
        elif new_res is None:
            print(f"\n  - {kind}/{name}: REMOVED")
            total += 1
        else:
            diffs = [(p, o, n) for p, o, n in deep_diff(old_res, new_res) if not is_noise(p)]
            if diffs:
                print(f"\n  {kind}/{name}: {len(diffs)} difference(s)")
                for path, old_val, new_val in diffs:
                    total += 1
                    print(f"    {path}:")
                    print(f"      old: {format_val(old_val)}")
                    print(f"      new: {format_val(new_val)}")

    return total


def main():
    parser = argparse.ArgumentParser(
        description="Structurally compare two Helm-rendered manifest files.",
        epilog="See scripts/render-and-diff.sh for automated render + compare workflow.",
    )
    parser.add_argument("old", help="Baseline manifest file (e.g. from release tag)")
    parser.add_argument("new", help="New manifest file (e.g. from main or feature branch)")
    parser.add_argument("--all", action="store_true",
                        help="Diff all resource types, not just ConfigMaps")
    args = parser.parse_args()

    old_manifests = parse_manifests(args.old)
    new_manifests = parse_manifests(args.new)

    total = 0

    print("=== ConfigMap structural diff ===")
    total += diff_configmaps(old_manifests, new_manifests)

    if args.all:
        print("\n=== Other resources ===")
        total += diff_all_resources(old_manifests, new_manifests)

    # Summary
    old_keys = set(old_manifests)
    new_keys = set(new_manifests)
    added = new_keys - old_keys
    removed = old_keys - new_keys

    print(f"\n--- Summary ---")
    print(f"Resources: {len(old_keys)} old, {len(new_keys)} new"
          f" (+{len(added)} added, -{len(removed)} removed)")

    if total == 0:
        print("Result: no structural differences found.")
    else:
        print(f"Result: {total} structural difference(s) found.")

    sys.exit(0 if total == 0 else 1)


if __name__ == "__main__":
    main()
