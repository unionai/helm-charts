#!/usr/bin/env python3
"""Every Union workload the dataplane chart renders carries the component label.

The operator's cluster snapshot discovers Union workloads by `platform.union.ai/component`
(unionai/cloud operator/pkg/components.go), not by name: a Deployment, DaemonSet or
StatefulSet without it is not reported, and one whose value the operator does not know is
skipped. Nothing at runtime says which, so this test walks the rendered snapshots under
tests/generated/ (every values file the chart is tested with) and requires the label in
metadata.labels and on the pod template, with a value from COMPONENT_IDS, unless the
workload's name is allowlisted because it has no component.
"""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / "tests/generated"
LABEL = "platform.union.ai/component"
WORKLOAD_KINDS = {"Deployment", "DaemonSet", "StatefulSet"}

# The ids the operator knows; see charts/CONVENTIONS.md and componentIDs in
# unionai/cloud operator/pkg/components.go.
COMPONENT_IDS = {
    "operator",
    "propeller",
    "propeller-manager",
    "leaseworker",
    "webhook",
    "proxy",
    "dataproxy",
    "gateway",
    "kourier",
    "knative-operator",
    "connector-service",
    "image-builder",
    "spark-history-server",
    "prometheus",
    "cloudwatch-exporter",
    "fuse-device-plugin",
    "logging",
    "cluster-resource-sync",
    "otel-collector",
    "node-otel-collector",
    "node-bootstrap",
    "node-observer",
    "uvol-broker",
    "mountpoint",
    "gpu-fault-watcher",
    "knative-activator",
    "knative-autoscaler",
    "knative-autoscaler-hpa",
    "knative-controller",
    "knative-webhook",
}

# Workloads with no component of their own, as the snapshots name them (the test
# release is "release-name", the kube-prometheus-stack alias "monitoring"). Add a name
# only with a reason.
ALLOWLIST = {
    # Monitoring helpers scraped by the dataplane's Prometheus.
    "release-name-kube-state-metrics",
    "release-name-prometheus-node-exporter",
    "release-name-dcgm-exporter",
    # kube-prometheus-stack mode: its operator, exporters and Grafana.
    "monitoring-operator",
    "monitoring-kube-state-metrics",
    "release-name-grafana",
}


def workloads(path):
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if isinstance(doc, dict) and doc.get("kind") in WORKLOAD_KINDS:
                yield doc


class WorkloadLabels(unittest.TestCase):
    def test_every_rendered_workload_is_labelled_or_allowlisted(self):
        snapshots = sorted(GENERATED.glob("dataplane.*.yaml"))
        self.assertTrue(snapshots, "no rendered dataplane snapshots; run make generate-expected")
        problems = []
        seen = 0
        for path in snapshots:
            for doc in workloads(path):
                seen += 1
                kind, name = doc["kind"], doc["metadata"].get("name", "<unnamed>")
                where = f"{path.name}: {kind} {name}"
                meta = (doc["metadata"].get("labels") or {}).get(LABEL)
                pod = (((doc.get("spec") or {}).get("template") or {}).get("metadata") or {}).get(
                    "labels"
                ) or {}
                pod = pod.get(LABEL)
                if meta is None and pod is None:
                    if name not in ALLOWLIST:
                        problems.append(f"{where} has no {LABEL} label")
                    continue
                if name in ALLOWLIST:
                    problems.append(f"{where} is labelled but allowlisted; drop one")
                if meta is None or pod is None:
                    problems.append(
                        f"{where} carries {LABEL} on only one of metadata.labels and the pod template"
                    )
                elif meta != pod:
                    problems.append(
                        f"{where} carries {LABEL}={meta!r} in metadata.labels and {pod!r} on the pod template"
                    )
                for value in {meta, pod} - {None}:
                    if value not in COMPONENT_IDS:
                        problems.append(
                            f"{where} carries {LABEL}={value!r}, which the operator does not know"
                        )
        self.assertGreater(seen, 0)
        self.assertEqual([], problems, "\n" + "\n".join(problems))

    def test_user_labels_cannot_override_the_component_label(self):
        # tests/values/dataplane.component-label-override.yaml sets the label through
        # every user-extensible label value; the chart emits its own id after them, so
        # the chart's value wins the duplicate key on every workload.
        path = GENERATED / "dataplane.component-label-override.yaml"
        self.assertTrue(path.exists(), f"{path.name} missing; run make generate-expected")
        overridden = []
        custom_seen = False
        for doc in workloads(path):
            for labels in (
                doc["metadata"].get("labels") or {},
                (((doc.get("spec") or {}).get("template") or {}).get("metadata") or {}).get(
                    "labels"
                )
                or {},
            ):
                custom_seen = custom_seen or labels.get("custom-label") == "custom-value"
                if labels.get(LABEL) == "user-override":
                    overridden.append(f"{doc['kind']} {doc['metadata'].get('name')}")
        self.assertTrue(custom_seen, "the fixture's user labels did not render at all")
        self.assertEqual([], overridden, f"user values overrode {LABEL} on: {overridden}")

    def test_allowlist_names_are_rendered_somewhere(self):
        # A stale allowlist entry would hide a workload renamed into it.
        names = {
            doc["metadata"].get("name")
            for path in GENERATED.glob("dataplane.*.yaml")
            for doc in workloads(path)
        }
        stale = sorted(ALLOWLIST - names)
        self.assertEqual([], stale, f"allowlisted workloads no chart renders: {stale}")


if __name__ == "__main__":
    unittest.main()
