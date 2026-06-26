import re
from datetime import datetime

import yaml

# Strict CalVer (YYYY.M.serial) with an optional SemVer-2 pre-release suffix:
#   2026.6.10            (stable)
#   2026.6.10-alpha.0    (pre-release)
_CALVER_RE = re.compile(r"^([1-9]\d{3}\.\d{1,2}\.\d+)(?:-(alpha|beta)\.(\d+))?$")
# Pre-release channels in promotion order. You may only move forward:
# alpha -> beta -> stable.
_CHANNELS = {"alpha": 0, "beta": 1}


class VersionFetcher(object):
    def __init__(self):
        pass

    def run(
        self,
        file: str = "Chart.yaml",
        key: str = "version",
        next: bool = True,
        prerelease: str = None,
    ) -> str:
        curr_version = self.get_chart_version(file, key)
        return self.get_calver(curr_version, next, prerelease)

    def get_chart_version(self, file, key: str) -> str:
        # Take a yaml Chart file and a key to determine the next
        # calver.
        with open(file, "r") as f:
            chart = yaml.load(f, Loader=yaml.FullLoader)

        if key not in chart:
            raise Exception(f"the requested key {key} was not found in the chart")

        return chart[key]

    def get_calver(self, version: str, next: bool, prerelease: str = None) -> str:
        if prerelease is not None and prerelease not in _CHANNELS:
            raise Exception(
                f"prerelease must be 'alpha' or 'beta', got {prerelease!r}"
            )

        base, channel, num = self.parse(version)

        if not next:
            return version

        # Stable bump (no pre-release requested).
        if prerelease is None:
            if channel is not None:
                # Promote an in-flight pre-release to its stable release: drop the
                # suffix, keep the base (2026.6.10-beta.2 -> 2026.6.10).
                return base
            return self.next_base(base)

        # Pre-release bump.
        if channel is None:
            # The first pre-release targets the NEXT base, so an alpha of the
            # released 2026.6.9 is 2026.6.10-alpha.0 (not 2026.6.9-alpha.0).
            return f"{self.next_base(base)}-{prerelease}.0"
        if channel == prerelease:
            # Same channel -> increment its counter.
            return f"{base}-{prerelease}.{num + 1}"
        if _CHANNELS[prerelease] > _CHANNELS[channel]:
            # Promote forward (alpha -> beta) on the same base; reset the counter.
            return f"{base}-{prerelease}.0"
        raise Exception(
            f"cannot move from {channel} back to {prerelease} on {base}"
        )

    def parse(self, version: str):
        """Split a version into (base, channel, num).

        channel and num are None for a plain stable CalVer.
        """
        match = _CALVER_RE.match(str(version))
        if not match:
            raise Exception(f"{version} is not a valid calver version")
        base, channel, num = match.group(1), match.group(2), match.group(3)
        return base, channel, (int(num) if num is not None else None)

    def next_base(self, base: str) -> str:
        now_yymm = self.current_yymm()
        curr_yymm, serial_str = base.rsplit(".", maxsplit=1)
        serial = int(serial_str)
        serial += 1
        if now_yymm != curr_yymm:
            # The months have changed so we need to reset the serial.
            serial = 0

        return f"{now_yymm}.{serial}"

    def current_yymm(self) -> str:
        return datetime.now().strftime("%Y.%-m")
