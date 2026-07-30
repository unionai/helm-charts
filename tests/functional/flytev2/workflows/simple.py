import asyncio
from typing import List

import flyte

env = flyte.TaskEnvironment("env")


@env.task
async def main(words: List[str] = ["hello", "world"]) -> str:
    with flyte.group("words"):
        coros = []
        for word in words:
            coros.append(shout(word))
        shouted = await asyncio.gather(*coros)
    return " ".join(shouted)


@env.task
async def shout(s: str) -> str:
    return s.upper()
