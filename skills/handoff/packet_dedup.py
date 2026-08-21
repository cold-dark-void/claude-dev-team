"""STM packet event collapse — LLM-free dedup (SPEC-018 M3d(1)/M8b, CDT-202).

Stdlib only. MUST NOT import assemble. Assemble and tests import this module.

Pass order: exact same-kind first-wins → same-kind prefix-collapse → open/conflict drop.
"""

from __future__ import annotations

PREFIX_MIN = 40
PUNCT_STRIP = ".?!;:,"
NONE = "_none_"
NONE_ALREADY_SHOWN = "_none not already shown above_"

_RSTRIP = PUNCT_STRIP + " \t\r\n"


def normalize_text(s):
    """Whitespace-collapse + casefold for dedup keys only (display keeps original)."""
    if s is None:
        return ""
    return " ".join(str(s).split()).casefold()


def event_body(ev):
    """Load-bearing body: prefer quote when set, else text."""
    if not isinstance(ev, dict):
        return ""
    q = ev.get("quote")
    if isinstance(q, str) and q.strip():
        return q
    t = ev.get("text")
    if isinstance(t, str) and t.strip():
        return t
    return ""


def punct_strip_norm(s):
    """normalize_text then rstrip whitespace + ASCII ``.?!;:,``."""
    return normalize_text(s).rstrip(_RSTRIP)


def exact_dedup(events):
    """First-wins on ``(kind, normalize_text(body))``; any length. No punct strip."""
    seen = set()
    out = []
    for ev in events or []:
        kind = ev.get("kind", "") if isinstance(ev, dict) else ""
        k = (kind, normalize_text(event_body(ev)))
        if k in seen:
            continue
        if not k[1]:
            continue
        seen.add(k)
        out.append(ev)
    return out


def _copy_body(dst, src):
    """Copy longer event's original text+quote onto earliest (id/facet stay)."""
    if "text" in src:
        dst["text"] = src["text"]
    else:
        dst.pop("text", None)
    if "quote" in src:
        dst["quote"] = src["quote"]
    else:
        dst.pop("quote", None)


def _strict_prefix(na, nb):
    """True if one is a STRICT prefix of the other and shorter is ≥ PREFIX_MIN."""
    if not na or not nb or na == nb:
        return False
    if nb.startswith(na):
        return len(na) >= PREFIX_MIN
    if na.startswith(nb):
        return len(nb) >= PREFIX_MIN
    return False


def prefix_collapse(events):
    """Same-kind strict prefix-collapse; longest body on earliest event. No stderr."""
    evs = list(events or [])
    i = 0
    while i < len(evs):
        j = i + 1
        while j < len(evs):
            a, b = evs[i], evs[j]
            if not isinstance(a, dict) or not isinstance(b, dict):
                j += 1
                continue
            if a.get("kind") != b.get("kind"):
                j += 1
                continue
            na = punct_strip_norm(event_body(a))
            nb = punct_strip_norm(event_body(b))
            if not _strict_prefix(na, nb):
                j += 1
                continue
            if nb.startswith(na) and na != nb:
                _copy_body(a, b)
            evs.pop(j)
        i += 1
    return evs


def _open_conflict_match(conflict_n, open_n):
    """Equal or prefix/superstring under the ≥40 rule."""
    if not conflict_n or not open_n:
        return False
    if conflict_n == open_n:
        return len(conflict_n) >= PREFIX_MIN
    if conflict_n.startswith(open_n):
        return len(open_n) >= PREFIX_MIN
    if open_n.startswith(conflict_n):
        return len(conflict_n) >= PREFIX_MIN
    return False


def drop_open_conflict_twins(events, err=None):
    """Drop each conflict twin of an open; keep the open. One assemble: line each."""
    evs = list(events or [])
    opens = [e for e in evs if isinstance(e, dict) and e.get("kind") == "open"]
    out = []
    for ev in evs:
        if not isinstance(ev, dict) or ev.get("kind") != "conflict":
            out.append(ev)
            continue
        cn = punct_strip_norm(event_body(ev))
        twin = None
        for op in opens:
            if _open_conflict_match(cn, punct_strip_norm(event_body(op))):
                twin = op
                break
        if twin is None:
            out.append(ev)
            continue
        if err is not None:
            cid = ev.get("id", "")
            oid = twin.get("id", "")
            err.write(
                f"assemble: dropped conflict {cid} as duplicate of open {oid}\n"
            )
    return out


def collapse_events(events, err=None):
    """exact_dedup → prefix_collapse → drop_open_conflict_twins."""
    return drop_open_conflict_twins(
        prefix_collapse(exact_dedup(events)), err=err
    )


def kill_catalog_placeholder(leftover_kills, assembled):
    """Empty leftover: already-shown if any killed in assembled, else ``_none_``."""
    if leftover_kills:
        return ""
    for ev in assembled or []:
        if isinstance(ev, dict) and ev.get("kind") == "killed":
            return NONE_ALREADY_SHOWN
    return NONE
