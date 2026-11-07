#!/usr/bin/env python3
"""Shared primitives for the isolated UI performance/accessibility QA runs.

Everything here talks only to a *development* copy of the app
(``com.zeh.pkd.development``) launched with ``PKD_DEVELOPMENT_ROOT`` pointing at
a disposable, fully synthetic library root. It never reads the real Mirage
library, never touches ``/Applications/PKD.app`` and never changes system
accessibility preferences.

Concurrency: at most one agent may drive the GUI at a time. Every driver wraps
its whole launch/drive/quit sequence in :class:`DriveLock` so keyboard and
scroll events (which are global) cannot be stolen by a second run.

CLI:
    python3 tools/dev/perf-qaenv.py assemble <dest.app>   # Lead-only rebuild
    python3 tools/dev/perf-qaenv.py doctor                # environment check
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import datetime
import json
import os
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
QA_ROOT = REPO / "app/.build/ui-qa"
DATA = QA_ROOT / "data"
RUNS = QA_ROOT / "runs"
EVIDENCE = QA_ROOT / "evidence"
LOCK_DIR = QA_ROOT / "lock/drive"
SKELETON = QA_ROOT / "bundle-skeleton/PKD QA.app"
DEV_BUNDLE_ID = "com.zeh.pkd.development"
WINDOW_TITLE = "PKD 开发预览"
APP_NAME = "PKD QA.app"

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
_libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                               ctypes.c_void_p, ctypes.c_int]


# ---------------------------------------------------------------------------
# app bundle
# ---------------------------------------------------------------------------

def ensure_skeleton() -> Path:
    """Create the development bundle skeleton once from the existing dev copy."""
    if SKELETON.exists():
        return SKELETON
    source = REPO / "app/.build/private-development/PKD Development.app"
    if not source.exists():
        raise SystemExit(
            "missing development bundle; run tools/dev/launch.sh once to create "
            f"{source}"
        )
    SKELETON.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, SKELETON, symlinks=True)
    return SKELETON


def assemble_app(dest: Path, build: bool = False, binary: Path | None = None) -> Path:
    """Assemble a dev bundle from a release binary (Lead only).

    ``binary`` lets a run pin the exact executable it benchmarks, so builds by
    other workstreams in the shared tree cannot silently swap the measured code.
    """
    if build:
        # This harness may run under a Rosetta Python whose children would
        # otherwise inherit x86_64 and break the arm64 Swift toolchain.
        result = subprocess.run(
            ["arch", "-arm64", "/usr/bin/swift", "build", "-c", "release",
             "--disable-sandbox", "--product", "PKD"],
            cwd=REPO / "app", capture_output=True, text=True,
        )
        if result.returncode != 0:
            tail = "\n".join(line for line in result.stderr.splitlines()
                             if "error" in line.lower())[-3000:]
            raise SystemExit(f"release build failed:\n{tail}")
    skeleton = ensure_skeleton()
    binary = binary or (REPO / "app/.build/release/PKD")
    if not binary.exists():
        raise SystemExit(f"missing release binary {binary}")
    if dest == SKELETON:
        raise SystemExit("destination must not be the bundle skeleton")
    if dest.exists():
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(skeleton, dest, symlinks=True)
    shutil.copy2(binary, dest / "Contents/MacOS/PKD")
    version = (REPO / "VERSION").read_text().strip() or "0"
    plist = dest / "Contents/Info.plist"
    for key, value in (
        ("CFBundleIdentifier", DEV_BUNDLE_ID),
        ("CFBundleDisplayName", WINDOW_TITLE),
        ("CFBundleShortVersionString", version),
        ("CFBundleVersion", version.split(".")[0]),
        ("SUEnableAutomaticChecks", False),
    ):
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :{key} {value}", str(plist)],
                       check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", DEV_BUNDLE_ID,
                    str(dest)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", str(dest)], check=True,
                   capture_output=True)
    return dest


def verify_dev_bundle(app: Path) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != DEV_BUNDLE_ID:
        raise SystemExit(f"refusing non-development bundle: {app}")
    if not (app / "Contents/MacOS/PKD").exists():
        raise SystemExit(f"bundle has no executable: {app}")


# ---------------------------------------------------------------------------
# serialized GUI driving
# ---------------------------------------------------------------------------

class DriveLock:
    """Directory lock shared by every GUI-driving agent.

    The holder refreshes the directory mtime every 15 s; a waiter only steals the
    lock when the heartbeat has been quiet for ``stale`` seconds. Without the
    heartbeat a single long batch (4-minute soak) looked "stale" after 240 s and
    two agents ended up driving the GUI at once.
    """

    HEARTBEAT_SECONDS = 15.0

    def __init__(self, timeout: float = 1800.0, stale: float = 900.0):
        self.timeout = timeout
        self.stale = stale
        self.acquired = False
        self._stop = None
        self._thread = None

    def __enter__(self) -> "DriveLock":
        import threading
        LOCK_DIR.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                LOCK_DIR.mkdir()
                (LOCK_DIR / "owner").write_text(
                    json.dumps({"pid": os.getpid(), "at": time.time(),
                                "argv": sys.argv[:3]}),
                    encoding="utf-8",
                )
                self.acquired = True
                self._stop = threading.Event()
                self._thread = threading.Thread(target=self._heartbeat, daemon=True)
                self._thread.start()
                return self
            except FileExistsError:
                try:
                    age = time.time() - LOCK_DIR.stat().st_mtime
                except FileNotFoundError:
                    continue
                if age > self.stale:
                    shutil.rmtree(LOCK_DIR, ignore_errors=True)
                    continue
                if time.monotonic() > deadline:
                    raise SystemExit(f"GUI drive lock held for {age:.0f}s: {LOCK_DIR}")
                time.sleep(0.5)

    def _heartbeat(self) -> None:
        assert self._stop is not None
        while not self._stop.wait(self.HEARTBEAT_SECONDS):
            try:
                os.utime(LOCK_DIR, None)
            except (FileNotFoundError, PermissionError):
                return

    def __exit__(self, *exc) -> None:
        if self.acquired:
            if self._stop is not None:
                self._stop.set()
            if self._thread is not None:
                self._thread.join(timeout=2)
            shutil.rmtree(LOCK_DIR, ignore_errors=True)
            self.acquired = False


# ---------------------------------------------------------------------------
# disposable library roots
# ---------------------------------------------------------------------------

def fresh_root(tag: str, base: Path | None = None) -> Path:
    base = base or (DATA / "library-400")
    if not (base / "Library").exists():
        raise SystemExit(f"missing base fixture library {base}; run tools/dev/perf-fixtures.py")
    RUNS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%H%M%S")
    root = RUNS / f"run-{tag}-{stamp}-{os.getpid()}"
    root.mkdir(parents=True)
    shutil.copytree(base / "Library", root / "Library")
    for name in ("Logs", "History", "Cache", "Images", "Extracted", "Incoming"):
        (root / name).mkdir()
    shutil.copy2(base / "fixtures.json", root / "fixtures.json")
    return root


# ---------------------------------------------------------------------------
# launching / quitting
# ---------------------------------------------------------------------------

def launch(app: Path, root: Path, extra_env: dict[str, str] | None = None,
           tag: str = "app", wait: float = 90.0) -> subprocess.Popen:
    verify_dev_bundle(app)
    root.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PKD_DEVELOPMENT_ROOT"] = str(root)
    env.update(extra_env or {})
    log = (root / f"{tag}.log").open("w")
    process = subprocess.Popen(
        [str(app / "Contents/MacOS/PKD")], env=env,
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
    )
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"app exited early: {root / (tag + '.log')}")
        if window_id(process.pid):
            return process
        time.sleep(0.2)
    quit_app(process)
    raise RuntimeError(f"app window never appeared: {root / (tag + '.log')}")


def quit_app(process: subprocess.Popen, timeout: float = 8.0) -> None:
    if process.poll() is not None:
        return
    try:
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=timeout)


def activate(pid: int) -> None:
    import AppKit
    running = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
    if running is None:
        raise RuntimeError(f"pid {pid} is gone")
    running.activateWithOptions_(AppKit.NSApplicationActivateAllWindows)
    time.sleep(0.25)


# ---------------------------------------------------------------------------
# window + screenshots (window-only captures, never the desktop)
# ---------------------------------------------------------------------------

def windows(pid: int) -> list[dict]:
    import Quartz
    result = []
    infos = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )
    for info in infos:
        if info.get("kCGWindowOwnerPID") != pid:
            continue
        frame = info.get("kCGWindowBounds") or {}
        result.append({
            "id": int(info.get("kCGWindowNumber", 0)),
            "title": info.get("kCGWindowName") or "",
            "layer": int(info.get("kCGWindowLayer", 0)),
            "frame": {k: float(frame.get(k, 0)) for k in ("X", "Y", "Width", "Height")},
        })
    return result


def window_id(pid: int) -> int | None:
    candidates = [w for w in windows(pid) if w["layer"] == 0 and w["title"]]
    if not candidates:
        return None
    candidates.sort(key=lambda w: w["frame"]["Width"] * w["frame"]["Height"], reverse=True)
    return candidates[0]["id"]


def main_window(pid: int) -> dict:
    ident = window_id(pid)
    for window in windows(pid):
        if window["id"] == ident:
            return window
    raise RuntimeError(f"no main window for pid {pid}")


def capture_cgimage(pid: int):
    """Fast window-only capture (CGWindowListCreateImage); ~10-40 ms on this host.

    Never captures the desktop: only the requested window ID is included.
    """
    import Quartz
    ident = window_id(pid)
    if ident is None:
        raise RuntimeError("no window to capture")
    image = Quartz.CGWindowListCreateImage(
        Quartz.CGRectNull, Quartz.kCGWindowListOptionIncludingWindow, ident,
        Quartz.kCGWindowImageBoundsIgnoreFraming,
    )
    if image is None:
        raise RuntimeError("CGWindowListCreateImage returned nil")
    return image


def capture_png(pid: int, path: Path) -> Path:
    """Write one fast window capture as PNG (for animation sampling)."""
    import AppKit
    image = capture_cgimage(pid)
    rep = AppKit.NSBitmapImageRep.alloc().initWithCGImage_(image)
    data = rep.representationUsingType_properties_(
        AppKit.NSBitmapImageFileTypePNG, {})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(data))
    return path


def frame_bytes(pid: int, divisor: int = 4) -> tuple[int, int, bytes]:
    """Grey, downscaled window pixels for animation sampling without PNG cost.

    Typical cost is ~15-30 ms per frame on this host, so a 240 ms transition can
    be sampled several times even though a PNG write is ~100 ms.
    """
    import Quartz
    image = capture_cgimage(pid)
    width = max(1, Quartz.CGImageGetWidth(image) // divisor)
    height = max(1, Quartz.CGImageGetHeight(image) // divisor)
    space = Quartz.CGColorSpaceCreateDeviceGray()
    # Supply our own buffer: pyobjc returns CGBitmapContextGetData as an
    # objc.varlist that ctypes cannot read, but writing into a ctypes buffer
    # owned here is cheap and stable.
    buffer = ctypes.create_string_buffer(width * height)
    context = Quartz.CGBitmapContextCreate(
        buffer, width, height, 8, width, space, Quartz.kCGImageAlphaNone
    )
    if context is None:
        raise RuntimeError("CGBitmapContextCreate failed")
    Quartz.CGContextDrawImage(context, Quartz.CGRectMake(0, 0, width, height), image)
    return width, height, buffer.raw[: width * height]


def frame_diff(before: tuple[int, int, bytes], after: tuple[int, int, bytes],
               threshold: int = 8) -> dict:
    if before[0] != after[0] or before[1] != after[1]:
        return {"sameSize": False}
    a, b = before[2], after[2]
    changed = 0
    worst = 0
    for x, y in zip(a, b):
        delta = x - y if x > y else y - x
        if delta > threshold:
            changed += 1
        if delta > worst:
            worst = delta
    total = max(1, before[0] * before[1])
    return {
        "sameSize": True,
        "changedFraction": round(changed / total, 6),
        "maxChannelDelta": worst,
    }


def screenshot(path: Path, pid: int | None = None) -> Path:
    ident = window_id(pid) if pid is not None else None
    if ident is None:
        raise RuntimeError("no window to capture")
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["screencapture", "-x", "-l", str(ident), str(path)], check=True)
    return path


def image_diff(a: Path, b: Path) -> dict:
    """Pixel-difference summary of two window screenshots (same size expected)."""
    from PIL import Image, ImageChops
    first, second = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if first.size != second.size:
        return {"sameSize": False, "size": [first.size, second.size]}
    difference = ImageChops.difference(first, second)
    box = difference.getbbox()
    histogram = difference.convert("L").histogram()
    changed = sum(histogram[8:])
    total = first.size[0] * first.size[1]
    return {
        "sameSize": True,
        "changedFraction": round(changed / total, 6),
        "boundingBox": list(box) if box else None,
    }


# ---------------------------------------------------------------------------
# accessibility (read/inspect and press/set; no permission changes)
# ---------------------------------------------------------------------------

def ax_app(pid: int):
    from ApplicationServices import AXUIElementCreateApplication, AXUIElementSetMessagingTimeout
    element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 3.0)
    return element


def ax_value(element, key: str):
    from ApplicationServices import AXUIElementCopyAttributeValue
    result = AXUIElementCopyAttributeValue(element, key, None)
    if isinstance(result, tuple):
        status, value = result[0], result[1]
        return value if status == 0 else None
    return None


def ax_children(element) -> list:
    value = ax_value(element, "AXChildren")
    return list(value) if value else []


def ax_find(root, role: str | None = None, title: str | None = None,
            description: str | None = None, contains: str | None = None,
            depth_limit: int = 40):
    """Depth-first search; returns the first matching element or None."""
    stack = [(root, 0)]
    while stack:
        element, depth = stack.pop(0)
        if depth > depth_limit:
            continue
        match = True
        if role is not None and ax_value(element, "AXRole") != role:
            match = False
        if title is not None and ax_value(element, "AXTitle") != title:
            match = False
        if description is not None and ax_value(element, "AXDescription") != description:
            match = False
        if contains is not None:
            texts = [ax_value(element, "AXTitle"), ax_value(element, "AXDescription"),
                     ax_value(element, "AXValue")]
            if not any(isinstance(t, str) and contains in t for t in texts):
                match = False
        if match and (role is not None or title is not None or description is not None
                      or contains is not None):
            return element
        stack.extend((child, depth + 1) for child in ax_children(element))
    return None


def ax_tree(pid: int, max_nodes: int = 4000) -> list[dict]:
    root = ax_app(pid)
    rows: list[dict] = []
    queue = [(root, "")]
    while queue and len(rows) < max_nodes:
        element, path = queue.pop(0)
        row = {
            "path": path,
            "role": ax_value(element, "AXRole"),
            "title": ax_value(element, "AXTitle"),
            "description": ax_value(element, "AXDescription"),
            "value": (str(ax_value(element, "AXValue"))[:120]
                      if ax_value(element, "AXValue") is not None else None),
            "enabled": ax_value(element, "AXEnabled"),
            "focused": ax_value(element, "AXFocused"),
            "actions": list(ax_value(element, "AXActions") or []),
        }
        for key in ("AXMinimumValue", "AXMaximumValue"):
            pass
        rows.append(row)
        for index, child in enumerate(ax_children(element)):
            queue.append((child, f"{path}/{index}" if path else f"/{index}"))
    return rows


def ax_press(element) -> None:
    from ApplicationServices import AXUIElementPerformAction
    status = AXUIElementPerformAction(element, "AXPress")
    if int(status) != 0:
        raise RuntimeError(f"AXPress failed: {status}")


def ax_set_size(pid: int, width: float, height: float) -> None:
    from ApplicationServices import AXUIElementSetAttributeValue, AXValueCreate, kAXValueCGSizeType
    import Quartz
    element = ax_app(pid)
    window = ax_find(element, role="AXWindow")
    if window is None:
        raise RuntimeError("no AXWindow")
    # pyobjc takes the CGSize itself (passing byref raises "must be a ctypes instance")
    value = AXValueCreate(kAXValueCGSizeType, Quartz.CGSizeMake(width, height))
    status = AXUIElementSetAttributeValue(window, "AXSize", value)
    if int(status) != 0:
        raise RuntimeError(f"AXSize failed: {status}")


def ax_frame(pid: int) -> dict:
    return main_window(pid)["frame"]


def ax_latency(pid: int, samples: int = 40) -> list[float]:
    """Round-trip time of a trivial AX query; a coarse main-thread responsiveness proxy."""
    from ApplicationServices import AXUIElementCopyAttributeValue
    element = ax_app(pid)
    times = []
    for _ in range(samples):
        started = time.perf_counter()
        AXUIElementCopyAttributeValue(element, "AXTitle", None)
        times.append((time.perf_counter() - started) * 1000)
    return times


# ---------------------------------------------------------------------------
# synthetic input (global; only used while holding DriveLock and with the dev
# app frontmost)
# ---------------------------------------------------------------------------

KEY_CODES = {
    "return": 0x24, "tab": 0x30, "space": 0x31, "escape": 0x35,
    "delete": 0x33, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "o": 0x1F, "r": 0x0F, "l": 0x25, "comma": 0x2B, "period": 0x2F,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
    "s": 0x01, "k": 0x28, "a": 0x00, "f": 0x03,
}


def key(name: str, command: bool = False, shift: bool = False, option: bool = False,
        control: bool = False, repeat: int = 1, delay: float = 0.04) -> None:
    import Quartz
    code = KEY_CODES[name]
    flags = 0
    if command:
        flags |= Quartz.kCGEventFlagMaskCommand
    if shift:
        flags |= Quartz.kCGEventFlagMaskShift
    if option:
        flags |= Quartz.kCGEventFlagMaskAlternate
    if control:
        flags |= Quartz.kCGEventFlagMaskControl
    for _ in range(repeat):
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            if flags:
                Quartz.CGEventSetFlags(event, flags)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
            time.sleep(delay)
        time.sleep(0.03)


def key_to_pid(pid: int, name: str, command: bool = False, shift: bool = False,
               option: bool = False, control: bool = False, repeat: int = 1) -> None:
    """Deliver key events straight to one process (CGEventPostToPid).

    Unlike global HID posting this does not rely on the app being frontmost, which
    matters on a machine where another app's full-screen overlay owns the screen.
    """
    import Quartz
    code = KEY_CODES[name]
    flags = 0
    if command:
        flags |= Quartz.kCGEventFlagMaskCommand
    if shift:
        flags |= Quartz.kCGEventFlagMaskShift
    if option:
        flags |= Quartz.kCGEventFlagMaskAlternate
    if control:
        flags |= Quartz.kCGEventFlagMaskControl
    for _ in range(repeat):
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            if flags:
                Quartz.CGEventSetFlags(event, flags)
            Quartz.CGEventPostToPid(pid, event)
            time.sleep(0.03)
        time.sleep(0.05)


def ax_focus(element) -> None:
    from ApplicationServices import AXUIElementSetAttributeValue
    status = AXUIElementSetAttributeValue(element, "AXFocused", True)
    if int(status) != 0:
        raise RuntimeError(f"AXFocused failed: {status}")


def ax_focused_element(pid: int):
    value = ax_value(ax_app(pid), "AXFocusedUIElement")
    return value


def type_text(text: str) -> None:
    import Quartz
    for character in text:
        event = Quartz.CGEventCreateKeyboardEvent(None, 0, True)
        Quartz.CGEventKeyboardSetUnicodeString(event, len(character), character)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        event = Quartz.CGEventCreateKeyboardEvent(None, 0, False)
        Quartz.CGEventKeyboardSetUnicodeString(event, len(character), character)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.02)


def scroll(pid: int, lines: int, points: float | None = None, x: float | None = None,
           y: float | None = None, delay: float = 0.01) -> None:
    """Scroll the main window; repeated wheel ticks when ``lines`` is large."""
    import Quartz
    frame = main_window(pid)["frame"]
    point = (x if x is not None else frame["X"] + frame["Width"] / 2,
             y if y is not None else frame["Y"] + frame["Height"] / 2)
    Quartz.CGWarpMouseCursorPosition(Quartz.CGPointMake(*point))
    time.sleep(0.1)
    for _ in range(abs(lines)):
        event = Quartz.CGEventCreateScrollWheelEvent(
            None, Quartz.kCGScrollEventUnitLine, 1, 1 if lines > 0 else -1
        )
        Quartz.CGEventSetLocation(event, Quartz.CGPointMake(*point))
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(delay)


def click(pid: int, x: float, y: float, count: int = 1, command: bool = False,
          shift: bool = False) -> None:
    import Quartz
    flags = 0
    if command:
        flags |= Quartz.kCGEventFlagMaskCommand
    if shift:
        flags |= Quartz.kCGEventFlagMaskShift
    point = Quartz.CGPointMake(x, y)
    Quartz.CGWarpMouseCursorPosition(point)
    time.sleep(0.05)
    for _ in range(count):
        for down in (True, False):
            event = Quartz.CGEventCreateMouseEvent(
                None, Quartz.kCGEventLeftMouseDown if down else Quartz.kCGEventLeftMouseUp,
                point, Quartz.kCGMouseButtonLeft
            )
            if flags:
                Quartz.CGEventSetFlags(event, flags)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
            time.sleep(0.02)
        time.sleep(0.06)


# ---------------------------------------------------------------------------
# metrics
# ---------------------------------------------------------------------------

_RUSAGE_BUFFER = 2048  # RUSAGE_INFO_V4 spills well past 80 bytes; never undersize


def _ticks_per_second() -> float:
    """Apple Silicon accounts ri_*_time in mach ticks at hw.tbfrequency (24 MHz here), not ns.

    Treating the raw value as nanoseconds under-reports CPU by ~42x on Apple Silicon.
    """
    try:
        value = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.tbfrequency"],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        ticks = float(value)
        if ticks > 0:
            return ticks
    except Exception:
        pass
    return 1e9


_TICKS_PER_SECOND = _ticks_per_second()


def rusage(pid: int) -> dict:
    import struct
    buffer = ctypes.create_string_buffer(_RUSAGE_BUFFER)
    if _libc.proc_pid_rusage(pid, 4, ctypes.byref(buffer)) != 0:
        raise RuntimeError(f"proc_pid_rusage failed for {pid}: errno {ctypes.get_errno()}")
    raw = buffer.raw
    user_ticks, system_ticks, pkg_idle, interrupt, pageins, _wired, resident, footprint = \
        struct.unpack_from("<8Q", raw, 16)
    scale = 1.0 / _TICKS_PER_SECOND
    task_buffer = ctypes.create_string_buffer(128)
    threads = None
    if _libc.proc_pidinfo(pid, 4, 0, ctypes.byref(task_buffer), 96) > 0:
        fields = struct.unpack_from("<12i", task_buffer.raw, 48)
        threads = fields[9]
    return {
        "userTime": user_ticks * scale,
        "systemTime": system_ticks * scale,
        "footprintBytes": int(footprint),
        "residentBytes": int(resident),
        "wakeups": int(pkg_idle + interrupt),
        "pageins": int(pageins),
        "threads": threads,
        "ticksPerSecond": _TICKS_PER_SECOND,
    }


class Monitor:
    """Samples CPU / footprint / thread / wakeup deltas at a fixed interval."""

    def __init__(self, pid: int, interval: float = 0.1):
        self.pid = pid
        self.interval = interval
        self.samples: list[dict] = []
        self._thread = None
        self._stop = False

    def _run(self) -> None:
        previous = rusage(self.pid)
        previous_at = time.monotonic()
        while not self._stop:
            time.sleep(self.interval)
            now = time.monotonic()
            try:
                current = rusage(self.pid)
            except RuntimeError:
                break
            elapsed = now - previous_at
            self.samples.append({
                "at": round(now, 4),
                "cpuPercent": round(
                    ((current["userTime"] - previous["userTime"])
                     + (current["systemTime"] - previous["systemTime"]))
                    / elapsed * 100, 2),
                "footprintBytes": current["footprintBytes"],
                "threads": current["threads"],
                "wakeups": current["wakeups"] - previous["wakeups"],
                "pageins": current["pageins"] - previous["pageins"],
            })
            previous = current
            previous_at = now

    def __enter__(self) -> "Monitor":
        import threading
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop = True
        if self._thread:
            self._thread.join(timeout=2)

    def summary(self) -> dict:
        if not self.samples:
            return {"samples": 0}
        cpu = [s["cpuPercent"] for s in self.samples]
        footprint = [s["footprintBytes"] for s in self.samples]
        threads = [s["threads"] for s in self.samples if s["threads"] is not None]
        return {
            "samples": len(self.samples),
            "cpuPercent": _stats(cpu),
            "footprintBytes": {
                "max": max(footprint), "last": footprint[-1],
                "first": footprint[0],
            },
            "threads": {"max": max(threads), "min": min(threads)} if threads else None,
            "wakeupsPerSecond": round(sum(s["wakeups"] for s in self.samples)
                                      / max(0.001, self.interval * len(self.samples)), 1),
        }


def footprint(pid: int) -> dict:
    try:
        output = subprocess.run(["/usr/bin/footprint", str(pid)], capture_output=True,
                                text=True, timeout=30).stdout
    except Exception as error:  # pragma: no cover - tool failure
        return {"error": str(error)}
    result = {}
    match = re.search(r"phys_footprint:\s*([\d.]+)\s*(\w+)", output)
    if match:
        result["physFootprintText"] = f"{match.group(1)} {match.group(2)}"
    match = re.search(r"phys_footprint_peak:\s*([\d.]+)\s*(\w+)", output)
    if match:
        result["peakText"] = f"{match.group(1)} {match.group(2)}"
    return result


def sample(pid: int, seconds: int, output: Path, interval_ms: int = 5) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/sample", str(pid), str(seconds), str(interval_ms),
                    "-file", str(output)], check=True, capture_output=True)
    return output


def sample_hotspots(path: Path, top: int = 25) -> list[tuple[int, str]]:
    """Rough 'heaviest leaf frames' summary from a `sample` text report."""
    counts: dict[str, int] = {}
    frame_re = re.compile(r"^\s+(?:\+ !?|\+|-|\|)?\s*[!:|+\s]*(\d+)\s+(.+?)\s+\(in\s")
    for line in path.read_text(errors="replace").splitlines():
        if "Thread_" in line or "Binary Images" in line or line.startswith("Sampling"):
            continue
        match = frame_re.match(line)
        if match:
            counts[match.group(2)[:110]] = max(counts.get(match.group(2)[:110], 0),
                                               int(match.group(1)))
    return sorted(((v, k) for k, v in counts.items()), reverse=True)[:top]


# ---------------------------------------------------------------------------
# Core Animation signposts: transaction commits and CA-reported stalls
# ---------------------------------------------------------------------------

SIGNPOST_RE = re.compile(
    r"(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) Sp PKD\[(?P<pid>\d+):\w+\] "
    r"\[com\.apple\.coreanimation:(?P<kind>Transaction(?:\.Stalls)?)\].*?"
    r"begin_time#_##_#(?P<begin>\d+)##"
)


class Signposts:
    """Captures CA transaction signposts while holding a handle to the app."""

    def __init__(self, pid: int, output: Path):
        self.pid = pid
        self.output = output
        self.process: subprocess.Popen | None = None

    def __enter__(self) -> "Signposts":
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.process = subprocess.Popen(
            ["log", "stream", "--signpost", "--style", "compact",
             "--predicate", f"processID == {self.pid}"],
            stdout=self.output.open("w"), stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(0.4)
        return self

    def __exit__(self, *exc) -> None:
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def parse(self) -> dict:
        commits: list[int] = []
        stalls: list[int] = []
        if not self.output.exists():
            return {"commits": 0, "stalls": 0}
        for line in self.output.read_text(errors="replace").splitlines():
            match = SIGNPOST_RE.search(line)
            if not match:
                continue
            begin = int(match.group("begin"))
            if match.group("kind") == "Transaction.Stalls":
                stalls.append(begin)
            else:
                commits.append(begin)
        all_times = sorted(commits + stalls)
        intervals = [(all_times[i] - all_times[i - 1]) / 1e6
                     for i in range(1, len(all_times))]
        return {
            "commits": len(commits),
            "stalls": len(stalls),
            "stallTimes": stalls[:200],
            "commitSpanMs": round((max(all_times) - min(all_times)) / 1e6, 2)
            if all_times else 0,
            "intervalMs": _stats(intervals) if intervals else None,
        }


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _stats(values: list[float]) -> dict:
    ordered = sorted(values)
    def percentile(p: float) -> float:
        if not ordered:
            return 0.0
        index = min(len(ordered) - 1, max(0, int(round(p * (len(ordered) - 1)))))
        return round(ordered[index], 2)
    return {
        "n": len(ordered),
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "worst": round(ordered[-1], 2) if ordered else 0.0,
        "mean": round(statistics.fmean(ordered), 2) if ordered else 0.0,
    }


def write_json(path: Path, payload: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True),
                    encoding="utf-8")
    return path


def doctor() -> dict:
    from PIL import Image  # noqa: F401
    import Quartz  # noqa: F401
    import ApplicationServices  # noqa: F401
    return {
        "repo": str(REPO),
        "qaRoot": str(QA_ROOT),
        "skeleton": SKELETON.exists(),
        "baseLibrary": (DATA / "library-400/Library").exists(),
        "tools": {name: shutil.which(name) for name in
                  ("screencapture", "sample", "footprint", "log", "swift")},
        "pyobjc": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    assemble = sub.add_parser("assemble", help="rebuild the QA dev bundle (Lead only)")
    assemble.add_argument("dest", type=Path)
    assemble.add_argument("--no-build", action="store_true")
    assemble.add_argument("--binary", type=Path, default=None,
                          help="pin an already-built PKD executable")
    sub.add_parser("doctor", help="check harness prerequisites")
    args = parser.parse_args()

    if args.command == "assemble":
        print(assemble_app(args.dest, build=not args.no_build, binary=args.binary))
    elif args.command == "doctor":
        print(json.dumps(doctor(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
