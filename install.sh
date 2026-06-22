#!/usr/bin/env bash
set -euo pipefail

# Install claude-dev-team for opencode by creating symlinks in the
# opencode config directory.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# opencode reads agents and commands from ~/.config/opencode/{agents,commands}/.
# Commands are symlinked as-is. Agents CANNOT be symlinked: Claude Code's
# `tools:` frontmatter is a comma-separated string, but opencode requires
# `tools:` to be an object and HARD-ERRORS ("Configuration is invalid ...
# Expected object") on the string form. So we generate opencode-valid agent
# copies by stripping the `tools:` line — Claude Code keeps it (in the source
# files) for per-agent tool scoping; opencode falls back to its own defaults.
# Skills are NOT installed here — they load in place from this clone's skills/
# directory via opencode.json skills.paths (see the echo at the end).

AGENT_DIR="$OPCODE_DIR/agents/dev-team"
CMD_DIR="$OPCODE_DIR/commands"

# Remove any prior install (older symlink, or a previously generated dir)
rm -rf "$OPCODE_DIR/agents/dev-team"
[ -L "$CMD_DIR/dev-team" ] && rm -f "$CMD_DIR/dev-team"

mkdir -p "$AGENT_DIR" "$CMD_DIR"

# Commands: symlink unchanged (opencode accepts `agent: build` and $ARGUMENTS).
ln -sf "$SCRIPT_DIR/commands" "$CMD_DIR/dev-team"

# Agents: generate opencode-valid copies (strip the Claude Code `tools:` line).
for f in "$SCRIPT_DIR"/agents/*.md; do
    grep -v '^tools:' "$f" > "$AGENT_DIR/$(basename "$f")"
done

echo "Installed claude-dev-team for opencode"
echo "  Agents:   $AGENT_DIR/ (generated from $SCRIPT_DIR/agents, tools: stripped)"
echo "  Commands: $CMD_DIR/dev-team -> $SCRIPT_DIR/commands"
echo ""
echo "For skills: add '$SCRIPT_DIR/skills' to opencode.json skills.paths:"
echo "  \"skills\": { \"paths\": [\"$SCRIPT_DIR/skills\"] }"
echo ""
echo "Commands are accessible as /dev-team/<command-name> (e.g., /dev-team/handoff)"
echo "Re-run 'bash install.sh' after editing an agent (agents are copied, not symlinked)."
echo "Uninstall: run 'bash uninstall.sh' in the claude-dev-team directory"
