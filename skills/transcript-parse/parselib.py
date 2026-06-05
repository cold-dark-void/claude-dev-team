"""
parselib.py — Shared parsing primitives for Claude Code session JSONL transcripts.

Consumed by skills/transcript-parse/assemble.py (SPEC-018 M1/M2) and any
future consumer that needs to read Claude session JSONL files.

Public API
----------
KNOWN_TOP_FIELDS      : frozenset[str] — canonical 6 top-level keys used for schema-drift detection
parse_line(raw)       : dict|None  — decode one JSONL line; return None on bad input
msg_text(content)     : str        — flatten content to text, KEEPING thinking blocks
is_edit_tool(name)    : bool       — True for Write/Edit/MultiEdit/NotebookEdit
edit_file_path(inp)   : str|None   — extract target path from a tool_use input dict
is_meta(d)            : bool       — True for system-injected isMeta user turns
is_sidechain(d)       : bool       — True for isSidechain-tagged messages
is_tool_result(obj)   : bool       — True when the line dict carries a tool_result block
schema_drift_warn(path): None      — stream first 50 lines of path; warn stderr if no known field seen
warn_schema_drift(path, lines_checked, seen_known): None  — lower-level helper (used by iter_lines)
iter_lines(path, n)   : Iterator[(int, dict)] — yield (line_no, dict) with auto schema-drift check
"""

import json
import sys
from typing import Any

# ---------------------------------------------------------------------------
# Schema constants
# ---------------------------------------------------------------------------

KNOWN_TOP_FIELDS: frozenset[str] = frozenset({
    "type",
    "uuid",
    "message",
    "parentUuid",
    "sessionId",
    "timestamp",
})

# ---------------------------------------------------------------------------
# Core parse
# ---------------------------------------------------------------------------


def parse_line(raw: str) -> "dict[str, Any] | None":
    """Decode one raw JSONL line.

    Returns a dict on success, None on empty / non-dict / parse error.
    Degrades gracefully: missing fields will simply be absent from the dict.
    """
    raw = raw.strip()
    if not raw:
        return None
    try:
        d = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(d, dict):
        return None
    return d


# ---------------------------------------------------------------------------
# Content flattening
# ---------------------------------------------------------------------------


def msg_text(content: Any) -> str:
    """Flatten a message's content field into a single plain-text string.

    CRITICAL difference from retro-gate/gate.sh:
      - gate.sh SKIPS thinking blocks (they are not user-visible for scoring).
      - This function KEEPS thinking blocks — downstream dead-ends extraction
        needs them to surface rejected hypotheses.

    Handles:
      - str content  → returned as-is
      - list content → iterates blocks:
          type="text"     → appended
          type="thinking" → appended (prefixed with a sentinel line)
          type="tool_use" → skipped (tool call, not text output)
          type="tool_result" → skipped (large payloads; pre-pass handles)
          anything else  → skipped
      - anything else → empty string
    """
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            text = block.get("text", "")
            if text:
                out.append(text)
        elif btype == "thinking":
            # Keep thinking blocks — required for dead-ends extraction (M4-b).
            # Real thinking blocks store their text under "thinking"; some
            # schema variants use "text" as a fallback. Accept both.
            thinking = block.get("thinking") or block.get("text") or ""
            if thinking:
                out.append(f"<thinking>\n{thinking}\n</thinking>")
        # tool_use, tool_result, and unknown block types are intentionally
        # skipped here; callers that need tool data walk content directly.
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Tool-use helpers
# ---------------------------------------------------------------------------

_EDIT_TOOLS: frozenset[str] = frozenset({"Edit", "Write", "MultiEdit", "NotebookEdit"})


def is_edit_tool(name: str) -> bool:
    """Return True if *name* is a file-editing tool."""
    return name in _EDIT_TOOLS


def edit_file_path(inp: Any) -> "str | None":
    """Extract the target file path from a tool_use input dict.

    Checks ``file_path``, ``notebook_path``, and ``path`` in that order.
    Returns None if none are present or if *inp* is not a dict.
    """
    if not isinstance(inp, dict):
        return None
    for key in ("file_path", "notebook_path", "path"):
        v = inp.get(key)
        if isinstance(v, str) and v:
            return v
    return None


# ---------------------------------------------------------------------------
# Message-type helpers
# ---------------------------------------------------------------------------


def is_meta(d: dict) -> bool:
    """True for system-injected user turns (slash command loads, skill context).

    These often contain words that match friction-signal regexes but are not
    genuine user utterances, so they should be skipped for signal detection.
    """
    return bool(d.get("isMeta"))


def is_sidechain(d: dict) -> bool:
    """True for messages tagged as belonging to a sidechain agent interaction.

    In real production transcripts (CDV-10 Task-1 spike) isSidechain was never
    True, so this is a defensive guard for future schema changes.
    """
    return bool(d.get("isSidechain"))


def is_tool_result(obj: Any) -> bool:
    """True when the line object carries at least one tool_result block.

    Accepts a full line dict (as yielded by ``iter_lines`` or ``parse_line``).
    Extracts ``obj["message"]["content"]`` and scans for blocks whose
    ``type == "tool_result"``.  Used to distinguish genuine human user turns
    from tool-result wrappers (the prepass strips these payloads).

    Returns False on any missing / unexpected structure.
    """
    if not isinstance(obj, dict):
        return False
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return False
    content = msg.get("content")
    if not isinstance(content, list):
        return False
    return any(
        isinstance(b, dict) and b.get("type") == "tool_result"
        for b in content
    )


# ---------------------------------------------------------------------------
# Schema-drift detection
# ---------------------------------------------------------------------------

_drift_warned: set[str] = set()


def warn_schema_drift(path: str, lines_checked: int, seen_known: bool) -> None:
    """Emit a one-time stderr warning if no known top-level fields were seen.

    Low-level helper used by ``iter_lines`` and ``schema_drift_warn``.
    Mirrors the guard in retro-gate/gate.sh.

    Parameters
    ----------
    path         : absolute path to the JSONL file (used as dedup key)
    lines_checked: how many lines were inspected before calling this
    seen_known   : True if at least one KNOWN_TOP_FIELDS key was encountered
    """
    if seen_known or path in _drift_warned:
        return
    if lines_checked == 0:
        return
    _drift_warned.add(path)
    sys.stderr.write(
        f"transcript-parse: WARNING — no known JSONL fields seen in first "
        f"{lines_checked} lines of {path}; possible schema drift.\n"
    )


def schema_drift_warn(path: str, n: int = 50) -> None:
    """Stream the first *n* lines of *path*; warn stderr if no known field seen.

    Documented public API consumed by Task 4/12 importers.  Thin wrapper
    around ``warn_schema_drift`` that handles its own I/O so callers do not
    need to manage ``lines_checked`` / ``seen_known`` bookkeeping.

    ``from parselib import schema_drift_warn`` MUST work.
    """
    seen_known = False
    lines_checked = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                if lines_checked >= n:
                    break
                lines_checked += 1
                d = parse_line(raw)
                if d is not None and KNOWN_TOP_FIELDS & set(d.keys()):
                    seen_known = True
                    break
    except OSError:
        return
    warn_schema_drift(path, lines_checked, seen_known)


# ---------------------------------------------------------------------------
# Convenience iterator
# ---------------------------------------------------------------------------


def iter_lines(path: str, schema_drift_check_n: int = 50):
    """Yield (line_no, dict) for every valid JSONL line in *path*.

    Also handles schema-drift detection automatically after the first
    *schema_drift_check_n* lines.  Uses UTF-8 with replacement for robustness
    on files containing stray bytes.

    Parameters
    ----------
    path                  : absolute path to the JSONL file
    schema_drift_check_n  : how many lines to scan before warning on drift
    """
    seen_known = False
    line_no = -1
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line_no, raw in enumerate(fh):
            d = parse_line(raw)
            if d is None:
                if line_no == schema_drift_check_n:
                    warn_schema_drift(path, line_no, seen_known)
                continue
            if not seen_known and line_no < schema_drift_check_n:
                if KNOWN_TOP_FIELDS & set(d.keys()):
                    seen_known = True
            if line_no == schema_drift_check_n:
                warn_schema_drift(path, line_no, seen_known)
            yield line_no, d
    # If file was shorter than schema_drift_check_n lines, still warn.
    warn_schema_drift(path, min(schema_drift_check_n, line_no + 1), seen_known)
