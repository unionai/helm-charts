#!/usr/bin/env python3
"""Shared flyte v2 SDK helpers for the integration CI — client init, submission
retry, and terminal-state assertion. Imported by both the ops driver
(.github/ci-scripts/integration_ops.py) and the pytest functional suite
(tests/functional/). Pure flyte / flyteplugins.union.remote; no uctl.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

# Quiet the HTTP client stack: at DEBUG it floods the log and echoes auth headers.
for _noisy in ("httpx", "httpcore", "urllib3", "hpack", "h2"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)


def ensure_workspace_in_path() -> None:
    """Add GITHUB_WORKSPACE (repo root) to sys.path so the ci_*_task modules import."""
    workspace = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
    if workspace not in sys.path:
        sys.path.insert(0, workspace)


async def init_client(
    control_plane_url: str,
    api_key: str,
    project: str,
    org: str = "",
    domain: str = "development",
) -> None:
    import flyte

    # Always pass an explicit org — else flyte.init derives it from the endpoint's
    # first hostname label, wrong for namespaced selfhosted CP hosts (→ denied
    # "OnbehalfOf"). ORG_NAME is set per leg by the creds-resolution step.
    org = org or os.environ.get("ORG_NAME", "")
    if not control_plane_url.startswith(("https://", "http://")):
        control_plane_url = "https://" + control_plane_url
    kwargs: dict = {
        "endpoint": control_plane_url,
        "project": project,
        "domain": domain,
        # Build images on the cluster's buildkit, not the runner (no Docker there).
        "image_builder": "remote",
    }
    if org:
        kwargs["org"] = org
    if api_key:
        kwargs["api_key"] = api_key
    await flyte.init.aio(**kwargs)  # type: ignore[attr-defined]


def _phase_name(run) -> str:  # type: ignore[no-untyped-def]
    return str(run.phase).rsplit(".", 1)[-1].lower()


_ASSERT_TIMEOUT = 600  # seconds — bound per-test wait so a stuck run fails


async def assert_succeeded(run, label: str, timeout: float = _ASSERT_TIMEOUT) -> None:  # type: ignore[no-untyped-def]
    try:
        await asyncio.wait_for(run.wait.aio(wait_for="terminal"), timeout=timeout)  # type: ignore
    except asyncio.TimeoutError:
        # Abort on the CP — wait_for only stopped us waiting; the run would else
        # keep executing and holding cluster resources.
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
        # Surface the run's failure reason into the exception so the retry
        # classifier can tell a transient blip from a real failure. error_info is
        # on ActionDetails; run.pb2.action.error_info is often empty, so try
        # details first, then pb2.action, then the bare phase.
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


_SUBMIT_MAX_ATTEMPTS = 40
_SUBMIT_RETRY_DELAY = 30

# Submission-time errors that are transient backend states, not real failures.
# Two families:
#   * routing/capability propagation on a fresh cluster ("no clusters found",
#     'cluster "<name>" not found' — the enabled-clusters cache is empty/lagging)
#   * a briefly-unhealthy dataplane: EKS Auto Mode / Karpenter can evict the
#     singleton operator/proxy (the DP<->CP tunnel) between the health gate and
#     submission, so the CP reports the pool unhealthy for ~30-60s until the pod
#     reschedules ("unhealthy", "could not select a cluster", "failed to get
#     proxy"). Riding these out avoids false negatives from node churn.
_TRANSIENT_SUBMIT_MARKERS = (
    "no clusters found",
    "no cluster",
    "could not select a cluster",
    "unhealthy",
    "failed to get proxy",
    "failed to get data proxy",
)


def _is_transient_submit_error(msg: str) -> bool:
    m = msg.lower()
    if any(marker in m for marker in _TRANSIENT_SUBMIT_MARKERS):
        return True
    return "cluster" in m and "not found" in m


async def submit_with_retry(task_fn, label: str, **kwargs):  # type: ignore[no-untyped-def]
    """Submit a task, retrying while the backend is in a transient state.

    Runs pin to this run's queue (== CLUSTER_NAME) so they only land on this
    dataplane. Retries both propagation lag ("no clusters found"; CP routing can
    take O(minutes) — observed >12 min on shared staging) and a briefly-unhealthy
    dataplane ("could not select a cluster" / "failed to get proxy" from mid-run
    node churn) — see `_is_transient_submit_error`. 40 × 30s = 20 min window. A
    deterministic error fails immediately; distinct from the scenario reruns
    pytest-rerunfailures handles for post-submit transient failures.
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
            if _is_transient_submit_error(last_err):
                if attempt < _SUBMIT_MAX_ATTEMPTS:
                    print(
                        f"[ci] {label}: attempt {attempt}/{_SUBMIT_MAX_ATTEMPTS} — "
                        f"{last_err[:160]} — retrying in {_SUBMIT_RETRY_DELAY}s …",
                        flush=True,
                    )
                    # Every 5th attempt, dump the cluster's CP state so a long
                    # retry stretch shows why (e.g. flapped out of ENABLED).
                    if attempt % 5 == 0 and queue:
                        await dump_cluster_state(queue)
                    await asyncio.sleep(_SUBMIT_RETRY_DELAY)
            else:
                raise
    if run is None:
        raise RuntimeError(
            f"{label}: submission failed after {_SUBMIT_MAX_ATTEMPTS} attempts "
            f"(last error: {last_err[:300]})"
        )
    return run


async def dump_cluster_state(cluster_name: str) -> None:
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


async def dump_app_state(app_name: str) -> None:
    """Print an app's spec.cluster_pool + full status from the control plane
    (best-effort diagnostic for verify_app failures; contains no credentials)."""
    try:
        import flyte.remote  # type: ignore

        app = await flyte.remote.App.get.aio(name=app_name)
        pb = app.pb2
        print(f"[ci] app {app_name!r} CP state:", flush=True)
        print(f"[ci]   spec.cluster_pool       = {pb.spec.cluster_pool!r}", flush=True)
        print(f"[ci]   status.assigned_cluster = {pb.status.assigned_cluster!r}", flush=True)
        for line in str(pb.status).splitlines():
            print(f"[ci]   status| {line}", flush=True)
    except Exception as exc:  # noqa: BLE001 — diagnostics must not mask the real error
        print(f"[ci] could not fetch app state: {exc}", flush=True)
