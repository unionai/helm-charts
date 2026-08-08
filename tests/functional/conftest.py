"""Pytest fixtures + hooks for the integration functional suite.

Runs the same flyte v2 scenarios the release-integration workflow's "Functional
tests" step drives, now as standard pytest. Reads the leg's contract from the
environment (set by the workflow's creds-resolution step): CONTROL_PLANE_URL,
FLYTE_API_KEY, CLUSTER_NAME, ORG_NAME. Task definitions live in tasks/ (one module
per scenario: simple, imgbuild, imgcache, reusable, trigger, app); shared
client/retry helpers in flyte_ops.py. Transient reruns via pytest-rerunfailures
(--only-rerun patterns in pyproject.toml).
"""

from __future__ import annotations

import asyncio
import os
import sys

import pytest

# flyte_ops.py sits in this dir (already on pytest's sys.path); the task modules
# live in tasks/ — put that on sys.path so they import by name.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "tasks"))

import app  # noqa: E402,F401
import flyte_ops  # noqa: E402

# Import the task modules once, up front: their module-level TaskEnvironment()s must
# register before the first flyte.init so a later import can't reset client routing.
import imgbuild  # noqa: E402,F401
import imgcache  # noqa: E402,F401
import reusable  # noqa: E402,F401
import simple  # noqa: E402,F401
import trigger  # noqa: E402,F401


def pytest_addoption(parser):
    parser.addoption(
        "--skip-app",
        action="store_true",
        help="Skip test_app (app serving is unsupported on selfhosted).",
    )
    parser.addoption(
        "--skip-logs",
        action="store_true",
        help="Skip test_logs (needs a log backend; k3d has none).",
    )


def pytest_configure(config):
    config.addinivalue_line("markers", "app: app-serving test, skipped with --skip-app")
    config.addinivalue_line("markers", "logs: log-persistence test, skipped with --skip-logs")


# Run light/warming scenarios first, heaviest (app) last. The app deploy (two
# image builds + Knative cold-start) is much slower — and flaked past the 600s
# wait — when it runs first on a cold cluster, before buildkit/operator warm up.
_ORDER = {
    "test_simple": 0,
    "test_image_builder": 1,
    "test_image_cache": 2,
    "test_io": 3,
    "test_logs": 4,
    "test_trigger": 5,
    "test_reusable": 6,
    "test_app": 7,
}


def pytest_collection_modifyitems(config, items):
    skip_app = pytest.mark.skip(reason="--skip-app: app serving unsupported on this topology")
    skip_logs = pytest.mark.skip(reason="--skip-logs: no log backend on this topology")
    for item in items:
        if config.getoption("--skip-app") and "app" in item.keywords:
            item.add_marker(skip_app)
        if config.getoption("--skip-logs") and "logs" in item.keywords:
            item.add_marker(skip_logs)
    items.sort(key=lambda it: _ORDER.get(it.name.split("[")[0], 3))


@pytest.fixture(scope="session")
def ci_env() -> dict:
    """The leg's control-plane contract, from the workflow-set environment."""
    return {
        "control_plane_url": os.environ["CONTROL_PLANE_URL"],
        "api_key": os.environ.get("FLYTE_API_KEY", ""),
        "cluster_name": os.environ["CLUSTER_NAME"],
        "org": os.environ.get("ORG_NAME", ""),
        # TaskEnvironment naming suffix (defaults to the cluster); matches the
        # tasks' _env_suffix so tests that reference an env name stay in sync.
        "env_suffix": os.environ.get("ENV_SUFFIX") or os.environ["CLUSTER_NAME"],
    }


@pytest.fixture
def flyte_ctx(ci_env) -> dict:
    """Re-initialise the flyte client to this leg's project/org before each test.

    Re-init per test because importing a task module (module-level
    TaskEnvironment()) can reset the client's project/org routing.
    """
    asyncio.run(
        flyte_ops.init_client(
            ci_env["control_plane_url"],
            ci_env["api_key"],
            project=ci_env["cluster_name"],
            org=ci_env["org"],
        )
    )
    return ci_env


# ── GitHub job-summary results table ──────────────────────────────────────────
_SCENARIO = {  # test function name → scenario label shown in the summary
    "test_simple": "verify_simple",
    "test_io": "verify_io",
    "test_logs": "verify_logs",
    "test_image_builder": "verify_image_builder",
    "test_image_cache": "verify_image_cache",
    "test_reusable": "verify_reusable",
    "test_trigger": "verify_trigger",
    "test_app": "verify_app",
}


def pytest_terminal_summary(terminalreporter):
    """Render a Markdown results table to the GitHub job-summary page."""
    # Under pytest-xdist this hook fires in every worker too, but only the
    # controller holds the aggregated stats — skip workers so they don't append
    # duplicate partial tables to the step summary.
    if os.environ.get("PYTEST_XDIST_WORKER"):
        return
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    tr = terminalreporter.stats
    rows = []  # (scenario, outcome)
    for outcome, icon in (
        ("passed", "✅ PASSED"),
        ("failed", "❌ FAILED"),
        ("error", "❌ ERROR"),
        ("skipped", "⏭️ SKIPPED"),
    ):
        for rep in tr.get(outcome, []):
            fn = rep.nodeid.rsplit("::", 1)[-1]
            rows.append((_SCENARIO.get(fn, fn), icon))
    if not rows:
        return
    passed = sum(1 for _, o in rows if "PASSED" in o)
    skipped = sum(1 for _, o in rows if "SKIPPED" in o)
    total = len(rows) - skipped
    cluster = os.environ.get("CLUSTER_NAME", "")
    md = [
        f"## Functional tests — {cluster}",
        "",
        f"**{passed}/{total} passed**" + (f" · {skipped} skipped" if skipped else ""),
        "",
        "| Scenario | Result |",
        "| --- | --- |",
    ]
    md += [f"| {name} | {icon} |" for name, icon in sorted(rows)]
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(md).rstrip() + "\n")
    except OSError as e:
        print(f"[ci] step-summary write failed (ignored): {e}", flush=True)
