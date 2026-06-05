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

    work_dir = tempfile.mkdtemp(prefix="union-ci-provision-")
    print(f"[ci] provision: working in {work_dir}", flush=True)

    # provision-dataplane-resources writes a values file to cwd
    result = subprocess.run(
        ["uctl", "selfserve", "provision-dataplane-resources",
         "--clusterName", cluster_name, "--provider", "metal"],
        cwd=work_dir, capture_output=True, text=True,
        env={**os.environ, **_uctl_extra_env()},
    )
    output = result.stdout + result.stderr
    print(output, flush=True)
    if result.returncode != 0:
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
    _uenv = {**os.environ, **_uctl_extra_env()}
    subprocess.run(
        ["uctl", "create", "clusterpool",
         "--clusterPoolSpecFile", spec_tmp.name, "--org", org],
        check=False, env=_uenv,
    )
    os.unlink(spec_tmp.name)

    # 2. Assign cluster to pool
    print(f"[ci] setup-routing: assigning {cluster_name} → pool {pool_name}", flush=True)
    subprocess.run(
        ["uctl", "create", "clusterpoolassignment",
         "--poolName", pool_name, "--clusterName", cluster_name, "--org", org],
        check=False, env=_uenv,
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
        subprocess.run(
            ["uctl", "update", "cluster-pool-attributes", "--force",
             "--attrFile", attr_tmp.name, "--org", org],
            check=False, env=_uenv,
        )
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
    org_name = _env("ORG_NAME", required=False) or ""
    # --org is a global uctl flag (matches provision step 6 instructions)
    org_flag = ["--org", org_name] if org_name else []
    result = subprocess.run(
        ["uctl"] + org_flag + ["create", "apikey", "--keyName", "EAGER_API_KEY"],
        capture_output=True, text=True,
        env={**os.environ, **_uctl_extra_env()},
    )
    output = result.stdout + result.stderr
    print(output, flush=True)
    if result.returncode != 0:
        # "already exists" is normal on reruns; uctl still propagates the key.
        low = output.lower()
        if "already exists" in low or "alreadyexists" in low:
            print("[ci] eager-api-key: key already exists (re-propagated).", flush=True)
        else:
            sys.exit(f"[ci] ERROR: uctl create apikey failed (exit {result.returncode})")
    else:
        print("[ci] eager-api-key: EAGER_API_KEY created.", flush=True)


# ── smoke-test ──────────────────────────────────────────────────────────────

async def _smoke_test_async(
    control_plane_url: str,
    api_key: str,
    cluster_name: str,
    org: str,
) -> str:
    import uuid
    import flyte  # type: ignore

    # Import the task from ci_smoke_task.py (repo root).
    # The task must live in a module with a clean Python name — this file's path
    # (.github/ci-scripts/ci_dataplane.py) produces '.github.ci-scripts.ci_dataplane'
    # which Python rejects as a relative import and is also invalid (hyphen).
    workspace = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
    if workspace not in sys.path:
        sys.path.insert(0, workspace)
    from ci_smoke_task import hello as _hello  # type: ignore  # noqa: E402

    await _init_client(control_plane_url, api_key, project=cluster_name, org=org)

    nonce = str(uuid.uuid4())
    print(f"[ci] smoke-test: submitting hello (nonce={nonce})", flush=True)
    run = await flyte.run.aio(_hello, nonce=nonce)  # type: ignore
    print(f"[ci] smoke-test: run={run.name}  url={run.url}", flush=True)

    await run.wait.aio(wait_for="terminal")  # type: ignore
    run.sync()
    phase = str(run.phase).rsplit(".", 1)[-1].lower()
    if phase != "succeeded":
        raise RuntimeError(f"smoke-test: run {run.name} ended in phase={run.phase}")

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


# ── teardown ────────────────────────────────────────────────────────────────

def cmd_teardown(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    print(f"[ci] teardown: deregistering cluster {cluster_name}", flush=True)
    subprocess.run(
        ["uctl", "delete", "cluster", cluster_name],
        check=False, env={**os.environ, **_uctl_extra_env()},
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
    sub.add_parser("teardown")

    args = p.parse_args()
    {
        "provision":      cmd_provision,
        "wait-healthy":   cmd_wait_healthy,
        "setup-routing":  cmd_setup_routing,
        "eager-api-key":  cmd_eager_api_key,
        "smoke-test":     cmd_smoke_test,
        "teardown":       cmd_teardown,
    }[args.command](args)


if __name__ == "__main__":
    main()
