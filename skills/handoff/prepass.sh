#!/usr/bin/env bash
#
# prepass.sh — /handoff deterministic pre-pass + size-adaptive spine (SPEC-018).
#
# Subcommands:
#   prepass.sh prepare     --uuid <uuid> [--out <plan.json>]
#   prepass.sh cache-check --uuid <uuid>
#   prepass.sh finalize    --uuid <uuid> --sections <dir>
#
# `prepare` — what it does (no LLM — this is the deterministic stage
# that feeds the extractor subagents):
#   (a) LOCATE   — resolve the canonical transcript file via the shared module
#                  (skills/transcript-parse/assemble.py locate).
#   (b) FRESHNESS — M9 guard via the shared freshness.sh; if the file was
#                  modified < 60 s ago (in-progress) we REFUSE: clear message,
#                  exit 9, no partial brief.
#   (c) ASSEMBLE — get the ordered, deduped timeline (assemble.py assemble),
#                  streamed; the 87 MB+ raw file is never read by us.
#   (d) PRE-PASS — M2: strip top-level `toolUseResult` payloads (where the bulk
#                  of the bytes live), dedup repeated Reads of the same path
#                  (keep last, leave a pointer for the superseded ones), and
#                  collapse contiguous `isSidechain` runs to a 1-line pointer
#                  (a no-op in real data — sidechains are never True — but
#                  honored defensively). `thinking` blocks are KEPT (M4-b needs
#                  the hypothesis-rejection reasoning), via parselib.msg_text.
#   (e) LEAF     — the cache key (M8): uuid of the last non-null-uuid line.
#   (f) SIZE     — M3: spine_chars / CHARS_PER_TOKEN <= HANDOFF_SPINE_TOKENS
#                  → mode="direct"; else mode="chunked", split at message
#                  boundaries into chunks each within the token budget.
#   (g) EMIT     — a plan.json the orchestrator and finalize
#                  consume: {mode, leaf_uuid, source_files, spine|chunks, stats}.
#
# `cache-check` (M8) — recompute the current leaf-uuid (same logic as
#   `prepare`: the last surviving message of the assembled timeline), then look
#   up <REPO>/.claude/handoff/cache/<uuid>.json. If it exists AND its stored
#   leaf_uuid equals the current leaf-uuid, print the cached brief and exit 0
#   (HIT — the session has not grown). Otherwise exit 10 (MISS — never built,
#   or new messages were appended). The cache lives under .claude/handoff/,
#   NEVER memory.db, so it cannot intersect the memory write-path (M8 / spec).
#
# `finalize` (M6/M7/M8) — merge the five extractor section JSONs (M4:
#   Convergence / Dead-ends / Code-state / Open-threads+conflicts / Basics) from
#   --sections <dir> into ONE dense markdown brief: five labeled sections, every
#   non-trivial claim carrying a drill-down pointer (M6), no raw tool output,
#   total <= 400 lines. Then write the cache file (keyed by leaf-uuid, M8) and
#   print the brief to stdout (cold-mode injection, M7).
#
# Exit codes (the API):
#   0  ok            prepare: plan.json written · cache-check: HIT · finalize: brief printed
#   9  too-fresh     transcript modified < 60 s ago (M9) — declined  [prepare]
#   10 cache-miss    no cached brief, or session has grown (M8)        [cache-check]
#   1  not-found     uuid not in any transcript, or usage / environment error
#
# Runtime: python3 only (already required by retro-gate + the shared module).
# We stream; we never read() the whole monster. JSON is emitted by python3 (no
# jq dependency, matching the "no new deps" rule).

set -eu

# --- locate this script's dir so we can find the shared module --------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# skills/handoff/ -> skills/transcript-parse/
PARSE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../transcript-parse" 2>/dev/null && pwd || true)

ASSEMBLE="$PARSE_DIR/assemble.py"
FRESHNESS="$PARSE_DIR/freshness.sh"

# --- python3 guard ----------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "prepass.sh: python3 is required but was not found on PATH." >&2
  exit 1
fi

usage() {
  cat >&2 <<'EOF'
Usage: prepass.sh prepare     --uuid <uuid> [--out <plan.json>]
       prepass.sh cache-check --uuid <uuid>
       prepass.sh finalize    --uuid <uuid> --sections <dir> [--leaf <uuid>]

  prepare      assemble + pre-pass + size-decide; emits plan.json (+ spine/chunks)
  cache-check  exit 0 (HIT, prints cached brief) / exit 10 (MISS) keyed by leaf-uuid
  finalize     merge 5 section JSONs -> dense brief; write cache; print brief

  --uuid     <uuid>   session uuid (required for all subcommands)
  --out      <path>   prepare: where to write the plan JSON (default: ./plan.json)
  --sections <dir>    finalize: dir holding the 5 extractor section JSONs
  --leaf     <uuid>   finalize: the leaf-uuid (M8 cache key) prepare already
                      computed; passing it skips a full transcript re-stream.
                      Omitted -> finalize recomputes it via assemble.py.

Env:
  HANDOFF_SPINE_TOKENS   token budget for a single spine (default 120000).
                         Over budget -> chunked mode (split at msg boundaries).
  HANDOFF_BRIEF_MAX_LINES brief line cap (default 400; M3/M4 bound).
EOF
  exit 1
}

# --- subcommand dispatch ----------------------------------------------------
SUBCMD="${1:-}"
case "$SUBCMD" in
  prepare|cache-check|finalize) shift ;;
  -h|--help|"") usage ;;
  *) echo "prepass.sh: unknown subcommand: $SUBCMD" >&2; usage ;;
esac

# Shared arg parse: --uuid (all), --out (prepare), --sections + --leaf (finalize).
UUID=""
OUT="plan.json"
SECTIONS=""
LEAF_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --uuid)
      [ $# -ge 2 ] || usage
      UUID="$2"; shift 2 ;;
    --uuid=*)
      UUID="${1#--uuid=}"; shift ;;
    --out)
      [ $# -ge 2 ] || usage
      OUT="$2"; shift 2 ;;
    --out=*)
      OUT="${1#--out=}"; shift ;;
    --sections)
      [ $# -ge 2 ] || usage
      SECTIONS="$2"; shift 2 ;;
    --sections=*)
      SECTIONS="${1#--sections=}"; shift ;;
    --leaf)
      [ $# -ge 2 ] || usage
      LEAF_ARG="$2"; shift 2 ;;
    --leaf=*)
      LEAF_ARG="${1#--leaf=}"; shift ;;
    -h|--help)
      usage ;;
    *)
      echo "prepass.sh: unknown argument: $1" >&2
      usage ;;
  esac
done

if [ -z "$UUID" ]; then
  echo "prepass.sh: --uuid is required." >&2
  usage
fi

if [ ! -f "$ASSEMBLE" ]; then
  echo "prepass.sh: shared module not found at $ASSEMBLE" >&2
  exit 1
fi

# --- shared: resolve repo root + cache path (M8) ----------------------------
# Cache lives under <REPO>/.claude/handoff/cache/, resolved via git-common-dir
# (worktree-aware: all worktrees share one .git common dir, hence one cache).
# It MUST NOT live in memory.db — this keeps the brief cache off the memory
# write-path and out of staleness scans (SPEC-018 M8 + Overview boundary).
resolve_repo_root() {
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) || { pwd; return; }
  ( cd -- "$(dirname -- "$_gc")" 2>/dev/null && pwd ) || pwd
}
REPO_ROOT=$(resolve_repo_root)
CACHE_DIR="$REPO_ROOT/.claude/handoff/cache"
CACHE_FILE="$CACHE_DIR/$UUID.json"

# compute_leaf — recompute the current leaf-uuid for UUID by streaming the
# assembled (timestamp-ordered) timeline and applying the shared keep_last_uuid
# rule (skills/handoff/leafrule.py). This is byte-identical to `prepare`'s leaf
# computation (SAME imported rule, same ordered input), so a brief built by
# `prepare`/`finalize` and a later `cache-check` agree on the M8 key. Prints leaf
# to stdout, exit 0; on uuid-not-found / assemble failure prints nothing and
# returns non-zero.
compute_leaf() {
  PREPASS_ASSEMBLE="$ASSEMBLE" PREPASS_UUID="$UUID" PREPASS_SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PYEOF'
import json, os, subprocess, sys

# Import the single-source leaf rule (keep_last_uuid) from this skill dir.
sys.path.insert(0, os.environ["PREPASS_SCRIPT_DIR"])
from leafrule import keep_last_uuid

ASSEMBLE = os.environ["PREPASS_ASSEMBLE"]
UUID = os.environ["PREPASS_UUID"]

proc = subprocess.Popen(
    [sys.executable, ASSEMBLE, "assemble", UUID],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
)

def _stream(p):
    for line in p.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except (ValueError, TypeError):
            continue

leaf = keep_last_uuid(_stream(proc))
proc.stdout.close()
err = proc.stderr.read()
proc.stderr.close()
rc = proc.wait()
if rc != 0 or leaf is None:
    if err:
        sys.stderr.write(err)
    sys.exit(1)
sys.stdout.write(leaf + "\n")
PYEOF
}

# ===========================================================================
# SUBCOMMAND: cache-check (M8)
# ===========================================================================
# Recompute the current leaf-uuid, compare it to the leaf-uuid stored in the
# cache file. Match -> print cached brief, exit 0 (HIT). Otherwise exit 10
# (MISS: never built, grown session, or unreadable cache).
if [ "$SUBCMD" = "cache-check" ]; then
  if [ ! -f "$CACHE_FILE" ]; then
    echo "prepass.sh: cache MISS (no cache file: $CACHE_FILE)" >&2
    exit 10
  fi
  set +e
  CUR_LEAF=$(compute_leaf)
  leaf_rc=$?
  set -e
  if [ "$leaf_rc" -ne 0 ] || [ -z "$CUR_LEAF" ]; then
    # Can't determine the current leaf (uuid vanished / assemble failed) ->
    # we cannot honor the cache safely; treat as a miss so the caller rebuilds.
    echo "prepass.sh: cache MISS (cannot recompute leaf-uuid for $UUID)" >&2
    exit 10
  fi
  # Compare stored leaf vs current leaf and, on match, stream the cached brief.
  # All cache I/O is confined to $CACHE_FILE under .claude/handoff/ — no memory.db.
  CACHE_FILE="$CACHE_FILE" CUR_LEAF="$CUR_LEAF" python3 - <<'PYEOF'
import json, os, sys

cache_file = os.environ["CACHE_FILE"]
cur_leaf = os.environ["CUR_LEAF"]
try:
    with open(cache_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as e:
    sys.stderr.write(f"prepass.sh: cache MISS (unreadable cache: {e})\n")
    sys.exit(10)
stored_leaf = data.get("leaf_uuid") if isinstance(data, dict) else None
brief = data.get("brief") if isinstance(data, dict) else None
if not stored_leaf or stored_leaf != cur_leaf:
    sys.stderr.write(
        f"prepass.sh: cache MISS (leaf changed: stored={stored_leaf} "
        f"current={cur_leaf}; session has grown)\n"
    )
    sys.exit(10)
if not isinstance(brief, str) or not brief.strip():
    sys.stderr.write("prepass.sh: cache MISS (cache file has no brief)\n")
    sys.exit(10)
# HIT — emit the cached brief verbatim (M7 injection on re-invocation).
sys.stdout.write(brief)
if not brief.endswith("\n"):
    sys.stdout.write("\n")
sys.stderr.write(f"prepass.sh: cache HIT (leaf={cur_leaf}) -> {cache_file}\n")
sys.exit(0)
PYEOF
  exit $?
fi

# ===========================================================================
# SUBCOMMAND: finalize (M4 merge / M6 pointers / M7 print / M8 cache)
# ===========================================================================
# Read the 5 extractor section JSONs from --sections <dir>, merge into ONE
# dense markdown brief (5 labeled sections, pointer-bearing, no raw tool
# output, <= line cap), recompute the leaf-uuid for the cache key, write the
# cache file, and print the brief to stdout.
if [ "$SUBCMD" = "finalize" ]; then
  if [ -z "$SECTIONS" ]; then
    echo "prepass.sh: finalize requires --sections <dir>." >&2
    usage
  fi
  if [ ! -d "$SECTIONS" ]; then
    echo "prepass.sh: --sections dir not found: $SECTIONS" >&2
    exit 1
  fi
  # Resolve the leaf-uuid (M8 cache key). FAST PATH: `prepare` already computed
  # it and the orchestrator passes it via --leaf, so we skip a full ~87 MB
  # assemble.py re-stream on the common cold path. FALLBACK: when --leaf is
  # absent (a stand-alone finalize), recompute it via compute_leaf(). Either way
  # the value is the same keep-last leaf rule (leafrule.py), so the cache key is
  # identical whichever path produced it. A finalize with no resolvable leaf
  # still produces a brief but cannot be cached — we warn and skip the write
  # rather than poison the cache with a null key.
  if [ -n "$LEAF_ARG" ]; then
    LEAF="$LEAF_ARG"
  else
    set +e
    LEAF=$(compute_leaf)
    leaf_rc=$?
    set -e
    if [ "$leaf_rc" -ne 0 ] || [ -z "$LEAF" ]; then
      echo "prepass.sh: WARNING — cannot recompute leaf-uuid for $UUID; brief will print but NOT be cached." >&2
      LEAF=""
    fi
  fi

  HANDOFF_BRIEF_MAX_LINES="${HANDOFF_BRIEF_MAX_LINES:-400}" \
  HANDOFF_CACHE_MAX_ENTRIES="${HANDOFF_CACHE_MAX_ENTRIES:-50}" \
  FINALIZE_SECTIONS="$SECTIONS" \
  FINALIZE_UUID="$UUID" \
  FINALIZE_LEAF="$LEAF" \
  FINALIZE_CACHE_DIR="$CACHE_DIR" \
  FINALIZE_CACHE_FILE="$CACHE_FILE" \
  python3 - <<'PYEOF'
import datetime
import io
import json
import os
import sys

SECTIONS = os.environ["FINALIZE_SECTIONS"]
UUID = os.environ["FINALIZE_UUID"]
LEAF = os.environ["FINALIZE_LEAF"] or None
CACHE_DIR = os.environ["FINALIZE_CACHE_DIR"]
CACHE_FILE = os.environ["FINALIZE_CACHE_FILE"]
MAX_LINES = max(1, int(os.environ.get("HANDOFF_BRIEF_MAX_LINES", "400")))


def warn(msg):
    sys.stderr.write("prepass.sh: " + msg + "\n")


def _cache_sort_key(path):
    """Chronological sort key (oldest first): payload created_at, else mtime.

    created_at is ISO-8601 'Z' (lexically chronological). A file lacking a
    parseable created_at falls back to its filesystem mtime so it still orders
    deterministically; a fully unreadable file sorts oldest (evicted first).
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        ca = data.get("created_at") if isinstance(data, dict) else None
        if isinstance(ca, str) and ca.strip():
            return ca
    except (OSError, ValueError):
        pass
    try:
        return (
            datetime.datetime.fromtimestamp(
                os.path.getmtime(path), datetime.timezone.utc
            )
            .isoformat()
            .replace("+00:00", "Z")
        )
    except OSError:
        return ""


def prune_cache(cache_dir, current_file):
    """Bound the handoff cache so it never grows without limit (M8 follow-up).

    Keep the newest HANDOFF_CACHE_MAX_ENTRIES briefs (default 50) by created_at
    and delete the rest, oldest first. The entry just written (current_file) is
    NEVER evicted. Orphan '*.tmp' files (from a crashed finalize) are swept too.

    A cached brief is a *derived* memoization of the session transcript, not the
    source — an evicted brief is simply rebuilt on the next cache MISS, so this
    never loses recoverable context. All I/O is confined to cache_dir; memory.db
    is never touched. Best-effort: every failure warns and is swallowed so cache
    pruning can never break the brief that was already produced.
    """
    raw = os.environ.get("HANDOFF_CACHE_MAX_ENTRIES", "50")
    try:
        max_entries = int(raw)
    except (TypeError, ValueError):
        warn(f"cache prune: HANDOFF_CACHE_MAX_ENTRIES={raw!r} not an int — using 50.")
        max_entries = 50
    if max_entries < 1:
        warn(f"cache prune: HANDOFF_CACHE_MAX_ENTRIES={max_entries} < 1 — using 50.")
        max_entries = 50

    try:
        if not os.path.isdir(cache_dir):
            return
        current = os.path.abspath(current_file)
        entries = []
        for name in os.listdir(cache_dir):
            path = os.path.join(cache_dir, name)
            if name.endswith(".tmp"):
                try:
                    os.remove(path)  # orphan from a crashed finalize
                except OSError:
                    pass
                continue
            if not name.endswith(".json"):
                continue
            if os.path.abspath(path) == current:
                continue  # never evict the entry we just wrote
            entries.append((_cache_sort_key(path), path))

        keep_others = max(0, max_entries - 1)  # the current entry holds one slot
        if len(entries) <= keep_others:
            return  # under the cap — stay silent
        entries.sort(key=lambda e: e[0])  # oldest first
        victims = entries[: len(entries) - keep_others]
        pruned = 0
        for _key, path in victims:
            try:
                os.remove(path)
                pruned += 1
            except FileNotFoundError:
                pass  # a concurrent worktree pruned it first
            except OSError as e:
                warn(f"cache prune: could not remove {path}: {e}")
        if pruned:
            warn(
                f"cache prune: removed {pruned} old brief(s), kept <= "
                f"{max_entries} (HANDOFF_CACHE_MAX_ENTRIES)."
            )
    except OSError as e:
        warn(f"cache prune: skipped ({e}).")


# The five M4 sections, in canonical brief order. Each entry is
# (section enum, rendered "## heading", accepted filename stems). The enum and
# the canonical filename stem are the UNDERSCORE spellings the extractors
# actually Write (SKILL.md "Section enum <-> heading <-> file" + commands/handoff.md
# Step 6 table). The heading column is the SINGLE SOURCE the warm template in
# commands/handoff.md renders the same bare "## <Heading>" from — warm and cold
# MUST render identically. Each stem list is the canonical underscore stem plus
# ONE slug-tolerant hyphen fallback, so a stray "dead-ends.json" still loads.
SECTION_SPEC = [
    ("convergence", "Convergence", ["convergence"]),
    ("dead_ends", "Dead-ends", ["dead_ends", "dead-ends"]),
    ("code_state", "Code-state", ["code_state", "code-state"]),
    ("open_threads", "Open-threads & conflicts",
     ["open_threads", "open-threads"]),
    ("basics", "Basics", ["basics"]),
]


def load_section(stems):
    """Find and parse the section JSON for the given accepted stems.

    Returns (data_dict_or_None, note). Tolerant: a missing or malformed
    section never aborts the merge (one bad extractor spawn must not sink the
    whole brief — landmine in the plan); we record a placeholder instead.
    """
    for stem in stems:
        path = os.path.join(SECTIONS, stem + ".json")
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    obj = json.load(fh)
                if isinstance(obj, dict):
                    return obj, None
                return None, f"(section file {os.path.basename(path)} was not a JSON object)"
            except (OSError, ValueError) as e:
                return None, f"(section file {os.path.basename(path)} unreadable: {e})"
    return None, "(no section file found — extractor produced no output)"


def fmt_pointer(p):
    """Render one pointer object to an inline drill-down token (M6).

    Accepts the contract shape {type, ref, note}. type in
    {transcript, commit, file}; we normalize to transcript:Lx / commit:<hash> /
    file:<symbol>, appending the optional note in parens.
    """
    if not isinstance(p, dict):
        # Allow a bare string pointer too (already-formatted).
        return str(p).strip()
    ptype = (p.get("type") or "").strip().lower()
    ref = str(p.get("ref") or "").strip()
    note = str(p.get("note") or "").strip()
    if not ref:
        token = ""
    elif ptype == "transcript":
        # ref may already be "L123" or just "123".
        r = ref if ref.lower().startswith("l") else "L" + ref
        token = f"transcript:{r}"
    elif ptype == "commit":
        token = f"commit:{ref}"
    elif ptype == "file":
        token = f"file:{ref}"
    else:
        token = ref  # unknown type: pass the ref through rather than drop it
    if note:
        return f"{token} ({note})" if token else f"({note})"
    return token


def render_pointers(pointers):
    """Return a compact ' — ptr1, ptr2' suffix, or '' if none."""
    if not isinstance(pointers, list):
        return ""
    toks = [t for t in (fmt_pointer(p) for p in pointers) if t]
    if not toks:
        return ""
    return "  ↳ " + ", ".join(toks)


def section_block(heading, data, note):
    """Render one '## heading' block from a section's {content, pointers}.

    M6: the section's pointers are attached as a drill-down line beneath the
    content so every non-trivial claim is traceable. No raw tool output is
    emitted — only the extractor's already-distilled markdown + pointer tokens.
    """
    out = [f"## {heading}"]
    if data is None:
        out.append(f"_{note}_")
        out.append("")
        return out
    content = data.get("content")
    if isinstance(content, str) and content.strip():
        out.append(content.strip())
    else:
        out.append("_(extractor returned no content for this section)_")
    ptr_line = render_pointers(data.get("pointers"))
    if ptr_line:
        out.append("")
        out.append(ptr_line)
    out.append("")
    return out


# --- assemble the brief ----------------------------------------------------
lines = []
lines.append(f"# Session handoff brief — {UUID}")
if LEAF:
    lines.append(f"_leaf-uuid: {LEAF}_")
lines.append("")

missing = []
for key, heading, stems in SECTION_SPEC:
    data, note = load_section(stems)
    if data is None:
        missing.append(key)
    lines.extend(section_block(heading, data, note))

# --- enforce the line cap (M3/M4 bound: <= MAX_LINES) ----------------------
# We truncate whole trailing lines and leave a visible marker rather than
# silently shipping an over-budget brief. Sections are ordered by importance
# (Convergence/Dead-ends first), so truncation sheds the least-critical tail.
truncated = False
if len(lines) > MAX_LINES:
    truncated = True
    keep = MAX_LINES - 1  # reserve one line for the marker
    lines = lines[:keep]
    lines.append(
        f"_[brief truncated to {MAX_LINES} lines — drill into pointers above for the full record]_"
    )

brief = "\n".join(lines).rstrip() + "\n"
brief_line_count = brief.count("\n")

# --- write the cache (M8) --------------------------------------------------
# Path: <REPO>/.claude/handoff/cache/<uuid>.json — NEVER memory.db. Keyed by
# leaf_uuid so cache-check can detect a grown session. Skip when leaf unknown.
cache_written = None
if LEAF:
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        payload = {
            "leaf_uuid": LEAF,
            "brief": brief,
            "created_at": datetime.datetime.now(datetime.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
        }
        tmp = CACHE_FILE + ".tmp"
        with io.open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, CACHE_FILE)  # atomic publish
        cache_written = CACHE_FILE
    except OSError as e:
        warn(f"WARNING — could not write cache {CACHE_FILE}: {e}")
else:
    warn("leaf-uuid unknown — brief printed but not cached (M8 key missing).")

# --- bound the cache size (retention policy) -------------------------------
# Keep .claude/handoff/cache/ from growing without limit. Safe because each
# cache file is a derived memoization of its transcript, not the source: an
# evicted brief is simply rebuilt on the next cache MISS.
if cache_written:
    prune_cache(CACHE_DIR, CACHE_FILE)

# --- print the brief to stdout (M7 cold-mode injection) --------------------
sys.stdout.write(brief)

# One-line human summary to stderr (stdout stays the brief, clean for capture).
summary = f"finalize  sections=5  missing={len(missing)}  lines={brief_line_count}/{MAX_LINES}"
if truncated:
    summary += "  [TRUNCATED]"
if cache_written:
    summary += f"  cached={cache_written}"
else:
    summary += "  cached=NO"
if missing:
    summary += f"  missing_sections={','.join(missing)}"
warn(summary)
PYEOF
  exit $?
fi

# --- (a) LOCATE canonical file ---------------------------------------------
# assemble.py locate prints the path on stdout, exit 1 + stderr if not found.
CANONICAL=""
if CANONICAL=$(python3 "$ASSEMBLE" locate "$UUID" 2>/dev/null); then
  :
else
  echo "prepass.sh: uuid not found in any transcript: $UUID" >&2
  exit 1
fi
if [ -z "$CANONICAL" ] || [ ! -f "$CANONICAL" ]; then
  echo "prepass.sh: uuid not found in any transcript: $UUID" >&2
  exit 1
fi

# --- (b) FRESHNESS guard (M9) ----------------------------------------------
# freshness.sh: exit 0 ok, exit 9 too-fresh (it prints its own warning), exit 1
# missing/usage. We mirror exit 9 and decline, per M9. Run it without `set -e`
# aborting on the non-zero exit we want to inspect.
if [ -f "$FRESHNESS" ]; then
  set +e
  sh "$FRESHNESS" check "$CANONICAL"
  fresh_rc=$?
  set -e
  if [ "$fresh_rc" -eq 9 ]; then
    echo "prepass.sh: transcript $CANONICAL is in-progress (modified < 60 s ago); declining to build a partial handoff. Try again once the session settles." >&2
    exit 9
  fi
  # rc 1 (e.g. unreadable mtime) is non-fatal here: locate already proved the
  # file exists and is readable; fall through and let assemble handle I/O.
fi

# --- (c)-(g) assemble -> pre-pass -> size-decide -> emit plan.json ----------
# Everything heavy happens inside python3 (streaming assemble output). We pass
# the env + paths in; python writes plan.json and chunk/spine files itself, and
# prints a one-line human summary to stderr.
HANDOFF_SPINE_TOKENS="${HANDOFF_SPINE_TOKENS:-120000}" \
HANDOFF_CHARS_PER_TOKEN="${HANDOFF_CHARS_PER_TOKEN:-4}" \
PREPASS_UUID="$UUID" \
PREPASS_CANONICAL="$CANONICAL" \
PREPASS_OUT="$OUT" \
PREPASS_ASSEMBLE="$ASSEMBLE" \
PREPASS_PARSE_DIR="$PARSE_DIR" \
PREPASS_SCRIPT_DIR="$SCRIPT_DIR" \
python3 - <<'PYEOF'
import io
import json
import os
import subprocess
import sys

# Make the shared parselib importable (msg_text keeps thinking blocks).
parse_dir = os.environ["PREPASS_PARSE_DIR"]
if parse_dir and parse_dir not in sys.path:
    sys.path.insert(0, parse_dir)
try:
    from parselib import msg_text, is_sidechain, edit_file_path
except Exception as e:  # pragma: no cover - exercised only if module is broken
    sys.stderr.write(f"prepass.sh: cannot import shared parselib: {e}\n")
    sys.exit(1)

# Single-source the M8 leaf rule: import keep_last_uuid from this skill dir so
# prepare and a later finalize/cache-check apply ONE identical rule (no second
# inline implementation). leafrule.py lives next to prepass.sh.
script_dir = os.environ.get("PREPASS_SCRIPT_DIR", "")
if script_dir and script_dir not in sys.path:
    sys.path.insert(0, script_dir)
try:
    from leafrule import keep_last_uuid
except Exception as e:  # pragma: no cover - exercised only if module is broken
    sys.stderr.write(f"prepass.sh: cannot import leafrule: {e}\n")
    sys.exit(1)

UUID = os.environ["PREPASS_UUID"]
CANONICAL = os.environ["PREPASS_CANONICAL"]
OUT = os.environ["PREPASS_OUT"]
ASSEMBLE = os.environ["PREPASS_ASSEMBLE"]
BUDGET_TOKENS = int(os.environ.get("HANDOFF_SPINE_TOKENS", "120000"))
CHARS_PER_TOKEN = max(1, int(os.environ.get("HANDOFF_CHARS_PER_TOKEN", "4")))
BUDGET_CHARS = BUDGET_TOKENS * CHARS_PER_TOKEN

OUT_DIR = os.path.dirname(os.path.abspath(OUT)) or "."
os.makedirs(OUT_DIR, exist_ok=True)
STEM = os.path.splitext(os.path.basename(OUT))[0] or "plan"


def warn(msg):
    sys.stderr.write("prepass.sh: " + msg + "\n")


# ---------------------------------------------------------------------------
# Stream the assembled (ordered, deduped) timeline from the shared module.
# We never read the raw 87 MB file ourselves; assemble.py streams it and emits
# one JSON object per surviving message. We read its stdout line-by-line.
# ---------------------------------------------------------------------------
proc = subprocess.Popen(
    [sys.executable, ASSEMBLE, "assemble", UUID],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def role_of(obj):
    msg = obj.get("message")
    if isinstance(msg, dict):
        r = msg.get("role")
        if r:
            return r
    t = obj.get("type")
    return t if isinstance(t, str) else "?"


def tool_uses(obj):
    """Yield (name, input_dict) for each tool_use block in this message."""
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return
    content = msg.get("content")
    if not isinstance(content, list):
        return
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            yield b.get("name") or "?", (b.get("input") if isinstance(b.get("input"), dict) else {})


def digest_input(inp):
    """A short, single-line digest of a tool input (never a payload dump)."""
    if not isinstance(inp, dict):
        return ""
    # Prefer a file path; else a command; else a compact key list.
    fp = edit_file_path(inp)
    if fp:
        return fp
    cmd = inp.get("command")
    if isinstance(cmd, str) and cmd:
        first = cmd.strip().splitlines()[0] if cmd.strip() else ""
        return (first[:160] + "…") if len(first) > 160 else first
    keys = ",".join(sorted(k for k in inp.keys()))
    return f"{{{keys}}}" if keys else ""


# ---------------------------------------------------------------------------
# PASS 1 over the assembled timeline: assign each surviving message a stable
# 1-based timeline line number L (this is the `transcript:L<n>` pointer space
# the brief uses), strip toolUseResult, and record, per Read path, the LAST L
# that reads it (for keep-last dedup) + a per-path read count. We buffer only
# the *parsed, stripped* objects — small (~3.8k msgs), the 87 MB never lands.
# ---------------------------------------------------------------------------
records = []          # list of dicts: {L, role, ts, obj}
last_read_L = {}      # path -> last L that issued a Read of it
read_count = {}       # path -> number of Reads
raw_msgs = 0
stripped_count = 0
stripped_bytes = 0
malformed = 0

L = 0
for line in proc.stdout:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        malformed += 1
        continue
    if not isinstance(obj, dict):
        malformed += 1
        continue
    raw_msgs += 1
    L += 1

    # (d) STRIP toolUseResult payload (top-level field — the byte sink).
    if "toolUseResult" in obj:
        try:
            stripped_bytes += len(json.dumps(obj["toolUseResult"]))
        except (TypeError, ValueError):
            pass
        del obj["toolUseResult"]
        stripped_count += 1

    rec = {"L": L, "role": role_of(obj), "ts": obj.get("timestamp") or "", "obj": obj}
    records.append(rec)

    for name, inp in tool_uses(obj):
        if name == "Read":
            fp = edit_file_path(inp)
            if fp:
                last_read_L[fp] = L
                read_count[fp] = read_count.get(fp, 0) + 1

proc.stdout.close()
assemble_err = proc.stderr.read()
proc.stderr.close()
rc = proc.wait()
if rc != 0:
    # assemble.py already wrote a clear stderr message (not-found / vanished).
    if assemble_err:
        sys.stderr.write(assemble_err)
    warn(f"assemble failed for uuid {UUID} (exit {rc}).")
    sys.exit(1)
# Surface any non-fatal assemble warnings (schema drift / sidechain spans).
for ln in (assemble_err or "").splitlines():
    if ln.strip():
        sys.stderr.write(ln + "\n")

if not records:
    warn(f"no messages assembled for uuid {UUID}.")
    sys.exit(1)

# ---------------------------------------------------------------------------
# (e) LEAF — cache key (M8). Apply the shared keep_last_uuid rule (leafrule.py,
# the same one compute_leaf/cache-check use) to the already-buffered records, so
# this value and a later finalize/cache-check recomputation agree by
# construction. The assembled timeline already dropped null-uuid bookkeeping
# lines; keep-last over the ordered records yields the last-message uuid.
# ---------------------------------------------------------------------------
leaf_uuid = keep_last_uuid(rec["obj"] for rec in records)

# ---------------------------------------------------------------------------
# PASS 2: render each surviving message to a compact spine record. KEEP
# thinking (msg_text). Dedup Reads: a Read of path P that is NOT the last read
# of P is replaced by a 1-line superseded pointer; the last read of P (and all
# non-Read tool calls) render in full-but-compact form. Collapse contiguous
# isSidechain runs to one pointer line (defensive no-op in real data).
# ---------------------------------------------------------------------------
spine_parts = []
deduped_reads = 0
sidechain_runs = 0
in_sidechain = False
sidechain_start_L = None

def flush_sidechain(end_L):
    """Emit a single collapsed pointer for the just-ended sidechain run."""
    global sidechain_runs
    sidechain_runs += 1
    spine_parts.append(
        f"[L{sidechain_start_L}-L{end_L}] (sidechain run collapsed — "
        f"{end_L - sidechain_start_L + 1} msgs; drill in at transcript:L{sidechain_start_L})\n"
    )

for rec in records:
    obj = rec["obj"]
    Ln = rec["L"]
    side = is_sidechain(obj)
    if side:
        if not in_sidechain:
            in_sidechain = True
            sidechain_start_L = Ln
        # While inside a sidechain run, withhold output until the run ends.
        continue
    else:
        if in_sidechain:
            in_sidechain = False
            flush_sidechain(Ln - 1)
        # fall through to render this (non-sidechain) message

    header = f"[L{Ln}] {rec['role']} {rec['ts']}".rstrip()
    body_lines = []

    msg = obj.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    text = msg_text(content) if content is not None else ""
    if text:
        body_lines.append(text)

    for name, inp in tool_uses(obj):
        if name == "Read":
            fp = edit_file_path(inp)
            if fp and last_read_L.get(fp) != Ln:
                # Superseded earlier read of this path -> 1-line pointer.
                deduped_reads += 1
                body_lines.append(
                    f"TOOL Read {fp} (superseded — latest read at transcript:L{last_read_L[fp]})"
                )
                continue
        dg = digest_input(inp)
        body_lines.append(f"TOOL {name} {dg}".rstrip())

    block = header
    if body_lines:
        block += "\n" + "\n".join(body_lines)
    spine_parts.append(block + "\n")

# A sidechain run that extends to the final message.
if in_sidechain:
    flush_sidechain(records[-1]["L"])

spine_text = "".join(spine_parts)
spine_chars = len(spine_text)
est_tokens = spine_chars // CHARS_PER_TOKEN

stats = {
    "raw_msgs": raw_msgs,
    "spine_msgs": len(records),
    "stripped_tool_results": stripped_count,
    "stripped_bytes": stripped_bytes,
    "deduped_reads": deduped_reads,
    "sidechain_runs_collapsed": sidechain_runs,
    "malformed_lines_skipped": malformed,
    "spine_chars": spine_chars,
    "est_tokens": est_tokens,
    "budget_tokens": BUDGET_TOKENS,
    "chars_per_token": CHARS_PER_TOKEN,
}

# ---------------------------------------------------------------------------
# (f) SIZE decision (M3).
# ---------------------------------------------------------------------------
plan = {
    "uuid": UUID,
    "leaf_uuid": leaf_uuid,
    "source_files": [CANONICAL],
    "stats": stats,
}

if est_tokens <= BUDGET_TOKENS:
    plan["mode"] = "direct"
    spine_path = os.path.join(OUT_DIR, f"{STEM}.spine.txt")
    with io.open(spine_path, "w", encoding="utf-8") as fh:
        fh.write(spine_text)
    plan["spine"] = os.path.abspath(spine_path)
else:
    plan["mode"] = "chunked"
    # Split into chunks that each fit the char budget, but PREFER a natural turn
    # boundary (the start of a user message) over an arbitrary token cutoff:
    # once a chunk passes a soft threshold, cut at the next user message so a
    # hypothesis -> test -> correction arc stays whole and the convergence
    # through-line survives the map step. The hard char budget is never exceeded
    # (a single oversized turn is still force-cut), preserving the "each chunk
    # fits the window" guarantee. Tunable via HANDOFF_CHUNK_SOFT_RATIO
    # (default 0.8; 1.0 restores pure budget cutting).
    try:
        soft_ratio = float(os.environ.get("HANDOFF_CHUNK_SOFT_RATIO", "0.8"))
    except ValueError:
        soft_ratio = 0.8
    soft_ratio = min(max(soft_ratio, 0.1), 1.0)
    SOFT_CHARS = int(BUDGET_CHARS * soft_ratio)

    def _block_role(part):
        # Block header is "[L<n>] <role> <ts>"; return <role> ("" if unknown).
        head = part.split("\n", 1)[0].split()
        return head[1] if len(head) >= 2 and head[0].startswith("[L") else ""

    chunks = []
    cur = []
    cur_chars = 0
    for part in spine_parts:
        plen = len(part)
        hard_cut = cur and cur_chars + plen > BUDGET_CHARS
        soft_cut = cur and cur_chars >= SOFT_CHARS and _block_role(part) == "user"
        if hard_cut or soft_cut:
            chunks.append(cur)
            cur = []
            cur_chars = 0
        cur.append(part)
        cur_chars += plen
    if cur:
        chunks.append(cur)

    chunk_meta = []
    for i, parts in enumerate(chunks):
        body = "".join(parts)
        cpath = os.path.join(OUT_DIR, f"{STEM}.chunk{i:03d}.txt")
        with io.open(cpath, "w", encoding="utf-8") as fh:
            fh.write(body)
        chunk_meta.append({
            "index": i,
            "path": os.path.abspath(cpath),
            "chars": len(body),
            "est_tokens": len(body) // CHARS_PER_TOKEN,
            "msgs": len(parts),
        })
    plan["chunks"] = chunk_meta
    stats["chunk_count"] = len(chunk_meta)

with io.open(OUT, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
    fh.write("\n")

# One-line human summary to stderr (stdout stays clean for piping the path).
if plan["mode"] == "direct":
    warn(
        f"mode=direct  msgs={len(records)}  spine~{est_tokens}tok "
        f"(<= {BUDGET_TOKENS})  stripped={stripped_count} payloads "
        f"({stripped_bytes} B)  deduped_reads={deduped_reads}  leaf={leaf_uuid}"
    )
else:
    warn(
        f"mode=chunked  msgs={len(records)}  spine~{est_tokens}tok "
        f"(> {BUDGET_TOKENS})  chunks={len(plan['chunks'])}  "
        f"stripped={stripped_count} payloads ({stripped_bytes} B)  "
        f"deduped_reads={deduped_reads}  leaf={leaf_uuid}"
    )

# stdout: the plan path (so the orchestrator can capture it).
sys.stdout.write(os.path.abspath(OUT) + "\n")
PYEOF
