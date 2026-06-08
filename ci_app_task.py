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
import flyte.remote  # type: ignore  # App.get — verify assigned_cluster routing

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
    # Kept small so the app revision + tester pod fit on the 4-vCPU CI runner
    # alongside the dataplane and (trimmed) Knative serving stack.
    resources=flyte.Resources(cpu="250m", memory="256Mi"),
    # cluster_pool is handled below (forced unset) — see the note after this
    # constructor. It can't be expressed here: the field defaults to the literal
    # "default" and passing cluster_pool=None to __init__ is ignored (the guard
    # keeps the default), so we null it on the instance post-construction.
    # See _app_task_env: CLUSTER_NAME is a runner-only var, so the in-pod module
    # would otherwise resolve names against the "ci-dev" default and mismatch
    # the registered ci-app-<run-id>. Inject the resolved value.
    env_vars={"CLUSTER_NAME": _cluster},
    requires_auth=False,
)

# Send NO cluster_pool so the control plane resolves the app's cluster from the
# project→pool routing rules (the same path Runs use), landing it on this run's
# pool via CI's setup-routing (project == _cluster → pool == _cluster, holding
# this run's k3d dataplane). The SDK can't express "unset": the field defaults
# to the literal "default" and app_serde serializes it unconditionally, so both
# omitting it and setting "" make the CP see "default" and pin the app to the
# (empty) default pool — bypassing routing and hanging serve(). Nulling the
# field makes app_serde emit Spec(cluster_pool=None), which proto3 drops from
# the wire entirely, so the create request carries no pool at all.
_app_env.cluster_pool = None

_app_task_env = flyte.TaskEnvironment(
    name=f"ci-app-tester-{_cluster}",
    image=flyte.Image.from_debian_base().with_pip_packages(
        "fastapi", "uvicorn", "httpx", "flyteplugins-union"
    ),
    resources=flyte.Resources(cpu="250m", memory="256Mi"),
    depends_on=[_app_env],
    cache="disable",
    # The tester pod calls flyte.serve(_app_env), which re-resolves _app_env.name
    # from CLUSTER_NAME at runtime. Without this it computes "ci-app-ci-dev"
    # (the default) and serve() hangs deploying/looking up an unregistered name.
    env_vars={"CLUSTER_NAME": _cluster},
)


class AppDeployResult(typing.NamedTuple):
    internal_url: str
    public_url: str
    assigned_cluster: str


@_app_task_env.task
async def app_deploy_test() -> AppDeployResult:
    import asyncio
    import httpx  # type: ignore
    import logging as _log
    log = _log.getLogger("ci.app")
    await flyte.init_in_cluster.aio()
    # serve()/deactivate() are @syncify wrappers — call the .aio variants from
    # this async task. Calling the sync wrapper inside the running event loop is
    # incorrect and can hang/deadlock instead of deploying the app.
    # No cluster_pool is pinned on _app_env: the control plane resolves the app's
    # cluster from the project→pool routing rules (see _app_env comment), so a
    # plain serve() routes to this run's dataplane.
    deployed = await flyte.serve.aio(_app_env)
    internal_url = _app_env.endpoint
    public_url = deployed.endpoint
    log.info(f"app: internal={internal_url} public={public_url}")

    # Verify the CP routed the app to THIS run's cluster via the project→pool
    # routing rules (no explicit cluster_pool pin). status.assigned_cluster is
    # the cluster the control plane bound the app to; it must equal the run's
    # cluster (CLUSTER_NAME == _cluster, the only dataplane in this CI). Re-fetch
    # the app if the watch object's status hasn't populated it yet.
    assigned_cluster = deployed.pb2.status.assigned_cluster
    if not assigned_cluster:
        refreshed = await flyte.remote.App.get.aio(name=_app_env.name)
        assigned_cluster = refreshed.pb2.status.assigned_cluster
    log.info(f"app: assigned_cluster={assigned_cluster!r} expected={_cluster!r}")
    if assigned_cluster != _cluster:
        raise RuntimeError(
            f"app routed to wrong cluster: assigned_cluster={assigned_cluster!r} "
            f"but expected {_cluster!r} (project→pool routing did not resolve to "
            f"this run's dataplane)"
        )

    try:
        # Knative may still be pulling the image / cold-starting the revision
        # when serve() returns, so poll "/" until it answers 200 instead of
        # firing a single un-timed request that hangs forever on a not-yet-ready
        # endpoint. Bounded so a genuinely broken deploy fails fast with detail.
        deadline = 300  # seconds
        interval = 5
        async with httpx.AsyncClient(timeout=10.0) as client:
            last_err = "no attempt made"
            for _ in range(deadline // interval):
                try:
                    resp = await client.get(f"{internal_url}/")
                    if resp.status_code == 200 and "ci-app-ok" in resp.text:
                        break
                    last_err = f"/ returned {resp.status_code}: {resp.text[:80]}"
                except Exception as exc:  # noqa: BLE001 — connection refused / cold start
                    last_err = f"{type(exc).__name__}: {exc}"
                await asyncio.sleep(interval)
            else:
                raise RuntimeError(f"app / endpoint not ready within {deadline}s: {last_err}")
            log.info("app: / is ready, checking /health")
            resp = await client.get(f"{internal_url}/health")
            assert resp.status_code == 200, f"/health returned {resp.status_code}"
            assert resp.json().get("status") == "healthy"
    finally:
        await deployed.deactivate.aio(wait=True)
    return AppDeployResult(
        internal_url=internal_url,
        public_url=public_url,
        assigned_cluster=assigned_cluster,
    )
