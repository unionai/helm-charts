#!/usr/bin/env python3
"""Check generated Fleet coverage against the dataplane values and schema.

The default check reads fleet-contract.json and validates synthetic common,
vendor, and merged output, including optional inputs, for all four providers.
Cloud automation generates this bundle from current templates and image-pinned
Go types. This local check requires neither Helm nor cross-repository access.

The explicit --fixture option retains the small path-checker test interface.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CHART = "charts/dataplane"


def check_bundle(chart_dir: Path) -> list[str]:
    """Check synthetic common, vendor and merged output without network or Helm."""
    bundle = json.loads((chart_dir / "fleet-contract.json").read_text())
    if bundle.get("version") != 1 or not bundle.get("scenarios"):
        return ["Fleet contract must contain version 1 coverage scenarios"]
    defaults = yaml.safe_load((chart_dir / "values.yaml").read_text())
    schema = json.loads((chart_dir / "values.schema.json").read_text())
    failures = []

    def kind(value):
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, int) or isinstance(value, float) and value.is_integer():
            return "integer"
        if isinstance(value, float):
            return "number"
        if isinstance(value, dict):
            return "object"
        if isinstance(value, list):
            return "array"
        return "string"

    def walk(values, expected, declared, path, label, inherited_open=False):
        declared_types = declared.get("type", [])
        declared_types = [declared_types] if isinstance(declared_types, str) else declared_types
        open_map = (
            inherited_open
            or expected == {}
            or (expected is None and "properties" not in declared and "object" in declared_types)
        )
        expected = expected or {}
        for key, value in values.items():
            at = path + [key]
            where = ".".join(at)
            node = declared.get("properties", {}).get(key)
            if key not in expected and node is None and not open_map:
                failures.append(f"{label}: {where} is not declared")
                continue
            if key in expected and value is None:
                continue
            types = (node or {}).get("type", [])
            types = [types] if isinstance(types, str) else types
            actual = kind(value)
            if types and actual not in types and not (actual == "integer" and "number" in types):
                failures.append(f"{label}: {where} has the wrong type")
                continue
            default = expected.get(key)
            if (
                not types
                and default is not None
                and actual != kind(default)
                and {actual, kind(default)} != {"integer", "number"}
            ):
                failures.append(f"{label}: {where} has the wrong type")
                continue
            if isinstance(value, dict):
                walk(
                    value,
                    default if isinstance(default, dict) else None,
                    node or {},
                    at,
                    label,
                    open_map,
                )

    providers = {"aws", "azure", "gcp", "metal"}
    coverage = {(s["provider"], s["variant"]) for s in bundle["scenarios"]}
    if not all((provider, variant) in coverage for provider in providers for variant in (0, 1)):
        failures.append(
            "Fleet coverage must include optional inputs present and absent for all four providers"
        )
    for scenario in bundle["scenarios"]:
        for part in ("common", "vendor", "merged"):
            walk(
                scenario[part],
                defaults,
                schema,
                [],
                f"{scenario['provider']}/{scenario['variant']}/{part}",
            )
    return failures


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
    parser.add_argument("--fixture", help="legacy path fixture for isolated checker tests")
    args = parser.parse_args(argv)
    chart_dir = Path(args.chart) if Path(args.chart).is_absolute() else REPO_ROOT / args.chart
    fixture = None
    if args.fixture:
        fixture = (
            Path(args.fixture) if Path(args.fixture).is_absolute() else REPO_ROOT / args.fixture
        )
    failures = check(chart_dir, fixture) if fixture else check_bundle(chart_dir)
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(
            f"{len(failures)} Fleet value path(s) are not accepted by {chart_dir.name}",
            file=sys.stderr,
        )
        return 1
    print("all generated Fleet coverage scenarios are accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
