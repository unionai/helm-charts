"""Union Volumes through the mount broker — the verify_volume scenario's tasks.

Its own module (like each scenario task) so only this pod's image carries
flyteplugins-union + fuse3. Two phases in one env: ``volume_write`` seals a
volume, ``volume_read`` mounts that sealed version read-only and verifies it;
``volume_roundtrip`` runs them as separate actions so the read is a genuinely
different pod adopting a different broker channel.

Both phases assert **broker mode**: ``allow_volumes()`` gives the pod no
privileges, so the only way the mount can succeed is by adopting the channel the
broker premounted — the requested mount path becomes a symlink into
``$UVOL_CHANNEL_DIR``. A chart that installs but does not actually serve the CSI
driver fails here, not at helm install.
"""

from __future__ import annotations

import hashlib
import os
import re

import flyte  # type: ignore
import flyte.errors  # type: ignore
from flyteplugins.union.io import ROVolume, RWVolume, allow_volumes  # type: ignore

_env_suffix = os.environ.get("ENV_SUFFIX") or os.environ.get("CLUSTER_NAME", "ci-dev")
_CACHE_BUST = os.environ.get("FUNCTIONAL_IMAGE_CACHE_BUST", "")

_N_SMALL = 64
_LARGE_MIB = 32

_volume_env = flyte.TaskEnvironment(
    name=f"ci-volume-{_env_suffix}",
    image=flyte.Image.from_debian_base()
    # redis-server: only used behind a custom S3 endpoint (k3d) — see _store().
    .with_apt_packages("fuse3", "redis-server", "redis-tools")
    .with_pip_packages("flyteplugins-union")
    .with_env_vars({"CI_CACHE_BUST": _CACHE_BUST}),
    # The client keeps a read/write buffer in memory; 2Gi is the floor at which
    # it is comfortable, and still fits next to buildkit on the 4-vCPU k3d node.
    resources=flyte.Resources(cpu="500m", memory="2Gi"),
    pod_template=allow_volumes(),
    cache="disable",
    # The driver action re-imports this module in its own pod: the env name must
    # resolve identically there, or the nested calls miss the image cache.
    env_vars={
        "CLUSTER_NAME": os.environ.get("CLUSTER_NAME", "ci-dev"),
        "ENV_SUFFIX": _env_suffix,
        "FUNCTIONAL_IMAGE_CACHE_BUST": _CACHE_BUST,
        "CI_VOLUME_STORE": os.environ.get("CI_VOLUME_STORE", ""),
    },
)


def _store() -> str | None:
    """Metadata store for the volume this run creates; None = the plugin default (badger).

    Behind a custom S3-compatible endpoint (k3d's RustFS) the default badger
    store cannot take a writable mount today: it needs a writer-session slice
    domain, whose claim is written with obstore against the ``s3://`` bucket
    form, while the JuiceFS client needs the path-style ``http://<endpoint>/…``
    form — the plugin offers no bucket URI that satisfies both (flyteplugins-
    union gap; self-managed dataplanes on MinIO/RustFS/Ceph hit the same wall).
    The redis store needs no domain claim, so that leg uses it; the broker
    path under test is identical either way. Drop this once the plugin resolves
    the endpoint for the client itself.
    """
    if os.environ.get("CI_VOLUME_STORE"):
        return os.environ["CI_VOLUME_STORE"]
    return "redis" if os.environ.get("FLYTE_AWS_ENDPOINT") else None


def _export_store_creds() -> bool:
    """Give the JuiceFS client the object-store credentials propeller injected.

    Behind a custom S3-compatible endpoint (k3d's RustFS) the store's keys arrive
    as ``FLYTE_AWS_*``; the client reads plain ``AWS_*``. Needed by *every* task
    that mounts — the reader's chunk GETs fail with EIO without it, not just the
    writer's uploads. On IRSA/workload-identity legs there is nothing to map.
    """
    mapped = False
    for k in ("ACCESS_KEY_ID", "SECRET_ACCESS_KEY"):
        v = os.environ.get(f"FLYTE_AWS_{k}")
        if v:
            os.environ.setdefault(f"AWS_{k}", v)
            mapped = True
    return mapped


def _bucket() -> tuple[str, str | None]:
    """(bucket URI for this run's volumes, region) from the task's raw-data path.

    Behind a custom S3-compatible endpoint (k3d's RustFS: ``FLYTE_AWS_ENDPOINT``
    set), JuiceFS wants the path-style ``http(s)://<endpoint>/<bucket>`` form.
    """
    rdp = flyte.ctx().raw_data_path
    raw = getattr(rdp, "path", None) or str(rdp)
    m = re.search(r"([A-Za-z][A-Za-z0-9+.-]*)://([^'\"\s)]+)", raw)
    if not m:
        raise RuntimeError(f"cannot parse raw_data_path {raw!r}")
    scheme, bucket = m.group(1), m.group(2).split("/", 1)[0]
    endpoint = os.environ.get("FLYTE_AWS_ENDPOINT")
    if scheme == "s3" and endpoint:
        return f"{endpoint.rstrip('/')}/{bucket}/ci-volume", None
    return f"{scheme}://{bucket}/ci-volume", os.environ.get("AWS_REGION") or os.environ.get(
        "AWS_DEFAULT_REGION"
    )


def _broker_mode(mount_path: str) -> dict:
    """Prove the mount went through the broker, not a privileged in-pod mount.

    In broker mode ``mount()`` resolves to the channel the broker premounted —
    a directory under ``$UVOL_CHANNEL_DIR`` (``/uvol/mnt`` for the main channel)
    — and leaves a symlink at the requested path. A privileged in-pod mount
    resolves to ``~/flyte-volume/<name>`` instead, which can never satisfy this.
    """
    chan = os.environ.get("UVOL_CHANNEL_DIR", "")
    real = os.path.realpath(mount_path)
    ok = bool(chan) and real.startswith(os.path.realpath(chan) + os.sep)
    return {"broker_mode": ok, "channel_dir": chan, "mount_path": mount_path, "resolved": real}


def _channel_preflight() -> dict:
    """What the pod was actually handed by the broker, for the failure message."""
    chan = os.environ.get("UVOL_CHANNEL_DIR", "")
    info = {"channel_dir": chan, "exists": bool(chan) and os.path.isdir(chan)}
    if info["exists"]:
        try:
            info["entries"] = sorted(os.listdir(chan))[:12]
        except OSError as e:
            info["entries"] = f"{type(e).__name__}: {e}"
        info["broker_sock"] = os.path.exists(os.path.join(chan, "ctl", "broker.sock"))
    return info


async def _mount_or_fail(vol, phase: str):
    """mount(), but a failure ends the run with a readable message instead of a retry storm.

    The plugin wraps mount/format failures as recoverable *system* errors, so
    propeller would retry a deterministic failure (no broker socket, bad bucket,
    OOM) until the scenario's timeout aborts the run with no message at all.
    """
    pre = _channel_preflight()
    if not pre.get("broker_sock"):
        raise flyte.errors.NonRecoverableError(
            f"{phase}: no broker socket in the pod's channel volume (is the uvol mount broker "
            f"installed, enabled and registered with kubelet on this node?): {pre}"
        )
    try:
        return str(await vol.mount(timeout=240))
    except Exception as e:  # noqa: BLE001 — turn any mount failure into a terminal, readable one
        raise flyte.errors.NonRecoverableError(
            f"{phase}: mount failed: {type(e).__name__}: {str(e)[:1500]} | channel={pre}"
        ) from e


def _mount_evidence(mnt: str) -> dict:
    """What a failed I/O on the mount can still tell us, for the error message.

    JuiceFS serves ``.stats`` (counters, incl. object-request errors) and
    ``.config`` (the effective mount config) as virtual files under the mount;
    the pod's client log is not reachable from the CI runner, so this is the
    only evidence that makes it into the run's error.
    """
    ev: dict = {
        "kernel": os.uname().release,
        "passthrough_env": os.environ.get("UNION_JUICEFS_PASSTHROUGH"),
    }
    try:
        with open(f"{mnt}/.stats") as f:
            lines = [ln.strip() for ln in f]
        ev["stats"] = [
            ln for ln in lines if ("error" in ln or "fail" in ln) and not ln.endswith(" 0")
        ][:20]
    except OSError as e:
        ev["stats"] = f"{type(e).__name__}: {e}"
    try:
        with open(f"{mnt}/.config") as f:
            cfg = f.read()
        keys = (
            "Passthrough",
            "Bucket",
            "Storage",
            "CacheDir",
            "BufferSize",
            "Writeback",
            "MaxUploads",
            "ReadOnly",
        )
        ev["config"] = [ln.strip() for ln in cfg.splitlines() if any(k in ln for k in keys)][:24]
    except OSError as e:
        ev["config"] = f"{type(e).__name__}: {e}"
    return ev


def _io_or_fail(phase: str, mnt: str, fn):
    """Run one I/O phase; an OSError on the mount ends the run with evidence attached."""
    try:
        return fn()
    except OSError as e:
        raise flyte.errors.NonRecoverableError(
            f"{phase}: I/O on the mount failed: [Errno {e.errno}] {e.strerror}: {e.filename} | "
            f"evidence={_mount_evidence(mnt)}"
        ) from e


def _payload(i: int, nonce: str) -> bytes:
    return hashlib.sha256(f"{nonce}:{i}".encode()).digest() * 512  # 16 KiB


@_volume_env.task(retries=2)
async def volume_write(nonce: str) -> ROVolume:
    """Create a volume, write a known payload, seal it."""
    _export_store_creds()
    bucket, region = _bucket()
    # Unique per *attempt*, not per run: `juicefs format` refuses a non-empty
    # prefix, so a retry that reused the first attempt's name could never pass.
    vol = RWVolume.new(
        name=f"ci-vol-{nonce[:8]}-{os.urandom(3).hex()}",
        bucket=bucket,
        region=region,
        metadata_store_type=_store(),
    )
    print(
        f"[ci] volume_write: bucket={bucket} region={region} channel={_channel_preflight()}",
        flush=True,
    )
    mnt = await _mount_or_fail(vol, "volume_write")
    mode = _broker_mode(mnt)
    assert mode["broker_mode"], f"write mount is not in broker mode: {mode}"

    def _write() -> None:
        os.makedirs(f"{mnt}/small", exist_ok=True)
        for i in range(_N_SMALL):
            with open(f"{mnt}/small/{i:04d}.bin", "wb") as f:
                f.write(_payload(i, nonce))
        h = hashlib.sha256()
        with open(f"{mnt}/large.bin", "wb") as f:
            for i in range(_LARGE_MIB):
                chunk = hashlib.sha256(f"{nonce}:large:{i}".encode()).digest() * (1 << 15)  # 1 MiB
                h.update(chunk)
                f.write(chunk)
        with open(f"{mnt}/MANIFEST", "w") as f:
            f.write(f"{nonce}\n{_N_SMALL}\n{h.hexdigest()}\n")

    _io_or_fail("volume_write", mnt, _write)
    print(f"[ci] volume_write: {mode}", flush=True)
    try:
        return await vol.finalize(message=f"ci verify_volume {nonce}")
    except Exception as e:  # noqa: BLE001 — the flush is where an object-store write failure surfaces
        raise flyte.errors.NonRecoverableError(
            f"volume_write: finalize failed: {type(e).__name__}: {str(e)[:1200]} | evidence={_mount_evidence(mnt)}"
        ) from e


@_volume_env.task(retries=2)
async def volume_read(vol: ROVolume, nonce: str) -> dict:
    """Mount the sealed version read-only in a fresh pod and verify every byte."""
    _export_store_creds()
    mnt = await _mount_or_fail(vol, "volume_read")
    mode = _broker_mode(mnt)
    assert mode["broker_mode"], f"read mount is not in broker mode: {mode}"

    def _read() -> tuple:
        got_nonce, n, large_hex = open(f"{mnt}/MANIFEST").read().split()
        assert got_nonce == nonce, f"MANIFEST nonce {got_nonce!r} != {nonce!r}"
        files_ok = sum(
            1
            for i in range(int(n))
            if open(f"{mnt}/small/{i:04d}.bin", "rb").read() == _payload(i, nonce)
        )
        h = hashlib.sha256()
        with open(f"{mnt}/large.bin", "rb") as f:
            while chunk := f.read(8 << 20):
                h.update(chunk)
        return n, files_ok, h.hexdigest() == large_hex

    n, files_ok, large_ok = _io_or_fail("volume_read", mnt, _read)
    assert files_ok == int(n) and large_ok, (
        f"read-back mismatch: {files_ok}/{n} small ok, large_ok={large_ok}"
    )
    report = {
        **mode,
        "files_ok": files_ok,
        "large_ok": large_ok,
        "inodes": vol.inode_count,
        "bytes": vol.used_bytes,
    }
    print(f"[ci] volume_read: {report}", flush=True)
    return report


@_volume_env.task
async def volume_roundtrip(nonce: str) -> dict:
    """Driver: write in one action, read in another (different pod, different channel)."""
    sealed = await volume_write(nonce)
    read = await volume_read(sealed, nonce)
    write = {"broker_mode": True, "files": _N_SMALL, "locator": sealed.locator}
    return {"write": write, "read": read}
