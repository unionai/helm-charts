"""Basic task check: submit the simple task and assert it succeeds."""

from __future__ import annotations

import asyncio
import uuid

import flyte_ops


def test_simple(flyte_ctx):
    """Submit the simple task and wait for a successful terminal state."""

    async def _run() -> None:
        from simple import simple

        nonce = str(uuid.uuid4())
        print(f"[ci] verify_simple: submitting (nonce={nonce})", flush=True)
        run = await flyte_ops.submit_with_retry(simple, "verify_simple", nonce=nonce)
        print(f"[ci] verify_simple: run={run.name}  url={run.url}", flush=True)
        await flyte_ops.assert_succeeded(run, "verify_simple")
        print(f"[ci] verify_simple: PASSED (run={run.name})", flush=True)

    asyncio.run(_run())
