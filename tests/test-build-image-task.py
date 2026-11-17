"""The build-image task the controlplane bootstrap Job registers must not request CoPilot.

imagebuild writes its outputs itself; CoPilot's uploader would fail on the missing
/var/outputs/fully_qualified_image. Run with the flyte version the bootstrap image pins.
"""

import importlib.util
import os
import pathlib

from flyte._internal.runtime.task_serde import translate_task_to_wire
from flyte.models import SerializationContext

os.environ.setdefault("APP_VERSION", "test")
os.environ.setdefault("UNION_IMAGE_NAME_PREFIX", "example.com/union")

path = pathlib.Path(__file__).parents[1] / "charts/controlplane/files/build_image_task.py"
spec = importlib.util.spec_from_file_location("build_image_task", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

sctx = SerializationContext(
    version="test", project="system", domain="production", org="o", code_bundle=None
)
pod = translate_task_to_wire(module.build_image_task, sctx).task_template.k8s_pod
assert not (pod.HasField("data_config") and pod.data_config.enabled), (
    f"build-image requests CoPilot: {pod.data_config}"
)
print("build-image task: no CoPilot data loading")
