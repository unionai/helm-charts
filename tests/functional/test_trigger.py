"""Scheduled-trigger deploy + toggle check (no execution needed)."""

from __future__ import annotations

import asyncio


def test_trigger(flyte_ctx):
    """Deploy a scheduled trigger, verify its automation spec, and toggle active.

    No execution needed — the registered schedule is the signal (cheap,
    topology-agnostic).
    """
    asyncio.run(_verify_trigger(flyte_ctx["env_suffix"]))


async def _verify_trigger(env_suffix: str) -> None:
    import flyte
    import flyte.remote
    from flyteidl2.task.common_pb2 import TriggerAutomationSpecType
    from trigger import _trigger_env

    print("[ci] verify_trigger: deploying trigger env", flush=True)
    await flyte.deploy.aio(_trigger_env)  # type: ignore

    trigger_name = flyte.Trigger.daily().name  # "daily"
    task_name = f"ci-trigger-{env_suffix}.triggered_task"

    td = await flyte.remote.Trigger.get.aio(name=trigger_name, task_name=task_name)  # type: ignore
    assert td.automation_spec.type == TriggerAutomationSpecType.TYPE_SCHEDULE, (
        f"expected TYPE_SCHEDULE, got {td.automation_spec.type}"
    )
    assert td.is_active, "trigger is not active after deploy"

    # Toggle inactive → re-read → confirm the update round-trips.
    await flyte.remote.Trigger.update.aio(  # type: ignore
        name=trigger_name, task_name=task_name, active=False
    )
    td = await flyte.remote.Trigger.get.aio(name=trigger_name, task_name=task_name)  # type: ignore
    assert not td.is_active, "trigger still active after deactivate"
    print(
        f"[ci] verify_trigger: PASSED (trigger {trigger_name!r} deployed, "
        f"schedule verified, deactivated)",
        flush=True,
    )
