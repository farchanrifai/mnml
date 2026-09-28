#!/usr/bin/env python3
"""Run against mnml Test: python3 Tests/drive-user-agent-check.py."""
import json
import subprocess
from pathlib import Path

bench = Path(__file__).resolve().parents[1] / "bench"


def ask(*args):
    return subprocess.check_output(
        [str(bench), "--world", "copy", *args], text=True
    ).strip()


tab = ask("open", "https://drive.google.com/drive/u/0/my-drive")
try:
    state = json.loads(ask("wait", tab, "20"))
    assert not state["loading"], state
    assert "Chrome/" in ask("eval", tab, "navigator.userAgent")
    ask("go", tab, "https://example.com")
    state = json.loads(ask("wait", tab, "20"))
    assert not state["loading"], state
    agent = ask("eval", tab, "navigator.userAgent")
    assert "Version/" in agent and "Chrome/" not in agent, agent
    print("PASS: Drive compatibility is scoped and clears on navigation")
finally:
    ask("close", tab)
