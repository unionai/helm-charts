import copy
import json
from pathlib import Path

import check_fleet_paths
import pytest
import values_schema

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
