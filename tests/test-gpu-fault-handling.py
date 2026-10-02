#!/usr/bin/env python3
"""Render the dataplane chart to check the opt-in GPU fault watcher and quarantine."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/dataplane"
HELM = os.environ.get("HELM_BIN", "helm")

BASE_VALUES = {
    "global": {"UNION_CONTROL_PLANE_HOST": "test-controlplane-host"},
    "secrets": {"admin": {"create": False}},
}
WATCHER = {"gpuFaultWatcher": {"enabled": True}}
QUARANTINE = {"low_privilege": False, "config": {"gpuQuarantine": {"enabled": True}}}


def render(values=None, kube_version="1.32.0", success=True):
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory) / "base.yaml"
        base.write_text(yaml.safe_dump(BASE_VALUES))
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(values or {}))
        result = subprocess.run(
            [
                HELM,
                "template",
                "gpu-test",
                str(CHART),
                "--namespace",
                "union",
                "--kube-version",
                kube_version,
                "-f",
                str(CHART / "examples/values-test-certs.yaml"),
                "-f",
                str(base),
                "-f",
                str(path),
            ],
            text=True,
            capture_output=True,
        )
    if not success:
        assert result.returncode != 0, "Invalid configuration unexpectedly rendered"
        return result.stderr
    assert result.returncode == 0, result.stderr
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def find(docs, kind, name):
    matches = [d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name]
    return matches[0] if matches else None


def watcher_docs(docs):
    return [
        d
        for d in docs
        if d["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "gpufaultwatcher"
    ]


def operator_config(docs):
    return yaml.safe_load(find(docs, "ConfigMap", "union-operator")["data"]["config.yaml"])


def rules_for(role, resource):
    return {
        verb
        for rule in role["rules"]
        if resource in rule.get("resources", [])
        for verb in rule["verbs"]
    }


class GpuFaultWatcherTest(unittest.TestCase):
    def test_off_by_default(self):
        docs = render()
        self.assertEqual(watcher_docs(docs), [])
        self.assertIsNone(find(docs, "ClusterRole", "union-gpufaultwatcher"))

    def test_daemonset_runs_the_operator_image_on_gpu_nodes_without_reserving_capacity(self):
        docs = render(WATCHER)
        daemonset = find(docs, "DaemonSet", "union-gpufaultwatcher")
        operator = find(docs, "Deployment", "union-operator")
        pod = daemonset["spec"]["template"]["spec"]
        container = pod["containers"][0]
        self.assertEqual(
            container["image"], operator["spec"]["template"]["spec"]["containers"][0]["image"]
        )
        self.assertEqual(container["args"][0], "gpufaultwatcher")
        self.assertEqual(container["resources"]["requests"], {"cpu": "0", "memory": "0"})
        self.assertTrue(pod["hostPID"])
        terms = pod["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
        keys = {term["matchExpressions"][0]["key"] for term in terms["nodeSelectorTerms"]}
        self.assertIn("nvidia.com/gpu.present", keys)
        self.assertIn({"operator": "Exists", "effect": "NoSchedule"}, pod["tolerations"])

        priority_class = find(docs, "PriorityClass", pod["priorityClassName"])
        self.assertEqual(priority_class["preemptionPolicy"], "Never")
        self.assertFalse(priority_class["globalDefault"])

        config = yaml.safe_load(
            find(docs, "ConfigMap", "union-gpufaultwatcher")["data"]["config.yaml"]
        )
        self.assertEqual(config["metricsBindAddress"], ":9096")
        self.assertEqual(container["ports"][0]["containerPort"], 9096)

    def test_existing_priority_class_is_used_and_not_created(self):
        docs = render({"gpuFaultWatcher": {"enabled": True, "priorityClassName": "node-low"}})
        pod = find(docs, "DaemonSet", "union-gpufaultwatcher")["spec"]["template"]["spec"]
        self.assertEqual(pod["priorityClassName"], "node-low")
        self.assertEqual([d for d in watcher_docs(docs) if d["kind"] == "PriorityClass"], [])

    def test_pod_resources_mount_follows_the_socket(self):
        socket = "unix:///run/k3s/pod-resources/kubelet.sock"
        docs = render(
            {"gpuFaultWatcher": {"enabled": True, "config": {"podResourcesSocket": socket}}}
        )
        pod = find(docs, "DaemonSet", "union-gpufaultwatcher")["spec"]["template"]["spec"]
        volume = next(v for v in pod["volumes"] if v["name"] == "pod-resources")
        self.assertEqual(volume["hostPath"]["path"], "/run/k3s/pod-resources")

    def test_invalid_config_fails(self):
        for config, expected in [
            ({"metricsBindAddress": ":1234"}, "gpuFaultWatcher.metricsPort"),
            ({"podResourcesSocket": "kubelet.sock"}, "absolute path"),
            ({"podResourcesSocket": "unix:///kubelet.sock"}, "absolute path"),
        ]:
            with self.subTest(config=config):
                values = {"gpuFaultWatcher": {"enabled": True, "config": config}}
                self.assertIn(expected, render(values, success=False))

    def test_rbac_writes_node_status_but_never_cordons_or_taints(self):
        role = find(render(WATCHER), "ClusterRole", "union-gpufaultwatcher")
        self.assertEqual(rules_for(role, "nodes/status"), {"patch"})
        self.assertEqual(rules_for(role, "nodes"), {"get"})
        self.assertEqual(rules_for(role, "pods"), {"get", "list", "watch"})

    def test_rbac_is_cluster_scoped_under_low_privilege(self):
        docs = render({"low_privilege": True, **WATCHER})
        self.assertIsNotNone(find(docs, "ClusterRoleBinding", "union-gpufaultwatcher"))

    def test_admission_policy_holds_writes_to_the_own_node_from_kubernetes_1_30(self):
        name = "union-gpufaultwatcher-own-node-status"
        self.assertIsNone(find(render(WATCHER, "1.29.0"), "ValidatingAdmissionPolicy", name))
        docs = render(WATCHER, "1.30.0")
        policy = find(docs, "ValidatingAdmissionPolicy", name)
        self.assertIn(
            "system:serviceaccount:union:union-gpufaultwatcher",
            policy["spec"]["matchConditions"][0]["expression"],
        )
        binding = find(docs, "ValidatingAdmissionPolicyBinding", name)
        self.assertEqual(binding["spec"]["validationActions"], ["Deny"])


class GpuQuarantineTest(unittest.TestCase):
    def test_off_by_default(self):
        docs = render({"low_privilege": False})
        self.assertNotIn("gpuQuarantine", operator_config(docs))
        self.assertNotIn("patch", rules_for(find(docs, "ClusterRole", "operator-system"), "nodes"))
        self.assertEqual(rules_for(find(docs, "Role", "operator-system"), "leases"), set())

    def test_enabled_renders_the_section_in_dry_run(self):
        docs = render(QUARANTINE)
        self.assertEqual(
            operator_config(docs)["gpuQuarantine"],
            {
                "enabled": True,
                "dryRun": True,
                "cordon": True,
                "maxQuarantinedNodes": 5,
                "resyncPeriod": "10m",
                "faultHistory": {"enabled": True},
            },
        )
        enforcing = {
            "low_privilege": False,
            "config": {"gpuQuarantine": {"enabled": True, "dryRun": False}},
        }
        self.assertFalse(operator_config(render(enforcing))["gpuQuarantine"]["dryRun"])

    def test_enabled_grants_node_patches_events_and_the_lease(self):
        docs = render(QUARANTINE)
        cluster_role = find(docs, "ClusterRole", "operator-system")
        self.assertIn("patch", rules_for(cluster_role, "nodes"))
        self.assertEqual(rules_for(cluster_role, "nodes/status"), {"patch"})
        self.assertEqual(rules_for(cluster_role, "events"), {"create", "patch"})
        role = find(docs, "Role", "operator-system")
        self.assertEqual(rules_for(role, "leases"), {"get", "create", "update"})

    def test_operator_knows_its_pod_for_the_lease(self):
        operator = find(render(QUARANTINE), "Deployment", "union-operator")
        env = {e["name"]: e for e in operator["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["POD_NAME"]["valueFrom"]["fieldRef"]["fieldPath"], "metadata.name")
        self.assertEqual(
            env["POD_NAMESPACE"]["valueFrom"]["fieldRef"]["fieldPath"], "metadata.namespace"
        )

    def test_without_cluster_permissions_fails(self):
        for values in (
            {"low_privilege": True},
            {"low_privilege": False, "config": {"operator": {"disableClusterPermissions": True}}},
        ):
            with self.subTest(values=values):
                values = {**values, "config": {**values.get("config", {}), **QUARANTINE["config"]}}
                self.assertIn("cluster permissions", render(values, success=False))


if __name__ == "__main__":
    unittest.main()
