"""Image-builder check — build a custom image (requests) and run a task on it."""

from __future__ import annotations

import os

import flyte  # type: ignore

_env_suffix = os.environ.get("ENV_SUFFIX") or os.environ.get("CLUSTER_NAME", "ci-dev")
# Bust the image-build cache when the underlying object store is ephemeral or its
# cache objects are GC'd, so a stale hit can't point at a collected output
# (ENG26-979). Empty elsewhere — persistent stores keep normal cross-run caching.
_CACHE_BUST = os.environ.get("FUNCTIONAL_IMAGE_CACHE_BUST", "")

_imgbuild_env = flyte.TaskEnvironment(
    name=f"ci-imgbuild-{_env_suffix}",
    image=flyte.Image.from_debian_base()
    .with_pip_packages("requests==2.32.3", "flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    cache="disable",
)


@_imgbuild_env.task(retries=2)  # tolerate transient base-image pull / build blips
async def imgbuild_task(nonce: str) -> str:
    import logging as _log

    import requests  # type: ignore

    _log.getLogger("ci.imgbuild").info(f"imgbuild nonce={nonce}")
    return f"requests={requests.__version__}"
