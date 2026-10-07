#!/usr/bin/env python3
"""Render the dataplane chart to check the opt-in GPU fault watcher and quarantine."""

import json
import os
import shutil
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
# gpuQuarantine.minOperatorVersion, the first operator release with the controller.
QUARANTINE_RELEASE = "2026.10.0"
QUARANTINE = {
    "low_privilege": False,
    "image": {"union": {"tag": QUARANTINE_RELEASE}},
    "config": {"gpuQuarantine": {"enabled": True}},
}
ALERTING = {"monitoring": {"alerting": {"enabled": True}}}
PROMTOOL = os.environ.get("PROMTOOL_BIN", "promtool")


def helm(command, values, *flags):
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory) / "base.yaml"
        base.write_text(yaml.safe_dump(BASE_VALUES))
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(values or {}))
        return subprocess.run(
            [
                HELM,
                command,
                "gpu-test",
                str(CHART),
                "--namespace",
                "union",
                "-f",
                str(CHART / "examples/values-test-certs.yaml"),
                "-f",
                str(base),
                "-f",
                str(path),
                *flags,
            ],
            text=True,
            capture_output=True,
        )


def install_notes(values):
    result = helm("install", values, "--dry-run=client")
    assert result.returncode == 0, result.stderr
    return result.stdout.partition("NOTES:")[2]


def render(values=None, kube_version="1.32.0", success=True):
    result = helm(
        "template",
        values,
        "--kube-version",
        kube_version,
        "--api-versions",
        "monitoring.coreos.com/v1",
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


def gpu_alerts(docs):
    rules = next(
        d
        for d in docs
        if d["kind"] == "PrometheusRule" and d["metadata"]["name"].endswith("-monitoring-rules")
    )
    for group in rules["spec"]["groups"]:
        if group["name"] == "union_dataplane_gpu_alerts":
            return {rule["alert"]: rule for rule in group["rules"]}
    return {}


def dashboard(docs):
    for doc in docs:
        if doc["kind"] == "ConfigMap" and "union-dataplane-gpu-faults.json" in doc.get("data", {}):
            return json.loads(doc["data"]["union-dataplane-gpu-faults.json"])
    return None


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
        self.assertEqual(
            daemonset["spec"]["updateStrategy"],
            {"type": "RollingUpdate", "rollingUpdate": {"maxUnavailable": "25%"}},
        )
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

    def test_global_pod_labels_reach_the_watcher_pods(self):
        docs = render({**WATCHER, "additionalPodLabels": {"team": "gpu", "cost-center": "ml"}})
        daemonset = find(docs, "DaemonSet", "union-gpufaultwatcher")
        labels = daemonset["spec"]["template"]["metadata"]["labels"]
        self.assertEqual(labels["team"], "gpu")
        self.assertEqual(labels["cost-center"], "ml")
        self.assertTrue(daemonset["spec"]["selector"]["matchLabels"].items() <= labels.items())

    def test_admission_policy_holds_writes_to_the_own_node_from_kubernetes_1_30(self):
        name = "union-gpufaultwatcher-own-node-status"
        self.assertIsNone(find(render(WATCHER, "1.29.0"), "ValidatingAdmissionPolicy", name))
        opted_out = {"gpuFaultWatcher": {"enabled": True, "restrictNodeWrites": False}}
        for kind in ("ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"):
            self.assertIsNone(find(render(opted_out, "1.30.0"), kind, name))
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
        enforcing = {**QUARANTINE, "config": {"gpuQuarantine": {"enabled": True, "dryRun": False}}}
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
                values = {
                    **QUARANTINE,
                    **values,
                    "config": {**values.get("config", {}), **QUARANTINE["config"]},
                }
                self.assertIn("cluster permissions", render(values, success=False))

    def test_notes_warn_when_the_chart_grants_the_operator_no_rbac(self):
        byo = {**QUARANTINE, "operator": {"serviceAccount": {"create": False}}}
        self.assertIn("grants the operator no RBAC", install_notes(byo))
        self.assertNotIn("RBAC", install_notes(QUARANTINE))
        without_quarantine = {"low_privilege": False, "operator": byo["operator"]}
        self.assertNotIn("RBAC", install_notes(without_quarantine))

    def test_operator_release_without_the_controller_fails(self):
        for tag in ("2026.9.7", "v2026.9.7", "2026.9.7-beta.1"):
            with self.subTest(tag=tag):
                values = {**QUARANTINE, "image": {"union": {"tag": tag}}}
                self.assertIn(
                    f"needs union operator {QUARANTINE_RELEASE} or later: operator {tag}",
                    render(values, success=False),
                )

    def test_operator_release_with_the_controller_or_a_build_tag_renders(self):
        for tag in (QUARANTINE_RELEASE, f"{QUARANTINE_RELEASE}-beta.0", "v2026.11.2", "6caf8646"):
            with self.subTest(tag=tag):
                values = {**QUARANTINE, "image": {"union": {"tag": tag}}}
                self.assertIn("gpuQuarantine", operator_config(render(values)))


class GpuMonitoringTest(unittest.TestCase):
    def test_nothing_without_the_features(self):
        docs = render(ALERTING)
        self.assertEqual(gpu_alerts(docs), {})
        self.assertIsNone(find(docs, "ServiceMonitor", "union-gpufaultwatcher"))
        self.assertIsNone(dashboard(docs))

    def test_watcher_alerts_need_alerting(self):
        self.assertEqual(gpu_alerts(render(WATCHER)), {})
        self.assertEqual(
            set(gpu_alerts(render({**WATCHER, **ALERTING}))),
            {
                "UnionDPGPUFaultDetected",
                "UnionDPGPUFaultUnresolved",
                "UnionDPGPUFaultWatcherUnavailable",
            },
        )

    def test_quarantine_adds_the_held_alert_and_the_release_instruction(self):
        alerts = gpu_alerts(render({**WATCHER, **QUARANTINE, **ALERTING}))
        self.assertIn("UnionDPGPUQuarantineHeld", alerts)
        release = "union.ai/gpu-quarantine-release"
        self.assertIn(release, alerts["UnionDPGPUFaultUnresolved"]["annotations"]["description"])
        unresolved = gpu_alerts(render({**WATCHER, **ALERTING}))["UnionDPGPUFaultUnresolved"]
        self.assertNotIn(release, unresolved["annotations"]["description"])

    def test_watcher_scrape_labels_the_node_and_drops_the_watcher_pod(self):
        docs = render(WATCHER)
        monitor = find(docs, "ServiceMonitor", "union-gpufaultwatcher")
        endpoint = monitor["spec"]["endpoints"][0]
        self.assertTrue(endpoint["honorLabels"])
        self.assertIn(
            {"sourceLabels": ["__meta_kubernetes_pod_node_name"], "targetLabel": "node"},
            endpoint["relabelings"],
        )
        self.assertIn({"action": "labeldrop", "regex": "pod"}, endpoint["relabelings"])
        service = find(docs, "Service", "union-gpufaultwatcher")
        self.assertEqual(service["spec"]["selector"], monitor["spec"]["selector"]["matchLabels"])
        self.assertEqual(service["spec"]["ports"][0]["name"], endpoint["port"])

        off = render({**WATCHER, "monitoring": {"serviceMonitors": {"enabled": False}}})
        self.assertIsNone(find(off, "ServiceMonitor", "union-gpufaultwatcher"))

    def test_operator_metrics_port_is_scraped_for_quarantine(self):
        docs = render(QUARANTINE)
        monitor = find(docs, "ServiceMonitor", "union-service-monitor")
        service = find(docs, "Service", "union-operator")
        selector = monitor["spec"]["selector"]["matchLabels"]
        self.assertTrue(selector.items() <= service["metadata"]["labels"].items())
        ports = {port["name"]: port["port"] for port in service["spec"]["ports"]}
        self.assertEqual(ports[monitor["spec"]["endpoints"][0]["port"]], 10254)

    def test_dashboard_ships_with_either_feature(self):
        for values in (WATCHER, QUARANTINE):
            with self.subTest(values=values):
                board = dashboard(render(values))
                self.assertEqual(board["uid"], "union-dp-gpu-faults")
                namespace = board["templating"]["list"][1]["current"]["value"]
                self.assertEqual(namespace, "union")
        self.assertIsNone(
            dashboard(render({**WATCHER, "monitoring": {"dashboards": {"enabled": False}}}))
        )


class GpuNodesApiTest(unittest.TestCase):
    def test_proxy_lists_and_watches_nodes_and_pods(self):
        role = find(render({"low_privilege": False}), "ClusterRole", "proxy-system")
        self.assertTrue({"list", "watch"} <= rules_for(role, "nodes"))
        self.assertTrue({"list", "watch"} <= rules_for(role, "pods"))

    def test_low_privilege_proxy_gets_no_node_rule(self):
        docs = render({"low_privilege": True})
        self.assertIsNone(find(docs, "ClusterRole", "proxy-system"))
        self.assertEqual(rules_for(find(docs, "Role", "proxy-system"), "nodes"), set())


def watcher_series(metric, node, values, gpu="0", kind="xid", instance="watcher-a"):
    labels = (
        f'severity="critical", node="{node}", kind="{kind}", code="79", gpu="{gpu}", '
        f'namespace="union", instance="{instance}"'
    )
    return {"series": f"{metric}{{{labels}}}", "values": values}


def faults(node, values, **labels):
    return watcher_series("union_gpufaultwatcher_faults_total", node, values, **labels)


def last_fault(node, values, **labels):
    return watcher_series(
        "union_gpufaultwatcher_last_fault_timestamp_seconds", node, values, **labels
    )


def fired(**labels):
    return {"exp_labels": {"severity": "warning", "namespace": "union", **labels}}


DAY = 86400

# Each case is (input series, [(eval time, alert, expected alerts)]), on a one-minute grid.
PROMTOOL_CASES = [
    # The last fault gauge holds the fault's Unix time; the test clock starts at 0.
    (
        [
            last_fault("new", "_x20 1200x20"),
            last_fault("repeat", f"{-DAY}x30 1800x30"),
            # A new fault on GPU 1 while GPU 0 still reports one from yesterday.
            last_fault("second-gpu", f"{-DAY}x60"),
            last_fault("second-gpu", "_x30 1800x30", gpu="1"),
            # Yesterday's fault reappears after a scrape gap without moving.
            last_fault("scrape-gap", f"{-DAY}x20 _x15 {-DAY}x25"),
        ],
        [
            (
                "25m",
                "UnionDPGPUFaultDetected",
                [fired(node="new", kind="xid", code="79")],
            ),
            (
                "35m",
                "UnionDPGPUFaultDetected",
                [
                    fired(node="repeat", kind="xid", code="79"),
                    fired(node="second-gpu", kind="xid", code="79"),
                ],
            ),
            ("45m", "UnionDPGPUFaultDetected", []),
        ],
    ),
    # Prometheus restarted with empty storage while the watcher kept a fault from
    # yesterday: the counter looks new, the gauge has not moved, and nothing fires.
    (
        [faults("old", "1x30"), last_fault("old", f"{-DAY}x30")],
        [("2m", "UnionDPGPUFaultDetected", []), ("20m", "UnionDPGPUFaultDetected", [])],
    ),
    # A fault at 10m, then the watcher restarts at 12m and comes back without the gauge.
    # The lookback still holds the fault until it is 10 minutes old.
    (
        [last_fault("restarted", f"{-DAY}x9 600x1 stale")],
        [
            ("15m", "UnionDPGPUFaultDetected", [fired(node="restarted", kind="xid", code="79")]),
            ("21m", "UnionDPGPUFaultDetected", []),
        ],
    ),
    # The watcher restarts in place at 20m, so its counter and gauge go stale, and the
    # same GPU faults again at 26m with the same labels.
    (
        [faults("node", "1x20 stale _x5 1x20"), last_fault("node", f"{-DAY}x20 stale _x5 1560x20")],
        [
            ("24m", "UnionDPGPUFaultDetected", []),
            ("28m", "UnionDPGPUFaultDetected", [fired(node="node", kind="xid", code="79")]),
        ],
    ),
    (
        [
            {
                "series": 'kube_node_status_condition{condition="GPUXidCritical", status="true", node="faulted", instance="ksm-a"}',
                "values": "1x40 stale",
            },
            {
                "series": 'kube_node_status_condition{condition="GPUXidCritical", status="true", node="faulted", instance="ksm-b"}',
                "values": "_x40 1x40",
            },
            {
                "series": 'kube_node_status_condition{condition="GPUXidCritical", status="true", node="released"}',
                "values": "1x30 0x50",
            },
        ],
        [
            ("55m", "UnionDPGPUFaultUnresolved", []),
            ("65m", "UnionDPGPUFaultUnresolved", [fired(node="faulted")]),
        ],
    ),
    (
        [
            {
                "series": 'kube_daemonset_status_number_unavailable{namespace="union", daemonset="union-gpufaultwatcher"}',
                "values": "0x10 1x50",
            },
        ],
        [
            ("38m", "UnionDPGPUFaultWatcherUnavailable", []),
            (
                "45m",
                "UnionDPGPUFaultWatcherUnavailable",
                [fired(daemonset="union-gpufaultwatcher")],
            ),
        ],
    ),
    (
        [
            {
                "series": 'kube_daemonset_status_number_unavailable{namespace="union", daemonset="union-gpufaultwatcher"}',
                "values": "0x10 1x5 0x5 1x5 0x40",
            },
        ],
        [("40m", "UnionDPGPUFaultWatcherUnavailable", [])],
    ),
    (
        [
            {
                "series": 'union_gpuquarantine_held_nodes{namespace="union", pod="leader"}',
                "values": "0x10 1x80",
            },
            {
                "series": 'union_gpuquarantine_held_nodes{namespace="union", pod="follower"}',
                "values": "0x90",
            },
        ],
        [
            ("65m", "UnionDPGPUQuarantineHeld", []),
            ("75m", "UnionDPGPUQuarantineHeld", [fired()]),
        ],
    ),
]


# At 150m over a 1h range: a fault from long before, one on a node replaced within
# the range, a new one, one more on an old series, Xid and SXid faults with the same
# code, and a new series that never counted a fault.
FAULT_TABLE_SERIES = [
    faults("old", "1x180"),
    faults("replaced", "_x100 1x10 stale"),
    faults("new", "_x120 1x60"),
    faults("bumped", "1x100 2x80"),
    faults("both-kinds", "_x120 1x60"),
    faults("both-kinds", "_x120 1x60", kind="sxid"),
    faults("zero", "_x120 0x60"),
]
FAULT_TABLE_ROWS = [
    ("replaced", "xid", 1),
    ("new", "xid", 1),
    # increase() extrapolates 59 minutes of samples to the 60 minute range.
    ("bumped", "xid", 60 / 59),
    ("both-kinds", "xid", 1),
    ("both-kinds", "sxid", 1),
]


class GpuPromtoolTest(unittest.TestCase):
    def setUp(self):
        if shutil.which(PROMTOOL):
            return
        if os.environ.get("CI"):
            self.fail("promtool is not installed, and CI must run these checks")
        self.skipTest("promtool is not installed")

    def promtool_test(self, rules, tests):
        with tempfile.TemporaryDirectory() as directory:
            rule_file = Path(directory) / "rules.yaml"
            rule_file.write_text(yaml.safe_dump({"groups": [{"name": "gpu", "rules": rules}]}))
            test_file = Path(directory) / "tests.yaml"
            test_file.write_text(yaml.safe_dump({"rule_files": [str(rule_file)], "tests": tests}))
            result = subprocess.run(
                [PROMTOOL, "test", "rules", str(test_file)], text=True, capture_output=True
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_alerts_fire_as_documented(self):
        rules = list(gpu_alerts(render({**WATCHER, **QUARANTINE, **ALERTING})).values())
        # promtool compares annotations too; these cases check the expressions.
        for rule in rules:
            rule.pop("annotations")
        tests = [
            {
                "interval": "1m",
                "input_series": series,
                "alert_rule_test": [
                    {"eval_time": at, "alertname": alert, "exp_alerts": expected}
                    for at, alert, expected in checks
                ],
            }
            for series, checks in PROMTOOL_CASES
        ]
        self.promtool_test(rules, tests)

    def test_dashboard_fault_table_counts_faults_in_the_range(self):
        panels = dashboard(render(WATCHER))["panels"]
        table = next(p for p in panels if p["title"] == "Critical GPU faults in the time range")
        expr = table["targets"][0]["expr"]
        expr = expr.replace("$namespace", "union").replace("$__range", "1h")
        rows = [
            {
                "labels": f'{{node="{node}", gpu="0", kind="{kind}", code="79"}}',
                "value": value,
            }
            for node, kind, value in FAULT_TABLE_ROWS
        ]
        test = {
            "interval": "1m",
            "input_series": FAULT_TABLE_SERIES,
            "promql_expr_test": [{"expr": expr, "eval_time": "150m", "exp_samples": rows}],
        }
        self.promtool_test([], [test])


if __name__ == "__main__":
    unittest.main()
