"""Reusable-environment (actor) check."""

from __future__ import annotations

import asyncio

import flyte_ops


def test_reusable(flyte_ctx):
    """Fan out square() calls over a ReusePolicy environment (replicas=1, concurrency=1)."""

    async def _run() -> None:
        from reusable import reuse_driver

        n = 4  # fixed for reproducibility
        print(f"[ci] verify_reusable: submitting reuse_driver(n={n})", flush=True)
        run = await flyte_ops.submit_with_retry(reuse_driver, "verify_reusable", n=n)
        await flyte_ops.assert_succeeded(run, "verify_reusable")
        print(f"[ci] verify_reusable: PASSED (run={run.name})", flush=True)

    asyncio.run(_run())
