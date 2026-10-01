#!/usr/bin/env python3
"""Shared transcript locate + fork-assembly primitive (SPEC-018 M1).

Three subcommands, all read-only over ~/.claude/projects/ (or a named path):

  assemble.py locate <uuid>
      Print the canonical transcript file for a session uuid and exit 0.
      The canonical file is the *latest descendant*: among all files that
      contain the uuid (either as a message line's "uuid" field, or as the
      file's own name stem), the one with the greatest maximum "timestamp".
      Not found -> message on stderr, exit 1.

  assemble.py assemble <uuid>
      Locate the canonical file, then stream it and emit one chronologically
      ordered raw-JSON message line per surviving message to stdout.
      Surviving = message lines (non-null "uuid"); null-uuid bookkeeping
      lines (mode / custom-title / agent-name / last-prompt /
      file-history-snapshot / etc.) are dropped from the timeline.
      Messages are de-duplicated on "uuid" KEEP-LAST and ordered by
      (timestamp, first-seen line index).

  assemble.py assemble-file <path>
      Stream exactly the named transcript file (no locate). Same emit
      contract as assemble. Used by PreCompact capture (SPEC-018 M12)
      when the hook already names the live file.

Why this shape (validated against real 72 MB+ transcripts):
  - `forkedFrom` is PROVENANCE -- an object {sessionId, messageUuid} where
    messageUuid is self-referential -- NOT a cross-file pointer. A fork copies
    its chosen-path prefix (with stable uuids) into the child file, so
    assembly is single-file: locate the canonical descendant + dedup + order.
    There is intentionally NO cross-file message walk.
  - Ordering uses timestamps, not the parentUuid DAG: copy-duplication makes
    that DAG multi-root and branchy. File order alone is also wrong because
    copied segments overlap in time, hence the (timestamp, line) sort.
  - A direct `<uuid>.jsonl` hit returns that file and does not open other
    transcripts. A fork scan (no direct file) streams line by line. Monsters
    are 70 MB+ and may be mid-write. We never read() a whole file.

This module is parse-only: it locates and orders, it never scores or distils.
Consumers (the /handoff prepass, the /retro gate + Step 2) own that.
"""

import os
import sys

# This file is invoked as a CLI (python3 assemble.py ... from retro.md and
# handoff/prepass.sh). When run as a script its own dir is NOT auto on
# sys.path, so an `import parselib` would fail. Inject the sibling dir first --
# mirrors the seam gate.sh/prepass.sh use to share the same primitives.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Canonical parse primitives live in parselib -- import them rather than
# re-defining, so this CLI shares one definition with the /retro gate and the
# /handoff prepass (KNOWN_TOP_FIELDS, parse_line, warn_schema_drift,
# is_sidechain). Do NOT re-inline these. We use the lower-level
# warn_schema_drift (not schema_drift_warn) so we keep our single streaming
# pass over the file -- monsters are 70 MB+ and must not be read twice.
from parselib import (  # noqa: E402  (after sys.path injection, by design)
    KNOWN_TOP_FIELDS,
    is_sidechain,
    parse_line,
    warn_schema_drift,
)

# How many leading lines to inspect before deciding the file looks foreign.
# Matches parselib's default schema_drift_check_n (50).
_DRIFT_PROBE_LINES = 50

PROJECTS_DIR = os.path.join(os.path.expanduser("~"), ".claude", "projects")


def _warn(msg):
    sys.stderr.write("transcript-parse: " + msg + "\n")


def _iter_project_files():
    """Yield absolute paths of every *.jsonl under ~/.claude/projects/*/.

    Tolerates a missing projects dir and unreadable subdirs (a session may
    reference ancestor projects that no longer exist on this machine).
    """
    if not os.path.isdir(PROJECTS_DIR):
        return
    try:
        subdirs = os.listdir(PROJECTS_DIR)
    except OSError as e:
        _warn(f"cannot list {PROJECTS_DIR}: {e}")
        return
    for name in subdirs:
        sub = os.path.join(PROJECTS_DIR, name)
        if not os.path.isdir(sub):
            continue
        try:
            entries = os.listdir(sub)
        except OSError:
            # Unreadable project dir -- skip, never crash.
            continue
        for fname in entries:
            if fname.endswith(".jsonl"):
                yield os.path.join(sub, fname)


def _scan_file_for_uuid(path, target_uuid):
    """Stream one file once. Return (contains, max_timestamp).

    contains -> True if target_uuid is the file's name stem OR appears as any
    line's non-null "uuid". max_timestamp -> greatest "timestamp" string seen
    (lexicographically; ISO-8601 UTC sorts correctly), or "" if none.

    Reads line-by-line so a 70 MB+ file never lands in memory. A file that
    vanishes or is unreadable mid-scan is treated as "not containing".
    """
    stem = os.path.splitext(os.path.basename(path))[0]
    contains = stem == target_uuid
    max_ts = ""
    known_seen = False
    probed = 0
    try:
        _log_scan(path)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # Substring pre-filter: skip lines that cannot hold the uuid
                # or a timestamp before paying for json.loads.
                if target_uuid not in line and '"timestamp"' not in line:
                    continue
                obj = parse_line(line)
                if obj is None:
                    # Blank / corrupt / non-dict line -- skip it.
                    continue
                if probed < _DRIFT_PROBE_LINES:
                    probed += 1
                    if obj.keys() & KNOWN_TOP_FIELDS:
                        known_seen = True
                u = obj.get("uuid")
                if isinstance(u, str) and u == target_uuid:
                    contains = True
                ts = obj.get("timestamp")
                if isinstance(ts, str) and ts > max_ts:
                    max_ts = ts
    except FileNotFoundError:
        return (False, "")
    except OSError as e:
        _warn(f"cannot read {path}: {e}")
        return (False, "")
    # Drift warning shares parselib's canonical text + once-per-path dedup.
    warn_schema_drift(path, probed, known_seen)
    return (contains, max_ts)


def _log_locate():
    log = os.environ.get("ASSEMBLE_LOCATE_LOG")
    if not log:
        return
    try:
        with open(log, "a", encoding="utf-8") as fh:
            fh.write("locate\n")
    except OSError:
        pass


def _log_scan(path):
    log = os.environ.get("ASSEMBLE_SCAN_LOG")
    if not log:
        return
    try:
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(path + "\n")
    except OSError:
        pass


def _direct_hit(target_uuid):
    """Return <project>/<uuid>.jsonl when one exists. Do not open other files."""
    if not target_uuid or os.sep in target_uuid or target_uuid in (".", ".."):
        return None
    if not os.path.isdir(PROJECTS_DIR):
        return None
    name = target_uuid + ".jsonl"
    found = []
    try:
        subdirs = os.listdir(PROJECTS_DIR)
    except OSError as e:
        _warn(f"cannot list {PROJECTS_DIR}: {e}")
        return None
    for dname in subdirs:
        sub = os.path.join(PROJECTS_DIR, dname)
        if not os.path.isdir(sub):
            continue
        path = os.path.join(sub, name)
        try:
            if os.path.isfile(path):
                found.append(path)
        except OSError:
            continue
    if not found:
        return None

    def _key(p):
        try:
            mt = os.path.getmtime(p)
        except OSError:
            mt = 0
        return (-mt, p)

    found.sort(key=_key)
    return found[0]


def locate(target_uuid):
    """Return the canonical transcript path for target_uuid, or None.

    Direct hit: `<project>/<uuid>.jsonl` returns immediately and does not
    open any other transcript. Fork descendants are scanned only when no
    direct file exists. Among those, canonical = greatest max-timestamp.
    Ties break by path.
    """
    _log_locate()
    direct = _direct_hit(target_uuid)
    if direct is not None:
        return direct
    best_path = None
    best_ts = None
    for path in _iter_project_files():
        contains, max_ts = _scan_file_for_uuid(path, target_uuid)
        if not contains:
            continue
        if (
            best_path is None
            or max_ts > best_ts
            or (max_ts == best_ts and path < best_path)
        ):
            best_path, best_ts = path, max_ts
    return best_path


def _stream_message_lines(path):
    """Yield (first_seen_index, timestamp, uuid, raw_line) for message lines.

    Message line = parses to a dict with a non-null "uuid". Null-uuid
    bookkeeping lines (mode / custom-title / agent-name / last-prompt /
    file-history-snapshot / permission-mode / queue-operation / ...) are
    skipped -- the non-null-uuid rule covers them generically, so new
    bookkeeping types need no code change.

    Per-line try/except keeps a single corrupt line (e.g. a half-flushed tail
    on a mid-write monster) from aborting the whole assembly.
    """
    idx = -1
    known_seen = False
    probed = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            obj = parse_line(raw)
            if obj is None:
                continue
            if probed < _DRIFT_PROBE_LINES:
                probed += 1
                if obj.keys() & KNOWN_TOP_FIELDS:
                    known_seen = True
            u = obj.get("uuid")
            if not isinstance(u, str) or not u:
                continue
            idx += 1
            ts = obj.get("timestamp")
            if not isinstance(ts, str):
                ts = ""
            yield (idx, ts, u, raw.strip())
    # Drift warning shares parselib's canonical text + once-per-path dedup.
    warn_schema_drift(path, probed, known_seen)


def assemble(target_uuid, out=sys.stdout, path=None):
    """Stream the canonical file and write the ordered, deduped timeline.

    Dedup on uuid KEEP-LAST: a later copy of the same uuid replaces the
    earlier, but we retain the *first-seen* line index so timestamp ties order
    by original appearance. Order by (timestamp, first_seen_index).

    isSidechain spans are tagged (maximal contiguous runs of
    isSidechain is True). In real transcripts no line is ever a sidechain, so
    this is a defensive no-op; when present, a span boundary is logged to
    stderr and the raw lines pass through unmodified (collapse is the
    prepass's job, not the parser's).

    path, when given, names the exact transcript to stream (PreCompact
    capture path, SPEC-018 M12 — the hook already knows the live file; no
    canonical-file search). target_uuid is unused in that mode.

    Returns the number of message lines emitted.
    """
    if path is None:
        path = locate(target_uuid)
        if path is None:
            _warn(f"uuid not found in any transcript: {target_uuid}")
            return None
    elif not os.path.isfile(path):
        _warn(f"transcript file not found: {path}")
        return None

    # uuid -> [timestamp, first_seen_index, raw_line]; keep-last on raw, but
    # first_seen_index is pinned on first sight for stable tie-breaking.
    by_uuid = {}
    try:
        for idx, ts, u, raw in _stream_message_lines(path):
            existing = by_uuid.get(u)
            if existing is None:
                by_uuid[u] = [ts, idx, raw]
            else:
                # keep-last payload + timestamp; preserve first_seen index.
                existing[0] = ts
                existing[2] = raw
    except FileNotFoundError:
        # Canonical file vanished between locate and read (race / mid-rotate).
        _warn(f"canonical file disappeared during read: {path}")
        return None
    except BrokenPipeError:
        raise
    except OSError as e:
        _warn(f"cannot read {path}: {e}")
        return None

    ordered = sorted(by_uuid.values(), key=lambda rec: (rec[0], rec[1]))

    emitted = 0
    in_sidechain = False
    for ts, idx, raw in ordered:
        # Defensive isSidechain span tagging (no-op in real data).
        obj = parse_line(raw)
        is_side = is_sidechain(obj) if obj is not None else False
        if is_side and not in_sidechain:
            in_sidechain = True
            _warn("isSidechain span begins (passthrough; collapse is prepass)")
        elif not is_side and in_sidechain:
            in_sidechain = False
            _warn("isSidechain span ends")
        out.write(raw + "\n")
        emitted += 1
    return emitted


def _usage(stream=sys.stderr):
    stream.write(
        "usage: assemble.py locate <uuid>\n"
        "       assemble.py assemble <uuid>\n"
        "       assemble.py assemble-file <path>   (stream exactly this file; no locate)\n"
    )


def main(argv):
    if sys.version_info[0] < 3:  # pragma: no cover - guarded again at shebang
        sys.stderr.write("transcript-parse: requires python3\n")
        return 2
    if len(argv) != 3:
        _usage()
        return 2
    cmd, target_uuid = argv[1], argv[2]
    if not target_uuid:
        _usage()
        return 2

    if cmd == "locate":
        path = locate(target_uuid)
        if path is None:
            _warn(f"uuid not found in any transcript: {target_uuid}")
            return 1
        sys.stdout.write(path + "\n")
        return 0

    if cmd == "assemble":
        count = assemble(target_uuid)
        if count is None:
            return 1
        return 0

    if cmd == "assemble-file":
        count = assemble(None, path=target_uuid)
        if count is None:
            return 1
        return 0

    _usage()
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
        sys.exit(0)
