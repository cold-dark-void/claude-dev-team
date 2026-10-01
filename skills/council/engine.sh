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

# ---- Usage ------------------------------------------------------------------
usage() {
  cat >&2 <<'USAGE'
Usage: engine.sh <subcommand> [args...]

Subcommands:
  preflight        [--scope claim|session|diff|plan|from-retro] [--scope-arg V]
                   [--last N] [--task-id ID] [--preset NAME] [--why]
                   [--external[=codex|gemini]]
                   [--tier light|full] [--grading-reason TEXT]
                   Emits investigation-plan JSON on stdout.

  finalize         --plan-file P --evidence-file E --judge-output J
                   [--task-id ID] [--report-out PATH]
                   [--verification-mode full|self-verified]
                   [--tokens-file PATH]
                   Renders report, writes index row; optional Tokens summary.

  resolve-task-id  [--task-id ID]   Print resolved id (or empty line).
  report-path SLUG [--task-id ID]   Print canonical report path.
                   Probes for the first free candidate (report-path[-<N>].md,
                   report AND its .finalize-meta.json sidecar both absent);
                   reserves nothing (SPEC-013 Phase 6 report no-overwrite).

  m14-check TICKET_ID SPEC-FILE     SPEC-033 M14(g)/(j) split + budget check
                   (shared by preflight's M14 trigger and the
                   skills/orchestrate/steps/10-qa.md Step 10b writers
                   backstop -- one implementation, no copy). Exit 0: prints
                   the m14-ac-split.sh split JSON on stdout, unchanged.
                   Exit 8: one "m14-ac-split: <cause>" stderr line (case
                   1-9 per m14-ac-split.sh / SPEC-033 M14(g)/(j)), no
                   stdout. Exit 64: argv misuse.

Exit codes: 0 ok | 1 jq required but not found | 2 usage/no-scope | 3 reserved (unused; no deferred scopes)
            4 unknown preset | 5 empty evidence | 6 index-writer failure | 7 schema mismatch
            8 M14 per-AC split fails closed (SPEC-033 M14(g)) | m14-ac-split: <cause>
            9 report no-overwrite: every candidate up to -99 is taken
            64 m14-check: argv misuse
            127 python3 required but not found (not exit 1 — that code is jq)
USAGE
}

# A value flag needs a value. With one argument left, `shift 2` fails without
# shifting, and under `set -e` the script exits 1 with no message (WP 2-02).
# need_val <flag> <$#> — exit 2 with the usage text when no value follows.
need_val() {
  [ "$2" -ge 2 ] || { echo "engine.sh: $1 needs a value" >&2; usage; exit 2; }
}

# ---- Dependency check -------------------------------------------------------
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "engine.sh: jq is required but not found in PATH" >&2
    exit 1
  fi
}

# Exit 127, not 1. Exit 1 already means "jq required".
require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "engine.sh: python3 is required but not found in PATH" >&2
    exit 127
  fi
}

# ---- resolve-task-id --------------------------------------------------------
# Fallback: --task-id flag → CLAUDE_TASK_ID env → empty. Never errors.
cmd_resolve_task_id() {
  local tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) need_val "$1" $#; tid="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$tid" ]; then
    tid="${CLAUDE_TASK_ID:-}"
  fi
  printf '%s\n' "$tid"
}

# ---- path-safe validation ----------------------------------------------------
# Reject any value containing path traversal characters.
validate_path_component() {
  local label="$1" value="$2"
  # ".." matches the character class; reject it so a slug or task-id cannot
  # walk out of .claude/council. "/" already fails the class.
  if [[ "$value" == *..* ]] || [[ "$value" == */* ]] || ! [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "engine.sh: invalid $label: must match [a-zA-Z0-9._-]+" >&2
    exit 2
  fi
}

# ---- report-path ------------------------------------------------------------
# $MROOT/.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>][-<N>].md
#
# Report no-overwrite (SPEC-013 Phase 6, WP 1-14). A candidate is free iff
# BOTH the report file and its `.finalize-meta.json` sidecar are absent. The
# base candidate (no `-<N>`) is tried first; on a collision `-2` .. `-99` are
# tried in filename order. `-<N>` sits directly before `.md`, after the
# task-id suffix.
#
# _report_path_candidate/_report_path_free are pure helpers shared by the
# read-only probe (cmd_report_path, used by preflight and the `report-path`
# subcommand — reserves nothing) and the write-time reservation
# (finalize_reserve_report_path, used by finalize only).
_report_path_candidate() {  # <slug> <task-id|""> <date> <n (1..99)>
  local slug="$1" tid="$2" date="$3" n="$4"
  local suffix="" nsuf=""
  [ -n "$tid" ] && suffix="--${tid}"
  [ "$n" -gt 1 ] && nsuf="-${n}"
  printf '%s/%s-%s%s%s.md\n' "$COUNCIL_DIR" "$date" "$slug" "$suffix" "$nsuf"
}

_report_path_free() {  # <candidate report path>
  [ ! -e "$1" ] && [ ! -e "${1}.finalize-meta.json" ]
}

# Scans candidates 1..99 for <slug>/<tid>/<date>, calling <pred-fn> on each
# one. Prints the first candidate <pred-fn> accepts and returns 0. Returns 9
# (no stdout) once every candidate up to -99 is rejected. Shared by the
# read-only probe (_report_path_free) and the write-time reservation
# (_report_path_try_reserve) — same scan order, different predicate (tech-lead
# review r1, B5: was two copies of this loop).
_report_path_scan() {  # <pred-fn> <slug> <tid> <date>
  local pred="$1" slug="$2" tid="$3" date="$4"
  local n cand
  for n in {1..99}; do
    cand=$(_report_path_candidate "$slug" "$tid" "$date" "$n")
    if "$pred" "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 9
}

# Probe only — never creates anything. Returns the first free candidate.
cmd_report_path() {
  if [ $# -lt 1 ]; then
    echo "engine.sh: report-path requires <slug>" >&2
    exit 2
  fi
  local slug="$1"; shift
  validate_path_component "slug" "$slug"
  local tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) need_val "$1" $#; tid="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$tid" ]; then
    validate_path_component "task-id" "$tid"
  fi
  local date
  date=$(date -u +%Y-%m-%d)  # UTC per SKILL.md report-path contract
  if _report_path_scan _report_path_free "$slug" "$tid" "$date"; then
    return 0
  fi
  echo "engine.sh: report-path: every candidate up to -99 is taken for slug '$slug' (report no-overwrite, SPEC-013 Phase 6)" >&2
  exit 9
}

# ---- report-path reservation (finalize write-time only) ---------------------
# Sequential exclusive creates of the report file then its sidecar — NOT a
# single atomic transaction over the pair (WP 1-14 plan-review finding: bash
# has no cross-file atomic create; "atomic as a pair" was struck as
# unimplementable). Each attempt is two O_EXCL creates (bash `noclobber`)
# with a rollback of the first placeholder when the second create fails.
_report_path_try_reserve() {  # <candidate report path>
  local report="$1" meta="${1}.finalize-meta.json"
  if ( set -C; : > "$report" ) 2>/dev/null; then
    if ( set -C; : > "$meta" ) 2>/dev/null; then
      return 0
    fi
    rm -f -- "$report"
    return 1
  fi
  return 1
}

# Reserves a report path at finalize write time. Tries $3 (plan.report_path,
# already task-id-adjusted by the caller) first; if that candidate is taken,
# scans base .. -99 at TODAY's UTC date (the finalize date, which may differ
# from the plan's original preflight date). Prints the reserved path and
# returns 0. Returns 9 (no stdout) once every candidate up to -99 is taken —
# the caller MUST exit 9 and write no report.
finalize_reserve_report_path() {  # <slug> <task-id|""> <preferred path>
  local slug="$1" tid="$2" preferred="$3"
  mkdir -p "$COUNCIL_DIR"
  if [ -n "$preferred" ] && _report_path_try_reserve "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi
  local date
  date=$(date -u +%Y-%m-%d)
  _report_path_scan _report_path_try_reserve "$slug" "$tid" "$date"
}

# ---- m14_check ---------------------------------------------------------
# Shared implementation of the SPEC-033 M14(g)/(j) split + budget check
# (WP 1-14 review round 2, B-2). ONE function backs both cmd_preflight's
# M14 trigger (in-process call) and the "m14-check" subcommand (direct CLI
# use, e.g. skills/orchestrate/steps/10-qa.md Step 10b) -- never a copy of
# the constant or the ceiling/budget arithmetic.
#
# $1 = ticket_id, $2 = ac_source (path, worktree-relative). On the M14(j)
# ceiling guard or m14-ac-split.sh's case 9 (the claim budget) this prints
# exactly one "m14-ac-split: <cause>" stderr line and exits 8, matching
# m14-ac-split.sh's own case 1-8 contract (C1) so every caller sees one
# uniform failure shape. m14-ac-split.sh's own exit (8 for cases 1-8, 64
# for its argv misuse) propagates unchanged. On success this prints the
# split JSON from m14-ac-split.sh to stdout, unmodified, and returns 0.
m14_check() {
  local ticket_id="$1" ac_source="$2"
  # M14(j): a budget above the ceiling fails every M14 split closed,
  # independent of the actual technical AC count (config-validity guard;
  # unreachable with the constants above, but must fail closed if a
  # future committed change ever violates it).
  if [ "$M14_AC_BUDGET" -gt "$M14_AC_BUDGET_CEILING" ]; then
    echo "m14-ac-split: M14_AC_BUDGET ($M14_AC_BUDGET) exceeds M14_AC_BUDGET_CEILING ($M14_AC_BUDGET_CEILING) -- every M14 split fails closed (SPEC-033 M14(j))" >&2
    exit 8
  fi
  local split_json
  split_json=$(bash "$M14_AC_SPLIT" "$ticket_id" "$ac_source") || exit $?
  local technical_count
  technical_count=$(printf '%s' "$split_json" | jq '[.acs[] | select(.process == false)] | length')
  if [ "$technical_count" -gt "$M14_AC_BUDGET" ]; then
    local over_ids
    over_ids=$(printf '%s' "$split_json" | jq -r --argjson b "$M14_AC_BUDGET" \
      '[.acs[] | select(.process == false)] | .[$b:] | map(.id) | join(", ")')
    echo "m14-ac-split: case 9: technical AC count ($technical_count) exceeds the M14 claim budget ($M14_AC_BUDGET); ids beyond budget: $over_ids" >&2
    exit 8
  fi
  printf '%s\n' "$split_json"
}

# ---- m14-check subcommand ----------------------------------------------
# CLI entry point for m14_check. Argv misuse (wrong arg count) exits 64,
# matching m14-ac-split.sh's own argv-misuse code (C1).
cmd_m14_check() {
  if [ $# -ne 2 ]; then
    echo "engine.sh: usage: engine.sh m14-check <ticket_id> <spec-file>" >&2
    exit 64
  fi
  m14_check "$1" "$2"
}

# ---- preflight --------------------------------------------------------------
# Parse scope flags → validate → resolve preset → emit investigation-plan
# JSON to stdout. No-scope / missing from-retro anchor / bad plan path → exit 2;
# bad preset → exit 4. Exit 3 reserved (no deferred scopes remain after CDV-212).
cmd_preflight() {
  require_jq

  local scope="" scope_arg="" last="" task_id="" preset="" why="false"
  local preset_source="inferred"
  local resolved_claim="" anchor_file=""
  local external="false" external_prefer="auto"
  local council_tier="" grading_reason=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)     need_val "$1" $#; scope="$2"; shift 2 ;;
      --scope-arg) need_val "$1" $#; scope_arg="$2"; shift 2 ;;
      --last)      need_val "$1" $#; last="$2"; shift 2 ;;
      --task-id)   need_val "$1" $#; task_id="$2"; shift 2 ;;
      --preset)    need_val "$1" $#; preset="$2"; preset_source="explicit"; shift 2 ;;
      --why)       why="true"; shift ;;
      # CDT-126: tier resolved by the caller (commands/council.md Step 1.5 —
      # grading, or an externally-supplied DRI/ship-gate tier). The engine
      # never grades; it only consumes the resolved value.
      --tier)           need_val "$1" $#; council_tier="$2"; shift 2 ;;
      --grading-reason) need_val "$1" $#; grading_reason="$2"; shift 2 ;;
      # CDV-207: optional external investigator (codex/gemini). Forms:
      #   --external | --external=codex|gemini | --external codex|gemini
      --external)
        external="true"
        if [ -n "${2:-}" ] && [[ "${2}" != --* ]]; then
          external_prefer="${2}"
          shift 2
        else
          external_prefer="auto"
          shift
        fi
        ;;
      --external=*)
        external="true"
        external_prefer="${1#--external=}"
        [ -n "$external_prefer" ] || external_prefer="auto"
        shift
        ;;
      *)
        echo "engine.sh: unknown preflight flag: $1" >&2
        exit 2
        ;;
    esac
  done

  case "$external_prefer" in
    auto|codex|gemini) ;;
    *)
      echo "engine.sh: invalid --external value: $external_prefer (want codex|gemini)" >&2
      exit 2
      ;;
  esac

  # CDT-126 tier validation. `skip` short-circuits the whole run at the call
  # site and must never reach the engine; anything else is a caller bug, and
  # the caller has already fail-closed to `full` before invoking us (SPEC-013
  # § Council tiering, Fail-closed contract), so coercing here would mask it.
  case "$council_tier" in
    light|full) ;;
    "")
      council_tier="full"
      [ -n "$grading_reason" ] || grading_reason="ungraded: no tier supplied (default full)"
      ;;
    skip)
      echo "engine.sh: --tier skip is resolved by the caller — the run must not reach preflight" >&2
      exit 2
      ;;
    *)
      echo "engine.sh: invalid --tier value: $council_tier (want light|full)" >&2
      exit 2
      ;;
  esac
  if [ -z "$grading_reason" ]; then
    grading_reason="externally supplied tier (no grading_reason given)"
  fi

  # No-scope invocation → usage error (exit 2)
  if [ -z "$scope" ]; then
    echo "engine.sh: scope required (--scope claim|session|diff|plan|from-retro)" >&2
    usage
    exit 2
  fi

  # Plan scope: require a readable file path (missing/unreadable → exit 2)
  if [ "$scope" = "plan" ]; then
    if [ -z "$scope_arg" ]; then
      echo "engine.sh: --plan requires a path (--scope-arg <path>)" >&2
      exit 2
    fi
    if [ ! -f "$scope_arg" ] || [ ! -r "$scope_arg" ]; then
      echo "engine.sh: plan file not found or not readable: $scope_arg" >&2
      exit 2
    fi
  fi

  # from-retro: load $MROOT/.claude/retro/anchors/<id>.json (CDV-212 design a).
  # Missing/unreadable/malformed → exit 2 (not deferred). Claim already isolated
  # → Phase 1 skip; resolved_claim carries fabricated_claim_text for Phase 2.
  if [ "$scope" = "from-retro" ]; then
    if [ -z "$scope_arg" ]; then
      echo "engine.sh: --from-retro requires an anchor-id (--scope-arg <id>)" >&2
      exit 2
    fi
    validate_path_component "anchor-id" "$scope_arg"
    anchor_file="$MROOT/.claude/retro/anchors/${scope_arg}.json"
    if [ ! -f "$anchor_file" ] || [ ! -r "$anchor_file" ]; then
      echo "engine.sh: retro anchor not found: $anchor_file" >&2
      exit 2
    fi
    if ! jq -e . "$anchor_file" >/dev/null 2>&1; then
      echo "engine.sh: retro anchor is not valid JSON: $anchor_file" >&2
      exit 2
    fi
    resolved_claim=$(jq -r '.fabricated_claim_text // empty' "$anchor_file")
    if [ -z "$resolved_claim" ]; then
      echo "engine.sh: retro anchor missing fabricated_claim_text: $anchor_file" >&2
      exit 2
    fi
  fi

  # Resolve task-id via fallback chain
  if [ -z "$task_id" ]; then
    task_id="${CLAUDE_TASK_ID:-}"
  fi

  # Scope is validated even when --preset is explicit. An explicit preset
  # used to skip this case, so `--scope bogus --preset generic` was accepted.
  case "$scope" in
    claim|session|diff|plan|from-retro) ;;
    *)
      echo "engine.sh: unknown scope: $scope" >&2
      exit 2
      ;;
  esac

  # Resolve preset (explicit or inferred from scope)
  if [ -z "$preset" ]; then
    preset_source="inferred"
    case "$scope" in
      diff) preset="diff-mode" ;;
      *)    preset="generic" ;;
    esac
  fi

  # Preset table (COUNCIL-001 hardcoded — see SKILL.md "Presets" section).
  local output_shape feedback_enabled spec_grep confidence_filter flavors
  case "$preset" in
    generic)
      output_shape="verdict[]"; feedback_enabled="true"; spec_grep="false"
      confidence_filter="null"
      flavors='["paranoid-ic","skeptic-ic"]' ;;
    diff-mode)
      output_shape="finding[]"; feedback_enabled="false"; spec_grep="true"
      confidence_filter="80"
      flavors='["logic","security","compliance","quality","simplification"]' ;;
    *)
      echo "engine.sh: unknown preset: $preset — known: generic, diff-mode" >&2
      exit 4 ;;
  esac

  # CDT-126 light flavor subsets (SPEC-013 § Council tiering). `generic` is
  # already exactly the 2 distinct Phase 2 flavors light requires (paranoid-ic
  # + skeptic-ic), so it is unchanged;
  # `diff-mode` keeps the two correctness/safety axes and drops the three
  # polish axes.
  if [ "$council_tier" = "light" ] && [ "$preset" = "diff-mode" ]; then
    flavors='["logic","security"]'
  fi

  local claim_budget=10  # SPEC-013 "per-run claim budget (default: 10 claims)", hardcoded in v1

  # ---- M14 per-AC split (SPEC-033 M14(g); SPEC-013 Phase 1 "M14 per-AC
  # split"; WP 1-14 interface contracts C1/C2). Trigger: scope==claim AND
  # scope_arg starts "Ship-gate audit for <ticket_id>." AND >=1 ac-source=
  # token. Zero ac-source= tokens does NOT split -- the plan stays exactly
  # as it was before WP 1-14 (AC G; the mapper then halts it, SPEC-033
  # M14(g)). Every stderr line below is prefixed "m14-ac-split:" (never
  # "engine.sh:") to match m14-ac-split.sh's own contract (C1) and the
  # SKILL.md exit-8 failure-table row.
  local m14_triggered="false" m14_claims_json="[]" m14_ac_source="" \
        m14_process_acs_json="[]"
  if [ "$scope" = "claim" ] \
     && [[ "$scope_arg" =~ ^Ship-gate\ audit\ for\ ([A-Za-z0-9._-]+)\. ]]; then
    local m14_ticket_id="${BASH_REMATCH[1]}"
    local m14_tokens m14_token_count=0
    m14_tokens="$(printf '%s' "$scope_arg" | grep -oE 'ac-source=[^[:space:]]+' || true)"
    [ -n "$m14_tokens" ] && m14_token_count=$(printf '%s\n' "$m14_tokens" | wc -l | tr -d ' ')
    if [ "$m14_token_count" -ge 1 ]; then
      m14_triggered="true"
      if [ "$m14_token_count" -ge 2 ]; then
        echo "m14-ac-split: case 1: envelope holds $m14_token_count ac-source= tokens (must hold exactly one)" >&2
        exit 8
      fi
      # WP 1-14 review round 2 (B-2): the ceiling check, the split, and the
      # case-9 budget check live in ONE place, m14_check (defined above) --
      # no copy of M14_AC_BUDGET or its arithmetic here.
      m14_ac_source="${m14_tokens#ac-source=}"
      local m14_split_json
      m14_split_json=$(m14_check "$m14_ticket_id" "$m14_ac_source")
      claim_budget="$M14_AC_BUDGET"  # SPEC-033 M14(j) -- overrides the generic 10 above
      m14_process_acs_json=$(printf '%s' "$m14_split_json" | jq -c '[.acs[] | select(.process == true) | .id]')
      # SPEC-013 Phase 1 claim record + exact template (WP 1-14 C2). Index i
      # (0-based) runs over the technical-only array, in document order.
      m14_claims_json=$(printf '%s' "$m14_split_json" | jq -c \
        --arg ticket_id "$m14_ticket_id" --arg path "$m14_ac_source" \
        --argjson default_budget "$INVESTIGATOR_TOOL_BUDGET" \
        --argjson verify_budget "$M14_VERIFY_TOOL_BUDGET" '
        [ .acs[] | select(.process == false) ] as $tech
        | [ range(0; ($tech | length)) as $i
            | ($tech[$i]) as $ac
            | {
                claim_id: ("c" + ($i | tostring)),
                ac_id: $ac.id,
                claim: ("[AC-" + $ac.id + "] For " + $ticket_id +
                        ", the diff from the merge-base of the origin default branch and HEAD to HEAD satisfies acceptance criterion " +
                        $ac.id + " as written at " + $path + ":" + ($ac.line | tostring) +
                        ". Read the criterion at that locator and judge this criterion only."),
                source_locator: ($path + ":" + ($ac.line | tostring)),
                claim_type: "factual",
                verify: ($ac.verify // null),
                tool_budget: (if ($ac.verify // null) == null then $default_budget else $verify_budget end)
              }
          ]
        ')
    fi
  fi

  local slug
  case "$scope" in
    claim)   slug="claim" ;;
    session) slug="session${last:+-last-$last}" ;;
    diff)    slug="diff-staged" ;;
    plan)
      # Slug from plan basename (path-safe for report-path validation)
      local base
      base=$(basename -- "$scope_arg")
      base="${base%.*}"
      # POSIX BRE. Strip a leading-dash run without a GNU-only plus.
      slug=$(printf '%s' "$base" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/--*/-/g;s/^-//;s/-$//')
      [ -z "$slug" ] && slug="plan"
      slug="plan-${slug}"
      ;;
    from-retro)
      slug="from-retro-${scope_arg}"
      ;;
    *)       slug="$scope" ;;
  esac
  local report_path
  report_path=$(cmd_report_path "$slug" --task-id "$task_id")

  # Phase 1 prompt: plan scope uses plan-extractor; others use claim-extractor.
  # skip=true for single pasted claim and from-retro (claim already isolated).
  local phase1_prompt="skills/council/prompts/claim-extractor.md"
  if [ "$scope" = "plan" ]; then
    phase1_prompt="skills/council/prompts/plan-extractor.md"
  fi

  # Build the investigation plan JSON for the orchestrating Claude. This is
  # the contract: the Claude that invoked /council reads this document and
  # uses it to drive Phase 1-5 via Task-tool spawns.
  # When --why: include why_detail (CDV-206) for stdout debug after summary.
  # Do not dump raw prompts. phase3_specialist at preflight is a plan stub;
  # commands/council.md overwrites the printed value after runtime classify (CDV-209).
  # from-retro: resolved_claim is fabricated_claim_text; scope_arg remains anchor-id.
  # Phase 3 skip for finding[] (diff-mode): flavors already cover specialist axes.
  # CDT-126 adds a second, independent skip condition: council_tier == light.
  local phase3_skip_reason="" phase3_why_stub
  if [ "$output_shape" = "finding[]" ]; then
    phase3_skip_reason="diff-mode (finding[] flavors cover specialist axes)"
    phase3_why_stub="skipped (diff-mode)"
  elif [ "$council_tier" = "light" ]; then
    phase3_skip_reason="council_tier: light"
    phase3_why_stub="skipped (council_tier: light)"
  else
    phase3_why_stub="pending (runtime classify)"
  fi

  # CDT-126: Phase 4 is keyed off TWO independent conditions — the
  # pre-existing finding[]-shape skip AND council_tier == light. Phase 5's
  # brief inputs and Phase 6's brief report sections follow the same key
  # (SPEC-013 Phases 4/5/6): when Phase 4 did not run, the Judge receives
  # claims + evidence bundles only and no brief is synthesized or stubbed.
  # Empty reason == Phase 4 runs, matching the Phase 3 block just above.
  local phase4_skip_reason=""
  if [ "$output_shape" = "finding[]" ]; then
    phase4_skip_reason="finding[]-shape preset"
  fi
  if [ "$council_tier" = "light" ]; then
    if [ -n "$phase4_skip_reason" ]; then
      phase4_skip_reason="${phase4_skip_reason}; council_tier: light"
    else
      phase4_skip_reason="council_tier: light"
    fi
  fi

  # CDV-211: per-run investigator tool-call cache under TMPDIR.
  # Layout: $cache_dir/{reads,greps}/<sha256>.txt + manifest.json.
  # Correctness unchanged if empty; finalize best-effort rm -rf.
  local cache_dir run_id
  cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/council-cache-XXXXXXXX") \
    || { echo "engine.sh: failed to create council-cache dir under TMPDIR" >&2; exit 2; }
  run_id=$(basename -- "$cache_dir" | sed 's/^council-cache-//')
  mkdir -p "$cache_dir/reads" "$cache_dir/greps"
  printf '%s\n' '{"version":1,"entries":[]}' > "$cache_dir/manifest.json"

  # CDV-207: optional external investigator detection (never hard-fail on miss).
  # External is additive — plan.flavors (internal) are never reduced.
  local external_json
  if [ "$external" = "true" ]; then
    local EXT_HELPER="$SCRIPT_DIR/external-reviewer.sh"
    local det_json det_status det_tool det_reason
    if [ -x "$EXT_HELPER" ]; then
      # stderr (skip notices) passes through; only stdout is capture-bound.
      det_json=$(bash "$EXT_HELPER" detect --prefer "$external_prefer") \
        || det_json='{"status":"skipped","tool":null,"reason":"detect failed"}'
    else
      det_json='{"status":"skipped","tool":null,"reason":"external-reviewer.sh not found"}'
      echo "engine.sh: external-reviewer.sh not found — skipping external slot" >&2
    fi
    det_status=$(printf '%s' "$det_json" | jq -r '.status // "skipped"')
    det_tool=$(printf '%s' "$det_json" | jq -r '.tool // empty')
    det_reason=$(printf '%s' "$det_json" | jq -r '.reason // empty')
    # Map detect → plan.external (available|skipped). Never exit non-zero here.
    external_json=$(jq -n \
      --arg prefer "$external_prefer" \
      --arg status "$det_status" \
      --arg tool "$det_tool" \
      --arg reason "$det_reason" \
      '{
        requested: true,
        prefer: $prefer,
        status: (if $status == "available" then "available" else "skipped" end),
        tool: (if $tool == "" then null else $tool end),
        reason: $reason,
        helper: "skills/council/external-reviewer.sh",
        flavor: "skills/council/flavors/external.md"
      }')
  else
    external_json='{"requested":false}'
  fi

  jq -n \
    --arg scope "$scope" \
    --arg scope_arg "$scope_arg" \
    --arg resolved_claim "$resolved_claim" \
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
    --arg preset_source "$preset_source" \
    --arg slug "$slug" \
    --arg report_path "$report_path" \
    --arg mroot "$MROOT" \
    --arg phase1_prompt "$phase1_prompt" \
    --arg phase3_why_stub "$phase3_why_stub" \
    --arg council_tier "$council_tier" \
    --arg grading_reason "$grading_reason" \
    --arg phase3_skip_reason "$phase3_skip_reason" \
    --arg phase4_skip_reason "$phase4_skip_reason" \
    --arg cache_dir "$cache_dir" \
    --arg run_id "$run_id" \
    --argjson external "$external_json" \
    --arg m14_triggered "$m14_triggered" \
    --argjson m14_claims "$m14_claims_json" \
    --arg m14_ac_source "$m14_ac_source" \
    --argjson m14_process_acs "$m14_process_acs_json" \
    '{
      scope: $scope,
      scope_arg: $scope_arg,
      resolved_claim: $resolved_claim,
      last: $last,
      task_id: $task_id,
      preset: $preset,
      output_shape: $output_shape,
      council_tier: $council_tier,
      grading_reason: $grading_reason,
      flavors: $flavors,
      external: $external,
      spec_grep: ($spec_grep == "true"),
      feedback_memory_enabled: ($feedback_enabled == "true"),
      confidence_filter_threshold: (if $confidence_filter == "null" then null else ($confidence_filter | tonumber) end),
      claim_budget: $claim_budget,
      why: ($why == "true"),
      slug: $slug,
      report_path: $report_path,
      mroot: $mroot,
      run_id: $run_id,
      cache_dir: $cache_dir,
      phases: {
        "1_claim_extraction": { skip: ($scope == "claim" or $scope == "from-retro"), prompt: $phase1_prompt },
        "2_parallel_investigation": { min_flavors_per_claim: 2, prompt: "skills/council/prompts/investigator.md" },
        # Phase 3 (CDV-209): topic classify → at most one team-agent specialist.
        # Runs before Phase 2.5. Skipped for finding[] (diff-mode) and at
        # council_tier: light (CDT-126).
        "3_domain_specialist": (
          if $phase3_skip_reason != ""
          then { deferred: false, skipped: true, reason: $phase3_skip_reason, confidence_threshold: 0.75, max_specialists_per_run: 1, classifier_prompt: "skills/council/prompts/topic-classifier.md", specialist_prompt: "skills/council/prompts/investigator.md" }
          else { deferred: false, skipped: false, confidence_threshold: 0.75, max_specialists_per_run: 1, classifier_prompt: "skills/council/prompts/topic-classifier.md", specialist_prompt: "skills/council/prompts/investigator.md", agents: ["devops", "ds", "qa", "pm"] }
          end
        ),
        # Phase 4 runs for verdict[]-shape presets at council_tier: full.
        # finding[]-shape (diff-mode) routes specialist findings straight to the
        # judge — there is no prosecutor/advocate step. See review-and-commit/SKILL.md
        # ("Phase 4 — skipped in diff-mode") and commands/council.md Phase 4.
        # council_tier: light skips it too (CDT-126) — a second, independent
        # condition, not a restatement of the shape one.
        "4_prosecution_defense": (
          if $phase4_skip_reason == ""
          then { prosecutor: { prompt: "skills/council/prompts/phase4-brief.md", role: "Prosecutor", evidence_field: "evidence_against", flavor: "jaded-senior" }, advocate: { prompt: "skills/council/prompts/phase4-brief.md", role: "Devil\u0027s Advocate", evidence_field: "evidence_for", flavor: "yolo-ic" } }
          else { skipped: true, reason: $phase4_skip_reason }
          end
        ),
        # Judge inputs: claims + evidence bundles ALWAYS; the two Phase-4 briefs
        # only when Phase 4 ran. A skipped Phase 4 is never papered over with a
        # synthesized, stubbed, or empty-string brief (SPEC-013 Phase 5).
        "5_judgment": (
          { agent: "council-judge", prompt: "skills/council/prompts/judge.md" }
          + (if $phase4_skip_reason == ""
             then { inputs: ["claims", "evidence_bundles", "prosecutor_brief", "advocate_brief"] }
             else { inputs: ["claims", "evidence_bundles"], briefs_omitted: true, briefs_omitted_reason: $phase4_skip_reason }
             end)
        ),
        "6_finalize": { invoke: "engine.sh finalize --plan-file <p> --evidence-file <e> --judge-output <j>" }
      }
    }
    | if $m14_triggered == "true" then
        . + { claims: $m14_claims, ac_source: $m14_ac_source, process_acs: $m14_process_acs }
      else .
      end
    | if $why == "true" then
        . + {
          why_detail: {
            preset: $preset,
            flavors: $flavors,
            council_tier: $council_tier,
            grading_reason: $grading_reason,
            phase3_specialist: $phase3_why_stub,
            claim_budget: $claim_budget,
            preset_source: $preset_source,
            external: $external
          }
        }
      else .
      end'
}

# ---- shared JSON repair -----------------------------------------------------
# repair_json_file <file> <mode> <err_label> <exit_code>
#   <mode>: "evidence" or "judge". Judge mode runs a markdown-fence-strip
#           pre-step before the shared backslash repair; evidence mode does not.
#   <err_label>: human label used in stderr messages ("evidence file" / "judge output").
#   <exit_code>: process exit code on unrepairable input (5 evidence / 7 judge).
#
# LLM-emitted JSON commonly contains unescaped backslashes inside string values
# (regex like \d \w \., paths) and — for judge output — markdown fences. This
# walks the raw text char-by-char, doubling any backslash inside a JSON string
# that is not part of a valid escape (" \ / b f n r t u).
#
# errexit note: engine.sh runs under `set -euo pipefail`. A python3 non-zero
# exit fires errexit before any later bash statement, so the per-mode exit
# code MUST be produced by sys.exit(int(code)) inside python (driven by the
# exit_code argv). Do not add a bash `$?` guard after this call.
repair_json_file() {
  local _file="$1" _mode="$2" _label="$3" _code="$4"
  require_python3
  python3 - "$_file" "$_mode" "$_label" "$_code" <<'PYREPAIR'
import json, sys, re

path = sys.argv[1]
mode = sys.argv[2]
label = sys.argv[3]
exit_code = int(sys.argv[4])

with open(path, 'r') as f:
    raw = f.read()

# Try parsing as-is first
try:
    json.loads(raw)
    sys.exit(0)  # already valid
except json.JSONDecodeError:
    pass

# Judge-only: strip markdown fences if present (common LLM wrapping)
text = raw
if mode == 'judge':
    stripped = re.sub(r'^```(?:json)?\s*\n?', '', raw.strip())
    stripped = re.sub(r'\n?```\s*$', '', stripped)
    try:
        json.loads(stripped)
        with open(path, 'w') as f:
            f.write(stripped)
        print("engine.sh: stripped markdown fences from judge output", file=sys.stderr)
        sys.exit(0)
    except json.JSONDecodeError:
        pass
    text = stripped  # apply backslash repair to the fence-stripped version

# Repair: fix unescaped backslashes inside JSON string values.
# Walk the text char by char, tracking whether we're inside a JSON string.
# Inside strings, double any backslash that isn't followed by a valid JSON
# escape character: " \ / b f n r t u
VALID_ESCAPES = set('"\\/' + 'bfnrtu')
out = []
i = 0
in_string = False
while i < len(text):
    ch = text[i]
    if not in_string:
        if ch == '"':
            in_string = True
        out.append(ch)
        i += 1
    else:
        if ch == '"':
            in_string = False
            out.append(ch)
            i += 1
        elif ch == '\\':
            if i + 1 < len(text) and text[i + 1] in VALID_ESCAPES:
                # Valid JSON escape — keep as-is
                out.append(ch)
                out.append(text[i + 1])
                i += 2
            else:
                # Invalid escape (e.g. \d, \., \w) — double the backslash
                out.append('\\')
                out.append('\\')
                i += 1
        else:
            out.append(ch)
            i += 1

repaired = ''.join(out)

try:
    json.loads(repaired)
    with open(path, 'w') as f:
        f.write(repaired)
    # Evidence path historically appended a "(unescaped backslashes)" suffix;
    # judge path did not. Preserve both verbatim for byte-identical stderr.
    suffix = " (unescaped backslashes)" if mode == 'evidence' else ""
    print(f"engine.sh: repaired malformed JSON in {label}{suffix}", file=sys.stderr)
except json.JSONDecodeError as e:
    print(f"engine.sh: {label} is not valid JSON and repair failed: {e}", file=sys.stderr)
    if mode == 'judge':
        print(f"engine.sh: first 200 chars: {raw[:200]}", file=sys.stderr)
    sys.exit(exit_code)
PYREPAIR
}

# CDT-390: rewrite a top-level JSON array judge file to object form in place.
# Temp file sits beside the destination, then rename. Non-array files are
# left untouched. Returns non-zero only when the rewrite itself fails.
normalize_judge_shape() {
  local file="$1" shape="$2" kind key tmp
  kind=$(jq -r 'if type == "array" then "array" else "other" end' "$file" 2>/dev/null) || return 1
  if [ "$kind" != "array" ]; then
    return 0
  fi
  key="verdicts"
  if [ "$shape" = "finding[]" ]; then
    key="findings"
  fi
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if ! jq --arg k "$key" '{($k): .}' "$file" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$file"
}

# ---- finalize ---------------------------------------------------------------
# Consume plan + evidence + judge output, render report, write index row.
# Inputs: --plan-file, --evidence-file, --judge-output. Does not interpret
# semantics beyond branching on output_shape and computing max_confidence.
cmd_finalize() {
  require_jq
  require_python3

  local plan_file="" evidence_file="" judge_output="" task_id="" report_out=""
  local cross_review_status="" cross_review_rankings="" cross_review_scores=""
  local verification_mode="" tokens_file="" degradation_reason=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --plan-file)     need_val "$1" $#; plan_file="$2"; shift 2 ;;
      --evidence-file) need_val "$1" $#; evidence_file="$2"; shift 2 ;;
      --judge-output)  need_val "$1" $#; judge_output="$2"; shift 2 ;;
      --task-id)       need_val "$1" $#; task_id="$2"; shift 2 ;;
      --report-out)    need_val "$1" $#; report_out="$2"; shift 2 ;;
      --cross-review-status)    need_val "$1" $#; cross_review_status="$2"; shift 2 ;;
      --cross-review-rankings)  need_val "$1" $#; cross_review_rankings="$2"; shift 2 ;;
      --cross-review-scores)    need_val "$1" $#; cross_review_scores="$2"; shift 2 ;;
      --verification-mode)      need_val "$1" $#; verification_mode="$2"; shift 2 ;;
      --degradation-reason)     need_val "$1" $#; degradation_reason="$2"; shift 2 ;;
      --tokens-file)            need_val "$1" $#; tokens_file="$2"; shift 2 ;;
      *)
        echo "engine.sh: unknown finalize flag: $1" >&2
        exit 2
        ;;
    esac
  done

  # Default full (happy path). Accept only full|self-verified (CDV-199).
  if [ -z "$verification_mode" ]; then
    verification_mode="full"
  fi
  case "$verification_mode" in
    full|self-verified) ;;
    *)
      echo "engine.sh: --verification-mode must be full|self-verified (got: $verification_mode)" >&2
      exit 2
      ;;
  esac

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
  # Original on-disk value — used below to decide whether the plan file needs
  # rewriting after reservation (SPEC-013 Phase 6 "one path everywhere").
  local plan_report_path_orig="$plan_report_path"

  # CDT-126: the plan is the sole carrier of the tier — preflight resolved it,
  # finalize only records it (frontmatter + index row). Plans written before
  # tiering landed have neither key; those runs are `full` by definition.
  local council_tier grading_reason
  council_tier=$(jq -r '.council_tier // "full"' "$plan_file")
  grading_reason=$(jq -r '.grading_reason // ""' "$plan_file")
  # Coerce here, once, so the report and the index row cannot disagree: the
  # renderer used to fail closed to "full" on its own while index-writer.sh
  # hard-rejected the same raw value, which wrote a report claiming "full" and
  # then aborted the run with exit 6 and no index row.
  case "$council_tier" in
    light|full) ;;
    *)
      echo "engine.sh: plan carries an invalid council_tier ($council_tier) — failing closed to full" >&2
      council_tier="full"
      ;;
  esac

  # task-id on finalize overrides plan's task-id if given
  if [ -z "$task_id" ]; then
    task_id="$plan_task_id"
  fi

  # Reject a bad id before any report reservation, plan rewrite, or index
  # write. Empty task_id is unbound (no index row), not an error.
  if [ -n "$task_id" ]; then
    validate_path_component "task-id" "$task_id"
  fi
  if [ -n "$slug" ] && [ "$slug" != "null" ]; then
    validate_path_component "slug" "$slug"
  fi

  # Recompute report path if task_id changed (the plan's recorded path was
  # built for the old task-id suffix and names the wrong file entirely).
  if [ -n "$report_out" ]; then
    plan_report_path="$report_out"
  elif [ "$task_id" != "$plan_task_id" ]; then
    plan_report_path=$(cmd_report_path "$slug" --task-id "$task_id")
  fi

  # Report no-overwrite (SPEC-013 Phase 6, WP 1-14): reserve the path again
  # at write time, right before rendering. `--report-out` is exempt — it
  # reserves nothing and can overwrite; the caller that passes it owns that
  # risk (unchanged from before WP 1-14).
  if [ -z "$report_out" ]; then
    local reserved_path
    if ! reserved_path=$(finalize_reserve_report_path "$slug" "$task_id" "$plan_report_path"); then
      echo "engine.sh: report no-overwrite: every candidate up to -99 is taken for slug '$slug' — writing no report (SPEC-013 Phase 6)" >&2
      exit 9
    fi
    plan_report_path="$reserved_path"
    # One path everywhere: when the reserved path differs from what the plan
    # already recorded (a collision, or a task-id-driven recompute), rewrite
    # plan.report_path (tmp + rename) so plan / rendered report / sidecar /
    # `Council report:` line / index row all agree, and say so once on stderr.
    if [ "$plan_report_path" != "$plan_report_path_orig" ]; then
      local plan_tmp
      plan_tmp=$(mktemp "${plan_file}.XXXXXX")
      jq --arg rp "$plan_report_path" '.report_path = $rp' "$plan_file" > "$plan_tmp"
      mv -- "$plan_tmp" "$plan_file"
      echo "engine.sh: report_path reserved at $plan_report_path (plan recorded $plan_report_path_orig) — rewrote plan.report_path (SPEC-013 Phase 6 report no-overwrite)" >&2
    fi
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
    echo "engine.sh: report template missing: $template_file" >&2
    exit 7
  fi

  # Validate evidence file is parseable JSON. Investigator raw_blob fields
  # may contain code with backslashes (regex, paths) that the LLM fails to
  # escape properly. Attempt repair before any jq calls.
  if ! jq empty "$evidence_file" 2>/dev/null; then
    repair_json_file "$evidence_file" evidence "evidence file" 5
  fi

  # Validate evidence file is non-empty JSON array. An empty bundle set is
  # exit 5 per SKILL.md failure-mode table.
  local evidence_count
  evidence_count=$(jq 'if type == "array" then length elif type == "object" then (.bundles // .evidence_bundles // []) | length else 0 end' "$evidence_file")
  if [ "$evidence_count" = "0" ]; then
    echo "engine.sh: Phase 2 produced zero evidence bundles — aborting" >&2
    exit 5
  fi

  # Validate judge output is parseable JSON. The judge is an LLM agent and
  # may emit malformed JSON (markdown fences, trailing text, unescaped chars).
  # Apply the same backslash repair as evidence, then validate.
  if ! jq empty "$judge_output" 2>/dev/null; then
    repair_json_file "$judge_output" judge "judge output" 7
  fi

  # CDT-390: a top-level JSON array has no .verdicts / .findings. Wrap it
  # before render and before the stdout counters so those jq paths stay object
  # form. Verdict shape → {"verdicts":[...]} ; finding shape → {"findings":[...]}.
  if ! normalize_judge_shape "$judge_output" "$output_shape"; then
    echo "engine.sh: failed to normalize judge output shape" >&2
    exit 7
  fi

  # max_*_confidence + struck_count come from finalize-meta.json after render
  # (unstruck-only; CDT-178). Pre-python all-items max would desync the index.
  # Confidence ints via Python int() (floor-compatible with CDT-181 index-writer).

  # Ensure parent dir exists
  mkdir -p "$(dirname "$plan_report_path")"

  # Render report: python3 reads the template + all JSON inputs, substitutes
  # every {{VAR}} placeholder, and writes the fully-rendered report.
  local created_at
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  export COUNCIL_SKILL_DIR="$SCRIPT_DIR"
  python3 - "$template_file" "$plan_file" "$evidence_file" "$judge_output" \
    "$plan_report_path" "$scope" "$preset" "$output_shape" "$created_at" \
    "$task_id" "$cross_review_status" "$cross_review_rankings" \
    "$cross_review_scores" "$verification_mode" "${tokens_file:-}" \
    "$council_tier" "$grading_reason" "$degradation_reason" <<'PYEOF'
import json, sys, os, re, math
from collections import Counter

# WP 1-15 C6: report_labels.py resolves claim ids/text for the report (AC H).
# COUNCIL_SKILL_DIR is engine.sh's own SCRIPT_DIR, set on the invocation.
sys.path.insert(0, os.environ["COUNCIL_SKILL_DIR"])
from report_labels import resolve_claims, label_verdict, load_usable_tokens

template_file  = sys.argv[1]
plan_file      = sys.argv[2]
evidence_file  = sys.argv[3]
judge_file     = sys.argv[4]
output_path    = sys.argv[5]
scope          = sys.argv[6]
preset         = sys.argv[7]
output_shape   = sys.argv[8]
created_at     = sys.argv[9]
task_id        = sys.argv[10] if len(sys.argv) > 10 else ""
cross_review_status   = sys.argv[11]
cross_review_rankings = sys.argv[12]
cross_review_scores   = sys.argv[13]
verification_mode     = sys.argv[14] if len(sys.argv) > 14 else "full"
tokens_file           = sys.argv[15] if len(sys.argv) > 15 else ""
council_tier          = sys.argv[16] if len(sys.argv) > 16 else "full"
grading_reason        = sys.argv[17] if len(sys.argv) > 17 else ""
degradation_reason    = sys.argv[18] if len(sys.argv) > 18 else ""
if verification_mode not in ("full", "self-verified"):
    verification_mode = "full"

def yaml_dq(s):
    """Escape a value for a double-quoted YAML scalar. grading_reason can carry
    LLM-authored triage text, so quotes and newlines must not escape the field."""
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\r", " ").replace("\n", " "))

# CDV-204: optional per-phase tokens (orchestrator-owned file). Never invent 0.
# Parser lives in report_labels.load_usable_tokens — one copy for render and stdout.
tokens_data = load_usable_tokens(tokens_file)

# CDV-199: banner only when orchestrator self-verified after spawn failure
if verification_mode == "self-verified":
    _deg = degradation_reason.strip() if isinstance(degradation_reason, str) else ""
    _detail = (
        _deg
        if _deg
        else "Orchestrator performed adversarial checks after refuter/investigator spawn failure."
    )
    verification_banner = (
        "> **self-verified — refuters unavailable**\n"
        f"> {_detail}\n"
    )
else:
    verification_banner = ""

# Phase 2.5 fallbacks when flags absent
if not cross_review_status:
    cross_review_status = "Phase 2.5 not run"
if not cross_review_rankings:
    cross_review_rankings = "_Phase 2.5 not run — no cross-review rankings._"
if not cross_review_scores:
    cross_review_scores = "_Phase 2.5 not run — no Borda scores._"

# --- Load JSON inputs ---
with open(plan_file) as f:
    plan = json.load(f)
with open(evidence_file) as f:
    evidence_raw = json.load(f)
with open(judge_file) as f:
    judge_raw = json.load(f)

# Evidence file may be a flat array of bundles or an object with sub-keys
if isinstance(evidence_raw, list):
    bundles = evidence_raw
    prosecutor_brief = ""
    advocate_brief = ""
    extracted_claims_raw = []
    struck_lines_raw = []
else:
    bundles = evidence_raw.get("bundles", evidence_raw.get("evidence_bundles", []))
    prosecutor_brief = evidence_raw.get("prosecutor_brief", "")
    advocate_brief = evidence_raw.get("advocate_brief", "")
    extracted_claims_raw = evidence_raw.get("extracted_claims", evidence_raw.get("claims", []))
    struck_lines_raw = evidence_raw.get("struck_lines", [])

# Judge emits {verdicts: [...], struck_lines: [...]} or {findings: [...], struck_lines: [...]}
if isinstance(judge_raw, dict):
    judge_items = judge_raw.get("verdicts", judge_raw.get("findings", []))
    # Append judge struck_lines to evidence trail (never replace; CDT-178)
    judge_struck = judge_raw.get("struck_lines", [])
    if judge_struck:
        if not isinstance(struck_lines_raw, list):
            struck_lines_raw = []
        if isinstance(judge_struck, list):
            struck_lines_raw = list(struck_lines_raw) + list(judge_struck)
        else:
            struck_lines_raw = list(struck_lines_raw) + [judge_struck]
elif isinstance(judge_raw, list):
    judge_items = judge_raw
else:
    judge_items = []

if not isinstance(struck_lines_raw, list):
    struck_lines_raw = []

# CDT-178: absent/null/non-string/whitespace-only tool_use_id → missing.
# Literal "unknown", external:…, self-verify-… with non-empty strip → valid.
def missing_tool_use_id(obj):
    if not isinstance(obj, dict):
        return True
    v = obj.get("tool_use_id", None)
    if v is None:
        return True
    if not isinstance(v, str):
        return True
    return v.strip() == ""

engine_strikes = []

# --- Plan metadata ---
flavors = plan.get("flavors", [])
if isinstance(flavors, list):
    flavors_str = ", ".join(flavors)
else:
    flavors_str = str(flavors)
claim_budget = str(plan.get("claim_budget", 10))
# Duration is not measured in this process. Use plan.completion_time when the
# orchestrator set it. Otherwise the finalize timestamp (created_at) — do not
# emit the literal N/A while that clock value exists.
raw_ct = plan.get("completion_time")
if isinstance(raw_ct, str) and raw_ct.strip():
    completion_time = raw_ct.strip()
else:
    completion_time = created_at

# --- Format extracted claims (WP 1-15 C6: claim id + text; AC H) ---
claims_resolved = resolve_claims(plan, evidence_raw, judge_items)
if claims_resolved:
    claims_lines = []
    for i, c in enumerate(claims_resolved, 1):
        ctype = c.get("claim_type", "factual")
        cid = c.get("claim_id", "")
        ctext = c.get("claim", "")
        src = c.get("source_locator", "")
        claims_lines.append(f"{i}. **{ctype}** — {cid}: {ctext} (source: {src})")
    extracted_claims_md = "\n".join(claims_lines)
else:
    extracted_claims_md = "_No claims extracted._"

# --- Format evidence bundles (unstruck only; missing tid → engine strike) ---
bundle_lines = []
raw_blobs = []
bundle_ids = set()
for b in bundles:
    if isinstance(b, dict):
        rb = b.get("raw_blob")
        if isinstance(rb, str):
            raw_blobs.append(rb)
    if missing_tool_use_id(b):
        fl = b.get("file_line", "") if isinstance(b, dict) else ""
        engine_strikes.append(
            f"evidence bundle missing tool_use_id (file_line={fl})"
        )
        continue
    tid = b.get("tool_use_id")
    bundle_ids.add(tid)
    raw = b.get("raw_blob", "")
    fl = b.get("file_line", "")
    cmd = b.get("reproducible_command", "")
    bundle_lines.append(f"### `{tid}` — {fl}\n")
    bundle_lines.append(f"```\n{raw}\n```\n")
    if cmd:
        bundle_lines.append(f"Reproducible: `{cmd}`\n")
evidence_bundles_md = "\n".join(bundle_lines) if bundle_lines else "_No evidence bundles._"

# --- Format briefs ---
# Phase-4-conditional (SPEC-013 Phases 5/6): when Phase 4 did not run there is
# no brief to render, and an empty or synthesized one is forbidden — the report
# records the skip and its reason in its place.
def brief_item_text(b):
    # Match workflow.js briefToText, plus argument/text fields (CDT-401).
    if not isinstance(b, dict):
        return str(b) if b else ""
    body = b.get("argument") or b.get("text") or b.get("evidence_against") or b.get("evidence_for") or ""
    if not isinstance(body, str):
        body = "" if body is None else str(body)
    ids = b.get("supporting_tool_use_ids") or []
    if not isinstance(ids, list):
        ids = []
    return (
        "claim_id=%s requested=%s\n%s\nids=%s"
        % (b.get("claim_id", ""), b.get("requested_verdict", ""), body, ",".join(str(x) for x in ids))
    )

def briefs_to_text(value):
    if isinstance(value, dict):
        briefs = value.get("briefs")
        if not isinstance(briefs, list):
            return ""
        return "\n\n".join(brief_item_text(b) for b in briefs)
    if isinstance(value, list):
        return "\n\n".join(brief_item_text(b) for b in value)
    if isinstance(value, str):
        return value
    return ""

def format_brief(text):
    # str keeps quote rendering. dict/list render brief text, then the same quotes.
    rendered = text if isinstance(text, str) else briefs_to_text(text)
    if not isinstance(rendered, str) or not rendered.strip():
        return "_Brief not provided._"
    lines = rendered.strip().splitlines()
    return "\n".join("> %s" % ln for ln in lines)

phase4_plan = (plan.get("phases") or {}).get("4_prosecution_defense") or {}
phase4_skipped = bool(phase4_plan.get("skipped"))
phase4_skip_reason = phase4_plan.get("reason") or "not recorded"

# Phase 3's skip needs the same visible audit trail as Phase 2.5's bypass note
# (SPEC-013 Council tiering), so it gets its own rendered status line. Finalize
# only knows whether the phase was eligible — whether a specialist was actually
# pulled is a runtime decision, so an eligible run says exactly that.
phase3_plan = (plan.get("phases") or {}).get("3_domain_specialist") or {}
if phase3_plan.get("skipped"):
    phase3_status_md = f"SKIPPED (reason: {phase3_plan.get('reason') or 'not recorded'})"
else:
    phase3_status_md = "ELIGIBLE (runtime classify)"

if phase4_skipped:
    brief_skip_md = (
        f"_Phase 4 skipped, reason: {phase4_skip_reason} — no brief was "
        "produced and none was synthesized._"
    )
    prosecutor_brief_md = brief_skip_md
    advocate_brief_md = brief_skip_md
else:
    prosecutor_brief_md = format_brief(prosecutor_brief)
    advocate_brief_md = format_brief(advocate_brief)

# CDT-181 floor (toward -inf). Bool is not a JSON number. None = not in 0..100.
def floor_conf(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return None
    n = math.floor(v)
    if n < 0 or n > 100:
        return None
    return int(n)

# CDT-178 / WP 1-14 C3: floor-to-int confidence helper, used both by the
# verdict/finding formatting below and by the finalize-meta sidecar block.
def _as_int_conf(v):
    n = floor_conf(v)
    return 0 if n is None else n

VERDICT_OK = {"VERIFIED", "PARTIALLY_VERIFIED", "UNVERIFIED", "CONTRADICTED", "FABRICATED"}
SEVERITY_OK = {"critical", "warning", "nitpick"}

def verdict_strike_reason(v, blobs, ids):
    cid = v.get("claim_id") or v.get("claim") or "?"
    verd = v.get("verdict")
    if verd not in VERDICT_OK:
        return "verdict %s outside taxonomy (claim=%s)" % (verd, cid)
    blob = v.get("evidence_blob", None)
    if not isinstance(blob, str) or blob.strip() == "":
        return "verdict evidence_blob empty (claim=%s)" % cid
    if floor_conf(v.get("confidence")) is None:
        return "verdict confidence not in 0..100 after floor (claim=%s)" % cid
    if not any(isinstance(rb, str) and blob in rb for rb in blobs):
        return "verdict evidence_blob is not a substring of a bundle raw_blob (claim=%s)" % cid
    tid = v.get("tool_use_id", None)
    if isinstance(tid, str) and tid.strip() and tid.strip() not in ids:
        return "verdict tool_use_id not in evidence bundles (claim=%s)" % cid
    return None

def finding_strike_reason(f, ids, threshold):
    fl = f.get("file", "")
    ln = f.get("line", "")
    if missing_tool_use_id(f):
        return "finding missing tool_use_id (file=%s line=%s)" % (fl, ln)
    sev = f.get("severity")
    if sev not in SEVERITY_OK:
        return "finding severity %s outside taxonomy (file=%s line=%s)" % (sev, fl, ln)
    tid = f.get("tool_use_id")
    tid_s = tid.strip() if isinstance(tid, str) else ""
    if tid_s not in ids:
        return "finding tool_use_id not in evidence bundles (file=%s line=%s)" % (fl, ln)
    conf = floor_conf(f.get("confidence"))
    if conf is None:
        return "finding confidence not in 0..100 after floor (file=%s line=%s)" % (fl, ln)
    # A failed council-judge stays critical at confidence 50 so the commit
    # gate still blocks and a task gate at 80 still fails. Do not filter it.
    desc = f.get("description")
    degraded = isinstance(desc, str) and desc.startswith("(degraded-judge:")
    if threshold is not None and conf < threshold and not degraded:
        return "finding confidence %s below confidence_filter_threshold %s (file=%s line=%s)" % (conf, threshold, fl, ln)
    return None

def validate_judge(items, shape, blobs, ids, threshold):
    # CDT-303: strike before render and before max-confidence. Continue (exit 0).
    kept = []
    strikes = []
    if not isinstance(items, list):
        strikes.append("judge items are not a list")
        return kept, strikes
    for item in items:
        if not isinstance(item, dict):
            strikes.append("judge item is not an object")
            continue
        if shape == "verdict[]":
            reason = verdict_strike_reason(item, blobs, ids)
        else:
            reason = finding_strike_reason(item, ids, threshold)
        if reason:
            strikes.append(reason)
        else:
            kept.append(item)
    return kept, strikes

# Findings only. Verdict[] is not filtered by confidence_filter_threshold.
conf_threshold = None
if output_shape == "finding[]":
    raw_th = plan.get("confidence_filter_threshold", None)
    if not isinstance(raw_th, bool) and isinstance(raw_th, (int, float)):
        th = math.floor(raw_th)
        if 0 <= th <= 100:
            conf_threshold = int(th)

unstruck_items, judge_strikes = validate_judge(
    judge_items, output_shape, raw_blobs, bundle_ids, conf_threshold
)
engine_strikes.extend(judge_strikes)

# --- Format verdicts / findings (unstruck only) ---
max_verified_confidence = None
worst_verdict_value = None
finding_counts = None
finding_attention = None
if output_shape == "verdict[]":
    verdict_lines = []
    for v in unstruck_items:
        cid, claim = label_verdict(v, claims_resolved)
        verd = v.get("verdict", "UNVERIFIED")
        conf = v.get("confidence", 0)
        blob = v.get("evidence_blob", "")
        badge = {"VERIFIED": "VERIFIED", "PARTIALLY_VERIFIED": "PARTIALLY_VERIFIED",
                 "UNVERIFIED": "UNVERIFIED", "CONTRADICTED": "CONTRADICTED",
                 "FABRICATED": "FABRICATED"}.get(verd, verd)
        verdict_lines.append(f"### Claim {cid}: {claim}\n")
        verdict_lines.append(f"**{badge}** — confidence: {conf}/100\n")
        verdict_lines.append(f"```\n{blob}\n```\n")
    verdicts_md = "\n".join(verdict_lines) if verdict_lines else "_No verdicts._"

    # Verdict summary table
    counts = Counter(v.get("verdict", "UNVERIFIED") for v in unstruck_items)
    # verdict taxonomy authority: SPEC-013 (Output Shapes)
    taxonomy = ["VERIFIED", "PARTIALLY_VERIFIED", "UNVERIFIED", "CONTRADICTED", "FABRICATED"]
    table_lines = ["| Taxonomy | Count |", "|---|---|"]
    for t in taxonomy:
        table_lines.append(f"| {t} | {counts.get(t, 0)} |")
    verdict_summary_table_md = "\n".join(table_lines)

    # WP 1-14 C3 (SPEC-013 Phase 6 "Finalize-meta sidecar"): sidecar fields
    # computed over the SAME unstruck_items / counts / taxonomy this branch
    # already built for the report body -- never a second pass over judge_raw.
    # `confs` is reused below (CDT-178 sidecar meta) for
    # max_verdict_confidence -- ONE list comprehension over unstruck_items,
    # not two (tech-lead review r1, B6).
    confs = [_as_int_conf(v.get("confidence")) for v in unstruck_items]
    min_verdict_confidence = min(confs) if confs else None
    verdict_counts = {t: counts.get(t, 0) for t in taxonomy}
    unstruck_verdicts = []
    for v in unstruck_items:
        blob = v.get("evidence_blob", "")
        if not isinstance(blob, str):
            blob = ""
        unstruck_verdicts.append({
            "claim": v.get("claim", ""),
            "verdict": v.get("verdict", "UNVERIFIED"),
            "confidence": _as_int_conf(v.get("confidence")),
            "evidence_blob": blob,
        })
    # CDT-317: verified confidence ignores UNVERIFIED/CONTRADICTED/FABRICATED.
    # worst_verdict is the worst unstruck taxonomy term (FABRICATED worst).
    verified_confs = [
        _as_int_conf(v.get("confidence"))
        for v in unstruck_items
        if v.get("verdict") in ("VERIFIED", "PARTIALLY_VERIFIED")
    ]
    max_verified_confidence = max(verified_confs) if verified_confs else None
    _worst_rank = {
        "FABRICATED": 0, "CONTRADICTED": 1, "UNVERIFIED": 2,
        "PARTIALLY_VERIFIED": 3, "VERIFIED": 4,
    }
    _best = 99
    for v in unstruck_items:
        _r = _worst_rank.get(v.get("verdict"))
        if _r is not None and _r < _best:
            _best = _r
            worst_verdict_value = v.get("verdict")
else:
    # finding[] — validate_judge already struck missing tid, bad severity,
    # foreign tid, OOB confidence, and below-threshold confidence.
    finding_lines = []
    for f in unstruck_items:
        fl = f.get("file", "")
        ln = f.get("line", "")
        sev = f.get("severity", "warning")
        cat = f.get("category", "")
        desc = f.get("description", "")
        sugg = f.get("suggestion", "")
        conf = f.get("confidence", 0)
        tid = f.get("tool_use_id", "")
        loc = f"{fl}:{ln}" if fl else ""
        finding_lines.append(f"### [{sev.upper()}] {loc} ({cat})\n")
        finding_lines.append(f"{desc}\n")
        if sugg:
            finding_lines.append(f"**Suggestion:** {sugg}\n")
        finding_lines.append(f"Confidence: {conf}/100 | tool_use_id: `{tid}`\n")
    verdicts_md = "\n".join(finding_lines) if finding_lines else "_No findings._"

    # Severity summary table (unstruck only)
    counts = Counter(f.get("severity", "warning") for f in unstruck_items)
    sev_taxonomy = ["critical", "warning", "nitpick"]
    table_lines = ["| Severity | Count |", "|---|---|"]
    for s in sev_taxonomy:
        table_lines.append(f"| {s} | {counts.get(s, 0)} |")
    verdict_summary_table_md = "\n".join(table_lines)

    # WP 1-14 C3: these three sidecar fields are null for finding[] runs
    # (SPEC-013 Phase 6 "Finalize-meta sidecar").
    min_verdict_confidence = None
    verdict_counts = None
    unstruck_verdicts = None
    finding_counts = {s: counts.get(s, 0) for s in sev_taxonomy}
    finding_attention = []
    for f in unstruck_items:
        sev = f.get("severity") or ""
        if sev not in ("critical", "warning"):
            continue
        desc = f.get("description", "")
        if not isinstance(desc, str):
            desc = ""
        fl = f.get("file", "")
        if not isinstance(fl, str):
            fl = ""
        finding_attention.append({
            "confidence": f.get("confidence", "?"),
            "severity": sev,
            "file": fl,
            "line": f.get("line", ""),
            "description": desc.strip(),
        })

# User-facing diff review reads this list. Struck rows stay out.
unstruck_findings = []
if output_shape == "finding[]":
    for f in unstruck_items:
        if not isinstance(f, dict):
            continue
        desc = f.get("description", "")
        if not isinstance(desc, str):
            desc = ""
        fl = f.get("file", "")
        if not isinstance(fl, str):
            fl = ""
        sugg = f.get("suggestion", "")
        if not isinstance(sugg, str):
            sugg = ""
        cat = f.get("category", "")
        if not isinstance(cat, str):
            cat = ""
        tid = f.get("tool_use_id", "")
        if not isinstance(tid, str):
            tid = ""
        unstruck_findings.append({
            "file": fl,
            "line": f.get("line", 0),
            "severity": f.get("severity") or "",
            "category": cat,
            "description": desc.strip(),
            "suggestion": sugg,
            "confidence": f.get("confidence", 0),
            "tool_use_id": tid,
        })

# CLAIMS_AUDITED over unstruck body only (finding[] after tid strike)
claims_audited = str(len(unstruck_items))

# Merge: pre_existing (evidence + judge) + engine_strikes (append, never replace)
struck_lines_raw = list(struck_lines_raw) + engine_strikes

# --- Format struck lines ---
# Objects are claim/line/reason records (workflow schemas). Rendering a dict
# with an f-string prints Python repr (`{'claim': ...}`), which is not a line.
def format_struck_line(ln):
    if isinstance(ln, str):
        return ln
    if isinstance(ln, dict):
        who = ln.get("claim_id") or ln.get("claim") or ""
        line = ln.get("line") or ""
        reason = ln.get("reason") or ""
        parts = [str(p) for p in (who, line, reason) if p]
        if parts:
            return " — ".join(parts)
        return json.dumps(ln, sort_keys=True, ensure_ascii=True)
    return str(ln)

if struck_lines_raw:
    struck_md = "\n".join(f"- {format_struck_line(ln)}" for ln in struck_lines_raw)
else:
    struck_md = "No lines struck."

# --- Diff-mode specific placeholders ---
# Missing or empty string is absent. Do not render an empty DIFF_SUMMARY.
def _nonempty_text(v):
    return v if isinstance(v, str) and v.strip() else None

diff_summary = _nonempty_text(plan.get("diff_summary")) or _nonempty_text(plan.get("scope_arg")) or "_Not available._"
applicable_raw = plan.get("applicable_specs", None)
if isinstance(applicable_raw, list) and applicable_raw:
    applicable_specs = "\n".join("- `%s`" % s for s in applicable_raw)
elif isinstance(applicable_raw, str) and applicable_raw.strip():
    applicable_specs = applicable_raw
else:
    # No file list on the plan — do not claim a spec-grep ran.
    applicable_specs = "_None matched._"

# Commit gate status for finding[] shape (unstruck only)
commit_gate = "PASSED"
if output_shape == "finding[]":
    for f in unstruck_items:
        if f.get("severity") == "critical" or f.get("category") == "compliance":
            commit_gate = "BLOCKED"
            break

# Action items for finding[] shape (unstruck only).
# Label + sort order is category-then-severity to match review-and-commit/SKILL.md
# (Step 8): BLOCKER -> COMPLIANCE -> DESIGN -> NITPICK. A compliance finding
# (any severity) gets the COMPLIANCE label and sorts to rank 1, EXCEPT a
# critical one which is a BLOCKER first (rank 0) — critical always blocks.
sev_order = {"critical": 0, "warning": 1, "nitpick": 2}
label_map = {"critical": "BLOCKER", "warning": "DESIGN", "nitpick": "NITPICK"}

def action_rank(f):
    sev = f.get("severity", "warning")
    if sev == "critical":
        return 0
    if f.get("category") == "compliance":
        return 1
    # warning -> 2, nitpick -> 3 (sev_order is 1/2 here, +1 to leave room for COMPLIANCE)
    return sev_order.get(sev, 8) + 1

def action_label(f):
    # critical always BLOCKER (label matches rank 0); a non-critical compliance
    # finding is COMPLIANCE; otherwise map by severity.
    if f.get("severity") == "critical":
        return "BLOCKER"
    if f.get("category") == "compliance":
        return "COMPLIANCE"
    return label_map.get(f.get("severity", "warning"), "NITPICK")

action_lines = []
for f in sorted(unstruck_items, key=action_rank):
    fl = f.get("file", "")
    ln = f.get("line", "")
    desc = f.get("description", "")
    sugg = f.get("suggestion", desc)
    if not isinstance(sugg, str):
        sugg = "" if sugg is None else str(sugg)
    sugg = sugg.strip()
    conf = f.get("confidence", 0)
    loc = f"`{fl}:{ln}`" if fl else ""
    label = action_label(f)
    if sugg:
        action_lines.append(f"- [ ] {label} {loc} — {desc} — {sugg} [confidence: {conf}]")
    else:
        action_lines.append(f"- [ ] {label} {loc} — {desc} [confidence: {conf}]")
action_items_md = "\n".join(action_lines) if action_lines else "_No action items._"

# --- Read template and strip comment block ---
with open(template_file) as f:
    template = f.read()

# Strip [//]: # comment lines (authoring notes)
template = re.sub(r'^\[//\]: #.*\n?', '', template, flags=re.MULTILINE)

# --- Substitution map ---
# Report templates own YAML frontmatter (CDV-203); finalize substitutes {{…}}
# in-place and does not dual-write a synthetic FM block.
subs = {
    "{{SCOPE}}": scope,
    "{{PRESET}}": preset,
    "{{TIMESTAMP}}": created_at,
    "{{INVESTIGATOR_FLAVORS}}": flavors_str,
    "{{CLAIM_BUDGET}}": claim_budget,
    "{{CLAIMS_AUDITED}}": claims_audited,
    "{{EXTRACTED_CLAIMS}}": extracted_claims_md,
    "{{EVIDENCE_BUNDLES}}": evidence_bundles_md,
    "{{PROSECUTOR_BRIEF}}": prosecutor_brief_md,
    "{{ADVOCATE_BRIEF}}": advocate_brief_md,
    "{{VERDICTS}}": verdicts_md,
    "{{FINDINGS}}": verdicts_md,
    "{{STRUCK_LINES}}": struck_md,
    "{{STRUCK_FINDINGS}}": struck_md,
    "{{VERDICT_SUMMARY_TABLE}}": verdict_summary_table_md,
    "{{SEVERITY_SUMMARY_TABLE}}": verdict_summary_table_md,
    "{{COMPLETION_TIME}}": completion_time,
    "{{DIFF_SUMMARY}}": str(diff_summary),
    "{{APPLICABLE_SPECS}}": str(applicable_specs),
    "{{COMMIT_GATE_STATUS}}": commit_gate,
    "{{ACTION_ITEMS}}": action_items_md,
    "{{TASK_ID}}": task_id,
    "{{VERIFICATION_MODE}}": verification_mode,
    "{{COUNCIL_TIER}}": council_tier,
    "{{GRADING_REASON}}": yaml_dq(grading_reason),
    "{{PHASE3_SPECIALIST_STATUS}}": phase3_status_md,
    "{{CROSS_REVIEW_STATUS}}": cross_review_status,
    "{{CROSS_REVIEW_RANKINGS}}": cross_review_rankings,
    "{{CROSS_REVIEW_SCORES}}": cross_review_scores,
    "{{VERIFICATION_BANNER}}": verification_banner,
}

# --- Apply substitutions ---
# The templates are placeholders-only (each section holds a single {{VAR}} plus
# legitimate prose/headings). The dynamic value rendered into {{VERDICT_SUMMARY_TABLE}}
# / {{SEVERITY_SUMMARY_TABLE}} / {{STRUCK_*}} fully replaces what the section needs,
# so there is no static example/fallback content left to strip post-substitution.
#
# ONE non-recursive pass, never a per-var chain of str.replace: substituted text
# is scanned once and its output is never re-scanned. A sequential chain lets a
# value substituted early carry a literal `{{LATER_VAR}}` that a later iteration
# then expands — with untrusted values (grading_reason is free text from the
# tier-triage model) that is a template-injection primitive, and it landed raw,
# multi-line and unescaped inside the YAML frontmatter fences. Unknown
# placeholders resolve to "" here, which also folds in the old safety-net strip.
# The class carries digits: the pre-existing [A-Z_]+ silently skipped names like
# {{PHASE3_SPECIALIST_STATUS}}, leaking them into the report verbatim.
rendered = re.sub(r'\{\{[A-Z0-9_]+\}\}', lambda m: subs.get(m.group(0), ''), template)

# Unbound runs: remove empty task_id key entirely (not null, not "")
# Template carries `task_id: "{{TASK_ID}}"`; after empty sub it is `task_id: ""`.
if not task_id:
    rendered = re.sub(r'^task_id:\s*(?:""|\'\'|)\s*\n', '', rendered, count=1, flags=re.MULTILINE)

# CDV-204: optional tokens_total / tokens_by_phase in frontmatter (omit when unavailable)
if tokens_data is not None:
    fm_lines = []
    if tokens_data.get("total") is not None:
        fm_lines.append(f'tokens_total: {tokens_data["total"]}')
    if tokens_data.get("phases"):
        fm_lines.append("tokens_by_phase:")
        for pk, pv in tokens_data["phases"].items():
            fm_lines.append(f"  {pk}: {pv}")
    if fm_lines:
        inject = "\n".join(fm_lines) + "\n"
        # Insert after verification_mode line (always present in templates)
        rendered, n_sub = re.subn(
            r'(^verification_mode:\s*.+\n)',
            r'\1' + inject,
            rendered,
            count=1,
            flags=re.MULTILINE,
        )
        if n_sub == 0:
            # Fallback: insert before closing --- of YAML frontmatter
            rendered = re.sub(
                r'(^---\n(?:.*\n)*?)(^---\n)',
                r'\1' + inject + r'\2',
                rendered,
                count=1,
                flags=re.MULTILINE,
            )

# --- Write output (atomic: tmp + rename) ---
import tempfile
output = rendered.strip() + "\n"
dir_name = os.path.dirname(output_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(output)
os.rename(tmp_path, output_path)
# mkstemp creates the report mode 0600. A normal create is 0644 masked by umask.
_saved_umask = os.umask(0)
os.umask(_saved_umask)
os.chmod(output_path, 0o644 & ~_saved_umask)

# CDT-178: sidecar meta for bash index/stdout (unstruck conf + merged struck)
if output_shape == "verdict[]":
    unstruck_verdict_count = len(unstruck_items)
    unstruck_finding_count = 0
    # `confs` already computed above (WP 1-14 C3 min_verdict_confidence) --
    # reused here, not recomputed (tech-lead review r1, B6).
    max_verdict_confidence = max(confs) if confs else None
    max_finding_confidence = None
else:
    unstruck_finding_count = len(unstruck_items)
    unstruck_verdict_count = 0
    confs = [_as_int_conf(f.get("confidence")) for f in unstruck_items]
    max_finding_confidence = max(confs) if confs else None
    max_verdict_confidence = None

meta = {
    "struck_count": len(struck_lines_raw),
    "max_verdict_confidence": max_verdict_confidence,
    "max_finding_confidence": max_finding_confidence,
    "unstruck_finding_count": unstruck_finding_count,
    "unstruck_verdict_count": unstruck_verdict_count,
    # WP 1-14 C3 (SPEC-013 Phase 6 "Finalize-meta sidecar"): min_verdict_confidence,
    # verdict_counts and unstruck_verdicts are null for finding[] runs (set above);
    # verification_mode is always "full" or "self-verified", never null.
    "min_verdict_confidence": min_verdict_confidence,
    "verdict_counts": verdict_counts,
    "verification_mode": verification_mode,
    "unstruck_verdicts": unstruck_verdicts,
    # CDT-317: null when no VERIFIED/PARTIALLY_VERIFIED remains; null worst for finding[].
    "max_verified_confidence": max_verified_confidence,
    "worst_verdict": worst_verdict_value,
    # Stdout counts. Null on the other shape. Attention rows are unstruck only.
    "finding_counts": finding_counts,
    "finding_attention": finding_attention,
    "unstruck_findings": unstruck_findings,
}

# M14 per-AC split (WP 1-14; SPEC-013 Phase 6 "Finalize-meta sidecar"): only
# when the plan carries AC-bound claims (an M14 split ran at preflight).
# Finalize copies these from the plan verbatim -- it never matches verdicts
# to ACs itself; SPEC-033 M14(b)/(i) own that mapping, implemented only in
# skills/autopilot/ship-gate-verdict.sh.
m14_plan_claims = plan.get("claims")
if isinstance(m14_plan_claims, list) and m14_plan_claims and all(
    isinstance(c, dict) and "ac_id" in c for c in m14_plan_claims
):
    meta["ac_source"] = plan.get("ac_source")
    meta["ac_claims"] = [
        {"claim_id": c.get("claim_id"), "ac_id": c.get("ac_id")}
        for c in m14_plan_claims
    ]
    meta["process_acs"] = plan.get("process_acs", [])

meta_path = output_path + ".finalize-meta.json"
with open(meta_path, "w") as mf:
    json.dump(meta, mf)
    mf.write("\n")
PYEOF

  # Read finalize-meta for index conf + struck count (unstruck-only; CDT-178)
  local max_verdict_confidence="null" max_finding_confidence="null"
  local max_verified_confidence="null" worst_verdict="null"
  local struck_count=0
  local meta_path="${plan_report_path}.finalize-meta.json"
  if [ -f "$meta_path" ]; then
    max_verdict_confidence=$(jq -r 'if .max_verdict_confidence == null then "null" else .max_verdict_confidence end' "$meta_path")
    max_finding_confidence=$(jq -r 'if .max_finding_confidence == null then "null" else .max_finding_confidence end' "$meta_path")
    max_verified_confidence=$(jq -r 'if .max_verified_confidence == null then "null" else .max_verified_confidence end' "$meta_path")
    worst_verdict=$(jq -r 'if .worst_verdict == null then "null" else .worst_verdict end' "$meta_path")
    struck_count=$(jq -r '.struck_count // 0' "$meta_path")
  fi

  # Call index-writer.sh ONLY when task-bound
  if [ -n "$task_id" ]; then
    if [ ! -x "$INDEX_WRITER" ]; then
      echo "engine.sh: index-writer.sh not executable at $INDEX_WRITER" >&2
      exit 6
    fi
    if ! "$INDEX_WRITER" "$task_id" "$plan_report_path" "$max_verdict_confidence" "$max_finding_confidence" "$council_tier" "$grading_reason" "$max_verified_confidence" "$worst_verdict" >&2; then
      echo "engine.sh: failed to update .claude/council/index.json" >&2
      exit 6
    fi
  fi

  # Stdout summary (contract from SKILL.md Phase 6)
  local rel_path="${plan_report_path#"$MROOT"/}"
  printf 'Council report: %s\n' "$rel_path"
  printf 'Scope: %s\n' "$scope"
  printf 'Preset: %s (%s)\n' "$preset" "$output_shape"
  # Tier line only when the run was NOT full: `full` keeps today's stdout
  # byte-identical (SPEC-013 § Council tiering), and a light run is exactly the
  # case a reader needs told about.
  if [ "$council_tier" != "full" ]; then
    printf 'council_tier=%s (%s)\n' "$council_tier" "$grading_reason"
  fi
  printf 'verification_mode=%s\n' "$verification_mode"

  if [ "$output_shape" = "verdict[]" ]; then
    # Unstruck counts from the sidecar. Do not rescan the raw judge file.
    local v_verified v_partial v_unverified v_contradicted v_fabricated
    v_verified=$(jq -r '.verdict_counts.VERIFIED // 0' "$meta_path")
    v_partial=$(jq -r '.verdict_counts.PARTIALLY_VERIFIED // 0' "$meta_path")
    v_unverified=$(jq -r '.verdict_counts.UNVERIFIED // 0' "$meta_path")
    v_contradicted=$(jq -r '.verdict_counts.CONTRADICTED // 0' "$meta_path")
    v_fabricated=$(jq -r '.verdict_counts.FABRICATED // 0' "$meta_path")
    printf 'VERIFIED: %d  PARTIALLY_VERIFIED: %d  UNVERIFIED: %d  CONTRADICTED: %d  FABRICATED: %d\n' \
      "$v_verified" "$v_partial" "$v_unverified" "$v_contradicted" "$v_fabricated"

    # Needs-attention block: any non-VERIFIED unstruck verdict
    local attention_count=$(( v_partial + v_unverified + v_contradicted + v_fabricated ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$meta_path" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
for v in meta.get("unstruck_verdicts") or []:
    if not isinstance(v, dict):
        continue
    vt = v.get("verdict", "")
    if vt == "VERIFIED":
        continue
    conf = v.get("confidence", "?")
    claim = v.get("claim", "")
    if not isinstance(claim, str):
        claim = ""
    claim = claim.strip()
    blob = v.get("evidence_blob", "")
    if not isinstance(blob, str):
        blob = ""
    snippet = next((ln.strip() for ln in blob.splitlines() if ln.strip()), "")
    if snippet:
        print("  [%s] %s \u2014 %s (%s)" % (conf, vt, claim, snippet))
    else:
        print("  [%s] %s \u2014 %s" % (conf, vt, claim))
PYEOF
    fi
  else
    # Unstruck severity counts from the sidecar.
    local f_critical f_warning f_nitpick
    f_critical=$(jq -r '.finding_counts.critical // 0' "$meta_path")
    f_warning=$(jq -r '.finding_counts.warning // 0' "$meta_path")
    f_nitpick=$(jq -r '.finding_counts.nitpick // 0' "$meta_path")
    printf 'critical: %d  warning: %d  nitpick: %d\n' \
      "$f_critical" "$f_warning" "$f_nitpick"

    # Needs-attention block: unstruck critical and warning findings
    local attention_count=$(( f_critical + f_warning ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$meta_path" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
for f in meta.get("finding_attention") or []:
    if not isinstance(f, dict):
        continue
    sev = f.get("severity", "")
    conf = f.get("confidence", "?")
    fname = f.get("file", "")
    if not isinstance(fname, str):
        fname = ""
    line = f.get("line", "")
    desc = f.get("description", "")
    if not isinstance(desc, str):
        desc = ""
    loc = "%s:%s" % (fname, line) if fname else ""
    if loc:
        print("  [%s] %s \u2014 %s: %s" % (conf, sev.upper(), loc, desc))
    else:
        print("  [%s] %s \u2014 %s" % (conf, sev.upper(), desc))
PYEOF
    fi
  fi

  # Struck lines count from finalize-meta (merged trail incl engine strikes)
  printf '\nStruck lines: %d\n' "$struck_count"

  # CDV-204: optional Tokens block (graceful omit when missing/unavailable)
  if [ -n "$tokens_file" ] && [ -f "$tokens_file" ]; then
    python3 - "$tokens_file" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["COUNCIL_SKILL_DIR"])
from report_labels import load_usable_tokens

data = load_usable_tokens(sys.argv[1])
if not data:
    sys.exit(0)
label = "Tokens (partial):" if data.get("partial") else "Tokens:"
print("\n%s" % label)
for k, v in data["phases"].items():
    print("  %s: %s" % (k, v))
if data.get("total") is not None:
    print("  Total: %s" % data["total"])
PYEOF
  fi

  # WP 3-05: diff user-facing review. Printed before this function returns.
  # The command fence deletes JUDGE_FILE on exit, so a later shell cannot
  # read it. Struck rows are already absent from unstruck_findings.
  if [ "$scope" = "diff" ]; then
    printf '\n'
    if ! (
      set -o pipefail
      jq -c '.unstruck_findings // []' "$meta_path" \
        | bash "$SCRIPT_DIR/../review-and-commit/bucket.sh"
    ); then
      echo "engine.sh: legacy review render failed" >&2
      exit 1
    fi
  fi

  # CDV-211: best-effort discard of per-run investigator tool-call cache.
  # Only remove dirs whose basename matches council-cache-* (preflight layout).
  local cache_dir_cleanup
  cache_dir_cleanup=$(jq -r '.cache_dir // empty' "$plan_file" 2>/dev/null || true)
  if [ -n "$cache_dir_cleanup" ] && [ -d "$cache_dir_cleanup" ]; then
    case "$(basename -- "$cache_dir_cleanup")" in
      council-cache-*)
        case "$cache_dir_cleanup" in
          *..*) ;;  # refuse path traversal
          *) rm -rf -- "$cache_dir_cleanup" 2>/dev/null || true ;;
        esac
        ;;
    esac
  fi
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
  m14-check)       cmd_m14_check "$@" ;;
  -h|--help|help)  usage; exit 0 ;;
  *)
    echo "engine.sh: unknown subcommand: $SUBCMD" >&2
    usage
    exit 2
    ;;
esac
