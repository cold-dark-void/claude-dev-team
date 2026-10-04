#!/usr/bin/env bash
set -euo pipefail

# Install claude-dev-team for opencode.
#
# Agents CANNOT be symlinked: Claude Code's `tools:` frontmatter is a
# comma-separated string, but opencode requires `tools:` to be an object and
# HARD-ERRORS ("Configuration is invalid ... Expected object") on the string
# form. Claude Code's `model:` uses tier names (sonnet/opus/haiku) but opencode
# expects full model IDs. So we generate opencode-valid agent copies: strip
# `tools:` and `model:` from YAML frontmatter only. Model pins live in
# opencode.json and are written only by --assign-models (see below).
# Skills are NOT installed here — they load in place from this clone's skills/
# directory via opencode.json skills.paths (see the echo at the end).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve opencode config directory
OPCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

AGENT_DIR="$OPCODE_DIR/agents/dev-team"
CMD_DIR="$OPCODE_DIR/commands"

# Parse flags. Default: agents inherit the session model and existing pins
# stay. --assign-models opts into the interactive per-tier picker.
# --reset clears dev-team pins. --dry-run prints every planned mutation and
# executes none (exit 0). Any other flag exits 64 and writes nothing.
ASSIGN_MODELS=false
RESET_PINS=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --assign-models) ASSIGN_MODELS=true; RESET_PINS=false ;;
    --reset)         RESET_PINS=true; ASSIGN_MODELS=false ;;
    --dry-run)       DRY_RUN=true ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

# Route every filesystem mutation through run(): in dry-run, print the command
# instead of executing it. Only works for argv-form commands (no redirection or
# &&) — the jq rewrites and agent-copy loop are gated with explicit $DRY_RUN
# blocks below.
run() { if $DRY_RUN; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

# opencode auto-detect (AC2): "present" = binary on PATH OR config dir exists
# (OR, not AND — a first-time install has the binary but no config dir yet).
# If BOTH are absent, warn and skip all writes (exit 0). --dry-run still prints
# its full plan below (dry-run is diagnostic, always runs to completion).
if ! command -v opencode >/dev/null 2>&1 && [ ! -d "$OPCODE_DIR" ]; then
  echo "Warning: opencode not detected (no 'opencode' on PATH and $OPCODE_DIR does not exist)."
  echo "Skipping install — nothing was written."
  $DRY_RUN || exit 0
fi

# Capacity warning (AC3): count agent .md files recursively across the whole
# opencode agent tree; opencode may silently ignore agents beyond ~100. Fires in
# both normal and dry-run mode; guarded so an absent agents/ dir can't error the
# count under `set -o pipefail`.
if [ -d "$OPCODE_DIR/agents" ]; then
  agent_count=$(find "$OPCODE_DIR/agents" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$agent_count" -ge 100 ]; then
    echo "Warning: $agent_count agent files under $OPCODE_DIR/agents/ — approaching the 100-agent cap;"
    echo "         opencode may silently ignore agents beyond the cap."
  fi
fi

# Validate opencode.json before any removal. A jq failure or a comments-style
# file must leave the previous agents dir, command symlink, and pins in place.
config_file="$OPCODE_DIR/opencode.json"
json_tmp=""
cleanup_json_tmp() {
  if [ -n "${json_tmp:-}" ] && [ -f "$json_tmp" ]; then
    rm -f "$json_tmp"
  fi
}
trap cleanup_json_tmp EXIT

apply_json_filter() {
  local filter="$1"
  json_tmp=$(mktemp "${TMPDIR:-/tmp}/opencode.json.XXXXXX")
  if ! jq "$filter" "$config_file" > "$json_tmp"; then
    echo "jq failed rewriting $config_file. Previous install left intact." >&2
    rm -f "$json_tmp"
    json_tmp=""
    exit 1
  fi
  mv "$json_tmp" "$config_file"
  json_tmp=""
}

PIN_AGENTS="ic4 qa devops pm tech-lead ic5 ds"
pin_delete_filter() {
  local filter="." a
  for a in $PIN_AGENTS; do
    filter="$filter | del(.agent[\"$a\"])"
  done
  printf '%s\n' "$filter"
}

if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1 && ! $DRY_RUN; then
  if ! jq -e . "$config_file" >/dev/null 2>&1; then
    echo "opencode.json is not strict JSON. Comments and trailing commas are not supported. Nothing was changed." >&2
    exit 1
  fi
fi

# Discover available models from opencode.json (all providers, sorted).
# Pin edits happen before the agents dir is removed, so a jq failure leaves
# the previous install in place. A default run does not touch pins.
if [ -f "$config_file" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "Note: 'jq' not found — cannot read models or edit dev-team model pins in"
    echo "      $config_file. Install jq to manage per-tier assignments; any existing pins are"
    echo "      left untouched and agents otherwise inherit the session model."
  elif $DRY_RUN && $RESET_PINS; then
    echo "[dry-run] would clear prior dev-team model pins in opencode.json"
  elif $RESET_PINS; then
    apply_json_filter "$(pin_delete_filter)"
  elif $DRY_RUN && ! $ASSIGN_MODELS; then
    echo "[dry-run] would leave existing dev-team model pins unchanged"
  fi

  available_models=()
  while IFS= read -r line; do
    [ -n "$line" ] && available_models+=("$line")
  done < <(jq -r '[.provider | to_entries[] | .key as $prov | .value.models | to_entries[] | "\($prov)/\(.key)"] | unique | .[]' "$config_file" 2>/dev/null | sort)

  # Prompt only when the user opted in (--assign-models), there's a real choice
  # (>1 model), and we're on a TTY (so CI / piped installs never block). Every
  # other case falls through to inherit the session model.
  if $DRY_RUN && $ASSIGN_MODELS; then
    # AC6: never touch the TTY in dry-run — skip the picker and the jq apply.
    echo "[dry-run] would prompt for model tiers (haiku/sonnet/opus) — skipped in dry-run"
    echo ""
  elif $ASSIGN_MODELS && [ ${#available_models[@]} -gt 1 ] && { [ -t 0 ] || [ "${DEV_TEAM_ASSIGN_MODELS_STDIN:-}" = 1 ]; }; then
    echo "Available models in your opencode.json:"
    printf '  %s\n' "${available_models[@]}"
    echo ""

    # 10 F7 / 10 E4: derive the tier groups from agents/*.md `model:`
    # frontmatter — the roster (SPEC-003) is the source of truth, never a
    # hardcoded agent list. Only tiers that actually hold behavioral agents
    # get a prompt.
    model_of() { awk -F': *' 'tolower($1)=="model" {print tolower($2); exit}' "$1" 2>/dev/null; }
    HAIKU_AGENTS=""; SONNET_AGENTS=""; OPUS_AGENTS=""
    for a in $PIN_AGENTS; do
      _m=$(model_of "$SCRIPT_DIR/agents/$a.md")
      case "$_m" in
        haiku)  HAIKU_AGENTS="$HAIKU_AGENTS $a" ;;
        sonnet) SONNET_AGENTS="$SONNET_AGENTS $a" ;;
        opus)   OPUS_AGENTS="$OPUS_AGENTS $a" ;;
        *) echo "  ⚠ $a: no recognizable model: tier in agents/$a.md — that agent stays on the session model." ;;
      esac
    done

    # Ask for one model per non-empty tier: haiku (fast), sonnet (general), opus (complex)
    echo "Assign model tiers for the agent team:"
    echo "(press Enter at any tier to leave those agents on the session model)"

    pick_tier() { # pick_tier <tier-label> <tier-hint> <agents> <idx-var-name>
      local label="$1" hint="$2" agents="$3" var="$4" i
      echo ""
      echo "  $label ($hint —$agents):"
      for i in "${!available_models[@]}"; do
        echo "    [$((i+1))] ${available_models[$i]}"
      done
      read -rp "  Model: " "$var"
    }
    haiku_idx=""; sonnet_idx=""; opus_idx=""
    [ -n "$HAIKU_AGENTS" ]  && pick_tier "Haiku"  "fast/simple tasks" "$HAIKU_AGENTS"  haiku_idx
    [ -n "$SONNET_AGENTS" ] && pick_tier "Sonnet" "general tasks"     "$SONNET_AGENTS" sonnet_idx
    [ -n "$OPUS_AGENTS" ]   && pick_tier "Opus"   "complex tasks"    "$OPUS_AGENTS"   opus_idx
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

    # Map: agents/*.md model tier → opencode agent pin (derived above, 10 F7).
    for a in $HAIKU_AGENTS;  do add_tier "$a" "$haiku_model";  done
    for a in $SONNET_AGENTS; do add_tier "$a" "$sonnet_model"; done
    for a in $OPUS_AGENTS;   do add_tier "$a" "$opus_model";   done

    # Replace only the dev-team pins, then apply the tiers just chosen.
    jq_filter="$(pin_delete_filter) | $jq_filter | .agent = (.agent // {})"
    apply_json_filter "$jq_filter"

    echo "Added to opencode.json agent section:"
    if [ -n "$haiku_model" ]; then
      for a in $HAIKU_AGENTS;  do echo "  $a → $haiku_model";  done
    fi
    if [ -n "$sonnet_model" ]; then
      for a in $SONNET_AGENTS; do echo "  $a → $sonnet_model"; done
    fi
    if [ -n "$opus_model" ]; then
      for a in $OPUS_AGENTS;   do echo "  $a → $opus_model";   done
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

# Remove any prior install only after config checks. A jq failure above has
# already exited, so this rm cannot run against a half-applied pin rewrite.
# rm -rf the command entry too — if a real directory somehow exists there,
# `ln -sf` would create the link *inside* it ($CMD_DIR/dev-team/commands)
# rather than replacing it.
run rm -rf "$OPCODE_DIR/agents/dev-team"
run rm -rf "$CMD_DIR/dev-team"
run mkdir -p "$AGENT_DIR" "$CMD_DIR"
# -n so an existing symlink-to-dir is replaced, not dereferenced into.
run ln -sfn "$SCRIPT_DIR/commands" "$CMD_DIR/dev-team"

# Generate opencode-valid copies of every agent. Strip tools: and model:
# only inside the YAML frontmatter (the first two --- lines). A body line
# that starts with those words stays. Internal agents (finder, debugger,
# project-init, distiller, council-judge, council-scribe) are installed too. They are not in
# the model-tier menu above, so they inherit the session model.
strip_frontmatter() {
  awk '
    BEGIN { n = 0; fm = 0 }
    /^---[[:space:]]*$/ {
      n++
      print
      if (n == 1) fm = 1
      else if (n == 2) fm = 0
      next
    }
    fm && /^[[:space:]]*(tools|model):/ { next }
    { print }
  ' "$1"
}
if $DRY_RUN; then
  n=$(find "$SCRIPT_DIR/agents" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  echo "[dry-run] would generate $n opencode agent copies into $AGENT_DIR/"
else
  for f in "$SCRIPT_DIR"/agents/*.md; do
    strip_frontmatter "$f" > "$AGENT_DIR/$(basename "$f")"
  done
fi

if $DRY_RUN; then
  echo "[dry-run] no changes made. Plan for claude-dev-team (opencode):"
else
  echo "Installed claude-dev-team for opencode"
fi
echo "  Agents:   $AGENT_DIR/ (generated from $SCRIPT_DIR/agents, frontmatter tools: + model: stripped)"
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
