import json
import textwrap
from pathlib import Path

import pytest
import values_schema

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REAL_CHART = REPO_ROOT / "charts" / "dataplane"


def leaves(schema: dict, prefix: tuple[str, ...] = ()) -> dict[str, str]:
    properties = schema.get("properties")
    if not properties:
        return {".".join(prefix): schema.get("type")}
    found: dict[str, str] = {}
    for name, child in properties.items():
        found.update(leaves(child, prefix + (name,)))
    return found


def chart(tmp_path: Path, values: str) -> Path:
    (tmp_path / "values.yaml").write_text(textwrap.dedent(values))
    return tmp_path


def generate(tmp_path: Path, values: str) -> dict:
    return json.loads(values_schema.generate(chart(tmp_path, values)))


def test_annotated_children_absent_from_defaults(tmp_path):
    schema = generate(
        tmp_path,
        """
        # @schema
        # type: object
        # properties:
        #   ACCOUNT: {type: string, description: Set by the overlay.}
        # @schema
        global:
          HOST: ""
        other: 1
        """,
    )
    assert schema["$schema"] == values_schema.DRAFT
    assert schema["type"] == "object"
    assert schema["properties"] == {
        "global": {
            "type": "object",
            "properties": {"ACCOUNT": {"type": "string", "description": "Set by the overlay."}},
        }
    }
    assert "additionalProperties" not in json.dumps(schema)


def test_root_block_declares_top_level_key(tmp_path):
    schema = generate(
        tmp_path,
        """
        # @schema.root
        # properties:
        #   provider: {type: string}
        # @schema.root
        global:
          HOST: ""
        """,
    )
    assert schema["properties"] == {"provider": {"type": "string"}}


def test_nested_annotation_builds_object_ancestors(tmp_path):
    schema = generate(
        tmp_path,
        """
        config:
          proxy:
            # -- helm-docs comment stays between the block and the key
            # @schema
            # properties:
            #   awsConfig:
            #     properties:
            #       account: {type: string}
            # @schema
            smConfig:
              enabled: "{{ .Values.x }}"
        """,
    )
    assert leaves(schema) == {"config.proxy.smConfig.awsConfig.account": "string"}
    assert schema["properties"]["config"]["type"] == "object"
    assert (
        schema["properties"]["config"]["properties"]["proxy"]["properties"]["smConfig"]["type"]
        == "object"
    )


def test_keys_inside_list_items_do_not_shift_paths(tmp_path):
    schema = generate(
        tmp_path,
        """
        a:
          items:
            - name: x
              deep:
                deeper: 1
          # @schema
          # type: string
          # @schema
          b: ""
        """,
    )
    assert leaves(schema) == {"a.b": "string"}


def test_quoted_keys_with_dots_and_slashes_stay_literal(tmp_path):
    schema = generate(
        tmp_path,
        """
        proxy:
          podAnnotations:
            # @schema
            # type: string
            # @schema
            "karpenter.sh/do-not-disrupt": "true"
        """,
    )
    assert leaves(schema) == {"proxy.podAnnotations.karpenter.sh/do-not-disrupt": "string"}
    assert (
        "karpenter.sh/do-not-disrupt"
        in schema["properties"]["proxy"]["properties"]["podAnnotations"]["properties"]
    )


def test_output_is_deterministic(tmp_path):
    values = """
        # @schema
        # properties:
        #   z: {type: string}
        #   a: {type: string}
        # @schema
        m: {}
        """
    first = values_schema.generate(chart(tmp_path, values))
    second = values_schema.generate(tmp_path)
    assert first == second
    assert first.index('"a"') < first.index('"z"')


@pytest.mark.parametrize(
    "values, message",
    [
        ("# @schema\n# type: string\n", "unterminated"),
        ("# @schema\n# type: string\nkey: 1\n", "non-comment line"),
        ("# @schema\n# - not a mapping\n# @schema\nkey: 1\n", "non-empty mapping"),
        ("# @schema\n# type: string\n# @schema\n\nkey: 1\n", "not directly above a key"),
        ("outer:\n  # @schema\n  # type: string\n  # @schema\nnext: 1\n", "does not match key"),
        (
            "key: 1\n# @schema.root\n# properties: {p: {type: string}}\n# @schema.root\nother: 2\n",
            "before the first key",
        ),
        ("items:\n  # @schema\n  # type: string\n  # @schema\n  - name: x\n", "list items"),
        (
            "# @schema\n# type: string\n# additionalProperties: false\n# @schema\nkey: 1\n",
            "additionalProperties",
        ),
        ("# @schema\n# type: object\n# required: [a]\n# @schema\nkey: {}\n", "required"),
        ("# @schema\n# $ref: '#/definitions/x'\n# @schema\nkey: 1\n", r"\$ref"),
        ("# @schema\n# type: tuple\n# @schema\nkey: 1\n", "unsupported type"),
        ("# @schema\n# type: string\n# enum: [aws]\n# @schema\nkey: ''\n", "enum"),
        (
            "# @schema\n# properties: {child: {type: string, enum: [aws]}}\n# @schema\nkey: {}\n",
            "enum",
        ),
        (
            "# @schema\n# type: array\n# items: {type: string, enum: [aws]}\n# @schema\nkey: []\n",
            "enum",
        ),
        (
            "# @schema\n# type: string\n# properties: {a: {type: string}}\n# @schema\nkey: {}\n",
            "declares properties but type string",
        ),
        (
            "# @schema\n# type: object\n# @schema\n# @schema\n# type: string\n# @schema\nkey: {}\n",
            "two annotation blocks",
        ),
        ("# @schema\n# type: string\n# @schema\n", "not followed by a key"),
    ],
)
def test_malformed_annotations_are_rejected(tmp_path, values, message):
    with pytest.raises(values_schema.AnnotationError, match=message):
        values_schema.generate(chart(tmp_path, values))


def test_check_mode_exit_codes(tmp_path, capsys):
    chart(tmp_path, "# @schema\n# type: string\n# @schema\nkey: ''\n")
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 1
    assert "stale" in capsys.readouterr().err
    assert values_schema.main(["--chart", str(tmp_path)]) == 0
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 0
    (tmp_path / "values.yaml").write_text("# @schema\n# type: boolean\n# @schema\nkey: true\n")
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 1
    diff = capsys.readouterr().err
    assert '-      "type": "string"' in diff
    assert '+      "type": "boolean"' in diff
    (tmp_path / "values.yaml").write_text("# @schema\n# type: boolean\nkey: true\n")
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 2


def test_real_dataplane_contract_is_open_and_current():
    schema = json.loads(values_schema.generate(REAL_CHART))
    labels = schema["properties"]["config"]["properties"]["k8s"]["properties"]["plugins"][
        "properties"
    ]["k8s"]["properties"]["default-labels"]
    assert labels["type"] == ["array", "object"]
    assert "additionalProperties" not in json.dumps(schema)
    assert "enum" not in json.dumps(schema)
    assert values_schema.generate(REAL_CHART) == (REAL_CHART / "values.schema.json").read_text()
