#!/usr/bin/env bash
#
# discover-host.sh — dual-host auto-detect for /retro (CDT-156 T5 / SPEC-012).
#
# Usage:
#   discover-host.sh [--cwd DIR] [--env-check]
#
# Stdout (success, exit 0) — space-separated key=value:
#   host=claude|grok session_id=<id> path=<abs_source> source=<pin|mtime>
#
# source values:
#   env:GROK_SESSION_ID | env:GROK_TRANSCRIPT_PATH
#   env:CLAUDE_CODE_SESSION_ID | env:CLAUDE_SESSION_ID
#   env:CLAUDE_TRANSCRIPT_PATH | env:TRANSCRIPT_PATH
#   mtime
#
# Exit:
#   0  host found
#   1  none (or --env-check with no resolvable env pin)
#   2  usage / missing python3 / hosts.py
#
# Precedence (SPEC-012 auto-detect, non--all):
#   1. GROK_SESSION_ID / GROK_TRANSCRIPT_PATH when resolvable via hosts.py
#   2. Claude env (CLAUDE_CODE_SESSION_ID | CLAUDE_SESSION_ID |
#      CLAUDE_TRANSCRIPT_PATH | TRANSCRIPT_PATH) when resolvable
#   3. Newest mtime across Claude project dir + Grok cwd bucket for --cwd
#      (OQ2). Skipped when --env-check.
#
# Test / override roots (passed through to hosts.py locate):
#   CLAUDE_PROJECTS_DIR  — Claude projects root (default ~/.claude/projects)
#   GROK_SESSIONS_DIR    — Grok sessions root (honored by hosts.py)
#
# Does NOT implement --host CLI parsing or --all ⇒ all (caller's job in retro.md).

set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HOSTS_PY="$HERE/hosts.py"
CWD=""
ENV_CHECK=0

usage() {
  echo "Usage: discover-host.sh [--cwd DIR] [--env-check]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      [ $# -ge 2 ] || usage
      CWD="$2"
      shift 2
      ;;
    --env-check)
      ENV_CHECK=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "discover-host: unknown arg: $1" >&2
      usage
      ;;
  esac
done

if [ -z "$CWD" ]; then
  CWD="$(pwd)"
fi
CWD="$(cd -- "$CWD" && pwd)" || {
  echo "discover-host: cannot cd to --cwd: $CWD" >&2
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "discover-host: python3 required" >&2
  exit 2
fi
if [ ! -f "$HOSTS_PY" ]; then
  echo "discover-host: missing $HOSTS_PY" >&2
  exit 2
fi

# Claude projects root override for tests (hosts.py --sessions-dir).
claude_sessions_args() {
  if [ -n "${CLAUDE_PROJECTS_DIR:-}" ]; then
    printf '%s\n' --sessions-dir "$CLAUDE_PROJECTS_DIR"
  fi
}

# Grok: hosts.py already reads GROK_SESSIONS_DIR; pass --sessions-dir when set
# so locate and env-path checks share the same root.
grok_sessions_args() {
  if [ -n "${GROK_SESSIONS_DIR:-}" ]; then
    printf '%s\n' --sessions-dir "$GROK_SESSIONS_DIR"
  fi
}

# Locate helper. Args: host [session_id]. Prints path or empty; rc ignored.
locate_host() {
  local host="$1"
  local sid="${2:-}"
  local -a cmd
  local out
  cmd=(python3 "$HOSTS_PY" locate --host "$host" --cwd "$CWD")
  if [ -n "$sid" ]; then
    cmd+=(--session-id "$sid")
  fi
  if [ "$host" = "claude" ]; then
    # shellcheck disable=SC2207
    cmd+=($(claude_sessions_args))
  else
    # shellcheck disable=SC2207
    cmd+=($(grok_sessions_args))
  fi
  out="$("${cmd[@]}" 2>/dev/null)" || true
  if [ -n "$out" ] && [ -f "$out" ]; then
    printf '%s' "$out"
  fi
}

session_id_from_path() {
  local host="$1"
  local path="$2"
  if [ "$host" = "grok" ]; then
    basename -- "$(dirname -- "$path")"
  else
    basename -- "$path" .jsonl
  fi
}

emit() {
  local host="$1"
  local path="$2"
  local source="$3"
  local sid
  sid="$(session_id_from_path "$host" "$path")"
  printf 'host=%s session_id=%s path=%s source=%s\n' "$host" "$sid" "$path" "$source"
}

# --- 1. Grok env pins ---
if [ -n "${GROK_TRANSCRIPT_PATH:-}" ]; then
  # hosts.py honors GROK_TRANSCRIPT_PATH on locate (any sid / newest).
  GPATH="$(locate_host grok)" || true
  if [ -n "${GPATH:-}" ]; then
    emit grok "$GPATH" "env:GROK_TRANSCRIPT_PATH"
    exit 0
  fi
fi

if [ -n "${GROK_SESSION_ID:-}" ]; then
  GPATH="$(locate_host grok "$GROK_SESSION_ID")" || true
  if [ -n "${GPATH:-}" ]; then
    emit grok "$GPATH" "env:GROK_SESSION_ID"
    exit 0
  fi
fi

# --- 2. Claude env pins ---
# Transcript path first (explicit file), then session id vars.
for pair in \
  "CLAUDE_TRANSCRIPT_PATH:${CLAUDE_TRANSCRIPT_PATH:-}" \
  "TRANSCRIPT_PATH:${TRANSCRIPT_PATH:-}"; do
  tag="${pair%%:*}"
  tpath="${pair#*:}"
  if [ -n "$tpath" ] && [ -f "$tpath" ]; then
    # Skip if this is actually a Grok chat_history (mixed env).
    base="$(basename -- "$tpath")"
    if [ "$base" != "chat_history.jsonl" ]; then
      emit claude "$(cd -- "$(dirname -- "$tpath")" && pwd)/$(basename -- "$tpath")" \
        "env:$tag"
      exit 0
    fi
  fi
done

for pair in \
  "CLAUDE_CODE_SESSION_ID:${CLAUDE_CODE_SESSION_ID:-}" \
  "CLAUDE_SESSION_ID:${CLAUDE_SESSION_ID:-}"; do
  tag="${pair%%:*}"
  csid="${pair#*:}"
  if [ -n "$csid" ]; then
    CPATH="$(locate_host claude "$csid")" || true
    if [ -n "${CPATH:-}" ]; then
      emit claude "$CPATH" "env:$tag"
      exit 0
    fi
  fi
done

if [ "$ENV_CHECK" -eq 1 ]; then
  exit 1
fi

# --- 3. Dual-host newest mtime (OQ2) ---
CPATH="$(locate_host claude)" || true
GPATH="$(locate_host grok)" || true

if [ -z "${CPATH:-}" ] && [ -z "${GPATH:-}" ]; then
  exit 1
fi
if [ -z "${CPATH:-}" ]; then
  emit grok "$GPATH" mtime
  exit 0
fi
if [ -z "${GPATH:-}" ]; then
  emit claude "$CPATH" mtime
  exit 0
fi

# Compare mtimes; tie → prefer lexicographically smaller path (matches hosts.py).
CMTIME=$(stat -c %Y "$CPATH" 2>/dev/null || stat -f %m "$CPATH" 2>/dev/null)
GMTIME=$(stat -c %Y "$GPATH" 2>/dev/null || stat -f %m "$GPATH" 2>/dev/null)
CMTIME=${CMTIME:-0}
GMTIME=${GMTIME:-0}

if [ "$GMTIME" -gt "$CMTIME" ]; then
  emit grok "$GPATH" mtime
  exit 0
fi
if [ "$CMTIME" -gt "$GMTIME" ]; then
  emit claude "$CPATH" mtime
  exit 0
fi
# Equal mtime: deterministic path order.
if [[ "$CPATH" < "$GPATH" ]]; then
  emit claude "$CPATH" mtime
else
  emit grok "$GPATH" mtime
fi
exit 0
