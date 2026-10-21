#!/usr/bin/env python3
"""Fail if the dataplane chart pulls an image through a mirror the pre-warm Job doesn't warm.

The image pre-warm hook (charts/dataplane/templates/image-prewarm/job.yaml)
keeps its image list by hand, so a new image, or a renamed one, that isn't
added to it would roll out cold through the mirror. For every image-mirror
test profile (tests/values/dataplane.image-mirrors*.yaml), this collects every
reference under one of the profile's global.imageMirrors prefixes in the
rendered snapshot, and checks that the Job's document has each of them.

Every mirror reference counts, not just container images: the copilot
sidecar's image lives in a ConfigMap and is pulled by task pods. The webhook's
rewrite rules (replacementPattern: <mirror>/$1) are patterns for task images,
not images, and are skipped.

Run over the checked-in tests/generated/ corpus, like check-image-paths.py, so
this needs no network and no helm; `make helm-test` keeps that corpus fresh.

Usage:
    uv run python scripts/check-image-prewarm.py
"""

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
VALUES_DIR = REPO_ROOT / "tests" / "values"
GENERATED_DIR = REPO_ROOT / "tests" / "generated"
PROFILE_GLOB = "dataplane.image-mirrors*.yaml"
JOB_SOURCE = "# Source: dataplane/templates/image-prewarm/job.yaml"


def mirror_refs(text: str, mirrors: list[str]) -> set[str]:
    """References under a mirror prefix. One ends at a quote, whitespace, comma
    or an escaped newline inside a ConfigMap string."""
    refs = set()
    for mirror in mirrors:
        for ref in re.findall(re.escape(mirror) + r"/[^\"'\s,\\]+", text):
            ref = ref.rstrip("]}")
            if "$" not in ref:
                refs.add(ref)
    return refs


def check(profile: Path) -> list[str]:
    """Return the problems with one profile's snapshot, empty when it passes."""
    values = yaml.safe_load(profile.read_text()) or {}
    mirrors = list(((values.get("global") or {}).get("imageMirrors") or {}).values())
    if not mirrors:
        return [f"{profile.name}: sets no global.imageMirrors"]

    generated = GENERATED_DIR / profile.name
    if not generated.is_file():
        return [f"{generated.relative_to(REPO_ROOT)} not found; run `make generate-expected`"]
    rendered = generated.read_text()

    job = [doc for doc in rendered.split("\n---\n") if JOB_SOURCE in doc]
    if not job:
        return [f"{profile.name}: the pre-warm Job did not render"]
    warmed = mirror_refs(job[0], mirrors)
    if not warmed:
        return [f"{profile.name}: the pre-warm Job warms no images"]

    missing = sorted(mirror_refs(rendered, mirrors) - warmed)
    return [f"{profile.name}: pulled through the mirror but not warmed: {ref}" for ref in missing]


def main() -> int:
    profiles = sorted(VALUES_DIR.glob(PROFILE_GLOB))
    if not profiles:
        print(f"error: no {PROFILE_GLOB} profiles in {VALUES_DIR.relative_to(REPO_ROOT)}")
        return 2

    problems = [problem for profile in profiles for problem in check(profile)]
    if not problems:
        print(f"check-image-prewarm: every mirror reference is warmed ({len(profiles)} profiles)")
        return 0

    print("The chart pulls these through the mirror, but")
    print("charts/dataplane/templates/image-prewarm/job.yaml doesn't warm them:\n")
    for problem in problems:
        print(f"  {problem}")
    print("\nAdd the image to the Job's list, then re-run `make generate-expected`.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
