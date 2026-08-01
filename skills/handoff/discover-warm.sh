#!/usr/bin/env bash
#
# discover-warm.sh — resolve this-session id + live JSONL for warm /handoff
# (SPEC-018 M10 / CDT-79-6 / CDT-85 session-id bridge / CDT-92 dual-host).
#
# Usage:
#   discover-warm.sh
#     Prints two lines on stdout:
#       <session_id>
#       <absolute_transcript_path_for_prepare>
#     When host=grok: line 2 is Claude-shaped adapted JSONL (TMPDIR).
#     Exit 0 on success; exit 1 with clear stderr on failure.
#
# Host selection (AC1 / AC3 / AC10):
#   Explicit Grok env (steps 1–2) wins over Claude. Grok cwd-newest (step 3)
#   wins over a *stale* Claude bridge / Claude projects-dir tip — but MUST NOT
#   fire when a definitive live-Claude env signal is present (CLAUDE_CODE_SESSION_ID
#   or CLAUDE_SESSION_ID, or CLAUDE_TRANSCRIPT_PATH / TRANSCRIPT_PATH → real
#   non-Grok file). Else fall through to Claude (CDT-85). If neither → fail hard.
#
# Grok discovery precedence (AC2):
#   1. GROK_SESSION_ID / GROK_TRANSCRIPT_PATH, or SESSION_ID naming a dir under
#      GROK_SESSIONS_DIR with chat_history.jsonl
#   2. CLAUDE_SESSION_ID / CLAUDE_TRANSCRIPT_PATH / TRANSCRIPT_PATH only if the
#      resolved path is a Grok chat_history.jsonl under sessions root
#      (sid = parent dir of that file — not CLAUDE_SESSION_ID when mixed)
#   3. Newest-mtime chat_history.jsonl under
#      ${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(cwd)>/*/
#      — SKIPPED when live Claude env signal is set (no silent hijack)
#   4. Grok miss → Claude path
#
# Claude session id precedence (when Grok miss):
#   1. $CLAUDE_CODE_SESSION_ID (non-empty) — the var Claude Code actually exports
#   2. $CLAUDE_SESSION_ID (non-empty)
#   3. $SESSION_ID (non-empty)
#   4. Bridge file ($HANDOFF_BRIDGE or $HANDOFF_DIR/.live-session.json) session_id
#   5. Basename stem of $CLAUDE_TRANSCRIPT_PATH / $TRANSCRIPT_PATH when *.jsonl
#   6. Newest-mtime *.jsonl under encoded project dir for live cwd (Claude bridge)
#   7. fail — clear diagnostic; never freeform live-context
#
# Claude transcript path precedence:
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
#   Fields: session_id, transcript_path (SOURCE path — Grok chat_history or
#   Claude jsonl), updated_at, source, host (grok|claude).
#
# Test overrides:
#   CLAUDE_PROJECTS_DIR   — projects root (default ~/.claude/projects)
#   GROK_SESSIONS_DIR     — Grok sessions root (default ~/.grok/sessions)
#   GROK_SESSION_ID       — Grok session id (step 1)
#   GROK_TRANSCRIPT_PATH  — path to chat_history.jsonl (step 1)
#   GROK_CWD / CLAUDE_CWD — live cwd for urlencode / Claude enc (default: pwd)
#   GROK_ADAPTER          — path to grok-to-claude-jsonl.py
#   DISCOVER_ASSEMBLE     — path to assemble.py for locate fallback
#   DISCOVER_RESOLVE_ROOT — path to resolve-root.sh for bridge write
#   HANDOFF_BRIDGE        — explicit bridge file path (read + write)
#   HANDOFF_DIR           — handoff dir (bridge = $HANDOFF_DIR/.live-session.json)
#
# Does NOT pass --allow-in-progress; callers (warm command only) own that flag.
# Does NOT invent freeform STM packets when discovery fails (CDT-85 honesty).

set -eu

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
GROK_SESSIONS_DIR="${GROK_SESSIONS_DIR:-$HOME/.grok/sessions}"
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

# write_bridge <sid> <source_transcript> [host]
write_bridge() {
  local sid="$1" tr="$2" host="${3:-}"
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
  BRIDGE_FILE="$bp" BRIDGE_SID="$sid" BRIDGE_TR="$tr" BRIDGE_HOST="$host" \
    python3 - <<'PY' 2>/dev/null || true
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
host = (os.environ.get("BRIDGE_HOST") or "").strip()
if host:
    payload["host"] = host
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

# Absolute live cwd for Grok urlencode / Claude enc / adapter inject.
live_cwd() {
  local cwd
  cwd="${GROK_CWD:-${CLAUDE_CWD:-}}"
  if [ -z "$cwd" ]; then
    cwd=$(pwd 2>/dev/null || true)
  fi
  [ -n "$cwd" ] || return 1
  if command -v realpath >/dev/null 2>&1; then
    cwd=$(realpath -- "$cwd" 2>/dev/null || printf '%s' "$cwd")
  fi
  printf '%s' "$cwd"
}

# urllib.parse.quote(cwd, safe="") — must match on-disk %2F… dirs.
urlencode_cwd() {
  local cwd="$1"
  CWD_RAW="$cwd" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
}

# Abs path helper.
abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$p"
  else
    printf '%s' "$p"
  fi
}

# True iff path is a regular file named chat_history.jsonl under GROK_SESSIONS_DIR.
is_grok_chat_history() {
  local p="$1" base abs root
  [ -n "$p" ] && [ -f "$p" ] || return 1
  base=$(basename -- "$p")
  [ "$base" = "chat_history.jsonl" ] || return 1
  abs=$(abs_path "$p")
  if command -v realpath >/dev/null 2>&1; then
    root=$(realpath -- "$GROK_SESSIONS_DIR" 2>/dev/null || printf '%s' "$GROK_SESSIONS_DIR")
  else
    root="$GROK_SESSIONS_DIR"
  fi
  # Strip trailing slash for prefix match.
  root="${root%/}"
  case "$abs" in
    "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Definitive live-Claude env: step-3 Grok cwd-newest must yield (no hijack).
# Explicit Grok env (steps 1–2) still wins; only the heuristic is gated.
live_claude_env_blocks_grok_cwd() {
  local cand
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    return 0
  fi
  for cand in "${CLAUDE_TRANSCRIPT_PATH:-}" "${TRANSCRIPT_PATH:-}"; do
    if [ -n "$cand" ] && [ -f "$cand" ] && ! is_grok_chat_history "$cand"; then
      return 0
    fi
  done
  return 1
}

# Locate chat_history for a Grok session id under sessions root (any cwd bucket).
# Prints absolute path or empty.
grok_find_by_sid() {
  local sid="$1"
  local f m best_m=-1 best_p=""
  [ -n "$sid" ] || return 0
  [ -d "$GROK_SESSIONS_DIR" ] || return 0
  # Null-delimited: sid charset-guarded before use as path component in tests.
  while IFS= read -r -d '' f; do
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ]; then
      best_m=$m
      best_p=$f
    fi
  done < <(find "$GROK_SESSIONS_DIR" -type f -path "*/${sid}/chat_history.jsonl" -print0 2>/dev/null)
  if [ -n "$best_p" ] && [ -f "$best_p" ]; then
    abs_path "$best_p"
  fi
}

# Newest chat_history.jsonl under urlencoded live cwd. Prints sid\npath or empty.
grok_cwd_newest_chat_history() {
  local cwd enc root f m best_m=-1 best_p="" sid
  cwd=$(live_cwd) || return 0
  enc=$(urlencode_cwd "$cwd") || return 0
  root="${GROK_SESSIONS_DIR%/}/$enc"
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' f; do
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ]; then
      best_m=$m
      best_p=$f
    fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name 'chat_history.jsonl' -print0 2>/dev/null)
  if [ -n "$best_p" ] && [ -f "$best_p" ]; then
    sid=$(basename -- "$(dirname -- "$best_p")")
    printf '%s\n%s\n' "$sid" "$(abs_path "$best_p")"
  fi
}

# Resolve Grok source. Prints sid\nsource_path on success; rc 1 on miss.
resolve_grok() {
  local sid="" src="" cand="" base parent

  # --- step 1: Grok/session env ---
  if [ -n "${GROK_TRANSCRIPT_PATH:-}" ] && [ -f "${GROK_TRANSCRIPT_PATH}" ]; then
    if is_grok_chat_history "$GROK_TRANSCRIPT_PATH"; then
      src=$(abs_path "$GROK_TRANSCRIPT_PATH")
      if [ -n "${GROK_SESSION_ID:-}" ]; then
        sid="$GROK_SESSION_ID"
      else
        sid=$(basename -- "$(dirname -- "$src")")
      fi
      printf '%s\n%s\n' "$sid" "$src"
      return 0
    fi
  fi

  if [ -n "${GROK_SESSION_ID:-}" ]; then
    cand=$(grok_find_by_sid "$GROK_SESSION_ID")
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      printf '%s\n%s\n' "$GROK_SESSION_ID" "$cand"
      return 0
    fi
  fi

  # SESSION_ID naming a Grok session dir (optional step-1 helper).
  if [ -n "${SESSION_ID:-}" ]; then
    cand=$(grok_find_by_sid "$SESSION_ID")
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      printf '%s\n%s\n' "$SESSION_ID" "$cand"
      return 0
    fi
  fi

  # --- step 2: CLAUDE_* / TRANSCRIPT_PATH only if Grok chat_history under root ---
  for cand in "${CLAUDE_TRANSCRIPT_PATH:-}" "${TRANSCRIPT_PATH:-}"; do
    if [ -n "$cand" ] && [ -f "$cand" ] && is_grok_chat_history "$cand"; then
      src=$(abs_path "$cand")
      # Sid from Grok folder — never pair Claude env sid with a Grok source.
      if [ -n "${GROK_SESSION_ID:-}" ]; then
        sid="$GROK_SESSION_ID"
      else
        sid=$(basename -- "$(dirname -- "$src")")
      fi
      printf '%s\n%s\n' "$sid" "$src"
      return 0
    fi
  done

  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    cand=$(grok_find_by_sid "$CLAUDE_SESSION_ID")
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      printf '%s\n%s\n' "$CLAUDE_SESSION_ID" "$cand"
      return 0
    fi
  fi

  # --- step 3: cwd newest Grok chat_history (skip if live Claude env) ---
  if live_claude_env_blocks_grok_cwd; then
    return 1
  fi
  local cn_out
  if cn_out=$(grok_cwd_newest_chat_history 2>/dev/null); then
    sid=$(printf '%s\n' "$cn_out" | sed -n '1p')
    src=$(printf '%s\n' "$cn_out" | sed -n '2p')
    if [ -n "$sid" ] && [ -n "$src" ] && [ -f "$src" ]; then
      printf '%s\n%s\n' "$sid" "$src"
      return 0
    fi
  fi

  return 1
}

# Adapt Grok chat_history → Claude-shaped temp file. Prints adapted path.
adapt_grok() {
  local sid="$1" src="$2"
  local adapter cwd out err
  adapter="${GROK_ADAPTER:-}"
  if [ -z "$adapter" ] && [ -f "$HERE/grok-to-claude-jsonl.py" ]; then
    adapter="$HERE/grok-to-claude-jsonl.py"
  fi
  if [ -z "$adapter" ] || [ ! -f "$adapter" ]; then
    echo "error: warm /handoff: Grok adapter not found (set GROK_ADAPTER or ship grok-to-claude-jsonl.py)" >&2
    return 1
  fi
  cwd=$(live_cwd) || {
    echo "error: warm /handoff: cannot resolve cwd for Grok adapter inject" >&2
    return 1
  }
  # Unique temp paths (avoid fixed-name races / predictable paths).
  out=$(mktemp "${TMPDIR:-/tmp}/handoff-grok-adapt.XXXXXX.jsonl") || {
    echo "error: warm /handoff: mktemp failed for adapter output" >&2
    return 1
  }
  err=$(mktemp "${TMPDIR:-/tmp}/handoff-grok-adapt.XXXXXX.err") || {
    rm -f "$out"
    echo "error: warm /handoff: mktemp failed for adapter stderr" >&2
    return 1
  }
  if ! python3 "$adapter" --in "$src" --out "$out" --cwd "$cwd" --session-id "$sid" 2>"$err"; then
    echo "error: warm /handoff: Grok→Claude adapt failed for session $sid" >&2
    if [ -s "$err" ]; then
      cat "$err" >&2
    fi
    rm -f "$out" "$err"
    return 1
  fi
  rm -f "$err"
  [ -f "$out" ] || {
    echo "error: warm /handoff: adapter produced no output at $out" >&2
    return 1
  }
  printf '%s' "$out"
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
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
    return 0
  fi
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
  Host selection: explicit Grok env wins; Grok cwd-newest wins over stale Claude
  bridge; live Claude env (CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID / non-Grok
  *_TRANSCRIPT_PATH) beats Grok cwd-heuristic; else Claude; neither → fail (CDT-92).
  Grok precedence: GROK_SESSION_ID / GROK_TRANSCRIPT_PATH → CLAUDE_* only if
  path is Grok chat_history.jsonl under sessions root → newest chat_history under
  ${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(cwd)>/*/ (skipped if live Claude env).
  Claude precedence: CLAUDE_CODE_SESSION_ID → CLAUDE_SESSION_ID → SESSION_ID →
  .live-session.json bridge → basename stem of CLAUDE_TRANSCRIPT_PATH /
  TRANSCRIPT_PATH (*.jsonl) → newest *.jsonl under encoded project cwd in
  CLAUDE_PROJECTS_DIR.
  Use cold /handoff <uuid> on a disk transcript, or export host session env
  (GROK_SESSION_ID / CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID / *_TRANSCRIPT_PATH)
  before bare /handoff.
  Do NOT call freeform live-context output a warm STM packet (CDT-85 / AC-16).
EOF
  exit 1
}

# ---- main: Grok first (explicit / non-gated), else Claude ----

GROK_OUT=""
if GROK_OUT=$(resolve_grok 2>/dev/null); then
  SID=$(printf '%s\n' "$GROK_OUT" | sed -n '1p')
  GROK_SRC=$(printf '%s\n' "$GROK_OUT" | sed -n '2p')
  if [ -n "$SID" ] && [ -n "$GROK_SRC" ] && [ -f "$GROK_SRC" ]; then
    # Charset guard — id becomes a filename component in packet names.
    case "$SID" in
      *[!A-Za-z0-9._-]*|*..*|*'/'*|*'\\'*|'')
        echo "error: warm /handoff: unsafe session id: $SID" >&2
        exit 1
        ;;
    esac
    TR=$(adapt_grok "$SID" "$GROK_SRC") || exit 1
    # Bridge stores SOURCE chat_history + host=grok (AC12/AC13).
    write_bridge "$SID" "$GROK_SRC" "grok" || true
    printf '%s\n%s\n' "$SID" "$TR"
    exit 0
  fi
fi

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
  echo "  (Grok path already missed; no freeform live-context.)" >&2
  echo "  Warm path requires a real transcript file (no freeform live-context)." >&2
  exit 1
}

# Best-effort session-id bridge for cold re-capture / later warm discover.
write_bridge "$SID" "$TR" "claude" || true

printf '%s\n%s\n' "$SID" "$TR"
