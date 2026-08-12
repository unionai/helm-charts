"""
FastAPI app functional-test task for the dataplane integration CI.

Its own module (like each scenario task) so the basic-task pods (simple, imgbuild,
etc.) never import fastapi — only the app-tester pod, which has fastapi in its
image, loads this module.
"""

from __future__ import annotations

import os
import typing

import flyte  # type: ignore
import flyte.app.extras  # type: ignore
import flyte.remote  # type: ignore  # App.get — verify assigned_cluster routing

_cluster = os.environ.get("CLUSTER_NAME", "ci-dev")
# Naming suffix for the TaskEnvironments (grouping/visual); defaults to the cluster.
_env_suffix = os.environ.get("ENV_SUFFIX") or _cluster

# Bust the image-build cache when the underlying object store is ephemeral or its
# cache objects are GC'd, so a stale hit can't point at a collected output
# (ENG26-979). Empty elsewhere — persistent stores keep normal cross-run caching.
_CACHE_BUST = os.environ.get("FUNCTIONAL_IMAGE_CACHE_BUST", "")

# App-serving ingress isn't guaranteed, and the public *.apps URL isn't
# multi-dataplane-safe (shared wildcard, last-writer-wins), so poll the app's
# intra-cluster k8s Service FQDN instead: <project>-<domain>-<app>.<ns>.svc.cluster.local
# (project == CLUSTER_NAME); INTERNAL_APP_ENDPOINT_PATTERN makes it _app_env.endpoint.
# _app_ns = the release namespace the operator pins app pods to under low_privilege
# ("dataplane" on standing legs, "union" on k3d); APP_NAMESPACE overrides per leg.
_app_ns = os.environ.get("APP_NAMESPACE", "dataplane")
_INTERNAL_APP_ENDPOINT = f"http://{_cluster}-development-{{app_fqdn}}.{_app_ns}.svc.cluster.local"


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
    name=f"ci-app-{_env_suffix}",
    app=_make_fastapi_app(),
    image=flyte.Image.from_debian_base()
    .with_pip_packages("fastapi", "uvicorn", "httpx", "flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    resources=flyte.Resources(cpu="250m", memory="256Mi"),
    cluster_pool=_cluster,  # resolved when the tester calls serve() (tester pod has CLUSTER_NAME)
    env_vars={"ENV_SUFFIX": _env_suffix},
    requires_auth=False,
)

_app_task_env = flyte.TaskEnvironment(
    name=f"ci-app-tester-{_env_suffix}",
    image=flyte.Image.from_debian_base()
    .with_pip_packages("fastapi", "uvicorn", "httpx", "flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    resources=flyte.Resources(cpu="250m", memory="256Mi"),
    depends_on=[_app_env],
    cache="disable",
    env_vars={
        "CLUSTER_NAME": _cluster,
        "ENV_SUFFIX": _env_suffix,
        "FUNCTIONAL_IMAGE_CACHE_BUST": _CACHE_BUST,
        "INTERNAL_APP_ENDPOINT_PATTERN": _INTERNAL_APP_ENDPOINT,
    },
)


class AppDeployResult(typing.NamedTuple):
    internal_url: str
    public_url: str
    assigned_cluster: str


# Upper bound on the teardown deactivate. deactivate(wait=True) blocks until the
# app reaches the deactivated state; on a cold-starting/churning app under CPU
# pressure that wait can outlast the run budget. Bounding it keeps a genuine
# assertion failure from being masked as a generic run timeout (a hung deactivate
# in a finally swallows the real error and burns the whole deadline at RUNNING).
_TEARDOWN_TIMEOUT = 60  # seconds


async def _teardown_app(deployed, log) -> None:  # type: ignore[no-untyped-def]
    """Best-effort, bounded deactivate. Never raises, never hangs.

    Run as a separate teardown step (not in an assertion `finally`) so the app
    stays up for the checks and a failed check surfaces its real reason instead
    of a masked deactivate hang.
    """
    import asyncio

    try:
        await asyncio.wait_for(deployed.deactivate.aio(wait=True), timeout=_TEARDOWN_TIMEOUT)
    except asyncio.TimeoutError:
        log.warning(
            f"app teardown: deactivate did not confirm stopped within "
            f"{_TEARDOWN_TIMEOUT}s; leaving best-effort (stop already requested)"
        )
    except Exception as exc:  # noqa: BLE001 — teardown must not mask the real result
        log.warning(f"app teardown: deactivate failed (best-effort): {exc}")


@_app_task_env.task
async def app_deploy_test() -> AppDeployResult:
    import asyncio
    import logging as _log

    import httpx  # type: ignore

    log = _log.getLogger("ci.app")
    await flyte.init_in_cluster.aio()
    # serve()/deactivate() are @syncify wrappers — call the .aio variants from
    # this async task. Calling the sync wrapper inside the running event loop is
    # incorrect and can hang/deadlock instead of deploying the app.
    deployed = await flyte.serve.aio(_app_env)
    internal_url = _app_env.endpoint
    public_url = deployed.endpoint
    log.info(f"app: internal={internal_url} public={public_url}")

    # Keep the app UP through every assertion; deactivate only afterwards as a
    # separate bounded teardown step (see _teardown_app). On failure we still run
    # a best-effort teardown, then re-raise the ORIGINAL error untouched.
    try:
        # Verify the CP bound the app to THIS run's cluster (the explicit
        # cluster_pool pin resolved to the run's dataplane). status.assigned_cluster
        # is the cluster the control plane dispatched the app to; it must equal the
        # run's cluster (CLUSTER_NAME == _cluster, the only dataplane in this CI).
        # Re-fetch the app if the watch object's status hasn't populated it yet.
        assigned_cluster = deployed.pb2.status.assigned_cluster
        if not assigned_cluster:
            refreshed = await flyte.remote.App.get.aio(name=_app_env.name)
            assigned_cluster = refreshed.pb2.status.assigned_cluster
        log.info(f"app: assigned_cluster={assigned_cluster!r} expected={_cluster!r}")
        if assigned_cluster != _cluster:
            raise RuntimeError(
                f"app routed to wrong cluster: assigned_cluster={assigned_cluster!r} "
                f"but expected {_cluster!r}"
            )

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
    except Exception:
        await _teardown_app(deployed, log)
        raise

    await _teardown_app(deployed, log)
    return AppDeployResult(
        internal_url=internal_url,
        public_url=public_url,
        assigned_cluster=assigned_cluster,
    )
