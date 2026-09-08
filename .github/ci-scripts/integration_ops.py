#!/usr/bin/env python3
"""
Control-plane operations for every integration-check leg — pure flyte 2.x SDK
(flyte / flyteplugins.union.remote), no uctl. Operator credentials are seeded /
provisioned out-of-band (terraform), so there is no runtime provisioning here.
Runs inside GitHub Actions; every command writes its key output to $GITHUB_OUTPUT
so subsequent steps can consume it.

Commands
--------
ensure-active         Undelete + activate the cluster if it is soft-deleted, so
                      the operator can re-register. Run before the chart install.
wait-healthy          Poll Cluster.get until enabled+healthy. Emit ORG_NAME.
setup-routing         Create the cluster pool + project and route this run's
                      cluster + queue to them.
register-build-image  (selfhosted) Register the build-image task in
                      system/production and route the system project to this DP.
teardown              Leave the stable cluster registered (no-op; see below).

The functional tests (verify_simple + verify_*) live in tests/functional/ as pytest; this
module provides the cluster operations they run against.

Environment
-----------
CLUSTER_NAME            required — the dataplane's cluster name (pool==project==name)
CONTROL_PLANE_URL       required — https://<control-plane-host>
FLYTE_API_KEY           required — base64("<host>:<clientId>:<clientSecret>:<org>")
ORG_NAME                optional — resolved automatically by wait-healthy
GITHUB_OUTPUT           set by Actions runner; commands write key=value here
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
import time

_REPO = os.environ.get("GITHUB_WORKSPACE") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..")
)
sys.path.insert(0, os.path.join(_REPO, "tests", "functional"))
import flyte_ops  # noqa: E402 - shared flyte helpers (tests/functional/)

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)-7s %(name)s - %(message)s",
)


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


# ── wait-healthy ─────────────────────────────────────────────────────────────


async def _wait_healthy_async(
    cluster_name: str,
    control_plane_url: str,
    api_key: str,
    timeout: int,
) -> str:
    from flyteplugins.union.remote import Cluster  # type: ignore

    await flyte_ops.init_client(control_plane_url, api_key, project=cluster_name)
    print(
        f"[ci] wait-healthy: polling Cluster.get(name={cluster_name}) (timeout={timeout}s)",
        flush=True,
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            cluster = await Cluster.get.aio(name=cluster_name)  # type: ignore
            state = cluster.state
            health = cluster.health
            org = cluster.organization or ""
            print(f"[ci]   state={state} health={health} org={org}", flush=True)
            if state == "enabled" and health == "healthy":
                print(f"[ci] wait-healthy: HEALTHY (org={org})", flush=True)
                return org
        except Exception as e:
            print(f"[ci]   Cluster.get error: {e}", flush=True)
        await asyncio.sleep(15)
    raise RuntimeError(f"Cluster {cluster_name} did not become enabled+healthy within {timeout}s")


def cmd_wait_healthy(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key = _env("FLYTE_API_KEY", required=False)
    org = asyncio.run(_wait_healthy_async(cluster_name, control_plane_url, api_key, args.timeout))
    _gha_output("org_name", org)


# ── ensure-active (self-heal a soft-deleted cluster) ─────────────────────────


async def _ensure_active_async(cluster_name: str, control_plane_url: str, api_key: str) -> None:
    from flyteplugins.union.remote import Cluster  # type: ignore

    await flyte_ops.init_client(control_plane_url, api_key, project=cluster_name)

    # The control plane's DeleteCluster is a SOFT delete: a deleted cluster keeps
    # its name reserved in a `deleted` state, disappears from Cluster.get, and
    # rejects heartbeats + status updates until it is undeleted. Our cluster name
    # is STABLE and seeded (reused every run), so a single teardown that deleted
    # it leaves every later run unable to (re-)register: the operator never mints
    # its Cloudflare tunnel token, the operator-proxy cloudflared sidecar
    # crash-loops on the unset token, and the chart install times out. Recover it
    # before the operator heartbeats. listall(deleted=True) is the only way to
    # see a soft-deleted cluster.
    is_deleted = False
    async for c in Cluster.listall.aio(deleted=True):  # type: ignore
        if c.name == cluster_name:
            is_deleted = True
            break
    if not is_deleted:
        print(f"[ci] ensure-active: {cluster_name} not soft-deleted — nothing to do.", flush=True)
        return

    # undelete restores it in the `drained` state; activate returns it to `active`
    # so it accepts the operator's heartbeat again.
    print(f"[ci] ensure-active: {cluster_name} is soft-deleted — undelete + activate", flush=True)
    await Cluster.undelete.aio(name=cluster_name)  # type: ignore
    await Cluster.activate.aio(name=cluster_name)  # type: ignore
    print(f"[ci] ensure-active: {cluster_name} restored to active.", flush=True)


def cmd_ensure_active(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key = _env("FLYTE_API_KEY", required=False)
    asyncio.run(_ensure_active_async(cluster_name, control_plane_url, api_key))


# ── setup-routing ─────────────────────────────────────────────────────────────


async def _setup_routing_async(
    cluster_name: str,
    org: str,
    control_plane_url: str,
    api_key: str,
) -> str:
    """Create the cluster pool + project and pin this run's cluster + queue to them.

    Queue-based routing model (flyteplugins-union #37): a heartbeat-registered
    cluster is pool-less until CreateCluster assigns it a pool (one-shot — the pool
    can't change afterwards) and auto-creates a queue named after the cluster. Runs
    and the dataproxy's upload-location selection both route via the project's
    run.default_queue → queue → pool → cluster (SDK equivalent of
    configure_routing.py). pool == cluster == queue == project name, so parallel
    legs never cross-land.
    """
    from flyte.remote import Project, Settings  # type: ignore
    from flyteplugins.union.remote import Cluster, ClusterPool, Queue  # type: ignore

    pool_name = cluster_name
    project_id = cluster_name

    await flyte_ops.init_client(control_plane_url, api_key, project=project_id, org=org)

    # 1. Create cluster pool. The config kwargs are placeholders — for a
    # single-cluster pool the CP overwrites them from the operator's status upsert.
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

    # 2. Assign the cluster to the pool (also auto-creates the implicit queue).
    # Without it every submission returns "no clusters found". The operator's
    # heartbeat registers the cluster (pool-less) before this runs and the
    # assignment is one-shot, so on a re-run against a perennial CI cluster the
    # cluster is already in its pool. Read its current pool and only assign when
    # unassigned; a cluster already in a DIFFERENT pool is a name collision with
    # a previous run.
    print(f"[ci] setup-routing: assigning {cluster_name} → pool {pool_name}", flush=True)
    existing = await Cluster.get.aio(name=cluster_name)  # type: ignore
    if existing.pool == pool_name:
        print(
            f"[ci] setup-routing: cluster '{cluster_name}' already in pool '{pool_name}'",
            flush=True,
        )
    elif existing.pool:
        raise RuntimeError(
            f"cluster '{cluster_name}' is already in pool '{existing.pool}', not '{pool_name}' "
            f"(name collision with a previous run)"
        )
    else:
        await Cluster.create.aio(cluster_name, cluster_pool_name=pool_name)  # type: ignore
        print(
            f"[ci] setup-routing: cluster '{cluster_name}' assigned to pool '{pool_name}'",
            flush=True,
        )

    # 3. Sanity-check the implicit queue; create it if an older CP didn't.
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
            run_concurrency=0,  # 0 == no limit (matches the implicit queue)
            action_concurrency=0,
            depth=0,
            clusters=[cluster_name],
            cluster_pool=pool_name,
        )

    # 4. Create project (idempotent) and ensure it's ACTIVE — a prior run may have
    # archived it, and an archived project can't schedule runs.
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

    # 5. Route project → this run's queue (all domains) via run.default_queue —
    # drives both run scheduling and the dataproxy's upload-location selection.
    for domain in ("development", "staging", "production"):
        s = await Settings.get_settings_for_edit.aio(project=project_id, domain=domain)  # type: ignore
        await s.update_settings.aio(overrides={"run.default_queue": cluster_name})  # type: ignore
        print(
            f"[ci] setup-routing: routed {project_id}/{domain} → queue {cluster_name}", flush=True
        )

    print(
        f"[ci] setup-routing: done — project '{project_id}', pool '{pool_name}' "
        f"(object store {os.environ.get('RUSTFS_BUCKET', 'union-data')!r}), "
        f"queue '{cluster_name}' — run.default_queue set for dev/staging/prod",
        flush=True,
    )
    return project_id


def cmd_setup_routing(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    org = _env("ORG_NAME")
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key = _env("FLYTE_API_KEY", required=False)
    project = asyncio.run(_setup_routing_async(cluster_name, org, control_plane_url, api_key))
    _gha_output("project_id", project)


# ── register-build-image (selfhosted only) ───────────────────────────────────


async def _register_build_image_async(
    control_plane_url: str,
    api_key: str,
    org: str,
    cluster_name: str,
    app_version: str,
    image_prefix: str,
    task_file: str,
) -> None:
    """Register the `build-image` ContainerTask in system/production and route the
    system project to this dataplane, so the remote image builder works on a
    SELFHOSTED CP. The managed tenant (selfmanaged legs) ships both pre-provisioned;
    a self-hosted CP does neither, so verify_image_* fail "remote image builder is
    not enabled". Needs both: the task registered in system/production, AND system/*
    routed to this run's queue so the build task can schedule on the lone DP.
    """
    import flyte  # type: ignore
    from flyte.remote import Project, Settings  # type: ignore

    # build_image_task.py reads these at import time (raises if unset).
    os.environ["UNION_IMAGE_NAME_PREFIX"] = image_prefix
    os.environ["APP_VERSION"] = app_version

    # 1. Ensure the `system` project exists + is active (build task registers there).
    await flyte_ops.init_client(control_plane_url, api_key, project="system", org=org)
    try:
        await Project.create.aio(  # type: ignore
            id="system",
            name="system",
            description="system project — build-image task registry",
        )
        print("[ci] register-build-image: created 'system' project", flush=True)
    except Exception as e:  # noqa: BLE001 — idempotent
        print(f"[ci] register-build-image: system project exists: {e}", flush=True)
    try:
        await Project.update.aio(id="system", state="active")  # type: ignore
    except Exception:  # noqa: BLE001
        pass

    # 2. Route system/* → this DP's queue so the build task can schedule.
    for domain in ("development", "staging", "production"):
        s = await Settings.get_settings_for_edit.aio(project="system", domain=domain)  # type: ignore
        await s.update_settings.aio(overrides={"run.default_queue": cluster_name})  # type: ignore
        print(
            f"[ci] register-build-image: routed system/{domain} → queue {cluster_name}", flush=True
        )

    # 3. Deploy the build-image task env into system/production, pinned to appVersion.
    await flyte_ops.init_client(
        control_plane_url, api_key, project="system", org=org, domain="production"
    )
    import importlib.util

    spec = importlib.util.spec_from_file_location("build_image_task", task_file)
    mod = importlib.util.module_from_spec(spec)  # type: ignore
    spec.loader.exec_module(mod)  # type: ignore
    await flyte.deploy.aio(mod.build_image_task_env, version=app_version)  # type: ignore
    print(
        f"[ci] register-build-image: registered build-image in system/production "
        f"(version={app_version}, prefix={image_prefix})",
        flush=True,
    )


def cmd_register_build_image(args: argparse.Namespace) -> None:
    control_plane_url = _env("CONTROL_PLANE_URL")
    api_key = _env("FLYTE_API_KEY", required=False)
    org = _env("ORG_NAME")
    cluster_name = _env("CLUSTER_NAME")
    app_version = _env("APP_VERSION")
    image_prefix = _env("UNION_IMAGE_NAME_PREFIX")
    asyncio.run(
        _register_build_image_async(
            control_plane_url,
            api_key,
            org,
            cluster_name,
            app_version,
            image_prefix,
            args.task_file,
        )
    )


# ── teardown ────────────────────────────────────────────────────────────────


def cmd_teardown(args: argparse.Namespace) -> None:
    cluster_name = _env("CLUSTER_NAME")
    # Deliberately DO NOT deregister the cluster. It is STABLE and seeded — reused
    # every run, exactly like the pool/queue/project (which teardown already left
    # in place). DeleteCluster is a SOFT delete: it reserves the name in a
    # `deleted` state that the next run's re-registration does not revive
    # ("undelete the cluster first"), so deleting here would brick every later run
    # (operator can't mint its tunnel token → operator-proxy cloudflared sidecar
    # crash-loops → chart install times out). The next run's operator simply
    # re-heartbeats the existing cluster; `ensure-active` recovers it if anything
    # soft-deletes it out of band.
    print(
        f"[ci] teardown: leaving cluster {cluster_name} registered "
        "(stable/seeded, reused across runs — soft-delete would brick the next run).",
        flush=True,
    )


# ── main ────────────────────────────────────────────────────────────────────


def main() -> None:
    p = argparse.ArgumentParser(description="Dataplane CI helper (flyte 2.x SDK; no uctl)")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("ensure-active")

    p_wait = sub.add_parser("wait-healthy")
    p_wait.add_argument("--timeout", type=int, default=300)

    sub.add_parser("setup-routing")
    p_reg = sub.add_parser("register-build-image")
    p_reg.add_argument(
        "--task-file",
        default="charts/controlplane/files/build_image_task.py",
        help="Path to the build-image ContainerTask definition to register.",
    )
    sub.add_parser("teardown")

    args = p.parse_args()
    {
        "ensure-active": cmd_ensure_active,
        "wait-healthy": cmd_wait_healthy,
        "setup-routing": cmd_setup_routing,
        "register-build-image": cmd_register_build_image,
        "teardown": cmd_teardown,
    }[args.command](args)


if __name__ == "__main__":
    main()
