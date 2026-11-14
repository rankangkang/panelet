#!/usr/bin/env python3
"""Validate snapshots captured through installed-app UI acceptance."""
import json
import math
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/product-acceptance")


def read(name):
    return json.loads((root / name).read_text())


def frames(snapshot):
    return [w["frame"] for w in snapshot["windows"]]


baseline = read("00-baseline.json")
active = read("01-ratio21-swapped-active.json")
assert all(w["fullScreen"] for w in active["windows"])
assert len({w["display"] for w in active["windows"]}) == 2
assert [w["frame"][2] for w in active["windows"]] == [854, 1706]
restored = read("02-auto-restored.json")
assert all(not w["fullScreen"] for w in restored["windows"])
assert frames(restored) == frames(baseline)

desktop = read("03-desktop-vertical12.json")
virtual = [d for d in desktop if d["virtual"]]
assert [d["bounds"][3] for d in virtual] == [480, 960]
assert [d["pixels"] for d in virtual] == [[2560, 480], [2560, 960]], "Smooth mode must use 1x"
assert all(w["fullScreen"] for w in read("04-pair-on-desktop.json")["windows"])
assert read("05-desktop-preserved.json") == desktop
assert all(not w["fullScreen"] for w in read("05-pair-ended.json")["windows"])
for name in ["06-restore-all.json", "07-cancelled.json", "08-unsupported-restored.json"]:
    displays = read(name)
    assert not any(d["virtual"] for d in displays), name
    assert displays[0]["bounds"] == [0, 0, 2560, 1440], name
assert frames(read("07-cancelled-windows.json")) == frames(read("08-normal-window-preserved.json"))
assert all(not w["fullScreen"] for w in read("08-unsupported-window-preserved.json")["windows"])
assert all(w["fullScreen"] for w in read("09-automatic-start.json")["windows"])

samples = read("10-stability.json")
assert len(samples) == 61 and samples[-1]["seconds"] >= 300
assert all(b["fixture_ticks"] > a["fixture_ticks"] for a, b in zip(samples, samples[1:]))
assert all(math.isfinite(s["cpu_percent"]) and s["rss_kib"] > 0 for s in samples)

assert frames(read("11-startup-recovery-target.json")) == frames(read("12-startup-recovered.json"))
assert frames(read("11-startup-displaced.json")) != frames(read("11-startup-recovery-target.json"))
assert read("13-startup-result.json")["journalRemoved"]
real_before = read("14-real-app-baseline.json")
real_active = read("15-real-app-active.json")
real_after = read("16-real-app-restored.json")
assert len(real_before) == len(real_active) == len(real_after) == 2
assert all(w["fullScreen"] is True and w["frame"][2] == 1280 for w in real_active)
assert [w["frame"][0] for w in real_active] == [2560, 3840]
assert [(w["windowID"], w["frame"]) for w in real_before] == [(w["windowID"], w["frame"]) for w in real_after]
assert all(w["fullScreen"] for w in read("18-final-qa-active.json")["windows"])
assert frames(read("17-final-qa-baseline.json")) == frames(read("19-final-qa-restored.json"))
physical_shortcut = read("20-physical-shortcut-restored.json")
assert physical_shortcut["userConfirmedGlobalShortcut"] and physical_shortcut["journalRemoved"]
assert not any(d["virtual"] for d in physical_shortcut["displays"])
assert all(not w["fullScreen"] for w in physical_shortcut["windows"])
assert frames(physical_shortcut) == frames(read("17-final-qa-baseline.json"))
report = (root / "diagnostics-en.txt").read_text()
for private in ["QA Monitor", "Mi Monitor", "QA One", "/Users/", "/Volumes/"]:
    assert private not in report, private
print("Product acceptance passed: ratios, swapped windows, exact recovery, desktop preservation, cancellation, unsupported windows, automatic start, 5-minute stability, startup recovery, Edge + TextEdit, final same-app regression, user-confirmed global shortcut and diagnostic privacy")
