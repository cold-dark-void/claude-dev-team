"""STM packet quality helpers — LLM-free invent-guard (SPEC-018 M3d/M11b, CDT-201).

Stdlib only. MUST NOT import assemble. Assemble and tests import this module.
"""

from __future__ import annotations

import json
import os
import re

SUMMARY_MAX = 800
WHERE_WE_ARE_HEADING = "### Where we are"
CITE_RE = r"\{[^{}\s]+\}"  # {through_line:tl-e1} | {tl-e1} | {prior:stem:raw#2}
SENTENCE_SPLIT_RE = r"(?<=[.!?])\s+"

_CITE = re.compile(CITE_RE)
_SENTENCE_SPLIT = re.compile(SENTENCE_SPLIT_RE)
_WS = re.compile(r"\s+")
_SPACE_BEFORE_PUNCT = re.compile(r" ([.,;:!?])")

_STATE_BUCKETS = (
    "product_surfaces_primary",
    "product_surfaces_unfinished",
    "ship_gaps",
    "decisions",
    "hypotheses",
    "opens",
)

_THROUGH_LINE_NAME = "through_line.json"
_STATE_NAME = "state.json"


def _load_json(path: str):
    """Return decoded JSON, or None on missing/unreadable (fail closed)."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError, TypeError):
        return None


def _summary_from_obj(obj) -> str | None:
    """obj['summary'] if non-empty str else None. Chunk-summarizer ignored."""
    if not isinstance(obj, dict):
        return None
    # Chunk-summarizer JSON: different `summary` field (chunk markdown).
    if "chunk_index" in obj and not isinstance(obj.get("events"), list):
        return None
    s = obj.get("summary")
    if isinstance(s, str) and s.strip():
        return s
    return None


def load_wrapper_summary(events_path: str) -> str | None:
    """File: obj['summary'] if str else None.
    Dir: through_line.json wins if both set; else state.json; else None.
    Missing/null/empty/non-str → None. Chunk-summarizer files ignored."""
    if not events_path:
        return None
    if os.path.isdir(events_path):
        tl = _summary_from_obj(
            _load_json(os.path.join(events_path, _THROUGH_LINE_NAME))
        )
        if tl is not None:
            return tl
        return _summary_from_obj(_load_json(os.path.join(events_path, _STATE_NAME)))
    if os.path.isfile(events_path):
        return _summary_from_obj(_load_json(events_path))
    return None


def known_cite_ids(events: list) -> set:
    """Each event assembled `id` plus `_raw_id` when present."""
    ids = set()
    for ev in events or []:
        if not isinstance(ev, dict):
            continue
        for key in ("id", "_raw_id"):
            v = ev.get(key)
            if v is None:
                continue
            s = str(v).strip()
            if s:
                ids.add(s)
    return ids


def _strip_cite_tokens(text: str) -> str:
    """Remove `{id}` tokens and collapse leftover whitespace."""
    prose = _CITE.sub("", text)
    prose = _WS.sub(" ", prose)
    prose = _SPACE_BEFORE_PUNCT.sub(r"\1", prose)
    return prose.strip()


def validate_summary(text, events) -> tuple:
    """(ok: bool, prose_or_None: str|None, reason: str).
    Fail closed (ok=False, prose=None): non-str; len(text.strip())>SUMMARY_MAX;
    any {token} not in known_cite_ids; any sentence (split SENTENCE_SPLIT_RE,
    trailing fragment counts, skip empty/whitespace) with zero valid tokens.
    Success: prose = text with {id} tokens removed (collapse leftover whitespace).
    LLM-free. MUST NOT invent."""
    if not isinstance(text, str):
        return False, None, "non-str"
    stripped = text.strip()
    if not stripped:
        return False, None, "empty"
    if len(stripped) > SUMMARY_MAX:
        return False, None, "too long"
    known = known_cite_ids(events)
    for m in _CITE.finditer(stripped):
        tok = m.group(0)[1:-1]
        if tok not in known:
            return False, None, "unknown token"
    for sent in _SENTENCE_SPLIT.split(stripped):
        if not sent.strip():
            continue
        has_valid = False
        for m in _CITE.finditer(sent):
            if m.group(0)[1:-1] in known:
                has_valid = True
                break
        if not has_valid:
            return False, None, "uncited sentence"
    return True, _strip_cite_tokens(stripped), "ok"


def occupied_ids(state: dict) -> set:
    """Union of `id` from state['product_surfaces_primary'],
    product_surfaces_unfinished, ship_gaps, decisions, hypotheses, opens."""
    ids = set()
    if not isinstance(state, dict):
        return ids
    for key in _STATE_BUCKETS:
        bucket = state.get(key)
        if not isinstance(bucket, list):
            continue
        for ev in bucket:
            if not isinstance(ev, dict):
                continue
            eid = ev.get("id")
            if eid is None or str(eid).strip() == "":
                continue
            ids.add(eid)
    return ids


def remainder_events(events, occupied: set) -> list:
    """Stable order; drop events whose `id` is in occupied."""
    occ = occupied if isinstance(occupied, set) else set(occupied or [])
    out = []
    for ev in events or []:
        if not isinstance(ev, dict):
            continue
        if ev.get("id") in occ:
            continue
        out.append(ev)
    return out


# self-check (not a runner): validate_summary("Hi {e1}.", [{"id": "e1"}])
#   → (True, "Hi.", "ok"); unknown/uncited/non-str/>800 → (False, None, reason)
