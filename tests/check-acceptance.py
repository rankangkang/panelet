#!/usr/bin/env python3
"""Check the fixture snapshots collected during the real-display acceptance run."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/acceptance")
def read(name):
    return json.loads((root / name).read_text())
def full(record, expected):
    assert len(record["windows"]) == 2
    assert all(w["fullScreen"] == expected for w in record["windows"])
def unchanged(before, after):
    assert before["windows"] == after["windows"], "Unaffected display changed its windows"
    assert before["events"] == after["events"], "Unaffected display entered/exited full screen"
    assert after["ticks"] > before["ticks"], "Fixture stopped responding"

active = read("01-quick-active.json")
restored = read("02-auto-restored.json")
full(active, True)
full(restored, False)
assert len({w["display"] for w in active["windows"]}) == 2
assert [w["frame"] for w in restored["windows"]] == [[180, 240, 440, 452], [660, 240, 440, 452]]
assert all(w["display"] == 3 for w in restored["windows"])

left = read("03-dual-One.json")
right = read("03-dual-Two.json")
full(left, True)
full(right, True)
assert {w["display"] for w in left["windows"]}.isdisjoint(w["display"] for w in right["windows"])
unchanged(left, read("04-right-ended-One.json"))
full(read("04-right-ended-Two.json"), False)

right_again = read("05-dual-again-Two.json")
full(right_again, True)
unchanged(right_again, read("06-left-ended-Two.json"))
unchanged(right_again, read("07-left-merged-right-active.json"))
full(read("06-left-ended-One.json"), False)
for name in ["One", "Two"]:
    full(read(f"08-final-{name}.json"), False)
print("Acceptance snapshots passed: auto-restore, independent dual displays, full desktop merge isolation")
