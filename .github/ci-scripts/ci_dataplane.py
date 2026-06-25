#!/usr/bin/env python3
"""
Dataplane CI helper — SDK-based operations that shell scripts can't do cleanly.

Mirrors the patterns from selfmanaged_common.py / smoke_tests.py in
unionai-docs/scripts. Runs inside GitHub Actions; every command writes its
key output to $GITHUB_OUTPUT so subsequent steps can consume it.

Commands
--------
provision       Run `uctl selfserve provision-dataplane-resources`, write the
                generated values file to disk, emit ORG_NAME.
wait-healthy    Poll Cluster.get until enabled+healthy. Emit ORG_NAME.
setup-routing   Create cluster pool + project, assign this run's cluster (and
                its implicit queue) to them, route all domains → ensures this
                PR's test run only hits our cluster.
eager-api-key   Create EAGER_API_KEY (idempotent).
smoke-test      Submit and wait for the hello workflow on our project.
teardown        Deregister the cluster from the control plane.

Environment
-----------
CLUSTER_NAME            required — unique per run (e.g. ci-<github_run_id>)
CONTROL_PLANE_URL       required — https://byok.us-west-2.union.ai
UNION_API_KEY           required — base64-encoded Union API key
ORG_NAME                optional — resolved automatically by wait-healthy
GITHUB_OUTPUT           set by Actions runner; commands write key=value here
PROVISION_WORK_DIR      set by provision; read by other commands for the
                        generated values file path
"""

from __future__ import annotations

import argparse
import asyncio
import glob
import logging
import os
import re
import subprocess
import sys
import tempfile
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


def _diag_exc(exc: BaseException, label: str) -> None:
    """Print the FULL exception chain for a build/run submission failure.

    The flyte SDK collapses the underlying transport error into a generic
    ``RuntimeSystemError("Flyte system is currently unavailable. …")`` (see
    flyte/_run.py: the CreateRun handler maps connectrpc ``Code.UNAVAILABLE`` to
    that string), but chains the real error via ``raise … from e``. The remote
    image build submits a CreateRun for the control-plane system image-builder
    task (project=system, domain=production, name=build-image), so a failing
    build surfaces only the wrapper text in the smoke summary.

    This walks the ``__cause__`` / ``__context__`` chain and extracts the
    connectrpc/gRPC ``code`` + ``message`` + ``details`` so the CI log shows the
    ACTUAL control-plane status (e.g. UNAVAILABLE vs UNAUTHENTICATED vs
    NOT_FOUND) instead of the generic wrapper. Purely diagnostic — never raises.
    """
    import traceback
    print(f"\n[ci] +-- {label}: full error diagnostic -------------------------", flush=True)
    seen: set[int] = set()
    e: BaseException | None = exc
    depth = 0
    while e is not None and id(e) not in seen and depth < 12:
        seen.add(id(e))
        cls = f"{type(e).__module__}.{type(e).__qualname__}"
        print(f"[ci] | [{depth}] {cls}: {e}", flush=True)
        # connectrpc.ConnectError exposes .code/.message/.details as properties;
        # grpc.aio.AioRpcError exposes .code()/.details() as callables — handle both.
        code = getattr(e, "code", None)
        if code is not None:
            try:
                code_val = code() if callable(code) else code
            except Exception:  # noqa: BLE001
                code_val = code
            cname = getattr(code_val, "name", None) or getattr(code_val, "value", None) or code_val
            print(f"[ci] |      code    = {cname!r}", flush=True)
        msg = getattr(e, "message", None)
        if msg and not callable(msg):
            print(f"[ci] |      message = {msg!r}", flush=True)
        details = getattr(e, "details", None)
        if details is not None:
            try:
                dval = details() if callable(details) else details
                if dval:
                    print(f"[ci] |      details = {dval!r}", flush=True)
            except Exception:  # noqa: BLE001
                pass
        des = getattr(e, "debug_error_string", None)
        if callable(des):
            try:
                print(f"[ci] |      debug   = {des()!r}", flush=True)
            except Exception:  # noqa: BLE001
                pass
        e = e.__cause__ or e.__context__
        depth += 1
    print("[ci] | traceback:", flush=True)
    for line in "".join(
        traceback.format_exception(type(exc), exc, exc.__traceback__)
    ).splitlines():
        print(f"[ci] |   {line}", flush=True)
    print("[ci] +-----------------------------------------------------------", flush=True)


def _uctl_extra_env() -> dict:
    """Return BYOK_CLIENT_SECRET decoded from UNION_API_KEY for uctl subprocesses.

    The uctl config uses clientSecretEnvVar: BYOK_CLIENT_SECRET, so uctl looks
    for that env var at call time.  We decode UNION_API_KEY (base64 of
    host:clientId:clientSecret:None) to extract the secret rather than
    requiring a separate env var in the workflow.
    """
    import base64
    api_key = os.environ.get("UNION_API_KEY", "")
    if not api_key:
        return {}
    try:
        decoded = base64.b64decode(api_key + "==").decode()
        parts = decoded.split(":")
        # format: host : clientId : clientSecret : None
        # clientSecret may itself contain ':', so join everything between [2] and [-1]
        if len(parts) >= 4:
            client_secret = ":".join(parts[2:-1])
            return {"BYOK_CLIENT_SECRET": client_secret}
    except Exception as exc:
        logger.warning(f"Could not decode UNION_API_KEY for uctl env: {exc}")
    return {}


def _run_uctl(*cmd: str) -> tuple[int, str]:
    """Run a uctl command, capture output, print it, and return (returncode, output).

    All uctl calls should go through here so their stdout/stderr is always
    visible in CI logs.  The caller decides whether a non-zero exit is fatal.
    """
    result = subprocess.run(
        list(cmd),
        capture_output=True,
        text=True,
        env={**os.environ, **_uctl_extra_env()},
    )
    output = (result.stdout + result.stderr).strip()
    if output:
        print(output, flush=True)
    return result.returncode, output


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


# ── provision ───────────────────────────────────────────────────────────────

def cmd_provision(args: argparse.Namespace) -> None:
    """Shell out to uctl provision, parse output, write values file to disk."""
    cluster_name     = _env("CLUSTER_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL").removeprefix("https://").removeprefix("http://")

    import time as _time
    work_dir = tempfile.mkdtemp(prefix="union-ci-provision-")
    print(f"[ci] provision: working in {work_dir}", flush=True)

    # provision-dataplane-resources writes a values file to cwd; retry on transient errors.
    output = ""
    for attempt in range(1, 4):
        result = subprocess.run(
            ["uctl", "selfserve", "provision-dataplane-resources",
             "--clusterName", cluster_name, "--provider", "metal",
             # Default per-retry timeout is 15s with 4 retries = 60s cap.
             # The provision RPC can take longer on a loaded control plane,
             # so raise per-retry to 90s and keep 3 retries → up to ~5 min.
             "--admin.perRetryTimeout", "90s", "--admin.maxRetries", "3"],
            cwd=work_dir, capture_output=True, text=True,
            env={**os.environ, **_uctl_extra_env()},
        )
        output = result.stdout + result.stderr
        print(output, flush=True)
        if result.returncode == 0:
            break
        low = output.lower()
        if attempt < 3 and ("503" in output or "unavailable" in low or "internal" in low or "name cannot be empty" in low or "deadline exceeded" in low or "deadlineexceeded" in low):
            print(f"[ci] provision: attempt {attempt} failed (transient), retrying in 20s…", flush=True)
            _time.sleep(20)
            continue
        sys.exit(f"[ci] ERROR: uctl provision-dataplane-resources failed (exit {result.returncode})")

    # Locate the generated values file.  uctl prints a line like:
    #   Generated values file: values-metal.yaml   (or similar)
    values_file = ""
    for line in output.splitlines():
        if "Generated" in line and ".yaml" in line:
            for word in line.split():
                if word.endswith(".yaml"):
                    candidate = os.path.join(work_dir, word)
                    if os.path.exists(candidate):
                        values_file = candidate
                        break
            if values_file:
                break
    if not values_file:
        candidates = glob.glob(os.path.join(work_dir, "*-values.yaml"))
        if candidates:
            values_file = candidates[0]
    if not values_file or not os.path.exists(values_file):
        sys.exit(
            f"[ci] ERROR: could not find generated values file in {work_dir}.\n"
            f"uctl output:\n{output}"
        )

    # Copy to a stable path the workflow can reference.
    dest = args.values_out
    with open(values_file) as f:
        content = f.read()
    with open(dest, "w") as f:
        f.write(content)
    print(f"[ci] provision: values written to {dest}", flush=True)

    # Parse org name from the uctl table output:
    #  | <cluster> | <org> | STATE_... | ...
    org_name = ""
    for line in output.splitlines():
        if cluster_name in line and "|" in line:
            fields = [f.strip() for f in line.split("|")]
            if len(fields) >= 3 and fields[1]:
                org_name = fields[1]
                break

    _gha_output("values_file", dest)
    _gha_output("org_name", org_name)
    print(f"[ci] provision: org={org_name or '(not parsed yet)'}", flush=True)


# ── wait-healthy ─────────────────────────────────────────────────────────────

async def _wait_healthy_async(
    cluster_name: str,
    control_plane_url: str,
    api_key: str,
    timeout: int,
    stable: int = 1,
    require_pools: bool = False,
) -> str:
    """Poll Cluster.get until the cluster is enabled+healthy.

    `stable` is the number of CONSECUTIVE healthy observations required before
    returning. Use stable=1 for the initial registration wait; use stable>1
    after an operator restart, when CP-side health flaps (a single healthy poll
    can be a transient blip immediately before the cluster drops back to
    unhealthy — which is exactly what makes downstream builds/runs flake). Any
    non-healthy observation resets the streak.

    `require_pools` additionally requires the cluster to report a NON-EMPTY pool
    list before counting an observation as healthy. `health='healthy'` alone is
    insufficient post-restart: run 28180756189 showed `health='healthy' pools=[]`
    while the `[default]` pool config was still syncing to the object store, so
    the queue-less image build hit UNAVAILABLE "[default] pool config still
    syncing". Only set this AFTER setup-routing has assigned a pool (the initial
    registration wait legitimately sees `pools=[]`).
    """
    from flyteplugins.union.remote import Cluster  # type: ignore

    await _init_client(control_plane_url, api_key, project=cluster_name)
    print(
        f"[ci] wait-healthy: polling Cluster.get(name={cluster_name}) "
        f"(timeout={timeout}s, require {stable} consecutive healthy"
        f"{', non-empty pools' if require_pools else ''})",
        flush=True,
    )
    deadline = time.time() + timeout
    streak = 0
    last_org = ""
    diagnosed_err = False  # dump the full Cluster.get error chain only once
    while time.time() < deadline:
        try:
            cluster = await Cluster.get.aio(name=cluster_name)  # type: ignore
            state  = cluster.state
            health = cluster.health
            org    = cluster.organization or ""
            if org:
                last_org = org
            # Only read .pools when we actually gate on it. `.pools` is a LAZY
            # property that fires a secondary fetch; in the not-yet-routed initial
            # registration state (org='', no pools assigned) flyteplugins-union
            # 0.4.3 raises "'Headers' object is not callable" from that fetch,
            # which would sink the whole poll and time out the initial gate (this
            # was a self-inflicted regression — the initial gate never needs pools).
            # Read it only for --require-pools (post-restart, cluster already
            # routed, the context where .pools is known to work), and defensively.
            pools = "(not checked)"
            pools_ok = True
            if require_pools:
                try:
                    pools = cluster.pools
                    pools_ok = bool(pools)
                except Exception as pe:  # noqa: BLE001
                    pools = f"(pools fetch error: {str(pe)[:80]})"
                    pools_ok = False
            if state == "enabled" and health == "healthy" and pools_ok:
                streak += 1
                print(f"[ci]   state={state} health={health} pools={pools} org={org} (healthy {streak}/{stable})", flush=True)
                if streak >= stable:
                    print(f"[ci] wait-healthy: HEALTHY (org={org}, pools={pools})", flush=True)
                    return org
            else:
                reason = ""
                if require_pools and not pools_ok and state == "enabled" and health == "healthy":
                    reason = " — healthy but pools=[] (pool config still syncing)"
                if streak:
                    print(f"[ci]   state={state} health={health} pools={pools} org={org}{reason} — healthy streak reset", flush=True)
                else:
                    print(f"[ci]   state={state} health={health} pools={pools} org={org}{reason}", flush=True)
                streak = 0
        except Exception as e:
            print(f"[ci]   Cluster.get error: {e}", flush=True)
            # `'Headers' object is not callable` (seen fleet-wide from ~15:50 on
            # 2026-06-25) is a CLIENT-side TypeError raised inside Cluster.get's
            # error path — it MASKS whatever the control plane actually returned
            # (same swallow-the-real-error pattern as "Flyte system unavailable").
            # Dump the full chain+traceback ONCE so we see where it's raised and
            # the underlying response, instead of just the opaque TypeError.
            if not diagnosed_err:
                diagnosed_err = True
                _diag_exc(e, "wait-healthy/Cluster.get")
            streak = 0
        await asyncio.sleep(15)
    raise RuntimeError(
        f"Cluster {cluster_name} did not stay enabled+healthy"
        f"{'+pooled' if require_pools else ''} "
        f"({stable} consecutive) within {timeout}s (last_org={last_org!r})"
    )


def cmd_wait_healthy(args: argparse.Namespace) -> None:
    cluster_name      = _env("CLUSTER_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key           = _env("UNION_API_KEY", required=False)
    org = asyncio.run(
        _wait_healthy_async(
            cluster_name, control_plane_url, api_key, args.timeout,
            stable=args.stable, require_pools=args.require_pools,
        )
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
      * the project/domain → pool CLUSTER_ASSIGNMENT attributes are still
        load-bearing for the DATAPROXY: CreateUploadLocation resolves the
        project's pool to pick which cluster's object store receives the
        fast-registration code bundle (dataproxy/service/cluster_selector.go).
        Without them our project resolves to the org default pool and bundles
        land in some other cluster's bucket → task pods 404 on download.
    Each PR still gets its own pool (== cluster == queue == project name), so
    parallel PRs can't land on each other's dataplane.
    """
    from flyte.remote import Project  # type: ignore
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

    # 4. Create project (idempotent)
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

    # 5. Route all three domains → pool (CLUSTER_ASSIGNMENT attributes). Run
    # scheduling no longer reads these, but the dataproxy and app pool
    # resolution still do (see docstring) — without them fast-registration
    # uploads go to the default pool's object store and every task 404s
    # downloading its code bundle. Fatal on failure: better a clear error here
    # than a cryptic FileNotFoundError 20 minutes into the smoke suite.
    for domain in ("development", "staging", "production"):
        attr_tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=f"-{domain}.yaml", delete=False
        )
        attr_tmp.write(
            f"domain: {domain}\n"
            f"project: {project_id}\n"
            f"clusterPoolName: {pool_name}\n"
        )
        attr_tmp.close()
        print(
            f"[ci] setup-routing: routing {project_id}/{domain} → {pool_name}",
            flush=True,
        )
        try:
            rc, out = _run_uctl(
                "uctl", "update", "cluster-pool-attributes", "--force",
                "--attrFile", attr_tmp.name, "--org", org,
            )
            if rc != 0:
                raise RuntimeError(
                    f"uctl update cluster-pool-attributes exited {rc} "
                    f"({project_id}/{domain} → {pool_name})\n{out[:400]}"
                )
        finally:
            os.unlink(attr_tmp.name)

    print(
        f"[ci] setup-routing: done — project '{project_id}', pool '{pool_name}', "
        f"queue '{cluster_name}' all pinned to cluster '{cluster_name}' "
        f"(dev/staging/prod attributes set)",
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


# ── eager-api-key ──────────────────────────────────────────────────────────

def cmd_eager_api_key(args: argparse.Namespace) -> None:
    """Create EAGER_API_KEY via uctl (idempotent).

    The provision instructions say to use `uctl create apikey` — this
    propagates the key to the cluster's operator so the webhook can inject it
    as a K8s secret into task pods.  The Python SDK ApiKey.create.aio() only
    creates the key on the control plane without triggering the cluster sync.
    """
    import time
    org_name = _env("ORG_NAME", required=False) or ""
    # --org is a global uctl flag (matches provision step 6 instructions)
    org_flag = ["--org", org_name] if org_name else []

    for attempt in range(1, 6):
        result = subprocess.run(
            ["uctl"] + org_flag + ["create", "apikey", "--keyName", "EAGER_API_KEY"],
            capture_output=True, text=True,
            env={**os.environ, **_uctl_extra_env()},
        )
        output = result.stdout + result.stderr
        print(output, flush=True)
        if result.returncode == 0:
            print("[ci] eager-api-key: EAGER_API_KEY created.", flush=True)
            return
        low = output.lower()
        if "already exists" in low or "alreadyexists" in low:
            print("[ci] eager-api-key: key already exists (re-propagated).", flush=True)
            return
        if attempt < 5 and ("503" in output or "unavailable" in low or "internal" in low):
            print(f"[ci] eager-api-key: attempt {attempt} failed (transient), retrying in 15s…", flush=True)
            time.sleep(15)
            continue
        sys.exit(f"[ci] ERROR: uctl create apikey failed (exit {result.returncode})")
    else:
        print("[ci] eager-api-key: EAGER_API_KEY created.", flush=True)


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
            #
            # "cluster pool [default] config … is still syncing and hasn't
            # updated its object store" is the same class one layer down: the
            # remote image build submits its run queue-less → the [default] pool,
            # whose config sync lags right after the cluster/operator restart.
            # It resolves once the pool config syncs, so it's worth the same
            # retry window (UNMASKED via _diag_exc — the SDK shows only the
            # generic "Flyte system is currently unavailable" for it).
            if (
                "no clusters found" in msg
                or "no cluster" in msg
                or ("cluster" in msg and "not found" in msg)
                or "still syncing" in msg
                or "hasn't updated its object store" in msg
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
    "still syncing",              # [default] cluster-pool config sync lag (queue-less image build)
    "hasn't updated its object store",  # same: pool config not yet flushed to object store
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


def _exc_chain_text(exc: BaseException) -> str:
    """Concatenate the message of an exception AND its whole cause/context chain.

    CRITICAL: the flyte SDK collapses the real transport error into a generic
    ``RuntimeSystemError("Flyte system is currently unavailable …")`` wrapper and
    chains the actual connectrpc error via ``raise … from e``. So the transient
    signatures (e.g. "still syncing") live in ``exc.__cause__``, NOT in
    ``str(exc)``. Matching only ``str(exc)`` (the old behaviour) meant the retry
    NEVER fired for these wrapped errors — the probe failed after 1 attempt. Walk
    the chain (same traversal as ``_diag_exc``) so the signature is found wherever
    in the chain it sits. Also fold in connectrpc ``.message`` (the wire text is
    on the ConnectError attribute, not always in ``str``).
    """
    parts: list[str] = []
    seen: set[int] = set()
    e: typing.Optional[BaseException] = exc
    depth = 0
    while e is not None and id(e) not in seen and depth < 12:
        seen.add(id(e))
        parts.append(str(e))
        m = getattr(e, "message", None)
        if m and not callable(m):
            parts.append(str(m))
        e = e.__cause__ or e.__context__
        depth += 1
    return " || ".join(parts).lower()


def _is_transient(exc: Exception) -> bool:
    msg = _exc_chain_text(exc)
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


async def _run_smoke_suite_async(
    control_plane_url: str,
    api_key: str,
    cluster_name: str,
    org: str,
) -> list[tuple[str, bool, str]]:
    """Run hello first, then all verify tests in parallel. Returns (name, passed, error)."""
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
            _diag_exc(outcome, f"smoke-suite/{name}")
        else:
            results.append((name, True, ""))

    # Step 3: the heavy tests run sequentially. Each needs a persistent pod
    # (reusable actor; app revision + tester) that, together with Knative
    # serving, can't co-schedule alongside the other on the 4-vCPU CI runner —
    # running them back-to-back lets each use the freed CPU instead of both
    # parking in WAITING_FOR_RESOURCES.
    sequential_tests: list[tuple[str, "typing.Callable"]] = [  # type: ignore
        ("verify_reusable",      lambda: _verify_reusable_async(control_plane_url, api_key, cluster_name, org)),
        ("verify_app",           lambda: _verify_app_async(control_plane_url, api_key, cluster_name, org)),
    ]
    for name, factory in sequential_tests:
        try:
            await _run_scenario_with_retry(name, factory)
            results.append((name, True, ""))
        except Exception as outcome:  # noqa: BLE001
            results.append((name, False, str(outcome)[:300]))
            print(f"[ci] smoke-suite: FAILED  {name}: {outcome}", flush=True)
            _diag_exc(outcome, f"smoke-suite/{name}")

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
        )
    )
    failed = [(n, e) for n, p, e in results if not p]
    if failed:
        sys.exit(
            "[ci] smoke-suite FAILED: "
            + ", ".join(n for n, _ in failed)
        )


# ── teardown ────────────────────────────────────────────────────────────────

def cmd_teardown(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    # ORG_NAME is produced by the wait-healthy step; absent if the run failed
    # before then (in which case setup-routing never ran, so there are no pool/
    # queue/project to clean up — only the cluster delete below).
    org = os.environ.get("ORG_NAME", "").strip()

    print(f"[ci] teardown: deregistering cluster {cluster_name}", flush=True)
    _run_uctl("uctl", "delete", "cluster", cluster_name)

    if not org:
        print("[ci] teardown: ORG_NAME unset — skipping pool/routing cleanup.", flush=True)
        print("[ci] teardown: done.", flush=True)
        return

    # setup-routing creates a pool, an implicit queue, a project and per-domain
    # routing attributes, all keyed by this run's id (pool == queue == project
    # == cluster_name). Clean up best-effort (a failed delete must never fail
    # the always() teardown step):
    #   * delete the per-domain CLUSTER_ASSIGNMENT attributes (still used by
    #     dataproxy/app routing).
    #   * drain the queue — queues have NO delete RPC, so draining (stops new
    #     submissions) is the most we can do; the cluster delete above already
    #     removed the cluster from the queue's spec.
    #   * delete the pool — today this returns FailedPrecondition because the
    #     drained queue still references it; attempted anyway so cleanup starts
    #     working the moment the CP allows deleting pools with drained queues.
    #     Until then each run leaks one empty pool + one drained queue on the
    #     shared staging CP.
    #   * archive the project (Flyte has no project delete).
    async def _drain_and_delete_async() -> None:
        from flyteplugins.union.remote import ClusterPool, Queue  # type: ignore
        control_plane_url = _env("CONTROL_PLANE_URL", required=False)
        api_key = _env("UNION_API_KEY", required=False)
        if not control_plane_url:
            print("[ci] teardown: CONTROL_PLANE_URL unset — skipping queue/pool cleanup.", flush=True)
            return
        await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
        try:
            await Queue.drain.aio(cluster_name)  # type: ignore
            print(f"[ci] teardown: queue '{cluster_name}' drained", flush=True)
        except Exception as e:
            print(f"[ci] teardown: queue drain failed (ignored): {str(e)[:200]}", flush=True)
        try:
            await ClusterPool.delete.aio(cluster_name)  # type: ignore
            print(f"[ci] teardown: pool '{cluster_name}' deleted", flush=True)
        except Exception as e:
            print(
                f"[ci] teardown: pool delete failed (ignored — pools with queues "
                f"are not deletable yet): {str(e)[:200]}",
                flush=True,
            )

    try:
        asyncio.run(_drain_and_delete_async())
    except Exception as e:  # noqa: BLE001 — teardown must never fail the job
        print(f"[ci] teardown: queue/pool cleanup failed (ignored): {str(e)[:200]}", flush=True)

    def _best_effort(label: str, *cmd: str) -> None:
        rc, _ = _run_uctl(*cmd)
        if rc != 0:
            print(f"[ci] teardown: {label} cleanup returned rc={rc} (ignored)", flush=True)

    for domain in ("development", "staging", "production"):
        _best_effort(
            f"routing/{domain}",
            "uctl", "delete", "cluster-pool-attributes",
            "-p", cluster_name, "-d", domain, "--org", org,
        )
    # Projects can't be deleted, only archived — leaves no schedulable routing.
    _best_effort(
        "project",
        "uctl", "update", "project", "-p", cluster_name, "--archive", "--org", org,
    )
    print("[ci] teardown: done.", flush=True)


# ── probe-image-builder (diagnostic) ─────────────────────────────────────────

# ── operator CPU / CFS-throttle probe (resource-starvation hypothesis) ────────
#
# The open question on the CI dataplane flap is WHY CP-reported Cluster.get
# health drops to `unhealthy` mid-run. Strong prior: the 4-vCPU GitHub runner is
# CPU-saturated (k3d server + operator + buildkit + rustfs + knative + task
# pods), so the union-operator pod gets CFS-throttled, misses heartbeats / fails
# its own health probes → CP marks the cluster unhealthy → flap.
#
# To settle CPU-starvation-vs-CP-side we read the kubelet's built-in cAdvisor
# metrics (`container_cpu_cfs_throttled_periods_total` etc.) directly via the
# apiserver node proxy. This needs NO metrics-server and gives the gold-standard
# throttle signal per container. All best-effort; never raises.

_CADV_RE = re.compile(
    r"^(container_cpu_(?:usage_seconds|cfs_throttled_periods|cfs_periods)_total)"
    r"\{([^}]*)\}\s+([0-9eE.+-]+)"
)


def _parse_labels(s: str) -> dict:
    return dict(re.findall(r'(\w+)="([^"]*)"', s))


def _first_node_name() -> typing.Optional[str]:
    out = subprocess.run(
        ["kubectl", "get", "nodes", "-o", "jsonpath={.items[0].metadata.name}"],
        capture_output=True, text=True, check=False,
    )
    n = out.stdout.strip()
    return n or None


def _pod_for_label(ns: str, selector: str) -> typing.Optional[str]:
    out = subprocess.run(
        ["kubectl", "get", "pods", "-n", ns, "-l", selector,
         "-o", "jsonpath={.items[0].metadata.name}"],
        capture_output=True, text=True, check=False,
    )
    n = out.stdout.strip()
    return n or None


def _cadvisor_scrape(node: str) -> str:
    """Raw cAdvisor metrics for a node (best-effort, '' on failure)."""
    out = subprocess.run(
        ["kubectl", "get", "--raw", f"/api/v1/nodes/{node}/proxy/metrics/cadvisor"],
        capture_output=True, text=True, check=False,
    )
    return out.stdout


def _cadvisor_counters(scrape: str) -> dict:
    """Parse a cAdvisor scrape into {(namespace, pod, container): {usage, throttled, periods}}.

    The node-root cgroup (whole-machine CPU) is keyed as ('', '<node>', '').
    """
    res: dict = {}
    for line in scrape.splitlines():
        m = _CADV_RE.match(line)
        if not m:
            continue
        metric, labels, val = m.group(1), _parse_labels(m.group(2)), m.group(3)
        try:
            v = float(val)
        except ValueError:
            continue
        ns = labels.get("namespace", "")
        pod = labels.get("pod", "")
        c = labels.get("container", "")
        if not pod and labels.get("id") == "/":
            key = ("", "<node>", "")  # whole-node root cgroup
        elif pod and c:
            key = (ns, pod, c)
        else:
            continue
        d = res.setdefault(key, {"usage": 0.0, "throttled": 0.0, "periods": 0.0})
        if metric == "container_cpu_usage_seconds_total":
            d["usage"] = v
        elif metric == "container_cpu_cfs_throttled_periods_total":
            d["throttled"] = v
        elif metric == "container_cpu_cfs_periods_total":
            d["periods"] = v
    return res


def _fmt_cpu_delta(prev: dict, cur: dict, ns: str, pod: str, dt: float) -> str:
    """Format cores-used + CFS-throttle% for a POD over [prev,cur].

    The container name in cAdvisor is NOT necessarily the chart app name, so we
    aggregate by pod: sum CPU usage across the pod's containers, and report the
    throttle% of its busiest (max-usage) container — the one that would stall the
    operator if CPU-starved. Avoids a hardcoded container-name that silently
    misses (the bug that produced `operator=n/a`).
    """
    def _pod_containers(d: dict) -> dict:
        return {k[2]: v for k, v in d.items() if k[0] == ns and k[1] == pod and k[2] not in ("", "POD")}
    a, b = _pod_containers(prev), _pod_containers(cur)
    if not b:
        return "n/a"
    if not a or dt <= 0:
        return "warming"
    cores = sum(b[c]["usage"] - a[c]["usage"] for c in b if c in a) / dt
    # busiest container drives the throttle reading
    busy = max(b, key=lambda c: (b[c]["usage"] - a.get(c, b[c])["usage"]) if c in a else 0.0)
    dper = b[busy]["periods"] - a.get(busy, b[busy])["periods"]
    dthr = b[busy]["throttled"] - a.get(busy, b[busy])["throttled"]
    thr = (dthr / dper * 100.0) if dper > 0 else 0.0
    return f"{cores:.2f}c thr={thr:.0f}%"


def _resolve_targets(ns: str) -> dict:
    """Map {label: (ns, pod)} for the pods whose CPU we track.

    Re-resolved each tick so a restart (new pod name) is followed. CPU is then
    aggregated across whatever containers that pod has (see _fmt_cpu_delta).
    """
    targets: dict = {}
    op = _pod_for_label(ns, "app.kubernetes.io/name=union-operator")
    if op:
        targets["operator"] = (ns, op)
    px = _pod_for_label(ns, "app.kubernetes.io/name=operator-proxy")
    if px:
        targets["proxy"] = (ns, px)
    return targets


def _operator_checker_tail(ns: str, since: str = "25s", n: int = 14) -> None:
    """Print the operator's recent per-health-checker / heartbeat verdicts.

    `health=unhealthy` is a CP-side aggregate; the operator computes the
    underlying signals (proxy/executor/propeller-health-checker, heartbeat-
    updater, tunnel-updater). At a flap edge these lines say WHICH signal went
    bad first. Best-effort; never raises.
    """
    _CHECKER_KEYS = (
        "health-checker", "health checker", "healthcheck",
        "heartbeat", "tunnel", "capabilit", "unhealthy", "degraded",
        "not ready", "reconnect", "disconnect", "lease",
    )
    try:
        out = subprocess.run(
            ["kubectl", "logs", "-n", ns, "-l", "app.kubernetes.io/name=union-operator",
             "--tail=400", "--all-containers", f"--since={since}"],
            capture_output=True, text=True, check=False,
        )
        lines = (out.stdout + out.stderr).splitlines()
        keep = [ln for ln in lines if any(k in ln.lower() for k in _CHECKER_KEYS)]
        print(f"[ci] hsample:   operator checker/heartbeat lines (last {n} of {len(keep)} in {since}):", flush=True)
        for ln in keep[-n:]:
            print(f"[ci] hsample:     {ln[:240]}", flush=True)
        if not keep:
            print("[ci] hsample:     (none matched — see raw debug dump)", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[ci] hsample:   checker tail failed: {exc}", flush=True)


async def _sample_health_async(
    cluster_name: str,
    control_plane_url: str,
    api_key: str,
    duration: int,
    interval: int,
) -> None:
    """Continuously time-align CP cluster health with operator CPU/CFS-throttle.

    Runs as a background process spanning the probe + smoke suite (the window
    where the flap actually bites, AFTER the wait-healthy gate passes). Each tick
    prints one line: elapsed, CP health, operator/proxy cores-used + throttle%,
    whole-node cores. On a health TRANSITION it also dumps the operator's recent
    per-checker/heartbeat verdicts — so the log shows, at the flap edge, whether
    the operator was being CPU-throttled and which health signal dropped first.

    This is the decisive diagnostic for resource-starvation vs CP-side cause.
    Best-effort and always exits 0 — it must never gate or fail the job.
    """
    from flyteplugins.union.remote import Cluster  # type: ignore

    ns = os.environ.get("UNION_NS", "union")
    # CP-health sampling needs the flyte client; CPU/throttle sampling does NOT.
    # If init fails, keep sampling CPU (the decisive starvation signal) anyway.
    cp_ok = True
    try:
        await _init_client(control_plane_url, api_key, project=cluster_name)
    except Exception as e:  # noqa: BLE001
        cp_ok = False
        print(f"[ci] hsample: flyte init failed ({str(e)[:120]}) — CPU-only sampling", flush=True)
    node = _first_node_name()
    print(
        f"[ci] hsample: starting health+CPU sampler — cluster={cluster_name} "
        f"node={node} ns={ns} duration={duration}s interval={interval}s",
        flush=True,
    )
    # One-time: operator container CPU request/limit for context.
    try:
        op = _pod_for_label(ns, "app.kubernetes.io/name=union-operator")
        if op:
            j = subprocess.run(
                ["kubectl", "get", "pod", "-n", ns, op, "-o",
                 "jsonpath={range .spec.containers[*]}{.name}:req={.resources.requests.cpu}"
                 "/lim={.resources.limits.cpu} {end}"],
                capture_output=True, text=True, check=False,
            )
            print(f"[ci] hsample: operator pod={op} container CPU req/lim: {j.stdout.strip() or '(unset)'}", flush=True)
    except Exception:  # noqa: BLE001
        pass

    deadline = time.time() + duration
    prev_counters: dict = {}
    prev_t = 0.0
    prev_health: typing.Optional[str] = None
    t0 = time.time()
    while time.time() < deadline:
        tick = time.time()
        # CP-reported health (the signal that gates build/run routing).
        health = "?"
        if cp_ok:
            try:
                c = await Cluster.get.aio(name=cluster_name)  # type: ignore
                health = f"{c.health}"
            except Exception as e:  # noqa: BLE001
                health = f"err({str(e)[:40]})"
        else:
            health = "no-cp-client"
        # CPU / CFS-throttle for operator + proxy + whole node.
        cpu_str = "cpu=n/a"
        cur_counters: dict = {}
        if node:
            try:
                cur_counters = _cadvisor_counters(_cadvisor_scrape(node))
                dt = tick - prev_t if prev_t else 0.0
                targets = _resolve_targets(ns)
                parts = []
                for label, (tns, tpod) in targets.items():
                    parts.append(f"{label}={_fmt_cpu_delta(prev_counters, cur_counters, tns, tpod, dt)}")
                node_key = ("", "<node>", "")
                if node_key in cur_counters and node_key in prev_counters and dt > 0:
                    ncores = (cur_counters[node_key]["usage"] - prev_counters[node_key]["usage"]) / dt
                    parts.append(f"node={ncores:.2f}c")
                cpu_str = " ".join(parts) if parts else "cpu=warming"
            except Exception as e:  # noqa: BLE001
                cpu_str = f"cpu=err({str(e)[:40]})"
        elapsed = int(tick - t0)
        flap = prev_health is not None and health != prev_health
        marker = " *** HEALTH TRANSITION" if flap else ""
        print(f"[ci] hsample +{elapsed:>4}s cp={health} {cpu_str}{marker}", flush=True)
        if flap:
            # At the flap edge, surface which operator signal went bad.
            _operator_checker_tail(ns, since=f"{max(interval * 2, 20)}s")
        prev_counters = cur_counters or prev_counters
        prev_t = tick
        prev_health = health
        await asyncio.sleep(interval)
    print(f"[ci] hsample: sampler finished after {int(time.time() - t0)}s", flush=True)


def cmd_sample_health(args: argparse.Namespace) -> None:
    try:
        asyncio.run(
            _sample_health_async(
                _env("CLUSTER_NAME"),
                _env("CONTROL_PLANE_URL"),
                _env("UNION_API_KEY", required=False),
                args.duration,
                args.interval,
            )
        )
    except Exception as exc:  # noqa: BLE001 — diagnostic must never fail the job
        print(f"[ci] hsample: sampler wrapper error (ignored): {exc}", flush=True)


def _dump_operator_connection() -> None:
    """Dump the operator's control-plane connection / heartbeat health.

    The image build runs ON the dataplane (its build run is created in this
    cluster's project/domain and executes on the in-cluster buildkit). The
    control plane only routes a build run here while it considers the cluster
    healthy, and that health is driven by the operator's heartbeat + tunnel
    connection to the CP. On a build failure this shows whether the operator→CP
    connection was actually alive at that moment, or whether the CP had stopped
    seeing this dataplane as a healthy build target. Best-effort; never raises.
    """
    import shutil
    ns = os.environ.get("UNION_NS", "union")
    if not shutil.which("kubectl"):
        print("[ci] probe: kubectl not on PATH — skipping operator connection dump", flush=True)
        return
    _KEYS = (
        "heartbeat", "tunnel", "connect", "register", "health", "control plane",
        "controlplane", "control-plane", "unavailable", "disconnect", "reconnect",
        "capabilit", "\"level\":\"error\"", "\"level\":\"warning\"",
    )
    for label, selector in (
        ("operator",       "app.kubernetes.io/name=union-operator"),
        ("operator-proxy", "app.kubernetes.io/name=operator-proxy"),
    ):
        try:
            out = subprocess.run(
                ["kubectl", "logs", "-n", ns, "-l", selector, "--tail=600", "--all-containers"],
                capture_output=True, text=True, check=False,
            )
            lines = (out.stdout + out.stderr).splitlines()
            keep = [ln for ln in lines if any(k in ln.lower() for k in _KEYS)]
            print(f"[ci] probe: --- {label} CP-connection/health lines (last 25 of {len(keep)}) ---", flush=True)
            if not keep:
                print("[ci] probe:   (no matching lines — check raw debug dump)", flush=True)
            for ln in keep[-25:]:
                print(f"[ci] probe:   {ln[:240]}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"[ci] probe: {label} log dump failed: {exc}", flush=True)

    # Per-checker verdicts + a one-shot operator CPU/CFS-throttle snapshot: was
    # the operator CPU-starved (throttled) at failure time, and which health
    # signal dropped? This is the resource-starvation-vs-CP-side discriminator.
    _operator_checker_tail(ns, since="60s", n=20)
    node = _first_node_name()
    if node:
        try:
            s1 = _cadvisor_counters(_cadvisor_scrape(node))
            time.sleep(2.0)
            s2 = _cadvisor_counters(_cadvisor_scrape(node))
            targets = _resolve_targets(ns)
            parts = [f"{lbl}={_fmt_cpu_delta(s1, s2, tns, tpod, 2.0)}" for lbl, (tns, tpod) in targets.items()]
            nk = ("", "<node>", "")
            if nk in s1 and nk in s2:
                parts.append(f"node={(s2[nk]['usage'] - s1[nk]['usage']) / 2.0:.2f}c")
            print(f"[ci] probe: operator CPU/throttle @failure — {' '.join(parts)}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"[ci] probe: CPU/throttle snapshot failed: {exc}", flush=True)


async def _probe_image_builder_async(
    control_plane_url: str,
    api_key: str,
    cluster_name: str,
    org: str,
) -> None:
    """Isolate the remote image-build submission and dump the REAL error.

    Every failing CI run since ~2026-06-22 fails exactly the four smoke tests
    that build a custom image (verify_image_builder/_image_cache/_reusable/_app)
    with the generic "Flyte system is currently unavailable", while the two that
    reuse the prebuilt base image (verify_logs/_io) pass — and it reproduces on
    identical flyte / flyteplugins-union versions that previously passed. That
    points at the control-plane image-builder backend, not this repo. This probe
    exercises ONLY the build path and prints the underlying connectrpc status so
    the cause (UNAVAILABLE vs UNAUTHENTICATED vs NOT_FOUND vs misroute) is
    unambiguous. It is best-effort and always exits 0 — it never gates the job.
    """
    import flyte  # type: ignore

    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    print(
        f"[ci] probe-image-builder: client initialised — "
        f"endpoint={control_plane_url} project={cluster_name} org={org}",
        flush=True,
    )

    # 1) Where does the SDK route image builds? (project/domain/task name)
    try:
        from flyte._internal.imagebuild import remote_builder as _rb  # type: ignore
        print(
            "[ci] probe: image-builder route — "
            f"project={_rb.IMAGE_TASK_PROJECT!r} domain={_rb.IMAGE_TASK_DOMAIN!r} "
            f"task={_rb.IMAGE_TASK_NAME!r} "
            f"(FLYTE_IMAGEBUILDER_TASK_DOMAIN={os.environ.get('FLYTE_IMAGEBUILDER_TASK_DOMAIN', '(unset)')})",
            flush=True,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[ci] probe: could not import remote_builder constants: {exc}", flush=True)
        _rb = None  # type: ignore

    # 2) Does the system build-image task resolve? Distinguishes "builder not
    #    enabled" (RemoteTaskNotFoundError) from "builder enabled but the run
    #    submission is rejected" (the case we actually see).
    if _rb is not None:
        try:
            from flyte import remote  # type: ignore
            # Task.get returns a LazyEntity synchronously; the real network
            # lookup happens in .fetch() (awaitable).
            lazy = remote.Task.get(  # type: ignore
                name=_rb.IMAGE_TASK_NAME,
                project=_rb.IMAGE_TASK_PROJECT,
                domain=_rb.IMAGE_TASK_DOMAIN,
                auto_version="latest",
            )
            t = await lazy.fetch.aio()  # type: ignore
            print(f"[ci] probe: system build-image task RESOLVED — {t}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print("[ci] probe: system build-image task lookup FAILED:", flush=True)
            _diag_exc(exc, "probe/Task.get(build-image)")

    # 3) Attempt an isolated remote image build and dump the underlying error.
    #    A fresh minimal env forces a real build (the failing builds are never
    #    cached). Retry on TRANSIENT failures — the build run is created in this
    #    cluster's project/domain, so for the first ~2 min after the cluster goes
    #    healthy the workflow-service cluster cache / capabilities haven't
    #    propagated and CreateRun returns NOT_FOUND "no clusters found for action"
    #    (the same lag the smoke suite's 120s wait + _submit_with_retry absorb).
    #    Retrying those means a FAILED verdict here reflects a *real* persistent
    #    build problem (e.g. the 06-24 UNAVAILABLE), not propagation lag.
    img = flyte.Image.from_debian_base().with_pip_packages("requests==2.32.3")
    probe_env = flyte.TaskEnvironment(name=f"ci-probe-{cluster_name}", image=img)
    _MAX, _DELAY = 10, 30
    for attempt in range(1, _MAX + 1):
        try:
            print(f"[ci] probe: submitting isolated remote image build (attempt {attempt}/{_MAX}) …", flush=True)
            cache = await flyte.build_images.aio(probe_env)  # type: ignore
            print(f"[ci] probe: image build SUCCEEDED — cache={cache}", flush=True)
            break
        except Exception as exc:  # noqa: BLE001
            if attempt < _MAX and _is_transient(exc):
                print(
                    f"[ci] probe: build attempt {attempt}/{_MAX} transient "
                    f"({str(exc)[:140]}) — retrying in {_DELAY}s …",
                    flush=True,
                )
                await asyncio.sleep(_DELAY)
                continue
            # Persistent and/or non-transient (e.g. UNAVAILABLE) → the real signal.
            print(f"[ci] probe: image build FAILED after {attempt} attempt(s):", flush=True)
            _diag_exc(exc, "probe/build_images")
            # The build runs on the dataplane, so a failed submission is most often
            # the CP no longer routing build runs here. Capture BOTH sides of that
            # decision: the CP's view of this cluster's health (Cluster.get) and the
            # operator's CP-connection/heartbeat state — to tell "CP dropped us as a
            # healthy build target" apart from a true CP-backend/transport error.
            print("[ci] probe: --- CP-side cluster health at build-failure time ---", flush=True)
            await _dump_cluster_state(cluster_name)
            _dump_operator_connection()
            break


def cmd_probe_image_builder(args: argparse.Namespace) -> None:
    try:
        asyncio.run(
            _probe_image_builder_async(
                _env("CONTROL_PLANE_URL"),
                _env("UNION_API_KEY", required=False),
                _env("CLUSTER_NAME"),
                _env("ORG_NAME", required=False),
            )
        )
    except Exception as exc:  # noqa: BLE001 — diagnostic step must never fail the job
        print(f"[ci] probe-image-builder: probe wrapper error (ignored): {exc}", flush=True)
        _diag_exc(exc, "probe-image-builder/wrapper")


# ── main ────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description="Dataplane CI helper")
    sub = p.add_subparsers(dest="command", required=True)

    p_prov = sub.add_parser("provision")
    p_prov.add_argument(
        "--values-out", default="values-provision.yaml",
        help="Destination for the generated values file",
    )

    p_wait = sub.add_parser("wait-healthy")
    p_wait.add_argument("--timeout", type=int, default=300)
    p_wait.add_argument(
        "--stable", type=int, default=1,
        help="Require N consecutive healthy observations (use >1 after an "
             "operator restart when CP health flaps).",
    )
    p_wait.add_argument(
        "--require-pools", action="store_true",
        help="Also require a non-empty pool list (health='healthy' alone can "
             "have pools=[] while the [default] pool config is still syncing). "
             "Use only AFTER setup-routing has assigned a pool.",
    )

    sub.add_parser("setup-routing")
    sub.add_parser("eager-api-key")
    sub.add_parser("smoke-test")
    sub.add_parser("run-smoke-suite")
    sub.add_parser("probe-image-builder")
    p_sample = sub.add_parser("sample-health")
    p_sample.add_argument(
        "--duration", type=int, default=1200,
        help="How long to sample (s). Span the probe + smoke suite window.",
    )
    p_sample.add_argument(
        "--interval", type=int, default=8,
        help="Seconds between CP-health + CPU/throttle samples.",
    )
    sub.add_parser("teardown")

    args = p.parse_args()
    {
        "provision":        cmd_provision,
        "wait-healthy":     cmd_wait_healthy,
        "setup-routing":    cmd_setup_routing,
        "eager-api-key":    cmd_eager_api_key,
        "smoke-test":       cmd_smoke_test,
        "run-smoke-suite":  cmd_run_smoke_suite,
        "probe-image-builder": cmd_probe_image_builder,
        "sample-health":    cmd_sample_health,
        "teardown":         cmd_teardown,
    }[args.command](args)


if __name__ == "__main__":
    main()
