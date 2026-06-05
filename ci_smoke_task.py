"""
Smoke test tasks for the dataplane integration CI.

Defined here (repo root) so module names are importable without dots or hyphens.
The .github/ci-scripts/ path produces an invalid Python module name (hyphens),
which causes the container to fail when loading tasks.

Environment name includes CLUSTER_NAME so each CI run registers its own
TaskEnvironment on the control plane — avoids routing new runs to a
dead cluster pool from a prior run.
"""
from __future__ import annotations

import asyncio
import os
import typing
from datetime import timedelta

import flyte  # type: ignore
import flyte.app.extras  # type: ignore

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
        "fastapi", "requests==2.32.3", "flyteplugins-union"
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
        .with_pip_packages("fastapi", "requests==2.32.3", "flyteplugins-union")
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
        "fastapi", "unionai-reuse>=0.1.10", "flyteplugins-union"
    ),
    resources=flyte.Resources(memory="512Mi", cpu="500m"),
    cache="disable",
    reusable=flyte.ReusePolicy(
        replicas=2,
        concurrency=1,
        scaledown_ttl=timedelta(minutes=2),
        idle_ttl=timedelta(minutes=5),
    ),
)


@_reuse_env.task
async def reuse_square(x: int) -> int:
    return x * x


@_reuse_env.task
async def reuse_driver(n: int) -> list[int]:
    """Fan out square() calls over the reusable environment (replicas=2, concurrency=1)."""
    return list(await asyncio.gather(*(reuse_square(i) for i in range(n))))


# ── App deployment ───────────────────────────────────────────────────────────

_fastapi_app_cache = None


def _make_fastapi_app():
    global _fastapi_app_cache
    if _fastapi_app_cache is not None:
        return _fastapi_app_cache
    import fastapi  # type: ignore
    app = fastapi.FastAPI()

    @app.get("/")
    async def root() -> str:
        return "ci-app-ok"

    @app.get("/health")
    async def health() -> dict:
        return {"status": "healthy"}

    _fastapi_app_cache = app
    return app


_app_env = flyte.app.extras.FastAPIAppEnvironment(
    name=f"ci-app-{_cluster}",
    app=_make_fastapi_app(),
    image=flyte.Image.from_debian_base().with_pip_packages(
        "fastapi", "uvicorn", "httpx", "flyteplugins-union"
    ),
    resources=flyte.Resources(cpu=1, memory="512Mi"),
    requires_auth=False,
)

_app_task_env = flyte.TaskEnvironment(
    name=f"ci-app-tester-{_cluster}",
    image=flyte.Image.from_debian_base().with_pip_packages(
        "fastapi", "uvicorn", "httpx", "flyteplugins-union"
    ),
    resources=flyte.Resources(cpu=1, memory="512Mi"),
    depends_on=[_app_env],
    cache="disable",
)


class AppDeployResult(typing.NamedTuple):
    internal_url: str
    public_url: str


@_app_task_env.task
async def app_deploy_test() -> AppDeployResult:
    import httpx  # type: ignore
    import logging as _log
    log = _log.getLogger("ci.app")
    await flyte.init_in_cluster.aio()
    deployed = flyte.serve(_app_env)
    internal_url = _app_env.endpoint
    public_url = deployed.endpoint
    log.info(f"app: internal={internal_url} public={public_url}")
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{internal_url}/")
            assert resp.status_code == 200, f"/ returned {resp.status_code}"
            assert "ci-app-ok" in resp.text, f"unexpected body: {resp.text}"
            resp = await client.get(f"{internal_url}/health")
            assert resp.status_code == 200, f"/health returned {resp.status_code}"
            assert resp.json().get("status") == "healthy"
    finally:
        deployed.deactivate(wait=True)
    return AppDeployResult(internal_url=internal_url, public_url=public_url)
