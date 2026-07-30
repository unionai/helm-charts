#!/usr/bin/env python3
"""Configure cluster pools, queues, and (project, domain) routing for a
self-hosted control plane, following the flyte v2 queue model.

    configure_queues.py <terraform_workspace_dir>

<terraform_workspace_dir> is the org's terraform workspace dir (e.g.
infra/terraform/envs/staging/mike-apple-gcp). It must contain the
terraform-generated per-DP config contracts at

    <terraform_workspace_dir>/<cluster>/dataplane/cluster-pool.yaml

Model — deliberately create-only and additive. Neither the flyte-sdk nor the
API supports updating or deleting cluster pools, queues, or their routing at the
time of authoring (queue draining is gated server-side), so this script never
reconciles or removes; every change is additive (create constructs, (re)pin
routing). Re-runs are safe: existing pools/clusters/queues are tolerated. When
update/delete land, they can layer on without unwinding clever state detection.

  * One cluster pool per data plane, named after the data plane, created from
    that DP's generated cluster-pool.yaml config contract.
  * `flyte create cluster <dp> --pool <dp>` subscribes the cluster and implicitly
    creates a queue of the same name.
  * The three base projects (flytesnacks, system, union-health-monitoring) are
    always registered by the control plane. Extra projects listed under
    `projects:` in cicd.yaml are created here (flyte create project, additive).
    Any project routed below must exist — a base project or one created here.
  * By default those three base projects route to the first data plane
    (alphanumeric by name) across all domains — enough for the build-image
    bootstrap hook and functional tests to run.
  * An optional <terraform_workspace_dir>/cicd.yaml declares extra `projects:`
    to create and, via `functional_tests:`, pins a project (+ domain) to a queue
    (a data plane's name) with each entry's optional `queue`. The same
    `functional_tests:` section is consumed by the pipeline to emit one test step
    per entry. See cicd.example.yaml.

Requires the authenticated `flyte` v2 CLI (FLYTE_API_KEY set by the caller).
Re-runnable: pools/clusters/queues that already exist are tolerated.

See queue-configuration.md (next to this script) for the model and for DB-level
remediation when re-configuring an environment hits the queue subsystem's
immutable cluster/queue -> pool bindings.
"""

from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys
import tempfile

import yaml

DOMAINS = ["development", "staging", "production"]
# The three base projects the control plane always registers. They are always
# routed (to the first data plane by default) and are assumed to exist — this
# script never creates projects.
DEFAULT_PROJECTS = ["flytesnacks", "system", "union-health-monitoring"]

# Global `flyte` args prepended before every subcommand (e.g. `--config
# config.yaml`). Empty for the selfhosted path, which authenticates via
# FLYTE_API_KEY and needs no config file; set by --config for the managed /
# selfmanaged path, where the caller generates a config.yaml (clientId,
# endpoint) and the client secret arrives via
# FLYTE_CREDENTIALS_CLIENT_SECRET_FROM_FILE.
_FLYTE_GLOBAL_ARGS: list[str] = []


def dataplane_pool_files(workspace_dir: str) -> dict[str, str]:
    """data plane name -> path to its terraform-generated cluster-pool.yaml."""
    out: dict[str, str] = {}
    for path in sorted(
        glob.glob(os.path.join(workspace_dir, "*", "dataplane", "cluster-pool.yaml"))
    ):
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
        name = doc.get("name") or os.path.basename(
            os.path.dirname(os.path.dirname(path))
        )
        out[name] = path
    return out


def flyte(*args: str, tolerate_exists: bool = False) -> None:
    argv = ["flyte", *_FLYTE_GLOBAL_ARGS, *args]
    print(f":: {' '.join(argv)}")
    result = subprocess.run(argv, text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    if result.returncode == 0:
        return
    if tolerate_exists and "already exists" in (result.stdout + result.stderr).lower():
        print(":: already exists, continuing")
        return
    sys.stderr.write(result.stderr)
    raise SystemExit(f"`flyte {' '.join(args)}` failed (exit {result.returncode})")


def functional_test_routes(
    workspace_dir: str, first_dp: str
) -> list[tuple[str, str | None, str]]:
    """(project, domain-or-None, queue) rows for run.default_queue: the always-on
    base-project defaults first, then any `queue` pinned on a cicd.yaml
    `functional_tests:` entry (later rows win for the same project + domain).

    A functional_tests entry is the single source of routing: its optional
    `queue` pins the data plane that entry's (project, domain) runs on. Base
    projects default to the first data plane; an entry without a `queue` adds no
    route (it runs wherever its project + domain already routes).

    Every project referenced must exist — a base project or one created from
    cicd.yaml `projects:`.
    """
    routes: list[tuple[str, str | None, str]] = [
        (p, None, first_dp) for p in DEFAULT_PROJECTS
    ]
    path = os.path.join(workspace_dir, "cicd.yaml")
    if os.path.exists(path):
        with open(path) as f:
            spec = yaml.safe_load(f) or {}
        for test in spec.get("functional_tests") or []:
            if test.get("queue"):
                routes.append((test["project"], test.get("domain"), test["queue"]))
    return routes


def load_projects(workspace_dir: str) -> list[str]:
    """Extra project names to create, from cicd.yaml `projects:` (create-only).

    The three base projects are always registered by the control plane and need
    not be listed. Returns [] when the file or the section is absent.
    """
    path = os.path.join(workspace_dir, "cicd.yaml")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        spec = yaml.safe_load(f) or {}
    projects = spec.get("projects") or []
    if not isinstance(projects, list) or not all(
        isinstance(p, str) and p for p in projects
    ):
        raise SystemExit(f"{path}: `projects` must be a list of non-empty strings")
    return projects


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "terraform_workspace_dir", help="the org's terraform workspace dir"
    )
    parser.add_argument(
        "--config",
        default=None,
        help=(
            "path to a flyte config.yaml, forwarded to every `flyte` call as "
            "`--config <path>`. Use for the managed / selfmanaged path where "
            "auth is a generated config.yaml + client-secret file rather than "
            "FLYTE_API_KEY. Omit for the selfhosted (FLYTE_API_KEY) path."
        ),
    )
    args = parser.parse_args()

    if args.config:
        _FLYTE_GLOBAL_ARGS[:] = ["--config", args.config]

    pools = dataplane_pool_files(args.terraform_workspace_dir)
    if not pools:
        print(
            f"no <cluster>/dataplane/cluster-pool.yaml under {args.terraform_workspace_dir}; "
            "nothing to configure",
            file=sys.stderr,
        )
        return 0

    print("--- 💾 Ensuring cluster pools and clusters exist")

    # One pool + cluster (=> queue) per data plane, all sharing the DP name.
    for dp, pool_file in pools.items():
        flyte("create", "cluster-pool", dp, "--file", pool_file, tolerate_exists=True)
        flyte("create", "cluster", dp, "--pool", dp, tolerate_exists=True)

    # Extra projects declared in cicd.yaml. Base projects are already registered
    # by the control plane; these are created before routing so `flyte edit
    # settings` below has a project to attach to.
    projects = load_projects(args.terraform_workspace_dir)
    if projects:
        print("--- 💾 Creating declared projects")
        for project in projects:
            flyte(
                "create",
                "project",
                "--id",
                project,
                "--name",
                project,
                tolerate_exists=True,
            )

    first_dp = sorted(pools)[0]
    routes = functional_test_routes(args.terraform_workspace_dir, first_dp)

    print("--- 💾 Configuring run.default_queue for every project domain pair")

    # Projects now exist (base projects always, cicd.yaml `projects:` created
    # above). `flyte edit settings` below attaches routing to an existing
    # project; it does not register one.

    with tempfile.TemporaryDirectory() as tmp:
        for project, domain, queue in routes:
            for d in [domain] if domain else DOMAINS:
                settings = os.path.join(tmp, f"settings-{project}-{d}.yaml")
                with open(settings, "w") as f:
                    f.write(f"run.default_queue: {queue}\n")
                flyte(
                    "edit",
                    "settings",
                    "--project",
                    project,
                    "--domain",
                    d,
                    "--from-file",
                    settings,
                )

    print("--- ✅ Queue configuration complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
