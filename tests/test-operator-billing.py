#!/usr/bin/env python3
"""Exercise billing defaults with Helm and a read-only local Kubernetes API fixture."""

import base64
import gzip
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/dataplane"
HELM = os.environ.get("HELM_BIN", "helm")
MODELS = ("None", "Legacy", "Shadow", "ResourceUsage")
LEGACY_DEFAULT = '{{ ternary "ResourceUsage" "None" .Values.operator.enableTunnelService }}'
NAMESPACE = "billing-test"


class KubernetesAPI(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        status = 200
        if path == "/version":
            body = {"major": "1", "minor": "32", "gitVersion": "v1.32.0"}
        elif path == "/api":
            body = {"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]}
        elif path == "/apis":
            body = {"kind": "APIGroupList", "apiVersion": "v1", "groups": []}
        elif path == "/api/v1":
            body = {
                "kind": "APIResourceList",
                "apiVersion": "v1",
                "groupVersion": "v1",
                "resources": [
                    {
                        "name": name,
                        "singularName": kind.lower(),
                        "namespaced": True,
                        "kind": kind,
                        "verbs": ["get", "list"],
                    }
                    for name, kind in [("configmaps", "ConfigMap"), ("secrets", "Secret")]
                ],
            }
        elif path == f"/api/v1/namespaces/{NAMESPACE}/secrets":
            body = {"kind": "SecretList", "apiVersion": "v1", "items": [self.server.release]}
        elif path == f"/api/v1/namespaces/{NAMESPACE}/secrets/sh.helm.release.v1.billing.v1":
            body = self.server.release
        elif path == f"/api/v1/namespaces/{NAMESPACE}/configmaps/union-operator":
            if self.server.forbidden:
                status, body = (
                    403,
                    {
                        "kind": "Status",
                        "apiVersion": "v1",
                        "status": "Failure",
                        "reason": "Forbidden",
                        "message": "ConfigMap read forbidden",
                        "code": 403,
                    },
                )
            else:
                body = self.server.configmap
                if body is None:
                    status = 404
        else:
            status, body = 404, None
        if body is None:
            body = {
                "kind": "Status",
                "apiVersion": "v1",
                "status": "Failure",
                "reason": "NotFound",
                "code": 404,
            }
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        self.server.writes.append(self.path)
        self.send_error(405, "The billing fixture is read-only")

    do_PUT = do_PATCH = do_DELETE = do_POST


class BillingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="operator-billing-")
        cls.directory = Path(cls.temp.name)
        cls.chart = cls.directory / "chart"
        (cls.chart / "templates").mkdir(parents=True)
        shutil.copy(CHART / "templates/operator/_billing.tpl", cls.chart / "templates/_billing.tpl")
        (cls.chart / "Chart.yaml").write_text(
            "apiVersion: v2\nname: billing-test\nversion: 2.0.0\n"
        )
        cls.defaults = {
            "operator": {"enableTunnelService": True},
            "config": {
                "operator": {
                    "billing": yaml.safe_load((CHART / "values.yaml").read_text())["config"][
                        "operator"
                    ]["billing"]
                }
            },
        }
        (cls.chart / "values.yaml").write_text(yaml.safe_dump(cls.defaults))
        (
            cls.chart / "templates/configmap.yaml"
        ).write_text("""{{- define "union-operator.fullname" -}}union-operator{{- end -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: union-operator
data:
  config.yaml: |
    operator:
      enableTunnelService: {{ .Values.operator.enableTunnelService }}
      billing:
        {{- include "operator.billing.config" . | nindent 8 }}
""")
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), KubernetesAPI)
        cls.server.writes = []
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.kubeconfig = cls.directory / "kubeconfig"
        cls.kubeconfig.write_text(
            yaml.safe_dump(
                {
                    "apiVersion": "v1",
                    "kind": "Config",
                    "current-context": "fixture",
                    "clusters": [
                        {
                            "name": "fixture",
                            "cluster": {"server": f"http://127.0.0.1:{cls.server.server_port}"},
                        }
                    ],
                    "users": [{"name": "fixture", "user": {}}],
                    "contexts": [
                        {
                            "name": "fixture",
                            "context": {
                                "cluster": "fixture",
                                "user": "fixture",
                                "namespace": NAMESPACE,
                            },
                        }
                    ],
                }
            )
        )
        cls.kubeconfig.chmod(0o600)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def setUp(self):
        self.installed("None", False)

    def tearDown(self):
        self.assertEqual([], self.server.writes, "dry runs must not mutate Kubernetes")

    def installed(self, model, tunnel, explicit=False, current_default=False):
        config = {"operator": {"enableTunnelService": tunnel, "billing": {"model": model}}}
        self.server.configmap = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "union-operator", "namespace": NAMESPACE},
            "data": {"config.yaml": yaml.safe_dump(config)},
        }
        self.server.forbidden = False
        defaults = json.loads(json.dumps(self.defaults))
        if not current_default:
            defaults["config"]["operator"]["billing"]["model"] = LEGACY_DEFAULT
        overrides = {"operator": {"enableTunnelService": tunnel}}
        if explicit:
            overrides["config"] = {"operator": {"billing": {"model": model}}}
        release = {
            "name": "billing",
            "namespace": NAMESPACE,
            "version": 1,
            "info": {
                "status": "deployed",
                "first_deployed": "2026-01-01T00:00:00Z",
                "last_deployed": "2026-01-01T00:00:00Z",
            },
            "chart": {
                "metadata": {"name": "billing-test", "version": "1.0.0", "apiVersion": "v2"},
                "values": defaults,
            },
            "config": overrides,
            "manifest": yaml.safe_dump(self.server.configmap),
        }
        encoded = base64.b64encode(
            base64.b64encode(gzip.compress(json.dumps(release).encode()))
        ).decode()
        self.server.release = {
            "apiVersion": "v1",
            "kind": "Secret",
            "type": "helm.sh/release.v1",
            "metadata": {
                "name": "sh.helm.release.v1.billing.v1",
                "namespace": NAMESPACE,
                "labels": {
                    "owner": "helm",
                    "name": "billing",
                    "status": "deployed",
                    "version": "1",
                },
            },
            "data": {"release": encoded},
        }

    def helm(self, *args, success=True):
        result = subprocess.run(
            [HELM, *map(str, args), "--kubeconfig", str(self.kubeconfig), "--namespace", NAMESPACE],
            text=True,
            capture_output=True,
            timeout=45,
            env={**os.environ, "HELM_DRIVER": "secret"},
        )
        if success:
            self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        else:
            self.assertNotEqual(0, result.returncode, result.stdout)
        return result

    def upgrade(self, *args, success=True):
        result = self.helm(
            "upgrade",
            "billing",
            self.chart,
            "--dry-run=server",
            "--disable-openapi-validation",
            "--output",
            "json",
            *args,
            success=success,
        )
        if not success:
            return result.stderr
        return self.operator(json.loads(result.stdout)["manifest"])

    @staticmethod
    def operator(manifest):
        document = next(
            doc
            for doc in yaml.safe_load_all(manifest)
            if doc
            and doc.get("kind") == "ConfigMap"
            and doc["metadata"]["name"] == "union-operator"
        )
        return yaml.safe_load(document["data"]["config.yaml"])["operator"]

    def test_fresh_defaults_and_explicit_models(self):
        for tunnel in ("true", "false"):
            for model in (None, *MODELS):
                with self.subTest(tunnel=tunnel, model=model):
                    args = ["--set", f"operator.enableTunnelService={tunnel}"]
                    if model is not None:
                        args += ["--set-string", f"config.operator.billing.model={model}"]
                    result = self.helm("template", "billing", self.chart, *args)
                    self.assertEqual(
                        model or "ResourceUsage", self.operator(result.stdout)["billing"]["model"]
                    )

    def test_upgrade_preserves_installed_models(self):
        for model in MODELS:
            for tunnel in (False, True):
                for flags in (
                    (),
                    ("--reuse-values",),
                    ("--reset-values",),
                    ("--set", "unrelated=changed"),
                ):
                    with self.subTest(model=model, tunnel=tunnel, flags=flags):
                        self.installed(model, tunnel, explicit=model in ("Legacy", "Shadow"))
                        self.assertEqual(model, self.upgrade(*flags)["billing"]["model"])

    def test_tunnel_change_and_billing_override(self):
        for flags in ((), ("--reuse-values",), ("--reset-values",)):
            with self.subTest(flags=flags):
                self.installed("None", False)
                operator = self.upgrade(*flags, "--set", "operator.enableTunnelService=true")
                self.assertTrue(operator["enableTunnelService"])
                self.assertEqual("None", operator["billing"]["model"])
                for model in MODELS:
                    self.assertEqual(
                        model,
                        self.upgrade(
                            *flags, "--set-string", f"config.operator.billing.model={model}"
                        )["billing"]["model"],
                    )
        self.installed("ResourceUsage", True)
        self.assertEqual(
            "ResourceUsage",
            self.upgrade("--reuse-values", "--set", "operator.enableTunnelService=false")[
                "billing"
            ]["model"],
        )

    def test_new_default_survives_repeated_upgrades(self):
        for model in MODELS:
            self.installed(model, True, current_default=True)
            self.assertEqual(model, self.upgrade()["billing"]["model"])
            self.assertEqual(model, self.upgrade("--reuse-values")["billing"]["model"])

    def test_unreadable_prior_config_fails_without_explicit_model(self):
        for config in (
            None,
            "",
            "invalid: [",
            "operator: []",
            "operator:\n  billing: wrong",
            "operator:\n  billing:\n    model: Unexpected",
        ):
            with self.subTest(config=config):
                self.installed("None", False)
                if config is None:
                    self.server.configmap = None
                else:
                    self.server.configmap["data"]["config.yaml"] = config
                self.assertIn(
                    "Cannot preserve installed billing model", self.upgrade(success=False)
                )
                self.assertEqual(
                    "None",
                    self.upgrade("--set-string", "config.operator.billing.model=None")["billing"][
                        "model"
                    ],
                )
        self.installed("None", False)
        self.server.forbidden = True
        self.assertIn("forbidden", self.upgrade(success=False).lower())

    def test_validation_templates_and_other_billing_fields(self):
        self.assertIn(
            "must resolve to",
            self.upgrade("--set-string", "config.operator.billing.model=Invalid", success=False),
        )
        values = self.directory / "custom.yaml"
        values.write_text(
            yaml.safe_dump(
                {
                    "config": {
                        "operator": {
                            "billing": {
                                "model": '{{ print "None" }}',
                                "resourceUsageCollectorConfig": {"interval": "37s"},
                            }
                        }
                    }
                }
            )
        )
        billing = self.upgrade("--values", values)["billing"]
        self.assertEqual("None", billing["model"])
        self.assertEqual("37s", billing["resourceUsageCollectorConfig"]["interval"])
        self.assertIn(
            "Cannot preserve installed billing model",
            self.helm("template", "billing", self.chart, "--is-upgrade", success=False).stderr,
        )

    def test_real_chart_config_and_workload_inventory(self):
        inventories = []
        for model in ("None", "ResourceUsage"):
            result = self.helm(
                "template",
                "billing",
                CHART,
                "--values",
                ROOT / "tests/values/dataplane.aws.yaml",
                "--values",
                CHART / "examples/values-test-certs.yaml",
                "--set-string",
                f"config.operator.billing.model={model}",
            )
            self.assertEqual(model, self.operator(result.stdout)["billing"]["model"])
            inventories.append(
                {
                    (doc["apiVersion"], doc["kind"], doc["metadata"]["name"])
                    for doc in yaml.safe_load_all(result.stdout)
                    if doc
                }
            )
        self.assertEqual(*inventories)


if __name__ == "__main__":
    unittest.main(verbosity=2)
