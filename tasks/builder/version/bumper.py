import yaml

from tasks.builder.version.fetcher import VersionFetcher


class VersionBumper:
    def __init__(self):
        pass

    def run(
        self,
        file: str = "Chart.yaml",
        key: str = "version",
        version: str = None,
        next: bool = True,
    ) -> None:
        if version is None:
            fetcher = VersionFetcher()
            version = fetcher.run(file=file, key=key, next=next)

        chart = self.get_chart(file=file)
        if key not in chart:
            raise Exception(f"the requested key {key} was not found in the chart")

        chart[key] = version
        self.write_chart(file=file, chart=chart)

        print(f"Bumped version to {version} in {file}")

    def get_chart(self, file: str = "Chart.yaml"):
        with open(file, "r") as f:
            chart = yaml.load(f, Loader=yaml.FullLoader)
        return chart

    def write_chart(self, file: str = "Chart.yaml", chart: dict = None):
        with open(file, "w") as f:
            yaml.dump(chart, f, Dumper=yaml.SafeDumper, sort_keys=False, width=450)
