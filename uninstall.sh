#!/usr/bin/env bash
set -euo pipefail

# Uninstall claude-dev-team from opencode by removing symlinks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

# Remove the command symlink and the generated agents dir
# (skills are never installed here — see install.sh).
for dir in agents commands; do
    existing="$OPCODE_DIR/$dir/dev-team"
    if [ -e "$existing" ] || [ -L "$existing" ]; then
        if $DRY_RUN; then
            echo "would remove: $existing"
        else
            rm -rf "$existing"
            echo "Removed $existing"
        fi
    else
        echo "Not found: $existing"
    fi
done

if $DRY_RUN; then
    echo "Dry run — no changes made."
else
    echo "Uninstalled claude-dev-team from opencode"
fi
