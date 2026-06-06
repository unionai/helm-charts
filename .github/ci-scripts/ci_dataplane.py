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
setup-routing   Create clusterpool, assign cluster, create project, route all
                domains → ensures this PR's test run only hits our cluster.
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

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)-7s %(name)s - %(message)s",
)
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
    """Create clusterpool + assignment + project + per-domain routes.

    Each PR gets its own cluster pool (named == cluster_name), a matching
    project, and routing rules that pin development/staging/production
    executions exclusively to this cluster.  Parallel PRs never share a
    cluster pool and therefore can't land on each other's dataplane.
    """
    from flyte.remote import Project  # type: ignore

    pool_name  = cluster_name
    project_id = cluster_name

    # 1. Create cluster pool
    spec_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
    spec_tmp.write(f"clusterPool:\n  id:\n    name: {pool_name}\n")
    spec_tmp.close()
    print(f"[ci] setup-routing: creating cluster pool {pool_name}", flush=True)
    try:
        rc, out = _run_uctl(
            "uctl", "create", "clusterpool",
            "--clusterPoolSpecFile", spec_tmp.name, "--org", org,
        )
        if rc != 0 and "already" not in out.lower():
            raise RuntimeError(
                f"uctl create clusterpool exited {rc} (pool={pool_name})\n{out}"
            )
    finally:
        os.unlink(spec_tmp.name)

    # 2. Assign cluster to pool — critical: without this the pool is empty and
    # every task submission returns "no clusters found".
    print(f"[ci] setup-routing: assigning {cluster_name} → pool {pool_name}", flush=True)
    rc, out = _run_uctl(
        "uctl", "create", "clusterpoolassignment",
        "--poolName", pool_name, "--clusterName", cluster_name, "--org", org,
    )
    if rc != 0 and "already" not in out.lower():
        raise RuntimeError(
            f"uctl create clusterpoolassignment exited {rc} "
            f"(cluster={cluster_name}, pool={pool_name})\n{out}"
        )

    # 3. Create project (idempotent)
    await _init_client(control_plane_url, api_key, project=project_id, org=org)
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

    # 4. Route all three domains
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
                print(
                    f"[ci] setup-routing: WARNING routing {domain} failed (rc={rc}): {out[:200]}",
                    flush=True,
                )
        finally:
            os.unlink(attr_tmp.name)

    print(
        f"[ci] setup-routing: done — project '{project_id}' routes to pool '{pool_name}' "
        f"(dev/staging/prod)",
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
        run.sync()
        raise RuntimeError(
            f"{label}: run {run.name} did not reach a terminal state within "
            f"{timeout:.0f}s (last phase={run.phase})"
        )
    run.sync()
    p = _phase_name(run)
    if p != "succeeded":
        raise RuntimeError(f"{label}: run {run.name} ended in phase={run.phase}")


def _ensure_workspace_in_path() -> None:
    """Add GITHUB_WORKSPACE (repo root) to sys.path so ci_smoke_task is importable."""
    workspace = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
    if workspace not in sys.path:
        sys.path.insert(0, workspace)


_SUBMIT_MAX_ATTEMPTS = 15
_SUBMIT_RETRY_DELAY  = 30


async def _submit_with_retry(task_fn, label: str, **kwargs):  # type: ignore[no-untyped-def]
    """Submit a task, retrying on 'no clusters found' (pool / capabilities propagation lag).

    Control-plane routing cache can take O(minutes) to reflect newly-published
    K8s Plugin Config.  15 attempts × 30 s = 7.5 min max retry window.
    """
    import flyte  # type: ignore
    run = None
    for attempt in range(1, _SUBMIT_MAX_ATTEMPTS + 1):
        try:
            run = await flyte.run.aio(task_fn, **kwargs)  # type: ignore
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
    """Fan out square() calls over a ReusePolicy environment (replicas=2, concurrency=1)."""
    from ci_smoke_task import reuse_driver  # type: ignore  # noqa: E402
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    n = 4  # fixed for reproducibility
    print(f"[ci] verify_reusable: submitting reuse_driver(n={n})", flush=True)
    run = await _submit_with_retry(reuse_driver, "verify_reusable", n=n)
    await _assert_succeeded(run, "verify_reusable")
    print(f"[ci] verify_reusable: PASSED (run={run.name})", flush=True)


async def _verify_app_async(
    control_plane_url: str, api_key: str, cluster_name: str, org: str
) -> None:
    """Deploy a FastAPI app, hit internal endpoints, deactivate."""
    from ci_app_task import app_deploy_test  # type: ignore  # noqa: E402
    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)
    print("[ci] verify_app: submitting app_deploy_test", flush=True)
    run = await _submit_with_retry(app_deploy_test, "verify_app")
    print(f"[ci] verify_app: run={run.name}  url={run.url}", flush=True)
    await _assert_succeeded(run, "verify_app")
    print(f"[ci] verify_app: PASSED (run={run.name})", flush=True)


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

    # Step 1: hello run (needed for verify_logs + verify_io).
    import uuid
    from ci_smoke_task import hello as _hello  # type: ignore

    nonce = str(uuid.uuid4())
    print(f"[ci] smoke-suite: submitting hello (nonce={nonce})", flush=True)
    hello_run = await _submit_with_retry(_hello, "hello", nonce=nonce)
    print(f"[ci] smoke-suite: hello run={hello_run.name}  url={hello_run.url}", flush=True)
    await _assert_succeeded(hello_run, "hello")
    print(f"[ci] smoke-suite: hello PASSED", flush=True)
    run_name = hello_run.name

    # Step 2: all verify tests in parallel.
    tests: list[tuple[str, "asyncio.coroutine"]] = [  # type: ignore
        ("verify_logs",          _verify_logs_async(run_name, cluster_name)),
        ("verify_io",            _verify_io_async(run_name)),
        ("verify_image_builder", _verify_image_builder_async(control_plane_url, api_key, cluster_name, org)),
        ("verify_image_cache",   _verify_image_cache_async(control_plane_url, api_key, cluster_name, org)),
        ("verify_reusable",      _verify_reusable_async(control_plane_url, api_key, cluster_name, org)),
        ("verify_app",           _verify_app_async(control_plane_url, api_key, cluster_name, org)),
    ]
    names = [n for n, _ in tests]
    outcomes = await asyncio.gather(*(c for _, c in tests), return_exceptions=True)

    results: list[tuple[str, bool, str]] = []
    for name, outcome in zip(names, outcomes):
        if isinstance(outcome, Exception):
            results.append((name, False, str(outcome)[:300]))
            print(f"[ci] smoke-suite: FAILED  {name}: {outcome}", flush=True)
        else:
            results.append((name, True, ""))

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
    print(f"[ci] teardown: deregistering cluster {cluster_name}", flush=True)
    _run_uctl("uctl", "delete", "cluster", cluster_name)
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
