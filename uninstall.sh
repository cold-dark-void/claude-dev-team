#!/usr/bin/env bash
set -euo pipefail

# Uninstall claude-dev-team from opencode by removing symlinks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# Remove the command symlink and the generated agents dir
# (skills are never installed here — see install.sh).
for dir in agents commands; do
    existing="$OPCODE_DIR/$dir/dev-team"
    if [ -e "$existing" ] || [ -L "$existing" ]; then
        rm -rf "$existing"
        echo "Removed $existing"
    else
        echo "Not found: $existing"
    fi
done

echo "Uninstalled claude-dev-team from opencode"
