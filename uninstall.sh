#!/usr/bin/env bash
set -euo pipefail

# Uninstall claude-dev-team from opencode by removing symlinks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# Remove symlinks (skills are never symlinked — see install.sh)
for dir in agents commands; do
    existing="$OPCODE_DIR/$dir/dev-team"
    if [ -L "$existing" ]; then
        rm -f "$existing"
        echo "Removed $existing"
    else
        echo "Not found: $existing"
    fi
done

echo "Uninstalled claude-dev-team from opencode"
