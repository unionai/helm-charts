#!/usr/bin/env python3
"""Render the self-managed chart to verify opt-in ARM builds and service isolation."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/dataplane"
HELM = os.environ.get("HELM_BIN", "helm")


def render(values=None, success=True):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(values or {}))
        result = subprocess.run(
            [
                HELM,
                "template",
                "arm-test",
                str(CHART),
                "--namespace",
                "union",
                "--kube-version",
                "1.32.0",
                "-f",
                str(CHART / "examples/values-test-certs.yaml"),
                "-f",
                str(ROOT / "tests/values/dataplane.namespace-single.yaml"),
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


def builders(docs, kind):
    return {
        doc["metadata"]["labels"]["app.kubernetes.io/name"]: doc
        for doc in docs
        if doc["kind"] == kind
        and doc["metadata"].get("labels", {}).get("app.kubernetes.io/name", "")
        in ("imagebuilder-buildkit", "imagebuilder-buildkit-arm")
    }


def config(docs, key):
    return [
        doc["data"][key]
        for doc in docs
        if doc["kind"] == "ConfigMap" and key in doc.get("data", {})
    ]


class BuildkitArmTest(unittest.TestCase):
    def test_default_remains_single_arch(self):
        docs = render()
        self.assertEqual(list(builders(docs, "Deployment")), ["imagebuilder-buildkit"])
        for key in ("buildkit-uri-arm", "image-builder.buildkit-uri-arm"):
            self.assertEqual(config(docs, key), [])
        deployment = builders(docs, "Deployment")["imagebuilder-buildkit"]
        self.assertNotIn(
            "kubernetes.io/arch", deployment["spec"]["template"]["spec"].get("nodeSelector", {})
        )

    def test_missing_arm_settings_remain_disabled(self):
        docs = render({"imageBuilder": {"buildkit": {"arm": None}}})
        self.assertEqual(list(builders(docs, "Deployment")), ["imagebuilder-buildkit"])
        self.assertEqual(config(docs, "image-builder.buildkit-uri-arm"), [])

    def test_arm_routing_scaling_and_configuration(self):
        for single_namespace in (False, True):
            for autoscaling in (False, True):
                with self.subTest(single_namespace=single_namespace, autoscaling=autoscaling):
                    docs = render(
                        {
                            "low_privilege": single_namespace,
                            "namespaces": {"enabled": not single_namespace},
                            "imageBuilder": {
                                "buildkit": {
                                    "arm": {"enabled": True},
                                    "replicaCount": 2,
                                    "autoscaling": {
                                        "enabled": autoscaling,
                                        "minReplicas": 2,
                                        "maxReplicas": 5,
                                    },
                                }
                            },
                        }
                    )
                    deployments = builders(docs, "Deployment")
                    self.assertEqual(len(deployments), 2)
                    for name, dep in deployments.items():
                        pod = dep["spec"]["template"]
                        arch = "arm64" if name.endswith("-arm") else "amd64"
                        self.assertEqual(pod["spec"]["nodeSelector"]["kubernetes.io/arch"], arch)
                        self.assertEqual("replicas" in dep["spec"], not autoscaling)
                        if not autoscaling:
                            self.assertEqual(dep["spec"]["replicas"], 2)
                    for kind in ("Service", "PodDisruptionBudget"):
                        resources = builders(docs, kind)
                        self.assertEqual(len(resources), 2)
                        for name, resource in resources.items():
                            selector = resource["spec"]["selector"]
                            selector = selector.get("matchLabels", selector)
                            selected = [
                                key
                                for key, dep in deployments.items()
                                if all(
                                    dep["spec"]["template"]["metadata"]["labels"].get(k) == v
                                    for k, v in selector.items()
                                )
                            ]
                            self.assertEqual(selected, [name])
                    hpas = builders(docs, "HorizontalPodAutoscaler")
                    self.assertEqual(len(hpas), 2 if autoscaling else 0)
                    for name, hpa in hpas.items():
                        self.assertEqual(
                            hpa["spec"]["scaleTargetRef"]["name"],
                            deployments[name]["metadata"]["name"],
                        )
                        self.assertEqual(hpa["spec"]["maxReplicas"], 5)
                    arm_service = builders(docs, "Service")["imagebuilder-buildkit-arm"]
                    uri = f"tcp://{arm_service['metadata']['name']}.union.svc.cluster.local:1234"
                    self.assertEqual(config(docs, "image-builder.buildkit-uri-arm"), [uri])
                    self.assertEqual(
                        config(docs, "buildkit-uri-arm"), [uri] if single_namespace else []
                    )

    def test_arm_inherits_security_identity_storage_and_allows_scheduling_overrides(self):
        docs = render(
            {
                "imageBuilder": {
                    "buildkit": {
                        "arm": {
                            "enabled": True,
                            "nodeSelector": {"pool": "arm"},
                            "tolerations": [{"key": "arm-pool", "operator": "Exists"}],
                        },
                        "nodeSelector": {"pool": "amd", "kubernetes.io/arch": "amd64"},
                        "tolerations": [{"key": "shared", "operator": "Exists"}],
                        "rootless": True,
                        "hostUsers": False,
                        "openShift": {"enabled": True},
                        "serviceAccount": {"forceDedicated": True},
                        "podEnv": [{"name": "TEST", "value": "shared"}],
                        "additionalVolumes": [{"name": "extra", "emptyDir": {}}],
                        "additionalVolumeMounts": [{"name": "extra", "mountPath": "/extra"}],
                    }
                }
            }
        )
        deps = builders(docs, "Deployment")
        amd = deps["imagebuilder-buildkit"]["spec"]["template"]
        arm = deps["imagebuilder-buildkit-arm"]["spec"]["template"]
        for key in ("containers", "volumes", "serviceAccountName", "hostUsers"):
            self.assertEqual(amd["spec"][key], arm["spec"][key])
        self.assertEqual(amd["metadata"]["annotations"], arm["metadata"]["annotations"])
        self.assertEqual(
            arm["spec"]["nodeSelector"], {"pool": "arm", "kubernetes.io/arch": "arm64"}
        )
        self.assertEqual(len(arm["spec"]["tolerations"]), 3)
        self.assertEqual(len(amd["spec"]["tolerations"]), 1)
        anti_affinity = arm["spec"]["affinity"]["podAntiAffinity"][
            "requiredDuringSchedulingIgnoredDuringExecution"
        ]
        self.assertEqual(
            anti_affinity[0]["labelSelector"]["matchLabels"],
            deps["imagebuilder-buildkit-arm"]["spec"]["selector"]["matchLabels"],
        )

    def test_external_arm_endpoint_without_managed_pool(self):
        uri = "tcp://external-arm.buildkit.svc.cluster.local:2345"
        for managed_primary in (False, True):
            with self.subTest(managed_primary=managed_primary):
                docs = render(
                    {
                        "imageBuilder": {
                            "buildkitUri": "" if managed_primary else "tcp://external-amd:1234",
                            "buildkitUriArm": uri,
                            "buildkit": {"enabled": managed_primary},
                        }
                    }
                )
                self.assertEqual(len(builders(docs, "Deployment")), int(managed_primary))
                if not managed_primary:
                    self.assertEqual(config(docs, "buildkit-uri"), ["tcp://external-amd:1234"])
                    self.assertEqual(
                        config(docs, "image-builder.buildkit-uri"), ["tcp://external-amd:1234"]
                    )
                for key in ("buildkit-uri-arm", "image-builder.buildkit-uri-arm"):
                    self.assertEqual(config(docs, key), [uri])

    def test_disabled_imagebuilder_emits_no_arm_resources_or_uri(self):
        docs = render({"imageBuilder": {"enabled": False, "buildkit": {"arm": {"enabled": True}}}})
        self.assertEqual(builders(docs, "Deployment"), {})
        self.assertEqual(config(docs, "image-builder.buildkit-uri-arm"), [])
        self.assertEqual(config(docs, "buildkit-uri-arm"), [])

    def test_invalid_endpoint_combinations_fail(self):
        for values, expected in [
            (
                {"buildkit": {"enabled": False, "arm": {"enabled": True}}},
                "requires imageBuilder.buildkit.enabled",
            ),
            (
                {"buildkitUriArm": "tcp://arm:1234", "buildkit": {"arm": {"enabled": True}}},
                "not both",
            ),
            (
                {"buildkitUriArm": "tcp://arm:1234", "buildkit": {"enabled": False}},
                "requires a primary BuildKit endpoint",
            ),
        ]:
            with self.subTest(values=values):
                self.assertIn(expected, render({"imageBuilder": values}, success=False))

    def test_arm_service_does_not_reuse_primary_load_balancer(self):
        docs = render(
            {
                "imageBuilder": {
                    "buildkit": {
                        "arm": {"enabled": True},
                        "fullnameOverride": "x" * 63,
                        "service": {"type": "LoadBalancer", "loadbalancerIp": "192.0.2.10"},
                    }
                }
            }
        )
        services = builders(docs, "Service")
        arm = services["imagebuilder-buildkit-arm"]
        self.assertLessEqual(len(arm["metadata"]["name"]), 63)
        self.assertNotEqual(
            arm["metadata"]["name"], services["imagebuilder-buildkit"]["metadata"]["name"]
        )
        self.assertEqual(arm["spec"]["type"], "ClusterIP")
        self.assertNotIn("loadBalancerIP", arm["spec"])

    def test_persistent_cache_is_per_architecture(self):
        """Each builder keeps its own cache volume and pointer: sharing them would
        make every restart fork the other architecture's state."""

        def sidecar_args(dep):
            spec = dep["spec"]["template"]["spec"]
            sidecar = next(c for c in spec["initContainers"] if c["name"] == "volume-cache")
            args = sidecar["args"]
            return {k: args[args.index(k) + 1] for k in ("--name", "--pointer")}

        base = {
            "enabled": True,
            "image": {"repository": "example/union-volume-cache", "tag": "x"},
            "bucket": "s3://b/cache/",
        }
        for pointers, want_amd, want_arm in (
            ({}, None, None),
            ({"pointer": "s3://b/p/amd"}, "s3://b/p/amd", None),
            ({"pointer": "s3://b/p/amd", "armPointer": "s3://b/p/arm"}, "s3://b/p/amd", "s3://b/p/arm"),
        ):
            with self.subTest(**pointers):
                docs = render(
                    {
                        "imageBuilder": {
                            "buildkit": {
                                "arm": {"enabled": True},
                                "persistentCache": {**base, **pointers},
                            }
                        }
                    }
                )
                deps = builders(docs, "Deployment")
                amd = sidecar_args(deps["imagebuilder-buildkit"])
                arm = sidecar_args(deps["imagebuilder-buildkit-arm"])
                amd_name = deps["imagebuilder-buildkit"]["metadata"]["name"]
                arm_name = deps["imagebuilder-buildkit-arm"]["metadata"]["name"]
                # The amd64 builder is unchanged by the ARM option.
                self.assertEqual(amd["--name"], amd_name)
                self.assertEqual(arm["--name"], arm_name)
                self.assertEqual(amd["--pointer"], want_amd or f"s3://b/cache/{amd_name}/LATEST")
                self.assertEqual(arm["--pointer"], want_arm or f"s3://b/cache/{arm_name}/LATEST")
                self.assertNotEqual(amd["--name"], arm["--name"])
                self.assertNotEqual(amd["--pointer"], arm["--pointer"])


if __name__ == "__main__":
    unittest.main()
