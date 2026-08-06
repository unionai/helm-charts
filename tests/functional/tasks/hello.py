"""Hello — the basic gating task; its run feeds verify_io / verify_logs."""

from __future__ import annotations

import os

import flyte  # type: ignore

# Env name includes CLUSTER_NAME so each CI run registers its own TaskEnvironment
# on the control plane (avoids routing new runs to a prior run's dead pool).
_env_suffix = os.environ.get("ENV_SUFFIX") or os.environ.get("CLUSTER_NAME", "ci-dev")

_hello_env = flyte.TaskEnvironment(name=f"ci-hello-{_env_suffix}", cache="disable")


# retries=2: a transient pod/registry blip (ImagePullBackOff, throttled base-image
# pull, CRI hiccup) is re-tried in-cluster by propeller on a fresh pod.
@_hello_env.task(retries=2)
async def hello(nonce: str) -> str:
    import logging as _log

    _log.getLogger("ci.hello").info(f"hello nonce={nonce}")
    return f"hello-{nonce}"
