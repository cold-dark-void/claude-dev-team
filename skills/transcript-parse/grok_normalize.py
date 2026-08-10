#!/usr/bin/env python3
"""Grok chat_history.jsonl → Claude-shaped JSONL (CDT-156 T3 / CDT-92 extract).

Scoring mode (default): preserve tool_result as user-wrapped blocks; map
write→Write, search_replace→Edit; is_error from exit:N with N≠0.

Handoff mode: skip tool_result (CDT-92 spine parity).

  python3 grok_normalize.py \\
    --in <chat_history.jsonl> \\
    --out <claude-shaped.jsonl> \\
    --cwd <abs-project-dir> \\
    --session-id <id> \\
    [--mode scoring|handoff]

Importable:
  normalize_to_file(source_path, *, cwd, session_id, mode="scoring", out_path=None) -> abs_path
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from typing import Any, Dict, List, Optional, TextIO, Tuple

MODES = ("scoring", "handoff")

# Always skip (not gate-relevant / not user-visible spine).
SKIP_ALWAYS = frozenset({"system", "reasoning", "backend_tool_call"})

# Handoff also skips tool_result (CDT-92).
SKIP_HANDOFF = frozenset({"tool_result"})

# uuid charset for leafrule / filesystem consumers
_UUID_SAFE = re.compile(r"[^A-Za-z0-9._-]+")

# Grok shell results use "exit: 0" / "exit:1" — allow optional whitespace.
_EXIT_RE = re.compile(r"exit:\s*(\d+)")

# S3 edit-tool name map (scoring only).
TOOL_NAME_MAP = {
    "write": "Write",
    "search_replace": "Edit",
}


def _warn(msg: str) -> None:
    sys.stderr.write(f"grok_normalize: {msg}\n")


def sanitize_session_id(session_id: str) -> str:
    s = (session_id or "").strip()
    if not s:
        raise ValueError("session_id is required and must be non-empty")
    safe = _UUID_SAFE.sub("-", s).strip("-._")
    if not safe:
        raise ValueError(
            f"session_id yields empty uuid prefix after sanitize: {session_id!r}"
        )
    return safe


def make_uuid(session_safe: str, line_no: int) -> str:
    """Deterministic stable uuid: <session>-L<n> (1-based emit index)."""
    return f"{session_safe}-L{line_no}"


def content_to_text_blocks(content: Any) -> List[Dict[str, str]]:
    """Normalize Grok content (str | list | other) to Claude text blocks."""
    blocks: List[Dict[str, str]] = []
    if isinstance(content, str):
        if content:
            blocks.append({"type": "text", "text": content})
        return blocks
    if isinstance(content, list):
        for item in content:
            if isinstance(item, str) and item:
                blocks.append({"type": "text", "text": item})
                continue
            if not isinstance(item, dict):
                continue
            btype = item.get("type")
            if btype == "text" or btype is None:
                text = item.get("text")
                if isinstance(text, str) and text:
                    blocks.append({"type": "text", "text": text})
        return blocks
    return blocks


def parse_tool_arguments(raw: Any) -> Dict[str, Any]:
    """Grok tool_calls[].arguments is typically a JSON string; accept dict too."""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict):
                return obj
        except (json.JSONDecodeError, ValueError):
            return {"_raw": raw}
    return {}


def map_tool_name(name: str, *, mode: str) -> str:
    if mode != "scoring":
        return name
    return TOOL_NAME_MAP.get(name, name)


def tool_use_blocks(tool_calls: Any, *, mode: str) -> List[Dict[str, Any]]:
    """Map Grok tool_calls → Claude tool_use content blocks."""
    out: List[Dict[str, Any]] = []
    if not isinstance(tool_calls, list):
        return out
    for i, tc in enumerate(tool_calls):
        if not isinstance(tc, dict):
            continue
        name = tc.get("name") or "unknown"
        if not isinstance(name, str):
            name = "unknown"
        name = map_tool_name(name, mode=mode)
        tid = tc.get("id") or f"toolu-adapt-{i}"
        if not isinstance(tid, str):
            tid = f"toolu-adapt-{i}"
        out.append(
            {
                "type": "tool_use",
                "id": tid,
                "name": name,
                "input": parse_tool_arguments(tc.get("arguments")),
            }
        )
    return out


def tool_result_body(content: Any) -> Any:
    """Preserve string bodies; stringify structured content for gate flatten."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, (dict, list)):
        return json.dumps(content, ensure_ascii=False)
    return str(content)


def is_error_from_content(content: Any) -> bool:
    """True iff body matches exit:N with N ≠ 0 (OQ5 / SPEC-012 Grok S2)."""
    if isinstance(content, str):
        text = content
    elif content is None:
        text = ""
    elif isinstance(content, (dict, list)):
        text = json.dumps(content, ensure_ascii=False)
    else:
        text = str(content)
    m = _EXIT_RE.search(text)
    if not m:
        return False
    try:
        return int(m.group(1)) != 0
    except ValueError:
        return False


def synthetic_timestamp(emit_index: int) -> str:
    """Order-preserving ISO-8601 when Grok lines lack timestamps.

    Base 2026-01-01T00:00:00Z + (emit_index-1) seconds so lexicographic sort
    matches emit order (matches transcript-parse (timestamp, line) sort).
    """
    sec = max(0, emit_index - 1)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    day = 1 + h // 24
    h = h % 24
    return f"2026-01-{day:02d}T{h:02d}:{m:02d}:{s:02d}Z"


def _base_line(
    *,
    typ: str,
    session_safe: str,
    session_id: str,
    cwd: str,
    emit_index: int,
    ts_raw: Any,
    content_blocks: List[Dict[str, Any]],
) -> Dict[str, Any]:
    ts = ts_raw if isinstance(ts_raw, str) and ts_raw else synthetic_timestamp(emit_index)
    return {
        "type": typ,
        "uuid": make_uuid(session_safe, emit_index),
        "sessionId": session_id,
        "cwd": cwd,
        "timestamp": ts,
        "message": {
            "role": typ,
            "content": content_blocks,
        },
    }


def convert_line(
    obj: Dict[str, Any],
    *,
    session_safe: str,
    session_id: str,
    cwd: str,
    emit_index: int,
    mode: str,
) -> Optional[Dict[str, Any]]:
    """Convert one Grok line to Claude shape, or None to skip."""
    typ = obj.get("type")
    if not isinstance(typ, str):
        return None
    if typ in SKIP_ALWAYS:
        return None
    if mode == "handoff" and typ in SKIP_HANDOFF:
        return None

    if typ == "tool_result":
        # scoring only (handoff returned above)
        tool_use_id = obj.get("tool_call_id") or obj.get("tool_use_id") or ""
        if not isinstance(tool_use_id, str):
            tool_use_id = str(tool_use_id) if tool_use_id is not None else ""
        body = tool_result_body(obj.get("content"))
        block: Dict[str, Any] = {
            "type": "tool_result",
            "tool_use_id": tool_use_id or f"toolu-adapt-{emit_index}",
            "is_error": is_error_from_content(obj.get("content")),
            "content": body,
        }
        return _base_line(
            typ="user",
            session_safe=session_safe,
            session_id=session_id,
            cwd=cwd,
            emit_index=emit_index,
            ts_raw=obj.get("timestamp"),
            content_blocks=[block],
        )

    if typ not in ("user", "assistant"):
        return None

    content_blocks: List[Dict[str, Any]] = content_to_text_blocks(obj.get("content"))
    if typ == "assistant":
        content_blocks = content_blocks + tool_use_blocks(
            obj.get("tool_calls"), mode=mode
        )

    # Drop empty assistant/user with nothing to say (no text, no tools)
    if not content_blocks:
        return None

    out = _base_line(
        typ=typ,
        session_safe=session_safe,
        session_id=session_id,
        cwd=cwd,
        emit_index=emit_index,
        ts_raw=obj.get("timestamp"),
        content_blocks=content_blocks,
    )
    if typ == "user" and obj.get("synthetic_reason"):
        out["isMeta"] = True
    return out


def convert_stream(
    infile: TextIO,
    *,
    session_safe: str,
    session_id: str,
    cwd: str,
    mode: str = "scoring",
) -> Tuple[List[Dict[str, Any]], int, int, int]:
    """Return (emitted, n_user, n_assistant, n_tool_result).

    n_user counts type=user lines (including tool_result wrappers in scoring).
    n_tool_result counts scoring tool_result emissions only.
    """
    m = (mode or "scoring").strip().lower()
    if m not in MODES:
        raise ValueError(f"unknown mode {mode!r}; expected one of {', '.join(MODES)}")

    emitted: List[Dict[str, Any]] = []
    n_user = 0
    n_assistant = 0
    n_tool_result = 0
    for raw in infile:
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            # Mid-write / truncated last line — drop (M14-style fail-open)
            continue
        if not isinstance(obj, dict):
            continue
        emit_index = len(emitted) + 1
        claude = convert_line(
            obj,
            session_safe=session_safe,
            session_id=session_id,
            cwd=cwd,
            emit_index=emit_index,
            mode=m,
        )
        if claude is None:
            continue
        emitted.append(claude)
        if claude["type"] == "user":
            n_user += 1
            # tool_result wrappers are user lines with a tool_result block
            content = claude.get("message", {}).get("content")
            if (
                isinstance(content, list)
                and content
                and isinstance(content[0], dict)
                and content[0].get("type") == "tool_result"
            ):
                n_tool_result += 1
        elif claude["type"] == "assistant":
            n_assistant += 1
    return emitted, n_user, n_assistant, n_tool_result


def write_jsonl(path: str, rows: List[Dict[str, Any]]) -> None:
    with open(path, "w", encoding="utf-8") as out:
        for obj in rows:
            out.write(
                json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
            )


def normalize_to_file(
    source_path: str,
    *,
    cwd: str,
    session_id: str,
    mode: str = "scoring",
    out_path: Optional[str] = None,
) -> str:
    """Normalize Grok chat_history to Claude-shaped JSONL; return absolute path.

    When out_path is None, write under TMPDIR (or system temp) with a unique name.
    """
    m = (mode or "scoring").strip().lower()
    if m not in MODES:
        raise ValueError(f"unknown mode {mode!r}; expected one of {', '.join(MODES)}")

    cwd_s = (cwd or "").strip()
    if not cwd_s:
        raise ValueError("cwd is required and must be non-empty")

    sid = (session_id or "").strip()
    session_safe = sanitize_session_id(sid)

    src = os.path.abspath(os.path.expanduser(source_path))
    if not src:
        raise ValueError("source_path is required")

    try:
        with open(src, "r", encoding="utf-8", errors="replace") as fh:
            emitted, n_user, n_assistant, _n_tr = convert_stream(
                fh,
                session_safe=session_safe,
                session_id=sid,
                cwd=cwd_s,
                mode=m,
            )
    except OSError as e:
        raise ValueError(f"cannot read source {src}: {e}") from e

    # Handoff parity: require ≥1 user and ≥1 assistant after filter (CDT-92).
    if m == "handoff" and (n_user < 1 or n_assistant < 1):
        raise ValueError(
            f"need ≥1 user and ≥1 assistant after filter "
            f"(got user={n_user} assistant={n_assistant})"
        )

    if out_path:
        dest = os.path.abspath(os.path.expanduser(out_path))
    else:
        tmp_dir = os.environ.get("TMPDIR") or tempfile.gettempdir()
        try:
            os.makedirs(tmp_dir, exist_ok=True)
        except OSError:
            pass
        fd, dest = tempfile.mkstemp(
            prefix=f"grok-norm-{session_safe}-",
            suffix=".jsonl",
            dir=tmp_dir,
        )
        os.close(fd)

    try:
        write_jsonl(dest, emitted)
    except OSError as e:
        raise ValueError(f"cannot write output {dest}: {e}") from e

    return dest


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="grok_normalize.py",
        description="Normalize Grok chat_history.jsonl to Claude-shaped JSONL.",
    )
    p.add_argument("--in", dest="infile", required=True, help="Grok chat_history.jsonl")
    p.add_argument(
        "--out",
        dest="outfile",
        default=None,
        help="Output path (default: unique file under TMPDIR)",
    )
    p.add_argument("--cwd", required=True, help="Project cwd injected on every line")
    p.add_argument(
        "--session-id",
        dest="session_id",
        required=True,
        help="Session id used for uuid/sessionId fields",
    )
    p.add_argument(
        "--mode",
        default="scoring",
        choices=list(MODES),
        help="scoring (keep tool_result + name map) or handoff (skip tool_result)",
    )
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    try:
        dest = normalize_to_file(
            args.infile,
            cwd=args.cwd,
            session_id=args.session_id,
            mode=args.mode,
            out_path=args.outfile,
        )
    except ValueError as e:
        _warn(str(e))
        return 1
    sys.stdout.write(dest + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
