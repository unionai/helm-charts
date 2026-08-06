"""App-serving check (selfmanaged / managed only; skipped on selfhosted)."""

from __future__ import annotations

import asyncio

import flyte_ops
import pytest


@pytest.mark.app
def test_app(flyte_ctx):
    """Deploy a FastAPI app, hit internal endpoints, deactivate; assert it landed
    on this run's dataplane (the task asserts assigned_cluster == CLUSTER_NAME)."""
    asyncio.run(_verify_app(flyte_ctx["env_suffix"]))


async def _verify_app(env_suffix: str) -> None:
    from app import app_deploy_test

    print("[ci] verify_app: submitting app_deploy_test", flush=True)
    run = await flyte_ops.submit_with_retry(app_deploy_test, "verify_app")
    print(f"[ci] verify_app: run={run.name}  url={run.url}", flush=True)
    # Heaviest scenario (two image builds + Knative cold-start); default 600s is
    # ample for a healthy ~1 min run while still catching a genuine hang.
    try:
        await flyte_ops.assert_succeeded(run, "verify_app")
    except Exception:
        # Dump the app's CP spec + status (assigned_cluster, failure message) so
        # the log shows where the CP routed it and why it failed.
        await flyte_ops.dump_app_state(f"ci-app-{env_suffix}")
        raise
    print(
        f"[ci] verify_app: PASSED (run={run.name}) — app assigned to cluster {env_suffix!r}",
        flush=True,
    )
