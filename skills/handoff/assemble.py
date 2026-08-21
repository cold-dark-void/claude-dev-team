#!/usr/bin/env python3
"""STM packet assemble — LLM-free event → markdown (SPEC-018 M3c/M3d, CDT-79).

Pipeline (deterministic, stdlib only):

  events JSON (+ optional annotations + pre-captured git blob)
        │
        ▼
  validate · drop invalid · dedup(kind + normalize(text))
        │
        ▼
  order by (order | timestamp | input index)
        │
        ▼
  State now (mechanical tail selection)
    · optional ### Where we are (wrapper summary, invent-guard)
    · Product surfaces (primary UX + unfinished / do-not-treat-as-product)
    · Open ship gaps
    · latest decisions (soft cap DECISION_CAP)
    · surviving (unkilled) hypotheses
    · untagged opens
  Through-line (remainder of State now occupancy; group by workstream when remainder >1)
  appendix (kill catalog / facts leftover after Through-line, git)
        │
        ▼
  markdown: ## State now → ## Through-line → ## appendix

State now is **not** an LLM essay: selection is pure rules over the ordered
event log. Annotation may only attach labels/rank to existing event_ids;
unknown ids are dropped (invent-guard).

Importable API
--------------
  EVENT_KINDS, QUOTE_MAX, normalize_text, validate_event, load_events,
  load_prior_events, load_annotations, dedup_events, order_events,
  merge_events, events_for_cache, load_merged_events, load_merged_for_summary,
  select_state_now, state_now_contract_ok, ensure_state_now_contract,
  assemble_packet, AssembleError, main

CLI
---
  python3 skills/handoff/assemble.py \\
    --events <file|dir> --git <blob> [--annotations ...] [--spine-tokens N] \\
    [--session-uuid U] [--leaf-uuid L] [--slug S] [--supersedes prior] \\
    [--mode cold|warm] [--light] [--prior-events PATH] [--events-out PATH] \\
    [--out packet.md]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from collections import OrderedDict

from packet_dedup import (
    collapse_events,
    event_body,
    exact_dedup as dedup_events,
    kill_catalog_placeholder,
    normalize_text,
)
from packet_quality import (
    WHERE_WE_ARE_HEADING,
    load_wrapper_summary,
    occupied_ids,
    remainder_events,
    validate_summary,
)

# ---------------------------------------------------------------------------
# Event schema constants (shared with miners / tests)
# ---------------------------------------------------------------------------

# CDT-91 M10c — exact honesty line for light warm preset (MUST NOT say UNMINED)
LIGHT_HONESTY = "light preset: reduced-cost mine, no annotation; not AC-16-scored."

EVENT_KINDS = frozenset(
    {
        "hypothesis",
        "killed",
        "ruling",
        "decision",
        "fact",
        "open",
        "conflict",
    }
)

# Miner role subsets (documentation + optional call-site checks)
MINER1_KINDS = frozenset({"hypothesis", "killed", "ruling", "decision", "fact"})
MINER2_KINDS = frozenset({"open", "conflict"})

# CDT-198 — optional miner tags (not new kinds; ceiling stays 7)
EVENT_FACETS = frozenset({"product_surface", "ship_gap"})
SURFACE_CLASSES = frozenset({"primary", "unfinished", "not_product"})
REQUIRED_STATE_NOW_HEADINGS = ("### Product surfaces", "### Open ship gaps")

REQUIRED_EVENT_FIELDS = frozenset({"id", "kind"})  # plus text-or-quote
QUOTE_MAX = 200
DECISION_CAP = 5  # soft advisory cap for State now decisions
DEFAULT_WORKSTREAM = "default"
SECTION_HEADERS = ("## State now", "## Through-line", "## appendix")


class AssembleError(ValueError):
    """Packet failed a mechanical assemble contract (not an LLM essay)."""


# ---------------------------------------------------------------------------
# Normalize / validate
# ---------------------------------------------------------------------------


def truncate_quote(s, max_len=QUOTE_MAX):
    """Cap inline load-bearing text at max_len (AC-7 / M6)."""
    if s is None:
        return ""
    s = str(s)
    if len(s) <= max_len:
        return s
    if max_len <= 1:
        return s[:max_len]
    return s[: max_len - 1] + "…"


def validate_event(raw):
    """Return a cleaned event dict, or None if invalid (fail soft — never invent).

    Required: id, kind ∈ EVENT_KINDS, non-empty text or quote.
    workstream defaults to "default". order/timestamp/pointers/how_verified optional.
    """
    if not isinstance(raw, dict):
        return None
    eid = raw.get("id")
    if eid is None or str(eid).strip() == "":
        return None
    kind = raw.get("kind")
    if not isinstance(kind, str) or kind not in EVENT_KINDS:
        return None
    text = raw.get("text") if isinstance(raw.get("text"), str) else None
    quote = raw.get("quote") if isinstance(raw.get("quote"), str) else None
    if not ((text and text.strip()) or (quote and quote.strip())):
        return None

    ws = raw.get("workstream")
    if not isinstance(ws, str) or not ws.strip():
        ws = DEFAULT_WORKSTREAM
    else:
        ws = ws.strip()

    out = {
        "id": str(eid).strip(),
        "kind": kind,
        "workstream": ws,
    }
    if text is not None and text.strip():
        out["text"] = text  # keep original (incl. over-cap); render truncates
    if quote is not None and quote.strip():
        out["quote"] = quote

    if "order" in raw and raw["order"] is not None:
        try:
            out["order"] = int(raw["order"])
        except (TypeError, ValueError):
            try:
                out["order"] = float(raw["order"])
            except (TypeError, ValueError):
                pass

    ts = raw.get("timestamp")
    if isinstance(ts, str) and ts.strip():
        out["timestamp"] = ts.strip()

    ptrs = raw.get("pointers")
    if isinstance(ptrs, list):
        cleaned = []
        for p in ptrs:
            if isinstance(p, dict) and (p.get("ref") or p.get("type")):
                cleaned.append(p)
            elif isinstance(p, str) and p.strip():
                cleaned.append(p.strip())
        if cleaned:
            out["pointers"] = cleaned

    hv = raw.get("how_verified")
    if isinstance(hv, str) and hv.strip():
        out["how_verified"] = hv.strip()

    facet = raw.get("facet")
    if isinstance(facet, str) and facet.strip() in EVENT_FACETS:
        out["facet"] = facet.strip()

    sc = raw.get("surface_class")
    if isinstance(sc, str) and sc.strip() in SURFACE_CLASSES:
        out["surface_class"] = sc.strip()

    return out


def validate_annotation(raw):
    """Return cleaned annotation or None. Schema: {event_id, labels[], rank?}."""
    if not isinstance(raw, dict):
        return None
    eid = raw.get("event_id")
    if eid is None or str(eid).strip() == "":
        return None
    labels = raw.get("labels")
    if labels is None:
        labels = []
    if not isinstance(labels, list):
        return None
    clean_labels = []
    for lab in labels:
        if isinstance(lab, str) and lab.strip():
            clean_labels.append(lab.strip())
    out = {"event_id": str(eid).strip(), "labels": clean_labels}
    if "rank" in raw and raw["rank"] is not None:
        try:
            out["rank"] = int(raw["rank"])
        except (TypeError, ValueError):
            try:
                out["rank"] = float(raw["rank"])
            except (TypeError, ValueError):
                pass
    return out


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------


def _extract_events_payload(obj):
    """Accept {events:[...]}, bare list, or single event object."""
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        if "events" in obj and isinstance(obj["events"], list):
            return obj["events"]
        # single event object
        if "kind" in obj or "id" in obj:
            return [obj]
    return []


def load_events(path):
    """Load events from a JSON file or a directory of *.json files.

    Returns list of validated events with ``_src_index`` for stable ordering.
    Each event ``id`` is namespaced as ``{stem}:{raw_id}`` where ``stem`` is
    the source basename without ``.json``; original miner id is kept as
    ``_raw_id`` for display hygiene. Invalid events are dropped (fail soft).

    Does **not** set ``_generation`` (cold path keeps default 0 for order
    identity). Merge callers tag delta events with ``_generation=1``.
    """
    paths = []
    if os.path.isdir(path):
        for name in sorted(os.listdir(path)):
            if name.endswith(".json"):
                paths.append(os.path.join(path, name))
    elif os.path.isfile(path):
        paths = [path]
    else:
        raise FileNotFoundError(f"events path not found: {path}")

    out = []
    i = 0
    for p in paths:
        stem = os.path.splitext(os.path.basename(p))[0]
        with open(p, "r", encoding="utf-8") as fh:
            try:
                obj = json.load(fh)
            except ValueError as e:
                sys.stderr.write(f"assemble: skip unreadable JSON {p}: {e}\n")
                continue
        for raw in _extract_events_payload(obj):
            ev = validate_event(raw)
            if ev is None:
                continue
            ev["_raw_id"] = ev["id"]
            ev["id"] = f"{stem}:{ev['id']}"
            ev["_src_index"] = i
            i += 1
            out.append(ev)
    return out


def _stem_map_from_prior_obj(obj):
    """Extract stem → [raw events] from cache JSON or bare stem map.

    Accepts:
      - cache wrapper ``{"events": {stem: [...]}, ...}``
      - bare stem map ``{stem: [...]}``
    Returns None if shape is unusable.
    """
    if not isinstance(obj, dict) or not obj:
        return None
    if "events" in obj:
        ev = obj["events"]
        if isinstance(ev, dict):
            return ev
        # list / null / missing usable map → no prior (soft)
        return None
    # bare stem map: all values lists (possibly empty)
    if all(isinstance(v, list) for v in obj.values()):
        return obj
    return None


def load_prior_events(path):
    """Load prior cumulative events from cache JSON or bare stem map.

    Each event id becomes ``prior:{stem}:{raw_id}`` with ``_raw_id`` preserved,
    ``_generation=0``, and sequential ``_src_index``. Soft-skips unreadable or
    unusable files (returns ``[]`` + stderr).
    """
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            obj = json.load(fh)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"assemble: prior events unreadable: {e}\n")
        return []

    stem_map = _stem_map_from_prior_obj(obj)
    if not stem_map:
        return []

    out = []
    i = 0
    seen_ids = set()
    for stem in sorted(stem_map.keys()):
        raws = stem_map[stem]
        if not isinstance(raws, list):
            continue
        stem_s = str(stem).strip() or "default"
        for raw in raws:
            ev = validate_event(raw)
            if ev is None:
                continue
            raw_id = ev["id"]
            # Defensive: never double-prefix prior: on multi-hop reloads
            if raw_id.startswith("prior:"):
                parts = raw_id.split(":", 2)
                if len(parts) == 3:
                    raw_id = parts[2]
            elif ":" in raw_id and raw_id.split(":", 1)[0] == stem_s:
                raw_id = raw_id.split(":", 1)[1]
            base_id = f"prior:{stem_s}:{raw_id}"
            final_id = base_id
            final_raw = raw_id
            if base_id in seen_ids:
                n = 2
                while f"{base_id}#{n}" in seen_ids:
                    n += 1
                final_id = f"{base_id}#{n}"
                final_raw = f"{raw_id}#{n}"
                sys.stderr.write(
                    f"assemble: prior id collision: {base_id} -> {final_id}\n"
                )
            seen_ids.add(final_id)
            ev["_raw_id"] = final_raw
            ev["id"] = final_id
            ev["_generation"] = 0
            ev["_src_index"] = i
            i += 1
            out.append(ev)
    return out


def _id_stem_raw(ev):
    """Parse stem + raw miner id from namespaced event (CDT-93 / CDT-88).

    ``prior:stem:raw`` → (stem, raw); ``stem:raw`` → (stem, raw).
    Prefers ``_raw_id`` when set for the raw half.
    """
    eid = str(ev.get("id") or "")
    raw_pref = ev.get("_raw_id")
    parts = eid.split(":")
    if parts and parts[0] == "prior" and len(parts) >= 3:
        stem = parts[1]
        raw = raw_pref if raw_pref is not None else ":".join(parts[2:])
        return stem, str(raw)
    if len(parts) >= 2:
        stem = parts[0]
        raw = raw_pref if raw_pref is not None else ":".join(parts[1:])
        return stem, str(raw)
    return "default", str(raw_pref if raw_pref is not None else eid)


def events_for_cache(events):
    """Build stem → [raw-id event dicts] for M8 cache ``events`` payload.

    Strips ``prior:`` / stem id prefixes, ``_generation``, ``_src_index``,
    ``_labels``, ``_rank``, ``_raw_id``. Emits validated public fields only.
    """
    by_stem = OrderedDict()
    for ev in events or []:
        if not isinstance(ev, dict):
            continue
        stem, raw_id = _id_stem_raw(ev)
        # Rebuild public fields with bare raw id
        public = {k: v for k, v in ev.items() if not str(k).startswith("_")}
        public["id"] = raw_id
        cleaned = validate_event(public)
        if cleaned is None:
            continue
        by_stem.setdefault(stem, []).append(cleaned)
    return dict(by_stem)


def merge_events(prior, delta):
    """Merge prior + delta: tag delta gen=1, concat → order → dedup → order.

    Dedup keeps first in ordered list → prior wins on body match (verbatim).
    When ``prior`` is empty, returns ordered+deduped ``delta`` without forcing
    ``_generation`` (cold path order identity).
    """
    prior = list(prior or [])
    delta = list(delta or [])
    if prior:
        for e in prior:
            if isinstance(e, dict):
                e.setdefault("_generation", 0)
        for e in delta:
            if isinstance(e, dict):
                e["_generation"] = 1
    combined = prior + delta
    ordered = order_events(combined)
    deduped = collapse_events(ordered, err=sys.stderr)
    return order_events(deduped)


def load_merged_events(events_path, prior=None):
    """Load miner events (+ optional prior) in the same id space as assemble.

    Parameters
    ----------
    events_path : str
        Miner events file or directory (``{stem}:{id}`` namespace).
    prior : str or None
        Path to cache JSON / stem map for ``load_prior_events``.
    """
    prior_evs = load_prior_events(prior) if prior else []
    delta = load_events(events_path)
    if prior_evs:
        return merge_events(prior_evs, delta)
    return delta


def load_merged_for_summary(events_path, prior_path=None):
    """Step 7 helper — same merge id space as assemble (alias)."""
    return load_merged_events(events_path, prior=prior_path)


def load_annotations(path):
    """Load annotations from JSON file. Returns list of cleaned annotations."""
    if not path:
        return []
    with open(path, "r", encoding="utf-8") as fh:
        obj = json.load(fh)
    if isinstance(obj, list):
        raws = obj
    elif isinstance(obj, dict) and isinstance(obj.get("annotations"), list):
        raws = obj["annotations"]
    else:
        raws = []
    out = []
    for r in raws:
        a = validate_annotation(r)
        if a is not None:
            out.append(a)
    return out


def load_git_blob(path):
    """Read pre-captured git state text (no live git). Empty string if missing."""
    if not path:
        return ""
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# Dedup + order
# ---------------------------------------------------------------------------


def _ts_sort_key(ts):
    if not ts:
        return ""
    return str(ts)


def order_events(events):
    """Stable sort: ``_generation`` (default 0) → order field → timestamp → input index.

    Generation primary keeps prior (gen 0) before delta (gen 1) even when
    miner ``order`` restarts at 1 each delta (CDT-88). Cold path leaves gen
    unset → all default 0 → byte-identical relative order.
    """

    def key(ev):
        gen = ev.get("_generation", 0)
        try:
            gen = int(gen)
        except (TypeError, ValueError):
            gen = 0
        if "order" in ev:
            return (gen, 0, ev["order"], ev.get("_src_index", 0))
        if "timestamp" in ev:
            return (gen, 1, _ts_sort_key(ev["timestamp"]), ev.get("_src_index", 0))
        return (gen, 2, ev.get("_src_index", 0), 0)

    return sorted(events, key=key)


# ---------------------------------------------------------------------------
# State now (mechanical)
# ---------------------------------------------------------------------------


def _killed_norms(events):
    """Normalized kill targets for State now filtering.

    Miners often set ``text`` = hypothesis name and ``quote`` = kill reason.
    ``event_body`` prefers quote for display, so we index **both** fields
    (plus the display body) so surviving-hyp selection still matches on name.
    """
    norms = set()
    for ev in events:
        if ev.get("kind") != "killed":
            continue
        for key in ("text", "quote"):
            val = ev.get(key)
            if isinstance(val, str) and val.strip():
                n = normalize_text(val)
                if n:
                    norms.add(n)
        n = normalize_text(event_body(ev))
        if n:
            norms.add(n)
    return norms


def select_state_now(events, decision_cap=DECISION_CAP):
    """Mechanical State now selection from ordered event log (AC-5 / M3d).

    Returns dict with keys decisions, hypotheses, opens,
    product_surfaces_primary, product_surfaces_unfinished, ship_gaps —
    each a list of events (chronological within bucket; decisions are the
    *latest* N). Surfaces/gaps are selected by miner ``facet`` tags, not
    by inventing names from free text. Opens exclude ``facet=ship_gap``;
    decisions/hypotheses exclude ``facet=product_surface``.
    """
    killed = _killed_norms(events)

    decisions = [
        e
        for e in events
        if e.get("kind") == "decision" and e.get("facet") != "product_surface"
    ]
    # latest decisions: take from tail
    if decision_cap is not None and decision_cap >= 0:
        decisions = decisions[-decision_cap:]

    hyps = []
    for e in events:
        if e.get("kind") != "hypothesis":
            continue
        if e.get("facet") == "product_surface":
            continue
        n = normalize_text(event_body(e))
        if n and n in killed:
            continue  # killed — exclude from State now
        hyps.append(e)

    opens = [
        e
        for e in events
        if e.get("kind") == "open"
        and e.get("facet") not in ("ship_gap", "product_surface")
    ]

    primary = []
    unfinished = []
    for e in events:
        if e.get("facet") != "product_surface":
            continue
        if e.get("surface_class") == "primary":
            primary.append(e)
        else:
            # unfinished | not_product | missing class → do-not-treat-as-product
            unfinished.append(e)

    ship_gaps = [e for e in events if e.get("facet") == "ship_gap"]

    return {
        "decisions": decisions,
        "hypotheses": hyps,
        "opens": opens,
        "product_surfaces_primary": primary,
        "product_surfaces_unfinished": unfinished,
        "ship_gaps": ship_gaps,
    }


def state_now_slice(packet_md):
    """Return the ``## State now`` block up to ``## Through-line`` (or EOF)."""
    if not packet_md:
        return ""
    i = packet_md.find("## State now")
    if i < 0:
        return ""
    j = packet_md.find("## Through-line")
    return packet_md[i:j] if j >= 0 else packet_md[i:]


def state_now_contract_ok(packet_md):
    """True iff both required subsections appear inside State now (CDT-198).

    Appendix-only headings do not count. Missing State now / Through-line
    markers fail closed.
    """
    sn = state_now_slice(packet_md)
    if not sn:
        return False
    return all(h in sn for h in REQUIRED_STATE_NOW_HEADINGS)


def ensure_state_now_contract(packet_md):
    """Raise AssembleError if State now lacks required subsections."""
    if not state_now_contract_ok(packet_md):
        raise AssembleError(
            "assemble: State now missing required Product surfaces or Open ship gaps"
        )
    return packet_md


# ---------------------------------------------------------------------------
# Annotation apply (invent-guard)
# ---------------------------------------------------------------------------


def apply_annotations(events, annotations):
    """Attach labels/rank onto events by id. Drop unknown event_ids.

    Returns (events_with_meta, applied_count, dropped_count).
    Does not invent events or free evidence fields.
    """
    by_id = {e["id"]: e for e in events}
    applied = 0
    dropped = 0
    for ann in annotations or []:
        eid = ann.get("event_id")
        if eid not in by_id:
            sys.stderr.write(
                f"assemble: annotation drop unknown event_id: {eid}\n"
            )
            dropped += 1
            continue
        ev = by_id[eid]
        labels = ann.get("labels") or []
        existing = list(ev.get("_labels") or [])
        for lab in labels:
            if lab not in existing:
                existing.append(lab)
        ev["_labels"] = existing
        if "rank" in ann:
            # lowest rank wins if multiple (optional ordering hint)
            prev = ev.get("_rank")
            if prev is None or ann["rank"] < prev:
                ev["_rank"] = ann["rank"]
        applied += 1
    return events, applied, dropped


# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------


def normalize_transcript_ref(ref):
    """Bare L<n> or already-prefixed transcript:L<n> → single L<n> body.

    Miners sometimes put the full rendered form in `ref` (dogfood: CDT-81).
    Assemble always adds the type prefix once; strip any existing one first.
    """
    r = (ref or "").strip()
    low = r.lower()
    # Strip repeated type prefixes defensively (transcript:transcript:L…)
    while low.startswith("transcript:"):
        r = r[len("transcript:") :].strip()
        low = r.lower()
    if not r:
        return ""
    if not low.startswith("l"):
        r = "L" + r
    return r


def fmt_pointer(p):
    if isinstance(p, str):
        return p.strip()
    if not isinstance(p, dict):
        return str(p).strip()
    ptype = (p.get("type") or "").strip().lower()
    ref = str(p.get("ref") or "").strip()
    note = str(p.get("note") or "").strip()
    if not ref:
        token = ""
    elif ptype == "transcript":
        r = normalize_transcript_ref(ref)
        token = f"transcript:{r}" if r else ""
    elif ptype == "commit":
        token = f"commit:{ref}"
    elif ptype == "file":
        token = f"file:{ref}"
    else:
        token = ref
    if note:
        return f"{token} ({note})" if token else f"({note})"
    return token


def _label_suffix(ev):
    labels = ev.get("_labels") or []
    if not labels:
        return ""
    return " " + " ".join(f"[{lab}]" for lab in labels)


def _pointer_suffix(ev):
    """Inline courtesy ``↳`` line when ``pointers[]`` is non-empty."""
    ptrs = ev.get("pointers")
    if not isinstance(ptrs, list) or not ptrs:
        return ""
    toks = [t for t in (fmt_pointer(p) for p in ptrs) if t]
    if not toks:
        return ""
    return "\n  ↳ " + ", ".join(toks)


def _display_body(ev):
    """Body for markdown; enforce QUOTE_MAX on ruling/killed (and any quote)."""
    kind = ev.get("kind")
    text = ev.get("text")
    quote = ev.get("quote")
    text_ok = isinstance(text, str) and text.strip()
    quote_ok = isinstance(quote, str) and quote.strip()
    # ruling: prefer non-empty text, else quote (AC10 / M6)
    if kind == "ruling":
        body = text if text_ok else (quote if quote_ok else (text or ""))
    elif kind == "killed" and quote_ok:
        body = quote
    elif quote_ok:
        body = quote
    else:
        body = text or ""
    # Cap inline load-bearing text
    if kind in ("ruling", "killed") or (isinstance(ev.get("quote"), str) and ev.get("quote") == body):
        body = truncate_quote(body, QUOTE_MAX)
    elif len(body) > QUOTE_MAX and kind in ("ruling", "killed", "hypothesis", "decision", "open", "conflict", "fact"):
        # Defensive: any over-cap body shown inline is truncated (AC-7)
        body = truncate_quote(body, QUOTE_MAX)
    return body


def render_event_line(ev, bullet="-"):
    kind = ev.get("kind", "?")
    body = _display_body(ev)
    line = f"{bullet} **{kind}**: {body}{_label_suffix(ev)}"
    hv = ev.get("how_verified")
    if hv and kind == "fact":
        line += f" _(verified: {hv})_"
    line += _pointer_suffix(ev)
    return line


def estimate_tokens(text):
    """Advisory token estimate (~4 chars/token). Not a hard budget (AC-13)."""
    if not text:
        return 0
    return max(1, (len(text) + 3) // 4)


# ---------------------------------------------------------------------------
# Packet assembly
# ---------------------------------------------------------------------------


def assemble_packet(
    events,
    git_blob="",
    annotations=None,
    spine_tokens=None,
    session_uuid=None,
    leaf_uuid=None,
    slug=None,
    supersedes=None,
    captured_at=None,
    mode=None,
    light=False,
    summary=None,
):
    """Build full STM packet markdown string.

    Parameters
    ----------
    events : list
        Raw or validated event dicts (will re-validate if needed).
    git_blob : str
        Pre-captured git state text for appendix (no live git).
    annotations : list, optional
        Warm annotation objects {event_id, labels[], rank?}.
    spine_tokens : int, optional
        Stripped spine token count for advisory footer ratio.
    session_uuid, leaf_uuid, slug, supersedes : str, optional
        Packet metadata.
    captured_at : str, optional
        ISO timestamp; default now UTC.
    mode : str, optional
        ``cold`` or ``warm`` — CDT-85 honesty header (not freeform live-context).
    light : bool, optional
        CDT-91 M10c light preset marker. When True, emit ``light: true`` in
        header/footer meta and the exact LIGHT_HONESTY line. Does not invent
        a third mode value (mode stays cold|warm as passed).
    summary : str, optional
        Miner wrapper summary. Valid → first State now ``### Where we are``.
        Invalid/missing → omit heading; does not occupy event ids.
    """
    def _copy_meta(v, raw, default_src):
        """Preserve namespace / generation meta across re-validate."""
        if not isinstance(raw, dict):
            v.setdefault("_src_index", default_src)
            return v
        v["_src_index"] = raw.get("_src_index", default_src)
        if raw.get("_raw_id") is not None:
            v["_raw_id"] = raw["_raw_id"]
        if "_generation" in raw:
            v["_generation"] = raw["_generation"]
        return v

    # Validate if callers passed raw events
    cleaned = []
    for i, raw in enumerate(events or []):
        if isinstance(raw, dict) and raw.get("kind") in EVENT_KINDS and "id" in raw:
            # may already be validated
            if "_src_index" not in raw and ("text" in raw or "quote" in raw):
                ev = dict(raw)
                if "workstream" not in ev or not ev["workstream"]:
                    ev["workstream"] = DEFAULT_WORKSTREAM
                ev.setdefault("_src_index", i)
                # still re-validate kinds/body
                v = validate_event(ev)
                if v is None:
                    continue
                cleaned.append(_copy_meta(v, ev, i))
            else:
                v = validate_event(raw)
                if v is None:
                    continue
                cleaned.append(_copy_meta(v, raw, i))
        else:
            v = validate_event(raw)
            if v is None:
                continue
            cleaned.append(_copy_meta(v, raw if isinstance(raw, dict) else {}, i))

    ordered = order_events(cleaned)
    deduped = collapse_events(ordered, err=sys.stderr)
    # re-order after dedup (stable; order preserved)
    deduped = order_events(deduped)

    apply_annotations(deduped, annotations or [])

    state = select_state_now(deduped)
    occ = occupied_ids(state)
    remainder = remainder_events(deduped, occ)
    if captured_at is None:
        captured_at = (
            datetime.datetime.now(datetime.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z")
        )

    lines = []

    # --- header ---
    title = "STM packet"
    if session_uuid:
        title += f" — {session_uuid}"
    if slug:
        title += f" / {slug}"
    lines.append(f"# {title}")
    if supersedes:
        lines.append(f"Supersedes: {supersedes}")
    # mode first when set so scorers can reject freeform live-context (CDT-85)
    mode_norm = None
    if isinstance(mode, str) and mode.strip():
        m = mode.strip().lower()
        if m in ("cold", "warm"):
            mode_norm = m
    light_on = bool(light)
    meta_bits = []
    if mode_norm:
        meta_bits.append(f"mode: {mode_norm}")
    if light_on:
        meta_bits.append("light: true")
    if leaf_uuid:
        meta_bits.append(f"leaf-uuid: {leaf_uuid}")
    if session_uuid:
        meta_bits.append(f"session: {session_uuid}")
    meta_bits.append(f"captured_at: {captured_at}")
    lines.append("_" + " · ".join(meta_bits) + "_")
    lines.append("")

    # --- State now ---
    lines.append("## State now")
    lines.append("")
    if summary is not None:
        ok, prose, reason = validate_summary(summary, deduped)
        if ok:
            lines.append(WHERE_WE_ARE_HEADING)
            lines.append(prose)
            lines.append("")
        else:
            sys.stderr.write(f"assemble: omit summary: {reason}\n")
    lines.append("### Product surfaces")
    if state["product_surfaces_primary"]:
        for ev in state["product_surfaces_primary"]:
            lines.append(
                f"- **primary**: {_display_body(ev)}{_label_suffix(ev)}"
                f"{_pointer_suffix(ev)}"
            )
    else:
        lines.append("- **primary**: _unspecified_")
    if state["product_surfaces_unfinished"]:
        for ev in state["product_surfaces_unfinished"]:
            lines.append(
                "- **unfinished / do-not-treat-as-product**: "
                f"{_display_body(ev)}{_label_suffix(ev)}{_pointer_suffix(ev)}"
            )
    else:
        lines.append("- **unfinished / do-not-treat-as-product**: _unspecified_")
    lines.append("")
    lines.append("### Open ship gaps")
    if state["ship_gaps"]:
        for ev in state["ship_gaps"]:
            lines.append(render_event_line(ev))
    else:
        lines.append("_unspecified_")
    lines.append("")
    lines.append("### Decisions")
    if state["decisions"]:
        for ev in state["decisions"]:
            lines.append(render_event_line(ev))
    else:
        lines.append("_none_")
    lines.append("")
    lines.append("### Hypotheses (alive)")
    if state["hypotheses"]:
        for ev in state["hypotheses"]:
            lines.append(render_event_line(ev))
    else:
        lines.append("_none_")
    lines.append("")
    lines.append("### Open")
    if state["opens"]:
        # optional rank sort for opens
        opens = list(state["opens"])
        opens.sort(key=lambda e: (e.get("_rank") is None, e.get("_rank", 0), e.get("_src_index", 0)))
        for ev in opens:
            lines.append(render_event_line(ev))
    else:
        lines.append("_none_")
    lines.append("")

    # --- Through-line (remainder of State now occupancy) ---
    lines.append("## Through-line")
    lines.append("")
    workstreams = OrderedDict()
    for ev in remainder:
        ws = ev.get("workstream") or DEFAULT_WORKSTREAM
        workstreams.setdefault(ws, []).append(ev)

    if not remainder:
        lines.append("_no events_")
    elif len(workstreams) <= 1:
        for ev in remainder:
            lines.append(render_event_line(ev))
    else:
        for ws, evs in workstreams.items():
            lines.append(f"### {ws}")
            for ev in evs:
                lines.append(render_event_line(ev))
            lines.append("")
    lines.append("")

    # --- appendix (leftover after State now + Through-line) ---
    lines.append("## appendix")
    lines.append("")

    shown = set(occ)
    for ev in remainder:
        eid = ev.get("id")
        if eid is not None and str(eid).strip() != "":
            shown.add(eid)
    leftover = remainder_events(deduped, shown)

    kills = [e for e in leftover if e.get("kind") == "killed"]
    lines.append("### Kill catalog")
    if kills:
        for ev in kills:
            lines.append(render_event_line(ev))
    else:
        lines.append(kill_catalog_placeholder(kills, deduped))
    lines.append("")

    facts = [e for e in leftover if e.get("kind") == "fact"]
    if facts:
        lines.append("### Facts")
        for ev in facts:
            lines.append(render_event_line(ev))
        lines.append("")

    lines.append("### Code state (git)")
    git_text = (git_blob or "").rstrip()
    if git_text:
        lines.append("```")
        lines.append(git_text)
        lines.append("```")
    else:
        lines.append("_no git snapshot_")
    lines.append("")

    # --- footer ---
    body_so_far = "\n".join(lines)
    packet_tokens = estimate_tokens(body_so_far)
    lines.append("---")
    if mode_norm:
        lines.append(f"mode: {mode_norm}")
    if light_on:
        lines.append("light: true")
    lines.append(f"session: {session_uuid or '—'}")
    lines.append(f"captured_at: {captured_at}")
    if leaf_uuid:
        lines.append(f"leaf_uuid: {leaf_uuid}")
    if supersedes:
        lines.append(f"Supersedes: {supersedes}")
    if spine_tokens is not None:
        try:
            st = int(spine_tokens)
        except (TypeError, ValueError):
            st = None
        if st is not None:
            ratio = (packet_tokens / st) if st > 0 else 0.0
            lines.append(
                f"packet_tokens / stripped_spine_tokens: {packet_tokens} / {st} "
                f"(ratio {ratio:.3f}, advisory)"
            )
        else:
            lines.append(f"packet_tokens: {packet_tokens} (advisory)")
    else:
        lines.append(f"packet_tokens: {packet_tokens} (advisory)")
    if light_on:
        lines.append(LIGHT_HONESTY)

    packet = "\n".join(lines).rstrip() + "\n"
    ensure_state_now_contract(packet)
    return packet


def extract_core(packet_md):
    """Return State now + Through-line only (cold stdout core; no appendix)."""
    lines = packet_md.splitlines()
    out = []
    section = None
    for line in lines:
        if line.startswith("## "):
            section = line.strip()
            if section in ("## State now", "## Through-line"):
                out.append(line)
            elif section == "## appendix":
                break
            continue
        if section in ("## State now", "## Through-line"):
            out.append(line)
        elif section is None and (line.startswith("# ") or line.startswith("Supersedes:") or line.startswith("_")):
            # keep title/meta before first section
            out.append(line)
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_arg_parser():
    p = argparse.ArgumentParser(
        prog="assemble.py",
        description="Assemble STM packet from event JSON (LLM-free, SPEC-018).",
    )
    p.add_argument(
        "--events",
        required=True,
        help="Events JSON file or directory of *.json miner outputs",
    )
    p.add_argument(
        "--git",
        default="",
        help="Pre-captured git state blob (text file); empty ok for tests",
    )
    p.add_argument("--annotations", default="", help="Warm annotations JSON")
    p.add_argument(
        "--spine-tokens",
        type=int,
        default=None,
        dest="spine_tokens",
        help="Stripped spine token count for advisory footer ratio",
    )
    p.add_argument("--session-uuid", default="", dest="session_uuid")
    p.add_argument("--leaf-uuid", default="", dest="leaf_uuid")
    p.add_argument("--slug", default="")
    p.add_argument("--supersedes", default="", help="Prior packet filename")
    p.add_argument(
        "--mode",
        default="",
        choices=["", "cold", "warm"],
        help="Capture mode for packet header honesty (CDT-85); empty = omit",
    )
    p.add_argument(
        "--light",
        action="store_true",
        help="CDT-91 M10c light preset: emit light: true meta + honesty line",
    )
    p.add_argument("--out", default="", help="Write packet markdown here (else stdout)")
    p.add_argument(
        "--print-core",
        action="store_true",
        help="Print State now + Through-line only (cold inject shape)",
    )
    p.add_argument(
        "--prior-events",
        default="",
        dest="prior_events",
        help="Prior cache JSON (events stem map) or bare stem map for merge (CDT-88)",
    )
    p.add_argument(
        "--events-out",
        default="",
        dest="events_out",
        help="Write post-dedup cumulative stem-map JSON (raw ids) for M8 cache",
    )
    return p


def main(argv=None):
    args = build_arg_parser().parse_args(argv)

    try:
        events = load_events(args.events)
    except FileNotFoundError as e:
        sys.stderr.write(f"assemble: {e}\n")
        return 2

    summary = load_wrapper_summary(args.events)

    prior = []
    if args.prior_events:
        prior = load_prior_events(args.prior_events)
        if prior:
            events = merge_events(prior, events)

    # Post-dedup list for events-out (mirrors assemble_packet pipeline)
    if args.events_out:
        for_cache = order_events(collapse_events(order_events(list(events)), err=sys.stderr))
        cache_map = events_for_cache(for_cache)
        out_dir = os.path.dirname(args.events_out)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.events_out, "w", encoding="utf-8") as fh:
            json.dump(cache_map, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    git_blob = ""
    if args.git:
        try:
            git_blob = load_git_blob(args.git)
        except OSError as e:
            sys.stderr.write(f"assemble: git blob unreadable: {e}\n")
            return 2

    annotations = []
    if args.annotations:
        try:
            annotations = load_annotations(args.annotations)
        except (OSError, ValueError) as e:
            sys.stderr.write(f"assemble: annotations unreadable: {e}\n")
            return 2

    try:
        packet = assemble_packet(
            events,
            git_blob=git_blob,
            annotations=annotations,
            spine_tokens=args.spine_tokens,
            session_uuid=args.session_uuid or None,
            leaf_uuid=args.leaf_uuid or None,
            slug=args.slug or None,
            supersedes=args.supersedes or None,
            mode=args.mode or None,
            light=bool(args.light),
            summary=summary,
        )
    except AssembleError as e:
        sys.stderr.write(f"{e}\n")
        return 1

    if args.out:
        out_dir = os.path.dirname(args.out)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(packet)

    if args.print_core:
        sys.stdout.write(extract_core(packet))
        if args.out:
            sys.stdout.write(f"\nFull packet (appendix): {args.out}\n")
    else:
        if not args.out:
            sys.stdout.write(packet)
        # when --out without --print-core, stay quiet on stdout (file is product)
        elif os.environ.get("ASSEMBLE_ECHO"):
            sys.stdout.write(packet)

    return 0


if __name__ == "__main__":
    sys.exit(main())
