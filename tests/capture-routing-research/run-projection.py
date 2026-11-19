"""Run the independent projection fixture or mirror one disposable TextEdit window."""

import argparse
import ctypes
import json
import plistlib
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")


class Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class Size(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class Rect(ctypes.Structure):
    _fields_ = [("origin", Point), ("size", Size)]

    def contains(self, x, y, width=0, height=0):
        return (
            self.origin.x <= x and x + width <= self.origin.x + self.size.width
            and self.origin.y <= y and y + height <= self.origin.y + self.size.height
        )


cg.CGGetActiveDisplayList.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)
]
cg.CGMainDisplayID.restype = ctypes.c_uint32
cg.CGDisplayVendorNumber.argtypes = [ctypes.c_uint32]
cg.CGDisplayVendorNumber.restype = ctypes.c_uint32
cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
cg.CGDisplayBounds.restype = Rect
cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
cg.CGEventCreate.argtypes = [ctypes.c_void_p]
cg.CGEventCreate.restype = ctypes.c_void_p
cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
cg.CGEventGetLocation.restype = Point
cg.CGWarpMouseCursorPosition.argtypes = [Point]
cf.CFRelease.argtypes = [ctypes.c_void_p]


def pointer():
    event = cg.CGEventCreate(None)
    if not event:
        raise RuntimeError("Cannot read the cursor position.")
    try:
        return cg.CGEventGetLocation(event)
    finally:
        cf.CFRelease(event)


def post(event):
    if not event:
        raise RuntimeError("Cannot create a test event.")
    cg.CGEventSetIntegerValueField(event, 42, 0x50414E45)
    cg.CGEventPost(0, event)
    cf.CFRelease(event)
    time.sleep(.06)


def mouse(kind, x, y):
    event = cg.CGEventCreateMouseEvent(None, kind, Point(x, y), 0)
    if event:
        cg.CGEventSetIntegerValueField(event, 1, 1)
    post(event)


def click(x, y):
    for kind in (5, 1, 2):
        mouse(kind, x, y)
    time.sleep(.25)


def wait_state(path, process):
    for _ in range(80):
        if path.is_file():
            return json.loads(path.read_text())
        if process.poll() is not None:
            raise RuntimeError("Projection probe exited.")
        time.sleep(.05)
    raise RuntimeError("The projection probe did not become ready.")


def bundle(probe, folder, role):
    contents = folder / f"Projection-{role}.app" / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    binary = contents / "MacOS" / f"Projection-{role}"
    shutil.copy2(probe, binary)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": f"dev.cmkk.panelet.prototype.{role}",
        "CFBundleExecutable": binary.name,
        "CFBundleName": f"Projection {role}",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
    }))
    return binary


def start_host(probe, folder, target, host_origin):
    subprocess.run(
        ["/usr/sbin/screencapture", "-x", "-o", "-l", str(target["window"]), str(folder / "target.png")],
        check=True,
    )
    arguments = [*host_origin, target["pid"], target["window"], *target["origin"], 3]
    return subprocess.Popen([str(bundle(probe, folder, "host")), "host", str(folder), *map(str, arguments)])


def smoke(folder):
    click(575, 342)
    click(575, 395)
    for key in (0, 36):  # A, Return
        for down in (True, False):
            post(cg.CGEventCreateKeyboardEvent(None, key, down))
    time.sleep(.7)
    mouse(5, 560, 475)
    mouse(1, 560, 475)
    for dx in (20, 40, 60):
        mouse(6, 560 + dx, 475)
    mouse(2, 620, 475)
    time.sleep(.35)
    (folder / "show-overlay").touch()
    time.sleep(.3)
    click(575, 342)

    target = [json.loads(line) for line in (folder / "target.jsonl").read_text().splitlines()]
    host = [json.loads(line) for line in (folder / "host.jsonl").read_text().splitlines()]
    checks = {
        "button_pressed_once": sum("button" in row for row in target) == 1,
        "complete_drag": all(any(event in row for row in target) for event in ("dragDown", "dragMove", "dragUp")),
        "field_received_a": any(row.get("text") == "a" for row in target),
        "overlay_received_click": sum("overlayClick" in row for row in host) == 1,
    }
    print(json.dumps(checks, indent=2))
    return 0 if all(checks.values()) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", type=Path, help="Path to the compiled ProjectionProbe")
    parser.add_argument("--textedit-window", metavar="TITLE", help="Use the exact title of a disposable TextEdit window")
    args = parser.parse_args()
    probe = args.probe.resolve(strict=True)
    for name in ("CGPreflightPostEventAccess", "CGPreflightScreenCaptureAccess"):
        check = getattr(cg, name)
        check.restype = ctypes.c_bool
        if not check():
            parser.exit(2, f"{name} denied.\n")

    ids, count = (ctypes.c_uint32 * 32)(), ctypes.c_uint32()
    if cg.CGGetActiveDisplayList(len(ids), ids, ctypes.byref(count)) != 0:
        parser.exit(2, "Cannot read the active displays.\n")
    virtuals = [cg.CGDisplayBounds(i) for i in ids[:count.value] if cg.CGDisplayVendorNumber(i) == 0x5653]
    if not virtuals:
        parser.exit(2, "An active Panelet split is required.\n")

    main_screen = cg.CGDisplayBounds(cg.CGMainDisplayID())
    origin = (500, 300)
    snapshot = None
    if args.textedit_window:
        snapshot = json.loads(subprocess.check_output([str(probe), "--textedit-window", args.textedit_window]))
        if not any(screen.contains(*snapshot["origin"], *snapshot["size"]) for screen in virtuals):
            parser.exit(2, "Place the entire TextEdit test window inside a Panelet virtual display.\n")
    elif not any(screen.size.width >= 600 and screen.size.height >= 450 for screen in virtuals):
        parser.exit(2, "The fixture needs a virtual display at least 600 × 450 points.\n")
    if not main_screen.contains(*origin, *(snapshot["size"] if snapshot else (400, 260))):
        parser.exit(2, "The projection panel does not fit on the main display.\n")

    folder = Path(tempfile.mkdtemp(prefix="panelet-projection-"))
    print(f"Test output: {folder}", flush=True)
    saved = pointer() if snapshot is None else None
    processes = []
    state = folder / "target-state.json"
    try:
        if snapshot:
            state.write_text(json.dumps(snapshot))
        else:
            screen = next(screen for screen in virtuals if screen.size.width >= 600 and screen.size.height >= 450)
            target = subprocess.Popen([
                str(bundle(probe, folder, "target")), "target", str(folder),
                str(screen.origin.x + 150), str(screen.origin.y + 180),
            ])
            processes.append(("target", target))
            wait_state(state, target)
            time.sleep(.4)
            snapshot = json.loads(state.read_text())
            if not screen.contains(*snapshot["origin"], 400, 260):
                raise RuntimeError("The target fixture is outside the selected virtual display.")
        host = start_host(probe, folder, snapshot, origin)
        processes.append(("host", host))
        wait_state(folder / "host-state.json", host)
        if args.textedit_window:
            print("Projection is ready. Press Ctrl+C when the manual comparison is complete.", flush=True)
            return host.wait()
        time.sleep(.5)
        return smoke(folder)
    except KeyboardInterrupt:
        return 130
    finally:
        for role, _ in processes:
            (folder / f"stop-{role}").touch()
        try:
            for _, process in reversed(processes):
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=2)
        finally:
            if saved is not None:
                cg.CGWarpMouseCursorPosition(saved)


if __name__ == "__main__":
    raise SystemExit(main())
