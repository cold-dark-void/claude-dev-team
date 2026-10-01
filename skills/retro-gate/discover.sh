#!/usr/bin/env bash
# discover.sh — resolve host, collect sources, filter, normalize to gate feeds.
# Reads MODE, HOST, HOST_EXPLICIT, WHY, AUTO, and EXPLICIT_SID from the environment.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOSTS_PY="$SCRIPT_DIR/../transcript-parse/hosts.py"
ASSEMBLE="$SCRIPT_DIR/../transcript-parse/assemble.py"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Grok cwd-bucket keys on live worktree path (not MROOT). Claude PROJECT_DIR stays MROOT-encoded.
HOST_CWD="${WTROOT:-$(pwd)}"
ENCODED=$(echo "$MROOT" | sed 's|/|-|g')
PROJECT_DIR="$HOME/.claude/projects/$ENCODED"
GROK_SESSIONS_ROOT="${GROK_SESSIONS_DIR:-$HOME/.grok/sessions}"

_mtime_of() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

_append_cand() {
  # $1=host $2=path
  [ -n "$2" ] && [ -f "$2" ] || return 0
  CANDIDATES="${CANDIDATES}
$1	$2"
}

_claude_uuid_ok() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*) return 0 ;;
    *) return 1 ;;
  esac
}

_locate_one() {
  # $1=host $2=optional sid → path
  # hosts.py always gets HOST_CWD (live WTROOT) so Grok buckets match session layout.
  # Separate local lines so skill-lint C1 sees both names (multi-assign only captures first).
  local _h="$1"
  local _sid="${2:-}"
  if [ -f "$HOSTS_PY" ] && command -v python3 >/dev/null 2>&1; then
    if [ -n "$_sid" ]; then
      python3 "$HOSTS_PY" locate --host "$_h" --session-id "$_sid" --cwd "$HOST_CWD" 2>/dev/null || true
    else
      python3 "$HOSTS_PY" locate --host "$_h" --cwd "$HOST_CWD" 2>/dev/null || true
    fi
    return 0
  fi
  # Claude-only fallback without hosts.py (MROOT-encoded PROJECT_DIR parity)
  if [ "$_h" != "claude" ]; then
    return 0
  fi
  if [ -n "$_sid" ]; then
    if [ -f "$ASSEMBLE" ] && command -v python3 >/dev/null 2>&1; then
      python3 "$ASSEMBLE" locate "$_sid" 2>/dev/null || true
    else
      find "$HOME/.claude/projects" -name "${_sid}.jsonl" 2>/dev/null | head -1
    fi
  else
    find "$PROJECT_DIR" -maxdepth 1 -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | head -1 | cut -d" " -f2-
  fi
}

# --- Auto-detect host when still empty (single mode; --all set HOST=all in Step 1) ---
if [ -z "$HOST" ]; then
  _auto_sid="${EXPLICIT_SID:-}"
  if [ -n "${GROK_TRANSCRIPT_PATH:-}" ] || [ -n "${GROK_SESSION_ID:-}" ]; then
    _pin_sid="${_auto_sid:-${GROK_SESSION_ID:-}}"
    _g_pin=$(_locate_one grok "$_pin_sid")
    if [ -n "$_g_pin" ]; then
      HOST="grok"
    fi
  fi
  if [ -z "$HOST" ]; then
    _c_path=$(_locate_one claude "$_auto_sid")
    _g_path=$(_locate_one grok "$_auto_sid")
    if [ -n "$_c_path" ] && [ -n "$_g_path" ]; then
      if [ "$(_mtime_of "$_g_path")" -gt "$(_mtime_of "$_c_path")" ]; then
        HOST="grok"
      else
        HOST="claude"
      fi
    elif [ -n "$_g_path" ]; then
      HOST="grok"
    else
      HOST="claude"
    fi
  fi
fi

# Explicit --host grok requires hosts.py (no silent Claude fallback).
if [ "$HOST" = "grok" ] && { [ ! -f "$HOSTS_PY" ] || ! command -v python3 >/dev/null 2>&1; }; then
  echo "error: --host grok requires skills/transcript-parse/hosts.py and python3" >&2
  exit 1
fi

CANDIDATES=""

# Auto-detect candidate from discover-host.sh (CDT-420). Explicit --sid
# still uses the host-scoped locate below.
DISCOVER="$SCRIPT_DIR/../transcript-parse/discover-host.sh"
if [ -z "${EXPLICIT_SID:-}" ] && [ -n "${DISCOVER:-}" ] && [ -f "$DISCOVER" ]; then
  _dh=$(bash "$DISCOVER" --cwd "$HOST_CWD" 2>/dev/null || true)
  _dh_host=$(printf '%s\n' "$_dh" | awk -F '\t' 'NF { print $1; exit }' | sed 's/^host=//')
  _dh_path=$(printf '%s\n' "$_dh" | awk -F '\t' 'NF { print $3; exit }' | sed 's/^path=//')
  if [ -n "$_dh_host" ] && [ -n "$_dh_path" ] && [ -f "$_dh_path" ]; then
    _append_cand "$_dh_host" "$_dh_path"
  fi
fi

if [ -n "$EXPLICIT_SID" ]; then
  # Explicit session-id: host-scoped locate. Claude UUIDs validated for claude path.
  _found=""
  case "$HOST" in
    claude)
      if ! _claude_uuid_ok "$EXPLICIT_SID"; then
        echo "error: session-id must be a UUID for --host claude (e.g. 00000000-0000-4000-8000-000000000004)" >&2
        exit 1
      fi
      _p=$(_locate_one claude "$EXPLICIT_SID")
      if [ -z "$_p" ]; then
        echo "Session not found (host=claude): $EXPLICIT_SID" >&2
        exit 1
      fi
      _append_cand claude "$_p"
      ;;
    grok)
      _p=$(_locate_one grok "$EXPLICIT_SID")
      if [ -z "$_p" ]; then
        # MUST NOT fall back to Claude when --host grok is explicit (SPEC-012).
        echo "error: Grok session not found for id=$EXPLICIT_SID cwd=$HOST_CWD" >&2
        echo "error: expected ${GROK_SESSIONS_ROOT}/<urlencode(cwd)>/${EXPLICIT_SID}/chat_history.jsonl" >&2
        echo "error: no Claude fallback for --host grok" >&2
        exit 1
      fi
      _append_cand grok "$_p"
      ;;
    all)
      _p=$(_locate_one claude "$EXPLICIT_SID")
      [ -n "$_p" ] && _append_cand claude "$_p" && _found=1
      _p=$(_locate_one grok "$EXPLICIT_SID")
      [ -n "$_p" ] && _append_cand grok "$_p" && _found=1
      if [ -z "$_found" ]; then
        echo "Session not found: $EXPLICIT_SID" >&2
        exit 1
      fi
      ;;
  esac

elif [ "$MODE" = "single" ]; then
  # Newest (or env-pinned) source for selected host.
  case "$HOST" in
    claude)
      if [ ! -d "$PROJECT_DIR" ] && [ ! -f "$HOSTS_PY" ]; then
        echo "No Claude project directory found for this repo."
        echo "Expected: $PROJECT_DIR"
        exit 1
      fi
      _p=$(_locate_one claude)
      if [ -n "$_p" ]; then
        _append_cand claude "$_p"
      fi
      ;;
    grok)
      _p=$(_locate_one grok)
      if [ -z "$_p" ]; then
        echo "error: no Grok session found under cwd bucket for $HOST_CWD" >&2
        echo "error: expected ${GROK_SESSIONS_ROOT}/<urlencode(cwd)>/*/chat_history.jsonl" >&2
        echo "error: no Claude fallback for --host grok" >&2
        exit 1
      fi
      _append_cand grok "$_p"
      ;;
    all)
      # Single mode + host all: one newest across both hosts.
      _c=$(_locate_one claude)
      _g=$(_locate_one grok)
      if [ -n "$_c" ] && [ -n "$_g" ]; then
        if [ "$(_mtime_of "$_g")" -gt "$(_mtime_of "$_c")" ]; then
          _append_cand grok "$_g"
        else
          _append_cand claude "$_c"
        fi
      elif [ -n "$_g" ]; then
        _append_cand grok "$_g"
      elif [ -n "$_c" ]; then
        _append_cand claude "$_c"
      fi
      ;;
  esac

elif [ "$MODE" = "all" ]; then
  # Cross-session mining: Claude all projects and/or Grok cwd-bucket only (MVP).
  if [ "$HOST" = "claude" ] || [ "$HOST" = "all" ]; then
    while IFS= read -r _p; do
      [ -z "$_p" ] && continue
      _append_cand claude "$_p"
    done < <(find "$HOME/.claude/projects" -name "*.jsonl" -type f 2>/dev/null)
  fi
  if [ "$HOST" = "grok" ] || [ "$HOST" = "all" ]; then
    # Grok MVP: exact live-cwd bucket only (urlencode HOST_CWD; same as hosts.grok_cwd_bucket).
    _g_bucket=""
    if command -v python3 >/dev/null 2>&1; then
      _g_bucket=$(GROK_SESSIONS_DIR="${GROK_SESSIONS_DIR:-}" python3 -c '
import os, urllib.parse, sys
root = os.environ.get("GROK_SESSIONS_DIR") or os.path.expanduser("~/.grok/sessions")
enc = urllib.parse.quote(os.path.abspath(sys.argv[1]), safe="")
print(os.path.join(os.path.abspath(os.path.expanduser(root)), enc))
' "$HOST_CWD" 2>/dev/null || true)
    fi
    if [ -n "$_g_bucket" ] && [ -d "$_g_bucket" ]; then
      while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        _append_cand grok "$_p"
      done < <(find "$_g_bucket" -mindepth 2 -maxdepth 2 -name chat_history.jsonl -type f 2>/dev/null)
    fi
    if [ "$HOST" = "grok" ]; then
      _gc=$(printf '%s\n' "$CANDIDATES" | sed '/^[[:space:]]*$/d' | grep -c . || true); _gc=${_gc:-0}
      if [ "$_gc" -eq 0 ]; then
        echo "error: no Grok sessions found under cwd bucket for $HOST_CWD" >&2
        echo "error: no Claude fallback for --host grok" >&2
        exit 1
      fi
    fi
  fi
  SESSION_COUNT=$(printf '%s\n' "$CANDIDATES" | sed '/^[[:space:]]*$/d' | grep -c . || true); SESSION_COUNT=${SESSION_COUNT:-0}
  if [ "$SESSION_COUNT" -gt 500 ]; then
    echo "# retro: --all found $SESSION_COUNT sessions; this will take a while" >&2
  fi
fi

CANDIDATES=$(printf '%s\n' "$CANDIDATES" | sed '/^[[:space:]]*$/d')

HOSTS_PY="$SCRIPT_DIR/../transcript-parse/hosts.py"
FRESHNESS="$SCRIPT_DIR/../transcript-parse/freshness.sh"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOST_CWD="${WTROOT:-$(pwd)}"

_session_id_from_source() {
  # $1=host $2=source_path
  local _h="$1"
  local _src="$2"
  if [ "$_h" = "grok" ]; then
    # …/<sid>/chat_history.jsonl → sid
    basename "$(dirname "$_src")"
  else
    basename "$_src" .jsonl
  fi
}

# Keep this run's feeds for later fences and the phase-2 read.
# Prune only retro-norm dirs older than 24h.
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'retro-norm.*' -mmin +1440 -print 2>/dev/null \
  | while IFS= read -r _old_norm; do rm -rf -- "$_old_norm"; done
_RETRO_NORM=$(mktemp -d "${TMPDIR:-/tmp}/retro-norm.XXXXXX") || _RETRO_NORM=""

_normalize_feed() {
  # $1=host $2=source $3=session_id → gate path on stdout
  # --cwd is live HOST_CWD (Grok session metadata / bucket parity).
  # Separate local lines so skill-lint C1 sees each name (multi-assign only captures first).
  local _h="$1"
  local _src="$2"
  local _sid="$3"
  if [ -f "$HOSTS_PY" ] && command -v python3 >/dev/null 2>&1; then
    if [ -n "${_RETRO_NORM:-}" ]; then
      TMPDIR="$_RETRO_NORM" python3 "$HOSTS_PY" normalize --host "$_h" --source "$_src" --cwd "$HOST_CWD" \
        --session-id "$_sid" --mode scoring 2>/dev/null || true
    else
      python3 "$HOSTS_PY" normalize --host "$_h" --source "$_src" --cwd "$HOST_CWD" \
        --session-id "$_sid" --mode scoring 2>/dev/null || true
    fi
    return 0
  fi
  # Identity fallback (Claude only).
  if [ "$_h" = "claude" ]; then
    printf '%s\n' "$_src"
  fi
}

NOW=$(date +%s)
FILTERED=""
SKIPPED_INPROG=${SKIPPED_INPROG:-0}
while IFS=$'\t' read -r _host _src; do
  [ -z "$_src" ] && continue
  [ -z "$_host" ] && _host="claude"

  MTIME=$(stat -c %Y "$_src" 2>/dev/null || stat -f %m "$_src" 2>/dev/null)
  AGE=$(( NOW - ${MTIME:-NOW} ))

  if [ -f "$FRESHNESS" ]; then  # lint-ok: C1
    bash "$FRESHNESS" check "$_src" >/dev/null 2>&1
    FRESH_RC=$?
  else
    if [ "$AGE" -lt 60 ]; then FRESH_RC=9; else FRESH_RC=0; fi
  fi

  if [ "$FRESH_RC" -eq 9 ]; then
    SKIPPED_INPROG=$(( SKIPPED_INPROG + 1 ))
    if [ "$WHY" = "1" ]; then  # lint-ok: C1
      _lab=$(_session_id_from_source "$_host" "$_src")
      echo "[skip] ${_lab}  (host=${_host}; modified ${AGE}s ago — in-progress threshold: 60s)"
    fi
    continue
  fi
  FILTERED="${FILTERED}
${_host}	${_src}"
done <<< "$CANDIDATES"
CANDIDATES=$(printf '%s\n' "$FILTERED" | sed '/^[[:space:]]*$/d')

# Normalize → Filter-2 on source and/or gate feed → SESSIONS = gate paths
FILTERED=""
SKIPPED_FILTER2=${SKIPPED_FILTER2:-0}
while IFS=$'\t' read -r _host _src; do
  [ -z "$_src" ] && continue
  [ -z "$_host" ] && _host="claude"
  _sid=$(_session_id_from_source "$_host" "$_src")
  _feed=$(_normalize_feed "$_host" "$_src" "$_sid")
  if [ -z "$_feed" ] || [ ! -f "$_feed" ]; then
    echo "# retro: normalize failed host=${_host} source=${_src} — skipping" >&2
    continue
  fi
  _skip=0
  if grep -qE '<command-name>/[a-z:-]*retro</command-name>' "$_src" 2>/dev/null; then
    _skip=1
  elif [ "$_feed" != "$_src" ] && grep -qE '<command-name>/[a-z:-]*retro</command-name>' "$_feed" 2>/dev/null; then
    _skip=1
  fi
  if [ "$_skip" = "1" ]; then
    SKIPPED_FILTER2=$(( SKIPPED_FILTER2 + 1 ))
    if [ "$WHY" = "1" ]; then  # lint-ok: C1
      echo "[skip] ${_sid}  (host=${_host}; contains /retro invocation — loop prevention)"
    fi
    continue
  fi
  FILTERED="${FILTERED}
${_feed}"
done <<< "$CANDIDATES"  # lint-ok: C1
SESSIONS=$(printf '%s\n' "$FILTERED" | sed '/^[[:space:]]*$/d')
SCANNED=$(printf '%s\n' "$SESSIONS" | sed '/^[[:space:]]*$/d' | grep -c . || true); SCANNED=${SCANNED:-0}

printf "SESSIONS<<RETRO_END\n%s\nRETRO_END\n" "${SESSIONS:-}"

printf "SCANNED=%s\n" "${SCANNED:-0}"

printf "SKIPPED_INPROG=%s\n" "${SKIPPED_INPROG:-0}"

printf "SKIPPED_FILTER2=%s\n" "${SKIPPED_FILTER2:-0}"
