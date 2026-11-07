#!/usr/bin/env python3
"""证据/测试工具共用的安全目录策略。

背景（渲染审查问题 5）：旧版 verify_golden.py 会无条件 ``shutil.rmtree`` 调用者传入的
目录，pkg_ablate.py 也会删除自己命名的历史目录。二者都可能误删调用者数据，且删除后
无法取证。本模块把规则收敛成一套：

* 工具只在 ``base/<tool>-<时间>-<随机>`` 这样的**专属新目录**里写数据；
* 目录里写归属标记 ``.evidence-tool-owner.json``，记录本次 run_id、工具名、真实路径、
  base 真实路径；
* 删除只允许“本次 run 创建、标记完全匹配、真实路径仍位于 base 内”的目录；
* 根目录、家目录、仓库源码树、符号链接、越界路径一律拒绝；
* 默认保留运行目录（便于取证），清理必须显式触发。

命令行工具把 :class:`ToolSafetyError` 转成固定退出码 :data:`EXIT_UNSAFE`，与“测试/断言
失败”的退出码区分开，方便脚本判断“拒绝执行”而不是“结果不对”。
"""
from __future__ import annotations

import json
import os
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional

SCHEMA = 1
MARKER_NAME = ".evidence-tool-owner.json"
EXIT_UNSAFE = 3

#: ``Path(__file__)`` 是 ``<repo>/tools/testdata/evidence_tool_safety.py``。
REPO = Path(__file__).resolve().parents[2]
#: 仓库里唯一允许写运行证据的目录（被 .gitignore 忽略）。
PRIVATE_EVIDENCE_ROOT = REPO / "app" / ".build"


class ToolSafetyError(RuntimeError):
    """违反安全目录策略；命令行工具应转成 :data:`EXIT_UNSAFE`。"""


def _real(path: os.PathLike) -> Path:
    return Path(os.path.realpath(str(path)))


def _protected_paths() -> List[Path]:
    home = Path.home()
    return [
        Path("/"),
        home,
        REPO,
        Path("/Users"),
        Path("/Applications"),
        Path("/System"),
        Path("/Library"),
        Path("/Volumes"),
        Path("/private"),
        Path("/usr"),
        Path("/etc"),
        Path("/bin"),
        Path("/sbin"),
        Path("/opt"),
        Path("/tmp"),
        Path("/var"),
    ]


def _protected_realpaths() -> List[Path]:
    return [_real(path) for path in _protected_paths()]


def is_within(child: os.PathLike, parent: os.PathLike) -> bool:
    """``child`` 是否等于 ``parent`` 或位于其下（均按真实路径比较）。"""
    child_real, parent_real = _real(child), _real(parent)
    if child_real == parent_real:
        return True
    try:
        child_real.relative_to(parent_real)
    except ValueError:
        return False
    return True


def _reject_protected(resolved: Path, what: str) -> None:
    for protected in _protected_realpaths():
        if resolved == protected:
            raise ToolSafetyError(f"拒绝把{what}指向受保护路径：{resolved}")


def _reject_repo_source(resolved: Path, what: str) -> None:
    if is_within(resolved, REPO) and not is_within(resolved, PRIVATE_EVIDENCE_ROOT):
        raise ToolSafetyError(
            f"拒绝把{what}指向仓库源码树：{resolved}（只允许 {PRIVATE_EVIDENCE_ROOT} 下的私有证据目录）"
        )


def _reject_shallow(resolved: Path, what: str) -> None:
    # /tmp、/Users/foo 这类过浅的路径不做运行目录容器，避免误删/误建。
    if len(resolved.parts) <= 2:
        raise ToolSafetyError(f"拒绝把{what}指向过浅的路径：{resolved}")


def ensure_directory(path: os.PathLike, *, what: str = "目录", create: bool = True) -> Path:
    """校验（必要时创建）一个可用于写入的目录，返回其真实路径。"""
    if path is None or str(path) == "":
        raise ToolSafetyError(f"{what}不能为空")
    candidate = Path(path)
    if not candidate.is_absolute():
        raise ToolSafetyError(f"{what}必须是绝对路径：{candidate}")

    resolved = _real(candidate)
    _reject_protected(resolved, what)
    _reject_shallow(resolved, what)
    _reject_repo_source(resolved, what)

    if candidate.exists():
        if candidate.is_symlink():
            # 符号链接可以指向受保护路径；真实路径校验已经做过，这里只做记录式放行，
            # 但要求目标确实是目录且不是悬挂链接。
            if not resolved.is_dir():
                raise ToolSafetyError(f"{what}是符号链接但目标不是目录：{candidate}")
        elif not candidate.is_dir():
            raise ToolSafetyError(f"{what}已存在但不是目录：{candidate}")
        return resolved

    if not create:
        raise ToolSafetyError(f"{what}不存在：{candidate}")

    # 逐级找到最近的存在祖先，确认它也不是受保护路径/源码树，再一次性创建。
    ancestor = candidate.parent
    while not ancestor.exists():
        if ancestor.parent == ancestor:
            break
        ancestor = ancestor.parent
    ancestor_real = _real(ancestor)
    _reject_protected(ancestor_real, f"{what}的上级")
    _reject_shallow(ancestor_real, f"{what}的上级")
    _reject_repo_source(ancestor_real, f"{what}的上级")
    try:
        candidate.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        pass
    resolved = _real(candidate)
    _reject_protected(resolved, what)
    _reject_repo_source(resolved, what)
    return resolved


def _write_marker(path: Path, payload: Dict[str, object]) -> None:
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    fd = os.open(str(path), flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=1)
            handle.write("\n")
    except BaseException:
        # os.fdopen 已经接管 fd；这里只保证半成品标记不会留下来冒充归属证明。
        try:
            path.unlink()
        except OSError:
            pass
        raise


def read_marker(path: os.PathLike) -> Optional[Dict[str, object]]:
    marker_path = Path(path) / MARKER_NAME
    try:
        with open(marker_path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def has_owned_marker(path: os.PathLike, tool: Optional[str] = None) -> bool:
    marker = read_marker(path)
    if marker is None:
        return False
    if marker.get("schema") != SCHEMA:
        return False
    if not isinstance(marker.get("realpath"), str):
        return False
    if Path(marker["realpath"]) != _real(path):
        return False
    if tool is not None and marker.get("tool") != tool:
        return False
    return True


def _validate_tool_name(tool: str) -> str:
    if not tool or not all(char.isalnum() or char in "-_." for char in tool):
        raise ToolSafetyError(f"工具名只允许字母数字与 -_.：{tool!r}")
    return tool


class OwnedRunDir:
    """``base`` 下的一次性专属运行目录，带归属标记。

    目录创建后不会自动删除；调用 :meth:`cleanup` 才会删，而且只删本次 run 的目录。
    """

    def __init__(
        self,
        base: os.PathLike,
        tool: str,
        *,
        purpose: str = "",
        slug: Optional[str] = None,
        create_base: bool = True,
    ) -> None:
        self.tool = _validate_tool_name(tool)
        self.base = ensure_directory(base, what=f"{tool} 的输出基准目录", create=create_base)
        self.run_id = uuid.uuid4().hex
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        middle = f"{self.tool}-{slug}-{stamp}-{self.run_id[:8]}"
        if not slug:
            middle = f"{self.tool}-{stamp}-{self.run_id[:8]}"
        self.path = self.base / middle
        os.mkdir(str(self.path))
        self.realpath = _real(self.path)
        if not is_within(self.realpath, self.base):
            try:
                os.rmdir(str(self.path))
            finally:
                raise ToolSafetyError(f"运行目录逃出了基准目录：{self.path} -> {self.realpath}")
        self.marker_path = self.path / MARKER_NAME
        _write_marker(
            self.marker_path,
            {
                "schema": SCHEMA,
                "tool": self.tool,
                "run_id": self.run_id,
                "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "pid": os.getpid(),
                "purpose": purpose,
                "realpath": str(self.realpath),
                "base_realpath": str(self.base),
                "host": os.uname().sysname if hasattr(os, "uname") else "",
            },
        )

    def cleanup(self) -> None:
        remove_owned_run_dir(self.path, run_id=self.run_id, tool=self.tool)

    def __enter__(self) -> "OwnedRunDir":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:  # noqa: D105 - 不自动删除
        return None

    def __fspath__(self) -> str:  # 方便 Path(...)/str(...) 直接使用
        return str(self.path)


def _is_symlink_anywhere(path: Path, base: Path) -> bool:
    """路径自身或 base 到路径之间是否有符号链接分量（防止删除被链接重定向）。"""
    if path.is_symlink():
        return True
    current = path
    while True:
        if current.is_symlink():
            return True
        if current == base or current.parent == current:
            return False
        current = current.parent


def remove_owned_run_dir(path: os.PathLike, *, run_id: str, tool: str) -> Path:
    """删除本次 run 创建、且有完整归属证明的目录；任何不匹配都拒绝。"""
    candidate = Path(path)
    if not str(candidate):
        raise ToolSafetyError("拒绝删除空路径")
    if not candidate.is_absolute():
        raise ToolSafetyError(f"拒绝删除相对路径：{candidate}")
    if not candidate.exists():
        raise ToolSafetyError(f"要删除的运行目录不存在：{candidate}")
    if candidate.is_symlink():
        raise ToolSafetyError(f"拒绝删除符号链接：{candidate}")
    resolved = _real(candidate)
    _reject_protected(resolved, "运行目录")
    _reject_shallow(resolved, "运行目录")
    _reject_repo_source(resolved, "运行目录")
    if not resolved.is_dir():
        raise ToolSafetyError(f"要删除的运行目录不是目录：{resolved}")

    marker = read_marker(candidate)
    if marker is None:
        raise ToolSafetyError(f"拒绝删除没有归属标记的目录：{resolved}")
    if marker.get("schema") != SCHEMA:
        raise ToolSafetyError(f"拒绝删除标记版本不匹配的目录：{resolved}")
    if marker.get("tool") != tool:
        raise ToolSafetyError(f"拒绝删除其它工具创建的目录：{resolved}（标记工具 {marker.get('tool')!r}）")
    if marker.get("run_id") != run_id:
        raise ToolSafetyError(f"拒绝删除其它 run 创建的目录：{resolved}")
    if Path(str(marker.get("realpath"))) != resolved:
        raise ToolSafetyError(f"拒绝删除标记与真实路径不一致的目录：{resolved}")
    base = Path(str(marker.get("base_realpath")))
    if not is_within(resolved, base):
        raise ToolSafetyError(f"拒绝删除位于基准目录之外的目录：{resolved}")
    if _is_symlink_anywhere(resolved, _real(base)):
        raise ToolSafetyError(f"拒绝删除路径中含符号链接的目录：{resolved}")

    shutil.rmtree(str(resolved))
    return resolved


def clean_owned_runs(base: os.PathLike, tool: str) -> List[Path]:
    """清理 ``base`` 下本工具留下的历史运行目录（只认完整标记）。"""
    tool = _validate_tool_name(tool)
    base_path = ensure_directory(base, what=f"{tool} 的输出基准目录", create=False)
    removed: List[Path] = []
    try:
        entries = sorted(base_path.iterdir())
    except OSError:
        return removed
    for entry in entries:
        if entry.is_symlink() or not entry.is_dir():
            continue
        if not entry.name.startswith(f"{tool}-"):
            continue
        marker = read_marker(entry)
        if marker is None or marker.get("tool") != tool or marker.get("schema") != SCHEMA:
            continue
        if Path(str(marker.get("realpath"))) != _real(entry):
            continue
        if not is_within(entry, base_path):
            continue
        try:
            shutil.rmtree(str(entry))
        except OSError:
            continue
        removed.append(entry)
    return removed


def ensure_empty_or_new(path: os.PathLike, *, what: str = "输出目录") -> Path:
    """用于接受调用者目录的入口：新目录/空目录可用，非空目录拒绝。"""
    resolved = ensure_directory(path, what=what, create=True)
    entries = list(resolved.iterdir())
    if entries:
        raise ToolSafetyError(
            f"{what}已存在且非空：{resolved}（拒绝混入/覆盖既有证据；请换新目录或显式允许复用）"
        )
    return resolved


def describe_error(error: BaseException) -> str:
    return f"{type(error).__name__}: {error}"


def iter_owned_children(base: os.PathLike, tool: str) -> Iterable[Path]:
    base_path = ensure_directory(base, what=f"{tool} 的输出基准目录", create=False)
    for entry in sorted(base_path.iterdir()):
        if entry.is_symlink() or not entry.is_dir():
            continue
        if has_owned_marker(entry, tool=tool):
            yield entry


def write_owner_marker(path: os.PathLike, tool: str, *, purpose: str = "",
                       run_id: Optional[str] = None) -> Dict[str, object]:
    """给调用者指定、但由本工具整目录拥有的证据目录写归属标记（不删除该目录）。"""
    tool = _validate_tool_name(tool)
    resolved = ensure_directory(path, what=f"{tool} 证据目录", create=True)
    if (resolved / MARKER_NAME).exists():
        raise ToolSafetyError(f"证据目录已有归属标记，拒绝覆盖：{resolved}")
    run_id = run_id or uuid.uuid4().hex
    payload: Dict[str, object] = {
        "schema": SCHEMA,
        "tool": tool,
        "run_id": run_id,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "pid": os.getpid(),
        "purpose": purpose,
        "realpath": str(resolved),
        "base_realpath": str(resolved.parent),
        "host": os.uname().sysname if hasattr(os, "uname") else "",
    }
    _write_marker(resolved / MARKER_NAME, payload)
    return payload
