#!/usr/bin/env python3
"""Shared transcript locate + fork-assembly primitive (SPEC-018 M1).

Two subcommands, both read-only over ~/.claude/projects/:

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

Why this shape (CDV-10 Task-1 spike against real 72 MB+ transcripts):
  - `forkedFrom` is PROVENANCE -- an object {sessionId, messageUuid} where
    messageUuid is self-referential -- NOT a cross-file pointer. A fork copies
    its chosen-path prefix (with stable uuids) into the child file, so
    assembly is single-file: locate the canonical descendant + dedup + order.
    There is intentionally NO cross-file message walk.
  - Ordering uses timestamps, not the parentUuid DAG: copy-duplication makes
    that DAG multi-root and branchy. File order alone is also wrong because
    copied segments overlap in time, hence the (timestamp, line) sort.
  - We never read the whole file: monsters are 70 MB+ and may be mid-write.

This module is parse-only: it locates and orders, it never scores or distils.
Consumers (the /handoff prepass, the /retro gate + Step 2) own that.
"""

import json
import os
import sys

PROJECTS_DIR = os.path.join(os.path.expanduser("~"), ".claude", "projects")

# Top-level fields we expect on a JSONL transcript line. Used only to emit a
# best-effort schema-drift warning -- never to reject a line. Mirrors
# skills/retro-gate/gate.sh KNOWN_TOP_FIELDS so the shared seam stays aligned.
KNOWN_TOP_FIELDS = {
    "type",
    "uuid",
    "message",
    "parentUuid",
    "sessionId",
    "timestamp",
}

# How many leading lines to inspect before deciding the file looks foreign.
_DRIFT_PROBE_LINES = 50


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
    drift_checked = False
    known_seen = False
    probed = 0
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    # Corrupt / partially written line -- skip it.
                    continue
                if not isinstance(obj, dict):
                    continue
                if not drift_checked and probed < _DRIFT_PROBE_LINES:
                    probed += 1
                    if obj.keys() & KNOWN_TOP_FIELDS:
                        known_seen = True
                    if probed >= _DRIFT_PROBE_LINES:
                        drift_checked = True
                u = obj.get("uuid")
                if u is not None and u == target_uuid:
                    contains = True
                ts = obj.get("timestamp")
                if isinstance(ts, str) and ts > max_ts:
                    max_ts = ts
    except FileNotFoundError:
        return (False, "")
    except OSError as e:
        _warn(f"cannot read {path}: {e}")
        return (False, "")
    if probed and not known_seen:
        _warn(
            f"WARNING -- no known JSONL fields in first {probed} lines of "
            f"{path}; possible schema drift."
        )
    return (contains, max_ts)


def locate(target_uuid):
    """Return the canonical transcript path for target_uuid, or None.

    Canonical = the descendant whose copied prefix is most complete, i.e. the
    matching file with the greatest max-timestamp (latest descendant). Ties
    broken by path for determinism.
    """
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
    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except (ValueError, TypeError):
                continue
            if not isinstance(obj, dict):
                continue
            if probed < _DRIFT_PROBE_LINES:
                probed += 1
                if obj.keys() & KNOWN_TOP_FIELDS:
                    known_seen = True
            u = obj.get("uuid")
            if u is None:
                continue
            idx += 1
            ts = obj.get("timestamp")
            if not isinstance(ts, str):
                ts = ""
            yield (idx, ts, u, stripped)
    if probed and not known_seen:
        _warn(
            f"WARNING -- no known JSONL fields in first {probed} lines of "
            f"{path}; possible schema drift."
        )


def assemble(target_uuid, out=sys.stdout):
    """Stream the canonical file and write the ordered, deduped timeline.

    Dedup on uuid KEEP-LAST: a later copy of the same uuid replaces the
    earlier, but we retain the *first-seen* line index so timestamp ties order
    by original appearance. Order by (timestamp, first_seen_index).

    isSidechain spans are tagged (maximal contiguous runs of
    isSidechain is True). In real transcripts no line is ever a sidechain, so
    this is a defensive no-op; when present, a span boundary is logged to
    stderr and the raw lines pass through unmodified (collapse is the
    prepass's job, not the parser's).

    Returns the number of message lines emitted.
    """
    path = locate(target_uuid)
    if path is None:
        _warn(f"uuid not found in any transcript: {target_uuid}")
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
    except OSError as e:
        _warn(f"cannot read {path}: {e}")
        return None

    ordered = sorted(by_uuid.values(), key=lambda rec: (rec[0], rec[1]))

    emitted = 0
    in_sidechain = False
    for ts, idx, raw in ordered:
        # Defensive isSidechain span tagging (no-op in real data).
        try:
            obj = json.loads(raw)
            is_side = obj.get("isSidechain") is True
        except (ValueError, TypeError):
            is_side = False
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

    _usage()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
