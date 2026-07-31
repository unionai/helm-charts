#!/usr/bin/env python3
"""
Dataplane CI helper for every integration leg — pure flyte 2.x SDK
(flyte / flyteplugins.union.remote), no uctl. Operator credentials are seeded /
provisioned out-of-band (terraform), so there is no runtime provisioning here.
Runs inside GitHub Actions; every command writes its key output to $GITHUB_OUTPUT
so subsequent steps can consume it.

Commands
--------
wait-healthy    Poll Cluster.get until enabled+healthy. Emit ORG_NAME.
setup-routing   Create cluster pool (object store) + project, assign this run's
                cluster (and its implicit queue) to them → the run's tasks only
                land on this dataplane. The pool's object_store config drives
                dataproxy routing (supersedes the old cluster-pool-attributes).
smoke-test      Submit and wait for the hello workflow on our project.
run-smoke-suite hello + the verify_* scenarios (logs/io/image builder/cache/
                reusable/app) with transient-retry.
teardown        Deregister the cluster + drain queue + delete pool + archive
                project (SDK, best-effort).

Environment
-----------
CLUSTER_NAME            required — the dataplane's cluster name (pool==project==name)
CONTROL_PLANE_URL       required — https://<control-plane-host>
UNION_API_KEY           required — base64("<host>:<clientId>:<clientSecret>:<org>")
ORG_NAME                optional — resolved automatically by wait-healthy
GITHUB_OUTPUT           set by Actions runner; commands write key=value here
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import subprocess
import sys
import time
import typing

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)-7s %(name)s - %(message)s",
)
# Quiet the HTTP client stack: at DEBUG these emit one line per request/response
# header, flooding the CI log (thousands of lines) and echoing auth-bearing
# headers. WARNING keeps real errors without the noise.
for _noisy in ("httpx", "httpcore", "urllib3", "hpack", "h2"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)
logger = logging.getLogger("ci.dataplane")


def _env(key: str, required: bool = True) -> str:
    val = os.environ.get(key, "")
    if required and not val:
        sys.exit(f"[ci] ERROR: required env var {key} is not set")
    return val


def _gha_output(key: str, value: str) -> None:
    """Write a key=value pair to $GITHUB_OUTPUT (no-op outside Actions)."""
    path = os.environ.get("GITHUB_OUTPUT")
    line = f"{key}={value}\n"
    if path:
        with open(path, "a") as f:
            f.write(line)
    print(f"[ci] >> {line.rstrip()}", flush=True)


async def _init_client(
    control_plane_url: str,
    api_key: str,
    project: str,
    org: str = "",
) -> None:
    import flyte
    if not control_plane_url.startswith(("https://", "http://")):
        control_plane_url = "https://" + control_plane_url
    kwargs: dict = {
        "endpoint": control_plane_url,
        "project": project,
        "domain": "development",
        # Delegate image builds to the cluster's buildkit service instead of
        # trying to run docker buildx on the CI runner (no Docker / no push creds).
        "image_builder": "remote",
    }
    if org:
        kwargs["org"] = org
    if api_key:
        kwargs["api_key"] = api_key
    await flyte.init.aio(**kwargs)  # type: ignore[attr-defined]


# ── wait-healthy ─────────────────────────────────────────────────────────────

async def _wait_healthy_async(
    cluster_name: str,
    control_plane_url: str,
    api_key: str,
    timeout: int,
) -> str:
    from flyteplugins.union.remote import Cluster  # type: ignore

    await _init_client(control_plane_url, api_key, project=cluster_name)
    print(
        f"[ci] wait-healthy: polling Cluster.get(name={cluster_name}) "
        f"(timeout={timeout}s)",
        flush=True,
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            cluster = await Cluster.get.aio(name=cluster_name)  # type: ignore
            state  = cluster.state
            health = cluster.health
            org    = cluster.organization or ""
            print(f"[ci]   state={state} health={health} org={org}", flush=True)
            if state == "enabled" and health == "healthy":
                print(f"[ci] wait-healthy: HEALTHY (org={org})", flush=True)
                return org
        except Exception as e:
            print(f"[ci]   Cluster.get error: {e}", flush=True)
        await asyncio.sleep(15)
    raise RuntimeError(
        f"Cluster {cluster_name} did not become enabled+healthy within {timeout}s"
    )


def cmd_wait_healthy(args: argparse.Namespace) -> None:
    cluster_name      = _env("CLUSTER_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key           = _env("UNION_API_KEY", required=False)
    org = asyncio.run(
        _wait_healthy_async(cluster_name, control_plane_url, api_key, args.timeout)
    )
    _gha_output("org_name", org)


# ── setup-routing ─────────────────────────────────────────────────────────────

async def _setup_routing_async(
    cluster_name: str,
    org: str,
    control_plane_url: str,
    api_key: str,
) -> str:
    """Create cluster pool + project, and pin this run's cluster + queue to them.

    The control plane dropped the clusterpoolassignment / cluster-pool-attributes
    APIs with the queue-based routing rework (flyteplugins-union #37). New model:
      * a cluster registered by the operator heartbeat is POOL-LESS until an
        explicit CreateCluster assigns it a pool — a one-shot operation: the
        pool can never be changed afterwards;
      * CreateCluster also auto-creates an org-level queue named after the
        cluster, bound to that pool and pinned to exactly this cluster;
      * runs route via that queue (flyte.with_runcontext(queue=...) in
        _submit_with_retry); apps route via spec.cluster_pool (ci_app_task.py);
      * BOTH run scheduling and the DATAPROXY's cluster/pool selection
        (CreateUploadLocation) route via run.default_queue on the project (set
        below via the Settings SDK) → queue → pool → cluster. Without it the
        project resolves to the org "default" pool and fast-registration uploads
        fail ("could not select a cluster ... pool 'default' unhealthy"). This is
        the queue-based replacement for the old `uctl update
        cluster-pool-attributes` — the same routing configure_queues.py applies
        via `flyte edit settings`. The pool's object_store (set at
        CreateClusterPool) then tells the dataproxy WHICH bucket.
    The pool == cluster == queue == project name, so parallel legs (and, with a
    stable name, serialized runs) never cross-land.
    """
    from flyte.remote import Project, Settings  # type: ignore
    from flyteplugins.union.remote import Cluster, ClusterPool, Queue  # type: ignore

    pool_name  = cluster_name
    project_id = cluster_name

    await _init_client(control_plane_url, api_key, project=project_id, org=org)

    # 1. Create cluster pool. The config kwargs are required by the client API
    # but effectively placeholders: for a pool with a single cluster the control
    # plane overwrites the pool config with whatever the operator reports
    # (object store / secret store) on its next status upsert.
    print(f"[ci] setup-routing: creating cluster pool {pool_name}", flush=True)
    try:
        await ClusterPool.create.aio(  # type: ignore
            pool_name,
            object_store_uri=f"s3://{os.environ.get('RUSTFS_BUCKET', 'union-data')}",
            secret_store_type="KUBERNETES",
        )
        print(f"[ci] setup-routing: pool '{pool_name}' created", flush=True)
    except Exception as e:
        if "already" not in str(e).lower():
            raise RuntimeError(f"create cluster pool {pool_name}: {e}") from e
        print(f"[ci] setup-routing: pool '{pool_name}' already exists", flush=True)

    # 2. Assign the (heartbeat-registered, pool-less) cluster to the pool.
    # CreateCluster upserts the existing cluster row with the pool name and
    # auto-creates the implicit queue '<cluster_name>' pinned to this cluster.
    # Critical: without this the cluster belongs to no pool and every task
    # submission returns "no clusters found". Idempotent: re-running with the
    # same pool is a no-op; a DIFFERENT pool fails ("cannot change cluster
    # pool"), which is fatal and means the cluster name collided with a
    # previous run's cluster.
    print(f"[ci] setup-routing: assigning {cluster_name} → pool {pool_name}", flush=True)
    await Cluster.create.aio(cluster_name, cluster_pool_name=pool_name)  # type: ignore

    # 3. Sanity-check the implicit queue; create it explicitly if the CP didn't
    # (belt and braces — older CP builds may not auto-create it).
    try:
        q = await Queue.get.aio(cluster_name)  # type: ignore
        print(
            f"[ci] setup-routing: queue '{cluster_name}' exists "
            f"(pool={q.cluster_pool!r} clusters={q.clusters})",
            flush=True,
        )
    except Exception:
        print(f"[ci] setup-routing: implicit queue missing — creating '{cluster_name}'", flush=True)
        await Queue.create.aio(  # type: ignore
            cluster_name,
            run_concurrency=0,      # 0 == no limit (matches the implicit queue)
            action_concurrency=0,
            depth=0,
            clusters=[cluster_name],
            cluster_pool=pool_name,
        )

    # 4. Create project (idempotent) and ensure it is ACTIVE — with a stable
    # cluster name a prior run's teardown may have archived it, and an archived
    # project can't schedule runs.
    print(f"[ci] setup-routing: creating project {project_id}", flush=True)
    try:
        await Project.create.aio(  # type: ignore
            id=project_id,
            name=project_id,
            description=f"CI integration test project for {cluster_name}",
        )
        print(f"[ci] setup-routing: project '{project_id}' created", flush=True)
    except Exception as e:
        print(f"[ci] setup-routing: project create (likely exists): {e}", flush=True)
    try:
        await Project.update.aio(id=project_id, state="active")  # type: ignore
    except Exception as e:
        print(f"[ci] setup-routing: project reactivate (likely already active): {e}", flush=True)

    # 5. Route project → this run's queue for all domains via run.default_queue.
    # Drives BOTH run scheduling and the dataproxy's CreateUploadLocation pool/
    # cluster selection. The queue (== cluster_name) was created by CreateCluster
    # above, so it resolves here. SDK-native equivalent of configure_queues.py's
    # `flyte edit settings run.default_queue`.
    for domain in ("development", "staging", "production"):
        s = await Settings.get_settings_for_edit.aio(project=project_id, domain=domain)  # type: ignore
        await s.update_settings.aio(overrides={"run.default_queue": cluster_name})  # type: ignore
        print(f"[ci] setup-routing: routed {project_id}/{domain} → queue {cluster_name}", flush=True)

    print(
        f"[ci] setup-routing: done — project '{project_id}', pool '{pool_name}' "
        f"(object store {os.environ.get('RUSTFS_BUCKET', 'union-data')!r}), "
        f"queue '{cluster_name}' — run.default_queue set for dev/staging/prod",
        flush=True,
    )
    return project_id


def cmd_setup_routing(args: argparse.Namespace) -> None:
    cluster_name      = _env("CLUSTER_NAME")
    org               = _env("ORG_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key           = _env("UNION_API_KEY", required=False)
    project = asyncio.run(
        _setup_routing_async(cluster_name, org, control_plane_url, api_key)
    )
    _gha_output("project_id", project)


# ── smoke-test helpers ───────────────────────────────────────────────────────

def _phase_name(run) -> str:  # type: ignore[no-untyped-def]
    return str(run.phase).rsplit(".", 1)[-1].lower()


_ASSERT_TIMEOUT = 600  # seconds — bound per-test wait so a stuck run fails


async def _assert_succeeded(run, label: str, timeout: float = _ASSERT_TIMEOUT) -> None:  # type: ignore[no-untyped-def]
    import flyte  # type: ignore
    try:
        await asyncio.wait_for(run.wait.aio(wait_for="terminal"), timeout=timeout)  # type: ignore
    except asyncio.TimeoutError:
        # Abort the run on the control plane — wait_for only stopped us waiting;
        # the run keeps executing (and holding cluster resources) otherwise, and
        # the teardown's cluster delete leaves an orphaned run on the CP.
        try:
            await asyncio.wait_for(
                run.abort.aio(reason=f"CI {label}: exceeded {timeout:.0f}s wait"),  # type: ignore
                timeout=30,
            )
            print(f"[ci] {label}: aborted run {run.name} after {timeout:.0f}s timeout", flush=True)
        except Exception as exc:  # noqa: BLE001 — best-effort cleanup
            print(f"[ci] {label}: abort after timeout failed: {exc}", flush=True)
        run.sync()
        raise RuntimeError(
            f"{label}: run {run.name} did not reach a terminal state within "
            f"{timeout:.0f}s (last phase={run.phase}) — aborted"
        )
    run.sync()
    p = _phase_name(run)
    if p != "succeeded":
        # Surface the run's underlying failure reason (ImagePullBackOff, grace
        # period exceeded, app endpoint not ready, …) into the exception message
        # so the scenario-level retry classifier (_is_transient) can tell a
        # transient infra/registry blip from a real product failure.
        # error_info lives on the ActionDetails proto (what the SDK's own run
        # watcher prints) — run.pb2.action.error_info is routinely EMPTY, which
        # used to starve the classifier (observed: verify_app's "endpoint not
        # ready within 300s … 530" got no scenario retry). Falls back to
        # run.pb2.action, then to the bare phase.
        detail = ""
        try:
            details = await run.details.aio()  # type: ignore
            err = details.action_details.error_info
            if err is not None:
                detail = f": {err.kind}: {err.message}"
        except Exception:  # noqa: BLE001 — diagnostics must never mask the phase error
            pass
        if not detail:
            try:
                act = run.pb2.action
                if act.HasField("error_info"):
                    detail = f": {act.error_info.kind}: {act.error_info.message}"
            except Exception:  # noqa: BLE001
                pass
        raise RuntimeError(f"{label}: run {run.name} ended in phase={run.phase}{detail}")


def _ensure_workspace_in_path() -> None:
    """Add GITHUB_WORKSPACE (repo root) to sys.path so ci_smoke_task is importable."""
    workspace = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
    if workspace not in sys.path:
        sys.path.insert(0, workspace)


_SUBMIT_MAX_ATTEMPTS = 40
_SUBMIT_RETRY_DELAY  = 30


async def _submit_with_retry(task_fn, label: str, **kwargs):  # type: ignore[no-untyped-def]
    """Submit a task, retrying on 'no clusters found' (pool / capabilities propagation lag).

    Every run is pinned to this PR's queue (named == CLUSTER_NAME, created by
    setup-routing's CreateCluster) so it can only land on this run's dataplane —
    project/domain → pool routing rules no longer exist on the control plane.

    Control-plane routing cache can take O(minutes) to reflect newly-published
    K8s Plugin Config — observed to occasionally exceed 12 min on the shared
    staging control plane (capability→routing propagation is intermittently
    slow). 40 attempts × 30 s = 20 min max retry window. Stays within the 75-min
    job budget even with the sequential heavy tests after it.
    """
    import flyte  # type: ignore
    queue = os.environ.get("CLUSTER_NAME", "") or None
    run = None
    last_err = ""
    for attempt in range(1, _SUBMIT_MAX_ATTEMPTS + 1):
        try:
            run = await flyte.with_runcontext(queue=queue).run.aio(task_fn, **kwargs)  # type: ignore
            break
        except Exception as exc:
            last_err = str(exc)
            msg = last_err.lower()
            # 'cluster "<name>" not found' is related but distinct from
            # "no clusters found": the former means our cluster is missing from
            # the workflow service's enabled-clusters cache (not ENABLED yet, or
            # cache lag); the latter means that cache returned nothing at all.
            # Both are propagation-lag classes worth the retry window — print
            # the REAL message so the two are distinguishable in CI logs.
            if (
                "no clusters found" in msg
                or "no cluster" in msg
                or ("cluster" in msg and "not found" in msg)
            ):
                if attempt < _SUBMIT_MAX_ATTEMPTS:
                    print(
                        f"[ci] {label}: attempt {attempt}/{_SUBMIT_MAX_ATTEMPTS} — "
                        f"{last_err[:160]} — retrying in {_SUBMIT_RETRY_DELAY}s …",
                        flush=True,
                    )
                    # Every 5th attempt, dump the cluster's CP-side state so a
                    # long retry stretch shows WHY (e.g. state flapped out of
                    # ENABLED, which evicts it from the workflow service's
                    # cluster cache and yields 'cluster "<name>" not found').
                    if attempt % 5 == 0 and queue:
                        await _dump_cluster_state(queue)
                    await asyncio.sleep(_SUBMIT_RETRY_DELAY)
            else:
                raise
    if run is None:
        raise RuntimeError(
            f"{label}: submission failed after {_SUBMIT_MAX_ATTEMPTS} attempts "
            f"(last error: {last_err[:300]})"
        )
    return run


async def _dump_cluster_state(cluster_name: str) -> None:
    """Print the cluster's control-plane state/health (best-effort diagnostic)."""
    try:
        from flyteplugins.union.remote import Cluster  # type: ignore
        c = await Cluster.get.aio(name=cluster_name)  # type: ignore
        print(
            f"[ci]   diagnostic: cluster {cluster_name!r} CP state={c.state!r} "
            f"health={c.health!r} pools={c.pools}",
            flush=True,
        )
    except Exception as exc:  # noqa: BLE001 — diagnostics must never fail the retry loop
        print(f"[ci]   diagnostic: Cluster.get failed: {exc}", flush=True)


# ── scenario-level transient retry ───────────────────────────────────────────
#
# A full CI re-run re-provisions the whole cluster (~20–25 min), so a single
# transient blip in one scenario shouldn't sink the suite. Retry a scenario once
# on a *transient* failure (infra / registry / propagation), but never on a
# deterministic one (assertion mismatch, wrong cluster, missing outputs) — those
# must fail loudly so we don't mask a real regression with a flaky pass.
#
# Classification is by substring on the exception message; _assert_succeeded
# enriches its message with the run's error_info so reasons like
# "Back-off pulling image" / "Grace period [3m0s] exceeded" / "endpoint not
# ready within …" reach this matcher.
_TRANSIENT_SIGNATURES = (
    "no clusters found",
    "no cluster",                 # routing/capabilities propagation lag
    "imagepullbackoff",
    "errimagepull",
    "back-off pulling",           # registry throttling / pull backoff
    "grace period",               # pod reaped while pull/create still backing off
    "not ready within",           # endpoint cold-start / activation lag
    "did not reach a terminal state",  # _assert_succeeded wait timeout (resource starvation)
    "connection refused",
    "connection reset",
    "connection aborted",
    "deadline exceeded",
    "timed out",
    "etcdserver",                 # transient control-plane store contention
    "503",
    "502",
    "504",
    "temporarily unavailable",
    "service unavailable",
    "too many requests",          # 429 registry rate-limit
)


def _is_transient(exc: Exception) -> bool:
    msg = str(exc).lower()
    # 'cluster "<name>" not found' — CP cluster/queue cache lag right after
    # setup-routing's CreateCluster (same class as "no clusters found", but the
    # message shape doesn't contain that substring).
    if "cluster" in msg and "not found" in msg:
        return True
    return any(sig in msg for sig in _TRANSIENT_SIGNATURES)


_SCENARIO_MAX_ATTEMPTS = 2
_SCENARIO_RETRY_DELAY  = 15


async def _run_scenario_with_retry(name: str, factory):  # type: ignore[no-untyped-def]
    """Run a scenario, retrying once on a transient failure.

    `factory` is a zero-arg callable returning a *fresh* coroutine each call (a
    coroutine can only be awaited once, so a retry needs a new one). Returns the
    factory's result so callers that need it (e.g. hello → run object) can use it.
    """
    last: BaseException | None = None
    for attempt in range(1, _SCENARIO_MAX_ATTEMPTS + 1):
        try:
            return await factory()
        except Exception as exc:  # noqa: BLE001
            last = exc
            if attempt < _SCENARIO_MAX_ATTEMPTS and _is_transient(exc):
                print(
                    f"[ci] {name}: attempt {attempt}/{_SCENARIO_MAX_ATTEMPTS} hit a "
                    f"transient failure ({str(exc)[:160]}) — retrying scenario in "
                    f"{_SCENARIO_RETRY_DELAY}s …",
                    flush=True,
                )
                await asyncio.sleep(_SCENARIO_RETRY_DELAY)
                continue
            raise
    assert last is not None
    raise last


# ── smoke-test (hello only) ──────────────────────────────────────────────────

async def _smoke_test_async(
    control_plane_url: str,
    api_key: str,
    cluster_name: str,
    org: str,
) -> str:
    import uuid

    _ensure_workspace_in_path()
    from ci_smoke_task import hello as _hello  # type: ignore  # noqa: E402

    # Re-init after importing ci_smoke_task (module-level TaskEnvironment() can
    # reset the client's project/org routing).
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    print(
        f"[ci] smoke-test: client initialised — "
        f"endpoint={control_plane_url} project={cluster_name} org={org}",
        flush=True,
    )

    nonce = str(uuid.uuid4())
    print(f"[ci] smoke-test: submitting hello (nonce={nonce})", flush=True)
    run = await _submit_with_retry(_hello, "smoke-test", nonce=nonce)

    print(f"[ci] smoke-test: run={run.name}  url={run.url}", flush=True)
    await _assert_succeeded(run, "smoke-test")
    print(f"[ci] smoke-test: PASSED (run={run.name})", flush=True)
    return run.name


def cmd_smoke_test(args: argparse.Namespace) -> None:
    run_name = asyncio.run(
        _smoke_test_async(
            _env("CONTROL_PLANE_URL"),
            _env("UNION_API_KEY", required=False),
            _env("CLUSTER_NAME"),
            _env("ORG_NAME"),
        )
    )
    _gha_output("smoke_run_name", run_name)


# ── smoke suite verifications ────────────────────────────────────────────────

async def _verify_logs_async(run_name: str, project: str) -> None:
    """Fetch live logs from the run, optionally delete pods, verify logs persist."""
    from flyte.remote import Run  # type: ignore
    print(f"[ci] verify_logs: run={run_name}", flush=True)
    run = await Run.get.aio(name=run_name)  # type: ignore
    parts: list[str] = []
    async for line in run.get_logs.aio():  # type: ignore
        parts.append(line)
    if not "\n".join(parts).strip():
        raise RuntimeError(f"verify_logs: no logs returned for {run_name}")

    # Attempt pod deletion (best-effort; pods may already be gone).
    ns = f"{project}-development"
    result = subprocess.run(
        ["kubectl", "get", "pods", "-n", ns,
         f"-l", f"execution-id={run_name}",
         "--no-headers", "-o", "custom-columns=NAME:.metadata.name"],
        capture_output=True, text=True, check=False,
    )
    for pod in result.stdout.strip().splitlines():
        pod = pod.strip()
        if pod:
            subprocess.run(
                ["kubectl", "delete", "pod", pod, "-n", ns, "--wait=false"],
                check=False,
            )
    await asyncio.sleep(10)

    # Verify persistent logs still accessible.
    parts2: list[str] = []
    async for line in run.get_logs.aio():  # type: ignore
        parts2.append(line)
    if not "\n".join(parts2).strip():
        raise RuntimeError(
            f"verify_logs: logs empty after pod deletion for {run_name} "
            f"(persistent log storage may not be configured)"
        )
    print(f"[ci] verify_logs: PASSED ({run_name})", flush=True)


async def _verify_io_async(run_name: str) -> None:
    """Verify Run.outputs is non-None after task completion."""
    from flyte.remote import Run  # type: ignore
    print(f"[ci] verify_io: run={run_name}", flush=True)
    run = await Run.get.aio(name=run_name)  # type: ignore
    outputs = run.outputs
    if outputs is None:
        raise RuntimeError(f"verify_io: no outputs for {run_name}")
    print(f"[ci] verify_io: PASSED ({run_name})", flush=True)


async def _verify_image_builder_async(
    control_plane_url: str, api_key: str, cluster_name: str, org: str
) -> None:
    """Build a custom image (fastapi+requests) and run a task on it."""
    import uuid
    from ci_smoke_task import imgbuild_task  # type: ignore  # noqa: E402
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    nonce = str(uuid.uuid4())
    print(f"[ci] verify_image_builder: submitting imgbuild_task (nonce={nonce})", flush=True)
    run = await _submit_with_retry(imgbuild_task, "verify_image_builder", nonce=nonce)
    print(f"[ci] verify_image_builder: run={run.name}", flush=True)
    await _assert_succeeded(run, "verify_image_builder")
    print(f"[ci] verify_image_builder: PASSED (run={run.name})", flush=True)


async def _verify_image_cache_async(
    control_plane_url: str, api_key: str, cluster_name: str, org: str
) -> None:
    """Submit same stable-image task twice; second run should hit image cache."""
    import uuid
    from ci_smoke_task import imgcache_task  # type: ignore  # noqa: E402
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    nonce1, nonce2 = str(uuid.uuid4()), str(uuid.uuid4())
    print(f"[ci] verify_image_cache: run 1 (nonce={nonce1})", flush=True)
    run1 = await _submit_with_retry(imgcache_task, "verify_image_cache/run1", nonce=nonce1)
    await _assert_succeeded(run1, "verify_image_cache run 1")
    print(f"[ci] verify_image_cache: run 2 (nonce={nonce2}) — expect cache hit", flush=True)
    run2 = await _submit_with_retry(imgcache_task, "verify_image_cache/run2", nonce=nonce2)
    await _assert_succeeded(run2, "verify_image_cache run 2")
    print(f"[ci] verify_image_cache: PASSED (run1={run1.name} run2={run2.name})", flush=True)


async def _verify_reusable_async(
    control_plane_url: str, api_key: str, cluster_name: str, org: str
) -> None:
    """Fan out square() calls over a ReusePolicy environment (replicas=1, concurrency=1)."""
    from ci_smoke_task import reuse_driver  # type: ignore  # noqa: E402
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    n = 4  # fixed for reproducibility
    print(f"[ci] verify_reusable: submitting reuse_driver(n={n})", flush=True)
    run = await _submit_with_retry(reuse_driver, "verify_reusable", n=n)
    await _assert_succeeded(run, "verify_reusable")
    print(f"[ci] verify_reusable: PASSED (run={run.name})", flush=True)


async def _dump_app_state(app_name: str) -> None:
    """Print an app's spec.cluster_pool + full status from the control plane.

    Diagnostic for verify_app failures: shows whether the CP resolved the
    (unset) cluster_pool via routing rules — status.assigned_cluster — and the
    CP-side failure reason. Contains no credentials; best-effort only.
    """
    try:
        import flyte.remote  # type: ignore
        app = await flyte.remote.App.get.aio(name=app_name)
        pb = app.pb2
        print(f"[ci] verify_app: app {app_name!r} CP state:", flush=True)
        print(f"[ci]   spec.cluster_pool       = {pb.spec.cluster_pool!r}", flush=True)
        print(f"[ci]   status.assigned_cluster = {pb.status.assigned_cluster!r}", flush=True)
        # Full status block (deployment state, conditions, failure message).
        for line in str(pb.status).splitlines():
            print(f"[ci]   status| {line}", flush=True)
    except Exception as exc:  # noqa: BLE001 — diagnostics must not mask the real error
        print(f"[ci] verify_app: could not fetch app state: {exc}", flush=True)


async def _verify_app_async(
    control_plane_url: str, api_key: str, cluster_name: str, org: str
) -> None:
    """Deploy a FastAPI app, hit internal endpoints, deactivate."""
    from ci_app_task import app_deploy_test  # type: ignore  # noqa: E402
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    print("[ci] verify_app: submitting app_deploy_test", flush=True)
    run = await _submit_with_retry(app_deploy_test, "verify_app")
    print(f"[ci] verify_app: run={run.name}  url={run.url}", flush=True)
    # App deploy is the heaviest scenario (two image builds + a Knative revision
    # cold-start), but a healthy run completes in ~1 min (measured) and even a
    # fully-cold build is a few minutes. The default 600s is ample margin while
    # still failing/aborting a genuine hang ~5 min sooner than the old 900s.
    try:
        await _assert_succeeded(run, "verify_app")
    except Exception:
        # Dump the app's spec + status from the CP (assigned_cluster, deployment
        # state, failure message) so the run log shows WHERE the CP routed it and
        # WHY it failed, instead of just the SDK's generic "deployment has failed".
        await _dump_app_state(f"ci-app-{cluster_name}")
        raise
    # The task asserts status.assigned_cluster == CLUSTER_NAME internally, so a
    # succeeded run proves the control plane dispatched the app to this run's
    # dataplane (explicit cluster_pool pin — see ci_app_task.py).
    print(
        f"[ci] verify_app: PASSED (run={run.name}) — app assigned to cluster "
        f"{cluster_name!r}", flush=True
    )


async def _verify_trigger_async(
    control_plane_url: str, api_key: str, cluster_name: str, org: str
) -> None:
    """Deploy a scheduled trigger, verify its automation spec, and toggle active.

    No execution needed — the registered schedule is the signal, so this is cheap
    and topology-agnostic (triggers are supported on selfhosted and selfmanaged).
    """
    import flyte  # type: ignore
    import flyte.remote  # type: ignore
    from flyteidl2.task.common_pb2 import TriggerAutomationSpecType  # type: ignore

    _ensure_workspace_in_path()
    from ci_smoke_task import _trigger_env  # type: ignore  # noqa: E402

    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    print("[ci] verify_trigger: deploying trigger env", flush=True)
    await flyte.deploy.aio(_trigger_env)  # type: ignore

    trigger_name = flyte.Trigger.daily().name  # "daily"
    task_name = f"ci-trigger-{cluster_name}.triggered_task"

    td = await flyte.remote.Trigger.get.aio(name=trigger_name, task_name=task_name)  # type: ignore
    if td.automation_spec.type != TriggerAutomationSpecType.TYPE_SCHEDULE:
        raise RuntimeError(
            f"verify_trigger: expected TYPE_SCHEDULE, got {td.automation_spec.type}"
        )
    if not td.is_active:
        raise RuntimeError("verify_trigger: trigger is not active after deploy")

    # Toggle inactive → re-read → confirm the update round-trips.
    await flyte.remote.Trigger.update.aio(  # type: ignore
        name=trigger_name, task_name=task_name, active=False
    )
    td = await flyte.remote.Trigger.get.aio(name=trigger_name, task_name=task_name)  # type: ignore
    if td.is_active:
        raise RuntimeError("verify_trigger: trigger still active after deactivate")
    print(
        f"[ci] verify_trigger: PASSED (trigger {trigger_name!r} deployed, "
        f"schedule verified, deactivated)", flush=True
    )


async def _run_smoke_suite_async(
    control_plane_url: str,
    api_key: str,
    cluster_name: str,
    org: str,
    skip_app: bool = False,
) -> list[tuple[str, bool, str]]:
    """Run hello first, then all verify tests in parallel. Returns (name, passed, error).

    skip_app omits verify_app — app serving is not supported on selfhosted, so
    that leg gates it off (`run-smoke-suite --skip-app`).
    """
    _ensure_workspace_in_path()
    # Import both task modules so all TaskEnvironments register before client init.
    import ci_smoke_task  # type: ignore  # noqa: F401
    import ci_app_task    # type: ignore  # noqa: F401
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    print(
        f"[ci] smoke-suite: client initialised — "
        f"endpoint={control_plane_url} project={cluster_name} org={org}",
        flush=True,
    )

    # Wait for the operator's capabilities-aggregator to complete its first cycle
    # and publish K8s Plugin Config to the control plane.  Without this, the
    # status-updater can fire before capabilities are set, leaving the cluster
    # unable to schedule tasks ("no clusters found") even while health=healthy.
    # 120 s covers the worst-case capabilities-aggregator + control-plane cache lag
    # in the nominal path; the retry loop in _submit_with_retry handles the tail.
    print("[ci] smoke-suite: waiting 120s for operator capabilities to propagate …", flush=True)
    await asyncio.sleep(120)

    # Step 1: hello run (needed for verify_logs + verify_io). Wrapped in the
    # scenario retry so a transient pod/pull blip on the gating run doesn't sink
    # the whole suite before any verification has a chance to run.
    import uuid
    from ci_smoke_task import hello as _hello  # type: ignore

    async def _do_hello():  # type: ignore[no-untyped-def]
        nonce = str(uuid.uuid4())
        print(f"[ci] smoke-suite: submitting hello (nonce={nonce})", flush=True)
        r = await _submit_with_retry(_hello, "hello", nonce=nonce)
        print(f"[ci] smoke-suite: hello run={r.name}  url={r.url}", flush=True)
        await _assert_succeeded(r, "hello")
        return r

    hello_run = await _run_scenario_with_retry("hello", _do_hello)
    print(f"[ci] smoke-suite: hello PASSED", flush=True)
    run_name = hello_run.name

    results: list[tuple[str, bool, str]] = []

    # Step 2: the light/fast verify tests run in parallel — they reuse the hello
    # run or spin up short-lived build pods, so they don't contend for long.
    # Each is a factory (zero-arg) so _run_scenario_with_retry can re-invoke it.
    parallel_tests: list[tuple[str, "typing.Callable"]] = [  # type: ignore
        ("verify_logs",          lambda: _verify_logs_async(run_name, cluster_name)),
        ("verify_io",            lambda: _verify_io_async(run_name)),
        ("verify_image_builder", lambda: _verify_image_builder_async(control_plane_url, api_key, cluster_name, org)),
        ("verify_image_cache",   lambda: _verify_image_cache_async(control_plane_url, api_key, cluster_name, org)),
        ("verify_trigger",       lambda: _verify_trigger_async(control_plane_url, api_key, cluster_name, org)),
    ]
    p_names = [n for n, _ in parallel_tests]
    outcomes = await asyncio.gather(
        *(_run_scenario_with_retry(n, f) for n, f in parallel_tests),
        return_exceptions=True,
    )
    for name, outcome in zip(p_names, outcomes):
        if isinstance(outcome, Exception):
            results.append((name, False, str(outcome)[:300]))
            print(f"[ci] smoke-suite: FAILED  {name}: {outcome}", flush=True)
        else:
            results.append((name, True, ""))

    # Step 3: the heavy tests run sequentially. Each needs a persistent pod
    # (reusable actor; app revision + tester) that, together with Knative
    # serving, can't co-schedule alongside the other on the 4-vCPU CI runner —
    # running them back-to-back lets each use the freed CPU instead of both
    # parking in WAITING_FOR_RESOURCES.
    sequential_tests: list[tuple[str, "typing.Callable"]] = [  # type: ignore
        ("verify_reusable",      lambda: _verify_reusable_async(control_plane_url, api_key, cluster_name, org)),
    ]
    if skip_app:
        print("[ci] smoke-suite: verify_app SKIPPED (app serving unsupported on this topology)", flush=True)
    else:
        sequential_tests.append(
            ("verify_app", lambda: _verify_app_async(control_plane_url, api_key, cluster_name, org))
        )
    for name, factory in sequential_tests:
        try:
            await _run_scenario_with_retry(name, factory)
            results.append((name, True, ""))
        except Exception as outcome:  # noqa: BLE001
            results.append((name, False, str(outcome)[:300]))
            print(f"[ci] smoke-suite: FAILED  {name}: {outcome}", flush=True)

    # Summary table.
    print("\n[ci] ── smoke suite results ──────────────────────────────────", flush=True)
    for name, passed, err in results:
        status = "PASSED" if passed else "FAILED"
        detail = f"  {err[:80]}" if err else ""
        print(f"[ci]   {name:<24} {status}{detail}", flush=True)
    passed_count = sum(1 for _, p, _ in results if p)
    print(f"[ci] {passed_count}/{len(results)} passed", flush=True)
    return results


def cmd_run_smoke_suite(args: argparse.Namespace) -> None:
    results = asyncio.run(
        _run_smoke_suite_async(
            _env("CONTROL_PLANE_URL"),
            _env("UNION_API_KEY", required=False),
            _env("CLUSTER_NAME"),
            _env("ORG_NAME"),
            skip_app=args.skip_app,
        )
    )
    failed = [(n, e) for n, p, e in results if not p]
    if failed:
        sys.exit(
            "[ci] smoke-suite FAILED: "
            + ", ".join(n for n, _ in failed)
        )


# ── teardown ────────────────────────────────────────────────────────────────

async def _teardown_step(label: str, coro) -> None:  # type: ignore[no-untyped-def]
    """Await a teardown coroutine, logging and swallowing any error — a failed
    cleanup must never fail the always() teardown step."""
    try:
        await coro
        print(f"[ci] teardown: {label} OK", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[ci] teardown: {label} failed (ignored): {str(e)[:200]}", flush=True)


def cmd_teardown(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    # ORG_NAME is produced by the wait-healthy step; absent if the run failed
    # before then (setup-routing never ran, so there is no pool/queue/project to
    # clean up — only the cluster delete).
    org = os.environ.get("ORG_NAME", "").strip()
    control_plane_url = _env("CONTROL_PLANE_URL", required=False)
    api_key = _env("UNION_API_KEY", required=False)

    if not control_plane_url:
        print("[ci] teardown: CONTROL_PLANE_URL unset — nothing to clean up.", flush=True)
        return

    # Deregister the ephemeral cluster only. The dataplane name is STABLE and its
    # pool / queue / project / run.default_queue are REUSED across runs (create-only
    # / additive model — same convention as configure_queues.py). Draining the queue
    # or archiving the project would break the next run (a drained queue rejects
    # submissions; an archived project can't schedule), so teardown leaves them in
    # place; setup-routing re-registers the cluster (operator heartbeat) and re-pins
    # routing next run. Only the k8s cluster is torn down (a separate workflow step).
    async def _teardown_async() -> None:
        from flyteplugins.union.remote import Cluster  # type: ignore
        await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
        print(f"[ci] teardown: deregistering cluster {cluster_name} (pool/queue/project reused)", flush=True)
        await _teardown_step("cluster delete", Cluster.delete.aio(name=cluster_name))  # type: ignore

    try:
        asyncio.run(_teardown_async())
    except Exception as e:  # noqa: BLE001 — teardown must never fail the job
        print(f"[ci] teardown: cleanup failed (ignored): {str(e)[:200]}", flush=True)
    print("[ci] teardown: done.", flush=True)


# ── main ────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description="Dataplane CI helper (flyte 2.x SDK; no uctl)")
    sub = p.add_subparsers(dest="command", required=True)

    p_wait = sub.add_parser("wait-healthy")
    p_wait.add_argument("--timeout", type=int, default=300)

    sub.add_parser("setup-routing")
    sub.add_parser("smoke-test")
    p_suite = sub.add_parser("run-smoke-suite")
    p_suite.add_argument(
        "--skip-app", action="store_true",
        help="Omit verify_app (app serving is unsupported on selfhosted).",
    )
    sub.add_parser("teardown")

    args = p.parse_args()
    {
        "wait-healthy":     cmd_wait_healthy,
        "setup-routing":    cmd_setup_routing,
        "smoke-test":       cmd_smoke_test,
        "run-smoke-suite":  cmd_run_smoke_suite,
        "teardown":         cmd_teardown,
    }[args.command](args)


if __name__ == "__main__":
    main()
