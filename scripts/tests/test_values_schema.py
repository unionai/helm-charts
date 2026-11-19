import json
import textwrap
from pathlib import Path

import pytest
import values_schema

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REAL_CHART = REPO_ROOT / "charts" / "dataplane"

# Every leaf the dataplane schema must declare: the paths Fleet's vendor
# templates write that values.yaml does not default.
FLEET_LEAVES = {
    "provider": "string",
    "low_privilege": "boolean",
    "global.AWS_ACCOUNT_ID": "string",
    "global.AWS_REGION": "string",
    "config.core.webhook.embeddedSecretManagerConfig.azureConfig.vaultURI": "string",
    "config.core.webhook.embeddedSecretManagerConfig.gcpConfig.project": "string",
    "config.proxy.smConfig.awsConfig.account": "string",
    "config.proxy.smConfig.awsConfig.region": "string",
    "config.proxy.smConfig.azureConfig.vaultURI": "string",
    "config.proxy.smConfig.gcpConfig.project": "string",
    "config.proxy.persistedLogs.azureLogAnalytics.logAnalyticsWorkspaceResourceIdTemplate": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.project": "string",
    "config.k8s.plugins.k8s.default-labels": "array",
    "config.k8s.plugins.k8s.interruptible-tolerations": "array",
    "config.k8s.plugins.k8s.gpu-device-node-label": "string",
    "config.k8s.plugins.k8s.gpu-partition-size-node-label": "string",
    "config.k8s.plugins.k8s.accelerator-device-classes": ["object", "array"],
    "config.k8s.plugins.k8s.accelerator-devices": ["object", "array"],
    "config.k8s.plugins.k8s.interruptible-node-selector-requirement.key": "string",
    "config.k8s.plugins.k8s.interruptible-node-selector-requirement.operator": "string",
    "config.k8s.plugins.k8s.interruptible-node-selector-requirement.values": "array",
    "config.k8s.plugins.k8s.non-interruptible-node-selector-requirement.key": "string",
    "config.k8s.plugins.k8s.non-interruptible-node-selector-requirement.operator": "string",
    "config.k8s.plugins.k8s.non-interruptible-node-selector-requirement.values": "array",
    "leaseworker.task_logs.plugins.logs.azure-log-templates": "array",
    "leaseworker.task_logs.plugins.logs.stackdriver-enabled": "boolean",
}


# Additional supported proxy fields, pinned to the selected operator source.
PROXY_LEAVES = {
    "config.proxy.logStreamTimeout": ["number", "string"],
    "config.proxy.informerResyncDuration": ["number", "string"],
    "config.proxy.actorConfig.streamingPollerInterval": ["number", "string"],
    "config.proxy.logsServiceConfig.streamingFlushInterval": ["number", "string"],
    "config.proxy.logsServiceConfig.streamingFlushByteSize": "integer",
    "config.proxy.logsServiceConfig.streamingBufferSize": "integer",
    "config.proxy.logsServiceConfig.maxConcurrentStreams": "integer",
    "config.proxy.smConfig.awsConfig.retries": "integer",
    "config.proxy.smConfig.gcpConfig.externalAccount.type": "string",
    "config.proxy.smConfig.gcpConfig.externalAccount.audience": "string",
    "config.proxy.smConfig.gcpConfig.externalAccount.scopes": "array",
    "config.proxy.smConfig.gcpConfig.externalAccount.subjectTokenType": "string",
    "config.proxy.smConfig.gcpConfig.externalAccount.serviceAccountImpersonationURL": "string",
    "config.proxy.smConfig.gcpConfig.externalAccount.enableAuthDebugTransport": "boolean",
    "config.proxy.smConfig.gcpConfig.externalAccount.aws.account": "string",
    "config.proxy.smConfig.gcpConfig.externalAccount.aws.region": "string",
    "config.proxy.smConfig.gcpConfig.externalAccount.aws.retries": "integer",
    "config.proxy.smConfig.gcpConfig.gcpSecretManager.replicationPolicy": "string",
    "config.proxy.smConfig.gcpConfig.gcpSecretManager.replicationLocations": "array",
    "config.proxy.organization": "string",
    "config.proxy.cluster": "string",
    "config.proxy.orgStorage.enabled": "boolean",
    "config.proxy.serverlessConfig.enabled": "boolean",
    "config.proxy.serverlessConfig.objectStoreServiceEndpoint": "string",
    "config.proxy.persistedLogs.awsCloudWatch.groupNameTemplate": "string",
    "config.proxy.persistedLogs.awsCloudWatch.streamNameTemplate": "string",
    "config.proxy.persistedLogs.awsCloudWatch.streamNamePrefixTemplate": "string",
    "config.proxy.persistedLogs.awsCloudWatch.aws.account": "string",
    "config.proxy.persistedLogs.awsCloudWatch.aws.region": "string",
    "config.proxy.persistedLogs.awsCloudWatch.aws.retries": "integer",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.type": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.audience": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.scopes": "array",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.subjectTokenType": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.serviceAccountImpersonationURL": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.enableAuthDebugTransport": "boolean",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.aws.account": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.aws.region": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.externalAccount.aws.retries": "integer",
    "config.proxy.persistedLogs.gcpLogging.gcp.gcpSecretManager.replicationPolicy": "string",
    "config.proxy.persistedLogs.gcpLogging.gcp.gcpSecretManager.replicationLocations": "array",
    "config.proxy.persistedLogs.gcpLogging.resourceNames": "array",
    "config.proxy.stream.modifyStreamContentType": "boolean",
    "config.proxy.imageBuilderConfig.repositoryOverride": "string",
    "config.proxy.imageBuilderConfig.basicAuth.registry": "string",
    "config.proxy.imageBuilderConfig.basicAuth.username": "string",
    "config.proxy.imageBuilderConfig.basicAuth.passwordPlainText": "string",
    "config.proxy.imageBuilderConfig.basicAuth.passwordSecretName": "string",
    "config.proxy.imageBuilderConfig.anonymousLookup": "boolean",
    "config.proxy.imageBuilderConfig.depotProjectId": "string",
    "config.proxy.imageBuilderConfig.orgDepot.enabled": "boolean",
    "config.proxy.imageBuilderConfig.orgDepot.namespaceTemplate": "string",
    "config.proxy.imageBuilderConfig.orgDepot.secret": "string",
    "config.proxy.connectorLogs.clientCacheSize": "integer",
    "config.proxy.connectorLogs.clientCacheTTL": ["number", "string"],
    "config.proxy.connectorLogs.maxPages": "integer",
    "config.proxy.prometheusUrl": "string",
    "config.proxy.podSessionCookiePrefixes": "array",
}


def leaves(schema: dict, prefix: tuple[str, ...] = ()) -> dict[str, str]:
    properties = schema.get("properties")
    if not properties:
        return {".".join(prefix): schema.get("type")}
    found: dict[str, str] = {}
    for name, child in properties.items():
        found.update(leaves(child, prefix + (name,)))
    return found


def chart(tmp_path: Path, values: str) -> Path:
    (tmp_path / "values.yaml").write_text(textwrap.dedent(values))
    return tmp_path


def generate(tmp_path: Path, values: str) -> dict:
    return json.loads(values_schema.generate(chart(tmp_path, values)))


def test_annotated_children_absent_from_defaults(tmp_path):
    schema = generate(
        tmp_path,
        """
        # @schema
        # type: object
        # properties:
        #   ACCOUNT: {type: string, description: Set by the overlay.}
        # @schema
        global:
          HOST: ""
        other: 1
        """,
    )
    assert schema["$schema"] == values_schema.DRAFT
    assert schema["type"] == "object"
    assert schema["properties"] == {
        "global": {
            "type": "object",
            "properties": {"ACCOUNT": {"type": "string", "description": "Set by the overlay."}},
        }
    }
    assert "additionalProperties" not in json.dumps(schema)


def test_root_block_declares_top_level_key(tmp_path):
    schema = generate(
        tmp_path,
        """
        # @schema.root
        # properties:
        #   provider: {type: string}
        # @schema.root
        global:
          HOST: ""
        """,
    )
    assert schema["properties"] == {"provider": {"type": "string"}}


def test_nested_annotation_builds_object_ancestors(tmp_path):
    schema = generate(
        tmp_path,
        """
        config:
          proxy:
            # -- helm-docs comment stays between the block and the key
            # @schema
            # properties:
            #   awsConfig:
            #     properties:
            #       account: {type: string}
            # @schema
            smConfig:
              enabled: "{{ .Values.x }}"
        """,
    )
    assert leaves(schema) == {"config.proxy.smConfig.awsConfig.account": "string"}
    assert schema["properties"]["config"]["type"] == "object"
    assert (
        schema["properties"]["config"]["properties"]["proxy"]["properties"]["smConfig"]["type"]
        == "object"
    )


def test_keys_inside_list_items_do_not_shift_paths(tmp_path):
    schema = generate(
        tmp_path,
        """
        a:
          items:
            - name: x
              deep:
                deeper: 1
          # @schema
          # type: string
          # @schema
          b: ""
        """,
    )
    assert leaves(schema) == {"a.b": "string"}


def test_quoted_keys_with_dots_and_slashes_stay_literal(tmp_path):
    schema = generate(
        tmp_path,
        """
        proxy:
          podAnnotations:
            # @schema
            # type: string
            # @schema
            "karpenter.sh/do-not-disrupt": "true"
        """,
    )
    assert leaves(schema) == {"proxy.podAnnotations.karpenter.sh/do-not-disrupt": "string"}
    assert (
        "karpenter.sh/do-not-disrupt"
        in schema["properties"]["proxy"]["properties"]["podAnnotations"]["properties"]
    )


def test_output_is_deterministic(tmp_path):
    values = """
        # @schema
        # properties:
        #   z: {type: string}
        #   a: {type: string}
        # @schema
        m: {}
        """
    first = values_schema.generate(chart(tmp_path, values))
    second = values_schema.generate(tmp_path)
    assert first == second
    assert first.index('"a"') < first.index('"z"')


@pytest.mark.parametrize(
    "values, message",
    [
        ("# @schema\n# type: string\n", "unterminated"),
        ("# @schema\n# type: string\nkey: 1\n", "non-comment line"),
        ("# @schema\n# - not a mapping\n# @schema\nkey: 1\n", "non-empty mapping"),
        ("# @schema\n# type: string\n# @schema\n\nkey: 1\n", "not directly above a key"),
        ("outer:\n  # @schema\n  # type: string\n  # @schema\nnext: 1\n", "does not match key"),
        (
            "key: 1\n# @schema.root\n# properties: {p: {type: string}}\n# @schema.root\nother: 2\n",
            "before the first key",
        ),
        ("items:\n  # @schema\n  # type: string\n  # @schema\n  - name: x\n", "list items"),
        (
            "# @schema\n# type: string\n# additionalProperties: false\n# @schema\nkey: 1\n",
            "additionalProperties",
        ),
        ("# @schema\n# type: object\n# required: [a]\n# @schema\nkey: {}\n", "required"),
        ("# @schema\n# $ref: '#/definitions/x'\n# @schema\nkey: 1\n", r"\$ref"),
        ("# @schema\n# type: tuple\n# @schema\nkey: 1\n", "unsupported type"),
        (
            "# @schema\n# type: string\n# properties: {a: {type: string}}\n# @schema\nkey: {}\n",
            "declares properties but type string",
        ),
        (
            "# @schema\n# type: object\n# @schema\n# @schema\n# type: string\n# @schema\nkey: {}\n",
            "two annotation blocks",
        ),
        ("# @schema\n# type: string\n# @schema\n", "not followed by a key"),
    ],
)
def test_malformed_annotations_are_rejected(tmp_path, values, message):
    with pytest.raises(values_schema.AnnotationError, match=message):
        values_schema.generate(chart(tmp_path, values))


def test_check_mode_exit_codes(tmp_path, capsys):
    chart(tmp_path, "# @schema\n# type: string\n# @schema\nkey: ''\n")
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 1
    assert "stale" in capsys.readouterr().err
    assert values_schema.main(["--chart", str(tmp_path)]) == 0
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 0
    (tmp_path / "values.yaml").write_text("# @schema\n# type: boolean\n# @schema\nkey: true\n")
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 1
    diff = capsys.readouterr().err
    assert '-      "type": "string"' in diff
    assert '+      "type": "boolean"' in diff
    (tmp_path / "values.yaml").write_text("# @schema\n# type: boolean\nkey: true\n")
    assert values_schema.main(["--chart", str(tmp_path), "--check"]) == 2


def test_real_dataplane_chart_declares_fleet_and_proxy_paths():
    schema = json.loads(values_schema.generate(REAL_CHART))
    assert leaves(schema) == FLEET_LEAVES | PROXY_LEAVES
    assert "additionalProperties" not in json.dumps(schema)
    assert "enum" not in json.dumps(schema)
    assert values_schema.generate(REAL_CHART) == (REAL_CHART / "values.schema.json").read_text()
