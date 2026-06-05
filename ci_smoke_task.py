"""
Smoke test task for the dataplane integration CI.

Defined here (repo root) so the module name is 'ci_smoke_task' — importable
without leading dots or hyphens. The .github/ci-scripts/ path is not a valid
Python module name, which caused the container to fail when loading the task.
"""
import flyte  # type: ignore

_smoke_env = flyte.TaskEnvironment(name="ci-smoke-hello", cache="disable")  # type: ignore


@_smoke_env.task
async def hello(nonce: str) -> str:
    import logging as _logging
    _logging.getLogger("ci.hello").info(f"hello nonce={nonce}")
    return f"hello-{nonce}"
