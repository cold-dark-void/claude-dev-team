#!/usr/bin/env python3
"""Grok chat_history.jsonl → Claude-shaped JSONL adapter (CDT-92 / SPEC-018 M10b).

Pure stdlib. No network. Used by discover-warm before prepass prepare.

  python3 grok-to-claude-jsonl.py \\
    --in <chat_history.jsonl> \\
    --out <claude-shaped.jsonl> \\
    --cwd <abs-project-dir> \\
    --session-id <id>

Line mapping
------------
  system       → skip
  reasoning    → skip
  tool_result  → skip
  user         → type=user, message.role=user; isMeta when synthetic_reason
  assistant    → type=assistant, message.role=assistant; text + optional tool_use

Each emitted line gets:
  - uuid        session-id-L<n> (charset-safe, unique, deterministic)
  - cwd         from --cwd (required for resolve-root / AC7)
  - sessionId   from --session-id
  - timestamp   preserved if present; else order-preserving synthetic ISO
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any, Dict, List, Optional, TextIO, Tuple

SKIP_TYPES = frozenset({"system", "reasoning", "tool_result"})
EMIT_TYPES = frozenset({"user", "assistant"})

# uuid must be charset-safe for leafrule / filesystem consumers
_UUID_SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def _warn(msg: str) -> None:
    sys.stderr.write(f"grok-to-claude-jsonl: {msg}\n")


def _die(msg: str, code: int = 1) -> None:
    _warn(msg)
    raise SystemExit(code)


def sanitize_session_id(session_id: str) -> str:
    s = (session_id or "").strip()
    if not s:
        _die("--session-id is required and must be non-empty")
    safe = _UUID_SAFE.sub("-", s).strip("-._")
    if not safe:
        _die(f"--session-id yields empty uuid prefix after sanitize: {session_id!r}")
    return safe


def make_uuid(session_safe: str, line_no: int) -> str:
    """Deterministic stable uuid: <session>-L<n> (1-based emit index)."""
    return f"{session_safe}-L{line_no}"


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="grok-to-claude-jsonl.py",
        description="Normalize Grok chat_history.jsonl to Claude-shaped JSONL.",
    )
    p.add_argument("--in", dest="infile", required=True, help="Grok chat_history.jsonl path")
    p.add_argument("--out", dest="outfile", required=True, help="Claude-shaped JSONL output path")
    p.add_argument("--cwd", required=True, help="Absolute project cwd injected on every line (AC7)")
    p.add_argument(
        "--session-id",
        dest="session_id",
        required=True,
        help="Session id used for uuid/sessionId fields",
    )
    return p.parse_args(argv)


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
            # ignore non-text blocks in user content
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


def tool_use_blocks(tool_calls: Any) -> List[Dict[str, Any]]:
    """Map Grok tool_calls → Claude tool_use content blocks (name+input only)."""
    out: List[Dict[str, Any]] = []
    if not isinstance(tool_calls, list):
        return out
    for i, tc in enumerate(tool_calls):
        if not isinstance(tc, dict):
            continue
        name = tc.get("name") or "unknown"
        if not isinstance(name, str):
            name = "unknown"
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


def synthetic_timestamp(emit_index: int) -> str:
    """Order-preserving ISO-8601 when Grok lines lack timestamps.

    Base 2026-01-01T00:00:00Z + (emit_index-1) seconds so lexicographic sort
    matches emit order (matches transcript-parse (timestamp, line) sort).
    """
    # Keep pure stdlib; fixed epoch offset is fine for synthetic fixtures.
    sec = max(0, emit_index - 1)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    # Cap day rollover simply via total seconds into day-ish string padding
    day = 1 + h // 24
    h = h % 24
    return f"2026-01-{day:02d}T{h:02d}:{m:02d}:{s:02d}Z"


def convert_line(
    obj: Dict[str, Any],
    *,
    session_safe: str,
    session_id: str,
    cwd: str,
    emit_index: int,
) -> Optional[Dict[str, Any]]:
    """Convert one Grok line to Claude shape, or None to skip."""
    typ = obj.get("type")
    if not isinstance(typ, str) or typ in SKIP_TYPES:
        return None
    if typ not in EMIT_TYPES:
        return None

    content_blocks: List[Dict[str, Any]] = content_to_text_blocks(obj.get("content"))
    if typ == "assistant":
        content_blocks = content_blocks + tool_use_blocks(obj.get("tool_calls"))

    # Drop empty assistant/user with nothing to say (no text, no tools)
    if not content_blocks:
        return None

    ts = obj.get("timestamp")
    if not isinstance(ts, str) or not ts:
        ts = synthetic_timestamp(emit_index)

    out: Dict[str, Any] = {
        "type": typ,
        "uuid": make_uuid(session_safe, emit_index),
        "sessionId": session_id,
        "cwd": cwd,
        "timestamp": ts,
        "message": {
            "role": typ,  # user | assistant
            "content": content_blocks,
        },
    }
    if typ == "user" and obj.get("synthetic_reason"):
        out["isMeta"] = True
    return out


def convert_stream(
    infile: TextIO,
    *,
    session_safe: str,
    session_id: str,
    cwd: str,
) -> Tuple[List[Dict[str, Any]], int, int]:
    """Return (emitted, n_user, n_assistant). Drops bad/truncated JSON lines."""
    emitted: List[Dict[str, Any]] = []
    n_user = 0
    n_assistant = 0
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
        )
        if claude is None:
            continue
        emitted.append(claude)
        if claude["type"] == "user":
            n_user += 1
        elif claude["type"] == "assistant":
            n_assistant += 1
    return emitted, n_user, n_assistant


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    cwd = (args.cwd or "").strip()
    if not cwd:
        _die("--cwd is required and must be non-empty")
    if not cwd.startswith("/"):
        _die(f"--cwd must be an absolute path, got: {cwd!r}")

    session_id = (args.session_id or "").strip()
    session_safe = sanitize_session_id(session_id)

    infile_path = args.infile
    outfile_path = args.outfile
    if not infile_path:
        _die("--in is required")
    if not outfile_path:
        _die("--out is required")

    try:
        with open(infile_path, "r", errors="replace") as fh:
            emitted, n_user, n_assistant = convert_stream(
                fh,
                session_safe=session_safe,
                session_id=session_id,
                cwd=cwd,
            )
    except OSError as e:
        _die(f"cannot read --in {infile_path}: {e}")

    if n_user < 1 or n_assistant < 1:
        _die(
            f"need ≥1 user and ≥1 assistant after filter "
            f"(got user={n_user} assistant={n_assistant})"
        )

    try:
        with open(outfile_path, "w") as out:
            for obj in emitted:
                out.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError as e:
        _die(f"cannot write --out {outfile_path}: {e}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
