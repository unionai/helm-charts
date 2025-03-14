import pprint
import shutil
import subprocess
import sys
from pathlib import Path

import github.Auth
import yaml
from git import Repo
import tempfile
from os import listdir

from github import Github, GithubException

from tasks.builder.version.bumper import VersionBumper
from tasks.builder.version.fetcher import VersionFetcher


class Release:
    def __init__(self, token=None):
        self.auth = github.Auth.AppAuthToken(token)
        pass

    def run(self, chart: str, dryRun: bool = False) -> None:
        root = Path(__file__).resolve().parent / '..' / '..' / '..'
        chart_path = root / 'charts' / chart / 'Chart.yaml'

        repo = Repo(path=Path(__file__).resolve().parent / '..' / '..' / '..')
        origin = repo.remote(name='origin')

        fetcher = VersionFetcher()
        version = fetcher.run(file=str(chart_path), key="version", next=True)

        release_branch = f'release/{chart}: {version}'
        repo.create_head(release_branch)

        bumper = VersionBumper()
        bumper.run(file=str(chart_path), key="version", version=version)

        print(repo.index.diff(create_patch=True))
        if dryRun:
            print('Dry run detected, stopping before release')
            sys.exit(0)

        repo.git.add(all=True)
        release_title = f'release({chart}): {version}'
        repo.index.commit(release_title)

        origin = repo.remote(name='origin')
        origin.push()

        # Clean up the local branch
        repo.delete_head(release_branch)

        # try:
        #     gh = Github(auth=self.auth)
        #     gh_repo = gh.get_repo('unionai/helm-charts')
        #
        #     # TODO(rob): We should add/expect release notes as part of a changelog that we can
        #     #  add to the description.
        #     release_notes = f"Release {cloud_chart_version}"
        #     pr = gh_repo.create_pull(
        #         title=release_title,
        #         body=release_notes,
        #         head=branch,
        #         base='main',
        #     )
        #
        # except GithubException as e:
        #     print(e.message)
        #     sys.exit(1)
        # finally:
        #     shutil.rmtree(repo_dir)

    def get_chart(self, file: str = "Chart.yaml"):
        with open(file, "r") as f:
            chart = yaml.load(f, Loader=yaml.FullLoader)
        return chart
