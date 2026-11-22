import json
import textwrap
from pathlib import Path

import check_fleet_paths
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


@pytest.mark.parametrize(
    "text, segments",
    [
        ("provider", ["provider"]),
        ("global.AWS_REGION", ["global", "AWS_REGION"]),
        (
            'proxy.podAnnotations["karpenter.sh/do-not-disrupt"]',
            ["proxy", "podAnnotations", "karpenter.sh/do-not-disrupt"],
        ),
        ('a["x.y"].b', ["a", "x.y", "b"]),
    ],
)
def test_parse_path(text, segments):
    assert check_fleet_paths.parse_path(text) == segments


@pytest.mark.parametrize("text", ["", "a..b", 'a["unterminated', "a[b]"])
def test_parse_path_rejects_malformed(text):
    with pytest.raises(ValueError):
        check_fleet_paths.parse_path(text)


def make_chart(tmp_path: Path, values: str, schema: dict | None = None) -> Path:
    (tmp_path / "values.yaml").write_text(textwrap.dedent(values))
    if schema is not None:
        (tmp_path / "values.schema.json").write_text(json.dumps(schema))
    return tmp_path


def make_fixture(tmp_path: Path, *paths: str) -> Path:
    fixture = tmp_path / "paths.txt"
    fixture.write_text("# comment\n\n" + "\n".join(paths) + "\n")
    return fixture


def test_each_acceptance_branch(tmp_path):
    chart = make_chart(
        tmp_path,
        """
        global:
          HOST: ""
        storage:
          custom: {}
        config:
          proxy:
            smConfig:
              enabled: "x"
        """,
        {
            "properties": {
                "config": {
                    "properties": {
                        "proxy": {
                            "properties": {
                                "smConfig": {
                                    "properties": {
                                        "awsConfig": {"properties": {"account": {"type": "string"}}}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
    )
    fixture = make_fixture(
        tmp_path,
        "global.HOST  # in values.yaml",
        'storage.custom["a.b/c"]  # open map',
        "storage.custom.stow.kind  # open map, deeper",
        "config.proxy.smConfig.awsConfig.account  # schema",
    )
    assert check_fleet_paths.check(chart, fixture) == []


def test_missing_paths_are_reported(tmp_path):
    chart = make_chart(tmp_path, "global:\n  HOST: ''\nconfig:\n  k8s:\n    plugins: {a: 1}\n")
    fixture = make_fixture(
        tmp_path,
        "global.HOST",
        "global.MISSING",
        "config.k8s.plugins.k8s.default-labels",
        "global.HOST.deeper",
    )
    failures = check_fleet_paths.check(chart, fixture)
    assert [f.split(": ")[1].split(" is ")[0] for f in failures] == [
        "global.MISSING",
        "config.k8s.plugins.k8s.default-labels",
        "global.HOST.deeper",
    ]
    assert all("neither in values.yaml" in f for f in failures)


def test_schema_without_properties_chain_does_not_accept(tmp_path):
    chart = make_chart(tmp_path, "a:\n  b: 1\n", {"properties": {"a": {"type": "object"}}})
    assert len(check_fleet_paths.check(chart, make_fixture(tmp_path, "a.c"))) == 1


def test_empty_fixture_is_an_error(tmp_path):
    chart = make_chart(tmp_path, "a: 1\n")
    with pytest.raises(ValueError, match="lists no paths"):
        check_fleet_paths.check(chart, make_fixture(tmp_path))


def test_main_exit_codes(tmp_path, capsys):
    chart = make_chart(tmp_path, "a: 1\n")
    ok = make_fixture(tmp_path, "a")
    assert check_fleet_paths.main(["--chart", str(chart), "--fixture", str(ok)]) == 0
    bad = make_fixture(tmp_path, "a", "b")
    assert check_fleet_paths.main(["--chart", str(chart), "--fixture", str(bad)]) == 1
    assert "1 Fleet value path(s) are not accepted" in capsys.readouterr().err
