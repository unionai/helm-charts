#!/usr/bin/env python3
"""Fail on container image references that omit the registry host.

Kubernetes resolves a reference whose first path segment is not a hostname
against the implicit `docker.io/` (and, with no slash at all, the implicit
`docker.io/library/`) default. Clusters that pin an allowed-registry admission
policy — or that run without Docker Hub reachable at all — reject those pulls
with ErrImagePull. Writing the host out in full removes the ambiguity.

Two independent passes, because neither alone is sufficient:

  rendered  Every `image:` in tests/generated/*.yaml, plus the `repository:` /
            `agentRepository:` fields that operator CRDs (ScyllaCluster) use to
            assemble an image. Catches subchart defaults we never spell out
            ourselves. Only as broad as tests/values/*.yaml — a template no
            profile exercises is invisible here, hence the second pass.

  values    Every image `repository:` literal in charts/*/values.yaml. Catches
            defaults that no test profile happens to render.

Run over the checked-in tests/generated/ corpus rather than rendering live, so
this needs no network and no helm. `make helm-test` is what guarantees that
corpus matches the charts; this check rides on that guarantee.

Usage:
    python scripts/check-image-paths.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATED_DIR = REPO_ROOT / "tests" / "generated"
CHARTS_DIR = REPO_ROOT / "charts"

# `image: <ref>` in a rendered manifest.
IMAGE_RE = re.compile(r"^\s*-?\s*image:\s*(.+?)\s*$")
# Image-repository fields that CRDs use instead of a plain `image:`. A bare
# `repository:` in a rendered k8s manifest is an image repo; the helm-repo sense
# of the word only appears in Chart.yaml, which we never scan.
REPO_FIELD_RE = re.compile(r"^\s*-?\s*(?:agentR|r)epository:\s*(.+?)\s*$")
SOURCE_RE = re.compile(r"^# Source: (.*)$")

# Values keys whose scalar is an image repository.
VALUES_REPO_RE = re.compile(r"^(\s*)(?:agentR|r)epository:\s*(.+?)\s*$")

# Refs we accept unqualified, each with the reason. Keep this empty if you can.
ALLOWLIST: dict[str, str] = {}


def strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def is_scannable(value: str) -> bool:
    """Skip anything that isn't a literal image reference."""
    if not value or value in ("{}", "[]", "~", "null"):
        return False
    if "{{" in value or "${" in value:  # unresolved template
        return False
    if "://" in value:  # helm repo URL
        return False
    if value.startswith("#"):
        return False
    return True


def is_qualified(ref: str) -> bool:
    """True when the reference names its registry host explicitly.

    A ref is qualified when its first path segment looks like a host: it
    contains a dot (docker.io, quay.io, gcr.io), contains a colon
    (localhost:5000, registry:30000), or is exactly `localhost`.

    Note the no-slash case: `busybox:latest` has no path segment at all and
    resolves to docker.io/library/busybox. Testing only "does segment zero
    contain a dot" passes it by mistake, because segment zero is the whole
    string `busybox:latest` — which contains a colon.
    """
    ref = ref.split("@", 1)[0]  # drop any digest
    if "/" not in ref:
        return False
    first = ref.split("/", 1)[0]
    return "." in first or ":" in first or first == "localhost"


def scan_rendered() -> list[tuple[str, str, str]]:
    """Yield (ref, file, source-template) for unqualified refs in rendered YAML."""
    findings = []
    for path in sorted(GENERATED_DIR.glob("*.yaml")):
        source = ""
        for line in path.read_text().splitlines():
            match = SOURCE_RE.match(line)
            if match:
                source = match.group(1)
                continue
            match = IMAGE_RE.match(line) or REPO_FIELD_RE.match(line)
            if not match:
                continue
            ref = strip_quotes(match.group(1))
            if not is_scannable(ref) or ref in ALLOWLIST:
                continue
            if not is_qualified(ref):
                findings.append((ref, path.name, source))
    return findings


def scan_values() -> list[tuple[str, str, int]]:
    """Yield (ref, path, lineno) for unqualified image literals in chart values.

    Covers every chart-root `values*.yaml`, not just `values.yaml` — the
    per-cloud overlays (`values.aws.yaml`, `values.gcp.yaml`, …) and
    `charts/sandbox/values-dataplane.yaml` ship as defaults too.

    Matches both spellings an image default takes: a `repository:` /
    `agentRepository:` key, and a scalar `image: <ref>` (e.g. the
    envoy-gateway-config `redis.image`). A mapping-valued `image:` has nothing
    after the colon, so the regex simply doesn't match it.
    """
    findings = []
    for path in sorted(CHARTS_DIR.glob("*/values*.yaml")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        for lineno, line in enumerate(path.read_text().splitlines(), start=1):
            repo_match = VALUES_REPO_RE.match(line)
            image_match = None if repo_match else IMAGE_RE.match(line)
            if not repo_match and not image_match:
                continue
            ref = strip_quotes(repo_match.group(2) if repo_match else image_match.group(1))
            if not is_scannable(ref) or ref in ALLOWLIST:
                continue
            if not is_qualified(ref):
                findings.append((ref, rel, lineno))
    return findings


def main() -> int:
    if not GENERATED_DIR.is_dir():
        print(f"error: {GENERATED_DIR} not found; run `make generate-expected`")
        return 2

    rendered = scan_rendered()
    values = scan_values()

    if not rendered and not values:
        print("check-image-paths: all image references are fully qualified")
        return 0

    print("Unqualified image references found.\n")
    print("Kubernetes resolves these against the implicit docker.io default,")
    print("which fails on clusters with an allowed-registry policy. Prefix the")
    print("registry host, e.g. `bitnami/kubectl` -> `docker.io/bitnami/kubectl`.\n")

    if values:
        print("In chart values (default that ships to users):")
        for ref, path, lineno in values:
            print(f"  {path}:{lineno}: {ref}")
        print()

    if rendered:
        print("In rendered output (includes subchart defaults):")
        seen = {}
        for ref, filename, source in rendered:
            seen.setdefault(ref, (filename, source))
        for ref, (filename, source) in sorted(seen.items()):
            origin = source or filename
            print(f"  {ref}\n      from {origin}")
        print()
        print("For a subchart default, add an override in the parent chart's")
        print("values.yaml, then re-run `make generate-expected`.")

    return 1


if __name__ == "__main__":
    sys.exit(main())
