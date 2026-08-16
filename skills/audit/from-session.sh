#!/usr/bin/env bash
# from-session.sh — locate a host session via transcript-parse only (SPEC-035).
# MUST call skills/transcript-parse/hosts.py locate. MUST NOT parse transcripts.
#
# Usage: from-session.sh --session-id ID [--cwd DIR]
# stdout: host=<claude|grok> session_id=… path=…
# exit 0 found · 1 not found · 2 usage / missing python3 / hosts.py
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOSTS_PY="$HERE/../transcript-parse/hosts.py"
SID=""
CWD=""

usage() {
  echo "Usage: from-session.sh --session-id ID [--cwd DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --session-id)
      [ $# -ge 2 ] || usage
      SID="$2"
      shift 2
      ;;
    --cwd)
      [ $# -ge 2 ] || usage
      CWD="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *)
      echo "from-session: unknown arg: $1" >&2
      usage
      ;;
  esac
done

[ -n "$SID" ] || usage
if [ -z "$CWD" ]; then
  CWD=$(pwd)
fi
CWD=$(CDPATH= cd -- "$CWD" && pwd) || {
  echo "from-session: cannot cd to --cwd" >&2
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "from-session: python3 required" >&2
  exit 2
fi
if [ ! -f "$HOSTS_PY" ]; then
  echo "from-session: skills/transcript-parse/hosts.py not found" >&2
  exit 2
fi

found_host=""
found_path=""
for host in claude grok; do
  loc=""
  rc=0
  loc=$(python3 "$HOSTS_PY" locate --host "$host" --session-id "$SID" --cwd "$CWD" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$loc" ]; then
    found_host=$host
    found_path=$loc
    break
  fi
done

if [ -z "$found_path" ]; then
  echo "from-session: session not found: $SID" >&2
  exit 1
fi

printf 'host=%s session_id=%s path=%s\n' "$found_host" "$SID" "$found_path"
exit 0
