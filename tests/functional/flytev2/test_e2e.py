import logging
import os

import flyte
import flyte.remote

from workflows.simple import main
from workflows.triggers import trigger_env
from flyteidl2.task.common_pb2 import TriggerAutomationSpecType

logger = logging.getLogger(__name__)


def _init_flyte(pytestconfig) -> None:
    """Pick the auth mode based on what's been configured.

    FLYTE_API_KEY env var → init_from_api_key (selfhosted / customer recipe).
    --config_file flag    → init_from_config (managed/BYOC legacy).

    The two modes are mutually exclusive at the SDK level: init_from_config
    eagerly reads clientSecretLocation from the config and blows up if the
    file isn't there, so we can't just call it and rely on FLYTE_API_KEY to
    "win" later — the dispatch has to happen here.
    """
    if os.environ.get("FLYTE_API_KEY"):
        project = pytestconfig.getoption("project")
        domain = pytestconfig.getoption("domain")
        if not project or not domain:
            import pytest

            raise pytest.UsageError(
                "FLYTE_API_KEY is set, so the test runs in API-key mode and "
                "needs --project and --domain (config.yaml is not consulted)."
            )
        flyte.init_from_api_key(project=project, domain=domain)
    else:
        flyte.init_from_config(pytestconfig.getoption("config_file"))


def test_workflow(pytestconfig):
    _init_flyte(pytestconfig)
    run = flyte.run(main)
    logger.info(run.url)
    run.wait(run)
    terminated_run = flyte.remote.Run.get(run.name)
    assert "succeeded" == terminated_run.phase


def test_trigger(pytestconfig):
    _init_flyte(pytestconfig)
    flyte.deploy(trigger_env)
    trigger_name = flyte.Trigger.daily().name
    task_name = "trigger_env.triggered_task"
    trigger_details = flyte.remote.Trigger.get(name=trigger_name, task_name=task_name)
    assert TriggerAutomationSpecType.TYPE_SCHEDULE == trigger_details.automation_spec.type
    assert "0 0 * * *" == trigger_details.automation_spec.schedule.cron.expression
    assert "UTC" == trigger_details.automation_spec.schedule.cron.timezone
    assert trigger_details.is_active
    flyte.remote.Trigger.update(name=trigger_name, task_name=task_name, active=False)
    trigger_details = flyte.remote.Trigger.get(name=trigger_name, task_name=task_name)
    assert not trigger_details.is_active
