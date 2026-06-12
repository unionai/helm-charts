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
        # transient infra/registry blip from a real product failure. Falls back
        # to the bare phase if error_info isn't populated.
        detail = ""
        try:
            act = run.pb2.action
            if act.HasField("error_info"):
                detail = f": {act.error_info.kind}: {act.error_info.message}"
        except Exception:  # noqa: BLE001 — diagnostics must never mask the phase error
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
    for attempt in range(1, _SUBMIT_MAX_ATTEMPTS + 1):
        try:
            run = await flyte.with_runcontext(queue=queue).run.aio(task_fn, **kwargs)  # type: ignore
            break
        except Exception as exc:
            msg = str(exc).lower()
            if "no clusters found" in msg or "no cluster" in msg:
                if attempt < _SUBMIT_MAX_ATTEMPTS:
                    print(
                        f"[ci] {label}: attempt {attempt}/{_SUBMIT_MAX_ATTEMPTS} — "
                        f"no clusters found, retrying in {_SUBMIT_RETRY_DELAY}s …",
                        flush=True,
                    )
                    await asyncio.sleep(_SUBMIT_RETRY_DELAY)
            else:
                raise
    if run is None:
        raise RuntimeError(
            f"{label}: submission failed after {_SUBMIT_MAX_ATTEMPTS} attempts "
            f"(no clusters found)"
        )
    return run


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

    sub.add_parser("setup-routing")
    sub.add_parser("eager-api-key")
    sub.add_parser("smoke-test")
    sub.add_parser("run-smoke-suite")
    sub.add_parser("teardown")

    args = p.parse_args()
    {
        "provision":        cmd_provision,
        "wait-healthy":     cmd_wait_healthy,
        "setup-routing":    cmd_setup_routing,
        "eager-api-key":    cmd_eager_api_key,
        "smoke-test":       cmd_smoke_test,
        "run-smoke-suite":  cmd_run_smoke_suite,
        "teardown":         cmd_teardown,
    }[args.command](args)


if __name__ == "__main__":
    main()
