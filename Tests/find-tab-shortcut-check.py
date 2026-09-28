#!/usr/bin/env python3
"""Run with mnml Test's window in front: python3 Tests/find-tab-shortcut-check.py."""
import json
import re
import subprocess
from pathlib import Path

bench = Path(__file__).resolve().parents[1] / "bench"

def ask(*args):
    return subprocess.check_output([str(bench), "--world", "copy", *args], text=True).strip()

assert json.loads(ask("probe"))["key"].startswith("AppKitWindow"), "Bring mnml Test's window to the front first"
tab = re.search(r"^●\s+([0-9a-f]+)", ask("tabs"), re.MULTILINE).group(1)
try:
    ask("press", "3", "f", "cmd")
    assert json.loads(ask("probe"))["finding"], "Find did not open"
    switched = json.loads(ask("press", "48", "\t", "ctrl"))
    state = json.loads(ask("probe"))
    assert not state["finding"], "Control-Tab left Find open"
    assert state["switchingTabs"] or switched["active"] != tab, "Tab navigation did not start"
    print("PASS: Control-Tab closes Find and reaches tab navigation")
finally:
    ask("press", "53", "\x1b")
    ask("select", tab)
