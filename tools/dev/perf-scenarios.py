#!/usr/bin/env python3
"""Independent UI performance scenarios for the PKD development copy.

Only measures; it never builds, edits product sources, or touches the real
Mirage library. Everything is wrapped in the shared ``DriveLock`` and every
launched app is always quit.

Scenarios (each repeat uses its own disposable ``runs/`` root and a freshly
launched app):

    S1  big-library first load + idle baseline
    S2  continuous scrolling (20 down / 20 up / 6 back-and-forth rounds)
    S3  24-step window resizing across four sizes
    S4  grid density switching (compact / standard / comfortable)
    S5  sort switching (title A-Z / size desc / id asc / size asc)
    S6  inspector toggling (cmd-opt-L and the toolbar button)
    S7  appearance matrix (theme x font scale x thumbnails) with a short scroll
    S8  reduced motion (pkd.appearance.motion = off) repeating S4/S5/S6
    S9  4-minute mixed loop, 2 s sampling of footprint / threads / wakeups
    S10 selection + extraction (card press, cmd multi-select, cmd-return, cancel)

Measurement honesty: there is no Instruments here, so "frames" are *proxies*:
Core Animation ``Transaction`` signpost commit instants (``begin_time``, not the
log line timestamp) and CA's self-reported ``Transaction.Stalls``. CPU is
user+sys from ``proc_pid_rusage`` divided by wall clock. Memory is
``ri_phys_footprint`` cross-checked with ``/usr/bin/footprint``. None of this is
a presented frame rate.

Usage:
    python3 tools/dev/perf-scenarios.py --label baseline-2010
    python3 tools/dev/perf-scenarios.py --app path/to/other.app --label after-fix
    python3 tools/dev/perf-scenarios.py --only S1,S2--repeat 3
"""
from __future__ import annotations

import argparse
import ctypes
import datetime
import importlib.util
import json
import os
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

sys.dont_write_bytecode = True

# The only interpreter on this host carrying PyObjC is a Rosetta Python 3.9.
# Loading PyObjC class extensions lazily while the cyclic GC is running has been
# observed to crash that interpreter (PyObjC_CallClassExtender -> update_subclasses
# -> _PyObject_Realloc); the harness disables the cyclic collector and preloads the
# bridges instead. This affects only the measuring process, never the app.
import gc  # noqa: E402
gc.disable()
import AppKit  # noqa: F401,E402
import ApplicationServices  # noqa: F401,E402
import Quartz  # noqa: F401,E402

REPO = Path(__file__).resolve().parents[2]
DOMAIN = "com.zeh.pkd.development"
DEFAULT_APP = REPO / "app/.build/ui-qa/app/PKD QA.app"
FIXTURE_BASE = REPO / "app/.build/ui-qa/data/library-400"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


qa = _load("qa", REPO / "tools/dev/perf-qaenv.py")

# ---------------------------------------------------------------------------
# memory-safe task counters
#
# ``perf_qaenv.rusage`` passes an 80-byte struct to proc_pid_rusage(RUSAGE_INFO_V4),
# which copies out far more than that (undefined behaviour; it crashed this Python
# intermittently), and it divides Apple Silicon mach ticks by 1e9 (the tick is
# 1/hw.tbfrequency = 41.667 ns here), under-reporting CPU by ~42x. Both are wrapped
# here instead of editing the shared module -- reported to the Lead.
# ---------------------------------------------------------------------------

import struct  # noqa: E402

_RUSAGE_BUFFER = ctypes.create_string_buffer(4096)
_TASK_BUFFER = ctypes.create_string_buffer(256)


def _sysctl_int(name: str, fallback: int) -> int:
    try:
        value = subprocess.run(["sysctl", "-n", name], capture_output=True,
                               text=True).stdout.strip()
        return int(value) if value else fallback
    except Exception:
        return fallback


TICKS_PER_SECOND = _sysctl_int("hw.tbfrequency", 1_000_000_000) or 1_000_000_000


def _u64(offset: int) -> int:
    return struct.unpack_from("<Q", _RUSAGE_BUFFER.raw, offset)[0]


def rusage(pid: int) -> dict:
    """CPU ticks / footprint / wakeups for one pid in real units (ns -> s)."""
    if qa._libc.proc_pid_rusage(pid, 4, _RUSAGE_BUFFER) != 0:
        raise RuntimeError(f"proc_pid_rusage failed for {pid}")
    threads = None
    if qa._libc.proc_pidinfo(pid, 4, 0, _TASK_BUFFER, 96) > 0:
        threads = struct.unpack_from("<12i", _TASK_BUFFER.raw, 48)[9]
    scale = 1.0 / TICKS_PER_SECOND
    return {
        "userTime": _u64(16) * scale,
        "systemTime": _u64(24) * scale,
        "pkgIdleWakeups": _u64(32),
        "interruptWakeups": _u64(40),
        "wakeups": _u64(32) + _u64(40),
        "pageins": _u64(48),
        "wiredBytes": _u64(56),
        "residentBytes": _u64(64),
        "footprintBytes": _u64(72),
        "threads": threads,
        "cpuSeconds": (_u64(16) + _u64(24)) * scale,
    }


class Monitor:
    """Samples CPU / footprint / threads / wakeups on a background thread."""

    def __init__(self, pid: int, interval: float = 0.1):
        self.pid = pid
        self.interval = interval
        self.samples: list[dict] = []
        self._thread = None
        self._stop = False

    def _run(self) -> None:
        try:
            previous = rusage(self.pid)
            previous_at = time.monotonic()
        except RuntimeError:
            return
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
                "cpuPercent": round((current["cpuSeconds"] - previous["cpuSeconds"])
                                    / elapsed * 100, 2) if elapsed > 0 else 0.0,
                "footprintBytes": current["footprintBytes"],
                "threads": current["threads"],
                "wakeups": current["wakeups"] - previous["wakeups"],
                "pageins": current["pageins"] - previous["pageins"],
            })
            previous, previous_at = current, now

    def __enter__(self) -> "Monitor":
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
        footprint = [s["footprintBytes"] for s in self.samples]
        threads = [s["threads"] for s in self.samples if s["threads"] is not None]
        return {
            "samples": len(self.samples),
            "cpuPercent": stats([s["cpuPercent"] for s in self.samples]),
            "footprintBytes": {"max": max(footprint), "last": footprint[-1],
                               "first": footprint[0]},
            "threads": {"max": max(threads), "min": min(threads)} if threads else None,
            "wakeupsPerSecond": round(sum(s["wakeups"] for s in self.samples)
                                      / max(0.001, self.interval * len(self.samples)), 1),
        }


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def stats(values) -> dict:
    values = [float(v) for v in values if v is not None]
    ordered = sorted(values)

    def pct(p: float) -> float:
        if not ordered:
            return 0.0
        index = min(len(ordered) - 1, max(0, int(round(p * (len(ordered) - 1)))))
        return round(ordered[index], 2)

    return {
        "n": len(ordered),
        "p50": pct(0.50),
        "p95": pct(0.95),
        "worst": round(ordered[-1], 2) if ordered else 0.0,
        "mean": round(statistics.fmean(ordered), 2) if ordered else 0.0,
        "min": round(ordered[0], 2) if ordered else 0.0,
    }


def json_safe(value):
    """Make plist/bytes-bearing structures JSON-serialisable."""
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    if isinstance(value, bytes):
        return {"__bytes_hex__": value.hex()[:400], "length": len(value)}
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    return str(value)


def write_json(path: Path, payload) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(json_safe(payload), ensure_ascii=False, indent=2,
                               sort_keys=True), encoding="utf-8")
    return path


def sha256(path: Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def default_domain_snapshot() -> dict:
    result = subprocess.run(["defaults", "export", DOMAIN, "-"],
                            capture_output=True)
    if result.returncode != 0 or not result.stdout:
        return {}
    try:
        return plistlib.loads(result.stdout)
    except Exception:
        return {"_unparsed": True}


def write_default(key: str, value) -> None:
    kind = "bool" if isinstance(value, bool) else "string"
    subprocess.run(["defaults", "write", DOMAIN, key, "-" + kind, str(value).lower()
                    if isinstance(value, bool) else str(value)], check=True,
                   capture_output=True)


def delete_default(key: str) -> None:
    subprocess.run(["defaults", "delete", DOMAIN, key], capture_output=True)


# ---------------------------------------------------------------------------
# window / AX wrappers
#
# NOTE: the shared module's ``ax_set_size`` uses ``Quartz.kAXValueCGSizeType``,
# which does not exist (the constant lives in ApplicationServices), so it raises
# AttributeError before touching the window. Reported to the Lead; wrapped here
# instead of editing the shared file.
# ---------------------------------------------------------------------------

def _ax_set_size(pid: int, width: float, height: float) -> None:
    import Quartz
    from ApplicationServices import (AXUIElementSetAttributeValue, AXValueCreate,
                                     kAXValueCGSizeType)
    window = qa.ax_find(qa.ax_app(pid), role="AXWindow")
    if window is None:
        raise RuntimeError("no AXWindow")
    value = AXValueCreate(kAXValueCGSizeType, Quartz.CGSizeMake(float(width), float(height)))
    status = int(AXUIElementSetAttributeValue(window, "AXSize", value))
    if status != 0:
        raise RuntimeError(f"AXSize failed: {status}")


class EnvironmentBlocked(RuntimeError):
    """The GUI cannot be driven right now (another app owns focus/overlays)."""


def frontmost_app() -> tuple:
    import AppKit
    app = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
    if app is None:
        return (None, None)
    return (app.localizedName(), int(app.processIdentifier()))


def environment_state(pid: int) -> dict:
    """Who owns focus and what sits in front of the measured window.

    Synthetic keys/wheels/clicks are global: if another app (or a floating
    layer>=1 window of one) is in front, every interaction scenario silently
    measures nothing. Observed on this host: a full-screen layer-999 overlay
    ("桌面端直播间") plus a music app taking focus; NSRunningApplication
    activate() and the AX AXFrontmost write both failed to take it back.
    """
    name, fpid = frontmost_app()
    ours = qa.window_id(pid)
    above = []
    import Quartz
    infos = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    for info in infos:
        if int(info.get("kCGWindowNumber", 0)) == ours:
            break
        frame = info.get("kCGWindowBounds") or {}
        above.append({
            "owner": info.get("kCGWindowOwnerName"),
            "title": info.get("kCGWindowName") or "",
            "layer": int(info.get("kCGWindowLayer", 0)),
            "frame": [float(frame.get(k, 0)) for k in ("X", "Y", "Width", "Height")],
        })
    alive = True
    if isinstance(fpid, int) and fpid != pid:
        try:
            os.kill(fpid, 0)
        except ProcessLookupError:
            alive = False
        except PermissionError:
            pass
    return {
        "frontmostName": name,
        "frontmostPid": fpid,
        "frontmostAlive": alive,
        "appPid": pid,
        # LaunchServices can keep pointing at an app that already exited; that is
        # a stale record, not a competing driver.
        "frontmostIsApp": fpid == pid or not alive,
        "noWindowAboveAtLayer0": not any(row["layer"] == 0 for row in above),
        "overlaysAbove": [row for row in above if row["layer"] >= 1][:6],
        "windowsAbove": above[:8],
    }


SYSTEM_CHROME = {"Window Server", "程序坞", "Dock", "Menubar", "Control Center",
                 "控制中心", "WindowManager", "Window Manager"}


def window_occlusion(pid: int) -> dict:
    """How much of the measured window is covered by *other apps'* layer>=1 windows.

    A fully covered window stops drawing, which would make every frame proxy
    meaningless even though CPU sampling still works.
    """
    import Quartz
    ours = qa.window_id(pid)
    try:
        frame = qa.main_window(pid)["frame"]
    except RuntimeError as error:
        # window on an inactive Space or hidden: treat as fully covered
        return {"coveredFraction": 1.0, "error": str(error), "windowsAbove": []}
    infos = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    above = []
    for info in infos:
        if int(info.get("kCGWindowNumber", 0)) == ours:
            break
        owner = info.get("kCGWindowOwnerName") or ""
        layer = int(info.get("kCGWindowLayer", 0))
        if owner in SYSTEM_CHROME:
            continue
        bounds = info.get("kCGWindowBounds") or {}
        above.append({"owner": owner, "layer": layer, "title": info.get("kCGWindowName") or "",
                      "frame": [float(bounds.get(k, 0)) for k in ("X", "Y", "Width", "Height")]})
    grid_x, grid_y = 24, 16
    covered = 0
    for gy in range(grid_y):
        for gx in range(grid_x):
            x = frame["X"] + (gx + 0.5) * frame["Width"] / grid_x
            y = frame["Y"] + (gy + 0.5) * frame["Height"] / grid_y
            for row in above:
                wx, wy, ww, wh = row["frame"]
                if layer_ok(row) and wx <= x <= wx + ww and wy <= y <= wy + wh:
                    covered += 1
                    break
    return {"coveredFraction": round(covered / (grid_x * grid_y), 3),
            "windowsAbove": above[:6]}


def layer_ok(row: dict) -> bool:
    return row.get("layer", 0) >= 1


def ensure_driveable(ctx: "Context", pid: int, attempts: int = 5,
                     delay: float = 1.5) -> dict:
    state = environment_state(pid)
    for _ in range(attempts):
        if state["frontmostIsApp"]:
            return state
        try:
            qa.activate(pid)
        except Exception:
            pass
        time.sleep(delay)
        state = environment_state(pid)
    ctx.anomaly("environment-blocked",
                f"frontmost={state['frontmostName']} pid={state['frontmostPid']} "
                f"(app pid {pid}); overlays={state['overlaysAbove'][:2]}")
    return state


def is_frontmost(pid: int) -> bool:
    return qa.ax_value(qa.ax_app(pid), "AXFrontmost") is True


def ensure_frontmost(pid: int, attempts: int = 4) -> bool:
    """Synthetic keys and wheels only work when the QA app is frontmost.

    A second live instance (or any app stealing focus) silently swallows the
    events and every interaction scenario measures nothing, so this is asserted
    rather than assumed.
    """
    for _ in range(attempts):
        if is_frontmost(pid):
            return True
        try:
            qa.activate(pid)
        except Exception:
            pass
        time.sleep(0.35)
        if is_frontmost(pid):
            return True
        frame = qa.main_window(pid)["frame"]
        qa.click(pid, frame["X"] + frame["Width"] / 2, frame["Y"] + 10)
        time.sleep(0.35)
    return is_frontmost(pid)


def card_signature(pid: int) -> tuple:
    return tuple((qa.ax_value(card, "AXDescription") or "")[:40]
                 for card in visible_cards(pid))


def ax_path_check(ctx: "Context", pid: int) -> dict:
    """AX-only liveness check: open a pull-down menu and read one item back.

    Menu presses are direct accessibility calls, so they work even when a
    foreign floating window swallows the global mouse stream. Used by scenarios
    that do not need synthetic mouse input.
    """
    detail = {"axMenuPath": False}
    for _ in range(2):
        root = qa.ax_app(pid)
        buttons = ax_find_all(root, role="AXMenuButton", prefix="排序：", limit=2)
        if not buttons:
            time.sleep(0.3)
            continue
        try:
            qa.ax_press(buttons[0])
        except RuntimeError:
            continue
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            if qa.ax_find(qa.ax_app(pid), role="AXMenuItem", title="体积从大到小") is not None:
                qa.key("escape")
                detail["axMenuPath"] = True
                return detail
            time.sleep(0.08)
        qa.key("escape")
        time.sleep(0.2)
    ctx.anomaly("ax-menu-path-unavailable", "sort menu never exposed its items via AX")
    raise EnvironmentBlocked("AX menu path unavailable")


def probe_input(pid: int) -> dict:
    """Non-raising input probe used by scenarios that do not need input (S1)."""
    before = card_signature(pid)
    qa.scroll(pid, -6)
    time.sleep(0.5)
    after = card_signature(pid)
    qa.scroll(pid, 6)
    time.sleep(0.3)
    return {"changed": before != after, "cards": len(before)}


def scroll_lines(pid: int, lines: int, mode: str | None = None) -> None:
    """Scroll the grid with whichever input channel is proven to work."""
    mode = mode or getattr(ctx_scroll_mode, "mode", "hid")
    if mode == "hid":
        qa.scroll(pid, lines)
    elif mode == "ax-scroll":
        scroll_by_ax(pid, lines)
    else:
        raise EnvironmentBlocked("no working scroll input channel")


class ctx_scroll_mode:
    mode = "hid"


def verify_scroll_path(ctx: "Context", pid: int) -> dict:
    """Prove a wheel tick actually reaches the grid before measuring for real."""
    before = card_signature(pid)
    qa.scroll(pid, -5)
    time.sleep(0.45)
    after = card_signature(pid)
    detail = {"cardsBefore": len(before), "cardsAfter": len(after),
              "changed": before != after, "mode": "hid" if before != after else None}
    if detail["changed"]:
        qa.scroll(pid, 5)
        time.sleep(0.3)
        ctx.scroll_mode = "hid"
        ctx_scroll_mode.mode = "hid"
        return detail
    # HID wheel is swallowed: retry once after refocusing, then try AX scrolling
    if not getattr(ctx, "no_activate", False):
        ensure_frontmost(pid)
    qa.scroll(pid, -6)
    time.sleep(0.5)
    if card_signature(pid) != before:
        qa.scroll(pid, 6)
        time.sleep(0.3)
        detail.update({"retryChanged": True, "mode": "hid"})
        ctx.scroll_mode = "hid"
        ctx_scroll_mode.mode = "hid"
        ctx.anomaly("scroll-ineffective-recovered", "first wheel burst missed, retry worked")
        return detail
    detail["retryChanged"] = False
    ax_result = scroll_by_ax(pid, -6)
    detail["axScroll"] = ax_result
    if ax_result.get("changed"):
        ctx.scroll_mode = "ax-scroll"
        ctx_scroll_mode.mode = "ax-scroll"
        ctx.anomaly("scroll-input-substituted",
                    f"HID wheel is swallowed here; using {ax_result.get('path')} "
                    "(AX scroll bar / page keys) and labelling it in evidence")
        return detail
    ctx.anomaly("scroll-ineffective",
                "neither HID wheel nor AX scroll moved the grid (pid "
                f"{pid}); frontmost/overlay state blocks synthetic input")
    raise EnvironmentBlocked(
        "no working scroll channel: HID wheel and AX scroll both had no effect")


def set_window_size(pid: int, width: float, height: float, settle: float = 0.5):
    _ax_set_size(pid, width, height)
    time.sleep(settle)
    try:
        return qa.main_window(pid)["frame"]
    except RuntimeError:
        return None


def ax_point(value) -> tuple[float, float] | None:
    """Decode an AXValue holding a CGPoint/CGSize into a plain tuple."""
    if value is None:
        return None
    text = repr(value)
    match = re.search(r"x:\s*(-?[\d.]+)\s+y:\s*(-?[\d.]+)", text)
    if match:
        return (float(match.group(1)), float(match.group(2)))
    match = re.search(r"w:\s*(-?[\d.]+)\s+h:\s*(-?[\d.]+)", text)
    if match:
        return (float(match.group(1)), float(match.group(2)))
    return None


def element_center(element) -> tuple[float, float] | None:
    position = ax_point(qa.ax_value(element, "AXPosition"))
    size = ax_point(qa.ax_value(element, "AXSize"))
    if not position or not size:
        return None
    return (position[0] + size[0] / 2, position[1] + size[1] / 2)


def ax_find_all(root, role=None, title=None, description=None, prefix=None,
                contains=None, limit=200) -> list:
    found = []
    stack = [(root, 0)]
    while stack and len(found) < limit:
        element, depth = stack.pop(0)
        if depth > 40:
            continue
        ok = True
        if role is not None and qa.ax_value(element, "AXRole") != role:
            ok = False
        if title is not None and qa.ax_value(element, "AXTitle") != title:
            ok = False
        if description is not None and qa.ax_value(element, "AXDescription") != description:
            ok = False
        if prefix is not None:
            text = qa.ax_value(element, "AXTitle")
            if not (isinstance(text, str) and text.startswith(prefix)):
                ok = False
        if contains is not None:
            texts = [qa.ax_value(element, "AXTitle"), qa.ax_value(element, "AXDescription"),
                     qa.ax_value(element, "AXValue")]
            if not any(isinstance(t, str) and contains in t for t in texts):
                ok = False
        if ok and (role or title or description or prefix or contains):
            found.append(element)
        stack.extend((child, depth + 1) for child in qa.ax_children(element))
    return found


def choose_menu_item(pid: int, button_title: str | None = None,
                     button_prefix: str | None = None, item_title: str = "",
                     attempts: int = 2, timeout: float = 2.0) -> dict:
    """Open a SwiftUI pull-down menu through AX and press one item.

    The very first AX press after activation sometimes only raises the window,
    so the press is retried until the item is actually exposed.
    """
    details = {"button": button_title or button_prefix, "item": item_title, "attempts": 0}
    for _ in range(attempts):
        root = qa.ax_app(pid)
        if button_title:
            button = qa.ax_find(root, role="AXMenuButton", title=button_title)
        else:
            candidates = ax_find_all(root, role="AXMenuButton", prefix=button_prefix, limit=5)
            button = candidates[0] if candidates else None
        if button is None:
            details["error"] = "menu button not found"
            return details
        details["attempts"] += 1
        try:
            qa.ax_press(button)
        except RuntimeError as error:
            details["error"] = str(error)
            continue
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            item = qa.ax_find(qa.ax_app(pid), role="AXMenuItem", title=item_title)
            if item is not None:
                qa.ax_press(item)
                details["pressed"] = True
                return details
            time.sleep(0.08)
        # menu did not expose its items; dismiss and retry
        qa.key("escape")
        time.sleep(0.2)
    details.setdefault("pressed", False)
    return details


def visible_cards(pid: int) -> list:
    root = qa.ax_app(pid)
    group = qa.ax_find(root, role="AXOpaqueProviderGroup")
    if group is None:
        return []
    return [child for child in qa.ax_children(group)
            if qa.ax_value(child, "AXRole") == "AXButton"]


def static_texts(pid: int) -> list[str]:
    rows = qa.ax_tree(pid, max_nodes=600)
    return [row["value"] for row in rows
            if row["role"] == "AXStaticText" and row["value"]]


def wait_ready(pid: int, expected: str = "400 项", timeout: float = 120.0,
               settle_cpu: float = 5.0, settle_for: float = 1.2,
               max_settle: float = 25.0) -> dict:
    """Wait for the scan count, then for background work (thumbnails/X-Ray) to idle.

    Scan-complete is announced while decode work is still running -- the gap
    between the two is itself reported as ``settleMs``.
    """
    started = time.monotonic()
    detail = {"scanMs": None, "settleMs": None, "busyCpuAfterScan": None}
    while time.monotonic() - started < timeout:
        if any(expected in text for text in static_texts(pid)):
            detail["scanMs"] = round((time.monotonic() - started) * 1000)
            break
        time.sleep(0.25)
    else:
        raise RuntimeError(f"scan never reported {expected}")

    # busy CPU right after the count appears: how much work is still queued
    with Monitor(pid, 0.25) as busy:
        time.sleep(1.0)
    if busy.samples:
        detail["busyCpuAfterScan"] = stats([s["cpuPercent"] for s in busy.samples])

    deadline = time.monotonic() + max_settle
    quiet_since = None
    recent: list[dict] = []
    with Monitor(pid, 0.3) as settle:
        while time.monotonic() < deadline:
            time.sleep(0.3)
            current = settle.samples[-1] if settle.samples else None
            if current is None:
                continue
            recent.append(current)
            if current["cpuPercent"] <= settle_cpu:
                quiet_since = quiet_since or time.monotonic()
                if time.monotonic() - quiet_since >= settle_for:
                    break
            else:
                quiet_since = None
    detail["settleMs"] = round((time.monotonic() - started) * 1000)
    detail["settled"] = quiet_since is not None
    if settle.samples:
        tail = settle.samples[-4:]
        detail["idleCpuAtSettle"] = stats([s["cpuPercent"] for s in tail])
        detail["idleFootprintBytes"] = tail[-1]["footprintBytes"]
        detail["idleThreads"] = tail[-1]["threads"]
    detail["totalMs"] = round((time.monotonic() - started) * 1000)
    return detail


# ---------------------------------------------------------------------------
# measurement primitives
# ---------------------------------------------------------------------------

class CAWindow:
    """Core Animation transaction signposts captured for exactly one action."""

    def __init__(self, pid: int, directory: Path, tag: str):
        self.pid = pid
        self.directory = directory
        self.tag = tag
        self.path = directory / f"signposts-{tag}.log"
        self._inner = None
        self.started_at = None

    def __enter__(self):
        self._inner = qa.Signposts(self.pid, self.path)
        self._inner.__enter__()
        self.started_at = time.monotonic()
        return self

    def __exit__(self, *exc):
        self.stopped_at = time.monotonic()
        self._inner.__exit__(*exc)

    def result(self) -> dict:
        parsed = self._inner.parse()
        parsed["windowSeconds"] = round(self.stopped_at - self.started_at, 2)
        commits = parsed.get("commits", 0)
        stalls = parsed.get("stalls", 0)
        parsed["stallsPer100Commits"] = (round(stalls / commits * 100, 1)
                                         if commits else None)
        interval = parsed.get("intervalMs")
        if interval:
            # multi-frame animation still running if commits are spread out
            parsed["commitSpacingMs"] = {"p50": interval["p50"], "p95": interval["p95"],
                                         "worst": interval["worst"]}
        return parsed


def monitor_slice(monitor, start: float, end: float) -> dict:
    samples = [s for s in monitor.samples if start <= s["at"] <= end]
    if not samples:
        return {"samples": 0}
    return {
        "samples": len(samples),
        "cpuPercent": stats([s["cpuPercent"] for s in samples]),
        "threadsMax": max((s["threads"] for s in samples if s["threads"]), default=None),
        "footprintMax": max(s["footprintBytes"] for s in samples),
    }


def axlat(pid: int, samples: int = 40) -> dict:
    values = qa.ax_latency(pid, samples)
    return stats(values)


DECODE_PATTERNS = ("CGImageSource", "ImageIO", "IIOImageSource", "_IIO", "CGImageCreate",
                   "IMPixelAccess", "IIODecode", "ImageProvider")


LEAF_RE = re.compile(r"^\s{4,}(\S.*?)\s{2,}\(in ([^)]+)\)\s+(\d+)\s*$")


def run_sample(pid: int, seconds: int, path: Path, interval_ms: int = 5) -> subprocess.CompletedProcess:
    """`sample` must be started through `arch -arm64`.

    This measuring interpreter is a Rosetta (x86_64) Python; when it spawns
    /usr/bin/sample directly the tool ends up running translated and only reports
    "sample_remote_thread_with_frame_filter failed to get thread state", producing
    an empty call graph. Prefixing with `arch -arm64` collects normally.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    return subprocess.run(["arch", "-arm64", "/usr/bin/sample", str(pid), str(seconds),
                           str(interval_ms), "-file", str(path)],
                          capture_output=True, text=True)


def sample_report(pid: int, seconds: int, path: Path) -> dict:
    """Run `sample` and summarise leaf hotspots + decode (ImageIO) activity."""
    result = run_sample(pid, seconds, path)
    text = path.read_text(errors="replace") if path.exists() else ""
    call_graph = text.split("Call graph:", 1)[-1].split("Binary Images:", 1)[0]

    # "Sort by top of stack" is the collapsed leaf-frame histogram
    leaves = []
    sorted_section = None
    if "Sort by top of stack" in text:
        sorted_section = text.split("Sort by top of stack", 1)[-1].split("Binary Images:", 1)[0]
        for line in sorted_section.splitlines():
            match = LEAF_RE.match(line)
            if match:
                leaves.append({"leaf": match.group(1)[:120], "image": match.group(2),
                               "samples": int(match.group(3))})
        leaves.sort(key=lambda row: row["samples"], reverse=True)

    cumulative = [{"count": count, "frame": frame}
                  for count, frame in qa.sample_hotspots(path, top=12)] if text else []
    decode_hits = {name: len(re.findall(re.escape(name), call_graph))
                   for name in DECODE_PATTERNS}
    decode_hits = {k: v for k, v in decode_hits.items() if v}
    main_thread = None
    block = re.search(r"(Thread_\w+.*?DispatchQueue_1: com\.apple\.main-thread.*?)(?=\n    \d)",
                      text, re.S)
    if block:
        main_thread = block.group(1).splitlines()[:3]
    total_samples = 0
    match = re.search(r"Total number in stack[^\n]*", text)
    return {
        "file": str(path),
        "seconds": seconds,
        "intervalMs": 5,
        "sampleCommandOk": result.returncode == 0 and bool(call_graph.strip()),
        "stderrTail": (result.stderr or "").strip().splitlines()[-2:],
        "topLeaves": leaves[:15],
        "topCumulativeFrames": cumulative,
        "decodeSymbolHits": decode_hits,
        "decodePresent": bool(decode_hits),
        "threadHeader": main_thread,
        "totalInStackHeader": match.group(0) if match else None,
        "emptyCallGraph": not call_graph.strip(),
    }


def sample_while(ctx: "Context", pid: int, name: str, action, settle: float = 0.35) -> dict:
    """Run `sample` while an action repeats on another thread (hotspot evidence)."""
    path = ctx.dir_for("sample") / f"{name}.sample.txt"
    holder = {}

    def _loop():
        end = time.monotonic() + ctx.args.sample_seconds + 0.6
        index = 0
        while time.monotonic() < end:
            try:
                action(index)
            except Exception:
                return
            index += 1
            time.sleep(settle)

    with Monitor(pid, 0.2) as monitor:
        worker = threading.Thread(target=_loop, daemon=True)
        worker.start()
        holder = sample_report(pid, ctx.args.sample_seconds, path)
        worker.join(timeout=ctx.args.sample_seconds + 10)
    holder["cpuDuringSample"] = stats([row["cpuPercent"] for row in monitor.samples])
    return holder


def footprint_crosscheck(pid: int) -> dict:
    info = qa.footprint(pid)
    info["rusageFootprintBytes"] = rusage(pid)["footprintBytes"]
    return info


# ---------------------------------------------------------------------------
# drive lock with a heartbeat
#
# perf_qaenv.DriveLock decides a lock is stale purely from the directory mtime,
# which is never refreshed after mkdir, and its stale window is 240 s. A batch
# longer than four minutes is therefore "stolen" by the next agent, and two
# drivers then trample each other. This wrapper (a) refreshes the lock mtime
# while held, and (b) only steals from an owner whose pid is actually gone, so a
# live agent is never pre-empted.
# ---------------------------------------------------------------------------

class DriveLockSafe:
    def __init__(self, timeout: float = 3600.0, stale: float = 900.0,
                 heartbeat: float = 20.0):
        self.timeout = timeout
        self.stale = stale
        self.heartbeat = heartbeat
        self.acquired = False
        self._stop = False
        self._thread = None
        self.waited = 0.0

    def __enter__(self) -> "DriveLockSafe":
        qa.LOCK_DIR.parent.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        while True:
            try:
                qa.LOCK_DIR.mkdir()
                (qa.LOCK_DIR / "owner").write_text(
                    json.dumps({"pid": os.getpid(), "at": time.time(),
                                "argv": sys.argv[:3], "agent": "perf-runner"}),
                    encoding="utf-8")
                self.acquired = True
                self._thread = threading.Thread(target=self._beat, daemon=True)
                self._thread.start()
                return self
            except FileExistsError:
                self.waited = round(time.monotonic() - started, 1)
                stale_or_dead = self._owner_gone()
                if stale_or_dead:
                    shutil.rmtree(qa.LOCK_DIR, ignore_errors=True)
                    continue
                if time.monotonic() - started > self.timeout:
                    raise SystemExit(f"GUI drive lock busy for {self.waited}s")
                time.sleep(1.0)

    def _owner_gone(self) -> bool:
        try:
            owner = json.loads((qa.LOCK_DIR / "owner").read_text())
        except Exception:
            owner = {}
        pid = owner.get("pid")
        if isinstance(pid, int):
            try:
                os.kill(pid, 0)
                alive = True
            except ProcessLookupError:
                alive = False
            except PermissionError:
                alive = True
            if not alive:
                return True
        try:
            age = time.time() - qa.LOCK_DIR.stat().st_mtime
        except FileNotFoundError:
            return True
        return age > self.stale

    def _beat(self) -> None:
        while not self._stop:
            try:
                os.utime(qa.LOCK_DIR, None)
            except Exception:
                pass
            time.sleep(self.heartbeat)

    def __exit__(self, *exc) -> None:
        self._stop = True
        if self._thread:
            self._thread.join(timeout=2)
        if self.acquired:
            shutil.rmtree(qa.LOCK_DIR, ignore_errors=True)
            self.acquired = False


# ---------------------------------------------------------------------------
# stray instance guard
#
# The DriveLock only serialises agents; it does not reap a QA app left behind by
# a crashed run. Keyboard and scroll events are global, so two live instances
# would pollute each other (the Lead saw exactly that during the first attempt).
# ---------------------------------------------------------------------------

QA_PROCESS_PATTERN = r"PKD QA( fixed)?\.app/Contents/MacOS/PKD"


def qa_pids() -> list[int]:
    found = subprocess.run(["pgrep", "-f", QA_PROCESS_PATTERN],
                           capture_output=True, text=True).stdout.split()
    return [int(item) for item in found if item.isdigit()]


def ensure_no_stray(ctx: "Context", timeout: float = 120.0) -> dict:
    """Wait (never kill) for other agents' QA instances to go away.

    Hard rule from the Lead: no agent may kill a QA app it did not spawn. If a
    foreign instance is still there after the wait, the caller records a blocked
    scenario instead of measuring on a contended GUI.
    """
    started = time.monotonic()
    while True:
        ours = set(getattr(ctx, "my_pids", set()))
        foreign = [pid for pid in qa_pids() if pid not in ours]
        if not foreign:
            return {"waitedSeconds": round(time.monotonic() - started, 1),
                    "foreignPids": []}
        if time.monotonic() - started > timeout:
            ctx.anomaly("foreign-qa-instance",
                        f"another agent's QA instance is still running: {foreign}")
            raise EnvironmentBlocked(
                f"foreign QA instance(s) {foreign} hold the GUI")
        time.sleep(1.0)


# ---------------------------------------------------------------------------
# run context
# ---------------------------------------------------------------------------

class Context:
    def __init__(self, app: Path, out: Path, args):
        self.app = app
        self.out = out
        self.args = args
        self.anomalies: list[dict] = []
        self.scenario: str = ""
        self.repeat: int = 0
        self.binary_sha = sha256(app / "Contents/MacOS/PKD")
        self.roots: list[Path] = []
        self.my_pids: set[int] = set()
        self.scroll_mode: str = "hid"
        self.no_activate: bool = bool(getattr(args, "no_activate", False))
        self._cpu_clock_checked = False

    def anomaly(self, kind: str, detail: str, **extra) -> None:
        entry = {"scenario": self.scenario, "repeat": self.repeat, "kind": kind,
                 "detail": detail, "at": now_iso()}
        entry.update(extra)
        self.anomalies.append(entry)
        print(f"  ! anomaly [{self.scenario}/{self.repeat}] {kind}: {detail}", flush=True)

    def dir_for(self, tag: str) -> Path:
        path = self.out / self.scenario / f"r{self.repeat}" / tag
        path.mkdir(parents=True, exist_ok=True)
        return path

    def launch(self, tag: str, extra_env: dict | None = None):
        guard = ensure_no_stray(self)
        root = qa.fresh_root(f"{self.scenario.lower()}-r{self.repeat}")
        self.roots.append(root)
        process = qa.launch(self.app, root, extra_env=extra_env or {}, tag=tag)
        self.my_pids.add(process.pid)
        self.last_guard = guard
        return root, process

    def check_cpu_clock(self, pid: int) -> None:
        """Sanity: ticks->seconds conversion agrees with ps and the shared module."""
        if self._cpu_clock_checked:
            return
        self._cpu_clock_checked = True
        try:
            mine = rusage(pid)
            try:
                shared = qa.rusage(pid)
            except Exception as error:  # pragma: no cover
                shared = {"error": repr(error)}
            ps_text = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                                     capture_output=True, text=True).stdout.strip()
            seconds = 0.0
            for part in ps_text.replace(":", " ").split():
                seconds = seconds * 60 + float(part)
            detail = {
                "ticksPerSecond": TICKS_PER_SECOND,
                "mineCpuSeconds": round(mine["cpuSeconds"], 3),
                "sharedModuleCpuSeconds": round(
                    shared["userTime"] + shared["systemTime"], 3) if "userTime" in shared else None,
                "psCpuSeconds": round(seconds, 2),
                "mineFootprintBytes": mine["footprintBytes"],
                "sharedFootprintBytes": shared.get("footprintBytes"),
                "myThreads": mine["threads"], "sharedThreads": shared.get("threads"),
            }
            write_json(self.out / "cpu-clock-check.json", detail)
        except Exception as error:  # pragma: no cover
            self.anomaly("cpu-clock-check", str(error))

    def finish_repeat(self, process, root: Path, log_tail: str = "") -> None:
        code = process.poll()
        try:
            qa.quit_app(process)
        except Exception as error:
            self.anomaly("quit-app", str(error))
        # copy the app log into evidence before the disposable root is removed
        for candidate in root.glob("*.log"):
            try:
                shutil.copy2(candidate, self.dir_for("logs") / candidate.name)
            except Exception:
                pass
        if code is not None:
            self.anomaly("early-exit", f"process exited with {code} before quit",
                         returncode=code)
        self.my_pids.discard(process.pid)
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            if process.pid not in qa_pids():
                break
            time.sleep(0.25)
        else:
            self.anomaly("lingering-process", f"pid {process.pid} still listed after quit")
        if self.args.clean_roots:
            if not str(root).startswith(str(qa.RUNS)):
                raise RuntimeError(f"refusing to remove non-run root {root}")
            shutil.rmtree(root, ignore_errors=True)


# ---------------------------------------------------------------------------
# shared scenario bodies
# ---------------------------------------------------------------------------

def prepare(ctx: Context, tag: str, width: float = 1100, height: float = 740,
            extra_env: dict | None = None, verify_events: bool = True,
            need_mouse: bool = True):
    """Fresh root, fresh app, fixed window size, scan complete and idle."""
    root, process = ctx.launch(tag, extra_env)
    try:
        return _prepare_after_launch(ctx, process, root, width, height, verify_events,
                                     need_mouse)
    except Exception:
        # never leak a QA instance when the environment gate fires mid-prepare
        try:
            qa.quit_app(process)
        except Exception:
            pass
        raise


def _prepare_after_launch(ctx: Context, process, root: Path, width: float, height: float,
                          verify_events: bool, need_mouse: bool = True):
    ctx.check_cpu_clock(process.pid)
    if not ctx.args.no_activate:
        qa.activate(process.pid)
    try:
        frame_before = qa.main_window(process.pid)["frame"]
    except RuntimeError as error:
        ctx.anomaly("window-not-listed", str(error))
        frame_before = None
    frame = set_window_size(process.pid, width, height, settle=0.8)
    ready = wait_ready(process.pid)
    if ctx.args.no_activate:
        environment = environment_state(process.pid)
        frontmost = environment["frontmostIsApp"]
    else:
        environment = ensure_driveable(ctx, process.pid)
        frontmost = ensure_frontmost(process.pid)
    if not environment["frontmostIsApp"]:
        ctx.anomaly("not-frontmost",
                    f"frontmost is {environment['frontmostName']}, not the QA app")
    prep = {
        "askedSize": [width, height],
        "frameBeforeFix": frame_before,
        "frameAfterFix": frame,
        "ready": ready,
        "frontmost": frontmost,
        "environment": environment,
        "occlusion": window_occlusion(process.pid),
        "strayGuard": getattr(ctx, "last_guard", None),
    }
    if verify_events and not environment["frontmostIsApp"] and need_mouse:
        raise EnvironmentBlocked(
            f"frontmost={environment['frontmostName']}; cannot drive synthetic mouse input")
    # prove the interaction path this scenario depends on actually works
    if verify_events and need_mouse:
        prep["scrollPathCheck"] = verify_scroll_path(ctx, process.pid)
        prep["inputMode"] = "mouse"
        time.sleep(1.2)
    elif verify_events:
        prep["axPathCheck"] = ax_path_check(ctx, process.pid)
        prep["inputMode"] = "ax"
        time.sleep(0.8)
    return root, process, prep


def start_signposts(ctx: Context, pid: int, tag: str) -> CAWindow:
    return CAWindow(pid, ctx.dir_for("ca"), tag)


KEY_FLAG_MAP = {"command": "kCGEventFlagMaskCommand", "shift": "kCGEventFlagMaskShift",
                "option": "kCGEventFlagMaskAlternate", "control": "kCGEventFlagMaskControl"}


def key_to_pid(pid: int, name: str, command: bool = False, shift: bool = False,
               option: bool = False, control: bool = False, repeat: int = 1,
               delay: float = 0.04) -> bool:
    """Deliver a keystroke straight to the app's event queue.

    Global HID keyboard input is unreliable on this host (a foreign layer-999
    overlay steals it), while CGEventPostToPid still reaches the app; a11y-runner
    independently confirmed the same for ⌘1–⌘6 / ⌥⌘L / ⌘↩.
    """
    import Quartz
    code = qa.KEY_CODES[name]
    flags = 0
    for enabled, mask in ((command, Quartz.kCGEventFlagMaskCommand),
                          (shift, Quartz.kCGEventFlagMaskShift),
                          (option, Quartz.kCGEventFlagMaskAlternate),
                          (control, Quartz.kCGEventFlagMaskControl)):
        if enabled:
            flags |= mask
    for _ in range(repeat):
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            if flags:
                Quartz.CGEventSetFlags(event, flags)
            Quartz.CGEventPostToPid(pid, event)
            time.sleep(delay)
        time.sleep(0.03)
    return True


def toggle_inspector(pid: int) -> None:
    key_to_pid(pid, "l", command=True, option=True)


PAGE_CODES = {"pageDown": 0x79, "pageUp": 0x74, "down": 0x7D, "up": 0x7E, "home": 0x73,
              "end": 0x77, "space": 0x31}


def key_code_to_pid(pid: int, code: int, flags: int = 0) -> None:
    import Quartz
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        if flags:
            Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPostToPid(pid, event)
        time.sleep(0.03)


def scroll_by_ax(pid: int, lines: int) -> dict:
    """Scroll without synthetic HID input.

    The host currently routes wheel/click events to a foreign floating window,
    so scrolling is attempted through (1) the AX scroll bar value, (2) page/arrow
    keys delivered with CGEventPostToPid. Returns which path actually moved the
    grid, so callers can label the deviation honestly.
    """
    before = card_signature(pid)
    steps = max(1, abs(lines))
    # 1) scroll bar fraction
    bar = qa.ax_find(qa.ax_app(pid), role="AXScrollBar")
    if bar is not None:
        current = qa.ax_value(bar, "AXValue")
        detail = {"scrollBarValue": current, "actions": list(qa.ax_value(bar, "AXActions") or [])}
        try:
            delta = 0.04 * (steps / 20.0) * (1 if lines > 0 else -1)
            value = max(0.0, min(1.0, float(current or 0.0) + delta))
            from ApplicationServices import AXUIElementSetAttributeValue, AXValueCreate, kAXValueCFRangeType
            import Quartz
            status = int(AXUIElementSetAttributeValue(
                bar, "AXValue", AXValueCreate(kAXValueCFRangeType, (value, 0, 0))))
            detail["setValueStatus"] = status
        except Exception as error:  # pragma: no cover
            detail["setValueError"] = repr(error)
        time.sleep(0.4)
        if card_signature(pid) != before:
            detail["path"] = "scrollbar-value"
            detail["changed"] = True
            return detail
    # 2) page/arrow keys to the pid
    for name in ("pageDown", "down"):
        key_code_to_pid(pid, PAGE_CODES["pageDown" if lines > 0 else "pageUp"])
        time.sleep(0.25)
    if card_signature(pid) != before:
        return {"path": "page-keys", "changed": True}
    if card_signature(pid) != before:
        return {"path": "arrow-keys", "changed": True}
    return {"path": "none", "changed": False}


def do_scroll(pid: int, lines: int) -> None:
    scroll_lines(pid, lines)


def scroll_rounds(pid: int, rounds: int = 6, lines: int = 20) -> None:
    for _ in range(rounds):
        scroll_lines(pid, lines)
        scroll_lines(pid, -lines)


# ---------------------------------------------------------------------------
# S1: first load + idle baseline
# ---------------------------------------------------------------------------

def scenario_S1(ctx: Context) -> dict:
    tag = "S1"
    root, process, prep = prepare(ctx, tag, verify_events=False)
    payload = {"prep": prep, "idle": {}, "anomalies": []}
    try:
        qa.activate(process.pid)
        with start_signposts(ctx, process.pid, "idle") as ca:
            with Monitor(process.pid, 0.1) as monitor:
                time.sleep(2.0)
            payload["idle"]["monitor"] = monitor.summary()
            payload["idle"]["cpuAll"] = stats([s["cpuPercent"] for s in monitor.samples])
        payload["idle"]["ca"] = ca.result()
        payload["idle"]["footprint"] = footprint_crosscheck(process.pid)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "idle.png",
                                                  process.pid))
        payload["visibleCards"] = len(visible_cards(process.pid))
        payload["statusTexts"] = [t for t in static_texts(process.pid) if "项" in t]
        payload["inputProbeAfterIdle"] = probe_input(process.pid)
        if not payload["inputProbeAfterIdle"]["changed"]:
            ctx.anomaly("input-not-reaching-app",
                        "post-idle wheel probe did not move the grid; window likely covered")
    except Exception as error:
        ctx.anomaly("S1-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# S2: continuous scrolling
# ---------------------------------------------------------------------------

def scenario_S2(ctx: Context) -> dict:
    tag = "S2"
    root, process, prep = prepare(ctx, tag)
    payload = {"prep": prep}
    try:
        qa.activate(process.pid)
        # steady state after the initial paint
        time.sleep(1.0)
        with Monitor(process.pid, 0.1) as monitor:
            with start_signposts(ctx, process.pid, "down") as ca_down:
                t0 = time.monotonic()
                do_scroll(process.pid, 20)
                t1 = time.monotonic()
            with start_signposts(ctx, process.pid, "up") as ca_up:
                do_scroll(process.pid, -20)
            with start_signposts(ctx, process.pid, "rounds") as ca_rounds:
                t2 = time.monotonic()
                scroll_rounds(process.pid, 6, 20)
                t3 = time.monotonic()
        payload["cpuAll"] = stats([s["cpuPercent"] for s in monitor.samples])
        payload["monitor"] = monitor.summary()
        payload["slices"] = {
            "down": monitor_slice(monitor, t0, t1),
            "rounds": monitor_slice(monitor, t2, t3),
        }
        payload["ca"] = {"down": ca_down.result(), "up": ca_up.result(),
                         "rounds": ca_rounds.result()}
        # `sample` needs its own pass: run it while scrolling from another thread
        sample_path = ctx.dir_for("sample") / "scroll.sample.txt"
        holder = {}

        def _scroll_loop():
            end = time.monotonic() + ctx.args.sample_seconds + 0.4
            direction = 20
            while time.monotonic() < end:
                try:
                    scroll_lines(process.pid, direction)
                except EnvironmentBlocked:
                    return
                direction = -direction

        with Monitor(process.pid, 0.2) as sample_monitor:
            worker = threading.Thread(target=_scroll_loop, daemon=True)
            worker.start()
            holder["sample"] = sample_report(process.pid, ctx.args.sample_seconds, sample_path)
            worker.join(timeout=ctx.args.sample_seconds + 6)
        holder["sample"]["cpuDuringSample"] = stats([s["cpuPercent"] for s in sample_monitor.samples])
        payload["sample"] = holder["sample"]
        payload["footprint"] = footprint_crosscheck(process.pid)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "after.png",
                                                  process.pid))
        payload["visibleCards"] = len(visible_cards(process.pid))
    except Exception as error:
        ctx.anomaly("S2-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# S3: continuous resizing
# ---------------------------------------------------------------------------

SIZES = [(1100, 740), (900, 700), (1300, 820), (780, 640)]


def scenario_S3(ctx: Context) -> dict:
    tag = "S3"
    root, process, prep = prepare(ctx, tag, need_mouse=False)
    payload = {"prep": prep}
    try:
        qa.activate(process.pid)
        time.sleep(0.8)
        frames = []
        with Monitor(process.pid, 0.05) as monitor:
            with start_signposts(ctx, process.pid, "resize") as ca:
                t0 = time.monotonic()
                for step in range(24):
                    width, height = SIZES[step % len(SIZES)]
                    _ax_set_size(process.pid, width, height)
                    frames.append([width, height])
                    time.sleep(0.12)
                t1 = time.monotonic()
                time.sleep(0.4)
        payload["steps"] = len(frames)
        payload["sizes"] = SIZES
        payload["cpu"] = stats([s["cpuPercent"] for s in monitor.samples])
        payload["slice"] = monitor_slice(monitor, t0, t1)
        payload["ca"] = ca.result()
        payload["frameAfter"] = qa.main_window(process.pid)["frame"]
        # sample while resizing (same threading trick)
        sample_path = ctx.dir_for("sample") / "resize.sample.txt"
        def _resize_loop():
            end = time.monotonic() + ctx.args.sample_seconds + 0.4
            index = 0
            while time.monotonic() < end:
                width, height = SIZES[index % len(SIZES)]
                try:
                    _ax_set_size(process.pid, width, height)
                except Exception:
                    return
                index += 1
                time.sleep(0.12)
        with Monitor(process.pid, 0.2) as sample_monitor:
            worker = threading.Thread(target=_resize_loop, daemon=True)
            worker.start()
            payload["sample"] = sample_report(process.pid, ctx.args.sample_seconds, sample_path)
            worker.join(timeout=ctx.args.sample_seconds + 6)
        payload["sample"]["cpuDuringSample"] = stats([s["cpuPercent"] for s in sample_monitor.samples])
        payload["footprint"] = footprint_crosscheck(process.pid)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "after.png", process.pid))
    except Exception as error:
        ctx.anomaly("S3-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# switch measuring helper (S4 / S5 / S6)
# ---------------------------------------------------------------------------

def measure_switch(ctx: Context, pid: int, label: str, action, settle: float = 1.2,
                   monitor=None) -> dict:
    """1.2 s of quiet, then the action with CA captured, then 1.2 s after."""
    before_lat = axlat(pid, 15)
    time.sleep(0.15)
    with start_signposts(ctx, pid, label) as ca:
        started = time.monotonic()
        action()
        time.sleep(settle)
        ended = time.monotonic()
    result = {
        "label": label,
        "ca": ca.result(),
        "axLatencyBeforeMs": before_lat,
        "axLatencyAfterMs": axlat(pid, 15),
        "windowSeconds": round(ended - started, 2),
    }
    if monitor is not None:
        result["cpuDuringSwitch"] = monitor_slice(monitor, started, ended)
    return result


def _calm(pid: int, seconds: float = 1.2) -> None:
    time.sleep(seconds)


# ---------------------------------------------------------------------------
# S4: grid density
# ---------------------------------------------------------------------------

DENSITY_MENU = "正方形网格，三乘三"


def scenario_S4(ctx: Context, switches=None, label_prefix="S4") -> dict:
    tag = "S4"
    root, process, prep = prepare(ctx, tag, need_mouse=False)
    payload = {"prep": prep, "switches": []}
    switches = switches or [("紧凑", "compact"), ("标准", "standard"), ("宽松", "comfortable")]
    try:
        qa.activate(process.pid)
        time.sleep(0.8)
        payload["buttonsBefore"] = [qa.ax_value(b, "AXTitle")
                                    for b in ax_find_all(qa.ax_app(process.pid),
                                                         role="AXMenuButton", limit=10)]
        payload["cardsBefore"] = len(visible_cards(process.pid))
        with Monitor(process.pid, 0.05) as monitor:
            for item_title, key in switches:
                _calm(process.pid, 1.2)
                # reopening the menu needs the *current* title, which is stable here
                switch = measure_switch(
                    ctx, process.pid, f"{label_prefix}-{key}",
                    lambda title=item_title: choose_menu_item(
                        process.pid, button_title=DENSITY_MENU, item_title=title),
                    settle=1.2, monitor=monitor)
                switch["density"] = key
                switch["cardsAfter"] = len(visible_cards(process.pid))
                switch["screenshot"] = str(qa.screenshot(
                    ctx.dir_for("shots") / f"{key}.png", process.pid))
                payload["switches"].append(switch)
        payload["cpuAll"] = stats([s["cpuPercent"] for s in monitor.samples])
        payload["monitor"] = monitor.summary()
        payload["footprint"] = footprint_crosscheck(process.pid)
        cycle = ("紧凑", "标准", "宽松")

        def _switch(index: int) -> None:
            choose_menu_item(process.pid, button_title=DENSITY_MENU,
                             item_title=cycle[index % 3])

        payload["sample"] = sample_while(ctx, process.pid, "density-switch", _switch)
    except Exception as error:
        ctx.anomaly("S4-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# S5: sort switching
# ---------------------------------------------------------------------------

SORT_SEQUENCE = [
    ("体积从大到小", "size-desc"),
    ("Workshop ID 升序", "id-asc"),
    ("体积从小到大", "size-asc"),
    ("标题 A–Z", "title-asc"),
    ("体积从大到小", "size-desc"),
    ("Workshop ID 升序", "id-asc"),
    ("体积从小到大", "size-asc"),
    ("标题 A–Z", "title-asc"),
]


def scenario_S5(ctx: Context, sequence=None, label_prefix="S5") -> dict:
    tag = "S5"
    root, process, prep = prepare(ctx, tag, need_mouse=False)
    payload = {"prep": prep, "switches": []}
    sequence = sequence or SORT_SEQUENCE
    try:
        qa.activate(process.pid)
        time.sleep(0.8)
        payload["sortBefore"] = [qa.ax_value(b, "AXTitle")
                                 for b in ax_find_all(qa.ax_app(process.pid),
                                                      role="AXMenuButton", prefix="排序：",
                                                      limit=3)]
        with Monitor(process.pid, 0.05) as monitor:
            for index, (item_title, key) in enumerate(sequence):
                _calm(process.pid, 1.2)
                switch = measure_switch(
                    ctx, process.pid, f"{label_prefix}-{index:02d}-{key}",
                    lambda title=item_title: choose_menu_item(
                        process.pid, button_prefix="排序：", item_title=title),
                    settle=1.2, monitor=monitor)
                switch["sort"] = key
                switch["sortLabelAfter"] = [qa.ax_value(b, "AXTitle")
                                            for b in ax_find_all(qa.ax_app(process.pid),
                                                                 role="AXMenuButton",
                                                                 prefix="排序：", limit=3)]
                payload["switches"].append(switch)
                if index == 0:
                    switch["screenshot"] = str(qa.screenshot(
                        ctx.dir_for("shots") / f"{index:02d}-{key}.png", process.pid))
        payload["cpuAll"] = stats([s["cpuPercent"] for s in monitor.samples])
        payload["monitor"] = monitor.summary()
        payload["footprint"] = footprint_crosscheck(process.pid)

        def _sort(index: int) -> None:
            choose_menu_item(process.pid, button_prefix="排序：",
                             item_title=SORT_SEQUENCE[index % len(SORT_SEQUENCE)][0])

        payload["sample"] = sample_while(ctx, process.pid, "sort-switch", _sort,
                                         settle=0.5)
    except Exception as error:
        ctx.anomaly("S5-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# S6: inspector
# ---------------------------------------------------------------------------

INSPECTOR_TABS = {"详情", "日志"}


def inspector_visible(pid: int) -> bool:
    """The inspector exposes its tabs as AXRadioButton (label may sit in title or
    description depending on macOS build), so both are checked."""
    for row in qa.ax_tree(pid, 1200):
        if row["role"] != "AXRadioButton":
            continue
        for field in ("title", "description"):
            label = row.get(field)
            if isinstance(label, str) and label.strip() in INSPECTOR_TABS:
                return True
    return False


def scenario_S6(ctx: Context, toggles: int = 3, label_prefix="S6") -> dict:
    tag = "S6"
    root, process, prep = prepare(ctx, tag, width=1200, height=800, need_mouse=False)
    payload = {"prep": prep, "switches": []}
    try:
        qa.activate(process.pid)
        time.sleep(0.8)
        with Monitor(process.pid, 0.05) as monitor:
            for round_index in range(toggles):
                for mode in ("key", "button"):
                    _calm(process.pid, 1.2)
                    if mode == "key":
                        action = lambda: toggle_inspector(process.pid)
                    else:
                        def action():
                            button = qa.ax_find(qa.ax_app(process.pid), role="AXButton",
                                                description="检查器")
                            if button is None:
                                raise RuntimeError("inspector toolbar button not found")
                            qa.ax_press(button)
                    was_visible = inspector_visible(process.pid)
                    switch = measure_switch(
                        ctx, process.pid, f"{label_prefix}-{round_index}-{mode}",
                        action, settle=1.2, monitor=monitor)
                    switch["mode"] = mode
                    switch["inspectorBefore"] = was_visible
                    switch["inspectorAfter"] = inspector_visible(process.pid)
                    if switch["inspectorBefore"] == switch["inspectorAfter"]:
                        ctx.anomaly("inspector-toggle-no-effect",
                                    f"{mode} toggle did not change inspector visibility")
                    switch["splitGroupsAfter"] = sum(
                        1 for row in qa.ax_tree(process.pid, 300)
                        if row["role"] == "AXSplitGroup")
                    payload["switches"].append(switch)
        payload["cpuAll"] = stats([s["cpuPercent"] for s in monitor.samples])
        payload["monitor"] = monitor.summary()
        payload["footprint"] = footprint_crosscheck(process.pid)

        def _toggle(index: int) -> None:
            if index % 2 == 0:
                toggle_inspector(process.pid)
            else:
                button = qa.ax_find(qa.ax_app(process.pid), role="AXButton",
                                    description="检查器")
                if button is not None:
                    qa.ax_press(button)

        payload["sample"] = sample_while(ctx, process.pid, "inspector-toggle", _toggle)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "end.png", process.pid))
    except Exception as error:
        ctx.anomaly("S6-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# S7: appearance matrix (theme x font scale x thumbnails), short S2
# ---------------------------------------------------------------------------

APPEARANCE_CELLS = [
    ("dark", "small", False), ("dark", "standard", False), ("dark", "large", False),
    ("light", "small", False), ("light", "standard", False), ("light", "large", False),
    ("dark", "small", True), ("dark", "standard", True), ("dark", "large", True),
    ("light", "small", True), ("light", "standard", True), ("light", "large", True),
]


def appearance_env(theme: str, font: str, thumbnails: bool) -> dict:
    write_default("pkd.appearance.theme", theme)
    write_default("pkd.appearance.font", font)
    write_default("pkd.appearance.thumbnails", thumbnails)
    return {}


def scenario_S7_cell(ctx: Context, theme: str, font: str, thumbnails: bool) -> dict:
    """One cell of the appearance matrix: fresh launch + scroll 10 down / 10 up."""
    label = f"S7-{theme}-{font}-{'on' if thumbnails else 'off'}"
    ctx.scenario = label
    appearance_env(theme, font, thumbnails)
    payload = {"cell": {"theme": theme, "font": font, "thumbnails": thumbnails}}
    root, process, prep = prepare(ctx, "S7")
    try:
        qa.activate(process.pid)
        time.sleep(1.0)
        payload["settingsEcho"] = {key: default_domain_snapshot().get(key)
                                   for key in ("pkd.appearance.theme", "pkd.appearance.font",
                                               "pkd.appearance.thumbnails")}
        with Monitor(process.pid, 0.1) as monitor:
            with start_signposts(ctx, process.pid, "scroll") as ca:
                t0 = time.monotonic()
                do_scroll(process.pid, 10)
                do_scroll(process.pid, -10)
                t1 = time.monotonic()
            payload["cpu"] = stats([s["cpuPercent"] for s in monitor.samples])
            payload["slice"] = monitor_slice(monitor, t0, t1)
            payload["monitor"] = monitor.summary()
        payload["ca"] = ca.result()
        payload["footprint"] = footprint_crosscheck(process.pid)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "cell.png", process.pid))
    except Exception as error:
        ctx.anomaly("S7-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


def scenario_S7(ctx: Context) -> dict:
    cells = []
    original = default_domain_snapshot()
    try:
        for theme, font, thumbnails in APPEARANCE_CELLS:
            print(f"  S7 cell {theme}/{font}/{thumbnails}", flush=True)
            cell_context = Context(ctx.app, ctx.out, ctx.args)
            cell_context.binary_sha = ctx.binary_sha
            cell_data = scenario_S7_cell(cell_context, theme, font, thumbnails)
            cell_data["anomalies"] = cell_context.anomalies
            cells.append(cell_data)
            ctx.anomalies.extend(cell_context.anomalies)
    finally:
        # restore the development-domain appearance defaults
        for key in ("pkd.appearance.theme", "pkd.appearance.font",
                    "pkd.appearance.thumbnails"):
            if key in original:
                write_default(key, original[key])
            else:
                delete_default(key)
    ctx.scenario = "S7"
    return {"cells": cells, "restoredDefaults": {
        key: original.get(key) for key in ("pkd.appearance.theme", "pkd.appearance.font",
                                           "pkd.appearance.thumbnails")}}


# ---------------------------------------------------------------------------
# S8: reduced motion, repeating S4 / S5 / S6
# ---------------------------------------------------------------------------

def scenario_S8(ctx: Context) -> dict:
    key = "pkd.appearance.motion"
    original = default_domain_snapshot()
    previous = original.get(key)
    write_default(key, "off")
    payload = {"motionSetting": "off", "previousValue": previous}
    try:
        sub = {}
        for name, runner in (("S4", scenario_S4), ("S5", scenario_S5), ("S6", scenario_S6)):
            scenario_ctx = Context(ctx.app, ctx.out, ctx.args)
            scenario_ctx.binary_sha = ctx.binary_sha
            scenario_ctx.scenario = f"S8_{name}"
            print(f"  S8 {name}", flush=True)
            sub[name] = runner(scenario_ctx,
                               **({"label_prefix": f"S8-{name}"}
                                  if name != "S6" else {"label_prefix": f"S8-{name}"}))
            ctx.anomalies.extend(scenario_ctx.anomalies)
        payload["results"] = sub
        # was any animation still multi-frame? commits spread over time per switch
        frames = []
        for name in ("S4", "S5", "S6"):
            for switch in sub[name].get("switches", []):
                ca = switch.get("ca") or {}
                frames.append({
                    "label": switch.get("label"),
                    "commits": ca.get("commits"),
                    "stalls": ca.get("stalls"),
                    "commitSpanMs": ca.get("commitSpanMs"),
                    "spacing": ca.get("commitSpacingMs"),
                })
        payload["commitSpans"] = frames
    finally:
        if previous is None:
            delete_default(key)
        else:
            write_default(key, previous)
    return payload


# ---------------------------------------------------------------------------
# S9: four minute mixed loop
# ---------------------------------------------------------------------------

def scenario_S9(ctx: Context, minutes: float = 4.0) -> dict:
    tag = "S9"
    root, process, prep = prepare(ctx, tag, need_mouse=False)
    mouse_ok = bool((prep.get("scrollPathCheck") or {}).get("changed"))
    payload = {"prep": prep, "minutes": minutes}
    try:
        qa.activate(process.pid)
        time.sleep(0.8)
        samples = []
        start = time.monotonic()
        actions = 0
        last = time.monotonic()
        previous = rusage(process.pid)
        previous_at = time.monotonic()
        cycle = 0
        with Monitor(process.pid, 0.1) as monitor:
            while time.monotonic() - start < minutes * 60:
                cycle += 1
                phase = cycle % 4
                if phase == 0 and mouse_ok:
                    qa.scroll(process.pid, 12)
                    qa.scroll(process.pid, -12)
                elif phase == 0:
                    # synthetic wheel input is unavailable: use an AX density
                    # switch instead so each cycle still changes the grid
                    choose_menu_item(process.pid, button_title=DENSITY_MENU,
                                     item_title=("紧凑", "标准", "宽松")[cycle % 3])
                elif phase == 1:
                    choose_menu_item(process.pid, button_prefix="排序：",
                                     item_title=SORT_SEQUENCE[cycle % len(SORT_SEQUENCE)][0])
                elif phase == 2:
                    key_to_pid(process.pid, str((cycle % 2) + 1), command=True)  # ⌘1/⌘2
                else:
                    toggle_inspector(process.pid)
                actions += 1
                # ~2 s cadence; resample footprint/threads/wakeups every 2 s
                while time.monotonic() - last < 2.0:
                    time.sleep(0.05)
                last = time.monotonic()
                current = rusage(process.pid)
                elapsed = last - previous_at
                samples.append({
                    "t": round(last - start, 2),
                    "footprintBytes": current["footprintBytes"],
                    "threads": current["threads"],
                    "wakeups": current["wakeups"] - previous["wakeups"],
                    "cpuPercent": round(((current["userTime"] - previous["userTime"])
                                         + (current["systemTime"] - previous["systemTime"]))
                                        / elapsed * 100, 2) if elapsed > 0 else None,
                })
                previous, previous_at = current, last
        payload["samples"] = samples
        payload["mouseAvailable"] = mouse_ok
        payload["actions"] = actions
        payload["monitor"] = monitor.summary()
        payload["footprint"] = footprint_crosscheck(process.pid)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "end.png", process.pid))
        # trend analysis
        def trend(key: str) -> dict:
            values = [s[key] for s in samples if s.get(key) is not None]
            if len(values) < 8:
                return {"n": len(values)}
            half = len(values) // 2
            first, second = values[:half], values[half:]
            x = list(range(len(values)))
            mean_x = statistics.fmean(x)
            mean_y = statistics.fmean(values)
            denom = sum((v - mean_x) ** 2 for v in x)
            slope = sum((x[i] - mean_x) * (values[i] - mean_y) for i in range(len(values))) / denom
            return {
                "n": len(values),
                "first": values[0], "last": values[-1],
                "min": min(values), "max": max(values),
                "firstHalfMean": round(statistics.fmean(first), 1),
                "secondHalfMean": round(statistics.fmean(second), 1),
                "slopePerSample": round(slope, 2),
                "monotonicGrowth": second[-1] > first[0] and statistics.fmean(second)
                                   > statistics.fmean(first),
            }
        payload["trend"] = {key: trend(key) for key in
                            ("footprintBytes", "threads", "wakeups", "cpuPercent")}
    except Exception as error:
        ctx.anomaly("S9-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# S10: selection + extraction memory
# ---------------------------------------------------------------------------

def scenario_S10(ctx: Context) -> dict:
    tag = "S10"
    root, process, prep = prepare(ctx, tag, width=1200, height=800, need_mouse=False)
    payload = {"prep": prep, "steps": []}
    holder: dict = {}
    try:
        qa.activate(process.pid)
        time.sleep(1.0)

        def record(name: str, action) -> None:
            before = rusage(process.pid)
            with start_signposts(ctx, process.pid, name) as ca:
                started = time.monotonic()
                action()
                time.sleep(1.0)
                ended = time.monotonic()
            after = rusage(process.pid)
            payload["steps"].append({
                "name": name,
                "footprintBefore": before["footprintBytes"],
                "footprintAfter": after["footprintBytes"],
                "footprintDelta": after["footprintBytes"] - before["footprintBytes"],
                "threadsBefore": before["threads"], "threadsAfter": after["threads"],
                "ca": ca.result(),
                "cpu": monitor_slice(holder["monitor"], started, ended),
            })

        with Monitor(process.pid, 0.1) as monitor:
            holder["monitor"] = monitor
            cards = visible_cards(process.pid)
            if not cards:
                raise RuntimeError("no visible cards")
            record("press-first-card", lambda: qa.ax_press(cards[0]))
            cards = visible_cards(process.pid)

            def multi_select():
                targets = cards[:5]
                points = [element_center(card) for card in targets[1:]]
                for point in points:
                    if point:
                        qa.click(process.pid, point[0], point[1], command=True)
                        time.sleep(0.15)

            record("cmd-multiselect-5", multi_select)
            payload["selectionAfterMultiselect"] = [t for t in static_texts(process.pid)
                                                    if "已选" in t]
            if not payload["selectionAfterMultiselect"]:
                ctx.anomaly("multiselect-no-effect",
                            "⌘-clicks did not add selection (mouse path blocked?)")
            record("cmd-return-extract",
                   lambda: key_to_pid(process.pid, "return", command=True))
            time.sleep(ctx.args.extract_wait)
            payload["extracted"] = sorted(p.name for p in (root / "Extracted").glob("*"))[:20]
            payload["historyEntries"] = len(list((root / "History").glob("*")))
            record("cancel-all", lambda: key_to_pid(process.pid, "period", command=True))
            time.sleep(0.5)
            payload["queueTexts"] = [t for t in static_texts(process.pid)
                                     if "任务" in t or "解包" in t][:10]
            # after everything settles, second footprint cross-check
            payload["statusTexts"] = [t for t in static_texts(process.pid) if "项" in t]
        payload["monitor"] = monitor.summary()
        payload["footprint"] = footprint_crosscheck(process.pid)
        payload["screenshot"] = str(qa.screenshot(ctx.dir_for("shots") / "end.png", process.pid))
    except Exception as error:
        ctx.anomaly("S10-error", repr(error))
        payload["error"] = repr(error)
        traceback.print_exc()
    finally:
        ctx.finish_repeat(process, root)
    return payload


# ---------------------------------------------------------------------------
# registry / driver
# ---------------------------------------------------------------------------

SCENARIOS = {
    "S1": scenario_S1,
    "S2": scenario_S2,
    "S3": scenario_S3,
    "S4": scenario_S4,
    "S5": scenario_S5,
    "S6": scenario_S6,
    "S7": scenario_S7,
    "S8": scenario_S8,
    "S9": scenario_S9,
    "S10": scenario_S10,
}

REPEATS = {"S1": 3, "S2": 3, "S3": 3, "S4": 3, "S5": 3, "S6": 3,
           "S7": 1, "S8": 1, "S9": 1, "S10": 3}


def environment(app: Path, out: Path, ctx: Context) -> dict:
    info = subprocess.run(["sw_vers"], capture_output=True, text=True).stdout.strip()
    try:
        mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True,
                                 text=True).stdout.strip())
    except Exception:
        mem = None
    fixture = {}
    fixture_path = FIXTURE_BASE / "fixtures.json"
    if fixture_path.exists():
        fixture = json.loads(fixture_path.read_text())
        fixture["root"] = str(FIXTURE_BASE)
        fixture["cardCount"] = len(list((FIXTURE_BASE / "Library").iterdir()))
    return {
        "runId": out.name,
        "startedAt": now_iso(),
        "agent": "perf-runner",
        "app": {
            "path": str(app),
            "executableSha256": ctx.binary_sha,
            "bundleId": DOMAIN,
            "infoPlist": _plist(app / "Contents/Info.plist"),
        },
        "host": {
            "os": info,
            "arch": subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip(),
            "cpu": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                                  capture_output=True, text=True).stdout.strip(),
            "memBytes": mem,
            "power": subprocess.run(["pmset", "-g", "batt"], capture_output=True,
                                    text=True).stdout.strip().splitlines()[:2],
            "python": sys.version.split()[0],
            "pythonArch": subprocess.run(["arch"], capture_output=True, text=True).stdout.strip(),
        },
        "fixture": fixture,
        "settingsSnapshot": default_domain_snapshot(),
        "activationPolicy": ("none (--no-activate)"
                             if getattr(ctx.args, "no_activate", False)
                             else "activate before each scenario"),
        "methodology": {
            "frameProxy": "Core Animation Transaction signpost commit instants "
                          "(begin_time) and CA self-reported Transaction.Stalls; "
                          "NOT a presented frame rate.",
            "cpu": "proc_pid_rusage user+sys delta divided by wall clock (percent of one core).",
            "memory": "ri_phys_footprint sampled by Monitor; cross-checked with /usr/bin/footprint.",
            "axLatency": "round-trip of a trivial AX attribute query (main-thread responsiveness proxy).",
            "sample": "/usr/bin/sample leaf frames, default 5 ms interval.",
            "notes": "Signposts are captured per action window; counts therefore cover "
                     "the action plus a short settle, not a global frame budget.",
        },
    }


def _plist(path: Path) -> dict:
    try:
        with path.open("rb") as stream:
            data = plistlib.load(stream)
        return {key: data.get(key) for key in
                ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
    except Exception:
        return {}


def summarise(values: list[float]) -> dict:
    return stats(values)


def run_all(args) -> dict:
    app = Path(args.app).resolve()
    qa.verify_dev_bundle(app)
    label = args.label or datetime.datetime.now().strftime("baseline-%H%M")
    out = Path(args.out) if args.out else (qa.EVIDENCE / "perf" / label)
    out.mkdir(parents=True, exist_ok=True)
    ctx = Context(app, out, args)
    env = environment(app, out, ctx)
    env_target = out / "env.json"
    if args.resume and env_target.exists():
        env_target = out / f"env-resume-{datetime.datetime.now().strftime('%H%M%S')}.json"
    write_json(env_target, env)
    print(f"app={app}\nsha256={ctx.binary_sha}\nout={out}", flush=True)

    only = [s.strip().upper() for s in args.only.split(",")] if args.only else list(SCENARIOS)
    result = {"runId": out.name, "label": label, "startedAt": now_iso(),
              "app": {"path": str(app), "executableSha256": ctx.binary_sha},
              "scenarios": {}, "anomalies": [], "completedScenarios": []}
    result_path = out / "result.json"
    if args.resume and result_path.exists():
        previous = json.loads(result_path.read_text())
        result["scenarios"] = previous.get("scenarios", {})
        result["anomalies"] = previous.get("anomalies", [])
        result["completedScenarios"] = previous.get("completedScenarios", [])
        result["startedAt"] = previous.get("startedAt", result["startedAt"])
        result["resumedAt"] = now_iso()
        print(f"resuming {out} with {sorted(result['scenarios'])}", flush=True)

    with DriveLockSafe(timeout=args.lock_timeout) as drive_lock:
        try:
            for name in only:
                if name not in SCENARIOS:
                    print(f"skip unknown scenario {name}")
                    continue
                repeats = 1 if name in ("S7", "S8", "S9") else args.repeat
                entries = []
                blocked_streak = 0
                for index in range(repeats):
                    ctx.scenario = name
                    ctx.repeat = index
                    print(f"[{name} r{index + 1}/{repeats}]", flush=True)
                    started = time.monotonic()
                    try:
                        payload = SCENARIOS[name](ctx)
                    except EnvironmentBlocked as error:
                        ctx.anomaly("environment-blocked-repeat", str(error))
                        payload = {"blocked": str(error)}
                        blocked_streak += 1
                        entries.append({"repeat": index, "blocked": str(error),
                                        "repeatSeconds": round(time.monotonic() - started, 1),
                                        "anomalies": [a for a in ctx.anomalies
                                                      if a["scenario"] == name]})
                        result["scenarios"].setdefault(name, {})["repeats"] = entries
                        result["blockedScenarios"] = sorted(set(result.get("blockedScenarios", [])
                                                                + [name]))
                        write_json(result_path, result)
                        break
                    except Exception as error:
                        ctx.anomaly(f"{name}-fatal", repr(error))
                        payload = {"error": repr(error)}
                    payload["repeat"] = index
                    payload["repeatSeconds"] = round(time.monotonic() - started, 1)
                    payload["anomalies"] = [a for a in ctx.anomalies
                                            if a["scenario"] == name]
                    entries.append(payload)
                    # incremental write so a later failure keeps earlier evidence
                    result["scenarios"].setdefault(name, {})["repeats"] = entries
                    result["anomalies"] = ctx.anomalies
                    write_json(result_path, result)
                result["scenarios"].setdefault(name, {})["repeats"] = entries
                blocked = sum(1 for entry in entries if entry.get("blocked"))
                if blocked < len(entries):
                    result["completedScenarios"].append(name)
                write_json(result_path, result)
                print(f"[{name}] done", flush=True)
                if blocked_streak:
                    print(f"[{name}] blocked: {blocked_streak} repeat(s)", flush=True)
        finally:
            result["anomalies"] = ctx.anomalies
            result["finishedAt"] = now_iso()
            result["methodology"] = env["methodology"]
            write_json(result_path, result)
            (out / "notes.md").write_text(build_notes(result, env), encoding="utf-8")
            # remaining disposable roots (should normally be empty)
            for root in ctx.roots:
                if args.clean_roots and str(root).startswith(str(qa.RUNS)):
                    shutil.rmtree(root, ignore_errors=True)
    return result


def build_notes(result: dict, env: dict) -> str:
    lines = [f"# UI perf run {result['runId']}", "",
             f"- app: `{result['app']['path']}`",
             f"- executable sha256: `{result['app']['executableSha256']}`",
             f"- started: {result['startedAt']} / finished: {result.get('finishedAt')}",
             "- All numbers are proxies: CA Transaction commit *instants* and CA "
             "`Transaction.Stalls` (not a presented frame rate), rusage user+sys CPU, "
             "`ri_phys_footprint` cross-checked with `/usr/bin/footprint`, `/usr/bin/sample` "
             "leaf frames, and AX round-trip latency.", ""]
    for name, data in result["scenarios"].items():
        repeats = data.get("repeats", [])
        lines.append(f"## {name} ({len(repeats)} repeats)")
        cpu = []
        st = []
        commits = []
        for entry in repeats:
            monitor = entry.get("monitor") or entry.get("idle", {}).get("monitor") or {}
            cpu_stats = entry.get("cpuAll") or (monitor.get("cpuPercent") if monitor else None)
            if cpu_stats:
                cpu.append(cpu_stats["p50"])
            ca = entry.get("ca")
            if isinstance(ca, dict) and "commits" in ca:
                commits.append(f"{ca.get('commits')}/{ca.get('stalls')}")
            if entry.get("error"):
                st.append(entry["error"][:80])
        if cpu:
            lines.append(f"- cpu p50 across repeats: {[round(c, 1) for c in cpu]}")
        if commits:
            lines.append(f"- CA commits/stalls per repeat: {commits}")
        if st:
            lines.append(f"- errors: {st}")
        lines.append("")
    if result["anomalies"]:
        lines.append("## Anomalies")
        for entry in result["anomalies"]:
            lines.append(f"- [{entry['scenario']} r{entry['repeat']}] {entry['kind']}: "
                         f"{entry['detail'][:200]}")
    return "\n".join(lines) + "\n"


def _mean(values) -> float | None:
    values = [v for v in values if isinstance(v, (int, float))]
    return round(statistics.fmean(values), 2) if values else None


def _switch_aggregate(switches: list) -> dict:
    commits = [s.get("ca", {}).get("commits", 0) for s in switches]
    stalls = [s.get("ca", {}).get("stalls", 0) for s in switches]
    spans = [s.get("ca", {}).get("commitSpanMs", 0) for s in switches]
    cpu_peak = [s.get("cpuDuringSwitch", {}).get("cpuPercent", {}).get("worst")
                for s in switches if s.get("cpuDuringSwitch")]
    ax_p50 = [s.get("axLatencyBeforeMs", {}).get("p50") for s in switches]
    ax_p95 = [s.get("axLatencyBeforeMs", {}).get("p95") for s in switches]
    return {
        "switches": len(switches),
        "commitsTotal": sum(commits),
        "commitsMean": _mean(commits),
        "stallsTotal": sum(stalls),
        "commitSpanMeanMs": _mean(spans),
        "cpuPeakMean": _mean(cpu_peak),
        "cpuPeakMax": max([v for v in cpu_peak if isinstance(v, (int, float))], default=None),
        "axP50Mean": _mean(ax_p50),
        "axP95Mean": _mean(ax_p95),
    }


def _flat_scenario(payload: dict) -> dict:
    """Reduce one repeat payload to comparable numbers."""
    cpu = payload.get("cpuAll") or payload.get("cpu") or payload.get("idle", {}).get("cpuAll")
    monitor = payload.get("monitor") or payload.get("idle", {}).get("monitor")
    ca = payload.get("ca")
    result = {}
    if cpu:
        result["cpuP50"] = cpu.get("p50")
        result["cpuP95"] = cpu.get("p95")
        result["cpuWorst"] = cpu.get("worst")
    if monitor:
        result["footprintMaxMB"] = round(monitor.get("footprintBytes", {}).get("max", 0) / 2**20, 1)
        result["footprintDeltaMB"] = round(
            (monitor.get("footprintBytes", {}).get("last", 0)
             - monitor.get("footprintBytes", {}).get("first", 0)) / 2**20, 1)
        result["threadsMax"] = (monitor.get("threads") or {}).get("max")
        result["wakeupsPerSecond"] = monitor.get("wakeupsPerSecond")
    if isinstance(ca, dict):
        if "commits" in ca:
            result["commits"] = ca["commits"]
            result["stalls"] = ca.get("stalls", 0)
            result["commitSpanMs"] = ca.get("commitSpanMs")
        elif payload.get("ca"):
            result["commits"] = sum(v.get("commits", 0) for v in ca.values() if isinstance(v, dict))
            result["stalls"] = sum(v.get("stalls", 0) for v in ca.values() if isinstance(v, dict))
    if payload.get("sample"):
        result["sampleDecodeHits"] = sum(payload["sample"].get("decodeSymbolHits", {}).values())
        result["sampleEmpty"] = payload["sample"].get("emptyCallGraph")
    if payload.get("switches"):
        result.update(_switch_aggregate(payload["switches"]))
    if payload.get("trend"):
        result["footprintSlopeKBPerSample"] = round(
            payload["trend"].get("footprintBytes", {}).get("slopePerSample", 0) / 1024, 1)
        result["threadsSlope"] = payload["trend"].get("threads", {}).get("slopePerSample")
    return result


IDLE_LEAVES = ("__workq_kernreturn", "mach_msg2_trap", "start_wqthread", "thread_start",
                "_pthread_wqthread", "semaphore_wait_trap", "kevent", "read", "open",
                "__psynch_cvwait", "mach_msg_trap", "select", "psynch_cvwait")


def useful_leaves(sample: dict, limit: int = 8) -> list:
    """Leaf frames with idle plumbing removed (what work actually ran)."""
    rows = []
    for row in sample.get("topLeaves") or []:
        if any(row["leaf"].startswith(name) for name in IDLE_LEAVES):
            continue
        rows.append(row)
        if len(rows) >= limit:
            break
    return rows


def report_markdown(result_path: Path, out_path: Path | None = None) -> str:
    result = json.loads(Path(result_path).read_text())
    lines = [f"# UI perf report — {result.get('runId')}", "",
             f"- app: `{result.get('app', {}).get('path')}`",
             f"- executable sha256: `{result.get('app', {}).get('executableSha256')}`", ""]
    lines.append("| scenario | repeats | CPU p50 % | CPU p95 % | CPU worst % | fp max MB | "
                 "threads | CA commits | CA stalls | AX p50 ms |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    for name, data in result.get("scenarios", {}).items():
        repeats = [r for r in data.get("repeats", []) if not r.get("blocked")]
        blocked = len(data.get("repeats", [])) - len(repeats)
        if not repeats:
            lines.append(f"| {name} | 0 (blocked {blocked}) | – | – | – | – | – | – | – | – |")
            continue
        rows = []
        for rep in repeats:
            cpu = rep.get("cpuAll") or rep.get("cpu") or rep.get("idle", {}).get("cpuAll") or {}
            mon = rep.get("monitor") or rep.get("idle", {}).get("monitor") or {}
            ca = rep.get("ca") if isinstance(rep.get("ca"), dict) and "commits" in rep.get("ca", {}) else None
            commits = stalls = None
            if ca:
                commits, stalls = ca.get("commits"), ca.get("stalls")
            elif rep.get("switches"):
                commits = sum(s.get("ca", {}).get("commits", 0) for s in rep["switches"])
                stalls = sum(s.get("ca", {}).get("stalls", 0) for s in rep["switches"])
            elif isinstance(rep.get("ca"), dict):
                commits = sum(v.get("commits", 0) for v in rep["ca"].values() if isinstance(v, dict))
                stalls = sum(v.get("stalls", 0) for v in rep["ca"].values() if isinstance(v, dict))
            ax = [s.get("axLatencyBeforeMs", {}).get("p50") for s in rep.get("switches", [])]
            ax = [v for v in ax if isinstance(v, (int, float))]
            rows.append({
                "cpu": cpu, "mon": mon, "commits": commits, "stalls": stalls,
                "ax": statistics.fmean(ax) if ax else None,
            })
        def avg(key, sub=None):
            values = []
            for row in rows:
                value = row[key]
                if sub:
                    value = (value or {}).get(sub)
                values.append(value)
            values = [v for v in values if isinstance(v, (int, float))]
            return round(statistics.fmean(values), 2) if values else None
        fp = [(row["mon"].get("footprintBytes") or {}).get("max", 0) / 2**20 for row in rows]
        th = [(row["mon"].get("threads") or {}).get("max") for row in rows]
        th = [v for v in th if v]
        lines.append(
            f"| {name} | {len(repeats)} | {avg('cpu', 'p50')} | {avg('cpu', 'p95')} | "
            f"{avg('cpu', 'worst')} | {round(statistics.fmean(fp), 1) if fp else None} | "
            f"{max(th) if th else None} | {avg('commits')} | {avg('stalls')} | "
            f"{round(statistics.fmean([r['ax'] for r in rows if r['ax'] is not None]), 2) if any(r['ax'] is not None for r in rows) else None} |")
    # hotspots
    lines.append("")
    lines.append("## sample hotspots (idle frames filtered)")
    for name, data in result.get("scenarios", {}).items():
        for rep in data.get("repeats", []):
            sample = rep.get("sample")
            if not sample or sample.get("emptyCallGraph"):
                continue
            leaves = useful_leaves(sample)
            hits = sample.get("decodeSymbolHits") or {}
            lines.append(f"- {name} r{rep.get('repeat')}: " +
                         ", ".join(f"{row['leaf']}×{row['samples']}" for row in leaves[:6]) +
                         (f" | decode symbols: {hits}" if hits else " | no decode symbols"))
            break
    if result.get("anomalies"):
        lines.append("")
        lines.append("## anomalies")
        for entry in result["anomalies"][:40]:
            lines.append(f"- [{entry['scenario']} r{entry['repeat']}] {entry['kind']}: "
                         f"{entry['detail'][:180]}")
    text = "\n".join(lines) + "\n"
    target = Path(out_path) if out_path else Path(result_path).with_name("report.md")
    target.write_text(text, encoding="utf-8")
    return text


def compare_runs(left_path: Path, right_path: Path) -> dict:
    """Baseline vs candidate on the same schema (S7 cells and S8 sub-runs included)."""
    left = json.loads(Path(left_path).read_text())
    right = json.loads(Path(right_path).read_text())
    report = {
        "baseline": {"path": str(left_path), "runId": left.get("runId"),
                     "executableSha256": left.get("app", {}).get("executableSha256")},
        "candidate": {"path": str(right_path), "runId": right.get("runId"),
                      "executableSha256": right.get("app", {}).get("executableSha256")},
        "scenarios": {},
    }

    def reduce_dataset(dataset: dict) -> dict:
        """Average the comparable numbers across repeats (and S7 cells / S8 subs)."""
        out = {}
        for name, data in dataset.items():
            repeats = data.get("repeats", [])
            if name == "S7":
                cells = {}
                for entry in repeats:
                    for cell in entry.get("cells", []):
                        label = "-".join(str(cell.get("cell", {}).get(k))
                                         for k in ("theme", "font", "thumbnails"))
                        cells[label] = _flat_scenario(cell)
                out[name] = {"cells": cells}
                continue
            if name == "S8":
                subs = {}
                for entry in repeats:
                    for sub_name, sub_payload in (entry.get("results") or {}).items():
                        sub_repeats = sub_payload.get("repeats") or [sub_payload]
                        metric_rows = [_flat_scenario(row) for row in sub_repeats]
                        merged = {}
                        for key in {k for row in metric_rows for k in row}:
                            values = [row.get(key) for row in metric_rows]
                            merged[key] = _mean([v for v in values
                                                 if isinstance(v, (int, float))])
                        subs[sub_name] = merged
                out[name] = {"subScenarios": subs, "motionSetting": "off"}
                continue
            metric_rows = [_flat_scenario(row) for row in repeats] or [_flat_scenario(data)]
            merged = {}
            for key in {k for row in metric_rows for k in row}:
                values = [row.get(key) for row in metric_rows]
                merged[key] = _mean([v for v in values if isinstance(v, (int, float))])
            merged["repeats"] = len(repeats)
            out[name] = merged
        return out

    left_flat = reduce_dataset(left.get("scenarios", {}))
    right_flat = reduce_dataset(right.get("scenarios", {}))

    def diff_block(a: dict, b: dict) -> dict:
        rows = {}
        for key in sorted(set(a) | set(b)):
            av, bv = a.get(key), b.get(key)
            row = {"baseline": av, "candidate": bv}
            if isinstance(av, (int, float)) and isinstance(bv, (int, float)):
                row["delta"] = round(bv - av, 2)
                row["pct"] = round((bv - av) / av * 100, 1) if av else None
            rows[key] = row
        return rows

    for name in sorted(set(left_flat) | set(right_flat)):
        entry = {}
        left_rows = left_flat.get(name, {})
        right_rows = right_flat.get(name, {})
        if "cells" in left_rows or "cells" in right_rows:
            entry["cells"] = {}
            for label in sorted(set(left_rows.get("cells", {})) | set(right_rows.get("cells", {}))):
                entry["cells"][label] = diff_block(left_rows.get("cells", {}).get(label, {}),
                                                   right_rows.get("cells", {}).get(label, {}))
        elif "subScenarios" in left_rows or "subScenarios" in right_rows:
            entry["subScenarios"] = {}
            for label in sorted(set(left_rows.get("subScenarios", {}))
                                | set(right_rows.get("subScenarios", {}))):
                entry["subScenarios"][label] = diff_block(
                    left_rows.get("subScenarios", {}).get(label, {}),
                    right_rows.get("subScenarios", {}).get(label, {}))
        else:
            entry.update(diff_block(left_rows, right_rows))
        report["scenarios"][name] = entry
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default=str(DEFAULT_APP),
                        help="development bundle to measure (for before/after runs)")
    parser.add_argument("--label", default=None,
                        help="evidence subdirectory name (default baseline-HHMM)")
    parser.add_argument("--out", default=None, help="explicit evidence directory")
    parser.add_argument("--only", default=None, help="comma separated scenario ids")
    parser.add_argument("--repeat", type=int, default=3,
                        help="repeats per scenario (default 3)")
    parser.add_argument("--sample-seconds", type=int, default=4)
    parser.add_argument("--extract-wait", type=float, default=6.0,
                        help="seconds to let the queue run in S10")
    parser.add_argument("--lock-timeout", type=float, default=3600.0)
    parser.add_argument("--no-clean-roots", dest="clean_roots", action="store_false",
                        default=True)
    parser.add_argument("--no-activate", dest="no_activate", action="store_true",
                        help="never call NSRunningApplication/AX activation (Lead rule)")
    parser.add_argument("--resume", action="store_true",
                        help="merge into an existing evidence directory (re-run only --only)")
    parser.add_argument("--report", metavar="RESULT_JSON",
                        help="write a markdown report for one result.json")
    parser.add_argument("--compare", nargs=2, metavar=("BASELINE", "CANDIDATE"),
                        help="compare two result.json files instead of measuring")
    args = parser.parse_args()
    if args.report:
        print(report_markdown(Path(args.report)))
        return
    if args.compare:
        report = compare_runs(Path(args.compare[0]), Path(args.compare[1]))
        target = Path(args.out) / "compare.json" if args.out else \
            Path(args.compare[1]).with_name("compare.json")
        write_json(target, report)
        print(f"wrote {target}")
        return
    if args.repeat < 1:
        raise SystemExit("--repeat must be >= 1")
    result = run_all(args)
    summary = {name: len(data.get("repeats", [])) for name, data in
               result["scenarios"].items()}
    print(json.dumps({"scenarios": summary, "anomalies": len(result["anomalies"])},
                     ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
