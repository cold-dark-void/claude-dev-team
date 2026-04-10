#!/usr/bin/env bash
#
# council/engine.sh — Adversarial council tribunal engine
#
# Deterministic scaffolding for the protocol in skills/council/SKILL.md.
# Spec: specs/core/SPEC-013-adversarial-council-tribunal.md.
#
# ARCHITECTURAL SPLIT (read before editing):
# A bash script cannot spawn Claude Code Task subagents — those are runtime
# concepts inside a Claude Code session. The orchestrating Claude (executing
# /council) invokes the Task tool and the council-judge agent. This script
# provides only the deterministic pre/post scaffolding around those
# LLM-driven phases. Same pattern as retro-gate/gate.sh + retro-subagent +
# commands/retro.md.
#
# Two execution modes:
#   preflight — parse args, resolve scope/task-id/preset, fail loud on
#     deferred scopes, emit an investigation-plan JSON document to stdout
#     describing what the orchestrating Claude must spawn for phases 1-5.
#   finalize  — consume evidence bundles + judge output (as files), validate
#     output_shape, render the report from skills/council/templates/, write
#     it, and call index-writer.sh for the atomic index update.
#
# Utility subcommands: resolve-task-id, report-path (pure helpers).

set -euo pipefail

# ---- Resolve MROOT (worktree-aware) -----------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUNCIL_DIR="$MROOT/.claude/council"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
INDEX_WRITER="$SCRIPT_DIR/index-writer.sh"

# ---- Usage ------------------------------------------------------------------
usage() {
  cat >&2 <<'USAGE'
Usage: engine.sh <subcommand> [args...]

Subcommands:
  preflight        [--scope claim|session|diff|plan|from-retro] [--scope-arg V]
                   [--last N] [--task-id ID] [--preset NAME] [--why]
                   Emits investigation-plan JSON on stdout.

  finalize         --plan-file P --evidence-file E --judge-output J
                   [--task-id ID] [--report-out PATH]
                   Renders report, writes index row.

  resolve-task-id  [--task-id ID]   Print resolved id (or empty line).
  report-path SLUG [--task-id ID]   Print canonical report path.

Exit codes: 0 ok | 2 usage/no-scope | 3 deferred scope | 4 unknown preset
            5 empty evidence | 6 index-writer failure | 7 schema mismatch
USAGE
}

# ---- Dependency check -------------------------------------------------------
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "engine.sh: jq is required but not found in PATH" >&2
    exit 1
  fi
}

# ---- resolve-task-id --------------------------------------------------------
# Fallback: --task-id flag → CLAUDE_TASK_ID env → empty. Never errors.
cmd_resolve_task_id() {
  local tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) tid="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$tid" ]; then
    tid="${CLAUDE_TASK_ID:-}"
  fi
  printf '%s\n' "$tid"
}

# ---- report-path ------------------------------------------------------------
# $MROOT/.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>].md
# Slug is used verbatim; caller must pre-sanitize.
cmd_report_path() {
  if [ $# -lt 1 ]; then
    echo "engine.sh: report-path requires <slug>" >&2
    exit 2
  fi
  local slug="$1"; shift
  local tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) tid="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local date
  date=$(date -u +%Y-%m-%d)  # UTC per SKILL.md report-path contract
  local suffix=""
  if [ -n "$tid" ]; then
    suffix="--${tid}"
  fi
  printf '%s/%s-%s%s.md\n' "$COUNCIL_DIR" "$date" "$slug" "$suffix"
}

# ---- preflight --------------------------------------------------------------
# Parse scope flags → validate → resolve preset → emit investigation-plan
# JSON to stdout. Deferred scopes exit 3; no scope exit 2; bad preset exit 4.
cmd_preflight() {
  require_jq

  local scope="" scope_arg="" last="" task_id="" preset="" why="false"

  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)     scope="${2:-}"; shift 2 ;;
      --scope-arg) scope_arg="${2:-}"; shift 2 ;;
      --last)      last="${2:-}"; shift 2 ;;
      --task-id)   task_id="${2:-}"; shift 2 ;;
      --preset)    preset="${2:-}"; shift 2 ;;
      --why)       why="true"; shift ;;
      *)
        echo "engine.sh: unknown preflight flag: $1" >&2
        exit 2
        ;;
    esac
  done

  # No-scope invocation → usage error (exit 2)
  if [ -z "$scope" ]; then
    echo "engine.sh: scope required (--scope claim|session|diff)" >&2
    usage
    exit 2
  fi

  # Deferred scopes → exit 3 with exact message
  case "$scope" in
    plan|from-retro)
      echo "engine.sh: --${scope} is not implemented in COUNCIL-001 (v0.18.0). Planned for COUNCIL-002. See SPEC-013." >&2
      exit 3
      ;;
  esac

  # Resolve task-id via fallback chain
  if [ -z "$task_id" ]; then
    task_id="${CLAUDE_TASK_ID:-}"
  fi

  # Resolve preset (explicit or inferred from scope)
  if [ -z "$preset" ]; then
    case "$scope" in
      diff)    preset="diff-mode" ;;
      claim|session|from-retro|plan) preset="generic" ;;
      *)
        echo "engine.sh: unknown scope: $scope" >&2
        exit 2
        ;;
    esac
  fi

  # Preset table (COUNCIL-001 hardcoded — see SKILL.md "Presets" section).
  local output_shape feedback_enabled spec_grep confidence_filter flavors
  case "$preset" in
    generic)
      output_shape="verdict[]"; feedback_enabled="true"; spec_grep="false"
      confidence_filter="null"
      flavors='["paranoid-ic","jaded-senior","yolo-ic"]' ;;
    diff-mode)
      output_shape="finding[]"; feedback_enabled="false"; spec_grep="true"
      confidence_filter="80"
      flavors='["logic","security","compliance","quality","simplification","jaded-senior","yolo-ic"]' ;;
    *)
      echo "engine.sh: unknown preset: $preset — known: generic, diff-mode" >&2
      exit 4 ;;
  esac

  local claim_budget=10  # SPEC-013 line 51, hardcoded in v1
  local slug
  case "$scope" in
    claim)   slug="claim" ;;
    session) slug="session${last:+-last-$last}" ;;
    diff)    slug="diff-staged" ;;
    *)       slug="$scope" ;;
  esac
  local report_path
  report_path=$(cmd_report_path "$slug" --task-id "$task_id")

  # Build the investigation plan JSON for the orchestrating Claude. This is
  # the contract: the Claude that invoked /council reads this document and
  # uses it to drive Phase 1-5 via Task-tool spawns.
  jq -n \
    --arg scope "$scope" \
    --arg scope_arg "$scope_arg" \
    --arg last "$last" \
    --arg task_id "$task_id" \
    --arg preset "$preset" \
    --arg output_shape "$output_shape" \
    --argjson flavors "$flavors" \
    --arg spec_grep "$spec_grep" \
    --arg feedback_enabled "$feedback_enabled" \
    --arg confidence_filter "$confidence_filter" \
    --argjson claim_budget "$claim_budget" \
    --arg why "$why" \
    --arg slug "$slug" \
    --arg report_path "$report_path" \
    --arg mroot "$MROOT" \
    '{
      scope: $scope,
      scope_arg: $scope_arg,
      last: $last,
      task_id: $task_id,
      preset: $preset,
      output_shape: $output_shape,
      flavors: $flavors,
      spec_grep: ($spec_grep == "true"),
      feedback_memory_enabled: ($feedback_enabled == "true"),
      confidence_filter_threshold: (if $confidence_filter == "null" then null else ($confidence_filter | tonumber) end),
      claim_budget: $claim_budget,
      why: ($why == "true"),
      slug: $slug,
      report_path: $report_path,
      mroot: $mroot,
      phases: {
        "1_claim_extraction": { skip: ($scope == "claim"), prompt: "skills/council/prompts/claim-extractor.md" },
        "2_parallel_investigation": { min_flavors_per_claim: 2, prompt: "skills/council/prompts/investigator.md" },
        "3_domain_specialist": { deferred: true },
        "4_prosecution_defense": { prosecutor: "skills/council/prompts/prosecutor.md", advocate: "skills/council/prompts/advocate.md" },
        "5_judgment": { agent: "council-judge", prompt: "skills/council/prompts/judge.md" },
        "6_finalize": { invoke: "engine.sh finalize --plan-file <p> --evidence-file <e> --judge-output <j>" }
      }
    }'
}

# ---- finalize ---------------------------------------------------------------
# Consume plan + evidence + judge output, render report, write index row.
# Inputs: --plan-file, --evidence-file, --judge-output. Does not interpret
# semantics beyond branching on output_shape and computing max_confidence.
cmd_finalize() {
  require_jq

  local plan_file="" evidence_file="" judge_output="" task_id="" report_out=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --plan-file)     plan_file="${2:-}"; shift 2 ;;
      --evidence-file) evidence_file="${2:-}"; shift 2 ;;
      --judge-output)  judge_output="${2:-}"; shift 2 ;;
      --task-id)       task_id="${2:-}"; shift 2 ;;
      --report-out)    report_out="${2:-}"; shift 2 ;;
      *)
        echo "engine.sh: unknown finalize flag: $1" >&2
        exit 2
        ;;
    esac
  done

  if [ -z "$plan_file" ] || [ ! -f "$plan_file" ]; then
    echo "engine.sh: finalize requires --plan-file <path> (existing file)" >&2
    exit 2
  fi
  if [ -z "$evidence_file" ] || [ ! -f "$evidence_file" ]; then
    echo "engine.sh: finalize requires --evidence-file <path> (existing file)" >&2
    exit 2
  fi
  if [ -z "$judge_output" ] || [ ! -f "$judge_output" ]; then
    echo "engine.sh: finalize requires --judge-output <path> (existing file)" >&2
    exit 2
  fi

  # Extract plan metadata
  local output_shape scope preset slug plan_task_id plan_report_path
  output_shape=$(jq -r '.output_shape' "$plan_file")
  scope=$(jq -r '.scope' "$plan_file")
  preset=$(jq -r '.preset' "$plan_file")
  slug=$(jq -r '.slug' "$plan_file")
  plan_task_id=$(jq -r '.task_id // ""' "$plan_file")
  plan_report_path=$(jq -r '.report_path' "$plan_file")

  # task-id on finalize overrides plan's task-id if given
  if [ -z "$task_id" ]; then
    task_id="$plan_task_id"
  fi

  # Recompute report path if task_id changed
  if [ -n "$report_out" ]; then
    plan_report_path="$report_out"
  elif [ "$task_id" != "$plan_task_id" ]; then
    plan_report_path=$(cmd_report_path "$slug" --task-id "$task_id")
  fi

  # Validate output_shape and select template
  local template_file
  case "$output_shape" in
    "verdict[]") template_file="$TEMPLATE_DIR/report-verdict.md" ;;
    "finding[]") template_file="$TEMPLATE_DIR/report-finding.md" ;;
    *)
      echo "engine.sh: invalid output_shape in plan: $output_shape" >&2
      exit 7
      ;;
  esac

  if [ ! -f "$template_file" ]; then
    echo "engine.sh: report template missing: $template_file (expected from Task 8)" >&2
    exit 7
  fi

  # Validate evidence file is non-empty JSON array. An empty bundle set is
  # exit 5 per SKILL.md failure-mode table.
  local evidence_count
  evidence_count=$(jq 'if type == "array" then length else 0 end' "$evidence_file")
  if [ "$evidence_count" = "0" ]; then
    echo "engine.sh: Phase 2 produced zero evidence bundles — aborting" >&2
    exit 5
  fi

  # Compute max confidence for the index row.
  local max_verdict_confidence="null" max_finding_confidence="null"
  local verdict_count=0 finding_count=0
  if [ "$output_shape" = "verdict[]" ]; then
    verdict_count=$(jq 'if type == "array" then length else 0 end' "$judge_output")
    if [ "$verdict_count" -gt 0 ]; then
      max_verdict_confidence=$(jq '[.[] | .confidence // 0] | max // 0' "$judge_output")
    fi
  else
    finding_count=$(jq 'if type == "array" then length else 0 end' "$judge_output")
    if [ "$finding_count" -gt 0 ]; then
      max_finding_confidence=$(jq '[.[] | .confidence // 0] | max // 0' "$judge_output")
    fi
  fi

  # Ensure parent dir exists
  mkdir -p "$(dirname "$plan_report_path")"

  # Render: engine.sh owns the write, templates own the prose. Task 8 may
  # refine substitution later; this preserves the contract.
  local created_at
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  {
    echo "---"
    echo "scope: \"$scope\""
    echo "preset: \"$preset\""
    echo "output_shape: \"$output_shape\""
    echo "created_at: \"$created_at\""
    if [ -n "$task_id" ]; then
      echo "task_id: \"$task_id\""
    fi
    echo "---"
    echo
    cat "$template_file"
    echo
    echo "## Evidence Bundles"
    echo
    echo '```json'
    jq '.' "$evidence_file"
    echo '```'
    echo
    echo "## Judge Output"
    echo
    echo '```json'
    jq '.' "$judge_output"
    echo '```'
  } > "$plan_report_path"

  # Call index-writer.sh ONLY when task-bound
  if [ -n "$task_id" ]; then
    if [ ! -x "$INDEX_WRITER" ]; then
      echo "engine.sh: index-writer.sh not executable at $INDEX_WRITER" >&2
      exit 6
    fi
    if ! "$INDEX_WRITER" "$task_id" "$plan_report_path" "$max_verdict_confidence" "$max_finding_confidence" >&2; then
      echo "engine.sh: failed to update .claude/council/index.json" >&2
      exit 6
    fi
  fi

  # Stdout summary (contract from SKILL.md Phase 6)
  printf '%d verdicts | %d findings written to %s\n' \
    "$verdict_count" "$finding_count" "$plan_report_path"
}

# ---- Dispatch ---------------------------------------------------------------
if [ $# -lt 1 ]; then
  usage
  exit 2
fi

SUBCMD="$1"; shift
case "$SUBCMD" in
  preflight)       cmd_preflight "$@" ;;
  finalize)        cmd_finalize "$@" ;;
  resolve-task-id) cmd_resolve_task_id "$@" ;;
  report-path)     cmd_report_path "$@" ;;
  -h|--help|help)  usage; exit 0 ;;
  *)
    echo "engine.sh: unknown subcommand: $SUBCMD" >&2
    usage
    exit 2
    ;;
esac
