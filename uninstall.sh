#!/usr/bin/env bash
set -euo pipefail

# Uninstall claude-dev-team from opencode.
# Agents are generated copies, not symlinks. The commands entry is a symlink
# and is removed only when it points at this repo's commands/ directory.
# Dev-team model pins in opencode.json are removed with them.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
AGENT_DIR="$OPCODE_DIR/agents/dev-team"
CMD_LINK="$OPCODE_DIR/commands/dev-team"
CONFIG="$OPCODE_DIR/opencode.json"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

if ! command -v opencode >/dev/null 2>&1 && [ ! -d "$OPCODE_DIR" ]; then
  echo "Warning: opencode not detected (no 'opencode' on PATH and $OPCODE_DIR does not exist)."
  echo "Skipping uninstall — nothing was removed."
  exit 0
fi

PIN_AGENTS="ic4 qa devops pm tech-lead ic5 ds"

clear_pins() {
  [ -f "$CONFIG" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "Note: 'jq' not found — dev-team model pins in $CONFIG were left in place." >&2
    return 0
  fi
  if ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    echo "opencode.json is not strict JSON. Model pins were left in place." >&2
    return 1
  fi
  local filter="." a tmp
  for a in $PIN_AGENTS; do
    filter="$filter | del(.agent[\"$a\"])"
  done
  if $DRY_RUN; then
    echo "would clear dev-team model pins in $CONFIG"
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/opencode.json.XXXXXX")
  if ! jq "$filter" "$CONFIG" > "$tmp"; then
    rm -f "$tmp"
    echo "jq failed clearing model pins. Nothing else was removed." >&2
    return 1
  fi
  mv "$tmp" "$CONFIG"
}

remove_commands() {
  if [ -L "$CMD_LINK" ]; then
    local dest
    dest=$(readlink "$CMD_LINK")
    if [ "$dest" = "$SCRIPT_DIR/commands" ]; then
      if $DRY_RUN; then
        echo "would remove: $CMD_LINK"
      else
        rm -f "$CMD_LINK"
        echo "Removed $CMD_LINK"
      fi
      return 0
    fi
    echo "refusing to remove $CMD_LINK (symlink target is not this repo's commands/)" >&2
    return 1
  fi
  if [ -e "$CMD_LINK" ]; then
    echo "refusing to remove $CMD_LINK (not a symlink to this repo's commands/)" >&2
    return 1
  fi
  echo "Not found: $CMD_LINK"
}

remove_agents() {
  if [ -L "$AGENT_DIR" ]; then
    echo "refusing to remove $AGENT_DIR (it is a symlink, not a generated directory)" >&2
    return 1
  fi
  if [ -d "$AGENT_DIR" ]; then
    if $DRY_RUN; then
      echo "would remove: $AGENT_DIR"
    else
      rm -rf "$AGENT_DIR"
      echo "Removed $AGENT_DIR"
    fi
    return 0
  fi
  echo "Not found: $AGENT_DIR"
}

# A jq failure stops before any directory is removed. A refusal to remove the
# commands entry must not skip the generated agents directory.
clear_pins || exit 1
rc=0
remove_agents || rc=1
remove_commands || rc=1
[ "$rc" -eq 0 ] || exit "$rc"

if $DRY_RUN; then
  echo "Dry run — no changes made."
else
  echo "Uninstalled claude-dev-team from opencode"
fi
