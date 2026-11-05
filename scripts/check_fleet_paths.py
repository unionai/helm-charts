#!/usr/bin/env python3
"""Fail when the dataplane chart stops accepting a value path that Union Fleet writes.

Fleet renders each dataplane's values from templates kept in unionai/cloud
(cluster/fleet/templates). Fleet admission accepts a rendered path only when
the chart's values.yaml has it, an ancestor is an empty mapping (an open
dictionary), or the packaged values.schema.json declares it. A chart change
that renames or drops one of those keys breaks registration of the next
release, and nothing in this repo would say so.

tests/fleet-values-paths.txt lists every path the templates write. This check
applies the same three acceptance rules to each one. It reads only
values.yaml, values.schema.json and the fixture, so it needs neither helm nor
network. A path that only a packaged subchart defaults would need a tgz
reader; none of the listed paths is one.

Fixture syntax: one dotted path per line; `#` starts a comment. A segment that
contains `.`, `/` or whitespace is written in brackets, for example
`proxy.podAnnotations["karpenter.sh/do-not-disrupt"]`.

Usage:
    python scripts/check_fleet_paths.py [--chart charts/dataplane] [--fixture tests/fleet-values-paths.txt]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CHART = "charts/dataplane"
DEFAULT_FIXTURE = "tests/fleet-values-paths.txt"


def parse_path(text: str) -> list[str]:
    """Split a dotted path into segments; `["…"]` segments are literal."""
    segments: list[str] = []
    current = ""
    i = 0
    while i < len(text):
        char = text[i]
        if char == "[":
            end = text.find('"]', i + 2)
            if not text.startswith('["', i) or end < 0:
                raise ValueError(f"malformed bracket segment in {text!r}")
            if current:
                segments.append(current)
                current = ""
            segments.append(text[i + 2 : end])
            i = end + 2
            if i < len(text) and text[i] == ".":
                i += 1
            continue
        if char == ".":
            if not current:
                raise ValueError(f"empty segment in {text!r}")
            segments.append(current)
            current = ""
        else:
            current += char
        i += 1
    if current:
        segments.append(current)
    if not segments:
        raise ValueError(f"empty path {text!r}")
    return segments


def load_fixture(path: Path) -> list[tuple[int, str, list[str]]]:
    entries = []
    for line_no, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if line:
            entries.append((line_no, line, parse_path(line)))
    if not entries:
        raise ValueError(f"{path} lists no paths")
    return entries


def accepted_by_values(values: object, segments: list[str]) -> bool:
    """The path exists in values.yaml, or an ancestor is an empty mapping."""
    node = values
    for segment in segments:
        if not isinstance(node, dict):
            return False
        if len(node) == 0:
            return True
        if segment not in node:
            return False
        node = node[segment]
    return True


def accepted_by_schema(schema: object, segments: list[str]) -> bool:
    node = schema
    for segment in segments:
        if not isinstance(node, dict):
            return False
        properties = node.get("properties")
        if not isinstance(properties, dict) or segment not in properties:
            return False
        node = properties[segment]
    return True


def check(chart_dir: Path, fixture: Path) -> list[str]:
    values = yaml.safe_load((chart_dir / "values.yaml").read_text())
    schema_path = chart_dir / "values.schema.json"
    schema = json.loads(schema_path.read_text()) if schema_path.exists() else {}
    failures = []
    for line_no, text, segments in load_fixture(fixture):
        if accepted_by_values(values, segments) or accepted_by_schema(schema, segments):
            continue
        failures.append(
            f"{fixture}:{line_no}: {text} is neither in values.yaml, under an open map, nor declared in values.schema.json"
        )
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--chart", default=DEFAULT_CHART)
    parser.add_argument("--fixture", default=DEFAULT_FIXTURE)
    args = parser.parse_args(argv)
    chart_dir = Path(args.chart) if Path(args.chart).is_absolute() else REPO_ROOT / args.chart
    fixture = Path(args.fixture) if Path(args.fixture).is_absolute() else REPO_ROOT / args.fixture
    failures = check(chart_dir, fixture)
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(
            f"{len(failures)} Fleet value path(s) are not accepted by {chart_dir.name}",
            file=sys.stderr,
        )
        return 1
    print(
        f"all Fleet value paths in {fixture.relative_to(REPO_ROOT) if fixture.is_relative_to(REPO_ROOT) else fixture} are accepted"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
