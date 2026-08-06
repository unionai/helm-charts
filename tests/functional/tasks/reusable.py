"""Reusable-environment (actor) check — fan out square() over a ReusePolicy env."""

from __future__ import annotations

import asyncio
import os
from datetime import timedelta

import flyte  # type: ignore

_env_suffix = os.environ.get("ENV_SUFFIX") or os.environ.get("CLUSTER_NAME", "ci-dev")
_CACHE_BUST = os.environ.get("FUNCTIONAL_IMAGE_CACHE_BUST", "")

_reuse_env = flyte.TaskEnvironment(
    name=f"ci-reuse-{_env_suffix}",
    image=flyte.Image.from_debian_base()
    .with_pip_packages("unionai-reuse>=0.1.10", "flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    # cpu/replicas kept small: the 4-vCPU CI runner is already near-full with the
    # dataplane + Knative serving stack, so a 2×500m reusable env can't schedule
    # (WAITING_FOR_RESOURCES). One replica fits, but reuse_driver itself runs on
    # this env, so with concurrency=1 the driver holds the only slot and the
    # reuse_square() calls it awaits can never get one → starvation/deadlock
    # (the run hangs in RUNNING forever). concurrency=2 gives the single pod a
    # second slot for the children, exercising the ReusePolicy path on one pod.
    resources=flyte.Resources(memory="256Mi", cpu="250m"),
    cache="disable",
    # The reusable actor re-resolves its env name (ci-reuse-<ENV_SUFFIX>) at pod
    # runtime from its own env. ENV_SUFFIX is a runner-only var, so inject the
    # resolved value — else the pod defaults to "ci-dev", looks up an unregistered
    # "ci-reuse-ci-dev", and fails "Environment not found in image cache".
    env_vars={"ENV_SUFFIX": _env_suffix},
    reusable=flyte.ReusePolicy(
        replicas=1,
        concurrency=2,
        scaledown_ttl=timedelta(minutes=2),
        idle_ttl=timedelta(minutes=5),
    ),
)


@_reuse_env.task(retries=2)  # tolerate transient pull/scheduling blips on the actor
async def reuse_square(x: int) -> int:
    return x * x


@_reuse_env.task(retries=2)  # tolerate transient pull/scheduling blips on the actor
async def reuse_driver(n: int) -> list[int]:
    """Fan out square() calls over the reusable environment (replicas=1, concurrency=2)."""
    return list(await asyncio.gather(*(reuse_square(i) for i in range(n))))
