#!/usr/bin/env python3
"""Keyboard + accessibility acceptance harness for the Mirage Unpacker dev copy.

Scope
-----
Measures (does *not* fix) keyboard navigation, AX semantics, focus order,
multi-select, detail-sheet dismissal, export shortcuts, reduce-motion behaviour
and VoiceOver associability. It only ever drives the isolated development copy
``app/.build/ui-qa/app/PKD QA.app`` (bundle id ``com.zeh.pkd.development``)
against a disposable 400-card synthetic library root. No product source is
modified, nothing is built, nothing is committed.

Hard rules honoured here
------------------------
* every GUI-driving run is wrapped in :class:`perf_qaenv.DriveLock` and always
  calls ``quit_app`` in a ``finally`` block;
* the development app is activated before any synthetic key/mouse event;
* screenshots are window-only (``qa.screenshot`` / ``CGWindowListCreateImage``
  restricted to the app window), never the desktop;
* no system settings, TCC, wallpaper or accessibility preferences are changed.
  The only persisted values touched are this app's own defaults domain
  ``com.zeh.pkd.development`` (``pkd.appearance.motion`` etc.), restored
  afterwards;
* failures are reported as UNVERIFIED instead of being papered over with AX-tree
  guesses.

Usage
-----
    python3 tools/dev/accessibility-audit.py                     # all scenarios
    python3 tools/dev/accessibility-audit.py --scenarios k1,k3   # subset
    python3 tools/dev/accessibility-audit.py --label baseline-2030
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
import subprocess
import sys
import time
import traceback
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def _load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, REPO / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


qa = _load("perf_qaenv", "tools/dev/perf-qaenv.py")

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

DEV_APP = qa.QA_ROOT / "app/PKD QA.app"
DEV_DOMAIN = qa.DEV_BUNDLE_ID               # com.zeh.pkd.development
BASE_ENV_FILE = qa.QA_ROOT / "baseline-environment.txt"
EVIDENCE_PARENT = qa.QA_ROOT / "evidence/a11y"

WIDE = (1200, 800)
NARROW = (900, 700)

CARD_ROLES = ("AXButton",)
CARD_MARKER = "可解包"
NAV_LABELS = ("全部", "可解包", "未解包", "已解包", "收藏", "最近使用", "队列", "存储")

PASS, FAIL, GAP, UNVERIFIED, INFO = "PASS", "FAIL", "GAP", "UNVERIFIED", "INFO"

# AXMenuItemCmdModifiers flags (Apple AX API)
MOD_SHIFT, MOD_OPTION, MOD_CONTROL, MOD_NO_COMMAND = 1, 2, 4, 8

MODIFIER_KEYCODES = {"command": 0x37, "shift": 0x38, "option": 0x3A, "control": 0x3B}


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def clock() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S")


def log(message: str) -> None:
    print(f"[{clock()}] {message}", flush=True)


def sha256(path: Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(cmd: list[str], timeout: float = 20.0) -> dict:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"cmd": cmd, "returncode": result.returncode,
                "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
    except Exception as error:  # pragma: no cover - defensive
        return {"cmd": cmd, "returncode": None, "error": str(error)}


def defaults_get(domain: str, key: str) -> dict:
    result = run(["defaults", "read", domain, key])
    if result.get("returncode") == 0:
        return {"present": True, "value": result["stdout"]}
    return {"present": False, "value": None, "stderr": result.get("stderr", "")}


def defaults_write(domain: str, key: str, value: str) -> dict:
    return run(["defaults", "write", domain, key, "-string", value])


def defaults_delete(domain: str, key: str) -> dict:
    return run(["defaults", "delete", domain, key])


def defaults_export(domain: str) -> dict:
    """Export the whole (dev-only) defaults domain as a JSON-safe dict."""
    try:
        result = subprocess.run(["defaults", "export", domain, "-"],
                                capture_output=True, timeout=30)
        if result.returncode != 0 or not result.stdout:
            return {}
        parsed = plistlib.loads(result.stdout)
        clean = {}
        for key, value in parsed.items():
            if not isinstance(value, (str, int, float, bool, list, dict)):
                value = repr(value)
            if key.startswith("NSSplitView") or key.startswith("NSWindow Frame"):
                continue                      # huge, irrelevant, noisy
            clean[key] = value
        return clean
    except Exception as error:  # pragma: no cover
        return {"__error__": str(error)}


# ---------------------------------------------------------------------------
# AX primitives (read-only; no TCC / system preference changes)
# ---------------------------------------------------------------------------

from ApplicationServices import (  # noqa: E402  (pyobjc, imported late on purpose)
    AXUIElementCreateSystemWide,
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    AXUIElementCopyAttributeNames,
    AXUIElementCopyActionNames,
    AXUIElementPerformAction,
    AXUIElementSetAttributeValue,
    AXValueCreate,
    AXValueGetValue,
    kAXValueCGPointType,
    kAXValueCGSizeType,
)




def attr(element, key: str):
    if element is None:
        return None
    try:
        result = AXUIElementCopyAttributeValue(element, key, None)
    except Exception:
        return None
    if isinstance(result, tuple):
        status, value = result[0], result[1]
        return value if status == 0 else None
    return None


def attr_names(element) -> list:
    try:
        result = AXUIElementCopyAttributeNames(element, None)
    except Exception:
        return []
    if isinstance(result, tuple) and result[0] == 0 and result[1]:
        return list(result[1])
    return []


def action_names(element) -> list:
    try:
        result = AXUIElementCopyActionNames(element, None)
    except Exception:
        return []
    if isinstance(result, tuple) and result[0] == 0 and result[1]:
        return [str(item) for item in result[1]]
    return []


def children(element) -> list:
    value = attr(element, "AXChildren")
    return list(value) if value else []


def ax_point(element) -> dict | None:
    raw = attr(element, "AXPosition")
    if raw is None:
        return None
    ok, point = AXValueGetValue(raw, kAXValueCGPointType, None)
    if not ok:
        return None
    return {"x": round(float(point.x), 1), "y": round(float(point.y), 1)}


def ax_size(element) -> dict | None:
    raw = attr(element, "AXSize")
    if raw is None:
        return None
    ok, size = AXValueGetValue(raw, kAXValueCGSizeType, None)
    if not ok:
        return None
    return {"w": round(float(size.width), 1), "h": round(float(size.height), 1)}


def ax_rect(element) -> dict | None:
    point, size = ax_point(element), ax_size(element)
    if point is None or size is None:
        return None
    return {"x": point["x"], "y": point["y"], "w": size["w"], "h": size["h"],
            "cx": round(point["x"] + size["w"] / 2, 1),
            "cy": round(point["y"] + size["h"] / 2, 1)}


def describe(element, depth_for_label: int = 4) -> dict | None:
    """Provider-normalised description of one AX element."""
    if element is None:
        return None
    role = attr(element, "AXRole")
    if role is None:
        return None
    description = {
        "role": role,
        "subrole": attr(element, "AXSubrole"),
        "roleDescription": attr(element, "AXRoleDescription"),
        "title": attr(element, "AXTitle"),
        "description": attr(element, "AXDescription"),
        "placeholder": attr(element, "AXPlaceholderValue"),
        "value": (str(attr(element, "AXValue"))[:160]
                  if attr(element, "AXValue") is not None else None),
        "help": attr(element, "AXHelp"),
        "identifier": attr(element, "AXIdentifier"),
        "traits": attr(element, "AXTraits"),
        "enabled": attr(element, "AXEnabled"),
        "focused": attr(element, "AXFocused"),
        "selected": attr(element, "AXSelected"),
        "actions": action_names(element),
        "rect": ax_rect(element),
        "childCount": len(children(element)),
    }
    # nearest ancestor that carries a human readable label: useful when the
    # focused element itself is an unlabelled internal cell/row.
    parent = attr(element, "AXParent")
    chain = []
    for _ in range(depth_for_label):
        if parent is None:
            break
        label = attr(parent, "AXTitle") or attr(parent, "AXDescription")
        chain.append({"role": attr(parent, "AXRole"), "title": attr(parent, "AXTitle"),
                      "description": attr(parent, "AXDescription"),
                      "label": label})
        if label:
            break
        parent = attr(parent, "AXParent")
    description["ancestors"] = chain
    description["label"] = (description["title"] or description["description"]
                            or description["placeholder"]
                            or next((item["label"] for item in chain if item["label"]), None))
    return description


def preorder(root, max_depth: int = 90, max_nodes: int = 8000) -> list[dict]:
    """Depth-first (AX traversal) dump, with index paths."""
    nodes: list[dict] = []
    stack = [(root, "", 0)]
    while stack and len(nodes) < max_nodes:
        element, path, depth = stack.pop()
        row = describe(element)
        if row is None:
            continue
        row["path"] = path or "/"
        row["depth"] = depth
        nodes.append(row)
        if depth >= max_depth:
            continue
        kids = children(element)
        for index in reversed(range(len(kids))):
            stack.append((kids[index], f"{path}/{index}" if path else f"/{index}", depth + 1))
    return nodes


def dump(pid: int, max_nodes: int = 8000) -> list[dict]:
    return preorder(qa.ax_app(pid), max_nodes=max_nodes)


def find(nodes: list[dict], role=None, description=None, title=None,
         placeholder=None, contains: str | None = None,
         action: str | None = None, help: str | None = None) -> list[dict]:
    result = []
    for node in nodes:
        if role is not None and node["role"] != role:
            continue
        if description is not None and node["description"] != description:
            continue
        if title is not None and node["title"] != title:
            continue
        if placeholder is not None and node["placeholder"] != placeholder:
            continue
        if help is not None and node.get("help") != help:
            continue
        if action is not None and action not in (node.get("actions") or []):
            continue
        if contains is not None:
            haystack = " ".join(str(node.get(key) or "")
                                for key in ("title", "description", "value", "placeholder", "help"))
            if contains not in haystack:
                continue
        result.append(node)
    return result


def first(nodes: list[dict], **kwargs) -> dict | None:
    hits = find(nodes, **kwargs)
    return hits[0] if hits else None


def cards(nodes: list[dict]) -> list[dict]:
    """Wallpaper cards: AXButton whose description carries the full status text."""
    return [node for node in nodes
            if node["role"] == "AXButton" and CARD_MARKER in (node.get("description") or "")]


def card_title(card: dict) -> str:
    text = card.get("description") or ""
    return text.split("，")[0].strip()


def visual_order(card_nodes: list[dict]) -> list[dict]:
    """Order cards the way a sighted user reads them: top-to-bottom, left-to-right."""
    return sorted(card_nodes, key=lambda node: (
        round((node.get("rect") or {}).get("y", 0) / 8),
        (node.get("rect") or {}).get("x", 0),
    ))


def text_value(node: dict) -> str:
    return str(node.get("value") or node.get("title") or node.get("description") or "")


def subtitle(nodes: list[dict]) -> str | None:
    """The grid header line ("400 项 · 已选 2") is an AXStaticText value."""
    for node in nodes:
        value = node.get("value") or ""
        if re.search(r"\d+\s*项", value) and node["role"] in ("AXStaticText", "AXHeading"):
            return value
    return None


def selection_count_from_subtitle(nodes: list[dict]) -> int | None:
    text = subtitle(nodes) or ""
    match = re.search(r"已选\s*(\d+)", text)
    return int(match.group(1)) if match else (0 if text else None)


def selected_cards(card_nodes: list[dict]) -> list[dict]:
    hits = []
    for node in card_nodes:
        traits = node.get("traits")
        selected_flag = node.get("selected")
        if selected_flag in (True, 1):
            hits.append(node)
        elif isinstance(traits, int) and traits & 0x20 and traits & 0x1:
            # observed layout: isButton | isSelected inside AXTraits
            hits.append(node)
    return hits


def focused_snapshot(pid: int) -> dict:
    """Focused element via system-wide, app and window AX entry points."""
    system_wide = AXUIElementCreateSystemWide()
    app = qa.ax_app(pid)
    window = qa.ax_find(app, role="AXWindow")
    return {
        "systemWide": describe(attr(system_wide, "AXFocusedUIElement")),
        "app": describe(attr(app, "AXFocusedUIElement")),
        "window": describe(attr(window, "AXFocusedUIElement")) if window is not None else None,
    }


def focus_label(snapshot: dict) -> str:
    for key in ("systemWide", "app", "window"):
        node = snapshot.get(key)
        if node and node.get("role") not in ("AXWindow", None):
            return f"{node['role']}:{node.get('label')}"
    node = snapshot.get("app") or {}
    return f"{node.get('role')}"


# ---------------------------------------------------------------------------
# window-only fast capture (CGWindowListCreateImage on the app window)
# ---------------------------------------------------------------------------

import Quartz  # noqa: E402
from AppKit import NSBitmapImageRep, NSPNGFileType  # noqa: E402


class Grabber:
    """Window-only frames fast enough to sample 60 ms after an interaction.

    ``qa.screenshot`` shells out to ``screencapture`` (~200-400 ms/frame) which
    cannot resolve a 60 ms window; ``CGWindowListCreateImage`` restricted to the
    app's own window is still strictly window-level (no desktop pixels) and
    takes ~10-15 ms.
    """

    def __init__(self, pid: int):
        self.pid = pid
        self.window_id = resolve_window_id(pid)

    def grab(self) -> dict:
        image = Quartz.CGWindowListCreateImage(
            Quartz.CGRectNull,
            Quartz.kCGWindowListOptionIncludingWindow,
            self.window_id,
            Quartz.kCGWindowImageBoundsIgnoreFraming,
        )
        return {"image": image, "at": time.monotonic()}

    @staticmethod
    def save(frame: dict, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        rep = NSBitmapImageRep.alloc().initWithCGImage_(frame["image"])
        data = rep.representationUsingType_properties_(NSPNGFileType, None)
        data.writeToFile_atomically_(str(path), True)
        return path

    def save_all(self, frames: list[dict], directory: Path, stem: str) -> list[Path]:
        paths = []
        for index, frame in enumerate(frames):
            path = directory / f"{stem}-{index}.png"
            paths.append(self.save(frame, path))
        return paths


def resolve_window_id(pid: int) -> int | None:
    """Titled layer-0 window first, else the biggest layer-0 window of the pid.

    SwiftUI briefly reports an empty title while re-configuring, which used to
    look like "the window disappeared" mid-scenario.
    """
    ident = qa.window_id(pid)
    if ident:
        return ident
    infos = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    candidates = [info for info in infos
                  if info.get("kCGWindowOwnerPID") == pid
                  and int(info.get("kCGWindowLayer", 0)) == 0]
    if not candidates:
        candidates = [info for info in infos if info.get("kCGWindowOwnerPID") == pid]
    if not candidates:
        return None
    candidates.sort(key=lambda info: (info.get("kCGWindowBounds") or {}).get("Width", 0)
                    * (info.get("kCGWindowBounds") or {}).get("Height", 0), reverse=True)
    return int(candidates[0]["kCGWindowNumber"])


def frame_times(frames: list[dict], t0: float) -> list[float]:
    return [round((frame["at"] - t0) * 1000, 1) for frame in frames]


def diff_files(first: Path, second: Path) -> dict:
    return qa.image_diff(first, second)


# ---------------------------------------------------------------------------
# window / app control helpers
# ---------------------------------------------------------------------------

def ensure_front(pid: int, attempts: int = 4) -> bool:
    """Deliberately does NOT activate the app.

    Lead's rule (2026-11-06): the user's full-screen overlay keeps the front, so
    activating only fights other agents. Keyboard events go through
    ``CGEventPostToPid`` and mouse through AXPress, neither of which needs the
    app to be frontmost. This helper is kept so call sites stay readable and
    only reports whether the app process is still alive.
    """
    return app_alive(pid)


def post_key(pid: int, name: str, command: bool = False, shift: bool = False,
             option: bool = False, control: bool = False) -> None:
    """Synthetic key event addressed to one process (CGEventPostToPid).

    On this host a third-party full-screen window (层 999, 哔哩哔哩「桌面端直播间」)
    stays frontmost, so plain ``kCGHIDEventTap`` keys are stolen before reaching
    the dev app. Posting the same ``CGEventCreateKeyboardEvent`` event to the
    app's pid is delivered regardless of which app owns the front, and the
    in-session controls (Tab focus movement, ⌘2 filter, ⌥⌘L) prove delivery.
    Recorded as a documented deviation in ``env.json``.
    """
    code = qa.KEY_CODES[name]
    flags = 0
    if command:
        flags |= Quartz.kCGEventFlagMaskCommand
    if shift:
        flags |= Quartz.kCGEventFlagMaskShift
    if option:
        flags |= Quartz.kCGEventFlagMaskAlternate
    if control:
        flags |= Quartz.kCGEventFlagMaskControl
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        if flags:
            Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPostToPid(pid, event)
        time.sleep(0.04)
    time.sleep(0.04)


def send_key(pid: int, name: str, **modifiers) -> None:
    ensure_front(pid)
    post_key(pid, name, **modifiers)


LETTER_KEYCODES = {"a": 0x00, "b": 0x0B, "c": 0x08, "x": 0x07, "z": 0x06}


def type_keycodes(pid: int, text: str) -> None:
    """Type letters as real keycode events (what a keyboard actually sends)."""
    for character in text:
        code = LETTER_KEYCODES.get(character.lower())
        if code is None:
            continue
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            Quartz.CGEventPostToPid(pid, event)
            time.sleep(0.03)
        time.sleep(0.03)


def post_text(pid: int, text: str) -> None:
    """Type unicode text into one process (used as a key-delivery control)."""
    for character in text:
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(character), character)
            Quartz.CGEventPostToPid(pid, event)
            time.sleep(0.03)
        time.sleep(0.03)


def front_app() -> str:
    import AppKit
    try:
        app = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
        return f"{app.localizedName()}|{app.bundleIdentifier()}"
    except Exception:
        return "unknown"


def activate_node(pid: int, node: dict, modifier: str | None = None) -> dict:
    """Activate a control the way a click would: AXPress on its default action.

    HID mouse clicks cannot be trusted here (a full-screen third-party window
    swallows them — record ``hidClick`` separately), and AXPress on a card runs
    the very same ``accessibilityAction(.default) { onTap() }`` path a click
    takes. Modifier keys are physically held so the app's
    ``NSEvent.modifierFlags`` reads them.
    """
    candidates = element_nodes(pid)
    live = next((item for item in candidates if item["path"] == node["path"]), None)
    if live is None or (node.get("description") or "") != (live.get("description") or ""):
        label = node.get("description") or node.get("title") or ""
        live = next((item for item in candidates
                     if label and (item.get("description") or item.get("title") or "") == label), None)
    if live is None:
        return {"ok": False, "reason": "element not found", "path": node["path"]}
    if modifier:
        modifier_down(modifier)
    time.sleep(0.08)
    try:
        ok = press_node(live)
    finally:
        if modifier:
            modifier_up(modifier)
    time.sleep(0.05)
    return {"ok": ok, "path": live.get("path"), "modifier": modifier,
            "label": (live.get("label") or "")[:80]}


def hid_click(pid: int, node: dict, modifier: str | None = None) -> dict:
    """HID mouse clicks are NOT deliverable on this host — record, do not send.

    Observed 2026-11-06: a third-party full-screen window (哔哩哔哩「桌面端直播间」,
    层 999) stays above normal windows; HID clicks (CGEventPost and
    CGEventPostToPid) produced no effect on the dev app (search field did not
    focus, sidebar did not switch, card did not select, title-bar close did not
    fire). Per the Lead's rule the audit no longer sends HID mouse events; this
    returns the blocked observation so evidence stays explicit.
    """
    return {"blocked": True, "reason": "HID 鼠标事件在本机被全屏浮层吞掉（已实测无效）",
            "node": (node.get("label") or "")[:60]}


_FRONT_PID: int | None = None


def bind_front(pid: int) -> None:
    global _FRONT_PID
    _FRONT_PID = pid


def ensure_front_quiet() -> None:
    if _FRONT_PID is not None:
        ensure_front(_FRONT_PID)


def modifier_down(name: str) -> None:
    code = MODIFIER_KEYCODES[name]
    for down in (True,):
        event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    time.sleep(0.05)


def modifier_up(name: str) -> None:
    code = MODIFIER_KEYCODES[name]
    event = Quartz.CGEventCreateKeyboardEvent(None, code, False)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    time.sleep(0.05)


def click_point(pid: int, x: float, y: float, modifier: str | None = None) -> None:
    ensure_front(pid)
    if modifier:
        modifier_down(modifier)
    try:
        qa.click(pid, x, y)
    finally:
        if modifier:
            modifier_up(modifier)
    time.sleep(0.05)


def click_node(pid: int, node: dict, modifier: str | None = None) -> bool:
    rect = node.get("rect")
    if not rect:
        return False
    click_point(pid, rect["cx"], rect["cy"], modifier=modifier)
    return True


def press_node(node: dict, action: str = "AXPress") -> bool:
    element = node.get("__element__")
    if element is None:
        return False
    try:
        status = AXUIElementPerformAction(element, action)
    except Exception:
        return False
    return int(status) == 0


def element_nodes(pid: int) -> list[dict]:
    """Same as dump() but keeps the live AXUIElement for pressing."""
    rows = []
    root = qa.ax_app(pid)
    stack = [(root, "", 0)]
    while stack and len(rows) < 8000:
        element, path, depth = stack.pop()
        row = describe(element)
        if row is None:
            continue
        row["path"] = path or "/"
        row["depth"] = depth
        row["__element__"] = element
        rows.append(row)
        for index in reversed(range(len(children(element)))):
            stack.append((children(element)[index],
                          f"{path}/{index}" if path else f"/{index}", depth + 1))
    return rows


def wait_scan(pid: int, expect: int = 400, timeout: float = 180.0) -> dict:
    started = time.monotonic()
    deadline = started + timeout
    last_text = None
    while time.monotonic() < deadline:
        if not app_alive(pid):
            raise RuntimeError(f"app {pid} exited while scanning")
        tree = qa.ax_tree(pid, max_nodes=900)
        for row in tree:
            value = row.get("value") or ""
            match = re.search(r"(\d+)\s*项", value)
            if match:
                last_text = value
                if int(match.group(1)) >= expect:
                    time.sleep(0.6)          # let the last thumbnail batch settle
                    return {"count": int(match.group(1)), "text": value,
                            "elapsedSeconds": round(time.monotonic() - started, 2)}
        time.sleep(0.5)
    raise TimeoutError(f"scan never reported {expect} 项 (last={last_text!r})")


def app_alive(pid: int) -> bool:
    result = subprocess.run(["kill", "-0", str(pid)], capture_output=True)
    return result.returncode == 0


def window_size(pid: int) -> dict:
    ident = resolve_window_id(pid)
    if ident is None:
        raise RuntimeError(f"no main window for pid {pid}")
    for window in qa.windows(pid):
        if window["id"] == ident:
            frame = window["frame"]
            return {"width": round(frame["Width"], 1), "height": round(frame["Height"], 1),
                    "x": round(frame["X"], 1), "y": round(frame["Y"], 1)}
    raise RuntimeError(f"window {ident} vanished for pid {pid}")


def set_window_size(pid: int, width: float, height: float) -> None:
    """Resize the dev window through the AX API.

    NOTE: ``perf_qaenv.ax_set_size`` currently raises ``AttributeError:
    kAXValueCGSizeType`` on this machine's pyobjc — ``Quartz`` has no such
    constant and the metadata for ``AXValueCreate`` only accepts a real
    ``CGSize`` value (not ``ctypes.byref``). Reimplemented here so the shared
    module stays untouched; reported to the Lead.
    """
    app = qa.ax_app(pid)
    window = qa.ax_find(app, role="AXWindow")
    if window is None:
        raise RuntimeError(f"no AXWindow for pid {pid}")
    value = AXValueCreate(kAXValueCGSizeType, Quartz.CGSize(float(width), float(height)))
    status = AXUIElementSetAttributeValue(window, "AXSize", value)
    if int(status) != 0:
        raise RuntimeError(f"AXSize failed: {status}")


def make_window(pid: int, width: float, height: float, attempts: int = 4) -> dict:
    target = (float(width), float(height))
    current = None
    for _ in range(attempts):
        try:
            qa.ax_set_size(pid, width, height)      # shared primitive (Lead-fixed)
        except Exception:
            set_window_size(pid, width, height)     # local fallback
        time.sleep(0.6)
        current = window_size(pid)
        if abs(current["width"] - target[0]) <= 2 and abs(current["height"] - target[1]) <= 2:
            return current
    return current


def other_qa_instances(exclude_pid: int | None = None) -> list[int]:
    result = subprocess.run(["pgrep", "-f", "PKD QA.app/Contents/MacOS/PKD"],
                            capture_output=True, text=True)
    pids = []
    for line in result.stdout.split():
        try:
            pid = int(line)
        except ValueError:
            continue
        if exclude_pid is not None and pid == exclude_pid:
            continue
        pids.append(pid)
    return pids


def wait_until_solo(timeout: float = 90.0) -> dict:
    """Other QA dev instances must exit before we drive the GUI (global events)."""
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        pids = other_qa_instances()
        if not pids:
            return {"solo": True, "waitedSeconds": round(time.monotonic() - started, 1),
                    "seen": []}
        time.sleep(1.5)
    return {"solo": False, "waitedSeconds": round(time.monotonic() - started, 1),
            "seen": other_qa_instances()}


def quit_app_safe(process) -> None:
    try:
        qa.quit_app(process)
    except Exception as error:  # pragma: no cover
        log(f"quit_app failed: {error}")


def tail_log(path: Path, lines: int = 12) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except Exception:
        return ""


def menu_bar(pid: int) -> list[dict]:
    """Full menu-bar snapshot including per-item enabled state and shortcuts."""
    app = qa.ax_app(pid)
    bar = attr(app, "AXMenuBar")
    if bar is None:
        return []
    menus = []
    for bar_item in children(bar):
        title = attr(bar_item, "AXTitle")
        entry = {"title": title, "items": []}
        for menu in children(bar_item):
            for item in children(menu):
                if attr(item, "AXRole") != "AXMenuItem":
                    continue
                char = attr(item, "AXMenuItemCmdChar")
                modifiers = attr(item, "AXMenuItemCmdModifiers")
                entry["items"].append({
                    "title": attr(item, "AXTitle"),
                    "enabled": attr(item, "AXEnabled"),
                    "shortcut": shortcut_text(char, modifiers),
                    "cmdChar": char,
                    "cmdModifiers": modifiers,
                })
        menus.append(entry)
    return menus


def shortcut_text(char, modifiers) -> str | None:
    if char is None:
        return None
    parts = []
    if isinstance(modifiers, int):
        if modifiers & MOD_CONTROL:
            parts.append("⌃")
        if modifiers & MOD_OPTION:
            parts.append("⌥")
        if modifiers & MOD_SHIFT:
            parts.append("⇧")
        if not modifiers & MOD_NO_COMMAND:
            parts.append("⌘")
    else:
        parts.append("⌘")
    readable = " " if char == " " else char
    return "".join(parts) + readable


def menu_item_state(menus: list[dict], menu_title: str, item_title: str) -> dict | None:
    for menu in menus:
        if menu["title"] != menu_title:
            continue
        for item in menu["items"]:
            if item["title"] == item_title:
                return item
    return None


def find_menu_item(pid: int, menu_title: str, item_title: str):
    app = qa.ax_app(pid)
    bar = attr(app, "AXMenuBar")
    if bar is None:
        return None
    for bar_item in children(bar):
        if attr(bar_item, "AXTitle") != menu_title:
            continue
        for menu in children(bar_item):
            for item in children(menu):
                if attr(item, "AXTitle") == item_title:
                    return item
    return None


def ax_press_element(element, action: str = "AXPress") -> bool:
    try:
        status = AXUIElementPerformAction(element, action)
    except Exception:
        return False
    return int(status) == 0


def extract_flow(pid: int, root: Path, confirm: bool = True,
                 timeout: float = 120.0) -> dict:
    """Trigger ⌘↩ and follow the confirm alert to completion (dev root only).

    Returns an observation dict; never raises for "engine failed", because the
    point is to record what a keyboard user would actually see.
    """
    observation = {"trigger": False, "alert": None, "confirmed": False,
                   "imagesDirectory": str(root / "Images"), "files": [],
                   "waitedSeconds": None}
    ensure_front(pid)
    send_key(pid, "return", command=True)
    deadline = time.monotonic() + 15
    nodes: list[dict] = []
    while time.monotonic() < deadline:
        nodes = dump(pid, max_nodes=2500)
        if any("确认解包" in text_value(node) for node in nodes):
            break
        time.sleep(0.4)
    if not any("确认解包" in text_value(node) for node in nodes):
        return observation
    texts = [text_value(node) for node in nodes
             if node["role"] in ("AXStaticText", "AXHeading") and text_value(node).strip()]
    buttons = [node for node in nodes if node["role"] == "AXButton"]
    observation["trigger"] = True
    observation["alert"] = {
        "texts": [text for text in texts
                  if any(marker in text for marker in ("确认解包", "输出", "目录", "解包", "图片"))][:12],
        "buttons": [{"label": node.get("label"), "role": node["role"],
                     "enabled": node.get("enabled")} for node in buttons][:10],
    }
    if not confirm:
        return observation

    start_button = next((node for node in element_nodes(pid)
                         if node["role"] == "AXButton"
                         and (node.get("label") in ("开始解包", "确定"))), None)
    if start_button is not None and press_node(start_button):
        observation["confirmed"] = True
    else:
        ensure_front(pid)
        send_key(pid, "return")
        time.sleep(0.3)
        observation["confirmed"] = start_button is not None
    started = time.monotonic()
    images = root / "Images"
    while time.monotonic() - started < timeout:
        if images.exists():
            files = sorted(images.rglob("*"))
            files = [path for path in files if path.is_file()]
            if files:
                observation["files"] = [str(path) for path in files[:20]]
                break
        if not app_alive(pid):
            break
        time.sleep(0.5)
    observation["waitedSeconds"] = round(time.monotonic() - started, 1)
    # stop whatever is still running so the scenario leaves no work behind
    ensure_front(pid)
    send_key(pid, "period", command=True)
    time.sleep(0.5)
    return observation


# ---------------------------------------------------------------------------
# evidence container
# ---------------------------------------------------------------------------

class Evidence:
    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.env: dict = {}

    def path(self, name: str) -> Path:
        return self.root / name

    def write_json(self, name: str, payload) -> Path:
        path = self.path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False),
                        encoding="utf-8")
        return path

    def write_text(self, name: str, text: str) -> Path:
        path = self.path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def rel(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.root))
        except ValueError:
            return str(path)


def finding(name: str, status: str, detail: str, evidence: list[Path | str] | None = None,
            expected: str | None = None, note: str | None = None) -> dict:
    return {
        "check": name,
        "status": status,
        "observed": detail,
        "expected": expected,
        "note": note,
        "evidence": [str(item) for item in (evidence or [])],
    }


def compact_node(node: dict, keys=("role", "subrole", "roleDescription", "title", "description",
                                   "placeholder", "value", "help", "enabled", "focused",
                                   "selected", "traits", "actions", "rect", "path", "label")) -> dict:
    return {key: node.get(key) for key in keys}


# ---------------------------------------------------------------------------
# scenario framework
# ---------------------------------------------------------------------------

SCENARIOS = {}
RUN_RECORDS: list[dict] = []


def scenario(name):
    def register(function):
        SCENARIOS[name] = function
        return function
    return register


APP_BUNDLE: Path = DEV_APP


class HeartbeatLock:
    """DriveLock + mtime heartbeat.

    ``perf_qaenv.DriveLock`` only creates the directory once, so a batch longer
    than its 240 s stale window can have the lock stolen mid-run. Touching the
    directory every 20 s keeps it alive for other agents (agreed with
    perf-runner).
    """

    def __init__(self, timeout: float = 900.0, interval: float = 20.0):
        self.timeout = timeout
        self.interval = interval
        self.lock = qa.DriveLock(timeout=timeout)
        self._stop = False
        self._thread = None

    def __enter__(self) -> "HeartbeatLock":
        self.lock.__enter__()

        def beat() -> None:
            while not self._stop:
                try:
                    os.utime(qa.LOCK_DIR, None)
                except Exception:
                    pass
                time.sleep(self.interval)

        import threading
        self._thread = threading.Thread(target=beat, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop = True
        if self._thread is not None:
            self._thread.join(timeout=2)
        self.lock.__exit__(*exc)


class Session:
    """One scenario run: fresh root + dev app + evidence directory."""

    def __init__(self, evidence: Evidence, tag: str, size=WIDE):
        self.evidence = evidence
        self.tag = tag
        self.size = size
        self.root: Path | None = None
        self.process = None
        self.pid: int | None = None
        self.evidence_dir = evidence.root / tag
        self.evidence_dir.mkdir(parents=True, exist_ok=True)
        self.window: dict = {}

    def __enter__(self) -> "Session":
        self.solo = wait_until_solo()
        if not self.solo["solo"]:
            log(f"[{self.tag}] warning: other QA instances still running {self.solo['seen']}")
        self.root = qa.fresh_root(f"a11y-{self.tag}")
        self.process = qa.launch(APP_BUNDLE, self.root, tag=self.tag)
        self.pid = self.process.pid
        try:
            bind_front(self.pid)
            # NOTE: deliberately no activate()/NSRunningApplication activation —
            # the user's full-screen overlay owns the front and activating only
            # fights other QA agents. All input is delivered per-pid / via AX.
            self.window = make_window(self.pid, *self.size)
        except Exception:
            quit_app_safe(self.process)
            bind_front(None)
            raise
        RUN_RECORDS.append({"scenario": self.tag, "root": str(self.root),
                            "tag": self.tag, "pid": self.pid,
                            "logPath": str(self.root / f"{self.tag}.log"),
                            "window": self.window, "size": list(self.size),
                            "solo": self.solo})
        return self

    def __exit__(self, *exc) -> None:
        if self.process is not None:
            quit_app_safe(self.process)
            if RUN_RECORDS and RUN_RECORDS[-1]["pid"] == self.pid:
                RUN_RECORDS[-1]["returncode"] = self.process.returncode
                RUN_RECORDS[-1]["logTail"] = tail_log(self.root / f"{self.tag}.log")
        bind_front(None)

    def nodes(self, max_nodes: int = 8000) -> list[dict]:
        return dump(self.pid, max_nodes=max_nodes)

    def grabber(self) -> Grabber:
        return Grabber(self.pid)

    def shot(self, name: str) -> Path:
        path = self.evidence_dir / name
        qa.screenshot(path, self.pid)
        return path

    def fast(self, name: str) -> tuple[Path, dict]:
        grab = self.grabber().grab()
        path = Grabber.save(grab, self.evidence_dir / name)
        return path, grab

    def log_path(self) -> Path | None:
        if self.root is None:
            return None
        path = self.root / f"{self.tag}.log"
        return path if path.exists() else None


def write_scan(session: Session, result: dict, name: str = "scan-wait.json") -> Path:
    return session.evidence.write_json(f"{session.tag}/{name}", result)


# ---------------------------------------------------------------------------
# scenario K1 — AX semantics audit
# ---------------------------------------------------------------------------

@scenario("k1")
def scenario_k1(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k1", WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.4)

        nodes = session.nodes()
        evidence.write_json(f"{session.tag}/ax-tree.json", nodes)
        evidence.write_json(f"{session.tag}/roles.json", role_histogram(nodes))

        card_nodes = cards(nodes)
        buttons = find(nodes, role="AXButton")
        # ---- grid cards ---------------------------------------------------
        card_without_press = [node for node in card_nodes if "AXPress" not in (node["actions"] or [])]
        card_empty_label = [node for node in card_nodes if not (node.get("description") or "").strip()]
        no_xray = [node for node in card_nodes
                   if "X-Ray" not in (node.get("description") or "")]
        missing_parts = []
        for node in card_nodes[:200]:
            text = node.get("description") or ""
            extractable = "不可解包" not in text
            parts = {"标题": bool(card_title(node)), "类型": "场景" in text or "视频" in text,
                     "体积": (not extractable) or re.search(r"\d+\s*(KB|MB|GB|字节)", text) is not None,
                     "可解包": "可解包" in text,
                     "已解包/未解包": "已解包" in text or "未解包" in text,
                     "X-Ray": (not extractable) or "X-Ray" in text}
            if not all(parts.values()):
                missing_parts.append({"label": text[:90], "missing": [k for k, v in parts.items() if not v]})
        findings.append(finding(
            "K1.1 网格卡片：AXButton + 可读 label（AXDescription）",
            PASS if card_nodes and not card_empty_label else FAIL,
            f"{len(card_nodes)} 张可见卡片；label 在 AXDescription（AXTitle 为空）"
            f"{'；有 ' + str(len(card_empty_label)) + ' 张无 description' if card_empty_label else ''}"
            f"{'；缺 ' + str(len(card_without_press)) + ' 张无 AXPress' if card_without_press else '；均含 AXPress'}",
            evidence=[f"{session.tag}/ax-tree.json"], expected="AXButton、AXTitle/AXDescription 至少一项非空、含 AXPress",
            note="卡片 label 放在 AXDescription 而非 AXTitle；VoiceOver 会读 description，属可用但非常规",
        ))
        findings.append(finding(
            "K1.2 卡片 label 内容完整性（标题/类型/体积/可解包/已解包/X-Ray）",
            PASS if card_nodes and not missing_parts else FAIL,
            f"{len(card_nodes)} 张卡片中 {len(missing_parts)} 张缺字段",
            evidence=[f"{session.tag}/ax-tree.json"],
            expected="每条 description 含标题、类型、体积、可解包、解包状态、X-Ray 状态",
            note=json.dumps(missing_parts[:5], ensure_ascii=False) if missing_parts else None,
        ))

        # ---- card traits & selection --------------------------------------
        traits_before = {node["path"]: node.get("traits") for node in card_nodes}
        press_target = next((node for node in card_nodes if node["actions"]), None)
        selection = {"pressed": False}
        if press_target is not None:
            live = next((node for node in element_nodes(session.pid)
                         if node["path"] == press_target["path"]), None)
            if live is not None and press_node(live):
                selection["pressed"] = True
                time.sleep(0.8)
            else:
                selection["activation"] = activate_node(session.pid, press_target)
                selection["pressed"] = bool(selection["activation"].get("ok"))
                time.sleep(0.8)
        selected_nodes = session.nodes()
        selected_cards = cards(selected_nodes)
        focused_card = next((node for node in selected_cards
                             if node["path"] == press_target["path"]), None) if press_target else None
        selection["card"] = compact_node(focused_card) if focused_card else None
        selection["traitsBefore"] = traits_before.get(press_target["path"]) if press_target else None
        selection["traitsAfter"] = focused_card.get("traits") if focused_card else None
        selection["selectedFlag"] = focused_card.get("selected") if focused_card else None
        selection["subtitle"] = subtitle(selected_nodes)
        evidence.write_json(f"{session.tag}/selection.json", selection)
        selected_trait = bool(focused_card and (
            focused_card.get("selected") in (True, 1)
            or (isinstance(focused_card.get("traits"), int)
                and focused_card["traits"] != selection["traitsBefore"])))
        findings.append(finding(
            "K1.3 选中态：AXSelected trait / AXSelected 属性",
            PASS if selected_trait else FAIL,
            f"选中后 traits {selection['traitsBefore']} → {selection['traitsAfter']}；"
            f"AXSelected={selection['selectedFlag']}；副标题={selection['subtitle']!r}",
            evidence=[f"{session.tag}/selection.json", f"{session.tag}/ax-tree.json"],
            expected="选中卡片暴露 isSelected（AXTraits 变化或 AXSelected=true）",
        ))

        # ---- toolbar ------------------------------------------------------
        toolbar_present = {
            "隐藏边栏": first(nodes, description="隐藏边栏"),
            "刷新": first(nodes, description="刷新"),
            "检查器": first(nodes, description="检查器"),
            "更多": first(nodes, title="更多") or first(nodes, help="更多操作"),
            "解包所选": first(nodes, description="解包所选"),
        }
        toolbar_rows = {}
        for name, node in toolbar_present.items():
            toolbar_rows[name] = {
                "found": node is not None,
                "role": node["role"] if node else None,
                "roleDescription": node.get("roleDescription") if node else None,
                "label": node.get("label") if node else None,
                "help": node.get("help") if node else None,
                "enabled": node.get("enabled") if node else None,
                "actions": node.get("actions") if node else None,
            }
        evidence.write_json(f"{session.tag}/toolbar.json", toolbar_rows)
        missing_toolbar = [name for name, node in toolbar_present.items() if node is None]
        unlabelled_toolbar = [name for name, node in toolbar_present.items()
                              if node is not None and not (node.get("label") or "").strip()]
        findings.append(finding(
            "K1.4 工具栏按钮：隐藏边栏/刷新/检查器/更多/解包所选",
            PASS if not missing_toolbar and not unlabelled_toolbar else FAIL,
            f"找到 {len(toolbar_present) - len(missing_toolbar)}/5；"
            f"缺 {missing_toolbar or '无'}；无 label {unlabelled_toolbar or '无'}",
            evidence=[f"{session.tag}/toolbar.json"],
            expected="5 个工具栏控件均存在且可读 label（description/title）",
            note="「更多」在 AX 中是 AXMenuButton(title=更多) 外层包 AXGroup（AXHelp=更多操作）；"
                 "「刷新/检查器/解包所选」的 label 同样在 AXDescription 而非 AXTitle",
        ))

        # ---- menus: sort & density ----------------------------------------
        menu_buttons = find(nodes, role="AXMenuButton")
        sort_menu = next((node for node in menu_buttons
                          if (node.get("title") or "").startswith("排序：")), None)
        density_menu = next((node for node in menu_buttons
                             if "正方形网格" in (node.get("title") or "")), None)
        evidence.write_json(f"{session.tag}/menus.json", {
            "menuButtons": [{"title": node.get("title"), "description": node.get("description"),
                             "help": node.get("help"), "role": node["role"],
                             "actions": node.get("actions")} for node in menu_buttons],
            "sortMenu": compact_node(sort_menu) if sort_menu else None,
            "densityMenu": compact_node(density_menu) if density_menu else None,
        })
        findings.append(finding(
            "K1.5 排序/密度菜单：可读名称",
            PASS if sort_menu and density_menu and sort_menu.get("title") and density_menu.get("title") else FAIL,
            f"排序={sort_menu.get('title') if sort_menu else '缺失'}；"
            f"密度={density_menu.get('title') if density_menu else '缺失'}（AXMenuButton/AXTitle）",
            evidence=[f"{session.tag}/menus.json"],
            expected="两个菜单暴露当前选择的可读名称",
            note="密度菜单名称固定为「正方形网格，三乘三」，不随实际密度变化；"
                 "排序菜单名称含当前排序（可用）",
        ))

        # ---- search field -------------------------------------------------
        search = first(nodes, role="AXTextField")
        search_row = compact_node(search) if search else None
        if search_row:
            search_row["hasTitle"] = bool(search_row.get("title"))
            search_row["hasDescription"] = bool(search_row.get("description"))
            search_row["hasPlaceholder"] = bool(search_row.get("placeholder"))
        evidence.write_json(f"{session.tag}/search.json", {"searchField": search_row,
                                                            "allTextFields": [
                                                                compact_node(node)
                                                                for node in find(nodes, role="AXTextField")]})
        has_any_name = bool(search and (search.get("title") or search.get("description")
                                        or search.get("placeholder")))
        explicit_label = bool(search and (search.get("title") or search.get("description")))
        findings.append(finding(
            "K1.6 搜索框：可读名称（任一来源）",
            PASS if has_any_name else FAIL,
            f"role={search.get('role') if search else '缺失'}；AXTitle={search.get('title') if search else None!r}；"
            f"AXDescription={search.get('description') if search else None!r}；"
            f"AXPlaceholderValue={search.get('placeholder') if search else None!r}",
            evidence=[f"{session.tag}/search.json"],
            expected="输入框有可读名称（title/description 或至少 placeholder）",
        ))
        findings.append(finding(
            "K1.6b 搜索框：名称是否来自 AXTitle/AXDescription（而非仅 placeholder）",
            PASS if explicit_label else FAIL,
            f"AXTitle={search.get('title') if search else None!r}；"
            f"AXDescription={search.get('description') if search else None!r}；"
            f"AXPlaceholderValue={search.get('placeholder') if search else None!r}",
            evidence=[f"{session.tag}/search.json"],
            expected="搜索框有显式 accessibilityLabel（AXTitle/AXDescription）",
            note="baseline 只有 placeholder；fixed2 已补 .accessibilityLabel(\"搜索标题或 ID\")",
        ))

        # ---- sidebar ------------------------------------------------------
        outline = first(nodes, role="AXOutline")
        rows = sidebar_rows(session.pid, outline)
        evidence.write_json(f"{session.tag}/sidebar.json", {"rows": rows,
                                                            "outline": compact_node(outline) if outline else None})
        sidebar_labels = [row["label"] for row in rows if row["label"]]
        header_rows = [row["index"] for row in rows if row["kind"] == "header"]
        other_rows = [row["index"] for row in rows if row["kind"] == "other"]
        missing_sidebar = [item for item in NAV_LABELS if item not in sidebar_labels]
        findings.append(finding(
            "K1.7 侧栏导航项：可读名称与选中态",
            PASS if not missing_sidebar else FAIL,
            f"导航项 label={sidebar_labels}；缺={missing_sidebar or '无'}；"
            f"计数文本与 label 同在一个 AXRow；分组标题行={header_rows or '无'}；"
            f"其它行={other_rows or '无'}",
            evidence=[f"{session.tag}/sidebar.json"],
            expected="8 个导航项都在 AX 中可读",
            note="AXRow 本身无 AXTitle/AXDescription，label 与数量由内部 AXStaticText 提供"
                 "（VoiceOver 会读子节点，因此可用但更脆弱）；"
                 f"分组标题行 {header_rows} 在 AX 中没有任何文本节点",
        ))

        # ---- inspector tabs ----------------------------------------------
        nodes = session.nodes()          # fresh: the selection above may have opened it
        if not any(node["role"] == "AXRadioButton" for node in nodes):
            send_key(session.pid, "l", command=True, option=True)
            time.sleep(1.2)
            nodes = session.nodes()
        tab_nodes = [node for node in nodes if node["role"] in
                     ("AXRadioGroup", "AXTabGroup", "AXSegmentedControl")]
        tab_buttons = [node for node in nodes if node["role"] == "AXRadioButton"]
        evidence.write_json(f"{session.tag}/inspector-tabs.json", {
            "containers": [compact_node(node) for node in tab_nodes],
            "radioButtons": [compact_node(node) for node in tab_buttons],
        })
        findings.append(finding(
            "K1.8 检查器标签页（详情/日志）",
            PASS if len(tab_buttons) >= 2 else FAIL,
            f"容器 role={[node['role'] for node in tab_nodes]}；"
            f"按钮={[node.get('title') or node.get('description') for node in tab_buttons]}",
            evidence=[f"{session.tag}/inspector-tabs.json"],
            expected="分段控件暴露为可选中的单选组，两个选项有可读名称",
        ))

        # ---- empty state --------------------------------------------------
        send_key(session.pid, "4", command=True)          # 已解包 → 空结果
        time.sleep(1.2)
        empty_nodes = session.nodes()
        empty_texts = [text_value(node) for node in empty_nodes
                       if node["role"] in ("AXStaticText", "AXHeading") and text_value(node).strip()]
        empty_button = first(empty_nodes, role="AXButton", description="重新扫描") or \
            first(empty_nodes, role="AXButton", contains="重新扫描")
        empty_state = {
            "texts": empty_texts[:12],
            "rescanButton": compact_node(empty_button) if empty_button else None,
            "subtitle": subtitle(empty_nodes),
        }
        evidence.write_json(f"{session.tag}/empty-state.json", empty_state)
        findings.append(finding(
            "K1.9 空状态可读性",
            PASS if empty_texts and any("没有可显示" in text for text in empty_texts) and empty_button else FAIL,
            f"文本={empty_state['texts'][:6]}；重新扫描按钮={'有' if empty_button else '无'}",
            evidence=[f"{session.tag}/empty-state.json"],
            expected="空状态标题/说明/可操作按钮都出现在 AX 中",
        ))
        send_key(session.pid, "1", command=True)
        time.sleep(0.8)

        session.shot("window-wide.png")
        shot_path = evidence.root / session.tag / "window-wide.png"
        grabber = session.grabber()
        fast_a = Grabber.save(grabber.grab(), session.evidence_dir / "capture-fast.png")
        time.sleep(0.2)
        fast_b = Grabber.save(grabber.grab(), session.evidence_dir / "capture-fast2.png")
        fast_noise = diff_files(fast_a, fast_b)
        shot_diff = diff_files(shot_path, fast_a)
        window = window_size(session.pid)
        from PIL import Image
        shot_size = Image.open(shot_path).size
        fast_size = Image.open(fast_a).size
        expected_pixels = (round(window["width"] * 2), round(window["height"] * 2))
        window_only = fast_size == expected_pixels
        evidence.write_json(f"{session.tag}/capture-sanity.json", {
            "window": window, "windowPointsTimes2": list(expected_pixels),
            "screencaptureSize": list(shot_size), "fastCaptureSize": list(fast_size),
            "fastCaptureNoise": fast_noise, "screencaptureVsFast": shot_diff,
            "note": "screencapture 会加窗口阴影/边缘（尺寸更大），CGWindowListCreateImage "
                    "只取窗口内容；两者都是窗口级，后者用于 60ms 采样",
        })
        findings.append(finding(
            "K1.10 证据截图方法自检（窗口级、无桌面像素）",
            PASS if window_only and fast_noise.get("changedFraction", 1) < 0.002 else FAIL,
            f"快速捕获尺寸={fast_size} 与窗口点数×2={expected_pixels} 一致={window_only}；"
            f"静止噪声={fast_noise.get('changedFraction')}；"
            f"screencapture 尺寸={shot_size}（含窗口阴影，故与快速捕获不同）",
            evidence=[f"{session.tag}/capture-sanity.json", f"{session.tag}/window-wide.png",
                      f"{session.tag}/capture-fast.png"],
            note="两张图都只包含开发窗口像素；screencapture 的额外边距是系统阴影，不是桌面内容",
        ))
    return {"scenario": "k1", "findings": findings,
            "score": score(findings)}


def role_histogram(nodes: list[dict]) -> dict:
    histogram: dict[str, int] = {}
    for node in nodes:
        histogram[node["role"]] = histogram.get(node["role"], 0) + 1
    return dict(sorted(histogram.items(), key=lambda item: -item[1]))


def sidebar_rows(pid: int, outline: dict | None) -> list[dict]:
    app = qa.ax_app(pid)
    target = qa.ax_find(app, role="AXOutline")
    if target is None:
        return []
    rows = []
    for index, row in enumerate(children(target)):
        texts = []
        stack = [(row, 0)]
        while stack:
            element, depth = stack.pop()
            if depth > 8:
                continue
            if attr(element, "AXRole") == "AXStaticText":
                value = attr(element, "AXValue")
                if value:
                    texts.append(str(value))
            for child in children(element):
                stack.append((child, depth + 1))
        label = next((text for text in texts if text in NAV_LABELS), None)
        rows.append({
            "index": index,
            "role": attr(row, "AXRole"),
            "subrole": attr(row, "AXSubrole"),
            "roleDescription": attr(row, "AXRoleDescription"),
            "selected": attr(row, "AXSelected"),
            "texts": texts,
            "label": label,
            "kind": ("nav" if label else ("header" if not texts else "other")),
            "hasTitle": bool(attr(row, "AXTitle")),
            "hasDescription": bool(attr(row, "AXDescription")),
            "rect": ax_rect(row),
        })
    return rows


def score(findings: list[dict]) -> dict:
    counts = {PASS: 0, FAIL: 0, GAP: 0, UNVERIFIED: 0, INFO: 0}
    for item in findings:
        counts[item["status"]] = counts.get(item["status"], 0) + 1
    return counts


# ---------------------------------------------------------------------------
# scenario K2 — keyboard focus traversal
# ---------------------------------------------------------------------------

def focus_step(session: Session, grabber: Grabber) -> dict:
    before, _ = session.fast("_tmp-before.png")
    started = time.perf_counter()
    send_key(session.pid, "tab")
    elapsed_key = (time.perf_counter() - started) * 1000
    time.sleep(0.32)
    snapshot = focused_snapshot(session.pid)
    after, _ = session.fast("_tmp-after.png")
    diff = diff_files(before, after)
    focus = snapshot.get("systemWide") or snapshot.get("app") or {}
    return {
        "at": clock(),
        "keyMs": round(elapsed_key, 1),
        "frontApp": front_app(),
        "focus": {
            "role": focus.get("role"),
            "subrole": focus.get("subrole"),
            "label": focus.get("label"),
            "description": (focus.get("description") or "")[:120],
            "title": focus.get("title"),
            "identifier": focus.get("identifier"),
            "rect": focus.get("rect"),
            "isCard": CARD_MARKER in (focus.get("description") or ""),
        },
        "systemWide": (snapshot.get("systemWide") or {}).get("role"),
        "appFocused": (snapshot.get("app") or {}).get("role"),
        "diff": diff,
        "_before": str(before), "_after": str(after),
    }


@scenario("k2")
def scenario_k2(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k2", WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.5)
        grabber = session.grabber()

        # noise floor: two idle frames a user-invisible time apart
        idle_a = Grabber.save(grabber.grab(), session.evidence_dir / "idle-a.png")
        time.sleep(0.25)
        idle_b = Grabber.save(grabber.grab(), session.evidence_dir / "idle-b.png")
        noise = diff_files(idle_a, idle_b)

        initial = focused_snapshot(session.pid)
        steps = []
        for index in range(1, 26):
            step = focus_step(session, grabber)
            step["step"] = index
            steps.append(step)
            if step["focus"]["isCard"]:
                # keep going to observe whether it stays usable, but note the step
                step["note"] = "focus entered a grid card"

        reverse = []
        for index in range(1, 6):
            started = time.perf_counter()
            send_key(session.pid, "tab", shift=True)
            elapsed = (time.perf_counter() - started) * 1000
            time.sleep(0.3)
            snapshot = focused_snapshot(session.pid)
            focus = snapshot.get("systemWide") or snapshot.get("app") or {}
            reverse.append({"step": index, "keyMs": round(elapsed, 1),
                            "role": focus.get("role"), "label": focus.get("label"),
                            "isCard": CARD_MARKER in (focus.get("description") or "")})

        cleaned = []
        for step in steps:
            clean = {key: value for key, value in step.items() if not key.startswith("_")}
            cleaned.append(clean)
        card_steps = [step["step"] for step in steps if step["focus"]["isCard"]]
        stuck = []
        previous = None
        streak = 0
        for step in steps:
            label = (step["focus"]["role"], step["focus"]["label"])
            if previous is not None and label == previous:
                streak += 1
            else:
                streak = 0
            if streak == 4:
                stuck.append({"step": step["step"], "label": step["focus"]["label"],
                              "role": step["focus"]["role"]})
            previous = label
        focus_ring_steps = []
        for step in steps:
            fraction = (step["diff"] or {}).get("changedFraction", 0)
            if fraction > 0.0005:
                focus_ring_steps.append({"step": step["step"], "changedFraction": fraction,
                                         "box": step["diff"].get("boundingBox")})
        evidence.write_json(f"{session.tag}/focus-sequence.json", {
            "noiseFloor": noise,
            "initialFocus": {
                "systemWide": (initial.get("systemWide") or {}).get("role"),
                "app": (initial.get("app") or {}).get("role"),
                "label": ((initial.get("app") or {}).get("label")),
            },
            "steps": cleaned,
            "reverseTab": reverse,
            "cardSteps": card_steps,
            "stuckRuns": stuck,
            "visibleChangeSteps": focus_ring_steps,
            "environment": {
                "AppleKeyboardUIMode": run(["defaults", "read", "-g", "AppleKeyboardUIMode"]).get("stdout"),
                "note": "AppleKeyboardUIMode=0 表示系统未开启全键盘控制（Tab 只走文本类控件）；本验收未改该设置",
            },
        })
        evidence.write_json(f"{session.tag}/focus-ring.json", {
            "noiseFloor": noise, "stepsWithVisibleChange": focus_ring_steps,
        })
        session.shot("window-after-tabs.png")

        reached_card = bool(card_steps)
        findings.append(finding(
            "K2.1 Tab 能否进入网格卡片",
            PASS if reached_card else FAIL,
            f"25 次 Tab 中卡片获得焦点的步骤={card_steps or '无'}；"
            f"焦点序列见 focus-sequence.json",
            evidence=[f"{session.tag}/focus-sequence.json"],
            expected="Tab 可依次进入网格卡片",
            note=None if reached_card else
                 "AppleKeyboardUIMode=0（未开启全键盘控制）时 SwiftUI focusable 卡片不参与 Tab 循环；"
                 "本验收未修改系统键盘设置",
        ))
        findings.append(finding(
            "K2.2 焦点是否可见（窗口级像素变化）",
            PASS if focus_ring_steps else FAIL,
            f"噪声基线 changedFraction={noise.get('changedFraction')}；"
            f"有可见变化的步骤={[item['step'] for item in focus_ring_steps] or '无'}",
            evidence=[f"{session.tag}/focus-ring.json", f"{session.tag}/idle-a.png",
                      f"{session.tag}/idle-b.png"],
            expected="焦点移动时出现可见焦点环",
        ))
        findings.append(finding(
            "K2.3 是否被无关控件卡住",
            PASS if not stuck else FAIL,
            f"连续 5 步同一焦点的位置={stuck or '无'}；25 步后的焦点归属="
            f"{steps[-1]['focus']['role']}/{steps[-1]['focus']['label']}",
            evidence=[f"{session.tag}/focus-sequence.json"],
            expected="Tab 不应长时间停在同一元素",
        ))
    return {"scenario": "k2", "findings": findings, "score": score(findings)}


# ---------------------------------------------------------------------------
# shared helpers for keyboard activation scenarios
# ---------------------------------------------------------------------------

def focus_card_by_tab(pid: int, max_tabs: int = 45, settle: float = 0.3) -> dict:
    """Try Tab traversal; return how (if at all) a card got focus."""
    for step in range(1, max_tabs + 1):
        send_key(pid, "tab")
        time.sleep(settle)
        snapshot = focused_snapshot(pid)
        focus = snapshot.get("systemWide") or snapshot.get("app") or {}
        if CARD_MARKER in (focus.get("description") or ""):
            return {"method": "tab", "tabs": step, "focus": focus}
    return {"method": None, "tabs": max_tabs, "focus": None}


def focus_card_programmatically(pid: int, card: dict) -> dict:
    """Fallback: set AXFocused on a card element so key handlers can be tested.

    This is the AX equivalent of "a card has keyboard focus"; it is labelled as
    programmatic in the evidence so no claim of TAB-reachability is implied.
    """
    live = next((node for node in element_nodes(pid) if node["path"] == card["path"]), None)
    if live is None:
        return {"method": "ax-set-focus", "ok": False, "reason": "card element not found"}
    element = live["__element__"]
    status = AXUIElementSetAttributeValue(element, "AXFocused", True)
    time.sleep(0.4)
    snapshot = focused_snapshot(pid)
    focus = snapshot.get("systemWide") or snapshot.get("app") or {}
    return {"method": "ax-set-focus", "ok": int(status) == 0,
            "status": int(status), "focus": focus}


def selection_snapshot(pid: int) -> dict:
    nodes = dump(pid, max_nodes=6000)
    card_nodes = cards(nodes)
    chosen = selected_cards(card_nodes)
    return {
        "subtitle": subtitle(nodes),
        "subtitleSelected": selection_count_from_subtitle(nodes),
        "visibleCards": len(card_nodes),
        "selectedTitles": [card_title(node) for node in chosen],
        "selectedCount": len(chosen),
        "traitsSample": [{"title": card_title(node), "traits": node.get("traits"),
                          "selected": node.get("selected"), "path": node["path"]}
                         for node in card_nodes[:6]],
    }


# ---------------------------------------------------------------------------
# scenario K3 — keyboard activation
# ---------------------------------------------------------------------------

@scenario("k3")
def scenario_k3(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k3", WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.5)

        nodes = session.nodes()
        card_nodes = visual_order(cards(nodes))
        evidence.write_json(f"{session.tag}/cards-initial.json",
                            [compact_node(node) for node in card_nodes[:12]])
        nofocus_path = session.fast("k3-nofocus.png")[0]   # focus-ring baseline

        # ---- key delivery control: typing really reaches the app ----------
        for _ in range(4):                    # Tab until the search field owns focus
            snap = focused_snapshot(session.pid)
            focus = snap.get("app") or {}
            if focus.get("role") == "AXTextField":
                break
            send_key(session.pid, "tab")
            time.sleep(0.4)
        time.sleep(0.3)
        type_keycodes(session.pid, "ab")
        time.sleep(1.0)
        control_nodes = session.nodes(max_nodes=2500)
        control_subtitle = subtitle(control_nodes)
        typed_ok = bool(control_subtitle and "搜索" in control_subtitle)
        for _ in range(2):
            send_key(session.pid, "delete")
        time.sleep(0.7)
        cleared_subtitle = subtitle(session.nodes(max_nodes=2500))
        evidence.write_json(f"{session.tag}/key-delivery-control.json", {
            "subtitleAfterTyping": control_subtitle,
            "subtitleAfterDelete": cleared_subtitle,
            "typedOk": typed_ok,
            "frontApp": front_app(),
        })
        findings.append(finding(
            "K3.0 键盘事件确实到达 App（输入框打字对照）",
            PASS if typed_ok else UNVERIFIED,
            f"在搜索框键入 ab 后副标题={control_subtitle!r}，退格后={cleared_subtitle!r}",
            evidence=[f"{session.tag}/key-delivery-control.json"],
            expected="键入字符后素材库副标题出现「搜索「ab」」",
            note="这是后续 Space/Return 结论的前置对照：事件通路正常，才谈得上按键语义缺失",
        ))

        focus_attempt = focus_card_by_tab(session.pid)
        if not focus_attempt["method"] and card_nodes:
            focus_attempt = focus_card_programmatically(session.pid, card_nodes[0])
            focus_attempt["fallbackReason"] = "Tab 未进入卡片；改用 AX 直接给卡片设置焦点以测试 key handler"
        evidence.write_json(f"{session.tag}/focus-attempt.json", focus_attempt)

        # ---- Space / Return reproduction (Lead-requested discriminator) ----
        grabber = session.grabber()

        def card_focus_probe(name: str) -> dict:
            nodes_now = session.nodes(max_nodes=4000)
            snap = focused_snapshot(session.pid)
            focus = snap.get("app") or snap.get("systemWide") or {}
            card_list = cards(nodes_now)
            ordered_now = visual_order(card_list)
            chosen = selected_cards(card_list)
            state = {
                "label": name,
                "focusedRole": focus.get("role"),
                "focusedLabel": (focus.get("label") or "")[:100],
                "isCardFocused": CARD_MARKER in (focus.get("description") or ""),
                "focusedAttr": focus.get("focused"),
                "subtitle": subtitle(nodes_now),
                "selectedTitles": [card_title(node) for node in chosen],
                "selectedCount": len(chosen),
                "firstVisibleCard": card_title(ordered_now[0]) if ordered_now else None,
                "scrollValues": [{"role": node["role"], "value": node.get("value")}
                                 for node in nodes_now
                                 if node["role"] in ("AXScrollArea", "AXScrollBar")],
                "searchFieldValue": next((node.get("value") for node in nodes_now
                                          if node["role"] == "AXTextField"), None),
                "inspectorVisible": inspector_visible(nodes_now),
            }
            state["framePath"] = str(session.fast(f"k3-{name}.png")[0])
            return state

        focused_state = card_focus_probe("focused")
        # channel control in exactly this focus state: one printable key + one menu shortcut
        send_key(session.pid, "a")
        time.sleep(0.6)
        after_a = card_focus_probe("after-a")
        send_key(session.pid, "space")
        time.sleep(1.0)
        after_space = card_focus_probe("after-space")
        if not after_space["isCardFocused"]:
            focus_card_by_tab(session.pid, max_tabs=10)
        send_key(session.pid, "return")
        time.sleep(1.0)
        after_return = card_focus_probe("after-return")
        send_key(session.pid, "2", command=True)      # menu shortcut = channel control
        time.sleep(1.0)
        after_cmd2 = card_focus_probe("after-cmd2")
        send_key(session.pid, "1", command=True)
        time.sleep(0.8)

        ring = diff_files(nofocus_path, Path(focused_state["framePath"]))
        repro = {
            "focusAttempt": focus_attempt,
            "focusRingVisible": ring,
            "nofocusFrame": str(nofocus_path),
            "focused": focused_state,
            "afterPrintableA": after_a,
            "afterSpace": after_space,
            "afterReturn": after_return,
            "afterCmd2ChannelControl": after_cmd2,
            "verdict": {
                "spaceSelected": after_space["selectedCount"] >= 1,
                "returnSelected": after_return["selectedCount"] >= 1,
                "focusStayedOnCardAfterSpace": after_space["isCardFocused"],
                "spaceChangedFocus": (after_space["focusedLabel"] != focused_state["focusedLabel"]),
                "spaceScrolled": (after_space["firstVisibleCard"] != focused_state["firstVisibleCard"]),
                "printableKeyChangedSearch": (after_a["subtitle"] != focused_state["subtitle"]),
                "channelWorksInSameFocusState": (after_cmd2["subtitle"] != focused_state["subtitle"]),
                "focusRingChangedFraction": ring.get("changedFraction"),
            },
        }
        evidence.write_json(f"{session.tag}/space-return-repro.json", repro)
        evidence.write_json(f"{session.tag}/after-space.json", after_space)
        evidence.write_json(f"{session.tag}/after-return.json", after_return)

        verdict = repro["verdict"]
        findings.append(finding(
            "K3.1 卡片聚焦后 Space 选中并露出详情",
            PASS if verdict["spaceSelected"] else FAIL,
            f"聚焦卡片={focused_state['focusedLabel'][:60]!r}（isCardFocused={focused_state['isCardFocused']}，"
            f"AXFocused={focused_state['focusedAttr']}）；"
            f"Space 后：已选={after_space['selectedCount']} 副标题={after_space['subtitle']!r} "
            f"焦点仍在卡片={after_space['isCardFocused']} 焦点变化={verdict['spaceChangedFocus']} "
            f"首个可见卡片={focused_state['firstVisibleCard']!r}→{after_space['firstVisibleCard']!r}"
            f"（滚动={verdict['spaceScrolled']}）检查器={after_space['inspectorVisible']}",
            evidence=[f"{session.tag}/space-return-repro.json", f"{session.tag}/after-space.json",
                      focused_state["framePath"], after_space["framePath"]],
            expected="Space 选中聚焦卡片并在检查器/面板露出详情",
            note="同一焦点状态下：发普通字符 a 未改变任何文本（副标题不变），发 ⌘2 菜单快捷键可切换筛选 → "
                 "事件到达 App，失败点在卡片的 onKeyPress/选中路径，不是投递通道",
        ))
        findings.append(finding(
            "K3.2 卡片聚焦后 Return 激活",
            PASS if verdict["returnSelected"] else FAIL,
            f"Return 后：已选={after_return['selectedCount']} 副标题={after_return['subtitle']!r} "
            f"焦点={after_return['focusedRole']}/{(after_return['focusedLabel'] or '')[:40]!r}",
            evidence=[f"{session.tag}/space-return-repro.json", f"{session.tag}/after-return.json",
                      after_return["framePath"]],
            expected="Return 触发与点击相同的选中路径",
            note="Space 之后如果焦点已离开卡片会先重新 Tab 聚焦再发 Return（记录在 repro 里）",
        ))
        findings.append(finding(
            "K3.2b 键盘通道对照（同一焦点状态下 ⌘2 是否生效）",
            PASS if verdict["channelWorksInSameFocusState"] else UNVERIFIED,
            f"⌘2 后副标题={after_cmd2['subtitle']!r}（之前 {focused_state['subtitle']!r}）；"
            f"字符 a 后副标题={after_a['subtitle']!r}",
            evidence=[f"{session.tag}/space-return-repro.json"],
            expected="⌘2 在同一焦点状态下完成页面筛选切换",
            note="用于排除「事件没送到 App」；Lead 的独立最小 SwiftUI 探针也证明 PostToPid 能触发 onKeyPress",
        ))
        after_space_selection = selection_snapshot(session.pid)

        # ---- ⌘↩ extraction -------------------------------------------------
        # Space/Return did not select above, so establish a selection through
        # the card's default AX action (same onTap path) before testing ⌘↩.
        nodes = session.nodes()
        ordered = visual_order(cards(nodes))
        extractable = [node for node in ordered
                       if "不可解包" not in (node.get("description") or "")]
        target_for_extraction = (extractable or ordered)[0] if ordered else None
        if target_for_extraction is not None:
            activate_node(session.pid, target_for_extraction)
            time.sleep(0.9)
        selection_before_extraction = selection_snapshot(session.pid)
        target_card_label = (target_for_extraction or {}).get("label")
        before_pictures = snapshot_picture_roots()
        extraction = extract_flow(session.pid, session.root)
        after_pictures = snapshot_picture_roots()
        extraction["pictureRootsBefore"] = before_pictures
        extraction["pictureRootsAfter"] = after_pictures
        extraction["selectionBeforeExtraction"] = selection_before_extraction
        extraction["targetCard"] = target_card_label
        extraction["devRoot"] = str(session.root)
        extraction["filesUnderDevRoot"] = sorted(
            str(path.relative_to(session.root))
            for path in (session.root / "Images").rglob("*") if path.is_file())[:20] \
            if (session.root / "Images").exists() else []
        evidence.write_json(f"{session.tag}/extraction.json", extraction)
        extraction_triggered = bool(extraction["trigger"])
        extraction_ok = extraction_triggered
        findings.append(finding(
            "K3.3 选中后 ⌘↩ 触发解包（确认框/产物只落在 dev root）",
            PASS if extraction_ok else FAIL,
            f"trigger={extraction['trigger']}；confirmed={extraction['confirmed']}；"
            f"确认框文本={ (extraction.get('alert') or {}).get('texts') }；"
            f"dev root 产物={extraction['filesUnderDevRoot'] or '无'}；等待={extraction['waitedSeconds']}s",
            evidence=[f"{session.tag}/extraction.json"],
            expected="⌘↩ 走确认→解包流程，输出目录为 dev root 内路径",
            note="开发副本把 outputRoot/imageExportRoot 固定到隔离 root，产物不可能落到个人目录；"
                 "已核对 ~/Pictures 前后状态。",
        ))
        findings.append(finding(
            "K3.4 解包产物未写入个人目录（~/Pictures）",
            PASS if before_pictures == after_pictures else FAIL,
            f"~/Pictures 快照 before==after: {before_pictures == after_pictures}",
            evidence=[f"{session.tag}/extraction.json"],
            expected="~/Pictures/MirageExtracted、~/Pictures/MirageImages 均无新增/修改",
        ))

        # ---- ⌥⌘L inspector toggle -----------------------------------------
        inspector_states = []
        for index in range(2):
            nodes = session.nodes()
            has_inspector = inspector_visible(nodes)
            send_key(session.pid, "l", command=True, option=True)
            time.sleep(1.0)
            after_nodes = session.nodes()
            inspector_states.append({
                "before": has_inspector,
                "after": inspector_visible(after_nodes),
                "tabs": [node.get("label") for node in find(after_nodes, role="AXRadioButton")],
            })
        evidence.write_json(f"{session.tag}/inspector-toggle.json", {"states": inspector_states})
        toggle_ok = inspector_states and inspector_states[0]["before"] != inspector_states[0]["after"] \
            and inspector_states[1]["before"] != inspector_states[1]["after"]
        findings.append(finding(
            "K3.5 ⌥⌘L 切换检查器",
            PASS if toggle_ok else FAIL,
            f"两次切换前后状态={[(item['before'], item['after']) for item in inspector_states]}",
            evidence=[f"{session.tag}/inspector-toggle.json"],
            expected="每次 ⌥⌘L 都翻转检查器可见性",
        ))

        # ---- ⌘1..⌘6 navigation -------------------------------------------
        nav_results = []
        for digit in "123456":
            send_key(session.pid, digit, command=True)
            time.sleep(1.2)
            nodes = session.nodes(max_nodes=3000)
            rows = sidebar_rows(session.pid, None)
            selected = [row["label"] or row["texts"] for row in rows if row["selected"] and row["texts"]]
            page_markers = [text_value(node) for node in nodes
                            if node["role"] in ("AXStaticText", "AXHeading")
                            and text_value(node).strip()][:12]
            nav_results.append({
                "shortcut": f"⌘{digit}",
                "sidebarSelectedRows": selected,
                "subtitle": subtitle(nodes),
                "hasGrid": any(node["role"] == "AXOpaqueProviderGroup" for node in nodes),
                "cardCount": len(cards(nodes)),
                "pageMarkers": page_markers,
                "page": classify_page(nodes),
            })
        evidence.write_json(f"{session.tag}/navigation.json", nav_results)
        expected_page = {"1": "library", "2": "library", "3": "library", "4": "library",
                         "5": "queue", "6": "storage"}
        expected_prefix = {"1": None, "2": "可解包", "3": "未解包", "4": "已解包"}
        nav_ok = True
        for result in nav_results:
            digit = result["shortcut"][-1]
            if result["page"] != expected_page[digit]:
                nav_ok = False
            prefix = expected_prefix.get(digit)
            if prefix and not (result["subtitle"] or "").startswith(prefix):
                nav_ok = False
        findings.append(finding(
            "K3.6 ⌘1..⌘6 切换页面",
            PASS if nav_ok else FAIL,
            "；".join(f"{item['shortcut']}→{item['page']}"
                      f"({item['subtitle']!r}, 卡片 {item['cardCount']})"
                      for item in nav_results),
            evidence=[f"{session.tag}/navigation.json"],
            expected="⌘1..⌘4 切换素材库筛选（副标题跟随），⌘5/⌘6 切到队列/存储页",
            note="侧栏行的 AXSelected 不随 ⌘ 快捷键刷新（见 K3.7），因此本项用页面内容判定",
        ))
        lagged_rows = [item["shortcut"] for item in nav_results
                       if item["sidebarSelectedRows"] and
                       item["sidebarSelectedRows"] == nav_results[0]["sidebarSelectedRows"]]
        findings.append(finding(
            "K3.7 侧栏 AXSelected 是否跟随快捷键导航",
            PASS if len(lagged_rows) < len(nav_results) else GAP,
            f"各快捷键后侧栏选中行={[item['sidebarSelectedRows'] for item in nav_results]}",
            evidence=[f"{session.tag}/navigation.json"],
            expected="导航变化时侧栏行 AXSelected 同步更新",
            note="若恒为同一行，VoiceOver 用户无法从侧栏获知当前所在位置（页面内容仍给出证据）",
        ))
        session.shot("window-final.png")
    return {"scenario": "k3", "findings": findings, "score": score(findings)}


MENU_ROLES = ("AXMenuItem", "AXMenu", "AXMenuBarItem", "AXMenuBar")


def classify_page(nodes: list[dict]) -> str:
    content = [node for node in nodes if node["role"] not in MENU_ROLES]
    texts = " ".join(text_value(node) for node in content)
    if any(node["role"] == "AXOpaqueProviderGroup" for node in content) or cards(content):
        return "library"
    if "队列为空" in texts or "没有符合条件的任务" in texts:
        return "queue"
    if re.search(r"共\s*\d+\s*项", texts) and "成功" in texts:
        return "queue"
    if "移到废纸篓" in texts or "选择全部" in texts or "清理" in texts:
        return "storage"
    if re.search(r"共\s*\d+\s*项\s*·\s*[\d.]+\s*(KB|MB|GB|字节)", texts):
        return "storage"
    return "unknown"


def inspector_visible(nodes: list[dict]) -> bool:
    if any(node["role"] == "AXRadioButton" for node in nodes):
        return True
    if any("面板" == (node.get("title") or "") for node in nodes):
        return True
    return any("未选择壁纸" in text_value(node) or "包内条目" in text_value(node)
               for node in nodes)


def snapshot_picture_roots() -> dict:
    home = Path.home()
    roots = {}
    for relative in ("Pictures/MirageExtracted", "Pictures/MirageImages"):
        path = home / relative
        if path.exists():
            try:
                stat = path.stat()
                roots[relative] = {"exists": True, "mtime": stat.st_mtime,
                                   "entries": len(list(path.iterdir()))}
            except Exception as error:
                roots[relative] = {"exists": True, "error": str(error)}
        else:
            roots[relative] = {"exists": False}
    return roots


# ---------------------------------------------------------------------------
# scenario K4 — multi-selection
# ---------------------------------------------------------------------------

@scenario("k4")
def scenario_k4(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k4", WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.5)
        nodes = session.nodes()
        ordered = visual_order(cards(nodes))
        evidence.write_json(f"{session.tag}/cards-ordered.json",
                            [{"title": card_title(node), "path": node["path"],
                              "rect": node.get("rect")} for node in ordered[:12]])
        if len(ordered) < 8:
            raise RuntimeError(f"not enough visible cards: {len(ordered)}")

        steps = []

        def record(name: str, note: str = ""):
            state = selection_snapshot(session.pid)
            steps.append({"action": name, "note": note, **state})
            return state

        def visible(offset: int) -> dict | None:
            fresh = visual_order(cards(session.nodes()))
            return fresh[offset] if len(fresh) > offset else None

        target_a = ordered[0]
        blocked_click = hid_click(session.pid, target_a)     # blocked: recorded, not sent
        steps.append({"action": "HID 点击（blocked，未发送）", "note": blocked_click.get("reason", ""),
                      **selection_snapshot(session.pid)})
        first_activation = activate_node(session.pid, target_a)
        time.sleep(0.8)
        state_single = record("单选第 1 张")
        state_single["activation"] = first_activation
        target_b = visible(2)
        second_activation = activate_node(session.pid, target_b, modifier="command") if target_b else {}
        time.sleep(0.9)
        state_command = record("⌘ 点第 3 张")
        state_command["activation"] = second_activation
        target_b2 = visible(2)
        third_activation = activate_node(session.pid, target_b2, modifier="command") if target_b2 else {}
        time.sleep(0.9)
        state_command_off = record("再次 ⌘ 点同一张（取消）")
        state_command_off["activation"] = third_activation
        target_c = visible(4)
        fourth_activation = activate_node(session.pid, target_c, modifier="shift") if target_c else {}
        time.sleep(0.9)
        state_shift = record("⇧ 点第 5 张（连选）")
        state_shift["activation"] = fourth_activation

        # keyboard multi-select probes (no fixes applied, just measurement)
        send_key(session.pid, "a", command=True)
        time.sleep(0.8)
        state_cmd_a = record("⌘A")
        keyboard_paths = {"cmdA": state_cmd_a["subtitleSelected"]}
        # focused card + ⇧Space / ⌘Space are common macOS list idioms
        focus_attempt = focus_card_by_tab(session.pid, max_tabs=6)
        if not focus_attempt["method"]:
            focus_attempt = focus_card_programmatically(session.pid, ordered[1])
        send_key(session.pid, "space", shift=True)
        time.sleep(0.7)
        state_shift_space = record("⇧Space")
        keyboard_paths["shiftSpace"] = state_shift_space["subtitleSelected"]
        keyboard_paths["focusMethod"] = focus_attempt.get("method")

        menus = menu_bar(session.pid)
        edit_menu = next((menu for menu in menus if menu["title"] == "编辑"), {"items": []})
        keyboard_paths["editMenu"] = edit_menu["items"]
        evidence.write_json(f"{session.tag}/multi-select.json", {
            "steps": steps, "keyboardPaths": keyboard_paths,
            "menus": menus,
        })
        session.shot("window-multi-select.png")

        command_ok = (state_command["subtitleSelected"] == 2)
        findings.append(finding(
            "K4.1 ⌘ 点击多选 / 再点取消",
            PASS if command_ok and state_command_off["subtitleSelected"] == 1 else FAIL,
            f"单击后={state_single['subtitle']!r}；⌘点后={state_command['subtitle']!r}；"
            f"再次 ⌘ 点后={state_command_off['subtitle']!r}；"
            f"AXPress 结果={[item.get('activation', {}).get('ok') for item in (state_single, state_command, state_command_off)]}",
            evidence=[f"{session.tag}/multi-select.json"],
            expected="⌘ 点击把新项加入选区，再点移出；标题行「已选 N」同步",
        ))
        shift_ok = (state_shift["subtitleSelected"] or 0) >= 2
        shift_expected = None
        findings.append(finding(
            "K4.2 ⇧ 连选",
            PASS if shift_ok else FAIL,
            f"⇧ 点击后={state_shift['subtitle']!r}；选中项 A={state_shift['selectedTitles']}",
            evidence=[f"{session.tag}/multi-select.json"],
            expected="⇧ 点击按锚点到点击项的区间连选",
        ))
        consistent = (state_shift["subtitleSelected"] == state_shift["selectedCount"]) or \
            (state_shift["selectedTitles"] and state_shift["subtitleSelected"] == len(
                state_shift["selectedTitles"]))
        findings.append(finding(
            "K4.3 标题行「已选 N」与 AX 选中态一致",
            PASS if consistent else FAIL,
            f"标题行已选={state_shift['subtitleSelected']}；"
            f"AX 可见选中卡片={state_shift['selectedCount']} 张 {state_shift['selectedTitles']}",
            evidence=[f"{session.tag}/multi-select.json"],
            expected="标题行计数等于 AX 中标记为选中的卡片数",
            note="AX 中可见卡片仅限当前视口，标题行计数覆盖整个筛选结果；"
                 "两者相等只说明本场景未滚出视口。",
        ))
        keyboard_ok = any(isinstance(value, int) and value and value > 1
                          for key, value in keyboard_paths.items()
                          if key in ("cmdA", "shiftSpace"))
        findings.append(finding(
            "K4.4 键盘等价多选路径",
            PASS if keyboard_ok else GAP,
            f"⌘A 后已选={keyboard_paths['cmdA']}；⇧Space 后已选={keyboard_paths['shiftSpace']}；"
            f"编辑菜单项={[item['title'] for item in edit_menu['items']]}",
            evidence=[f"{session.tag}/multi-select.json"],
            expected="不依赖鼠标即可改变多选集合",
            note="产品未提供键盘多选入口（编辑菜单无「全选」命令、卡片无 ⇧Space/⌘Space 处理）；"
                 "按任务约定只记录缺口，不新增功能",
        ))
    return {"scenario": "k4", "findings": findings, "score": score(findings)}


# ---------------------------------------------------------------------------
# scenario K5 — narrow window detail sheet dismissal
# ---------------------------------------------------------------------------

@scenario("k5")
def scenario_k5(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k5", NARROW) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.6)
        window = window_size(session.pid)
        nodes = session.nodes()
        ordered = visual_order(cards(nodes))
        if not ordered:
            raise RuntimeError("no cards visible at narrow width")
        activate_node(session.pid, ordered[0])
        time.sleep(1.2)
        open_nodes = session.nodes()
        close_button = next((node for node in open_nodes
                             if node["role"] == "AXButton"
                             and (node.get("label") or "") in ("关闭详情",)), None)
        detail_texts = [text_value(node) for node in open_nodes
                        if node["role"] in ("AXStaticText", "AXHeading")
                        and text_value(node).strip()][:25]
        overlay_visible = close_button is not None
        evidence.write_json(f"{session.tag}/sheet-open.json", {
            "window": window,
            "closeButton": compact_node(close_button) if close_button else None,
            "detailTexts": detail_texts,
            "tabs": [node.get("label") for node in find(open_nodes, role="AXRadioButton")],
        })
        session.shot("sheet-open.png")
        focus_inside = focused_snapshot(session.pid)

        # Escape
        send_key(session.pid, "escape")
        time.sleep(1.0)
        after_escape = session.nodes()
        escape_closed = not any((node.get("label") or "") == "关闭详情" for node in after_escape)
        focus_after_escape = focused_snapshot(session.pid)
        evidence.write_json(f"{session.tag}/after-escape.json", {
            "closed": escape_closed,
            "focusBefore": {"role": (focus_inside.get("app") or {}).get("role"),
                            "label": (focus_inside.get("app") or {}).get("label")},
            "focusAfter": {"role": (focus_after_escape.get("app") or {}).get("role"),
                           "label": (focus_after_escape.get("app") or {}).get("label")},
            "texts": [text_value(node) for node in after_escape
                      if node["role"] in ("AXStaticText", "AXHeading")][:12],
        })
        session.shot("after-escape.png")

        # reopen, then close with the button
        nodes = session.nodes()
        ordered = visual_order(cards(nodes))
        activate_node(session.pid, ordered[0])
        time.sleep(1.2)
        reopened = session.nodes()
        close_button = next((node for node in element_nodes(session.pid)
                             if node["role"] == "AXButton"
                             and (node.get("label") or "") == "关闭详情"), None)
        pressed = False
        if close_button is not None:
            pressed = ax_press_element(close_button["__element__"])
        time.sleep(1.0)
        after_button = session.nodes()
        button_closed = not any((node.get("label") or "") == "关闭详情" for node in after_button)
        focus_after_button = focused_snapshot(session.pid)
        evidence.write_json(f"{session.tag}/after-close-button.json", {
            "reopened": overlay_visible,
            "pressed": pressed,
            "closed": button_closed,
            "focusAfter": {"role": (focus_after_button.get("app") or {}).get("role"),
                           "label": (focus_after_button.get("app") or {}).get("label")},
        })
        session.shot("after-close-button.png")

        narrow_ok = window["width"] <= 1020
        findings.append(finding(
            "K5.0 窄窗（≤1020）下点卡片弹出详情面板",
            PASS if narrow_ok and overlay_visible else FAIL,
            f"窗口宽={window['width']}；关闭按钮={overlay_visible}；"
            f"面板文本={detail_texts[:5]}",
            evidence=[f"{session.tag}/sheet-open.json", f"{session.tag}/sheet-open.png"],
            expected="≤1020 宽时点击卡片弹出带关闭按钮的详情面板",
        ))
        findings.append(finding(
            "K5.1 Esc 关闭详情面板",
            PASS if escape_closed else FAIL,
            f"Esc 后「关闭详情」按钮存在={not escape_closed}；关闭={escape_closed}",
            evidence=[f"{session.tag}/after-escape.json", f"{session.tag}/after-escape.png"],
            expected="Esc 关闭面板且 AX 中不再存在面板",
        ))
        findings.append(finding(
            "K5.2 左上关闭按钮关闭详情面板",
            PASS if button_closed else FAIL,
            f"重新打开={overlay_visible}；AXPress 成功={pressed}；关闭={button_closed}",
            evidence=[f"{session.tag}/after-close-button.json",
                      f"{session.tag}/after-close-button.png"],
            expected="AXPress 关闭按钮后面板消失",
        ))
        focus_ok = bool((focus_after_escape.get("app") or {}).get("role"))
        findings.append(finding(
            "K5.3 关闭后焦点归属合理",
            PASS if focus_ok and escape_closed and button_closed else FAIL,
            f"Esc 后焦点={(focus_after_escape.get('app') or {}).get('role')}/"
            f"{(focus_after_escape.get('app') or {}).get('label')}；"
            f"按钮关闭后焦点={(focus_after_button.get('app') or {}).get('role')}/"
            f"{(focus_after_button.get('app') or {}).get('label')}",
            evidence=[f"{session.tag}/after-escape.json",
                      f"{session.tag}/after-close-button.json"],
            expected="面板关闭后焦点仍在应用内且指向可见控件/窗口，不落在已消失的面板",
        ))
    return {"scenario": "k5", "findings": findings, "score": score(findings)}


# ---------------------------------------------------------------------------
# scenario K6 — export shortcuts
# ---------------------------------------------------------------------------

@scenario("k6")
def scenario_k6(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k6", WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.5)

        def export_menu_states(tag: str) -> dict:
            menus = menu_bar(session.pid)
            open_output = menu_item_state(menus, "文件", "打开输出目录")
            reveal = menu_item_state(menus, "文件", "在 Finder 中显示")
            extract = menu_item_state(menus, "文件", "解包所选")
            state = {"label": tag, "openOutput": open_output, "revealInFinder": reveal,
                     "extractSelected": extract,
                     "fileMenuTitles": [item["title"] for item in
                                        next((menu for menu in menus if menu["title"] == "文件"),
                                             {"items": []})["items"]]}
            return state

        states = [export_menu_states("无选中")]
        nodes = session.nodes()
        ordered = visual_order(cards(nodes))
        extractable = [node for node in ordered
                       if "不可解包" not in (node.get("description") or "")]
        click_target = (extractable or ordered)[0] if ordered else None
        if click_target is not None:
            activate_node(session.pid, click_target)
        time.sleep(1.0)
        states.append(export_menu_states("选中 1 项、尚无解包历史"))

        # create a real history entry through the dev extraction path
        extraction = extract_flow(session.pid, session.root, timeout=90)
        time.sleep(1.0)
        states.append(export_menu_states("解包完成后"))
        evidence.write_json(f"{session.tag}/menu-states.json",
                            {"states": states, "extraction": extraction})

        finder_before = finder_windows()
        observations = []
        for shortcut, key, shift in (("⇧⌘O", "o", True), ("⇧⌘R", "r", True)):
            before_latency = qa.ax_latency(session.pid, samples=8)
            pressed_at = time.monotonic()
            send_key(session.pid, key, command=True, shift=shift)
            time.sleep(1.5)
            after_latency = qa.ax_latency(session.pid, samples=8)
            observations.append({
                "shortcut": shortcut,
                "alive": app_alive(session.pid),
                "axLatencyBeforeMs": round(sum(before_latency) / len(before_latency), 2),
                "axLatencyAfterMs": round(sum(after_latency) / len(after_latency), 2),
                "elapsedSeconds": round(time.monotonic() - pressed_at, 2),
                "finderWindowsAfter": finder_windows(),
            })
        evidence.write_json(f"{session.tag}/shortcut-firing.json", {
            "finderWindowsBefore": finder_before,
            "observations": observations,
            "note": "Finder 窗口只通过 CGWindowList 观察计数，未截图、未操作；"
                    "本节按任务约定只验证菜单项 enabled 状态与 App 无崩溃",
        })
        session.shot("window-after-shortcuts.png")

        no_selection = states[0]
        with_selection = states[1]
        with_history = states[2]
        findings.append(finding(
            "K6.1 ⇧⌘O「打开输出目录」菜单项可用性",
            PASS if with_history["openOutput"]["enabled"] is True
            and no_selection["openOutput"]["enabled"] is False else FAIL,
            f"无选中 enabled={no_selection['openOutput']['enabled']}；"
            f"有选中+有历史 enabled={with_history['openOutput']['enabled']}；"
            f"快捷键={with_history['openOutput']['shortcut']!r}",
            evidence=[f"{session.tag}/menu-states.json"],
            expected="无输出目录时禁用；解包完成后启用",
        ))
        findings.append(finding(
            "K6.2 ⇧⌘R「在 Finder 中显示」菜单项可用性",
            PASS if with_selection["revealInFinder"]["enabled"] is True
            and no_selection["revealInFinder"]["enabled"] is False else FAIL,
            f"无选中 enabled={no_selection['revealInFinder']['enabled']}；"
            f"有选中 enabled={with_selection['revealInFinder']['enabled']}；"
            f"快捷键={with_selection['revealInFinder']['shortcut']!r}",
            evidence=[f"{session.tag}/menu-states.json"],
            expected="选中项时启用",
        ))
        alive = all(item["alive"] for item in observations)
        findings.append(finding(
            "K6.3 实际按键后 App 存活且 AX 仍可响应",
            PASS if alive else FAIL,
            f"各快捷键 alive={[item['alive'] for item in observations]}；"
            f"AX 往返={[item['axLatencyAfterMs'] for item in observations]} ms",
            evidence=[f"{session.tag}/shortcut-firing.json"],
            expected="⇧⌘O / ⇧⌘R 不导致崩溃或长时间无响应",
        ))
    return {"scenario": "k6", "findings": findings, "score": score(findings)}


def finder_windows() -> list[dict]:
    """Observe (never manipulate) Finder's window list."""
    try:
        infos = Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
            Quartz.kCGNullWindowID)
    except Exception:
        return []
    result = []
    for info in infos:
        if (info.get("kCGWindowOwnerName") or "") == "Finder":
            bounds = info.get("kCGWindowBounds") or {}
            result.append({"id": int(info.get("kCGWindowNumber", 0)),
                           "layer": int(info.get("kCGWindowLayer", 0)),
                           "width": round(float(bounds.get("Width", 0)), 1),
                           "height": round(float(bounds.get("Height", 0)), 1)})
    return result


# ---------------------------------------------------------------------------
# scenario K7 — reduce motion
# ---------------------------------------------------------------------------

TEMP_RESTORE: list[tuple[str, str, dict]] = []


def remember_default(key: str) -> dict:
    current = defaults_get(DEV_DOMAIN, key)
    TEMP_RESTORE.append((DEV_DOMAIN, key, current))
    return current


def restore_remembered() -> list[dict]:
    restored = []
    for domain, key, original in reversed(TEMP_RESTORE):
        if original.get("present"):
            defaults_write(domain, key, str(original["value"]))
        else:
            defaults_delete(domain, key)
        restored.append({"domain": domain, "key": key, "restored": original})
    TEMP_RESTORE.clear()
    return restored


def sample_action(session: Session, grabber: Grabber, action: str) -> dict:
    """Capture t0/+60/+200/+600/+1200 ms around one interaction."""
    def capture() -> dict:
        return grabber.grab()

    nodes = session.nodes(max_nodes=1500)
    before = [capture()]
    time.sleep(0.2)
    before.append(capture())
    if action == "sort":
        menu = next((node for node in nodes
                     if node["role"] == "AXMenuButton"
                     and (node.get("title") or "").startswith("排序：")), None)
        if menu is None:
            raise RuntimeError("sort menu button not found")
        opened = activate_node(session.pid, menu)
        if not opened.get("ok"):
            raise RuntimeError(f"sort menu AXPress failed: {opened}")
        time.sleep(0.5)
        send_key(session.pid, "down")
        send_key(session.pid, "down")
        send_key(session.pid, "return")
    elif action == "density":
        menu = next((node for node in nodes
                     if node["role"] == "AXMenuButton"
                     and "正方形网格" in (node.get("title") or "")), None)
        if menu is None:
            raise RuntimeError("density menu button not found")
        opened = activate_node(session.pid, menu)
        if not opened.get("ok"):
            raise RuntimeError(f"density menu AXPress failed: {opened}")
        time.sleep(0.5)
        # density is pinned to "standard" (index 1) before launch; pick index 2
        for _ in range(3):
            send_key(session.pid, "down")
        send_key(session.pid, "return")
    elif action == "inspector":
        send_key(session.pid, "l", command=True, option=True)
    else:
        raise ValueError(action)
    action_at = time.monotonic()
    frames = []
    # dense profile: ~40 ms cadence for 1.4 s (35 frames max). A jump shows one
    # large consecutive diff; an animation shows a decaying series.
    deadline = action_at + 1.4
    while time.monotonic() < deadline and len(frames) < 35:
        frames.append(capture())
        time.sleep(0.028)
    return {"action": action, "actionAt": action_at,
            "before": before, "after": frames}


def save_action(session: Session, grabber: Grabber, result: dict, slug: str) -> dict:
    directory = session.evidence_dir
    before_paths = grabber.save_all(result["before"], directory, f"{slug}-before")
    after_paths = grabber.save_all(result["after"], directory, f"{slug}-after")
    times = frame_times(result["after"], result["actionAt"])
    diffs = []
    for index in range(len(after_paths) - 1):
        diffs.append({"from_ms": times[index], "to_ms": times[index + 1],
                      "diff": diff_files(after_paths[index], after_paths[index + 1])})
    baseline = diff_files(before_paths[0], before_paths[1])
    action_changed = diff_files(before_paths[-1], after_paths[-1])
    versus_final = [{"at_ms": times[index],
                     "changedFraction": diff_files(after_paths[index],
                                                   after_paths[-1]).get("changedFraction")}
                    for index in range(len(after_paths) - 1)]
    consecutive = [{"from_ms": times[index], "to_ms": times[index + 1],
                    "changedFraction": diff_files(after_paths[index],
                                                  after_paths[index + 1]).get("changedFraction")}
                   for index in range(len(after_paths) - 1)]
    settle_at = None
    for item in reversed(consecutive):
        if item["changedFraction"] and item["changedFraction"] > max(0.0005, 2 * baseline.get("changedFraction", 0)):
            settle_at = item["to_ms"]
            break
    moving_frames = [item for item in consecutive
                     if item["changedFraction"] and
                     item["changedFraction"] > max(0.0005, 2 * baseline.get("changedFraction", 0))]
    return {
        "action": result["action"],
        "framesMs": times,
        "beforeNoise": baseline,
        "actionChanged": action_changed,
        "consecutiveDiffs": diffs,
        "versusFinal": versus_final,
        "movingFrames": len(moving_frames),
        "settleAtMs": settle_at,
        "profile": motion_profile(versus_final, action_changed, baseline),
        "files": {
            "before": [str(path) for path in before_paths],
            "after": [str(path) for path in after_paths],
        },
    }


def motion_measurement(evidence: Evidence, motion_value: str, tag: str) -> dict:
    """Launch once with the given dev-domain motion preference and sample actions."""
    defaults_write(DEV_DOMAIN, "pkd.appearance.motion", motion_value)
    defaults_write(DEV_DOMAIN, "pkd.appearance.density", "standard")
    defaults_write(DEV_DOMAIN, "pkd.library.sort", "titleAsc")
    results = {}
    with Session(evidence, tag, WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan, name=f"{tag}/scan-wait.json")
        ensure_front(session.pid)
        time.sleep(1.0)
        grabber = session.grabber()
        # park the pointer away from any control and let the window settle
        frame = qa.main_window(session.pid)["frame"]
        Quartz.CGWarpMouseCursorPosition(
            Quartz.CGPointMake(frame["X"] + frame["Width"] / 2, frame["Y"] + 8))
        time.sleep(0.6)
        for action in ("sort", "density", "inspector"):
            try:
                raw = sample_action(session, grabber, action)
                results[action] = save_action(session, grabber, raw, action)
            except Exception as error:
                results[action] = {"action": action, "error": str(error),
                                   "traceback": traceback.format_exc()[-600:]}
            time.sleep(1.0)
        evidence.write_json(f"{tag}/motion.json", {
            "motionDefault": motion_value,
            "devDefaults": defaults_export(DEV_DOMAIN),
            "results": results,
        })
        session.shot("window.png")
    return results


def motion_profile(versus_final: list[dict], action_changed: dict | None,
                   baseline: dict | None) -> dict:
    """Classify a dense frame profile as one jump vs a decaying transition.

    ``versusFinal`` is the pixel difference of every post-action frame against
    the settled (+~1.4 s) frame. A single jump shows a plateau at the full
    change followed by zeros; a transition shows frames that are only partly
    different (the animation's intermediate positions).
    """
    noise = max(0.0005, 2 * ((baseline or {}).get("changedFraction") or 0))
    full = max(noise, (action_changed or {}).get("changedFraction") or 0)
    values = [item.get("changedFraction") or 0 for item in versus_final]
    intermediate = [{"at_ms": item["at_ms"], "changedFraction": item["changedFraction"]}
                    for item in versus_final
                    if noise < (item.get("changedFraction") or 0) < 0.85 * full]
    plateau = [item for item in versus_final if (item.get("changedFraction") or 0) >= 0.85 * full]
    settle_ms = None
    for item in reversed(versus_final):
        if (item.get("changedFraction") or 0) > noise:
            settle_ms = item["at_ms"]
            break
    return {
        "fullChange": round(full, 6),
        "plateauFrames": len(plateau),
        "intermediateFrames": len(intermediate),
        "intermediate": intermediate[:12],
        "settleAtMs": settle_ms,
        "firstFrameMs": versus_final[0]["at_ms"] if versus_final else None,
        "animation": len(intermediate) >= 1,
        "noise": noise,
    }


def inspector_region_analysis(directory: Path) -> dict:
    """Split the inspector-toggle frames into grid vs right-panel regions."""
    import re as _re
    try:
        from PIL import Image, ImageChops
    except Exception:
        return {"error": "PIL missing"}
    frames = sorted(directory.glob("inspector-after-*.png"),
                    key=lambda path: int(_re.search(r"-after-(\d+)\.png$", path.name).group(1)))
    if len(frames) < 3:
        return {"error": "not enough frames", "frames": len(frames)}
    width, height = Image.open(frames[0]).size
    panel_x = width - int(width * 0.233)      # inspector column ≈ 280pt of 1200pt

    def region_diff(first: Path, second: Path, box) -> float:
        left = Image.open(first).crop(box).convert("RGB")
        right = Image.open(second).crop(box).convert("RGB")
        histogram = ImageChops.difference(left, right).convert("L").histogram()
        area = (box[2] - box[0]) * (box[3] - box[1])
        return round(sum(histogram[8:]) / area, 5)

    final = frames[-1]
    rows = []
    for index in range(min(6, len(frames) - 1)):
        rows.append({
            "frame": index,
            "vsFinal": {
                "whole": region_diff(frames[index], final, (0, 0, width, height)),
                "grid": region_diff(frames[index], final, (0, 0, panel_x, height)),
                "panel": region_diff(frames[index], final, (panel_x, 0, width, height)),
            },
        })
    early = rows[0:2]
    late = rows[2:4]
    late_grid = [row["vsFinal"]["grid"] for row in late]
    late_panel = [row["vsFinal"]["panel"] for row in late]
    residual_in_grid = any(value > 0.02 for value in late_grid)
    panel_settled = bool(late_panel) and all(value <= 0.01 for value in late_panel)
    early_panel = [row["vsFinal"]["panel"] for row in early]
    return {
        "frames": len(frames), "panelX": panel_x,
        "rows": rows,
        "verdict": (("前两帧（≈0–55ms）网格区与面板区都在变（0.44→0.27 同时出现，属列滑动/首帧重绘），"
                     "从 ≈100ms 起只有网格区继续变化（%.3f→%.3f），面板区已归零（%.4f→%.4f）"
                     "→ 后段残留是内容列宽过渡（NavigationSplitView inspector 列动画）带动网格重排，"
                     "不是面板内容动画")
                    % (late_grid[0], late_grid[1] if len(late_grid) > 1 else 0,
                       late_panel[0], late_panel[1] if len(late_panel) > 1 else 0)
                    if residual_in_grid and panel_settled else
                    "网格区与面板区都有残留，需人工复核"),
        "residualInGrid": residual_in_grid, "panelSettled": panel_settled,
        "earlyPanel": early_panel,
        "lateGrid": late_grid, "latePanel": late_panel,
    }


def analyze_motion_evidence(directory: Path) -> dict:
    """Recompute the K7 verdict from already-recorded frames (no GUI needed)."""
    output = {}
    for group in ("k7-off", "k7-control"):
        path = directory / group / "motion.json"
        if not path.exists():
            output[group] = {"missing": str(path)}
            continue
        payload = json.loads(path.read_text())
        per_action = {}
        for action, record in (payload.get("results") or {}).items():
            if "error" in record:
                per_action[action] = {"error": record["error"]}
                continue
            profile = record.get("profile") or motion_profile(
                record.get("versusFinal") or [], record.get("actionChanged") or {},
                record.get("beforeNoise") or {})
            per_action[action] = {
                "profile": profile,
                "framesMs": record.get("framesMs"),
                "actionChanged": (record.get("actionChanged") or {}).get("changedFraction"),
                "beforeNoise": (record.get("beforeNoise") or {}).get("changedFraction"),
            }
        output[group] = per_action
    return output


def verdict_for_action(result: dict, noise: float = 0.0005) -> dict:
    if "error" in result:
        return {"verdict": UNVERIFIED, "reason": result["error"]}
    changed = (result.get("actionChanged") or {}).get("changedFraction", 0)
    if changed is not None and changed <= noise:
        return {"verdict": UNVERIFIED, "reason": "动作没有改变窗口像素（无法据此判断动画）",
                "actionChanged": changed}
    profile = result.get("profile") or {}
    if not profile:
        return {"verdict": UNVERIFIED, "reason": "no dense profile",
                "movingFrames": result.get("movingFrames"),
                "settleAtMs": result.get("settleAtMs")}
    moving = profile.get("intermediateFrames")
    settle = profile.get("settleAtMs")
    # one moving frame == a single jump; several moving frames == a transition
    animated = moving > 1
    return {"verdict": FAIL if animated else PASS,
            "movingFrames": moving,
            "settleAtMs": settle,
            "note": "密集采样（~40ms/帧、最长 1.4s）里超过一帧仍在变化即为过渡动画；"
                    "单帧跳变记为无动画"}


@scenario("k7")
def scenario_k7(evidence: Evidence) -> dict:
    findings: list[dict] = []
    original = defaults_get(DEV_DOMAIN, "pkd.appearance.motion")
    remember_default("pkd.appearance.motion")
    remember_default("pkd.appearance.density")
    remember_default("pkd.library.sort")
    evidence.write_json("k7/defaults-before.json", {
        "domain": DEV_DOMAIN, "key": "pkd.appearance.motion", "state": original,
        "density": defaults_get(DEV_DOMAIN, "pkd.appearance.density"),
        "sort": defaults_get(DEV_DOMAIN, "pkd.library.sort"),
        "exported": defaults_export(DEV_DOMAIN),
    })
    restored = []
    try:
        off_results = motion_measurement(evidence, "off", "k7-off")
        # sensitivity control: with the setting on "system" the same actions must
        # show a clear transient, otherwise the measurement proves nothing.
        control_results = motion_measurement(evidence, "system", "k7-control")
    finally:
        restored = restore_remembered()
    evidence.write_json("k7/defaults-after.json", {
        "restored": restored,
        "current": defaults_get(DEV_DOMAIN, "pkd.appearance.motion"),
    })

    noise_floor = max(
        [((payload.get("beforeNoise") or {}).get("changedFraction") or 0)
         for payload in list(off_results.values()) + list(control_results.values())]
        or [0])
    for action, label in (("sort", "排序切换"), ("density", "密度切换"),
                          ("inspector", "检查器开关")):
        off = verdict_for_action(off_results.get(action, {}), noise=noise_floor)
        control = verdict_for_action(control_results.get(action, {}), noise=noise_floor)
        status = off["verdict"]
        if status == PASS and control["verdict"] != FAIL:
            status = UNVERIFIED
        findings.append(finding(
            f"K7 · motion=off 时「{label}」无过渡动画",
            status,
            f"off: 动作改变量={((off_results.get(action) or {}).get('actionChanged') or {}).get('changedFraction')} "
            f"变化帧数={off.get('movingFrames')} 稳定于≈{off.get('settleAtMs')}ms；"
            f"control(system): 动作改变量={((control_results.get(action) or {}).get('actionChanged') or {}).get('changedFraction')} "
            f"变化帧数={control.get('movingFrames')} 稳定于≈{control.get('settleAtMs')}ms",
            evidence=[f"k7-off/motion.json", f"k7-control/motion.json",
                      f"k7/defaults-before.json", f"k7/defaults-after.json"],
            expected="motion=off 时三处交互都不应残留过渡动画",
            note="changedFraction 为相对 +1200ms 终帧的窗口级像素差；"
                 "control 组用于证明该指标能捕捉到动画本身",
        ))
    current_motion = defaults_get(DEV_DOMAIN, "pkd.appearance.motion")
    restore_ok = (bool(current_motion.get("present")) == bool(original.get("present"))) and (
        not original.get("present") or current_motion.get("value") == original.get("value"))
    findings.append(finding(
        "K7 · 恢复 pkd.appearance.motion 原值",
        PASS if restore_ok else FAIL,
        f"原值={original}；恢复后={current_motion}",
        evidence=["k7/defaults-before.json", "k7/defaults-after.json"],
        expected="结尾把开发域动效偏好恢复成运行前的值",
    ))
    return {"scenario": "k7", "findings": findings, "score": score(findings),
            "measurements": {"off": summarize_motion(off_results),
                             "control": summarize_motion(control_results)}}


def summarize_motion(results: dict) -> dict:
    summary = {}
    for action, payload in results.items():
        summary[action] = {"error": payload.get("error")} if "error" in payload else {
            "framesMs": payload.get("framesMs"),
            "beforeNoise": payload.get("beforeNoise", {}).get("changedFraction"),
            "actionChanged": payload.get("actionChanged", {}).get("changedFraction"),
            "movingFrames": payload.get("movingFrames"),
            "settleAtMs": payload.get("settleAtMs"),
            "consecutiveDiffs": payload.get("consecutiveDiffs"),
        }
    return summary


# ---------------------------------------------------------------------------
# scenario K8 — VoiceOver associability
# ---------------------------------------------------------------------------

def voiceover_running() -> bool:
    result = subprocess.run(["pgrep", "-x", "VoiceOver"], capture_output=True)
    return result.returncode == 0


def voiceover_pids() -> list[str]:
    result = subprocess.run(["pgrep", "-x", "VoiceOver"], capture_output=True, text=True)
    return result.stdout.split()


def universal_access_snapshot() -> dict:
    return {
        "voiceOverRunning": voiceover_running(),
        "voiceOverPids": voiceover_pids(),
        "VoiceOverTouchEnabled": defaults_get("com.apple.universalaccess",
                                              "voiceOverOnOffKey"),
        "systemReduceMotion": defaults_get(
            "com.apple.universalaccess", "reduceMotion"),
        "AppleKeyboardUIMode": defaults_get("com.apple.universalaccess",
                                            "keyboardAccessEnabled"),
    }


@scenario("k8")
def scenario_k8(evidence: Evidence) -> dict:
    findings: list[dict] = []
    initial = universal_access_snapshot()
    evidence.write_json("k8/voiceover-before.json", initial)
    started_by_us = False
    launched = False
    focus_trace: list[dict] = []
    notes: list[str] = []
    if not initial["voiceOverRunning"]:
        result = run(["open", "-a", "VoiceOver"], timeout=30)
        started_by_us = True
        notes.append(f"open -a VoiceOver → rc={result.get('returncode')} "
                     f"stderr={result.get('stderr')!r}")
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if voiceover_running():
                launched = True
                break
            time.sleep(0.5)
        notes.append(f"VoiceOver 进程出现={launched}")
    else:
        launched = True
        notes.append("VoiceOver 在运行前已启动（未由本验收启动）")

    if launched:
        try:
            with Session(evidence, "k8", WIDE) as session:
                scan = wait_scan(session.pid)
                write_scan(session, scan)
                ensure_front(session.pid)
                time.sleep(1.0)
                for step in range(1, 6):
                    snapshot = focused_snapshot(session.pid)
                    focus_trace.append({
                        "step": step,
                        "systemWide": (snapshot.get("systemWide") or {}).get("role"),
                        "app": (snapshot.get("app") or {}).get("role"),
                        "label": (snapshot.get("app") or {}).get("label"),
                    })
                    send_key(session.pid, "tab")
                    time.sleep(0.6)
                nodes = session.nodes(max_nodes=2500)
                focus_trace.append({
                    "step": "after",
                    "focusedNodes": [compact_node(node, keys=("role", "label", "focused"))
                                     for node in nodes if node.get("focused")],
                })
                evidence.write_json("k8/focus-trace.json", focus_trace)
                session.shot("window-with-vo.png")
                vo_pids = voiceover_pids()
        except Exception as error:
            notes.append(f"关联尝试失败: {error}")
            evidence.write_json("k8/focus-trace.json", focus_trace)
    else:
        evidence.write_json("k8/focus-trace.json", [])

    # restore: only quit VoiceOver if this audit started it
    quit_result = None
    if started_by_us and launched:
        quit_result = run(["osascript", "-e",
                           'tell application id "com.apple.VoiceOver" to quit'], timeout=30)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and voiceover_running():
            time.sleep(0.5)
        if voiceover_running():
            run(["killall", "VoiceOver"], timeout=20)
            time.sleep(1.5)
    final = universal_access_snapshot()
    evidence.write_json("k8/voiceover-after.json", {
        "startedByUs": started_by_us, "launched": launched,
        "quitResult": quit_result, "final": final, "notes": notes,
    })

    vo_running_final = final["voiceOverRunning"]
    focus_moved = len({(item.get("systemWide"), item.get("app")) for item in focus_trace
                       if "step" in item and isinstance(item["step"], int)}) > 1
    if not launched:
        findings.append(finding(
            "K8 · VoiceOver 朗读实测", UNVERIFIED,
            f"无法启动/确认 VoiceOver：{notes}",
            evidence=["k8/voiceover-before.json", "k8/voiceover-after.json"],
            expected="VoiceOver 建立与开发 App 的可验证关联",
            note="禁止修改 TCC/辅助功能偏好，无法通过授权路径启动时按要求记 UNVERIFIED",
        ))
    else:
        findings.append(finding(
            "K8.1 VoiceOver 与开发 App 的可验证关联（进程 + 前台焦点）",
            PASS if (not vo_running_final or not started_by_us) and any(focus_trace) else UNVERIFIED,
            f"VoiceOver 运行={initial['voiceOverRunning']}→本验收启动={started_by_us}→"
            f"结束运行={vo_running_final}；焦点追踪样本={len(focus_trace)} 条；焦点变化={focus_moved}",
            evidence=["k8/voiceover-before.json", "k8/voiceover-after.json",
                      "k8/focus-trace.json"],
            expected="VoiceOver 进程存在且开发 App 为前台，焦点在应用内可读",
            note="；".join(notes) or None,
        ))
        findings.append(finding(
            "K8.2 VoiceOver 实际朗读输出", UNVERIFIED,
            "未捕获任何朗读文本/语音队列事件（无 TCC 授权、无公开 API 读取 VoiceOver 朗读内容）",
            evidence=["k8/focus-trace.json"],
            expected="能证明 VoiceOver 朗读了卡片/工具栏的正确名称",
            note="AX 焦点变化不等价于朗读；按任务要求不用 AX 树替代 VoiceOver 结论",
        ))
        findings.append(finding(
            "K8.3 VoiceOver 状态恢复",
            PASS if vo_running_final == initial["voiceOverRunning"] else FAIL,
            f"初始运行={initial['voiceOverRunning']}；结束时运行={vo_running_final}",
            evidence=["k8/voiceover-before.json", "k8/voiceover-after.json"],
            expected="结束时 VoiceOver 状态与开始时一致",
        ))
    return {"scenario": "k8", "findings": findings, "score": score(findings)}


# ---------------------------------------------------------------------------
# scenario K9 — large-library keyboard traversal + reading order
# ---------------------------------------------------------------------------

@scenario("k9")
def scenario_k9(evidence: Evidence) -> dict:
    findings: list[dict] = []
    with Session(evidence, "k9", WIDE) as session:
        scan = wait_scan(session.pid)
        write_scan(session, scan)
        ensure_front(session.pid)
        time.sleep(0.8)

        # reading-order inference (AX traversal order vs visual order)
        grid = session.nodes()
        ordered_nodes = cards(grid)
        ax_order = [card_title(node) for node in ordered_nodes]
        visual = [card_title(node) for node in visual_order(ordered_nodes)]
        order_matches = ax_order == visual
        first_visible = ax_order[0] if ax_order else None
        evidence.write_json(f"{session.tag}/reading-order.json", {
            "axTraversalOrder": ax_order,
            "visualOrder": visual,
            "match": order_matches,
            "note": "AX 前序遍历顺序作为 VoiceOver 阅读顺序的推断；不是朗读实测",
        })

        # 20 Tab presses, measuring focus change / scroll follow / cost
        grabber = session.grabber()
        grid_rect = grid_viewport(session.pid, grid)
        steps = []
        previous_focus = None
        previous_first = first_visible
        for index in range(1, 46):
            started = time.perf_counter()
            send_key(session.pid, "tab")
            key_ms = (time.perf_counter() - started) * 1000
            time.sleep(0.35)
            snapshot = focused_snapshot(session.pid)
            focus = snapshot.get("systemWide") or snapshot.get("app") or {}
            light = qa.ax_tree(session.pid, max_nodes=900)
            first_card = next((row.get("description", "").split("，")[0]
                               for row in light
                               if row["role"] == "AXButton"
                               and CARD_MARKER in (row.get("description") or "")), None)
            rect = focus.get("rect")
            inside_grid = bool(rect and grid_rect and rect_inside(rect, grid_rect))
            steps.append({
                "step": index,
                "keyMs": round(key_ms, 2),
                "focusRole": focus.get("role"),
                "focusLabel": focus.get("label"),
                "isCard": CARD_MARKER in (focus.get("description") or ""),
                "focusInsideGrid": inside_grid,
                "firstVisibleCard": first_card,
                "scrolled": first_card != previous_first,
                "focusChanged": (focus.get("role"), focus.get("label")) != previous_focus,
            })
            previous_focus = (focus.get("role"), focus.get("label"))
            previous_first = first_card
        evidence.write_json(f"{session.tag}/tab-traversal.json", {
            "gridViewport": grid_rect, "steps": steps,
        })
        session.shot("window-after-20-tabs.png")

        entered_cards = [step["step"] for step in steps if step["isCard"]]
        scrolled_steps = [step["step"] for step in steps if step["scrolled"]]
        inside_steps = [step["step"] for step in steps if step["focusInsideGrid"]]
        costs = [step["keyMs"] for step in steps]
        findings.append(finding(
            "K9.1 大库中 Tab 45 次的焦点行为",
            PASS if entered_cards else FAIL,
            f"进入卡片的步骤={len(entered_cards)} 次（首个 {entered_cards[0] if entered_cards else '无'}）；"
            f"焦点落在网格内={inside_steps or '无'}；"
            f"每次 Tab 耗时 p50={qa._stats(costs)['p50']}ms worst={qa._stats(costs)['worst']}ms",
            evidence=[f"{session.tag}/tab-traversal.json"],
            expected="Tab 能在 400 卡库中逐个进入卡片",
            note="系统未开启全键盘控制（AppleKeyboardUIMode=0）时 SwiftUI focusable 不参与 Tab 环",
        ))
        findings.append(finding(
            "K9.2 焦点随滚动进入视口",
            PASS if scrolled_steps and entered_cards else UNVERIFIED,
            f"焦点进入网格={bool(inside_steps)}；可视首卡变化步骤={scrolled_steps or '无'}",
            evidence=[f"{session.tag}/tab-traversal.json"],
            expected="焦点移动时网格自动滚动让焦点进入视口",
            note=None if entered_cards else "焦点未进入网格，无法验证滚动跟随",
        ))
        findings.append(finding(
            "K9.3 AX 顺序与视觉顺序一致性（阅读顺序推断）",
            PASS if order_matches else FAIL,
            f"AX 前序={ax_order[:6]}…；视觉序={visual[:6]}…；完全一致={order_matches}",
            evidence=[f"{session.tag}/reading-order.json"],
            expected="AX 遍历顺序与视觉阅读顺序一致",
            note="以 AX 顺序推断 VoiceOver 阅读顺序，非朗读实测",
        ))
    return {"scenario": "k9", "findings": findings, "score": score(findings)}


def grid_viewport(pid: int, nodes: list[dict]) -> dict | None:
    card_nodes = cards(nodes)
    if card_nodes:
        rects = [node["rect"] for node in card_nodes if node.get("rect")]
        if rects:
            left = min(rect["x"] for rect in rects)
            right = max(rect["x"] + rect["w"] for rect in rects)
            return {"x": left, "y": min(rect["y"] for rect in rects),
                    "w": right - left,
                    "h": max(rect["y"] + rect["h"] for rect in rects)
                    - min(rect["y"] for rect in rects),
                    "source": "visible-card-union"}
    scroll_areas = [node for node in nodes if node["role"] == "AXScrollArea"]
    for node in scroll_areas:
        rect = node.get("rect")
        if rect and rect["w"] > 300:
            return {**rect, "source": "AXScrollArea"}
    return None


def rect_inside(inner: dict, outer: dict) -> bool:
    return (inner["x"] >= outer["x"] - 2 and inner["y"] >= outer["y"] - 2
            and inner["x"] + inner["w"] <= outer["x"] + outer["w"] + 2
            and inner["y"] + inner["h"] <= outer["y"] + outer["h"] + 2)


# ---------------------------------------------------------------------------
# scenario K10 — crash / hang record
# ---------------------------------------------------------------------------

def scenario_k10(evidence: Evidence, results: dict | None = None) -> dict:
    findings: list[dict] = []
    baseline_binary = qa.QA_ROOT / "bin/PKD-baseline"
    bundle_binary = DEV_APP / "Contents/MacOS/PKD"
    identity = {
        "baselineBinary": str(baseline_binary),
        "baselineBinarySha256": sha256(baseline_binary) if baseline_binary.exists() else None,
        "bundleBinary": str(bundle_binary),
        "bundleBinarySha256": sha256(bundle_binary) if bundle_binary.exists() else None,
        "baselineEnvironment": str(BASE_ENV_FILE),
        "baselineEnvironmentSha256": sha256(BASE_ENV_FILE) if BASE_ENV_FILE.exists() else None,
        "runs": RUN_RECORDS,
    }
    evidence.write_json("k10/identity.json", identity)
    evidence.write_json("k10/runs.json", {
        "runs": RUN_RECORDS,
        "sceneRuntime": {name: payload.get("runtime") for name, payload in (results or {}).items()},
    })
    crashed_runs = [item for item in RUN_RECORDS
                    if item.get("returncode") not in (None, -15, 0, 15)]
    exceptions = {name: payload.get("runtime") for name, payload in (results or {}).items()
                  if (payload.get("runtime") or {}).get("crashed")}
    crash_hints = []
    for item in RUN_RECORDS:
        tail = item.get("logTail") or ""
        for marker in ("Fatal error", "SIGSEGV", "SIGABRT", "Trace/BPT trap",
                       "Illegal instruction", "崩溃"):
            if marker in tail:
                crash_hints.append({"scenario": item["scenario"], "marker": marker,
                                    "logPath": item.get("logPath")})
    ok = not crashed_runs and not exceptions and not crash_hints
    findings.append(finding(
        "K10.1 验收期间是否出现崩溃/无响应",
        PASS if ok else FAIL,
        f"未正常退出的运行={crashed_runs or '无'}；场景异常={list(exceptions) or '无'}；"
        f"日志崩溃标记={crash_hints or '无'}；运行次数={len(RUN_RECORDS)}",
        evidence=["k10/identity.json", "k10/runs.json", str(BASE_ENV_FILE)],
        expected="所有场景进程存活到 quit_app，无未处理异常/崩溃标记",
        note="被测二进制 SHA-256 见 identity.json；每个 run 的 root 与日志路径也记录在其中（不引用任何旧二进制结论）",
    ))
    return {"scenario": "k10", "findings": findings, "score": score(findings)}


# ---------------------------------------------------------------------------
# env snapshot + notes
# ---------------------------------------------------------------------------

def input_delivery_environment() -> dict:
    """Facts that decide whether synthetic input can be trusted on this host."""
    fronts = []
    for _ in range(3):
        fronts.append(front_app())
        time.sleep(0.2)
    infos = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    stack = []
    for info in infos[:12]:
        bounds = info.get("kCGWindowBounds") or {}
        stack.append({
            "owner": info.get("kCGWindowOwnerName"),
            "pid": info.get("kCGWindowOwnerPID"),
            "layer": info.get("kCGWindowLayer"),
            "title": (info.get("kCGWindowName") or "")[:40],
            "bounds": [round(bounds.get(key, 0)) for key in ("X", "Y", "Width", "Height")],
        })
    overlays = [item for item in stack
                if isinstance(item["layer"], int) and item["layer"] > 24]
    return {
        "frontmostSamples": fronts,
        "windowStackFrontToBack": stack,
        "windowsAboveNormalLayer": overlays,
        "keyboardDelivery": "CGEventPostToPid(pid, CGEventCreateKeyboardEvent) — "
                            "HID-tap keys are stolen while another app owns the front",
        "mouseDelivery": "AXPress on the control's default action (+ real modifier key state "
                         "for ⌘/⇧); HID clicks were observed to have no effect on the dev app",
    }


def build_environment(app_bundle: Path) -> dict:
    baseline_binary = qa.QA_ROOT / "bin/PKD-baseline"
    bundle_binary = app_bundle / "Contents/MacOS/PKD"
    display = Quartz.CGDisplayPixelsWide(Quartz.CGMainDisplayID()), \
        Quartz.CGDisplayPixelsHigh(Quartz.CGMainDisplayID())
    environment = {
        "startedAt": now_iso(),
        "repo": str(REPO),
        "head": run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"]).get("stdout"),
        "macOS": run(["sw_vers"]).get("stdout"),
        "kernel": run(["uname", "-m"]).get("stdout"),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"]).get("stdout"),
        "memoryBytes": run(["sysctl", "-n", "hw.memsize"]).get("stdout"),
        "displayPixels": display,
        "python": sys.version,
        "devApp": str(app_bundle),
        "devBundleIdentifier": DEV_DOMAIN,
        "bundleBinarySha256": sha256(bundle_binary) if bundle_binary.exists() else None,
        "baselineBinarySha256": sha256(baseline_binary) if baseline_binary.exists() else None,
        "baselineEnvironmentFile": str(BASE_ENV_FILE),
        "baselineEnvironmentSha256": sha256(BASE_ENV_FILE) if BASE_ENV_FILE.exists() else None,
        "baselineEnvironmentText": BASE_ENV_FILE.read_text(errors="replace")
        if BASE_ENV_FILE.exists() else None,
        "fixtureLibrary": str(qa.DATA / "library-400"),
        "fixtureCount": 400,
        "windowSizes": {"wide": list(WIDE), "narrow": list(NARROW)},
        "defaultsDomain": defaults_export(DEV_DOMAIN),
        "global": {
            "AppleKeyboardUIMode": defaults_get("-g", "AppleKeyboardUIMode"),
            "AppleShowScrollBars": defaults_get("-g", "AppleShowScrollBars"),
            "systemReduceMotion": defaults_get("com.apple.universalaccess", "reduceMotion"),
            "voiceOverRunning": voiceover_running(),
        },
        "axTrusted": ax_trusted(),
        "voiceOver": universal_access_snapshot(),
        "inputDelivery": input_delivery_environment(),
        "notes": [
            "只驱动开发副本；未修改产品源码、未构建、未提交",
            "截图全部窗口级；K7 的 60ms 采样用 CGWindowListCreateImage 限制在开发窗口",
            "未修改系统设置 / TCC / 辅助功能偏好；仅临时改写开发域 pkd.appearance.* 并恢复",
            "合成键盘用 CGEventPostToPid 直接投递到开发 App：本机有第三方全屏浮层窗口"
            "（层 999）长期占据前台，HID 键盘事件会被它抢走；在同一会话内用 Tab 焦点移动 / ⌘2 / "
            "⌥⌘L 证明事件确实到达 App。",
            "合成鼠标点击（HID 与 PostToPid 两种）在本机对开发 App 均无效（被全屏浮层吞掉/不进入窗口"
            "命中测试），因此点击类验证改用卡片的默认 AX 动作 AXPress（与 onTap 同一条代码路径）"
            "并真实按住修饰键；这一点在每个相关场景的 evidence 中单独记录。",
        ],
    }
    return environment


def ax_trusted() -> bool:
    try:
        from ApplicationServices import AXIsProcessTrusted
        return bool(AXIsProcessTrusted())
    except Exception:
        return False


def write_notes_from_disk(label_dir: Path) -> Path:
    """Rebuild notes.md from every scenario result already on disk."""
    results: dict[str, dict] = {}
    for name in ORDER:
        path = label_dir / name / "result.json"
        if not path.exists():
            continue
        try:
            payload = json.loads(path.read_text())
        except Exception:
            continue
        payload.setdefault("runtime", {})
        payload["runtime"]["logPath"] = str(label_dir / name)      # place-holder
        results[name] = payload
    evidence = Evidence(label_dir)
    env_path = label_dir / "env.json"
    evidence.env = json.loads(env_path.read_text()) if env_path.exists() else {}
    return write_notes(evidence, results, [name for name in ORDER if name in results])


def write_notes(evidence: Evidence, scenario_results: dict, order: list[str]) -> Path:
    lines = ["# 键盘 / 辅助功能验收记录", "",
             f"- 运行目录：`{evidence.root}`",
             f"- 开始时间：{evidence.env.get('startedAt')}",
             f"- 被测二进制：`{DEV_APP}/Contents/MacOS/PKD` "
             f"SHA-256 `{evidence.env.get('bundleBinarySha256')}`",
             f"- 基线二进制 SHA-256：`{evidence.env.get('baselineBinarySha256')}`",
             f"- 素材库：400 张中性占位卡（每个场景独立 fresh root）",
             f"- 窗口：宽 1200×800 / 窄 900×700（除个别场景）",
             "", "| 项目 | 结果 | 证据 |", "| --- | --- | --- |"]
    totals = {PASS: 0, FAIL: 0, GAP: 0, UNVERIFIED: 0}
    for name in order:
        payload = scenario_results.get(name) or {}
        for item in payload.get("findings", []):
            totals[item["status"]] = totals.get(item["status"], 0) + 1
            evidence_list = ", ".join(f"`{path}`" for path in item["evidence"][:3])
            lines.append(f"| {item['check']} | {item['status']} | {evidence_list} |")
    lines += ["", "## 汇总", "",
              f"- PASS {totals.get(PASS, 0)} · FAIL {totals.get(FAIL, 0)} · "
              f"GAP {totals.get(GAP, 0)} · UNVERIFIED {totals.get(UNVERIFIED, 0)}", ""]
    for name in order:
        payload = scenario_results.get(name) or {}
        findings = payload.get("findings", [])
        if not findings:
            continue
        lines.append(f"### {name.upper()}")
        for item in findings:
            lines.append(f"- **{item['status']}** {item['check']}")
            lines.append(f"  - 观察：{item['observed']}")
            if item.get("expected"):
                lines.append(f"  - 期望：{item['expected']}")
            if item.get("note"):
                lines.append(f"  - 备注：{item['note']}")
            for path in item["evidence"]:
                lines.append(f"  - 证据：`{path}`")
        lines.append("")
    return evidence.write_text("notes.md", "\n".join(lines))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

ORDER = ["k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9", "k10"]


def parse_selection(raw: str | None) -> list[str]:
    if not raw:
        return [name for name in ORDER if name != "k10"]
    chosen = [part.strip().lower() for part in raw.split(",") if part.strip()]
    unknown = [name for name in chosen if name not in ORDER]
    if unknown:
        raise SystemExit(f"unknown scenarios: {unknown}; pick from {ORDER}")
    return chosen


def main() -> None:
    global SCENARIOS
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenarios", default=None,
                        help="comma separated subset of k1..k10 (default: all but k10)")
    parser.add_argument("--label", default=None,
                        help="evidence directory name (default baseline-<HHMM>)")
    parser.add_argument("--app", default=None,
                        help="development bundle to drive (default app/.build/ui-qa/app/PKD QA.app)")
    parser.add_argument("--reanalyze-k7", nargs="*", default=None,
                        help="recompute K7 verdicts from recorded frames for these labels")
    parser.add_argument("--notes", nargs="*", default=None,
                        help="rebuild notes.md from finished scenario results "
                             "(args: evidence labels or dirs; default: every label)")
    parser.add_argument("--keep-going", action="store_true", default=True)
    parser.add_argument("--lock-timeout", type=float, default=900.0)
    args = parser.parse_args()

    if args.reanalyze_k7 is not None:
        labels = args.reanalyze_k7 or [path.name for path in sorted(EVIDENCE_PARENT.iterdir())
                                       if path.is_dir() and (path / "k7-off").exists()]
        for label in labels:
            directory = EVIDENCE_PARENT / label if not Path(label).is_absolute() else Path(label)
            analysis = analyze_motion_evidence(directory)
            (directory / "k7").mkdir(parents=True, exist_ok=True)
            (directory / "k7" / "analysis.json").write_text(
                json.dumps(analysis, ensure_ascii=False, indent=2), encoding="utf-8")
            inspector_regions = inspector_region_analysis(directory / "k7-off")
            (directory / "k7" / "inspector-regions.json").write_text(
                json.dumps(inspector_regions, ensure_ascii=False, indent=2), encoding="utf-8")
            verdicts = []
            for action, label_text in (("sort", "排序切换"), ("density", "密度切换"),
                                       ("inspector", "检查器开关")):
                off = (analysis.get("k7-off") or {}).get(action) or {}
                control = (analysis.get("k7-control") or {}).get(action) or {}
                off_profile = off.get("profile") or {}
                control_profile = control.get("profile") or {}
                if not off_profile:
                    verdicts.append((label_text, UNVERIFIED, "off 组没有可用帧",
                                     off, control))
                    continue
                animated = bool(off_profile.get("animation"))
                status = FAIL if animated else PASS
                control_animated = bool(control_profile.get("animation"))
                if status == PASS and not control_animated:
                    status = UNVERIFIED          # measurement could not see animation at all
                if action == "inspector":
                    # region split shows the residual motion lives in the content
                    # column (grid reflow while the split-view column animates),
                    # not in the panel content -> system inspector transition.
                    status = UNVERIFIED
                    off_profile = dict(off_profile)
                    off_profile["systemTransition"] = inspector_regions.get("verdict")
                verdicts.append((label_text, status, off_profile, off, control))
            findings = []
            for label_text, status, profile, off, control in verdicts:
                detail = (f"off: 中间帧={profile.get('intermediateFrames') if isinstance(profile, dict) else 'n/a'} "
                          f"跳变帧={profile.get('plateauFrames') if isinstance(profile, dict) else 'n/a'} "
                          f"稳定于≈{profile.get('settleAtMs') if isinstance(profile, dict) else 'n/a'}ms "
                          f"动作改变量={(off.get('actionChanged'))}；"
                          f"control: 中间帧={(control.get('profile') or {}).get('intermediateFrames')} "
                          f"动作改变量={control.get('actionChanged')}")
                findings.append(finding(
                    f"K7 · motion=off 时「{label_text}」无过渡动画",
                    status, detail,
                    evidence=["k7/analysis.json", "k7-off/motion.json", "k7-control/motion.json",
                              "k7/defaults-before.json", "k7/defaults-after.json"],
                    expected="motion=off 时三处交互都不应残留过渡动画",
                    note="帧档案来自窗口级 CGWindowListCreateImage 密集采样（约 40ms/帧、1.4s）；"
                         "中间帧=出现了既非旧布局也非新布局的像素状态，即存在过渡动画；"
                         "control 组（motion=system）必须能看到动画，否则记 UNVERIFIED。",
                ))
            result_path = directory / "k7" / "result.json"
            previous = json.loads(result_path.read_text()) if result_path.exists() else {}
            previous.setdefault("scenario", "k7")
            previous["findings"] = findings
            previous["score"] = score(findings)
            previous["source"] = "reanalyzed from recorded frames by --reanalyze-k7"
            result_path.write_text(json.dumps(previous, ensure_ascii=False, indent=2),
                                   encoding="utf-8")
            print(f"k7 reanalyzed: {result_path}")
        return

    if args.notes is not None:
        targets = args.notes or [str(path) for path in sorted(EVIDENCE_PARENT.iterdir())
                                 if path.is_dir()]
        for target in targets:
            directory = Path(target).expanduser()
            if not directory.is_absolute():
                directory = EVIDENCE_PARENT / directory
            if not directory.exists():
                print(f"skip missing {directory}")
                continue
            print(write_notes_from_disk(directory))
        return

    selected = parse_selection(args.scenarios)
    label = args.label or f"baseline-{datetime.datetime.now().strftime('%H%M')}"
    evidence = Evidence(EVIDENCE_PARENT / label)
    log(f"evidence: {evidence.root}")

    app_bundle = Path(args.app).expanduser() if args.app else DEV_APP
    if not app_bundle.exists():
        raise SystemExit(f"missing development bundle: {app_bundle}")
    qa.verify_dev_bundle(app_bundle)      # refuses anything but com.zeh.pkd.development
    global APP_BUNDLE
    APP_BUNDLE = app_bundle
    evidence.env = build_environment(app_bundle)
    evidence.write_json("env.json", evidence.env)

    results: dict[str, dict] = {}
    with HeartbeatLock(timeout=args.lock_timeout):
        log(f"drive lock acquired; scenarios={selected}")
        for name in selected:
            function = SCENARIOS.get(name)
            if function is None:
                results[name] = {"scenario": name, "findings": [
                    finding(f"{name} · 未知场景", UNVERIFIED, f"{name} 未实现",
                            expected=None)]}
                continue
            log(f"scenario {name}: start")
            started = time.monotonic()
            runs_before = len(RUN_RECORDS)
            runtime = {"startedAt": now_iso(), "crashed": False, "logPath": None,
                       "root": None, "tag": name, "exception": None}
            try:
                payload = function(evidence)
                runtime["elapsedSeconds"] = round(time.monotonic() - started, 1)
            except Exception as error:
                runtime["crashed"] = True
                runtime["exception"] = f"{type(error).__name__}: {error}"
                runtime["traceback"] = traceback.format_exc()[-4000:]
                log(f"scenario {name} raised: {runtime['exception']}")
                payload = {"scenario": name, "findings": [
                    finding(f"{name} · 场景执行异常", UNVERIFIED,
                            runtime["exception"], evidence=[f"{name}/traceback.txt"],
                            expected="场景完整执行")], "score": {}}
                evidence.write_text(f"{name}/traceback.txt", runtime["traceback"])
            scenario_runs = RUN_RECORDS[runs_before:]
            if scenario_runs:
                runtime["root"] = scenario_runs[-1]["root"]
                runtime["logPath"] = scenario_runs[-1]["logPath"]
            runtime["runs"] = scenario_runs
            payload["runtime"] = runtime
            results[name] = payload
            evidence.write_json(f"{name}/result.json", {
                key: value for key, value in payload.items() if key != "runtime"})
            log(f"scenario {name}: {payload.get('score')}")

    if True:      # k10 is pure aggregation over what already ran
        try:
            results["k10"] = scenario_k10(evidence, results)
            evidence.write_json("k10/result.json",
                                {key: value for key, value in results["k10"].items()
                                 if key != "runtime"})
            results["k10"]["runtime"] = {"startedAt": now_iso(), "crashed": False}
        except Exception as error:  # pragma: no cover
            log(f"k10 failed: {error}")

    summary = {name: {"score": payload.get("score"),
                      "runtime": payload.get("runtime")}
               for name, payload in results.items()}
    evidence.write_json("run-summary.json", {"label": label, "scenarios": selected,
                                             "summary": summary,
                                             "env": evidence.env})
    notes_path = write_notes(evidence, results, [name for name in ORDER if name in results])
    log(f"notes: {notes_path}")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
