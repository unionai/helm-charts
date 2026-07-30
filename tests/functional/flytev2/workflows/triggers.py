from datetime import datetime
import flyte


trigger_env = flyte.TaskEnvironment(
    name="trigger_env",
)


@trigger_env.task(triggers=flyte.Trigger.daily(trigger_time_input_key="trigger_time"))
def triggered_task(trigger_time: datetime, x: int = 1) -> str:
    return f"Triggered task at {trigger_time.isoformat()} with x={x}"
