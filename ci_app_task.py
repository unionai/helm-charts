"""
FastAPI app smoke-test task for the dataplane integration CI.

Kept in a separate file from ci_smoke_task.py so that pods running basic tasks
(hello, imgbuild, etc.) never import fastapi.  Only the app-tester pod, which
has fastapi in its image, will load this module.
"""
from __future__ import annotations

import os
import typing

import flyte  # type: ignore
import flyte.app.extras  # type: ignore

_cluster = os.environ.get("CLUSTER_NAME", "ci-dev")


def _make_fastapi_app():
    import fastapi  # type: ignore
    app = fastapi.FastAPI()

    @app.get("/")
    async def root() -> str:
        return "ci-app-ok"

    @app.get("/health")
    async def health() -> dict:
        return {"status": "healthy"}

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
