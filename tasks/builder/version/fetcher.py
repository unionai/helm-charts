import re
from datetime import datetime

import yaml


class VersionFetcher(object):
    def __init__(self):
        pass

    def run(
        self, file: str = "Chart.yaml", key: str = "version", next: bool = True
    ) -> str:
        curr_version = self.get_chart_version(file, key)
        return self.get_calver(curr_version, next)

    def get_chart_version(self, file, key: str) -> str:
        # Take a yaml Chart file and a key to determine the next
        # calver.
        with open(file, "r") as f:
            chart = yaml.load(f, Loader=yaml.FullLoader)

        if key not in chart:
            raise Exception(f"the requested key {key} was not found in the chart")

        return chart[key]

    def get_calver(self, version: str, next: bool) -> str:
        if not self.matches_caldev(version):
            raise Exception(f"{version} is not a valid calver version")

        if not next:
            return version

        now_yymm = self.current_yymm()
        curr_yymm, serial_str = version.rsplit(".", maxsplit=1)
        serial = int(serial_str)
        serial += 1
        if now_yymm != curr_yymm:
            # The months have changed so we need to reset the serial.
            serial = 0

        return f"{now_yymm}.{serial}"

    def current_yymm(self) -> str:
        return datetime.now().strftime("%Y.%-m")

    def matches_caldev(self, tag: str) -> bool:
        exp = "[1-9][0-9]{3}.[0-9]{1,2}.[0-9]+"
        match = re.match(exp, tag)
        if match:
            return True
