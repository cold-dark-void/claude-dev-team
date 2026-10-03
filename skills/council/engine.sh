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
#   preflight — parse args, resolve scope/task-id/preset (from-retro loads
#     $MROOT/.claude/retro/anchors/<id>.json), emit an investigation-plan
#     JSON document to stdout describing what the orchestrating Claude must
#     spawn for phases 1-5.
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
M14_AC_SPLIT="$SCRIPT_DIR/m14-ac-split.sh"

# ---- M14 claim budget (normative; SPEC-033 M14(j), WP 1-14) -----------------
# The maximum technical AC count an M14 per-AC split (SPEC-013 Phase 1 "M14
# per-AC split") accepts. Only the Tech Lead may raise this, with a committed
# change to these two lines plus a new SPEC-033 Version History row -- never
# an environment variable, a flag, a plan field or a spec field. Applies to
# M14 split runs only; every other /council caller keeps the SPEC-013
# per-run claim budget of 10 (unaffected below).
readonly M14_AC_BUDGET=16
readonly M14_AC_BUDGET_CEILING=20

# ---- Investigator tool budgets (normative; SPEC-033 M14(j), WP 1-15) -------
# An M14 claim with a Verify command gets M14_VERIFY_TOOL_BUDGET investigator
# tool calls (the verify run plus the citation calls); every other claim,
# M14 or not, keeps INVESTIGATOR_TOOL_BUDGET (SPEC-013 interface contract C2).
readonly M14_VERIFY_TOOL_BUDGET=8
readonly INVESTIGATOR_TOOL_BUDGET=5


# ---- Sourced helpers (L-10 / rv-w3-39-style decompose; no behavior change) ---
# Each helper is pure function definitions; engine.sh stays the only entry
# point (subprocess CLI — never source this script).
. "$SCRIPT_DIR/engine-util.sh"
. "$SCRIPT_DIR/engine-report-path.sh"
. "$SCRIPT_DIR/engine-preflight.sh"
. "$SCRIPT_DIR/engine-finalize.sh"
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
  m14-check)       cmd_m14_check "$@" ;;
  -h|--help|help)  usage; exit 0 ;;
  *)
    echo "engine.sh: unknown subcommand: $SUBCMD" >&2
    usage
    exit 2
    ;;
esac
