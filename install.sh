#!/usr/bin/env bash
set -euo pipefail

# Install claude-dev-team for opencode by creating symlinks in the
# opencode config directory.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# opencode reads agents and commands from symlinks under:
#   ~/.config/opencode/agents/
#   ~/.config/opencode/commands/
# Skills are NOT symlinked — they load in place from this clone's skills/
# directory via opencode.json skills.paths (see the echo at the end).

AGENT_DIR="$OPCODE_DIR/agents"
CMD_DIR="$OPCODE_DIR/commands"

# Clean up existing symlinks to avoid duplicates
for dir in agents commands; do
    existing="$OPCODE_DIR/$dir/dev-team"
    if [ -L "$existing" ]; then
        rm -f "$existing"
    fi
done

# Create symlinks
mkdir -p "$AGENT_DIR" "$CMD_DIR"

ln -sf "$SCRIPT_DIR/agents" "$AGENT_DIR/dev-team"
ln -sf "$SCRIPT_DIR/commands" "$CMD_DIR/dev-team"

echo "Installed claude-dev-team for opencode"
echo "  Agents:  $AGENT_DIR/dev-team -> $SCRIPT_DIR/agents"
echo "  Commands: $CMD_DIR/dev-team -> $SCRIPT_DIR/commands"
echo ""
echo "For skills: add '$SCRIPT_DIR/skills' to opencode.json skills.paths:"
echo "  \"skills\": { \"paths\": [\"$SCRIPT_DIR/skills\"] }"
echo ""
echo "Commands are accessible as /dev-team/<command-name> (e.g., /dev-team/handoff)"
echo "Uninstall: run 'bash uninstall.sh' in the claude-dev-team directory"
