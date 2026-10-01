#!/usr/bin/env bash
# install.sh — opt-in Transcript mirror helper (SPEC-036 M3).
# Run this script with the target project as the current directory.
# It copies hook-shim.sh and merges Stop + SessionEnd into
# .claude/settings.json. It does not register the hook through
# /setup orchestration. It does not edit crontab.
# --subagent also merges SubagentStop.
# --cron prints one cron line (absolute transcript-sync.sh + PATH).
# Subprocess only. Never source this file.
set -u

usage() {
  printf '%s\n' "usage: install.sh [--subagent] [--cron]" >&2
  exit 64
}

SUB=0
CRON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --subagent) SUB=1 ;;
    --cron) CRON=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Use the files beside this script. plugin-dir.sh `file` can return a
# different install when the current directory is not that plugin tree.
# Operators invoke this script by the path plugin-dir.sh already resolved,
# so the shim and transcript-sync.sh stay in that same tree.
SHIM=$HERE/hook-shim.sh
SYNC=$HERE/transcript-sync.sh
if [ ! -f "$SHIM" ] || [ ! -f "$SYNC" ]; then
  printf '%s\n' "install.sh: hook-shim.sh or transcript-sync.sh not found" >&2
  exit 1
fi

ROOT=$(pwd)
umask 077
mkdir -p -- "$ROOT/.claude/hooks" || exit 1
cp -- "$SHIM" "$ROOT/.claude/hooks/transcript-mirror.sh" || exit 1
chmod +x "$ROOT/.claude/hooks/transcript-mirror.sh" || exit 1

SETTINGS="$ROOT/.claude/settings.json"
if [ -e "$SETTINGS" ] && [ ! -f "$SETTINGS" ]; then
  printf '%s\n' "install.sh: $SETTINGS is not a file" >&2
  exit 1
fi
if [ -f "$SETTINGS" ]; then
  if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    printf '%s\n' "install.sh: $SETTINGS is not a JSON object" >&2
    exit 1
  fi
  mode=$(stat -c %a "$SETTINGS" 2>/dev/null || stat -f %OLp "$SETTINGS")
else
  mode=600
fi

prog=$(mktemp "${TMPDIR:-/tmp}/tm-install-prog.XXXXXX") || exit 1
tmp=$(mktemp "$ROOT/.claude/settings.json.tmp.XXXXXX") || {
  rm -f -- "$prog"
  exit 1
}
trap 'rm -f -- "$prog" "$tmp"' EXIT

cat >"$prog" <<'EOF'
def mirror: "transcript-mirror.sh";
def block:
  {hooks: [{type: "command",
            command: "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh\"",
            timeout: 10}]};
def event_has($name):
  ((.hooks[$name] // [])
   | [.. | objects | .command? // empty | select(tostring | contains(mirror))]
   | length) > 0;
def add($name):
  if event_has($name) then .
  else .hooks[$name] = ((.hooks[$name] // []) + [block])
  end;
(if . == null then {} else . end)
| if type != "object" then error("settings root must be an object") else . end
| .hooks //= {}
| add("Stop")
| add("SessionEnd")
| if $sub == "1" then add("SubagentStop") else . end
EOF

if [ -f "$SETTINGS" ]; then
  jq --arg sub "$SUB" -f "$prog" "$SETTINGS" >"$tmp" || exit 1
else
  jq -n --arg sub "$SUB" -f "$prog" >"$tmp" || exit 1
fi
chmod "$mode" "$tmp" || exit 1
mv -f -- "$tmp" "$SETTINGS" || exit 1

if [ "$CRON" -eq 1 ]; then
  printf '0 * * * * cd %q && PATH=/usr/local/bin:/opt/homebrew/bin:$PATH bash %q\n' "$ROOT" "$SYNC"
fi
exit 0
