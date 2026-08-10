#!/usr/bin/env python3
"""Host adapter registry for multi-host transcript locate + normalize (CDT-156).

Importable contract (SPEC-012 multi-host adapters; transcript-parse boundary):

  HOSTS = ("claude", "grok")
  locate(host, session_id|None, cwd, *, sessions_dir=None) -> abs_source_path|None
  normalize(host, source_path, *, cwd, session_id, mode="scoring"|"handoff") -> abs_feed_path

Claude (this task):
  locate  — wrap assemble.locate(uuid) when session_id set; else newest-mtime
            *.jsonl under ~/.claude/projects/<dash-encoded-cwd>/
  normalize — identity (return source_path); score-compatible, no rewrite

Grok:
  locate  — cwd-bucket under GROK_SESSIONS_DIR (urlencode cwd); by-id or newest
  normalize — grok_normalize.normalize_to_file (scoring keeps tool_result)

CLI (shell callers in retro.md):
  python3 hosts.py locate  --host claude|grok [--session-id SID] --cwd DIR
                           [--sessions-dir DIR]
  python3 hosts.py normalize --host claude|grok --source PATH --cwd DIR
                             --session-id SID [--mode scoring|handoff]
"""

from __future__ import annotations

import argparse
import os
import sys
import urllib.parse
from typing import Callable, Optional

# Same directory as assemble.py / parselib.py — import sibling without package.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import assemble  # noqa: E402  — sibling module, not a package
import grok_normalize  # noqa: E402  — sibling module (CDT-156 T3)

HOSTS = ("claude", "grok")
MODES = ("scoring", "handoff")

# Default Claude projects root (overridable via locate sessions_dir=).
DEFAULT_CLAUDE_PROJECTS_DIR = assemble.PROJECTS_DIR

# Default Grok sessions root when GROK_SESSIONS_DIR unset (resolved at call time).
DEFAULT_GROK_SESSIONS_DIR = os.path.expanduser("~/.grok/sessions")
CHAT_HISTORY_BASENAME = "chat_history.jsonl"


def _warn(msg: str) -> None:
    sys.stderr.write("transcript-parse hosts: " + msg + "\n")


def _require_host(host: str) -> str:
    h = (host or "").strip().lower()
    if h not in HOSTS:
        raise ValueError(
            f"unknown host {host!r}; expected one of {', '.join(HOSTS)}"
        )
    return h


def _require_mode(mode: str) -> str:
    m = (mode or "scoring").strip().lower()
    if m not in MODES:
        raise ValueError(
            f"unknown mode {mode!r}; expected one of {', '.join(MODES)}"
        )
    return m


def dash_encode_cwd(cwd: str) -> str:
    """Claude project-dir encoding: absolute path with every '/' → '-'."""
    abs_cwd = os.path.abspath(os.path.expanduser(cwd or "."))
    return abs_cwd.replace("/", "-")


def urlencode_cwd(cwd: str) -> str:
    """Grok session-bucket encoding: urllib.parse.quote(abs_cwd, safe='').

    Matches discover-warm / live layout: slashes become %2F (CDT-92).
    """
    abs_cwd = os.path.abspath(os.path.expanduser(cwd or "."))
    return urllib.parse.quote(abs_cwd, safe="")


def claude_project_dir(cwd: str, *, projects_dir: Optional[str] = None) -> str:
    root = projects_dir or DEFAULT_CLAUDE_PROJECTS_DIR
    return os.path.join(root, dash_encode_cwd(cwd))


def grok_sessions_root(*, sessions_dir: Optional[str] = None) -> str:
    """Resolve Grok sessions root: sessions_dir= > GROK_SESSIONS_DIR > default."""
    if sessions_dir is not None:
        return os.path.abspath(os.path.expanduser(sessions_dir))
    env = os.environ.get("GROK_SESSIONS_DIR")
    if env:
        return os.path.abspath(os.path.expanduser(env))
    return os.path.abspath(DEFAULT_GROK_SESSIONS_DIR)


def grok_cwd_bucket(cwd: str, *, sessions_dir: Optional[str] = None) -> str:
    """`${sessions_root}/<urlencode(cwd)>` — MVP exact-cwd bucket only."""
    return os.path.join(grok_sessions_root(sessions_dir=sessions_dir), urlencode_cwd(cwd))


def _claude_locate_newest(cwd: str, *, projects_dir: Optional[str] = None) -> Optional[str]:
    """Newest-mtime *.jsonl under the dash-encoded project dir for cwd."""
    pdir = claude_project_dir(cwd, projects_dir=projects_dir)
    if not os.path.isdir(pdir):
        return None
    best_path: Optional[str] = None
    best_mtime: float = -1.0
    try:
        names = os.listdir(pdir)
    except OSError as e:
        _warn(f"cannot list {pdir}: {e}")
        return None
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(pdir, name)
        if not os.path.isfile(path):
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        # Ties: prefer lexicographically smaller path (deterministic).
        if best_path is None or mtime > best_mtime or (
            mtime == best_mtime and path < best_path
        ):
            best_path, best_mtime = path, mtime
    return best_path


def _claude_locate(
    session_id: Optional[str],
    cwd: str,
    *,
    sessions_dir: Optional[str] = None,
) -> Optional[str]:
    """Claude locate: by uuid (fork-aware) or newest mtime under project dir."""
    if session_id:
        # assemble.locate scans all ~/.claude/projects (fork canonical pick).
        # sessions_dir override is ignored for uuid locate — fork trees may
        # span project dirs; assemble always uses PROJECTS_DIR. If a test
        # needs a custom root, patch assemble.PROJECTS_DIR.
        if sessions_dir is not None and sessions_dir != DEFAULT_CLAUDE_PROJECTS_DIR:
            # Temporarily point assemble at the override for testability.
            prev = assemble.PROJECTS_DIR
            try:
                assemble.PROJECTS_DIR = sessions_dir
                return assemble.locate(session_id)
            finally:
                assemble.PROJECTS_DIR = prev
        return assemble.locate(session_id)
    return _claude_locate_newest(cwd, projects_dir=sessions_dir)


def _claude_normalize(
    source_path: str,
    *,
    cwd: str,
    session_id: str,
    mode: str,
) -> str:
    """Identity normalize — Claude JSONL is already the gate feed shape."""
    del cwd, session_id, mode  # contract kwargs; unused for identity
    if not source_path:
        raise ValueError("source_path is required")
    return os.path.abspath(os.path.expanduser(source_path))


def _realpath_or_abs(path: str) -> str:
    try:
        return os.path.realpath(path)
    except OSError:
        return os.path.abspath(path)


def _path_under_root(path: str, root: str) -> bool:
    """True if path is root or a descendant (realpath prefix match)."""
    abs_p = _realpath_or_abs(path)
    abs_root = _realpath_or_abs(root).rstrip(os.sep)
    return abs_p == abs_root or abs_p.startswith(abs_root + os.sep)


def is_grok_chat_history(path: str, *, sessions_dir: Optional[str] = None) -> bool:
    """True iff path is a regular file named chat_history.jsonl under sessions root."""
    if not path or not os.path.isfile(path):
        return False
    if os.path.basename(path) != CHAT_HISTORY_BASENAME:
        return False
    return _path_under_root(path, grok_sessions_root(sessions_dir=sessions_dir))


def _grok_env_transcript_path(
    session_id: Optional[str],
    *,
    sessions_dir: Optional[str] = None,
) -> Optional[str]:
    """Honor GROK_TRANSCRIPT_PATH when under sessions root and named chat_history.jsonl."""
    env_path = os.environ.get("GROK_TRANSCRIPT_PATH")
    if not env_path:
        return None
    if not is_grok_chat_history(env_path, sessions_dir=sessions_dir):
        return None
    abs_p = os.path.abspath(env_path)
    if session_id:
        parent_sid = os.path.basename(os.path.dirname(abs_p))
        if parent_sid != session_id:
            return None
    return abs_p


def _grok_locate_by_id(
    session_id: str,
    cwd: str,
    *,
    sessions_dir: Optional[str] = None,
) -> Optional[str]:
    """Path under cwd bucket only: …/<enc>/<sid>/chat_history.jsonl (MVP)."""
    if not session_id or session_id in (".", "..") or os.sep in session_id:
        return None
    if os.altsep and os.altsep in session_id:
        return None
    path = os.path.join(
        grok_cwd_bucket(cwd, sessions_dir=sessions_dir),
        session_id,
        CHAT_HISTORY_BASENAME,
    )
    if os.path.isfile(path):
        return os.path.abspath(path)
    return None


def _grok_locate_newest(
    cwd: str,
    *,
    sessions_dir: Optional[str] = None,
) -> Optional[str]:
    """Newest-mtime chat_history.jsonl under cwd bucket only (no MROOT fan-out)."""
    bucket = grok_cwd_bucket(cwd, sessions_dir=sessions_dir)
    if not os.path.isdir(bucket):
        return None
    best_path: Optional[str] = None
    best_mtime: float = -1.0
    try:
        names = os.listdir(bucket)
    except OSError as e:
        _warn(f"cannot list {bucket}: {e}")
        return None
    for name in names:
        # Layout: bucket/<sid>/chat_history.jsonl (mindepth 2 / maxdepth 2).
        if name in (".", ".."):
            continue
        path = os.path.join(bucket, name, CHAT_HISTORY_BASENAME)
        if not os.path.isfile(path):
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if best_path is None or mtime > best_mtime or (
            mtime == best_mtime and path < best_path
        ):
            best_path, best_mtime = path, mtime
    return os.path.abspath(best_path) if best_path else None


def _grok_locate(
    session_id: Optional[str],
    cwd: str,
    *,
    sessions_dir: Optional[str] = None,
) -> Optional[str]:
    """Grok locate: cwd-bucket by-id or newest; optional GROK_TRANSCRIPT_PATH pin.

    Path layout:
      ${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(cwd)>/<sid>/chat_history.jsonl

    MVP: exact cwd bucket only (no full MROOT/worktree fan-out).
    """
    pinned = _grok_env_transcript_path(session_id, sessions_dir=sessions_dir)
    if pinned is not None:
        return pinned
    if session_id:
        return _grok_locate_by_id(session_id, cwd, sessions_dir=sessions_dir)
    return _grok_locate_newest(cwd, sessions_dir=sessions_dir)


def _grok_normalize(
    source_path: str,
    *,
    cwd: str,
    session_id: str,
    mode: str,
) -> str:
    """Grok → Claude-shaped feed via grok_normalize (TMPDIR unless out set)."""
    return grok_normalize.normalize_to_file(
        source_path,
        cwd=cwd,
        session_id=session_id,
        mode=mode,
    )


# Dispatch tables — T2/T3 replace stub callables in place or extend maps.
_LOCATORS: dict[str, Callable[..., Optional[str]]] = {
    "claude": _claude_locate,
    "grok": _grok_locate,
}
_NORMALIZERS: dict[str, Callable[..., str]] = {
    "claude": _claude_normalize,
    "grok": _grok_normalize,
}


def locate(
    host: str,
    session_id: Optional[str],
    cwd: str,
    *,
    sessions_dir: Optional[str] = None,
) -> Optional[str]:
    """Return absolute source transcript path for host, or None if missing.

    host: "claude" | "grok"
    session_id: explicit session uuid, or None for newest under host root
    cwd: project directory used for host bucket encoding
    sessions_dir: optional override root (Claude: projects dir; Grok: sessions dir)
    """
    h = _require_host(host)
    if not cwd:
        raise ValueError("cwd is required")
    fn = _LOCATORS[h]
    return fn(session_id, cwd, sessions_dir=sessions_dir)


def normalize(
    host: str,
    source_path: str,
    *,
    cwd: str,
    session_id: str,
    mode: str = "scoring",
) -> str:
    """Return absolute gate-feed path (Claude-shaped JSONL for scoring).

    Claude scoring/handoff: identity (source_path).
    Grok scoring: tool_result kept + name map + exit:N is_error (TMPDIR path).
    Grok handoff: skip tool_result (CDT-92 parity; T8 may wrap handoff script).
    """
    h = _require_host(host)
    m = _require_mode(mode)
    if not source_path:
        raise ValueError("source_path is required")
    if not cwd:
        raise ValueError("cwd is required")
    if not session_id:
        raise ValueError("session_id is required")
    fn = _NORMALIZERS[h]
    return fn(source_path, cwd=cwd, session_id=session_id, mode=m)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cmd_locate(args: argparse.Namespace) -> int:
    try:
        path = locate(
            args.host,
            args.session_id,
            args.cwd,
            sessions_dir=args.sessions_dir,
        )
    except NotImplementedError as e:
        _warn(str(e))
        return 2
    except ValueError as e:
        _warn(str(e))
        return 2
    if path is None:
        sid = args.session_id or "(newest)"
        _warn(f"no transcript for host={args.host} session={sid} cwd={args.cwd}")
        return 1
    sys.stdout.write(path + "\n")
    return 0


def _cmd_normalize(args: argparse.Namespace) -> int:
    try:
        out = normalize(
            args.host,
            args.source,
            cwd=args.cwd,
            session_id=args.session_id,
            mode=args.mode,
        )
    except NotImplementedError as e:
        _warn(str(e))
        return 2
    except ValueError as e:
        _warn(str(e))
        return 2
    sys.stdout.write(out + "\n")
    return 0


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="hosts.py",
        description=(
            "Multi-host transcript adapter: locate source JSONL and normalize "
            "to a Claude-shaped gate feed (CDT-156)."
        ),
    )
    sub = p.add_subparsers(dest="command", required=True)

    loc = sub.add_parser("locate", help="Locate source transcript for a host")
    loc.add_argument(
        "--host",
        required=True,
        choices=list(HOSTS),
        help="Host adapter (claude|grok)",
    )
    loc.add_argument(
        "--session-id",
        default=None,
        help="Session id/uuid; omit for newest under host bucket for --cwd",
    )
    loc.add_argument(
        "--cwd",
        required=True,
        help="Project directory (dash-encode for Claude; urlencode for Grok)",
    )
    loc.add_argument(
        "--sessions-dir",
        default=None,
        help="Override host sessions/projects root (tests / GROK_SESSIONS_DIR)",
    )
    loc.set_defaults(func=_cmd_locate)

    norm = sub.add_parser(
        "normalize",
        help="Normalize source path to Claude-shaped gate feed",
    )
    norm.add_argument(
        "--host",
        required=True,
        choices=list(HOSTS),
        help="Host adapter (claude|grok)",
    )
    norm.add_argument(
        "--source",
        required=True,
        help="Absolute (or expandable) source transcript path",
    )
    norm.add_argument("--cwd", required=True, help="Project directory")
    norm.add_argument(
        "--session-id",
        required=True,
        help="Session id (used for Grok turn_id / metadata)",
    )
    norm.add_argument(
        "--mode",
        default="scoring",
        choices=list(MODES),
        help="scoring (keep tool_result) or handoff (may skip tool_result)",
    )
    norm.set_defaults(func=_cmd_normalize)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
