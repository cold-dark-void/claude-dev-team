#!/usr/bin/env bash
#
# prepass.sh — /handoff deterministic pre-pass + size-adaptive spine (SPEC-018).
#
# Subcommands:
#   prepass.sh prepare     --uuid <uuid> [--out <plan.json>]
#                          [--transcript <path>] [--allow-in-progress]
#   prepass.sh cache-check --uuid <uuid>
#   prepass.sh finalize    --uuid <uuid> --events <dir|file>
#                          [--git-state <file>] [--annotations <file>]
#                          [--leaf <uuid>] [--slug <s>] [--mode cold|warm]
#                          [--print-core] [--packet-out <path>]
#                          [--spine-tokens N] [--supersedes <name>]
#
# Capture-path flags (SPEC-018 M12/M14) — warm self-mine + PreCompact only:
#   --transcript <path>     skip M1 locate; stream exactly this file
#   --allow-in-progress     soften M9 guard to warn-and-proceed
# Passed by: skills/handoff/precompact-capture.sh and warm /handoff
# (commands/handoff.md Step 1w). Cold user path MUST NOT forward either flag.
# Independent: --transcript alone still enforces M9.
#
# `prepare` — what it does (no LLM — this is the deterministic stage
# that feeds the spine-mine miners):
#   (a) LOCATE   — resolve the canonical transcript file via the shared module
#                  (skills/transcript-parse/assemble.py locate).
#   (b) FRESHNESS — M9 guard via the shared freshness.sh; if the file was
#                  modified < 60 s ago (in-progress) we REFUSE: clear message,
#                  exit 9, no partial spine.
#   (c) ASSEMBLE — get the ordered, deduped timeline (assemble.py assemble),
#                  streamed; the 87 MB+ raw file is never read by us.
#   (d) PRE-PASS — M2: strip top-level `toolUseResult` payloads (where the bulk
#                  of the bytes live), dedup repeated Reads of the same path
#                  (keep last, leave a pointer for the superseded ones), and
#                  collapse contiguous `isSidechain` runs: routine → 1-line
#                  pointer; signal-bearing (cue hit in withheld text) → condensed
#                  multi-line reconstruction (CDV-205 / M2).
#                  Defensive no-op when isSidechain is never True. `thinking`
#                  blocks are KEPT, via parselib.msg_text.
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
#   leaf_uuid equals the current leaf-uuid, print the cold core shape
#   (State now + Through-line + packet path cite when known) and exit 0
#   (HIT — the session has not grown). Otherwise exit 10 (MISS — never built,
#   or new messages were appended). Cache payload field is `packet` (STM markdown);
#   dual-reads legacy `brief` for compatibility. Cache lives under .claude/handoff/,
#   NEVER memory.db (M8 / spec).
#
# `finalize` (M3d/M7/M8) — consume miner event JSON (--events dir|file) +
#   deterministic git blob → call skills/handoff/assemble.py → write full STM
#   packet under .claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md.
#   Filename clock: local wall clock via `date +%Y%m%d-%H%M` (no Z suffix;
#   not UTC-forced — matches existing handoff artifacts).
#   Slug: sanitized to [a-z0-9-]+, ≤40, fallback `stm` (M11).
#   Supersedes (M11): when --supersedes unset, auto-discover newest prior
#   packet for the same session under HANDOFF_DIR (exclude *-precompact-*).
#   Cache stores full packet keyed by leaf-uuid (M8). Cold mode (default):
#   stdout = State now + Through-line + path cite (M7); warm mode: file-only.
#
# Exit codes (the API):
#   0  ok            prepare: plan.json written · cache-check: HIT · finalize: packet ok
#   9  too-fresh     transcript modified < 60 s ago (M9) — declined  [prepare]
#   10 cache-miss    no cached packet, or session has grown (M8)       [cache-check]
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

ASSEMBLE="$PARSE_DIR/assemble.py"           # transcript timeline assemble (prepare)
PACKET_ASSEMBLE="$SCRIPT_DIR/assemble.py"   # STM packet assemble (finalize, CDT-79)
FRESHNESS="$PARSE_DIR/freshness.sh"

# --- python3 guard ----------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "prepass.sh: python3 is required but was not found on PATH." >&2
  exit 1
fi

usage() {
  cat >&2 <<'EOF'
Usage: prepass.sh prepare     --uuid <uuid> [--out <plan.json>]
                              [--transcript <path>] [--allow-in-progress]
       prepass.sh cache-check --uuid <uuid>
       prepass.sh finalize    --uuid <uuid> --events <dir|file>
                              [--git-state <file>] [--annotations <file>]
                              [--leaf <uuid>] [--slug <s>] [--mode cold|warm]
                              [--print-core] [--packet-out <path>]
                              [--spine-tokens N] [--supersedes <name>]

  prepare      timeline assemble + pre-pass + size-decide; emits plan.json
  cache-check  exit 0 (HIT, prints cold core + path cite) / exit 10 (MISS)
  finalize     miner events + git → STM packet via assemble.py; cache; cold print

  --uuid     <uuid>   session uuid (required for all subcommands)
  --out      <path>   prepare: where to write the plan JSON (default: ./plan.json)
  --events   <path>   finalize: events JSON file OR dir of miner *.json outputs
  --git-state <file>  finalize: pre-captured git blob (else capture now, read-only)
  --annotations <file> finalize: warm annotations JSON (optional)
  --leaf     <uuid>   finalize/cache-check: leaf-uuid (M8 cache key) from prepare;
                      skip re-stream. Omitted -> recompute via transcript assemble.
  --slug     <s>      finalize: packet filename slug (default: stm)
  --mode     cold|warm  finalize: cold=print core+path (default); warm=file-only
  --print-core        finalize: force State now + Through-line stdout (cold default)
  --packet-out <path> finalize: explicit packet path (else auto under .claude/handoff/)
  --spine-tokens N    finalize: stripped spine tokens for advisory footer ratio
  --supersedes <name> finalize: prior packet filename for footer
  --transcript <path> prepare: stream exactly this file (skip locate; M12).
                      Capture path only — precompact-capture.sh.
  --allow-in-progress prepare: soften M9 freshness to warn-and-proceed (M14).
                      Capture path only; independent of --transcript.

Env:
  HANDOFF_SPINE_TOKENS        token budget for a single spine (default 120000).
                              Over budget -> chunked mode (split at msg boundaries).
  HANDOFF_CACHE_MAX_ENTRIES   max cache files under .claude/handoff/cache/ (default 50).
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

# Shared arg parse: --uuid (all), --out (prepare), finalize event/packet flags,
# --transcript / --allow-in-progress (prepare capture path only; M12/M14).
UUID=""
OUT="plan.json"
EVENTS=""
GIT_STATE=""
ANNOTATIONS=""
LEAF_ARG=""
SLUG_ARG=""
MODE="cold"
PRINT_CORE=""
PACKET_OUT=""
SPINE_TOKENS=""
SUPERSEDES=""
TRANSCRIPT=""
ALLOW_IN_PROGRESS=0
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
    --transcript)
      [ $# -ge 2 ] || usage
      TRANSCRIPT="$2"; shift 2 ;;
    --transcript=*)
      TRANSCRIPT="${1#--transcript=}"; shift ;;
    --allow-in-progress)
      ALLOW_IN_PROGRESS=1; shift ;;
    --events)
      [ $# -ge 2 ] || usage
      EVENTS="$2"; shift 2 ;;
    --events=*)
      EVENTS="${1#--events=}"; shift ;;
    --git-state)
      [ $# -ge 2 ] || usage
      GIT_STATE="$2"; shift 2 ;;
    --git-state=*)
      GIT_STATE="${1#--git-state=}"; shift ;;
    --annotations)
      [ $# -ge 2 ] || usage
      ANNOTATIONS="$2"; shift 2 ;;
    --annotations=*)
      ANNOTATIONS="${1#--annotations=}"; shift ;;
    --leaf)
      [ $# -ge 2 ] || usage
      LEAF_ARG="$2"; shift 2 ;;
    --leaf=*)
      LEAF_ARG="${1#--leaf=}"; shift ;;
    --slug)
      [ $# -ge 2 ] || usage
      SLUG_ARG="$2"; shift 2 ;;
    --slug=*)
      SLUG_ARG="${1#--slug=}"; shift ;;
    --mode)
      [ $# -ge 2 ] || usage
      MODE="$2"; shift 2 ;;
    --mode=*)
      MODE="${1#--mode=}"; shift ;;
    --print-core)
      PRINT_CORE=1; shift ;;
    --packet-out)
      [ $# -ge 2 ] || usage
      PACKET_OUT="$2"; shift 2 ;;
    --packet-out=*)
      PACKET_OUT="${1#--packet-out=}"; shift ;;
    --spine-tokens)
      [ $# -ge 2 ] || usage
      SPINE_TOKENS="$2"; shift 2 ;;
    --spine-tokens=*)
      SPINE_TOKENS="${1#--spine-tokens=}"; shift ;;
    --supersedes)
      [ $# -ge 2 ] || usage
      SUPERSEDES="$2"; shift 2 ;;
    --supersedes=*)
      SUPERSEDES="${1#--supersedes=}"; shift ;;
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

# Validate --uuid shape BEFORE any path is built from it. CACHE_FILE below is
# "$CACHE_DIR/$UUID.json"; an unconstrained UUID (e.g. "../../etc/passwd" or
# "a/b") would escape the cache dir, so reject anything that isn't a safe id.
# Allow only [A-Za-z0-9._-]; this also forbids '/' and any '..' path segment.
# (Matches the in-script validation discipline of engine.sh / worktree-lib.sh /
# task-store.sh — the guard does not live solely in the calling command.)
case "$UUID" in
  *[!A-Za-z0-9._-]*|*..*)
    echo "prepass.sh: invalid --uuid '$UUID' (allowed: letters, digits, '.', '_', '-'; no '/' or '..')." >&2
    exit 2 ;;
esac

if [ ! -f "$ASSEMBLE" ]; then
  echo "prepass.sh: shared module not found at $ASSEMBLE" >&2
  exit 1
fi

# --- shared: resolve TARGET session root + cache path (M8 / CDT-80) ---------
# Packet + M8 cache live under <TARGET_MROOT>/.claude/handoff/cache/, NOT the
# invoker's cwd. Worktree sessions share one cache via git-common-dir.
# MUST NOT live in memory.db (SPEC-018 M8).
# HANDOFF_DIR env override: isolated tests / command Step 0 export.
RESOLVE_ROOT="$SCRIPT_DIR/resolve-root.sh"
HANDOFF_DIR_FROM_ENV=0
if [ -n "${HANDOFF_DIR:-}" ]; then
  HANDOFF_DIR_FROM_ENV=1
fi
REPO_ROOT="${REPO_ROOT:-}"
PROJECT_DIR="${PROJECT_DIR:-}"
if [ "$HANDOFF_DIR_FROM_ENV" = "1" ]; then
  CACHE_DIR="$HANDOFF_DIR/cache"
  CACHE_FILE="$CACHE_DIR/$UUID.json"
else
  HANDOFF_DIR=""
  CACHE_DIR=""
  CACHE_FILE=""
fi

# ensure_target_roots [transcript]
# Resolve REPO_ROOT / HANDOFF_DIR / CACHE_* from target session.
# Returns 0 on success, 1 if undetermined. Never falls back to invoker pwd (AC4).
# Callers that write (cache-check / finalize) MUST exit 1 on failure.
ensure_target_roots() {
  # Entire body under set +e: a bare `return 1` with set -e aborts the script
  # (bash ERR-exit treats failing return as fatal). Callers re-enable set -e
  # and use `ensure_target_roots || exit 1` for fail-hard write paths.
  set +e
  local tr="${1:-}"
  local out mroot hdir pdir rc
  if [ "$HANDOFF_DIR_FROM_ENV" = "1" ]; then
    if [ -z "$REPO_ROOT" ] && [ -n "$tr" ] && [ -f "$tr" ] && [ -x "$RESOLVE_ROOT" ]; then
      if out=$(bash "$RESOLVE_ROOT" --transcript "$tr" 2>/dev/null); then
        PROJECT_DIR=$(printf '%s\n' "$out" | sed -n '1p')
        REPO_ROOT=$(printf '%s\n' "$out" | sed -n '2p')
      fi
    fi
    CACHE_DIR="$HANDOFF_DIR/cache"
    CACHE_FILE="$CACHE_DIR/$UUID.json"
    return 0
  fi
  if [ ! -x "$RESOLVE_ROOT" ]; then
    echo "prepass.sh: resolve-root.sh not found at $RESOLVE_ROOT" >&2
    return 1
  fi
  if [ -n "$tr" ] && [ -f "$tr" ]; then
    out=$(bash "$RESOLVE_ROOT" --transcript "$tr" 2>/dev/null)
    rc=$?
  else
    out=$(bash "$RESOLVE_ROOT" --uuid "$UUID" 2>/dev/null)
    rc=$?
  fi
  if [ "${rc:-1}" -ne 0 ] || [ -z "$out" ]; then
    echo "prepass.sh: cannot resolve target handoff root for uuid $UUID (no invoker-cwd fallback; CDT-80 AC4)" >&2
    return 1
  fi
  pdir=$(printf '%s\n' "$out" | sed -n '1p')
  mroot=$(printf '%s\n' "$out" | sed -n '2p')
  hdir=$(printf '%s\n' "$out" | sed -n '3p')
  if [ -z "$mroot" ] || [ -z "$hdir" ]; then
    echo "prepass.sh: resolve-root returned empty MROOT/HANDOFF_DIR" >&2
    return 1
  fi
  PROJECT_DIR="$pdir"
  REPO_ROOT="$mroot"
  HANDOFF_DIR="$hdir"
  CACHE_DIR="$HANDOFF_DIR/cache"
  CACHE_FILE="$CACHE_DIR/$UUID.json"
  return 0
}

# capture_git_state — deterministic appendix code-state blob (SPEC-018 AC-8).
# Read-only git from TARGET REPO_ROOT; no LLM. Writes text to $1.
# Non-git target: empty sections (git -C fails soft).
capture_git_state() {
  local out="$1"
  local root="${REPO_ROOT:-}"
  {
    echo "### git log --oneline -n 30"
    if [ -n "$root" ]; then
      git -C "$root" log --oneline -n 30 2>/dev/null || true
    fi
    echo
    echo "### git status --porcelain"
    if [ -n "$root" ]; then
      git -C "$root" status --porcelain 2>/dev/null || true
    fi
    echo
    echo "### git diff --stat HEAD"
    if [ -n "$root" ]; then
      git -C "$root" diff --stat HEAD 2>/dev/null || true
    fi
    echo
    echo "### git diff --stat"
    if [ -n "$root" ]; then
      git -C "$root" diff --stat 2>/dev/null || true
    fi
  } >"$out"
}

# sanitize_slug — M11: [a-z0-9-]+ only, ≤40 chars; empty → stm
sanitize_slug() {
  local s="$1"
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
  s=$(printf '%s' "$s" | cut -c1-40)
  [ -n "$s" ] || s="stm"
  printf '%s' "$s"
}

# discover_supersedes <handoff_dir> <session_uuid> [exclude_basename]
# Newest prior packet for this session (mtime, then filename desc). Prints
# basename only; empty if none. Skips PreCompact rescues named
# <session_id>-precompact-<n>.md (not STM packets) and optional exclude.
discover_supersedes() {
  local dir="$1" uuid="$2" exclude="${3:-}"
  local f m base best_m=-1 best_base=""
  [ -d "$dir" ] || return 0
  # Null-delimited; uuid charset is session-id safe (caller-owned).
  while IFS= read -r -d '' f; do
    base=$(basename -- "$f")
    # Rescue artifacts only: exact "${uuid}-precompact-*" (no YYYYMMDD-HHmm prefix).
    # Do NOT match session ids that merely contain the substring "precompact".
    case "$base" in
      "${uuid}-precompact-"*) continue ;;
    esac
    [ -n "$exclude" ] && [ "$base" = "$exclude" ] && continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ] || { [ "$m" -eq "$best_m" ] && [ "$base" \> "$best_base" ]; }; then
      best_m=$m
      best_base=$base
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "*-${uuid}-*.md" -print0 2>/dev/null)
  if [ -n "$best_base" ]; then
    printf '%s' "$best_base"
  fi
}

# compute_leaf — recompute the current leaf-uuid for UUID by streaming the
# assembled (timestamp-ordered) timeline and applying the shared keep_last_uuid
# rule (skills/handoff/leafrule.py). This is byte-identical to `prepare`'s leaf
# computation (SAME imported rule, same ordered input), so a brief built by
# `prepare`/`finalize` and a later `cache-check` agree on the M8 key. Prints leaf
# to stdout, exit 0; on uuid-not-found / assemble failure prints nothing and
# returns non-zero.
compute_leaf() {
  PREPASS_ASSEMBLE="$ASSEMBLE" PREPASS_UUID="$UUID" PREPASS_SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PYEOF'
import json, os, subprocess, sys, threading

# Import the single-source leaf rule (keep_last_uuid) from this skill dir.
sys.path.insert(0, os.environ["PREPASS_SCRIPT_DIR"])
from leafrule import keep_last_uuid

ASSEMBLE = os.environ["PREPASS_ASSEMBLE"]
UUID = os.environ["PREPASS_UUID"]

proc = subprocess.Popen(
    [sys.executable, ASSEMBLE, "assemble", UUID],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
)

# Drain stderr concurrently so a stderr flood cannot fill the pipe buffer and
# deadlock while we still consume stdout (stdout-then-stderr was latent-risk).
err_chunks = []
def _drain_err():
    try:
        err_chunks.append(proc.stderr.read())
    except Exception:
        err_chunks.append("")
err_thread = threading.Thread(target=_drain_err, daemon=True)
err_thread.start()

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
err_thread.join()
err = err_chunks[0] if err_chunks else ""
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
# cache file. Match -> print cold core (State now + Through-line) + path cite,
# exit 0 (HIT). Otherwise exit 10 (MISS: never built, grown session, or bad cache).
if [ "$SUBCMD" = "cache-check" ]; then
  # Target root first (CDT-80) — cache lives under target MROOT, not invoker cwd.
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    ensure_target_roots "$TRANSCRIPT" || { set -e; exit 1; }
  else
    ensure_target_roots || { set -e; exit 1; }
  fi
  set -e
  if [ ! -f "$CACHE_FILE" ]; then
    echo "prepass.sh: cache MISS (no cache file: $CACHE_FILE)" >&2
    exit 10
  fi
  # Optional --leaf: orchestrator/tests pass prepare's leaf to skip re-stream.
  if [ -n "$LEAF_ARG" ]; then
    CUR_LEAF="$LEAF_ARG"
  else
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
  fi
  # Dual-read packet (preferred) / brief (legacy). All I/O under $CACHE_FILE.
  CACHE_FILE="$CACHE_FILE" CUR_LEAF="$CUR_LEAF" \
  PACKET_ASSEMBLE="$PACKET_ASSEMBLE" python3 - <<'PYEOF'
import json, os, sys

cache_file = os.environ["CACHE_FILE"]
cur_leaf = os.environ["CUR_LEAF"]
sys.path.insert(0, os.path.dirname(os.environ["PACKET_ASSEMBLE"]))
from assemble import extract_core  # noqa: E402

try:
    with open(cache_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as e:
    sys.stderr.write(f"prepass.sh: cache MISS (unreadable cache: {e})\n")
    sys.exit(10)
if not isinstance(data, dict):
    sys.stderr.write("prepass.sh: cache MISS (cache file not a JSON object)\n")
    sys.exit(10)
stored_leaf = data.get("leaf_uuid")
# Prefer STM packet field; dual-read legacy `brief` (pre-CDT-79).
packet = data.get("packet")
if not isinstance(packet, str) or not packet.strip():
    packet = data.get("brief")
path = data.get("path") if isinstance(data.get("path"), str) else ""
if not stored_leaf or stored_leaf != cur_leaf:
    sys.stderr.write(
        f"prepass.sh: cache MISS (leaf changed: stored={stored_leaf} "
        f"current={cur_leaf}; session has grown)\n"
    )
    sys.exit(10)
if not isinstance(packet, str) or not packet.strip():
    sys.stderr.write("prepass.sh: cache MISS (cache file has no packet/brief)\n")
    sys.exit(10)
# HIT — cold core shape (M7): State now + Through-line; cite path for appendix.
if "## State now" in packet or "## Through-line" in packet:
    core = extract_core(packet)
else:
    # Legacy five-section brief: emit as-is (compat).
    core = packet if packet.endswith("\n") else packet + "\n"
sys.stdout.write(core if core.endswith("\n") else core + "\n")
if path.strip():
    sys.stdout.write(f"Full packet (appendix): {path.strip()}\n")
sys.stderr.write(f"prepass.sh: cache HIT (leaf={cur_leaf}) -> {cache_file}\n")
sys.exit(0)
PYEOF
  exit $?
fi

# ===========================================================================
# SUBCOMMAND: finalize (M3d assemble / M7 cold print / M8 cache)
# ===========================================================================
# Miner event JSON + deterministic git → skills/handoff/assemble.py → STM packet
# file + cache. Cold stdout = State now + Through-line + path cite (not full appendix).
if [ "$SUBCMD" = "finalize" ]; then
  if [ -z "$EVENTS" ]; then
    echo "prepass.sh: finalize requires --events <dir|file>." >&2
    usage
  fi
  if [ ! -e "$EVENTS" ]; then
    echo "prepass.sh: --events path not found: $EVENTS" >&2
    exit 1
  fi
  if [ ! -f "$PACKET_ASSEMBLE" ]; then
    echo "prepass.sh: packet assemble not found at $PACKET_ASSEMBLE" >&2
    exit 1
  fi
  case "$MODE" in
    cold|warm) ;;
    *)
      echo "prepass.sh: --mode must be cold or warm (got: $MODE)" >&2
      exit 1 ;;
  esac

  # Target handoff root (CDT-80). HANDOFF_DIR env (tests / command Step 0) wins;
  # else resolve from --transcript or locate --uuid. Fail hard if undetermined.
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    ensure_target_roots "$TRANSCRIPT" || { set -e; exit 1; }
  else
    ensure_target_roots || { set -e; exit 1; }
  fi
  set -e

  # Resolve leaf-uuid (M8). Fast path: orchestrator passes --leaf from prepare.
  # Fallback: recompute via compute_leaf(). No leaf → packet still written, not cached.
  if [ -n "$LEAF_ARG" ]; then
    LEAF="$LEAF_ARG"
  else
    set +e
    LEAF=$(compute_leaf)
    leaf_rc=$?
    set -e
    if [ "$leaf_rc" -ne 0 ] || [ -z "$LEAF" ]; then
      echo "prepass.sh: WARNING — cannot recompute leaf-uuid for $UUID; packet will write but NOT be cached." >&2
      LEAF=""
    fi
  fi

  # Git blob: use provided file or capture deterministically into a temp.
  GIT_TMP=""
  if [ -n "$GIT_STATE" ]; then
    if [ ! -f "$GIT_STATE" ]; then
      echo "prepass.sh: --git-state file not found: $GIT_STATE" >&2
      exit 1
    fi
    GIT_BLOB="$GIT_STATE"
  else
    GIT_TMP=$(mktemp "${TMPDIR:-/tmp}/handoff-git.XXXXXX")
    capture_git_state "$GIT_TMP"
    GIT_BLOB="$GIT_TMP"
  fi

  # Slug + packet path (M11): .claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md
  # Clock = local wall time (no Z). Slug charset [a-z0-9-]+ via sanitize_slug.
  # Same-minute re-capture: never overwrite — append -N before .md (M11 new file).
  SLUG=$(sanitize_slug "${SLUG_ARG:-stm}")
  if [ -n "$PACKET_OUT" ]; then
    PACKET_PATH="$PACKET_OUT"
  else
    TS=$(date +%Y%m%d-%H%M)   # local wall clock; not UTC-forced
    mkdir -p "$HANDOFF_DIR"
    PACKET_PATH="$HANDOFF_DIR/${TS}-${UUID}-${SLUG}.md"
    if [ -e "$PACKET_PATH" ]; then
      n=2
      while [ -e "$HANDOFF_DIR/${TS}-${UUID}-${SLUG}-${n}.md" ]; do
        n=$((n + 1))
      done
      PACKET_PATH="$HANDOFF_DIR/${TS}-${UUID}-${SLUG}-${n}.md"
    fi
  fi
  PACKET_DIR=$(dirname -- "$PACKET_PATH")
  mkdir -p "$PACKET_DIR"

  # Supersedes (M11): explicit --supersedes wins; else newest same-session tip.
  # Scan HANDOFF_DIR even when --packet-out is set (warm re-capture tip).
  if [ -z "$SUPERSEDES" ]; then
    SUPERSEDES=$(discover_supersedes "$HANDOFF_DIR" "$UUID" "$(basename -- "$PACKET_PATH")")
  fi

  # Cold default prints core; warm is file-only unless --print-core forced.
  DO_PRINT_CORE=0
  if [ "$PRINT_CORE" = "1" ]; then
    DO_PRINT_CORE=1
  elif [ "$MODE" = "cold" ]; then
    DO_PRINT_CORE=1
  fi

  ASM_ARGS=(
    --events "$EVENTS"
    --git "$GIT_BLOB"
    --session-uuid "$UUID"
    --slug "$SLUG"
    --mode "$MODE"
    --out "$PACKET_PATH"
  )
  [ -n "$LEAF" ] && ASM_ARGS+=(--leaf-uuid "$LEAF")
  [ -n "$ANNOTATIONS" ] && ASM_ARGS+=(--annotations "$ANNOTATIONS")
  [ -n "$SPINE_TOKENS" ] && ASM_ARGS+=(--spine-tokens "$SPINE_TOKENS")
  [ -n "$SUPERSEDES" ] && ASM_ARGS+=(--supersedes "$SUPERSEDES")
  [ "$DO_PRINT_CORE" = "1" ] && ASM_ARGS+=(--print-core)

  set +e
  python3 "$PACKET_ASSEMBLE" "${ASM_ARGS[@]}"
  asm_rc=$?
  set -e
  if [ -n "$GIT_TMP" ]; then
    rm -f "$GIT_TMP"
  fi
  if [ "$asm_rc" -ne 0 ]; then
    echo "prepass.sh: assemble.py failed (rc=$asm_rc)" >&2
    exit 1
  fi
  if [ ! -f "$PACKET_PATH" ]; then
    echo "prepass.sh: assemble.py did not write packet: $PACKET_PATH" >&2
    exit 1
  fi

  # Cache full packet (M8). Field `packet` preferred; readers dual-read packet||brief.
  HANDOFF_CACHE_MAX_ENTRIES="${HANDOFF_CACHE_MAX_ENTRIES:-50}" \
  FINALIZE_UUID="$UUID" \
  FINALIZE_LEAF="$LEAF" \
  FINALIZE_CACHE_DIR="$CACHE_DIR" \
  FINALIZE_CACHE_FILE="$CACHE_FILE" \
  FINALIZE_PACKET_PATH="$PACKET_PATH" \
  FINALIZE_MODE="$MODE" \
  python3 - <<'PYEOF'
import datetime
import io
import json
import os
import sys

UUID = os.environ["FINALIZE_UUID"]
LEAF = os.environ["FINALIZE_LEAF"] or None
CACHE_DIR = os.environ["FINALIZE_CACHE_DIR"]
CACHE_FILE = os.environ["FINALIZE_CACHE_FILE"]
PACKET_PATH = os.environ["FINALIZE_PACKET_PATH"]
MODE = os.environ.get("FINALIZE_MODE", "cold")


def warn(msg):
    sys.stderr.write("prepass.sh: " + msg + "\n")


def _cache_sort_key(path):
    """Chronological sort key (oldest first): payload created_at, else mtime."""
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
    """Bound handoff cache (M8 follow-up). Keep newest N; never evict current."""
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
                    os.remove(path)
                except OSError:
                    pass
                continue
            if not name.endswith(".json"):
                continue
            if os.path.abspath(path) == current:
                continue
            entries.append((_cache_sort_key(path), path))

        keep_others = max(0, max_entries - 1)
        if len(entries) <= keep_others:
            return
        entries.sort(key=lambda e: e[0])
        victims = entries[: len(entries) - keep_others]
        pruned = 0
        for _key, path in victims:
            try:
                os.remove(path)
                pruned += 1
            except FileNotFoundError:
                pass
            except OSError as e:
                warn(f"cache prune: could not remove {path}: {e}")
        if pruned:
            warn(
                f"cache prune: removed {pruned} old packet cache(s), kept <= "
                f"{max_entries} (HANDOFF_CACHE_MAX_ENTRIES)."
            )
    except OSError as e:
        warn(f"cache prune: skipped ({e}).")


try:
    with open(PACKET_PATH, "r", encoding="utf-8") as fh:
        packet = fh.read()
except OSError as e:
    warn(f"WARNING — could not read packet for cache: {e}")
    packet = None

cache_written = None
if LEAF and packet is not None:
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        payload = {
            "leaf_uuid": LEAF,
            "packet": packet,
            "path": os.path.abspath(PACKET_PATH),
            "created_at": datetime.datetime.now(datetime.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
        }
        tmp = CACHE_FILE + ".tmp"
        with io.open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, CACHE_FILE)
        cache_written = CACHE_FILE
    except OSError as e:
        warn(f"WARNING — could not write cache {CACHE_FILE}: {e}")
elif not LEAF:
    warn("leaf-uuid unknown — packet written but not cached (M8 key missing).")

if cache_written:
    prune_cache(CACHE_DIR, CACHE_FILE)

# Summary on stderr only (stdout owned by assemble --print-core or silent warm).
lines = packet.count("\n") if packet else 0
summary = (
    f"finalize  mode={MODE}  packet={os.path.abspath(PACKET_PATH)}  "
    f"lines={lines}"
)
if cache_written:
    summary += f"  cached={cache_written}"
else:
    summary += "  cached=NO"
warn(summary)
sys.exit(0)
PYEOF
  exit $?
fi

# --- (a) LOCATE canonical file ---------------------------------------------
# PreCompact capture path (M12): --transcript names the exact live file; M1
# locate is skipped. Only precompact-capture.sh passes this flag.
CANONICAL=""
if [ -n "$TRANSCRIPT" ]; then
  if [ ! -f "$TRANSCRIPT" ]; then
    echo "prepass.sh: --transcript file not found: $TRANSCRIPT" >&2
    exit 1
  fi
  CANONICAL="$TRANSCRIPT"
else
  # assemble.py locate prints the path on stdout, exit 1 + stderr if not found.
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
fi

# Target root after locate (CDT-80). Prepare does not write packets — soft on
# undetermined (fixtures / synthetic transcripts without cwd). Finalize/cache
# fail hard. Never invent invoker cwd as write root.
ensure_target_roots "$CANONICAL" || true
set -e

# --- (b) FRESHNESS guard (M9) ----------------------------------------------
# freshness.sh: exit 0 ok, exit 9 too-fresh (it prints its own warning), exit 1
# missing/usage. We mirror exit 9 and decline, per M9. Run it without `set -e`
# aborting on the non-zero exit we want to inspect.
# --allow-in-progress (M14): append flag so freshness warn-and-proceeds.
if [ -f "$FRESHNESS" ]; then
  FRESH_FLAG=""
  [ "$ALLOW_IN_PROGRESS" = "1" ] && FRESH_FLAG="--allow-in-progress"
  set +e
  # shellcheck disable=SC2086  # FRESH_FLAG empty-or-one-token by design
  sh "$FRESHNESS" check "$CANONICAL" $FRESH_FLAG
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
PREPASS_FROM_FILE="$([ -n "$TRANSCRIPT" ] && echo 1 || echo 0)" \
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
    from parselib import (
        msg_text,
        is_sidechain,
        edit_file_path,
        sidechain_cue_hit,
    )
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
# PreCompact capture path: assemble-file <path> skips locate (M12).
# ---------------------------------------------------------------------------
if os.environ.get("PREPASS_FROM_FILE") == "1":
    assemble_args = [sys.executable, ASSEMBLE, "assemble-file", CANONICAL]
else:
    assemble_args = [sys.executable, ASSEMBLE, "assemble", UUID]
proc = subprocess.Popen(
    assemble_args,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

# Drain stderr concurrently — stdout-then-stderr can deadlock if stderr fills
# the OS pipe buffer while stdout is still being consumed.
import threading
err_chunks = []
def _drain_err():
    try:
        err_chunks.append(proc.stderr.read())
    except Exception:
        err_chunks.append("")
err_thread = threading.Thread(target=_drain_err, daemon=True)
err_thread.start()


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
err_thread.join()
assemble_err = err_chunks[0] if err_chunks else ""
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
# isSidechain runs: routine → one pointer line; signal-bearing (cue hit in
# withheld msg_text) → condensed multi-line reconstruction (CDV-205 / M2).
# Defensive no-op in real data where isSidechain is never True.
# ---------------------------------------------------------------------------
spine_parts = []
deduped_reads = 0
sidechain_runs_collapsed = 0
sidechain_runs_signal = 0
in_sidechain = False
sidechain_start_L = None
sidechain_buf = []  # list of {role, text} for the open sidechain run
SIDECHAIN_BLOCK_CAP = 400
HYP_CAP = 120
KILLED_CAP = 160

def _clip(s, n):
    s = (s or "").replace("\n", " ").strip()
    if len(s) <= n:
        return s
    return s[: max(0, n - 1)] + "…"

def flush_sidechain(end_L):
    """Emit noise one-liner or signal-bearing condensed reconstruction."""
    global sidechain_runs_collapsed, sidechain_runs_signal
    n_msgs = end_L - sidechain_start_L + 1
    # Scan withheld texts for the first cue hit (MVP: any single cue).
    killed_cue = None
    killed_line = None
    killed_role = None
    for entry in sidechain_buf:
        hit = sidechain_cue_hit(entry["text"])
        if hit is not None:
            killed_cue, killed_line = hit
            killed_role = entry["role"]
            break

    if killed_cue is None:
        sidechain_runs_collapsed += 1
        spine_parts.append(
            f"[L{sidechain_start_L}-L{end_L}] (sidechain run collapsed — "
            f"{n_msgs} msgs; drill in at transcript:L{sidechain_start_L})\n"
        )
    else:
        sidechain_runs_signal += 1
        # hypothesis: first non-empty assistant text, else "(unstated)"
        hyp = "(unstated)"
        for entry in sidechain_buf:
            if entry["role"] == "assistant" and entry["text"].strip():
                hyp = _clip(entry["text"], HYP_CAP)
                break
        killed = _clip(killed_line or killed_cue, KILLED_CAP)
        # notes: compact tags from cue/role (no freeform dump)
        notes_bits = []
        low = (killed_line or "").lower()
        if killed_role == "user":
            notes_bits.append("user correction")
        if any(k in low for k in ("abandoned", "dead end", "scratch that", "wrong approach")):
            notes_bits.append("abandoned investigation")
        if not notes_bits:
            notes_bits.append("rejected path")
        notes = " | ".join(notes_bits)
        block = (
            f"[L{sidechain_start_L}-L{end_L}] (sidechain signal — "
            f"{n_msgs} msgs; transcript:L{sidechain_start_L})\n"
            f"  hypothesis: {hyp}\n"
            f"  killed: {killed}\n"
            f"  notes: {notes}\n"
        )
        if len(block) > SIDECHAIN_BLOCK_CAP:
            block = block[: SIDECHAIN_BLOCK_CAP - 1] + "…\n"
        spine_parts.append(block)
    sidechain_buf.clear()

for rec in records:
    obj = rec["obj"]
    Ln = rec["L"]
    side = is_sidechain(obj)
    if side:
        if not in_sidechain:
            in_sidechain = True
            sidechain_start_L = Ln
        # Withhold full render; buffer text only (no tool payloads).
        msg = obj.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        text = msg_text(content) if content is not None else ""
        sidechain_buf.append({"role": rec["role"], "text": text or ""})
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
    "sidechain_runs_collapsed": sidechain_runs_collapsed,
    "sidechain_runs_signal": sidechain_runs_signal,
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
    # through-line survives the map step. A single oversized turn is force-cut
    # at line boundaries so the hard char budget is honored (a single line
    # longer than the budget is emitted whole with a warn — no mid-line cut).
    # Tunable via HANDOFF_CHUNK_SOFT_RATIO (default 0.8; 1.0 = pure budget cut).
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

    def _force_split(text, budget):
        """Split text into pieces each <= budget at line boundaries.
        A single line longer than budget is emitted whole (with warn)."""
        pieces = []
        piece_lines = []
        piece_chars = 0
        for ln in text.splitlines(keepends=True):
            if piece_lines and piece_chars + len(ln) > budget:
                pieces.append("".join(piece_lines))
                piece_lines = []
                piece_chars = 0
            if not piece_lines and len(ln) > budget:
                warn(
                    f"chunk force-cut: single line ({len(ln)} chars) exceeds "
                    f"budget ({budget}); emitting oversize piece"
                )
                pieces.append(ln)
                continue
            piece_lines.append(ln)
            piece_chars += len(ln)
        if piece_lines:
            pieces.append("".join(piece_lines))
        return pieces if pieces else [text]

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
        if plen > BUDGET_CHARS:
            # Force-cut oversized single turn at line boundaries.
            for piece in _force_split(part, BUDGET_CHARS):
                if cur and cur_chars + len(piece) > BUDGET_CHARS:
                    chunks.append(cur)
                    cur = []
                    cur_chars = 0
                cur.append(piece)
                cur_chars += len(piece)
                if cur_chars >= BUDGET_CHARS:
                    chunks.append(cur)
                    cur = []
                    cur_chars = 0
            continue
        cur.append(part)
        cur_chars += plen
    if cur:
        chunks.append(cur)

    chunk_meta = []
    for i, parts in enumerate(chunks):
        body = "".join(parts)
        if len(body) > BUDGET_CHARS:
            warn(
                f"chunk {i} is {len(body)} chars (budget {BUDGET_CHARS}); "
                f"oversize after force-cut (single-line residue)"
            )
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
