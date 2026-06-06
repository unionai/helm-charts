"""
Smoke test tasks for the dataplane integration CI.

Defined here (repo root) so module names are importable without dots or hyphens.
The .github/ci-scripts/ path produces an invalid Python module name (hyphens),
which causes the container to fail when loading tasks.

Environment name includes CLUSTER_NAME so each CI run registers its own
TaskEnvironment on the control plane — avoids routing new runs to a
dead cluster pool from a prior run.

App / FastAPI tasks live in ci_app_task.py (separate file) to prevent the
hello/imgbuild/imgcache/reuse task pods — which run without fastapi — from
hitting an ImportError when this module is loaded.
"""
from __future__ import annotations

import asyncio
import os
from datetime import timedelta

import flyte  # type: ignore

_cluster = os.environ.get("CLUSTER_NAME", "ci-dev")


# ── Hello (basic smoke) ──────────────────────────────────────────────────────

_smoke_env = flyte.TaskEnvironment(name=f"ci-smoke-{_cluster}", cache="disable")


@_smoke_env.task
async def hello(nonce: str) -> str:
    import logging as _log
    _log.getLogger("ci.hello").info(f"hello nonce={nonce}")
    return f"hello-{nonce}"


# ── Image builder ────────────────────────────────────────────────────────────

_imgbuild_env = flyte.TaskEnvironment(
    name=f"ci-imgbuild-{_cluster}",
    image=flyte.Image.from_debian_base().with_pip_packages(
        "requests==2.32.3", "flyteplugins-union"
    ),
    cache="disable",
)


@_imgbuild_env.task
async def imgbuild_task(nonce: str) -> str:
    import logging as _log
    import requests  # type: ignore
    _log.getLogger("ci.imgbuild").info(f"imgbuild nonce={nonce}")
    return f"requests={requests.__version__}"


# ── Image cache ──────────────────────────────────────────────────────────────

_imgcache_env = flyte.TaskEnvironment(
    name=f"ci-imgcache-{_cluster}",
    image=(
        flyte.Image.from_debian_base()
        .with_pip_packages("requests==2.32.3", "flyteplugins-union")
        .with_env_vars({"CI_CACHE_TEST": "v1"})
    ),
    cache="disable",
)


@_imgcache_env.task
async def imgcache_task(nonce: str) -> str:
    import logging as _log
    import requests  # type: ignore
    _log.getLogger("ci.imgcache").info(f"imgcache nonce={nonce}")
    return f"requests={requests.__version__}"


# ── Reusable containers ──────────────────────────────────────────────────────

_reuse_env = flyte.TaskEnvironment(
    name=f"ci-reuse-{_cluster}",
    image=flyte.Image.from_debian_base().with_pip_packages(
        "unionai-reuse>=0.1.10", "flyteplugins-union"
    ),
    # cpu/replicas kept small: the 4-vCPU CI runner is already near-full with the
    # dataplane + Knative serving stack, so a 2×500m reusable env can't schedule
    # (WAITING_FOR_RESOURCES). One replica fits, but reuse_driver itself runs on
    # this env, so with concurrency=1 the driver holds the only slot and the
    # reuse_square() calls it awaits can never get one → starvation/deadlock
    # (the run hangs in RUNNING forever). concurrency=2 gives the single pod a
    # second slot for the children, exercising the ReusePolicy path on one pod.
    resources=flyte.Resources(memory="256Mi", cpu="250m"),
    cache="disable",
    # The reusable actor re-resolves its environment name from CLUSTER_NAME at
    # pod runtime. CLUSTER_NAME is a runner-only env var, so without this it
    # defaults to "ci-dev" inside the pod and the actor looks up
    # "ci-reuse-ci-dev" — which was never registered (it was registered as
    # ci-reuse-<run-id> from the runner) → "Environment not found in image
    # cache". Inject the resolved value so the in-pod name matches.
    env_vars={"CLUSTER_NAME": _cluster},
    reusable=flyte.ReusePolicy(
        replicas=1,
        concurrency=2,
        scaledown_ttl=timedelta(minutes=2),
        idle_ttl=timedelta(minutes=5),
    ),
)


@_reuse_env.task
async def reuse_square(x: int) -> int:
    return x * x


@_reuse_env.task
async def reuse_driver(n: int) -> list[int]:
    """Fan out square() calls over the reusable environment (replicas=1, concurrency=2)."""
    return list(await asyncio.gather(*(reuse_square(i) for i in range(n))))
