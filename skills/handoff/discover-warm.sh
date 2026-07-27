#!/usr/bin/env bash
#
# discover-warm.sh — resolve this-session id + live JSONL for warm /handoff
# (SPEC-018 M10 / CDT-79-6 / CDT-85 session-id bridge).
#
# Usage:
#   discover-warm.sh
#     Prints two lines on stdout:
#       <session_id>
#       <absolute_transcript_path>
#     Exit 0 on success; exit 1 with clear stderr on failure.
#
# Session id precedence:
#   1. $CLAUDE_SESSION_ID (non-empty)
#   2. $SESSION_ID (non-empty)
#   3. Bridge file ($HANDOFF_BRIDGE or $HANDOFF_DIR/.live-session.json) session_id
#   4. Basename stem of $CLAUDE_TRANSCRIPT_PATH / $TRANSCRIPT_PATH when *.jsonl
#   5. Newest-mtime *.jsonl under encoded project dir for live cwd (Claude bridge)
#   6. fail — clear diagnostic; never freeform live-context
#
# Transcript path precedence:
#   1. $CLAUDE_TRANSCRIPT_PATH if set and is a regular file
#   2. $TRANSCRIPT_PATH if set and is a regular file
#   3. Bridge file transcript_path when file still exists
#   4. Newest-mtime match of ${CLAUDE_PROJECTS_DIR:-~/.claude/projects}/*/<id>.jsonl
#   5. skills/transcript-parse/assemble.py locate <id>
#   6. fail
#
# On success (best-effort): writes session-id bridge JSON so cold re-capture
# of the same session can supersede (filename + header already carry the id).
#   Bridge path: $HANDOFF_BRIDGE, else $HANDOFF_DIR/.live-session.json,
#   else resolve-root --transcript → HANDOFF_DIR/.live-session.json
#
# Test overrides:
#   CLAUDE_PROJECTS_DIR   — projects root (default ~/.claude/projects)
#   DISCOVER_ASSEMBLE     — path to assemble.py for locate fallback
#   DISCOVER_RESOLVE_ROOT — path to resolve-root.sh for bridge write
#   HANDOFF_BRIDGE        — explicit bridge file path (read + write)
#   HANDOFF_DIR           — handoff dir (bridge = $HANDOFF_DIR/.live-session.json)
#   CLAUDE_CWD            — live cwd for project-dir encoding (default: pwd)
#
# Does NOT pass --allow-in-progress; callers (warm command only) own that flag.
# Does NOT invent freeform STM packets when discovery fails (CDT-85 honesty).

set -eu

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

bridge_path() {
  if [ -n "${HANDOFF_BRIDGE:-}" ]; then
    printf '%s' "$HANDOFF_BRIDGE"
    return 0
  fi
  if [ -n "${HANDOFF_DIR:-}" ]; then
    printf '%s' "${HANDOFF_DIR%/}/.live-session.json"
    return 0
  fi
  return 1
}

# Read session_id (line1) + transcript_path (line2) from bridge JSON. Empty → miss.
read_bridge() {
  local bp out
  bp=$(bridge_path 2>/dev/null) || return 1
  [ -f "$bp" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  out=$(BRIDGE_FILE="$bp" python3 - <<'PY'
import json, os, re, sys
try:
    with open(os.environ["BRIDGE_FILE"], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
sid = d.get("session_id") or ""
tp = d.get("transcript_path") or ""
if not isinstance(sid, str) or not sid.strip():
    sys.exit(1)
if not isinstance(tp, str):
    tp = ""
if not re.fullmatch(r"[A-Za-z0-9._-]+", sid):
    sys.exit(1)
# Two lines; path may be empty.
sys.stdout.write(sid + "\n" + tp + "\n")
PY
) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  # ensure trailing newline if python omitted last
  case "$out" in
    *$'\n') ;;
    *) printf '\n' ;;
  esac
}

write_bridge() {
  local sid="$1" tr="$2"
  local bp="" hdir="" root_out="" resolve=""

  if bp=$(bridge_path 2>/dev/null); then
    :
  else
    # Best-effort: resolve HANDOFF_DIR from transcript (CDT-80 root).
    resolve="${DISCOVER_RESOLVE_ROOT:-}"
    if [ -z "$resolve" ] && [ -f "$HERE/resolve-root.sh" ]; then
      resolve="$HERE/resolve-root.sh"
    fi
    if [ -n "$resolve" ] && [ -f "$resolve" ] && [ -f "$tr" ]; then
      root_out=$(bash "$resolve" --transcript "$tr" 2>/dev/null) || root_out=""
      hdir=$(printf '%s\n' "$root_out" | sed -n '3p')
      if [ -n "$hdir" ]; then
        bp="${hdir%/}/.live-session.json"
      fi
    fi
  fi
  [ -n "$bp" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname -- "$bp")" 2>/dev/null || return 0
  BRIDGE_FILE="$bp" BRIDGE_SID="$sid" BRIDGE_TR="$tr" python3 - <<'PY' 2>/dev/null || true
import datetime, json, os
path = os.environ["BRIDGE_FILE"]
payload = {
    "session_id": os.environ["BRIDGE_SID"],
    "transcript_path": os.environ["BRIDGE_TR"],
    "updated_at": datetime.datetime.now(datetime.timezone.utc)
    .isoformat()
    .replace("+00:00", "Z"),
    "source": "discover-warm",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

# Newest *.jsonl under encoded project dir for live cwd. Prints sid\npath or empty.
cwd_newest_jsonl() {
  local cwd enc pdir f m best_m=-1 best_p="" base
  cwd="${CLAUDE_CWD:-}"
  if [ -z "$cwd" ]; then
    cwd=$(pwd 2>/dev/null || true)
  fi
  [ -n "$cwd" ] || return 0
  # Prefer absolute path for encoding (Claude uses abs path with / → -).
  if command -v realpath >/dev/null 2>&1; then
    cwd=$(realpath -- "$cwd" 2>/dev/null || printf '%s' "$cwd")
  fi
  enc=$(printf '%s' "$cwd" | sed 's|/|-|g')
  pdir="$PROJECTS_DIR/$enc"
  [ -d "$pdir" ] || return 0
  while IFS= read -r -d '' f; do
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ]; then
      best_m=$m
      best_p=$f
    fi
  done < <(find "$pdir" -maxdepth 1 -type f -name '*.jsonl' -print0 2>/dev/null)
  if [ -n "$best_p" ] && [ -f "$best_p" ]; then
    base=$(basename -- "$best_p")
    printf '%s\n%s\n' "${base%.jsonl}" "$best_p"
  fi
}

resolve_session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_SESSION_ID"
    return 0
  fi
  if [ -n "${SESSION_ID:-}" ]; then
    printf '%s' "$SESSION_ID"
    return 0
  fi
  # Bridge file (CDT-85) — prior warm discover or agent-written live tip.
  local br_sid br_rest
  if br_rest=$(read_bridge 2>/dev/null); then
    br_sid=$(printf '%s\n' "$br_rest" | sed -n '1p')
    if [ -n "$br_sid" ]; then
      printf '%s' "$br_sid"
      return 0
    fi
  fi
  local tp="${CLAUDE_TRANSCRIPT_PATH:-${TRANSCRIPT_PATH:-}}"
  if [ -n "$tp" ]; then
    local base
    base=$(basename -- "$tp")
    case "$base" in
      *.jsonl)
        printf '%s' "${base%.jsonl}"
        return 0
        ;;
    esac
  fi
  # Claude Code without env: newest JSONL for this project cwd (session-id bridge).
  local cn_out cn_sid
  if cn_out=$(cwd_newest_jsonl 2>/dev/null); then
    cn_sid=$(printf '%s\n' "$cn_out" | sed -n '1p')
    if [ -n "$cn_sid" ]; then
      printf '%s' "$cn_sid"
      return 0
    fi
  fi
  return 1
}

# Newest mtime among stem matches under projects dir. Empty → not found.
stem_newest() {
  local sid="$1"
  local f m best_m=-1 best_p=""
  [ -d "$PROJECTS_DIR" ] || return 0
  # Null-delimited find: sid is charset-guarded by caller before this runs.
  while IFS= read -r -d '' f; do
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ]; then
      best_m=$m
      best_p=$f
    fi
  done < <(find "$PROJECTS_DIR" -type f -name "${sid}.jsonl" -print0 2>/dev/null)
  if [ -n "$best_p" ] && [ -f "$best_p" ]; then
    printf '%s' "$best_p"
  fi
}

resolve_transcript() {
  local sid="$1"
  local tp

  if [ -n "${CLAUDE_TRANSCRIPT_PATH:-}" ] && [ -f "${CLAUDE_TRANSCRIPT_PATH}" ]; then
    # Prefer realpath when available so packet metadata sees absolute paths.
    if command -v realpath >/dev/null 2>&1; then
      realpath -- "$CLAUDE_TRANSCRIPT_PATH"
    else
      printf '%s' "$CLAUDE_TRANSCRIPT_PATH"
    fi
    return 0
  fi
  if [ -n "${TRANSCRIPT_PATH:-}" ] && [ -f "${TRANSCRIPT_PATH}" ]; then
    if command -v realpath >/dev/null 2>&1; then
      realpath -- "$TRANSCRIPT_PATH"
    else
      printf '%s' "$TRANSCRIPT_PATH"
    fi
    return 0
  fi

  # Bridge transcript when still on disk.
  local br_rest br_tp
  if br_rest=$(read_bridge 2>/dev/null); then
    br_tp=$(printf '%s\n' "$br_rest" | sed -n '2p')
    if [ -n "$br_tp" ] && [ -f "$br_tp" ]; then
      if command -v realpath >/dev/null 2>&1; then
        realpath -- "$br_tp"
      else
        printf '%s' "$br_tp"
      fi
      return 0
    fi
  fi

  tp=$(stem_newest "$sid")
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    printf '%s' "$tp"
    return 0
  fi

  # Fallback: shared locate (stem-or-uuid-in-file).
  local assemble="${DISCOVER_ASSEMBLE:-}"
  if [ -z "$assemble" ]; then
    if [ -f "$HERE/../transcript-parse/assemble.py" ]; then
      assemble="$HERE/../transcript-parse/assemble.py"
    fi
  fi
  if [ -n "$assemble" ] && [ -f "$assemble" ]; then
    tp=$(python3 "$assemble" locate "$sid" 2>/dev/null || true)
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      printf '%s' "$tp"
      return 0
    fi
  fi

  # Last resort: cwd newest if its stem matches sid (session-id bridge).
  local cn_out cn_sid cn_tp
  if cn_out=$(cwd_newest_jsonl 2>/dev/null); then
    cn_sid=$(printf '%s\n' "$cn_out" | sed -n '1p')
    cn_tp=$(printf '%s\n' "$cn_out" | sed -n '2p')
    if [ "$cn_sid" = "$sid" ] && [ -n "$cn_tp" ] && [ -f "$cn_tp" ]; then
      printf '%s' "$cn_tp"
      return 0
    fi
  fi

  return 1
}

fail_no_session() {
  cat >&2 <<'EOF'
error: warm /handoff could not resolve this session's id
  Warm STM = spine-mine THIS session's live JSONL (shared engine) — not a
  freeform brief from model memory / live-context.
  Precedence: CLAUDE_SESSION_ID → SESSION_ID → .live-session.json bridge →
  basename stem of CLAUDE_TRANSCRIPT_PATH / TRANSCRIPT_PATH (*.jsonl) →
  newest *.jsonl under encoded project cwd in CLAUDE_PROJECTS_DIR.
  Non-Claude / Grok hosts without session env: warm STM is unavailable.
  Use cold /handoff <uuid> on a disk transcript, or export CLAUDE_SESSION_ID
  (or CLAUDE_TRANSCRIPT_PATH) before bare /handoff.
  Do NOT write freeform live-context output a warm STM packet (CDT-85 / AC-16).
EOF
  exit 1
}

SID=$(resolve_session_id) || fail_no_session

# Charset guard — id becomes a filename component in packet names.
case "$SID" in
  *[!A-Za-z0-9._-]*|*..*|*'/'*|*'\\'*|'')
    echo "error: warm /handoff: unsafe session id: $SID" >&2
    exit 1
    ;;
esac

TR=$(resolve_transcript "$SID") || {
  echo "error: warm /handoff could not locate transcript JSONL for session $SID" >&2
  echo "  precedence: CLAUDE_TRANSCRIPT_PATH → TRANSCRIPT_PATH → bridge path →" >&2
  echo "  \${CLAUDE_PROJECTS_DIR:-~/.claude/projects}/*/${SID}.jsonl (newest mtime) →" >&2
  echo "  assemble.py locate ${SID} → cwd-newest when stem matches" >&2
  echo "  Warm path requires a real transcript file (no freeform live-context)." >&2
  exit 1
}

# Best-effort session-id bridge for cold re-capture / later warm discover.
write_bridge "$SID" "$TR" || true

printf '%s\n%s\n' "$SID" "$TR"
