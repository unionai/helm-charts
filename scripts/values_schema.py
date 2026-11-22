#!/usr/bin/env python3
"""Generate a chart's values.schema.json from `# @schema` annotations in values.yaml.

The chart packages a *partial, open* JSON Schema: it declares only the paths
that carry an annotation, and never emits `additionalProperties`, `required`
or `$ref`. Helm validates every consumer's merged values against a packaged
schema, so a schema that typed every key, or closed any mapping, would change
install behaviour for existing deployments. Union Fleet's admission check, on
the other hand, accepts a rendered path only when values.yaml has it or the
packaged schema declares it. Annotating the paths that Fleet's templates set
but values.yaml does not contain is what this generator is for.

Annotation syntax follows helm-schema (github.com/dadav/helm-schema): a block
of comment lines between two `# @schema` markers, directly above the key it
describes. The block body is YAML. `properties` declares children that are
absent from values.yaml. A `# @schema.root` block before the first key
annotates the root object, which is how a top-level key that values.yaml
lacks (such as `provider`) is declared.

    # @schema
    # type: object
    # properties:
    #   AWS_ACCOUNT_ID: {type: string, description: Set by values.aws.yaml.}
    # @schema
    global:

Usage:
    python scripts/values_schema.py [--chart charts/dataplane]            # write
    python scripts/values_schema.py [--chart charts/dataplane] --check    # verify

Exit codes: 0 ok, 1 committed schema is stale (--check), 2 malformed annotation.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CHART = "charts/dataplane"
SCHEMA_FILE = "values.schema.json"
VALUES_FILE = "values.yaml"
DRAFT = "http://json-schema.org/draft-07/schema#"

MARKER = "# @schema"
ROOT_MARKER = "# @schema.root"

# JSON Schema keywords an annotation may use. Everything else is rejected so
# the generated schema stays open and self-contained.
ALLOWED_KEYS = {"type", "title", "description", "items", "properties", "$comment"}
# The type names Fleet's path check understands (cluster/fleet/validate/paths.go schemaKinds).
ALLOWED_TYPES = {"string", "boolean", "number", "integer", "object", "array", "null"}

# A mapping key at the start of a line: optional list dash, then a plain,
# single-quoted or double-quoted key, then a colon followed by whitespace or EOL.
KEY_RE = re.compile(
    r'^(?P<indent>\s*)(?P<dash>- )?(?P<key>"(?:[^"\\]|\\.)*"|\'(?:[^\']|\'\')*\'|[^\s#\-"\'][^:]*?):(?:\s|$)'
)


class AnnotationError(Exception):
    """A malformed or misplaced annotation. The message names the line."""


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _unquote(key: str) -> str:
    if len(key) >= 2 and key[0] == key[-1] and key[0] in "\"'":
        inner = key[1:-1]
        return (
            inner.replace("''", "'") if key[0] == "'" else inner.encode().decode("unicode_escape")
        )
    return key


def _comment_body(line: str, line_no: int) -> str:
    stripped = line.strip()
    if not stripped.startswith("#"):
        raise AnnotationError(f"line {line_no}: annotation block contains a non-comment line")
    body = stripped[1:]
    return body[1:] if body.startswith(" ") else body


def parse_annotations(text: str) -> tuple[dict | None, list[tuple[list[str], dict, int]]]:
    """Return (root block, [(path, node, line_no)]) for every annotation in text."""
    lines = text.splitlines()
    stack: list[tuple[int, str]] = []
    annotations: list[tuple[list[str], dict, int]] = []
    root: dict | None = None
    pending: tuple[int, dict, int] | None = None
    list_indent: int | None = None
    seen_key = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        line_no = i + 1
        if stripped in (MARKER, ROOT_MARKER):
            indent = _indent(line)
            body: list[str] = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != stripped:
                body.append(_comment_body(lines[j], j + 1))
                j += 1
            if j >= len(lines):
                raise AnnotationError(f"line {line_no}: unterminated {stripped} block")
            if _indent(lines[j]) != indent:
                raise AnnotationError(
                    f"line {j + 1}: closing {stripped} marker is not at the opening indent"
                )
            try:
                data = yaml.safe_load("\n".join(body))
            except yaml.YAMLError as err:
                raise AnnotationError(
                    f"line {line_no}: annotation body is not valid YAML: {err}"
                ) from err
            if not isinstance(data, dict) or not data:
                raise AnnotationError(
                    f"line {line_no}: annotation body must be a non-empty mapping"
                )
            if stripped == ROOT_MARKER:
                if seen_key or pending is not None:
                    raise AnnotationError(
                        f"line {line_no}: {ROOT_MARKER} must come before the first key"
                    )
                root = _merge(root or {}, data, "<root>", line_no)
            else:
                if pending is not None:
                    raise AnnotationError(f"line {line_no}: two annotation blocks before one key")
                pending = (indent, data, line_no)
            i = j + 1
            continue
        if not stripped:
            if pending is not None:
                raise AnnotationError(f"line {pending[2]}: annotation is not directly above a key")
            i += 1
            continue
        if stripped.startswith("#"):
            i += 1
            continue
        match = KEY_RE.match(line)
        indent = _indent(line)
        if list_indent is not None and indent <= list_indent:
            list_indent = None
        if match is None or list_indent is not None:
            # Continuation of a scalar, or a key that belongs to a list element.
            if pending is not None:
                raise AnnotationError(
                    f"line {pending[2]}: annotation is not directly above a mapping key"
                )
            i += 1
            continue
        if match.group("dash"):
            if pending is not None:
                raise AnnotationError(
                    f"line {pending[2]}: annotations inside list items are not supported"
                )
            list_indent = indent
            i += 1
            continue
        seen_key = True
        key = _unquote(match.group("key").strip())
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = [k for _, k in stack] + [key]
        if pending is not None:
            block_indent, data, block_line = pending
            if block_indent != indent:
                raise AnnotationError(
                    f"line {block_line}: annotation indent does not match key `{key}` on line {line_no}"
                )
            annotations.append((path, data, block_line))
            pending = None
        stack.append((indent, key))
        i += 1
    if pending is not None:
        raise AnnotationError(f"line {pending[2]}: annotation is not followed by a key")
    return root, annotations


def _merge(base: dict, extra: dict, where: str, line_no: int) -> dict:
    """Deep-merge two schema nodes; a differing scalar is a conflict."""
    for key, value in extra.items():
        if key not in base:
            base[key] = value
        elif isinstance(base[key], dict) and isinstance(value, dict):
            _merge(base[key], value, f"{where}.{key}", line_no)
        elif base[key] != value:
            raise AnnotationError(
                f"line {line_no}: `{where}` declares {key} twice with different values"
            )
    return base


def _validate_node(node: object, where: str, line_no: int) -> dict:
    if not isinstance(node, dict):
        raise AnnotationError(f"line {line_no}: `{where}` must be a mapping")
    unknown = set(node) - ALLOWED_KEYS
    if unknown:
        raise AnnotationError(
            f"line {line_no}: `{where}` uses unsupported keyword(s) {sorted(unknown)}; allowed: {sorted(ALLOWED_KEYS)}"
        )
    types = node.get("type")
    if types is not None:
        listed = types if isinstance(types, list) else [types]
        bad = [t for t in listed if t not in ALLOWED_TYPES]
        if bad or not listed:
            raise AnnotationError(
                f"line {line_no}: `{where}` has unsupported type {bad or types}; allowed: {sorted(ALLOWED_TYPES)}"
            )
    for text_key in ("title", "description", "$comment"):
        if text_key in node and not isinstance(node[text_key], str):
            raise AnnotationError(f"line {line_no}: `{where}` {text_key} must be a string")
    if "items" in node:
        node["items"] = _validate_node(node["items"], f"{where}.items", line_no)
    if "properties" in node:
        properties = node["properties"]
        if not isinstance(properties, dict) or not properties:
            raise AnnotationError(
                f"line {line_no}: `{where}` properties must be a non-empty mapping"
            )
        node["properties"] = {
            str(name): _validate_node(child, f"{where}.{name}", line_no)
            for name, child in properties.items()
        }
        declared = node.get("type", "object")
        if declared != "object":
            raise AnnotationError(
                f"line {line_no}: `{where}` declares properties but type {declared}"
            )
        node["type"] = "object"
    return node


def build_schema(root: dict | None, annotations: list[tuple[list[str], dict, int]]) -> dict:
    schema: dict = {"$schema": DRAFT, "type": "object", "properties": {}}
    if root is not None:
        node = _validate_node(dict(root), "<root>", 0)
        if node.get("type", "object") != "object":
            raise AnnotationError("root annotation must have type object")
        node.pop("type", None)
        _merge(schema, node, "<root>", 0)
    for path, data, line_no in annotations:
        node = _validate_node(data, ".".join(path), line_no)
        target = schema
        for segment in path[:-1]:
            target = target.setdefault("properties", {}).setdefault(segment, {"type": "object"})
            if target.get("type", "object") != "object":
                raise AnnotationError(
                    f"line {line_no}: `{'.'.join(path)}` nests under a non-object ancestor"
                )
            target["type"] = "object"
        properties = target.setdefault("properties", {})
        if path[-1] in properties:
            _merge(properties[path[-1]], node, ".".join(path), line_no)
        else:
            properties[path[-1]] = node
    return schema


def render(schema: dict) -> str:
    return json.dumps(schema, indent=2, sort_keys=True) + "\n"


def generate(chart_dir: Path) -> str:
    root, annotations = parse_annotations((chart_dir / VALUES_FILE).read_text())
    schema = build_schema(root, annotations)
    bundle_path = chart_dir / "fleet-contract.json"
    if bundle_path.exists():
        bundle = json.loads(bundle_path.read_text())
        if bundle.get("version") != 1:
            raise AnnotationError(
                "unsupported Fleet contract version; regenerate with cloud tooling"
            )
        fragment = _validate_node(bundle["schema"], "Fleet contract", 0)
        _merge(schema, fragment, "Fleet contract", 0)
    elif (chart_dir / "fleet-sources.json").exists():
        raise AnnotationError("missing generated fleet-contract.json")
    return render(schema)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--chart",
        default=DEFAULT_CHART,
        help="chart directory, relative to the repo root or absolute",
    )
    parser.add_argument(
        "--check", action="store_true", help="verify the committed schema matches; write nothing"
    )
    parser.add_argument(
        "--dump-owned",
        action="store_true",
        help="print chart annotations without generated Fleet declarations",
    )
    args = parser.parse_args(argv)
    chart_dir = Path(args.chart) if Path(args.chart).is_absolute() else REPO_ROOT / args.chart
    schema_path = chart_dir / SCHEMA_FILE
    try:
        if args.dump_owned:
            root, annotations = parse_annotations((chart_dir / VALUES_FILE).read_text())
            print(render(build_schema(root, annotations)), end="")
            return 0
        rendered = generate(chart_dir)
    except AnnotationError as err:
        print(f"{chart_dir / VALUES_FILE}: {err}", file=sys.stderr)
        return 2
    if args.check:
        current = schema_path.read_text() if schema_path.exists() else ""
        if current == rendered:
            return 0
        diff = difflib.unified_diff(
            current.splitlines(True), rendered.splitlines(True), str(schema_path), "generated"
        )
        sys.stderr.writelines(diff)
        print(f"{schema_path} is stale; run `make values-schema`", file=sys.stderr)
        return 1
    schema_path.write_text(rendered)
    print(f"wrote {schema_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
