#!/usr/bin/env python3
"""Grok chat_history.jsonl → Claude-shaped JSONL adapter (CDT-92 / SPEC-018 M10b).

Thin wrapper around skills/transcript-parse/grok_normalize.py with mode=handoff
(skip tool_result; CDT-156 T8). Preserves the CDT-92 CLI + exit contract used by
discover-warm and grok-to-claude-jsonl-test.sh.

  python3 grok-to-claude-jsonl.py \\
    --in <chat_history.jsonl> \\
    --out <claude-shaped.jsonl> \\
    --cwd <abs-project-dir> \\
    --session-id <id>

Line mapping (handoff mode)
---------------------------
  system / reasoning / backend_tool_call / tool_result → skip
  user         → type=user; isMeta when synthetic_reason
  assistant    → type=assistant; text + optional tool_use (names unmapped)

Each emitted line gets uuid, cwd, sessionId, timestamp (synthetic if missing).
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import List, Optional

# Sibling skill module (install-aware: both ship under skills/).
_HERE = os.path.dirname(os.path.abspath(__file__))
_TP = os.path.abspath(os.path.join(_HERE, "..", "transcript-parse"))
if _TP not in sys.path:
    sys.path.insert(0, _TP)

import grok_normalize  # noqa: E402  — sibling skill path


def _warn(msg: str) -> None:
    sys.stderr.write(f"grok-to-claude-jsonl: {msg}\n")


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


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    cwd = (args.cwd or "").strip()
    if not cwd:
        _warn("--cwd is required and must be non-empty")
        return 1
    if not cwd.startswith("/"):
        _warn(f"--cwd must be an absolute path, got: {cwd!r}")
        return 1

    session_id = (args.session_id or "").strip()
    if not session_id:
        _warn("--session-id is required and must be non-empty")
        return 1

    infile_path = args.infile
    outfile_path = args.outfile
    if not infile_path:
        _warn("--in is required")
        return 1
    if not outfile_path:
        _warn("--out is required")
        return 1

    try:
        grok_normalize.normalize_to_file(
            infile_path,
            cwd=cwd,
            session_id=session_id,
            mode="handoff",
            out_path=outfile_path,
        )
    except ValueError as e:
        _warn(str(e))
        return 1

    # No stdout path print — discover-warm uses --out; tests assert on file only.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
