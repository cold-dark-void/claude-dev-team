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

Exit codes: 0 ok | 2 usage/no-scope | 3 reserved (unused; no deferred scopes) | 4 unknown preset
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

# ---- path-safe validation ----------------------------------------------------
# Reject any value containing path traversal characters.
validate_path_component() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "engine.sh: invalid $label: must match [a-zA-Z0-9._-]+" >&2
    exit 2
  fi
}

# ---- report-path ------------------------------------------------------------
# $MROOT/.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>].md
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
      --task-id) tid="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$tid" ]; then
    validate_path_component "task-id" "$tid"
  fi
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
      --scope)     scope="${2:-}"; shift 2 ;;
      --scope-arg) scope_arg="${2:-}"; shift 2 ;;
      --last)      last="${2:-}"; shift 2 ;;
      --task-id)   task_id="${2:-}"; shift 2 ;;
      --preset)    preset="${2:-}"; preset_source="explicit"; shift 2 ;;
      --why)       why="true"; shift ;;
      # CDT-126: tier resolved by the caller (commands/council.md Step 1.5 —
      # grading, or an externally-supplied DRI/ship-gate tier). The engine
      # never grades; it only consumes the resolved value.
      --tier)           council_tier="${2:-}"; shift 2 ;;
      --grading-reason) grading_reason="${2:-}"; shift 2 ;;
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

  # Resolve preset (explicit or inferred from scope)
  if [ -z "$preset" ]; then
    preset_source="inferred"
    case "$scope" in
      diff)    preset="diff-mode" ;;
      claim|session|plan|from-retro) preset="generic" ;;
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
      flavors='["paranoid-ic","jaded-senior"]' ;;
    diff-mode)
      output_shape="finding[]"; feedback_enabled="false"; spec_grep="true"
      confidence_filter="80"
      flavors='["logic","security","compliance","quality","simplification"]' ;;
    *)
      echo "engine.sh: unknown preset: $preset — known: generic, diff-mode" >&2
      exit 4 ;;
  esac

  # CDT-126 light flavor subsets (SPEC-013 § Council tiering). `generic` is
  # already exactly the 2 distinct flavors light requires, so it is unchanged;
  # `diff-mode` keeps the two correctness/safety axes and drops the three
  # polish axes.
  if [ "$council_tier" = "light" ] && [ "$preset" = "diff-mode" ]; then
    flavors='["logic","security"]'
  fi

  local claim_budget=10  # SPEC-013 "per-run claim budget (default: 10 claims)", hardcoded in v1
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
      slug=$(printf '%s' "$base" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/^-\+//;s/-\+$//;s/-\+/-/g')
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
# exit fires errexit before any post-heredoc bash guard can run, so the per-mode
# exit code MUST be produced by sys.exit(int(code)) inside python (driven by the
# exit_code argv), NOT by a bash `[ $? -ne 0 ]` guard. The guard is kept as
# explicit documentation of the 5-vs-7 failure contract.
repair_json_file() {
  local _file="$1" _mode="$2" _label="$3" _code="$4"
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

# ---- finalize ---------------------------------------------------------------
# Consume plan + evidence + judge output, render report, write index row.
# Inputs: --plan-file, --evidence-file, --judge-output. Does not interpret
# semantics beyond branching on output_shape and computing max_confidence.
cmd_finalize() {
  require_jq

  local plan_file="" evidence_file="" judge_output="" task_id="" report_out=""
  local cross_review_status="" cross_review_rankings="" cross_review_scores=""
  local verification_mode="" tokens_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --plan-file)     plan_file="${2:-}"; shift 2 ;;
      --evidence-file) evidence_file="${2:-}"; shift 2 ;;
      --judge-output)  judge_output="${2:-}"; shift 2 ;;
      --task-id)       task_id="${2:-}"; shift 2 ;;
      --report-out)    report_out="${2:-}"; shift 2 ;;
      --cross-review-status)    cross_review_status="${2:-}"; shift 2 ;;
      --cross-review-rankings)  cross_review_rankings="${2:-}"; shift 2 ;;
      --cross-review-scores)    cross_review_scores="${2:-}"; shift 2 ;;
      --verification-mode)      verification_mode="${2:-}"; shift 2 ;;
      --tokens-file)            tokens_file="${2:-}"; shift 2 ;;
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
    echo "engine.sh: report template missing: $template_file" >&2
    exit 7
  fi

  # Validate evidence file is parseable JSON. Investigator raw_blob fields
  # may contain code with backslashes (regex, paths) that the LLM fails to
  # escape properly. Attempt repair before any jq calls.
  if ! jq empty "$evidence_file" 2>/dev/null; then
    repair_json_file "$evidence_file" evidence "evidence file" 5
    # Note: under set -e, python3 non-zero exit fires errexit before this
    # guard executes. Guard kept as explicit documentation of the contract.
    [ $? -ne 0 ] && exit 5
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
    # Note: under set -e, python3 non-zero exit fires errexit before this
    # guard executes. Guard kept as explicit documentation of the contract.
    if [ $? -ne 0 ]; then
      exit 7
    fi
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

  python3 - "$template_file" "$plan_file" "$evidence_file" "$judge_output" \
    "$plan_report_path" "$scope" "$preset" "$output_shape" "$created_at" \
    "$task_id" "$cross_review_status" "$cross_review_rankings" \
    "$cross_review_scores" "$verification_mode" "${tokens_file:-}" \
    "$council_tier" "$grading_reason" <<'PYEOF'
import json, sys, os, re
from collections import Counter

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
if verification_mode not in ("full", "self-verified"):
    verification_mode = "full"

def yaml_dq(s):
    """Escape a value for a double-quoted YAML scalar. grading_reason can carry
    LLM-authored triage text, so quotes and newlines must not escape the field."""
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\r", " ").replace("\n", " "))

# CDV-204: optional per-phase tokens (orchestrator-owned file). Never invent 0.
def load_usable_tokens(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    source = data.get("source") or ""
    if source == "unavailable":
        return None
    raw_phases = data.get("phases") or {}
    if not isinstance(raw_phases, dict):
        raw_phases = {}
    clean = {}
    for k, v in raw_phases.items():
        if v is None:
            continue
        try:
            n = int(v)
        except (TypeError, ValueError):
            continue
        if n > 0:
            clean[str(k)] = n
    total = data.get("total")
    total_n = None
    if total is not None:
        try:
            t = int(total)
            if t > 0:
                total_n = t
        except (TypeError, ValueError):
            total_n = None
    if total_n is None and clean:
        total_n = sum(clean.values())
    if not clean and total_n is None:
        return None
    partial = source == "partial" or bool(data.get("partial"))
    return {"phases": clean, "total": total_n, "partial": partial, "source": source}

tokens_data = load_usable_tokens(tokens_file)

# CDV-199: banner only when orchestrator self-verified after spawn failure
if verification_mode == "self-verified":
    verification_banner = (
        "> **self-verified — refuters unavailable**\n"
        "> Orchestrator performed adversarial checks after "
        "refuter/investigator spawn failure.\n"
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
completion_time = plan.get("completion_time", "N/A")

# --- Format extracted claims ---
if extracted_claims_raw:
    claims_lines = []
    for i, c in enumerate(extracted_claims_raw, 1):
        if isinstance(c, dict):
            ctype = c.get("claim_type", c.get("type", "factual"))
            ctext = c.get("claim_text", c.get("claim", c.get("text", "")))
            src = c.get("source_locator", c.get("source", ""))
            claims_lines.append(f"{i}. **{ctype}** — {ctext} (source: {src})")
        else:
            claims_lines.append(f"{i}. {c}")
    extracted_claims_md = "\n".join(claims_lines)
else:
    # Infer from judge output when claims not provided separately
    claims_lines = []
    for i, j in enumerate(judge_items, 1):
        claim_text = j.get("claim", j.get("description", ""))
        claims_lines.append(f"{i}. **factual** — {claim_text}")
    extracted_claims_md = "\n".join(claims_lines) if claims_lines else "_No claims extracted._"

# --- Format evidence bundles (unstruck only; missing tid → engine strike) ---
bundle_lines = []
for b in bundles:
    if missing_tool_use_id(b):
        fl = b.get("file_line", "") if isinstance(b, dict) else ""
        engine_strikes.append(
            f"evidence bundle missing tool_use_id (file_line={fl})"
        )
        continue
    tid = b.get("tool_use_id")
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
def format_brief(text):
    if not text:
        return "_Brief not provided._"
    lines = text.strip().splitlines()
    return "\n".join(f"> {ln}" for ln in lines)

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

# --- Format verdicts / findings (unstruck only for finding[] tid strikes) ---
if output_shape == "verdict[]":
    # No finding-tid strike this ticket; all verdicts remain unstruck body.
    unstruck_items = list(judge_items) if isinstance(judge_items, list) else []
    verdict_lines = []
    for v in unstruck_items:
        cid = v.get("claim_id", "?")
        claim = v.get("claim", "")
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
else:
    # finding[] shape — partition missing tool_use_id (CDT-178)
    unstruck_items = []
    for f in (judge_items if isinstance(judge_items, list) else []):
        if missing_tool_use_id(f):
            fl = f.get("file", "") if isinstance(f, dict) else ""
            ln = f.get("line", "") if isinstance(f, dict) else ""
            engine_strikes.append(
                f"finding missing tool_use_id (file={fl} line={ln})"
            )
            continue
        unstruck_items.append(f)

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

# CLAIMS_AUDITED over unstruck body only (finding[] after tid strike)
claims_audited = str(len(unstruck_items))

# Merge: pre_existing (evidence + judge) + engine_strikes (append, never replace)
struck_lines_raw = list(struck_lines_raw) + engine_strikes

# --- Format struck lines ---
if struck_lines_raw:
    struck_md = "\n".join(f"- {ln}" for ln in struck_lines_raw)
else:
    struck_md = "No lines struck."

# --- Diff-mode specific placeholders ---
diff_summary = plan.get("diff_summary", plan.get("scope_arg", "_Not available._"))
applicable_specs = plan.get("applicable_specs", "_None matched._")
if isinstance(applicable_specs, list):
    applicable_specs = "\n".join(f"- `{s}`" for s in applicable_specs)

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
    conf = f.get("confidence", 0)
    loc = f"`{fl}:{ln}`" if fl else ""
    label = action_label(f)
    action_lines.append(f"- [ ] {label} {loc} — {desc} — {sugg} [confidence: {conf}]")
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

# CDT-178: sidecar meta for bash index/stdout (unstruck conf + merged struck)
def _as_int_conf(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0

if output_shape == "verdict[]":
    unstruck_verdict_count = len(unstruck_items)
    unstruck_finding_count = 0
    confs = [_as_int_conf(v.get("confidence")) for v in unstruck_items]
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
}
meta_path = output_path + ".finalize-meta.json"
with open(meta_path, "w") as mf:
    json.dump(meta, mf)
    mf.write("\n")
PYEOF

  # Read finalize-meta for index conf + struck count (unstruck-only; CDT-178)
  local max_verdict_confidence="null" max_finding_confidence="null"
  local struck_count=0
  local meta_path="${plan_report_path}.finalize-meta.json"
  if [ -f "$meta_path" ]; then
    max_verdict_confidence=$(jq -r 'if .max_verdict_confidence == null then "null" else .max_verdict_confidence end' "$meta_path")
    max_finding_confidence=$(jq -r 'if .max_finding_confidence == null then "null" else .max_finding_confidence end' "$meta_path")
    struck_count=$(jq -r '.struck_count // 0' "$meta_path")
  fi

  # Call index-writer.sh ONLY when task-bound
  if [ -n "$task_id" ]; then
    if [ ! -x "$INDEX_WRITER" ]; then
      echo "engine.sh: index-writer.sh not executable at $INDEX_WRITER" >&2
      exit 6
    fi
    if ! "$INDEX_WRITER" "$task_id" "$plan_report_path" "$max_verdict_confidence" "$max_finding_confidence" "$council_tier" "$grading_reason" >&2; then
      echo "engine.sh: failed to update .claude/council/index.json" >&2
      exit 6
    fi
  fi

  # Stdout summary (contract from SKILL.md Phase 6)
  local rel_path="${plan_report_path#$MROOT/}"
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
    # Verdict counts
    local v_verified v_partial v_unverified v_contradicted v_fabricated
    v_verified=$(jq '[(.verdicts // [])[] | select(.verdict=="VERIFIED")] | length' "$judge_output")
    v_partial=$(jq '[(.verdicts // [])[] | select(.verdict=="PARTIALLY_VERIFIED")] | length' "$judge_output")
    v_unverified=$(jq '[(.verdicts // [])[] | select(.verdict=="UNVERIFIED")] | length' "$judge_output")
    v_contradicted=$(jq '[(.verdicts // [])[] | select(.verdict=="CONTRADICTED")] | length' "$judge_output")
    v_fabricated=$(jq '[(.verdicts // [])[] | select(.verdict=="FABRICATED")] | length' "$judge_output")
    printf 'VERIFIED: %d  PARTIALLY_VERIFIED: %d  UNVERIFIED: %d  CONTRADICTED: %d  FABRICATED: %d\n' \
      "$v_verified" "$v_partial" "$v_unverified" "$v_contradicted" "$v_fabricated"

    # Needs-attention block: any non-VERIFIED verdict
    local attention_count=$(( v_partial + v_unverified + v_contradicted + v_fabricated ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$judge_output" <<'PYEOF'
import json, sys, textwrap
raw = json.load(open(sys.argv[1]))
data = raw.get("verdicts", raw) if isinstance(raw, dict) else raw
for v in data:
    vt = v.get("verdict", "")
    if vt == "VERIFIED":
        continue
    conf = v.get("confidence", "?")
    claim = v.get("claim", "").strip()
    blob = v.get("evidence_blob", "").strip()
    # First non-empty line of blob as snippet
    snippet = next((ln.strip() for ln in blob.splitlines() if ln.strip()), "")
    if snippet:
        print(f"  [{conf}] {vt} \u2014 {claim} ({snippet})")
    else:
        print(f"  [{conf}] {vt} \u2014 {claim}")
PYEOF
    fi
  else
    # Finding counts by severity — unstruck only (jq twin of missing_tool_use_id)
    # Present non-empty string after strip; null/non-string/blank → missing.
    local f_critical f_warning f_nitpick
    f_critical=$(jq '[(.findings // [])[] | select((.tool_use_id != null) and (.tool_use_id | type == "string") and ((.tool_use_id | gsub("^[[:space:]]+|[[:space:]]+$";"")) | length > 0) and .severity=="critical")] | length' "$judge_output")
    f_warning=$(jq '[(.findings // [])[] | select((.tool_use_id != null) and (.tool_use_id | type == "string") and ((.tool_use_id | gsub("^[[:space:]]+|[[:space:]]+$";"")) | length > 0) and .severity=="warning")] | length' "$judge_output")
    f_nitpick=$(jq '[(.findings // [])[] | select((.tool_use_id != null) and (.tool_use_id | type == "string") and ((.tool_use_id | gsub("^[[:space:]]+|[[:space:]]+$";"")) | length > 0) and .severity=="nitpick")] | length' "$judge_output")
    printf 'critical: %d  warning: %d  nitpick: %d\n' \
      "$f_critical" "$f_warning" "$f_nitpick"

    # Needs-attention block: critical and warning findings (unstruck only)
    local attention_count=$(( f_critical + f_warning ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$judge_output" <<'PYEOF'
import json, sys

def missing_tool_use_id(obj):
    if not isinstance(obj, dict):
        return True
    v = obj.get("tool_use_id", None)
    if v is None:
        return True
    if not isinstance(v, str):
        return True
    return v.strip() == ""

raw = json.load(open(sys.argv[1]))
data = raw.get("findings", raw) if isinstance(raw, dict) else raw
for f in data:
    if missing_tool_use_id(f):
        continue
    sev = f.get("severity", "")
    if sev not in ("critical", "warning"):
        continue
    conf = f.get("confidence", "?")
    fname = f.get("file", "")
    line = f.get("line", "")
    desc = f.get("description", "").strip()
    loc = f"{fname}:{line}" if fname else ""
    if loc:
        print(f"  [{conf}] {sev.upper()} \u2014 {loc}: {desc}")
    else:
        print(f"  [{conf}] {sev.upper()} \u2014 {desc}")
PYEOF
    fi
  fi

  # Struck lines count from finalize-meta (merged trail incl engine strikes)
  printf '\nStruck lines: %d\n' "$struck_count"

  # CDV-204: optional Tokens block (graceful omit when missing/unavailable)
  if [ -n "$tokens_file" ] && [ -f "$tokens_file" ]; then
    python3 - "$tokens_file" <<'PYEOF'
import json, sys, os

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
source = data.get("source") or ""
if source == "unavailable":
    sys.exit(0)
raw_phases = data.get("phases") or {}
if not isinstance(raw_phases, dict):
    raw_phases = {}
clean = {}
for k, v in raw_phases.items():
    if v is None:
        continue
    try:
        n = int(v)
    except (TypeError, ValueError):
        continue
    if n > 0:
        clean[str(k)] = n
total = data.get("total")
total_n = None
if total is not None:
    try:
        t = int(total)
        if t > 0:
            total_n = t
    except (TypeError, ValueError):
        total_n = None
if total_n is None and clean:
    total_n = sum(clean.values())
if not clean and total_n is None:
    sys.exit(0)
partial = source == "partial" or bool(data.get("partial"))
label = "Tokens (partial):" if partial else "Tokens:"
print(f"\n{label}")
for k, v in clean.items():
    print(f"  {k}: {v}")
if total_n is not None:
    print(f"  Total: {total_n}")
PYEOF
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
  -h|--help|help)  usage; exit 0 ;;
  *)
    echo "engine.sh: unknown subcommand: $SUBCMD" >&2
    usage
    exit 2
    ;;
esac
