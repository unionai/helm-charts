#!/usr/bin/env python3
"""External Knative releases must coexist even with the same Helm release name."""
import os
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get("HELM_BIN", "helm")


def render(namespace, external=True, release="dataplane"):
    result = subprocess.run([
        HELM, "template", release, str(ROOT / "charts/dataplane"), "-n", namespace,
        "--kube-version", "1.32.0", "-f", str(ROOT / "charts/dataplane/examples/values-test-certs.yaml"),
        "-f", str(ROOT / "tests/values/dataplane.apps-external.yaml"),
        "--set", f"apps.external.enabled={str(external).lower()}",
    ], check=True, capture_output=True, text=True)
    return [d for d in yaml.safe_load_all(result.stdout) if d]


def rbac(docs):
    return [d for d in docs if d["kind"] in ("ClusterRole", "ClusterRoleBinding")
            and d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "net-kourier"]


class ExternalRBAC(unittest.TestCase):
    def test_same_release_name_different_namespaces(self):
        first, second = rbac(render("acme")), rbac(render("globex"))
        self.assertEqual(len(first), 2)
        self.assertEqual(len(second), 2)
        self.assertFalse({d["metadata"]["name"] for d in first} & {d["metadata"]["name"] for d in second})
        for docs, ns in ((first, "acme"), (second, "globex")):
            role = next(d for d in docs if d["kind"] == "ClusterRole")
            binding = next(d for d in docs if d["kind"] == "ClusterRoleBinding")
            self.assertEqual(binding["roleRef"]["name"], role["metadata"]["name"])
            self.assertEqual(binding["subjects"][0]["namespace"], ns)

    def test_long_names_do_not_collide_after_truncation(self):
        a = rbac(render("n" * 60 + "a", release="r" * 53))[0]["metadata"]["name"]
        b = rbac(render("n" * 60 + "b", release="r" * 53))[0]["metadata"]["name"]
        self.assertLessEqual(len(a), 63)
        self.assertLessEqual(len(b), 63)
        self.assertNotEqual(a, b)

    def test_existing_default_name_is_unchanged(self):
        for doc in rbac(render("acme", external=False)):
            self.assertEqual(doc["metadata"]["name"], "net-kourier")


if __name__ == "__main__":
    unittest.main()
