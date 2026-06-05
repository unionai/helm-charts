"""
Smoke test task for the dataplane integration CI.

Defined here (repo root) so the module name is 'ci_smoke_task' — importable
without leading dots or hyphens. The .github/ci-scripts/ path is not a valid
Python module name, which caused the container to fail when loading the task.
"""
import os

import flyte  # type: ignore

# Use CLUSTER_NAME (unique per run, e.g. ci-27023305710) so the environment
# name is unique per CI run.  A fixed name like "ci-smoke-hello" gets stored
# on the control plane after the first run and retains that run's cluster pool;
# subsequent runs then try to route to the dead pool → "no clusters found".
_cluster = os.environ.get("CLUSTER_NAME", "ci-dev")
_smoke_env = flyte.TaskEnvironment(name=f"ci-smoke-{_cluster}", cache="disable")  # type: ignore


@_smoke_env.task
async def hello(nonce: str) -> str:
    import logging as _logging
    _logging.getLogger("ci.hello").info(f"hello nonce={nonce}")
    return f"hello-{nonce}"
