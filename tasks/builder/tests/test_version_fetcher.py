from pathlib import Path
from unittest.mock import patch

import pytest

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
    with patch.object(VersionFetcher, "current_yymm") as current_ymm_mock:
        current_ymm_mock.return_value = "2025.3"
        assert "2025.3.1" == fetcher.get_calver("2025.3.0", next=True)
        assert "2025.3.0" == fetcher.get_calver("2025.3.0", next=False)
        assert "2025.3.0" == fetcher.get_calver("2025.2.9", next=True)
        assert "2025.2.9" == fetcher.get_calver("2025.2.9", next=False)

        with pytest.raises(Exception) as exc_info:
            fetcher.get_calver("1.2.3", next=True)


def test_get_calver_prerelease():
    fetcher = VersionFetcher()
    with patch.object(VersionFetcher, "current_yymm") as current_ymm_mock:
        current_ymm_mock.return_value = "2026.6"

        # First pre-release targets the NEXT base.
        assert "2026.6.10-alpha.0" == fetcher.get_calver(
            "2026.6.9", next=True, prerelease="alpha"
        )
        assert "2026.6.10-beta.0" == fetcher.get_calver(
            "2026.6.9", next=True, prerelease="beta"
        )

        # Same channel increments its counter.
        assert "2026.6.10-alpha.1" == fetcher.get_calver(
            "2026.6.10-alpha.0", next=True, prerelease="alpha"
        )
        assert "2026.6.10-beta.3" == fetcher.get_calver(
            "2026.6.10-beta.2", next=True, prerelease="beta"
        )

        # Promote forward alpha -> beta on the same base, reset the counter.
        assert "2026.6.10-beta.0" == fetcher.get_calver(
            "2026.6.10-alpha.3", next=True, prerelease="beta"
        )

        # Stable bump of a pre-release drops the suffix in place (promotion).
        assert "2026.6.10" == fetcher.get_calver("2026.6.10-beta.2", next=True)

        # next=False returns the version untouched, suffix and all.
        assert "2026.6.10-beta.2" == fetcher.get_calver(
            "2026.6.10-beta.2", next=False, prerelease="beta"
        )

        # Going backward (beta -> alpha) is rejected.
        with pytest.raises(Exception):
            fetcher.get_calver("2026.6.10-beta.0", next=True, prerelease="alpha")

        # Unknown channel is rejected.
        with pytest.raises(Exception):
            fetcher.get_calver("2026.6.9", next=True, prerelease="rc")
