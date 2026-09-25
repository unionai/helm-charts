"""Union Volumes through the mount broker: write in one task, read in another.

Only meaningful when the dataplane installs with ``uvolMountBroker.enabled``
(values.k3d.yaml / the workflow's --set); the tasks assert *broker mode* — the
mount path is a symlink into the pod's premounted channel volume — so a mount
that fell back to the privileged in-pod path fails the scenario rather than
passing by accident.
"""

from __future__ import annotations

import asyncio
import uuid

import flyte_ops
import pytest


@pytest.mark.volume
def test_volume(flyte_ctx):
    """volume_roundtrip: RWVolume.new → write → finalize → ROVolume.mount → verify."""

    async def _run() -> None:
        from flyte.remote import Run
        from volume import volume_roundtrip

        nonce = str(uuid.uuid4())
        run = await flyte_ops.submit_with_retry(volume_roundtrip, "verify_volume", nonce=nonce)
        print(f"[ci] verify_volume: run={run.name}  url={run.url}", flush=True)
        await flyte_ops.assert_succeeded(run, "verify_volume")
        got = await Run.get.aio(name=run.name)  # type: ignore
        report = (await got.outputs.aio()).o0  # type: ignore
        assert report, f"no outputs for {run.name}"
        print(f"[ci] verify_volume: {report}", flush=True)
        # The task already asserted each of these; re-check the outputs so a task
        # that was silently rewritten to skip a phase still cannot pass.
        assert report["write"]["broker_mode"] is True, report
        assert report["read"]["broker_mode"] is True, report
        assert report["read"]["files_ok"] == report["write"]["files"], report
        assert report["read"]["large_ok"] is True, report

    asyncio.run(_run())
