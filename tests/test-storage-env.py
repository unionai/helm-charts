#!/usr/bin/env python3
"""Secret env mode must fail closed and keep static credentials out of config."""
import os
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get("HELM_BIN", "helm")


def render(*settings):
    args = [HELM, "template", "dp", str(ROOT / "charts/dataplane"), "-n", "union",
            "--kube-version", "1.32.0", "-f", str(ROOT / "charts/dataplane/examples/values-test-certs.yaml"),
            "-f", str(ROOT / "tests/values/dataplane.namespace-single.yaml")]
    for setting in settings:
        args.extend(["--set", setting])
    return subprocess.run(args, capture_output=True, text=True)


class StorageEnv(unittest.TestCase):
    def test_invalid_mode_and_missing_secret_fail_closed(self):
        for settings, message in [
            (["storage.credentialsSecretRef.mode=env"], "requires a Secret name"),
            (["storage.credentialsSecretRef.mode=evn", "storage.credentialsSecretRef.name=r2"], "must be lookup or env"),
            (["storage.credentialsSecretRef.mode=env", "storage.credentialsSecretRef.name=r2", "storage.credentialsSecretRef.namespace=other"], "release namespace"),
            (["storage.credentialsSecretRef.mode=env", "storage.credentialsSecretRef.name=r2", "low_privilege=false", "namespaces.enabled=true"], "single-namespace mode"),
        ]:
            with self.subTest(settings=settings):
                result = render(*settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_env_config_contains_references_not_plaintext(self):
        result = render("storage.credentialsSecretRef.mode=env", "storage.credentialsSecretRef.name=r2")
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        for doc in docs:
            if doc["kind"] == "ConfigMap":
                self.assertNotIn("test123", yaml.safe_dump(doc))
        template = next(d for d in docs if d["kind"] == "PodTemplate")
        env = {e["name"]: e for e in template["template"]["spec"]["containers"][0]["env"]}
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "FLYTE_AWS_ACCESS_KEY_ID", "FLYTE_AWS_SECRET_ACCESS_KEY"):
            self.assertEqual(env[name]["valueFrom"]["secretKeyRef"]["name"], "r2")
        for doc in docs:
            if doc["kind"] == "ConfigMap" and "storage.yaml" in doc.get("data", {}):
                cfg = yaml.safe_load(doc["data"]["storage.yaml"])["storage"]["stow"]["config"]
                self.assertEqual(cfg["auth_type"], "iam")
                self.assertNotIn("access_key_id", cfg)
                self.assertNotIn("secret_key", cfg)

    def test_default_still_renders_legacy_accesskey(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("test123", result.stdout)


if __name__ == "__main__":
    unittest.main()
