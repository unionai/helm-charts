import copy
import json
from pathlib import Path

import check_fleet_paths
import pytest
import values_schema
import yaml

REAL_CHART = Path(__file__).resolve().parents[2] / "charts/dataplane"


def chart_copy(tmp_path):
    for name in ("values.yaml", "values.schema.json", "fleet-contract.json", "fleet-sources.json"):
        (tmp_path / name).write_bytes((REAL_CHART / name).read_bytes())
    return tmp_path


def test_all_generated_scenarios_are_accepted():
    assert check_fleet_paths.check_bundle(REAL_CHART) == []


def test_coverage_detects_unknown_paths_and_wrong_types(tmp_path):
    chart = chart_copy(tmp_path)
    original = json.loads((chart / "fleet-contract.json").read_text())
    for replacement, expected in (
        ({"unknownCandidatePath": True}, "not declared"),
        ({"provider": False}, "wrong type"),
    ):
        bundle = copy.deepcopy(original)
        bundle["scenarios"][0]["vendor"] = replacement
        (chart / "fleet-contract.json").write_text(json.dumps(bundle))
        assert any(expected in failure for failure in check_fleet_paths.check_bundle(chart))


def test_coverage_requires_all_providers_and_optional_variants(tmp_path):
    chart = chart_copy(tmp_path)
    bundle = json.loads((chart / "fleet-contract.json").read_text())
    bundle["scenarios"] = [
        scenario for scenario in bundle["scenarios"] if scenario["provider"] != "azure"
    ]
    (chart / "fleet-contract.json").write_text(json.dumps(bundle))
    assert any("all four providers" in failure for failure in check_fleet_paths.check_bundle(chart))


def test_generated_fragments_obey_the_annotation_policy(tmp_path):
    chart = chart_copy(tmp_path)
    bundle = json.loads((chart / "fleet-contract.json").read_text())
    bundle["schema"]["properties"]["bad"] = {"type": "string", "enum": ["restricted"]}
    (chart / "fleet-contract.json").write_text(json.dumps(bundle))
    with pytest.raises(values_schema.AnnotationError, match="enum"):
        values_schema.generate(chart)


def test_generated_bundle_is_required_when_sources_are_present(tmp_path):
    chart = chart_copy(tmp_path)
    (chart / "fleet-contract.json").unlink()
    with pytest.raises(values_schema.AnnotationError, match="missing generated"):
        values_schema.generate(chart)


def test_declared_types_apply_under_empty_default_mappings(tmp_path):
    chart = chart_copy(tmp_path)
    defaults = yaml.safe_load((chart / "values.yaml").read_text())
    defaults["covered"] = {}
    (chart / "values.yaml").write_text(yaml.safe_dump(defaults))
    schema = json.loads((chart / "values.schema.json").read_text())
    schema["properties"]["covered"] = {
        "type": "object",
        "properties": {"typedLeaf": {"type": "string"}},
    }
    (chart / "values.schema.json").write_text(json.dumps(schema))
    bundle = json.loads((chart / "fleet-contract.json").read_text())
    bundle["scenarios"][0]["vendor"] = {"covered": {"typedLeaf": False, "openKey": "ok"}}
    (chart / "fleet-contract.json").write_text(json.dumps(bundle))
    failures = check_fleet_paths.check_bundle(chart)
    assert any("covered.typedLeaf has the wrong type" in failure for failure in failures)
    assert not any("openKey" in failure for failure in failures)


@pytest.mark.parametrize(
    "value,types,valid",
    [
        (None, "string", False),
        (None, ["string", "null"], True),
        (False, "string", False),
        (0.5, "integer", False),
        (1.0, "integer", True),
    ],
)
def test_schema_types_validate_null_and_numeric_values(tmp_path, value, types, valid):
    chart = chart_copy(tmp_path)
    schema = json.loads((chart / "values.schema.json").read_text())
    schema["properties"]["optionalProbe"] = {"type": types}
    (chart / "values.schema.json").write_text(json.dumps(schema))
    bundle = json.loads((chart / "fleet-contract.json").read_text())
    bundle["scenarios"][0]["vendor"] = {"optionalProbe": value}
    (chart / "fleet-contract.json").write_text(json.dumps(bundle))
    assert (check_fleet_paths.check_bundle(chart) == []) == valid


def test_explicit_type_is_checked_when_default_kind_matches_the_bad_value(tmp_path):
    chart = chart_copy(tmp_path)
    defaults = yaml.safe_load((chart / "values.yaml").read_text())
    defaults["provider"] = False
    (chart / "values.yaml").write_text(yaml.safe_dump(defaults))
    bundle = json.loads((chart / "fleet-contract.json").read_text())
    bundle["scenarios"][0]["vendor"] = {"provider": True}
    (chart / "fleet-contract.json").write_text(json.dumps(bundle))
    assert any(
        "provider has the wrong type" in failure
        for failure in check_fleet_paths.check_bundle(chart)
    )
