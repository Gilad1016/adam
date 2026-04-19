"""Built-in wait tool — rest to conserve electricity."""

import time

TOOL_NAME = "wait"
TOOL_DESCRIPTION = "Rest for N minutes to conserve electricity. Args: {minutes: number}"


def execute(args: dict) -> str:
    minutes = int(args.get("minutes", 5))
    minutes = max(1, min(minutes, 60))
    time.sleep(minutes * 60)
    return f"rested for {minutes} minutes"
