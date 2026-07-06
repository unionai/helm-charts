import shutil
import tempfile
from pathlib import Path
from unittest.mock import patch

from tasks.builder.version.bumper import VersionBumper
from tasks.builder.version.fetcher import VersionFetcher


@patch.object(VersionFetcher, "current_yymm", return_value="2025.3")
def test_run(_current_yymm):
    chart_tmp = Path(tempfile.mkdtemp()) / "Chart.yaml"
    chart_fixture = Path(__file__).parent / "fixtures" / "Chart.yaml"

    shutil.copy(chart_fixture, chart_tmp)

    bumper = VersionBumper()
    chart = bumper.get_chart(str(chart_tmp))

    # Just make sure we are getting the chart we expected
    assert chart["version"] == "2025.3.1"
    assert chart["appVersion"] == "2025.3.0"

    bumper.run(file=str(chart_tmp), key="version")
    bumper.run(file=str(chart_tmp), key="appVersion")

    chart = bumper.get_chart(str(chart_tmp))
    assert chart["version"] == "2025.3.2"
    assert chart["appVersion"] == "2025.3.1"


@patch.object(VersionFetcher, "current_yymm", return_value="2025.3")
def test_run_prerelease(_current_yymm):
    chart_tmp = Path(tempfile.mkdtemp()) / "Chart.yaml"
    chart_fixture = Path(__file__).parent / "fixtures" / "Chart.yaml"
    shutil.copy(chart_fixture, chart_tmp)

    bumper = VersionBumper()
    bumper.run(file=str(chart_tmp), key="version", prerelease="beta")

    chart = bumper.get_chart(str(chart_tmp))
    # 2025.3.1 -> beta of the next base 2025.3.2
    assert chart["version"] == "2025.3.2-beta.0"
