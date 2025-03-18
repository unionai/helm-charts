from pathlib import Path

import pytest
from unittest.mock import patch

from tasks.builder.version.fetcher import VersionFetcher


def test_get_chart_version():
    fetcher = VersionFetcher()
    chart_path = Path(__file__).parent / "fixtures" / "Chart.yaml"
    assert "2025.3.1" == fetcher.get_chart_version(chart_path, "version")
    assert "2025.3.0" == fetcher.get_chart_version(chart_path, "appVersion")

    with pytest.raises(Exception):
        fetcher.get_chart_version(chart_path, "nope")


def test_get_calver():
    fetcher = VersionFetcher()
    with patch.object(VersionFetcher, 'current_yymm') as current_ymm_mock:
        current_ymm_mock.return_value = '2025.3'
        assert "2025.3.1" == fetcher.get_calver("2025.3.0", next=True)
        assert "2025.3.0" == fetcher.get_calver("2025.3.0", next=False)
        assert "2025.3.0" == fetcher.get_calver("2025.2.9", next=True)
        assert "2025.2.9" == fetcher.get_calver("2025.2.9", next=False)

        with pytest.raises(Exception) as exc_info:
            fetcher.get_calver("1.2.3", next=True)
