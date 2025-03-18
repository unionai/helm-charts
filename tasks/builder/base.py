import os
import sys
from pathlib import Path

from invoke import task

from tasks.builder.release.release import Release
from tasks.builder.version.bumper import VersionBumper
from tasks.builder.version.fetcher import VersionFetcher


@task(
    name="version_fetcher",
    help={
        "file": "The chart file to use in determining the version",
        "key": "The key in the chart file used in determining the version",
        "next": "Return the next version",
        "metadata_key": "The buildkite metadata key used to store the version",
    },
)
def version_fetcher(
    ctx, file: str, key: str = "version", next: bool = False, metadata_key: str = ""
):
    fetcher = VersionFetcher()
    version = fetcher.run(file=file, key=key, next=next)
    print(version)

    if metadata_key:
        ctx.run(f"buildkite-agent meta-data set {metadata_key} {version}")


@task(
    name="version_bumper",
    help={
        "file": "The chart file to use in determining the version",
        "key": "The key in the chart file used in determining the version",
    },
)
def version_bumper(ctx, file: str, key: str = "version"):
    bumper = VersionBumper()
    bumper.run(file=file, key=key, next=True)


@task(
    name="release",
    help={
        "chart": "The chart to release",
        "dryrun": "Don't actually release, just show the diff between the repos.",
    },
)
def release(ctx, chart: str, dryrun: bool = False):
    if chart == "":
        print("No chart specified")
        sys.exit(1)

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("GITHUB_TOKEN is a required environment variable")
        sys.exit(1)

    rel = Release(token=token)
    rel.run(chart=chart, dryRun=dryrun)
