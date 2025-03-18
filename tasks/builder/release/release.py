import pprint
import shutil
import subprocess
import sys
import tempfile
from os import listdir
from pathlib import Path

import github.Auth
import yaml
from git import Repo
from github import Github, GithubException

from tasks.builder.version.bumper import VersionBumper
from tasks.builder.version.fetcher import VersionFetcher


class Release:
    def __init__(self, token=None):
        self.auth = github.Auth.AppAuthToken(token)
        pass

    def run(self, chart: str, dryRun: bool = False):
        tmp_root = repo_dir = tempfile.mkdtemp()
        tmp_chart_path = Path(tmp_root) / "charts" / chart

        try:
            repo = Repo.clone_from(
                "git@github.com:unionai/helm-charts.git", to_path=tmp_root
            )

            fetcher = VersionFetcher()
            version = fetcher.run(
                str(tmp_chart_path / "Chart.yaml"), key="version", next=True
            )

            # TODO(rob): We should add/expect release notes as part of a changelog that we can
            #  add to the description.
            notes = f"Release {version} for {chart}"
            title = f"release/{chart}: {version}"
            branch = f"release/{chart}_{version}"

            head = repo.create_head(branch)
            head.checkout()

            # Copy any new chart data over to the temporary repo
            # self.rsync_chart_updates(chart_path, tmp_chart_path)

            # Version bump
            bumper = VersionBumper()
            bumper.run(
                file=str(tmp_chart_path / "Chart.yaml"), key="version", next=True
            )

            # Output a diff
            self.diff(repo)
            if dryRun:
                print("Exiting on dry run")
                sys.exit(0)

            # Create a new release branch/pr
            self.commit_and_push(repo, branch=branch, notes=notes, title=title)
        except Exception as e:
            print(e)
            sys.exit(1)
        finally:
            shutil.rmtree(tmp_chart_path)

    def bump(self, file: str):
        bumper = VersionBumper()
        bumper.run(file=file, key="version", next=True)

    def diff(self, repo):
        diffs = repo.index.diff(None, create_patch=True)
        for diff in diffs:
            print(diff)

    def commit_and_push(self, repo, branch: str, title: str, notes: str) -> None:
        repo.git.add(all=True)
        repo.index.commit(title)
        origin = repo.remote("origin")
        origin.push(branch)

        gh = Github(auth=self.auth)
        gh_repo = gh.get_repo("unionai/helm-charts")

        pr = gh_repo.create_pull(
            title=title,
            body=notes,
            head=branch,
            base="main",
        )

        pr.add_to_labels("release")
