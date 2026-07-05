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

# Parse flags. Default: agents inherit the session model (any prior dev-team
# pins are cleared). --assign-models opts into the interactive per-tier picker.
# --reset is an explicit alias for the default (clear pins → inherit).
ASSIGN_MODELS=false
for arg in "$@"; do
  case "$arg" in
    --assign-models) ASSIGN_MODELS=true ;;
    --reset)         ASSIGN_MODELS=false ;;
  esac
done

# Remove any prior install (older symlink, or a previously generated dir).
# rm -rf the command entry too — if a real directory somehow exists there,
# `ln -sf` would create the link *inside* it ($CMD_DIR/dev-team/commands)
# rather than replacing it.
rm -rf "$OPCODE_DIR/agents/dev-team"
rm -rf "$CMD_DIR/dev-team"

mkdir -p "$AGENT_DIR" "$CMD_DIR"

# Commands: symlink unchanged (opencode accepts `agent: build` and $ARGUMENTS).
# -n so an existing symlink-to-dir is replaced, not dereferenced into.
ln -sfn "$SCRIPT_DIR/commands" "$CMD_DIR/dev-team"

# Discover available models from opencode.json (all providers, sorted)
config_file="$OPCODE_DIR/opencode.json"
if [ -f "$config_file" ]; then
  # Reset prior dev-team model pins so every run starts clean (default = inherit
  # the session model). Without this, an inherit run would leave stale
  # assignments from an earlier --assign-models run in opencode.json. The
  # --assign-models path below re-adds only the tiers you choose.
  if command -v jq >/dev/null 2>&1; then
    reset_filter="."
    for a in ic4 qa devops pm tech-lead ic5 ds; do
      reset_filter="$reset_filter | del(.agent[\"$a\"])"
    done
    jq "$reset_filter" "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
  else
    echo "Note: 'jq' not found — cannot read models or clear existing dev-team model pins in"
    echo "      $config_file. Install jq to manage per-tier assignments; any existing pins are"
    echo "      left untouched and agents otherwise inherit the session model."
  fi

  available_models=()
  while IFS= read -r line; do
    [ -n "$line" ] && available_models+=("$line")
  done < <(jq -r '[.provider | to_entries[] | .key as $prov | .value.models | to_entries[] | "\($prov)/\(.key)"] | unique | .[]' "$config_file" 2>/dev/null | sort)

  # Prompt only when the user opted in (--assign-models), there's a real choice
  # (>1 model), and we're on a TTY (so CI / piped installs never block). Every
  # other case falls through to inherit the session model.
  if $ASSIGN_MODELS && [ ${#available_models[@]} -gt 1 ] && [ -t 0 ]; then
    echo "Available models in your opencode.json:"
    printf '  %s\n' "${available_models[@]}"
    echo ""

    # Ask for 3 model tiers: haiku (fast), sonnet (general), opus (complex)
    echo "Assign model tiers for the agent team:"
    echo "(press Enter at any tier to leave those agents on the session model)"
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

    # Resolve a 1-based menu index to a model ID. Prints the model on success;
    # prints nothing for blank, non-numeric, or out-of-range input. This is the
    # single validation point — the summary below reads the resolved values, so
    # bad input (e.g. 0 → index -1 → bash wraps to the last element, or 99 →
    # unbound index that crashes under `set -u`) can neither mis-report nor abort.
    resolve_model() {
      local raw="$1"
      [[ "$raw" =~ ^[0-9]+$ ]] || return 0
      local idx=$((raw - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#available_models[@]} ]; then
        printf '%s' "${available_models[$idx]}"
      fi
    }

    # Add one agent → model assignment to the jq filter (no-op if model is empty).
    add_tier() {
      local tier_name="$1"
      local model_id="$2"
      [ -n "$model_id" ] || return 0
      local agent_name_escaped model_id_escaped
      agent_name_escaped=$(printf '%s' "$tier_name" | sed 's/"/\\"/g')
      model_id_escaped=$(printf '%s' "$model_id" | sed 's/"/\\"/g')
      jq_filter="$jq_filter | .agent[\"$agent_name_escaped\"] = {\"model\": \"$model_id_escaped\"}"
    }

    haiku_model=$(resolve_model "$haiku_idx")
    sonnet_model=$(resolve_model "$sonnet_idx")
    opus_model=$(resolve_model "$opus_idx")

    # Warn on non-empty input that didn't map to a real model.
    warn_bad() {
      if [ -n "$1" ] && [ -z "$2" ]; then
        echo "  ⚠ $3: '$1' is not a valid choice (1-${#available_models[@]}) — those agents stay on the session model."
      fi
    }
    warn_bad "$haiku_idx" "$haiku_model" "Haiku"
    warn_bad "$sonnet_idx" "$sonnet_model" "Sonnet"
    warn_bad "$opus_idx" "$opus_model" "Opus"

    # Map: Claude Code model tier → opencode agent name
    # haiku → ic4, qa (fast/simple)
    add_tier "ic4" "$haiku_model"
    add_tier "qa" "$haiku_model"
    # sonnet → devops, pm (general)
    add_tier "devops" "$sonnet_model"
    add_tier "pm" "$sonnet_model"
    # opus → tech-lead, ic5, ds (complex)
    add_tier "tech-lead" "$opus_model"
    add_tier "ic5" "$opus_model"
    add_tier "ds" "$opus_model"

    # Apply filter
    jq "$jq_filter | .agent = (.agent // {})" "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"

    echo "Added to opencode.json agent section:"
    if [ -n "$haiku_model" ]; then
      echo "  ic4 → $haiku_model"
      echo "  qa  → $haiku_model"
    fi
    if [ -n "$sonnet_model" ]; then
      echo "  devops → $sonnet_model"
      echo "  pm     → $sonnet_model"
    fi
    if [ -n "$opus_model" ]; then
      echo "  tech-lead → $opus_model"
      echo "  ic5       → $opus_model"
      echo "  ds        → $opus_model"
    fi
    echo ""
  else
    if $ASSIGN_MODELS && [ ${#available_models[@]} -le 1 ]; then
      echo "Fewer than two models available — nothing to assign; agents inherit the session model."
    elif $ASSIGN_MODELS; then
      echo "Not a TTY — skipping the model picker; agents inherit the session model."
    else
      echo "Agents inherit the session model (run with --assign-models to pin per-tier models)."
    fi
    echo ""
  fi
else
  echo "No $config_file found — agents will inherit the session model."
  echo ""
fi

# Generate opencode-valid copies of ALL agents (strip tools: + model:).
# Internal agents (council-judge/project-init/distiller) are installed too —
# they're excluded only from the model-tier menu above (their model isn't
# switched per-provider), so they inherit the session model.
for f in "$SCRIPT_DIR"/agents/*.md; do
  grep -v -E '^\s*(tools|model):' "$f" > "$AGENT_DIR/$(basename "$f")"
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
echo "Models: agents inherit the session model by default."
echo "  'bash install.sh --assign-models' pins models per tier; '--reset' clears pins (back to inherit)."
echo "Uninstall: run 'bash uninstall.sh' in the claude-dev-team directory"
