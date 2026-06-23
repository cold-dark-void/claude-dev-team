#!/usr/bin/env bash
set -euo pipefail

# Install claude-dev-team for opencode.
#
# Agents CANNOT be symlinked: Claude Code's `tools:` frontmatter is a
# comma-separated string, but opencode requires `tools:` to be an object and
# HARD-ERRORS ("Configuration is invalid ... Expected object") on the string
# form. Claude Code's `model:` uses tier names (sonnet/opus/haiku) but opencode
# expects full model IDs. So we generate opencode-valid agent copies: strip
# `tools:` and `model:` (model assignments go in opencode.json agent section).
# Model assignments go into opencode.json agent section (see below).
# Skills are NOT installed here — they load in place from this clone's skills/
# directory via opencode.json skills.paths (see the echo at the end).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

AGENT_DIR="$OPCODE_DIR/agents/dev-team"
CMD_DIR="$OPCODE_DIR/commands"

# Parse flags
NON_INTERACTIVE=false
for arg in "$@"; do
  [ "$arg" = "--non-interactive" ] && NON_INTERACTIVE=true
done

# Remove any prior install (older symlink, or a previously generated dir)
rm -rf "$OPCODE_DIR/agents/dev-team"
[ -L "$CMD_DIR/dev-team" ] && rm -f "$CMD_DIR/dev-team"

mkdir -p "$AGENT_DIR" "$CMD_DIR"

# Commands: symlink unchanged (opencode accepts `agent: build` and $ARGUMENTS).
ln -sf "$SCRIPT_DIR/commands" "$CMD_DIR/dev-team"

# Internal agents invoked by commands (not directly) — skip them
INTERNAL_AGENTS="council-judge project-init distiller"

# Discover available models from opencode.json (all providers, sorted)
config_file="$OPCODE_DIR/opencode.json"
if [ -f "$config_file" ]; then
  available_models=()
  while IFS= read -r line; do
    [ -n "$line" ] && available_models+=("$line")
  done < <(jq -r '[.provider | to_entries[] | .key as $prov | .value.models | to_entries[] | "\($prov)/\(.key)"] | unique | .[]' "$config_file" 2>/dev/null | sort)

  if [ ${#available_models[@]} -gt 0 ] && ! $NON_INTERACTIVE; then
    echo "Available models in your opencode.json:"
    printf '  %s\n' "${available_models[@]}"
    echo ""

    # Ask for 3 model tiers: haiku (fast), sonnet (general), opus (complex)
    echo "Assign model tiers for the agent team:"
    echo ""
    echo "  Haiku  (fast/simple tasks — ic4, qa):"
    for i in "${!available_models[@]}"; do
      echo "    [$((i+1))] ${available_models[$i]}"
    done
    read -rp "  Model: " haiku_idx

    echo ""
    echo "  Sonnet (general tasks — devops, pm):"
    for i in "${!available_models[@]}"; do
      echo "    [$((i+1))] ${available_models[$i]}"
    done
    read -rp "  Model: " sonnet_idx

    echo ""
    echo "  Opus   (complex tasks — tech-lead, ic5, ds):"
    for i in "${!available_models[@]}"; do
      echo "    [$((i+1))] ${available_models[$i]}"
    done
    read -rp "  Model: " opus_idx
    echo ""

    # Build jq filter from tier assignments
    jq_filter="."

    # Function to add a tier assignment to the filter
    add_tier() {
      local tier_name="$1"
      local tier_idx="$2"

      if [ -n "$tier_idx" ] && [[ "$tier_idx" =~ ^[0-9]+$ ]]; then
        local idx=$((tier_idx - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#available_models[@]} ]; then
          local model_id="${available_models[$idx]}"
          local agent_name_escaped=$(echo "$tier_name" | sed 's/"/\\"/g')
          local model_id_escaped=$(echo "$model_id" | sed 's/"/\\"/g')
          jq_filter="$jq_filter | .agent[\"$agent_name_escaped\"] = {\"model\": \"$model_id_escaped\"}"
        fi
      fi
    }

    # Map: Claude Code model tier → opencode agent name
    # haiku → ic4, qa (fast/simple)
    add_tier "ic4" "$haiku_idx"
    add_tier "qa" "$haiku_idx"
    # sonnet → devops, pm (general)
    add_tier "devops" "$sonnet_idx"
    add_tier "pm" "$sonnet_idx"
    # opus → tech-lead, ic5, ds (complex)
    add_tier "tech-lead" "$opus_idx"
    add_tier "ic5" "$opus_idx"
    add_tier "ds" "$opus_idx"

    # Apply filter
    jq "$jq_filter | .agent = (.agent // {})" "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"

    echo "Added to opencode.json agent section:"
    if [ -n "$haiku_idx" ] && [[ "$haiku_idx" =~ ^[0-9]+$ ]]; then
      h_idx=$((haiku_idx - 1))
      echo "  ic4 → ${available_models[$h_idx]}"
      echo "  qa  → ${available_models[$h_idx]}"
    fi
    if [ -n "$sonnet_idx" ] && [[ "$sonnet_idx" =~ ^[0-9]+$ ]]; then
      s_idx=$((sonnet_idx - 1))
      echo "  devops → ${available_models[$s_idx]}"
      echo "  pm     → ${available_models[$s_idx]}"
    fi
    if [ -n "$opus_idx" ] && [[ "$opus_idx" =~ ^[0-9]+$ ]]; then
      o_idx=$((opus_idx - 1))
      echo "  tech-lead → ${available_models[$o_idx]}"
      echo "  ic5       → ${available_models[$o_idx]}"
      echo "  ds        → ${available_models[$o_idx]}"
    fi
    echo ""
  else
    echo "Agents will inherit session model."
    echo "To assign models later, edit opencode.json:"
    echo '  "agent": { "pm": { "model": "provider/model-id" } }'
    echo ""
  fi
else
  echo "No $config_file found — agents will inherit session model."
  echo "To assign models later, edit opencode.json:"
  echo '  "agent": { "pm": { "model": "provider/model-id" } }'
  echo ""
fi

# Strip tools: and model: from agent files (model assignments go in opencode.json)
for f in "$SCRIPT_DIR"/agents/*.md; do
  base=$(basename "$f")
  is_internal=false
  for ia in $INTERNAL_AGENTS; do
    [ "$base" = "${ia}.md" ] && is_internal=true && break
  done
  if $is_internal; then continue; fi
  grep -v -E '^\s*(tools|model):' "$f" > "$AGENT_DIR/$base"
done

echo "Installed claude-dev-team for opencode"
echo "  Agents:   $AGENT_DIR/ (generated from $SCRIPT_DIR/agents, tools: + model: stripped)"
echo "  Commands: $CMD_DIR/dev-team -> $SCRIPT_DIR/commands"
echo ""
echo "For skills: add '$SCRIPT_DIR/skills' to opencode.json skills.paths:"
echo "  \"skills\": { \"paths\": [\"$SCRIPT_DIR/skills\"] }"
echo ""
echo "Commands are accessible as /dev-team/<command-name> (e.g., /dev-team/handoff)"
echo "Re-run 'bash install.sh' after editing an agent (agents are copied, not symlinked)."
echo "To fine-tune model assignments later, edit opencode.json directly:"
echo '  "agent": { "pm": { "model": "provider/model-id" } }'
echo "Use 'bash install.sh --non-interactive' to skip model assignment prompt."
echo "Uninstall: run 'bash uninstall.sh' in the claude-dev-team directory"
