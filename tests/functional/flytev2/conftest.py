#!/usr/bin/env python3
"""Mirror of cloud/tests/flytev2/conftest.py (the v2 functional suite).

Vendored into helm-charts so the release-integration workflow runs the same
v2 functional tests customers'/canary pipelines run, without checking out the
cloud repo. Kept in sync with cloud/tests/flytev2 by hand.

Two authentication modes, picked at runtime by tests/functional/flytev2/test_e2e.py:

1. **FLYTE_API_KEY mode (selfhosted, customer recipe)**: set `FLYTE_API_KEY`
   and pass `--project` / `--domain`. The SDK decodes endpoint+client_id+secret
   from the key. Mirrors unionai-docs .../selfhosted/operations/cicd.md.

2. **Config-file mode (managed / selfmanaged legacy)**: `--config_file
   path/to/config.yaml` carrying endpoint, clientId, clientSecretLocation.

Note: the cloud suite's test_dataproxy.py (and workflows/io_logs.py) are NOT
mirrored — they import the clouddataproxy stubs from cloud's gen/pb_python,
which isn't available here. Only the endpoint/workflow-run e2e path is mirrored.
"""


def pytest_addoption(parser):
    parser.addoption(
        "--config_file",
        action="store",
        default=None,
        help="Path to a flyte config.yaml. Required unless FLYTE_API_KEY mode is used.",
    )
    parser.addoption(
        "--project",
        action="store",
        default=None,
        help="Flyte project. Used in FLYTE_API_KEY mode (otherwise read from config.yaml).",
    )
    parser.addoption(
        "--domain",
        action="store",
        default=None,
        help="Flyte deployment domain (e.g. 'development'). Used in FLYTE_API_KEY mode.",
    )
