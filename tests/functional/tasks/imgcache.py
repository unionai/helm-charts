"""Image-cache check — submit the same stable-image task twice; expect a cache hit."""

from __future__ import annotations

import os

import flyte  # type: ignore

_env_suffix = os.environ.get("ENV_SUFFIX") or os.environ.get("CLUSTER_NAME", "ci-dev")
_CACHE_BUST = os.environ.get("FUNCTIONAL_IMAGE_CACHE_BUST", "")

_imgcache_env = flyte.TaskEnvironment(
    name=f"ci-imgcache-{_env_suffix}",
    image=(
        flyte.Image.from_debian_base()
        .with_pip_packages("requests==2.32.3", "flyteplugins-union")
        .with_env_vars({"CI_CACHE_TEST": "v1", "CI_CACHE_BUST": _CACHE_BUST})
    ),
    cache="disable",
)


@_imgcache_env.task(retries=2)  # tolerate transient base-image pull / build blips
async def imgcache_task(nonce: str) -> str:
    import logging as _log

    import requests  # type: ignore

    _log.getLogger("ci.imgcache").info(f"imgcache nonce={nonce}")
    return f"requests={requests.__version__}"
