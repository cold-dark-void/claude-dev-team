#!/usr/bin/env bash
# precompact-capture.sh — PreCompact rescue-capture engine (SPEC-018 M12/M14/M15/M17/M18).
#
# Invoked with the PreCompact hook JSON on stdin by .claude/hooks/precompact-rescue.sh.
# Deterministic and LLM-free by construction: bash + python3 + the existing
# prepass/transcript-parse machinery. Writes a rescue artifact
#   <repo>/.claude/handoff/<session-id>-precompact-<seq>.md
# — a spine snapshot + drill-down pointers, explicitly NOT the five-section M4
# brief (M4 quality needs a model; this is raw material for a later cold
# `/handoff <uuid>`, which stays the canonical quality path).
#
# FAIL-OPEN CONTRACT (M17): ALWAYS exits 0. Never exits 2 (2 would block the
# compaction). Every failure logs ONE stderr line and exits 0. Runtime is
# bounded via `timeout` when available (soft; degrades to unbounded).
#
# HARD BOUNDARIES (M18): no LLM invocation; no memory.db access; all writes
# confined to .claude/handoff/ (gitignored, machine-local — same isolation as
# the M8 cache).
#
# Env knobs:
#   HANDOFF_PRECOMPACT_MAX_PER_SESSION  artifacts kept per session (default 3)
#   HANDOFF_PRECOMPACT_TIMEOUT          soft prepare timeout, seconds (default 30)
#   HANDOFF_PRECOMPACT_SPINE_BYTES      spine byte cap, tail-kept (default 2000000)

set -u   # NOT -e / NOT pipefail: every failure is handled explicitly -> exit 0

fail() { echo "precompact-capture: $*" >&2; exit 0; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || fail "cannot resolve script dir"
PREPASS="$SCRIPT_DIR/prepass.sh"
[ -f "$PREPASS" ] || fail "prepass.sh not found next to capture script"
command -v python3 >/dev/null 2>&1 || fail "python3 unavailable — skipping rescue capture"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/precompact.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. Parse hook stdin JSON (bounded read; fields land as files, so values
#        with any byte content survive — command substitution drops NULs) ----
STDIN_JSON=$(head -c 65536) || fail "cannot read hook stdin"
[ -n "$STDIN_JSON" ] || fail "empty hook stdin"
printf '%s' "$STDIN_JSON" | python3 -c '
import json, os, sys
out = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
for k in ("session_id", "transcript_path", "trigger"):
    v = d.get(k, "")
    with open(os.path.join(out, k), "w", encoding="utf-8") as fh:
        fh.write(v if isinstance(v, str) else "")
' "$WORKDIR" || fail "unparseable hook stdin JSON"
SESSION_ID=$(cat "$WORKDIR/session_id")
TRANSCRIPT_PATH=$(cat "$WORKDIR/transcript_path")
TRIGGER=$(cat "$WORKDIR/trigger")
[ -n "$TRIGGER" ] || TRIGGER="unknown"

[ -n "$SESSION_ID" ] || fail "hook JSON missing session_id"
# Same charset guard as prepass.sh: the id becomes a filename component.
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*|*..*) fail "unsafe session_id: $SESSION_ID" ;;
esac
[ -n "$TRANSCRIPT_PATH" ] || fail "hook JSON missing transcript_path"
[ -f "$TRANSCRIPT_PATH" ] || fail "transcript not found: $TRANSCRIPT_PATH"

# --- 2. Repo root (worktree-aware; CLAUDE_PROJECT_DIR fallback) -------------
if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
  MROOT=$(cd -- "$(dirname -- "$_gc")" && pwd) || fail "cannot resolve repo root"
else
  MROOT="${CLAUDE_PROJECT_DIR:-}"
fi
{ [ -n "$MROOT" ] && [ -d "$MROOT" ]; } || fail "no repo root (not a git repo; CLAUDE_PROJECT_DIR unset)"
HANDOFF_DIR="$MROOT/.claude/handoff"
mkdir -p "$HANDOFF_DIR" 2>/dev/null || fail "cannot create $HANDOFF_DIR"

# --- 3. Monotonic per-session sequence (find, never bare globs) -------------
LAST_SEQ=$(find "$HANDOFF_DIR" -maxdepth 1 -name "${SESSION_ID}-precompact-*.md" 2>/dev/null \
  | sed -n 's/.*-precompact-0*\([0-9][0-9]*\)\.md$/\1/p' | sort -n | tail -1)
SEQ=$(printf '%03d' $(( ${LAST_SEQ:-0} + 1 )))
ARTIFACT="$HANDOFF_DIR/${SESSION_ID}-precompact-${SEQ}.md"

# --- 4. Deterministic pre-pass over the LIVE transcript (M12/M14) -----------
# Huge token budget forces mode=direct -> exactly one spine file (a rescue
# capture never chunk-summarizes; chunking exists for the LLM fan-out only).
PLAN="$WORKDIR/plan.json"
PREPARE_CMD=(bash "$PREPASS" prepare --uuid "$SESSION_ID" --transcript "$TRANSCRIPT_PATH" \
  --allow-in-progress --out "$PLAN")
if command -v timeout >/dev/null 2>&1; then
  PREPARE_CMD=(timeout "${HANDOFF_PRECOMPACT_TIMEOUT:-30}" "${PREPARE_CMD[@]}")
fi
if ! HANDOFF_SPINE_TOKENS=999999999 "${PREPARE_CMD[@]}" >/dev/null 2>"$WORKDIR/prepare.err"; then
  fail "prepare failed or timed out: $(tail -n 1 "$WORKDIR/prepare.err" 2>/dev/null)"
fi

# --- 5. Render the artifact (atomic tmp+replace; spine tail-capped) ---------
CAPTURE_PLAN="$PLAN" CAPTURE_ARTIFACT="$ARTIFACT" CAPTURE_SESSION="$SESSION_ID" \
CAPTURE_TRIGGER="$TRIGGER" CAPTURE_TRANSCRIPT="$TRANSCRIPT_PATH" \
CAPTURE_SPINE_BYTES="${HANDOFF_PRECOMPACT_SPINE_BYTES:-2000000}" \
python3 - <<'PYEOF' || fail "artifact render failed"
import datetime, json, os, sys

plan_path = os.environ["CAPTURE_PLAN"]
artifact = os.environ["CAPTURE_ARTIFACT"]
sid = os.environ["CAPTURE_SESSION"]
trigger = os.environ["CAPTURE_TRIGGER"]
transcript = os.environ["CAPTURE_TRANSCRIPT"]
try:
    cap = max(65536, int(os.environ.get("CAPTURE_SPINE_BYTES", "2000000")))
except ValueError:
    cap = 2000000

with open(plan_path, encoding="utf-8") as fh:
    plan = json.load(fh)
spine_path = plan.get("spine")
if not spine_path or not os.path.isfile(spine_path):
    sys.stderr.write("no spine in plan.json (unexpected chunked mode?)\n")
    sys.exit(1)

size = os.path.getsize(spine_path)
truncated = size > cap
with open(spine_path, "rb") as fh:
    if truncated:
        fh.seek(size - cap)
    body = fh.read().decode("utf-8", errors="replace")
if truncated:
    body = body.split("\n", 1)[-1]  # drop the partial first line after the seek

stats = plan.get("stats") or {}
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
head = [
    f"# PreCompact rescue artifact — session {sid}",
    "",
    f"- captured_at: {now}",
    f"- trigger: {trigger}",
    f"- transcript: {transcript}",
    f"- spine_msgs: {stats.get('spine_msgs', '?')}  stripped_tool_results: "
    f"{stats.get('stripped_tool_results', '?')}  est_tokens: {stats.get('est_tokens', '?')}",
    f"- recover: run `/handoff {sid}` in a fresh session — the cold path builds the",
    "  full five-section brief; this artifact is deterministic raw material, NOT the brief.",
]
if truncated:
    head.append(f"- NOTE: spine tail-kept at ~{cap} bytes; the full record is the transcript above.")
head += [
    "",
    "---",
    "",
    "## Spine snapshot (deterministic pre-pass output; `[L<n>]` markers are drill-down pointers)",
    "",
]
tmp = artifact + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("\n".join(head) + "\n")
    fh.write(body)
    if not body.endswith("\n"):
        fh.write("\n")
os.replace(tmp, artifact)
PYEOF

# --- 6. Bounded retention (M15): newest N per session; ONLY *-precompact-*.md
KEEP="${HANDOFF_PRECOMPACT_MAX_PER_SESSION:-3}"
case "$KEEP" in ''|*[!0-9]*|0) KEEP=3 ;; esac
find "$HANDOFF_DIR" -maxdepth 1 -name "${SESSION_ID}-precompact-*.md" 2>/dev/null \
  | sort -r | awk -v keep="$KEEP" 'NR > keep' \
  | while IFS= read -r victim; do rm -f -- "$victim"; done

# --- 7. Surfacing marker (M16 input; consumed by rescue-pointer.sh) ---------
MARKER_SESSION="$SESSION_ID" MARKER_ARTIFACT="$ARTIFACT" \
MARKER_FILE="$HANDOFF_DIR/.rescue-pointer.json" \
python3 - <<'PYEOF' || echo "precompact-capture: marker write failed (artifact still saved)" >&2
import datetime, json, os
payload = {
    "session_id": os.environ["MARKER_SESSION"],
    "artifact": os.environ["MARKER_ARTIFACT"],
    "created_at": datetime.datetime.now(datetime.timezone.utc)
    .isoformat().replace("+00:00", "Z"),
}
marker = os.environ["MARKER_FILE"]
tmp = marker + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
os.replace(tmp, marker)
PYEOF

echo "precompact-capture: rescue artifact written: $ARTIFACT (trigger=$TRIGGER, keep<=$KEEP)" >&2
exit 0
