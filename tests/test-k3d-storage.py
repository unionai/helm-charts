"""Exercise the real storage phase with isolated command fixtures, never Kubernetes."""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = "RELEASE.2025-08-13T08-35-41Z"
DIGESTS = {
    "linux-amd64": "01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891",
    "linux-arm64": "14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c",
    "darwin-amd64": "2862c79cce11b09be9a8911a279b2e9465bebf74b9f01abca9c348a0d795f0cb",
    "darwin-arm64": "a877fd0c183409da9f20f9d6e1811987298bbbca1aa03428eebdffba79fb9445",
}

COMMAND = r"""
import json
import os
import signal
import sys
import time
from pathlib import Path

state = Path(os.environ["STORAGE_FIXTURE"])
config = json.loads((state / "config.json").read_text())
name = Path(sys.argv[0]).name
if name == ".mc":
    name = "mc"
args = sys.argv[1:]
record = (json.dumps({"command": name, "args": args}) + "\n").encode()
fd = os.open(state / "calls.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.write(fd, record)
os.close(fd)

if name == "uname":
    print(config["os"] if args == ["-s"] else config["arch"])
elif name == "sleep":
    time.sleep(0.01)
elif name == "kubectl":
    if args[0] == "port-forward":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        (state / "port-forward.pid").write_text(str(os.getpid()))
        if config.get("port_forward_exit"):
            sys.exit(1)
        while True:
            signal.pause()
    elif args[0] == "create":
        print("apiVersion: v1\nkind: Namespace")
    elif args[0] == "apply":
        if args[-1] == "-":
            sys.stdin.read()
    elif args[0] != "wait":
        raise AssertionError(args)
elif name == "curl":
    url = next(arg for arg in args if arg.startswith("http"))
    if url == "http://localhost:9000/health/live":
        for _ in range(100):
            if (state / "port-forward.pid").exists():
                break
            time.sleep(0.01)
        counter = state / "health-count"
        count = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(count))
        if config.get("port_forward_exit"):
            time.sleep(0.05)
            sys.exit(7)
        sys.exit(0 if count >= config.get("ready_after", 1) else 22)
    assert url.startswith("https://github.com/minio/mc/releases/download/"), url
    target = Path(args[args.index("--output") + 1])
    if config.get("download_failure"):
        target.write_text("partial download")
        print("curl: (22) HTTP 410", file=sys.stderr)
        sys.exit(22)
    target.write_text(Path(__file__).read_text())
elif name in ("sha256sum", "shasum"):
    assert Path(args[-1]).exists()
    if name == "shasum":
        assert args[:2] == ["-a", "256"], args
    digest = "0" * 64 if config.get("checksum_failure") else config["digest"]
    print(digest + "  " + args[-1])
elif name == "mc":
    if args[:2] == ["alias", "set"]:
        if config.get("alias_failure"):
            sys.exit(11)
    elif args[0] == "mb":
        if config.get("bucket_failure"):
            sys.exit(12)
        bucket = state / "bucket"
        if bucket.exists() and "--ignore-existing" not in args:
            sys.exit(13)
        bucket.touch()
    else:
        raise AssertionError(args)
else:
    raise AssertionError(name)
"""


class StorageTests(unittest.TestCase):
    def run_storage(self, *, installed=False, system="Linux", arch="x86_64", **options):
        temporary = tempfile.TemporaryDirectory(prefix="k3d-storage-")
        self.addCleanup(temporary.cleanup)
        state = Path(temporary.name)
        repo = state / "repo"
        script = repo / "tools/dataplane/k3d/up.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "tools/dataplane/k3d/up.sh", script)
        previous = repo / ".mc"
        previous.write_text("previous executable\n")
        previous.chmod(0o755)
        platform = system.lower() + "-" + ("amd64" if arch == "x86_64" else "arm64")
        config = {
            "os": system,
            "arch": arch,
            "digest": DIGESTS.get(platform),
            **options,
        }
        (state / "config.json").write_text(json.dumps(config))
        if options.get("existing_bucket"):
            (state / "bucket").touch()
        commands = state / "bin"
        commands.mkdir()
        fixture = state / "command.py"
        fixture.write_text(f"#!{sys.executable}\n" + COMMAND)
        fixture.chmod(0o755)
        mocked = ["kubectl", "curl", "uname", "sleep"]
        mocked.append("shasum" if system == "Darwin" else "sha256sum")
        if installed:
            mocked.append("mc")
        for name in mocked:
            (commands / name).symlink_to(fixture)
        # Only these filesystem utilities can escape the command fixtures.
        for name in ("dirname", "mktemp", "chmod", "mv", "rm"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable)
            (commands / name).symlink_to(executable)

        def stop_fixture():
            pid_file = state / "port-forward.pid"
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass

        self.addCleanup(stop_fixture)
        result = subprocess.run(
            ["/bin/bash", str(script), "storage"],
            env={
                **os.environ,
                "PATH": str(commands),
                "STORAGE_FIXTURE": str(state),
                "RUSTFS_NS": "rustfs",
                "RUSTFS_ACCESS_KEY": "rustfsadmin",
                "RUSTFS_SECRET_KEY": "rustfsadmin",
                "RUSTFS_BUCKET": "union-data",
            },
            text=True,
            capture_output=True,
            check=False,
            timeout=15,
        )
        calls = [json.loads(line) for line in (state / "calls.jsonl").read_text().splitlines()]
        pid_file = state / "port-forward.pid"
        self.assertTrue(pid_file.exists(), result.stderr)
        with self.assertRaises(ProcessLookupError, msg="port-forward survived storage exit"):
            os.kill(int(pid_file.read_text()), 0)
        self.assertEqual([], list(repo.glob(".mc.*")), "unfinished download was not removed")
        if result.returncode:
            self.assertNotIn("bucket-ok", result.stdout)
        else:
            self.assertIn("bucket-ok", result.stdout)
        return result, calls, previous.read_text()

    @staticmethod
    def downloads(calls):
        return [
            arg
            for call in calls
            if call["command"] == "curl"
            for arg in call["args"]
            if arg.startswith("https://")
        ]

    @staticmethod
    def mc_calls(calls):
        return [call["args"] for call in calls if call["command"] == "mc"]

    def test_installed_client_and_existing_bucket(self):
        result, calls, previous = self.run_storage(installed=True, existing_bucket=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.downloads(calls))
        self.assertEqual("previous executable\n", previous)
        self.assertEqual(
            [
                [
                    "alias",
                    "set",
                    "k3dstore",
                    "http://localhost:9000",
                    "rustfsadmin",
                    "rustfsadmin",
                ],
                ["mb", "--ignore-existing", "k3dstore/union-data"],
            ],
            self.mc_calls(calls),
        )

    def test_native_downloads(self):
        for system, arch, platform in (
            ("Linux", "x86_64", "linux-amd64"),
            ("Linux", "aarch64", "linux-arm64"),
            ("Linux", "arm64", "linux-arm64"),
            ("Darwin", "x86_64", "darwin-amd64"),
            ("Darwin", "arm64", "darwin-arm64"),
        ):
            with self.subTest(system=system, arch=arch):
                result, calls, executable = self.run_storage(system=system, arch=arch)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(
                    [
                        f"https://github.com/minio/mc/releases/download/{RELEASE}/mc.{platform}.{RELEASE}"
                    ],
                    self.downloads(calls),
                )
                self.assertTrue(executable.startswith("#!"))
                self.assertEqual(2, len(self.mc_calls(calls)))

    def test_unsupported_platform(self):
        result, calls, previous = self.run_storage(system="FreeBSD")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("install mc on PATH", result.stderr)
        self.assertEqual([], self.downloads(calls))
        self.assertEqual([], self.mc_calls(calls))
        self.assertEqual("previous executable\n", previous)

    def test_download_failure_preserves_previous_client(self):
        result, calls, previous = self.run_storage(download_failure=True)
        self.assertEqual(22, result.returncode, result.stderr)
        self.assertIn("HTTP 410", result.stderr)
        self.assertEqual(1, len(self.downloads(calls)))
        self.assertEqual([], self.mc_calls(calls))
        self.assertEqual("previous executable\n", previous)

    def test_checksum_mismatch_preserves_previous_client(self):
        result, calls, previous = self.run_storage(checksum_failure=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual([], self.mc_calls(calls))
        self.assertEqual("previous executable\n", previous)

    def test_delayed_readiness(self):
        result, calls, _ = self.run_storage(installed=True, ready_after=3)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(3, sum(call["command"] == "curl" for call in calls))

    def test_readiness_timeout(self):
        result, calls, previous = self.run_storage(ready_after=100)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("did not become ready", result.stderr)
        self.assertEqual(20, sum(call["command"] == "curl" for call in calls))
        self.assertEqual([], self.downloads(calls))
        self.assertEqual([], self.mc_calls(calls))
        self.assertEqual("previous executable\n", previous)

    def test_port_forward_exit(self):
        result, calls, _ = self.run_storage(port_forward_exit=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("port-forward exited", result.stderr)
        self.assertEqual([], self.downloads(calls))
        self.assertEqual([], self.mc_calls(calls))

    def test_bucket_creation_failure(self):
        result, calls, _ = self.run_storage(installed=True, bucket_failure=True)
        self.assertEqual(12, result.returncode)
        self.assertEqual(2, len(self.mc_calls(calls)))

    def test_alias_setup_failure(self):
        result, calls, _ = self.run_storage(installed=True, alias_failure=True)
        self.assertEqual(11, result.returncode)
        self.assertEqual(1, len(self.mc_calls(calls)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
