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

# See ci_smoke_task._CACHE_BUST: jitter the built-image tag per run so
# build_image_task gets a fresh cache key on the ephemeral k3d store (ENG26-979).
# Empty on persistent-store legs, which keep normal cross-run image caching.
_CACHE_BUST = os.environ.get("SMOKE_IMAGE_CACHE_BUST", "")

# Route verify_app's poll at the app's PER-CLUSTER internal ksvc URL instead of
# the shared tenant-wide *.apps public URL. The public URL rides a single
# Cloudflare record (*.apps.<tenant>) that every dataplane's operator overwrites
# to its own tunnel on each reconcile — last-writer-wins, so concurrent DPs on a
# shared tenant fight over it. The internal ksvc host is per-project/per-cluster
# (<project>-<domain>-<app>.union.svc.cluster.local, project == CLUSTER_NAME) and
# contention-free. INTERNAL_APP_ENDPOINT_PATTERN makes _app_env.endpoint resolve
# to it; {app_fqdn} is filled by the SDK with the app name. Per-DP PUBLIC ingress
# is the durable fix (ENG26-982); this makes CI independent of the shared wildcard.
_INTERNAL_APP_ENDPOINT = f"http://{_cluster}-development-{{app_fqdn}}.union.svc.cluster.local"


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
    image=flyte.Image.from_debian_base()
    .with_pip_packages("fastapi", "uvicorn", "httpx", "flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    # Kept small so the app revision + tester pod fit on the 4-vCPU CI runner
    # alongside the dataplane and (trimmed) Knative serving stack.
    resources=flyte.Resources(cpu="250m", memory="256Mi"),
    # Pin the app to this run's cluster pool explicitly. Routing pool-less apps
    # via project→pool rules (the path Runs use) isn't reliably deployed on the
    # shared staging CP — verified 2026-06-10: an app sent with NO cluster_pool
    # field (proto3 field absent on the wire) failed deployment after the CP fix
    # was overridden. Re-test the rule-based path by removing this pin once the
    # CP fix is durably rolled out.
    cluster_pool=_cluster,
    # See _app_task_env: CLUSTER_NAME is a runner-only var, so the in-pod module
    # would otherwise resolve names against the "ci-dev" default and mismatch
    # the registered ci-app-<run-id>. Inject the resolved value.
    env_vars={"CLUSTER_NAME": _cluster},
    requires_auth=False,
)

_app_task_env = flyte.TaskEnvironment(
    name=f"ci-app-tester-{_cluster}",
    image=flyte.Image.from_debian_base()
    .with_pip_packages("fastapi", "uvicorn", "httpx", "flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    resources=flyte.Resources(cpu="250m", memory="256Mi"),
    depends_on=[_app_env],
    cache="disable",
    # The tester pod calls flyte.serve(_app_env), which re-resolves _app_env at
    # runtime from the pod's own env — so both inputs to that resolution must be
    # injected here, not just set on the CI runner:
    #   * CLUSTER_NAME       — _app_env.name; without it the pod computes the
    #                          "ci-app-ci-dev" default and serve() hangs on an
    #                          unregistered name.
    #   * SMOKE_IMAGE_CACHE_BUST — _app_env.image tag jitter. serve() BUILDS the
    #                          app image inside this pod, so an empty value here
    #                          yields the stable tag every run → the build_image
    #                          task hits a purged-output cache entry and fails
    #                          the leaseworker read (ENG26-979). Propagate the
    #                          run-unique value so the in-pod build gets a fresh
    #                          build cache key, matching the driver-built images.
    #   * INTERNAL_APP_ENDPOINT_PATTERN — _app_env.endpoint. Without it the poll
    #                          targets the shared *.apps public URL (ENG26-982);
    #                          with it, the per-cluster internal ksvc URL.
    env_vars={
        "CLUSTER_NAME": _cluster,
        "SMOKE_IMAGE_CACHE_BUST": _CACHE_BUST,
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
    import httpx  # type: ignore
    import logging as _log
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
