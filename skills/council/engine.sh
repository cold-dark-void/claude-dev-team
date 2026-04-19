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

# ---- path-safe validation ----------------------------------------------------
# Reject any value containing path traversal characters.
validate_path_component() {
  local label="$1" value="$2"
  if ! printf '%s' "$value" | grep -qE '^[a-zA-Z0-9._-]+$'; then
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
      flavors='["paranoid-ic","logic"]' ;;
    diff-mode)
      output_shape="finding[]"; feedback_enabled="false"; spec_grep="true"
      confidence_filter="80"
      flavors='["logic","security","compliance","quality","simplification"]' ;;
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

  # Validate evidence file is parseable JSON. Investigator raw_blob fields
  # may contain code with backslashes (regex, paths) that the LLM fails to
  # escape properly. Attempt repair before any jq calls.
  if ! jq empty "$evidence_file" 2>/dev/null; then
    python3 - "$evidence_file" <<'PYREPAIR'
import json, sys

path = sys.argv[1]
with open(path, 'r') as f:
    raw = f.read()

# Try parsing as-is first
try:
    json.loads(raw)
    sys.exit(0)  # already valid
except json.JSONDecodeError:
    pass

# Repair: fix unescaped backslashes inside JSON string values.
# Walk the raw text character by character, tracking whether we're inside a
# JSON string. Inside strings, double any backslash that isn't followed by
# a valid JSON escape character: " \ / b f n r t u
VALID_ESCAPES = set('"\\/' + 'bfnrtu')
out = []
i = 0
in_string = False
while i < len(raw):
    ch = raw[i]
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
            if i + 1 < len(raw) and raw[i + 1] in VALID_ESCAPES:
                # Valid JSON escape — keep as-is
                out.append(ch)
                out.append(raw[i + 1])
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
    print("engine.sh: repaired malformed JSON in evidence file (unescaped backslashes)", file=sys.stderr)
except json.JSONDecodeError as e:
    print(f"engine.sh: evidence file is not valid JSON and repair failed: {e}", file=sys.stderr)
    sys.exit(5)
PYREPAIR
    if [ $? -ne 0 ]; then
      exit 5
    fi
  fi

  # Validate evidence file is non-empty JSON array. An empty bundle set is
  # exit 5 per SKILL.md failure-mode table.
  local evidence_count
  evidence_count=$(jq 'if type == "array" then length elif type == "object" then (.bundles // .evidence_bundles // []) | length else 0 end' "$evidence_file")
  if [ "$evidence_count" = "0" ]; then
    echo "engine.sh: Phase 2 produced zero evidence bundles — aborting" >&2
    exit 5
  fi

  # Compute max confidence for the index row.
  local max_verdict_confidence="null" max_finding_confidence="null"
  local verdict_count=0 finding_count=0
  if [ "$output_shape" = "verdict[]" ]; then
    verdict_count=$(jq '(.verdicts // []) | length' "$judge_output")
    if [ "$verdict_count" -gt 0 ]; then
      max_verdict_confidence=$(jq '[(.verdicts // [])[] | .confidence // 0] | max // 0' "$judge_output")
    fi
  else
    finding_count=$(jq '(.findings // []) | length' "$judge_output")
    if [ "$finding_count" -gt 0 ]; then
      max_finding_confidence=$(jq '[(.findings // [])[] | .confidence // 0] | max // 0' "$judge_output")
    fi
  fi

  # Ensure parent dir exists
  mkdir -p "$(dirname "$plan_report_path")"

  # Render report: python3 reads the template + all JSON inputs, substitutes
  # every {{VAR}} placeholder, and writes the fully-rendered report.
  local created_at
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 - "$template_file" "$plan_file" "$evidence_file" "$judge_output" \
    "$plan_report_path" "$scope" "$preset" "$output_shape" "$created_at" \
    "$task_id" <<'PYEOF'
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
    # struck_lines from judge output take precedence over evidence file
    judge_struck = judge_raw.get("struck_lines", [])
    if judge_struck:
        struck_lines_raw = judge_struck
elif isinstance(judge_raw, list):
    judge_items = judge_raw
else:
    judge_items = []

# --- Plan metadata ---
flavors = plan.get("flavors", [])
if isinstance(flavors, list):
    flavors_str = ", ".join(flavors)
else:
    flavors_str = str(flavors)
claim_budget = str(plan.get("claim_budget", 10))
claims_audited = str(len(judge_items))
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

# --- Format evidence bundles ---
bundle_lines = []
for b in bundles:
    tid = b.get("tool_use_id", "unknown")
    raw = b.get("raw_blob", "")
    fl = b.get("file_line", "")
    cmd = b.get("reproducible_command", "")
    bundle_lines.append(f"### `{tid}` — {fl}\n")
    bundle_lines.append(f"```\n{raw}\n```\n")
    if cmd:
        bundle_lines.append(f"Reproducible: `{cmd}`\n")
evidence_bundles_md = "\n".join(bundle_lines) if bundle_lines else "_No evidence bundles._"

# --- Format briefs ---
def format_brief(text):
    if not text:
        return "_Brief not provided._"
    lines = text.strip().splitlines()
    return "\n".join(f"> {ln}" for ln in lines)

prosecutor_brief_md = format_brief(prosecutor_brief)
advocate_brief_md = format_brief(advocate_brief)

# --- Format verdicts / findings ---
if output_shape == "verdict[]":
    verdict_lines = []
    for v in judge_items:
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
    counts = Counter(v.get("verdict", "UNVERIFIED") for v in judge_items)
    taxonomy = ["VERIFIED", "PARTIALLY_VERIFIED", "UNVERIFIED", "CONTRADICTED", "FABRICATED"]
    table_lines = ["| Taxonomy | Count |", "|---|---|"]
    for t in taxonomy:
        table_lines.append(f"| {t} | {counts.get(t, 0)} |")
    verdict_summary_table_md = "\n".join(table_lines)
else:
    # finding[] shape
    finding_lines = []
    for f in judge_items:
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

    # Severity summary table
    counts = Counter(f.get("severity", "warning") for f in judge_items)
    sev_taxonomy = ["critical", "warning", "nitpick"]
    table_lines = ["| Severity | Count |", "|---|---|"]
    for s in sev_taxonomy:
        table_lines.append(f"| {s} | {counts.get(s, 0)} |")
    verdict_summary_table_md = "\n".join(table_lines)

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

# Commit gate status for finding[] shape
commit_gate = "PASSED"
if output_shape == "finding[]":
    for f in judge_items:
        if f.get("severity") == "critical" or f.get("category") == "compliance":
            commit_gate = "BLOCKED"
            break

# Action items for finding[] shape
action_lines = []
sev_order = {"critical": 0, "warning": 1, "nitpick": 2}
label_map = {"critical": "BLOCKER", "warning": "DESIGN", "nitpick": "NITPICK"}
for f in sorted(judge_items, key=lambda x: sev_order.get(x.get("severity", ""), 9)):
    sev = f.get("severity", "warning")
    fl = f.get("file", "")
    ln = f.get("line", "")
    desc = f.get("description", "")
    sugg = f.get("suggestion", desc)
    conf = f.get("confidence", 0)
    loc = f"`{fl}:{ln}`" if fl else ""
    label = label_map.get(sev, "NITPICK")
    action_lines.append(f"- [ ] {label} {loc} — {desc} — {sugg} [confidence: {conf}]")
action_items_md = "\n".join(action_lines) if action_lines else "_No action items._"

# --- Read template and strip comment block ---
with open(template_file) as f:
    template = f.read()

# Strip [//]: # comment lines (authoring notes)
template = re.sub(r'^\[//\]: #.*\n?', '', template, flags=re.MULTILINE)

# --- Build YAML frontmatter ---
fm_lines = ["---"]
fm_lines.append(f'scope: "{scope}"')
fm_lines.append(f'preset: "{preset}"')
fm_lines.append(f'output_shape: "{output_shape}"')
fm_lines.append(f'created_at: "{created_at}"')
if task_id:
    fm_lines.append(f'task_id: "{task_id}"')
fm_lines.append("---")
frontmatter = "\n".join(fm_lines)

# --- Substitution map ---
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
}

# --- Apply substitutions ---
rendered = template
for var, val in subs.items():
    rendered = rendered.replace(var, val)

# Remove the template's static fallback table that follows the summary
# table placeholder (it has "| — |" placeholders meant to be replaced
# by the dynamic table above).
rendered = re.sub(
    r'\n\| Taxonomy \| Count \|\n\|---\|---\|\n(\| [A-Z_]+ \| — \|\n)+',
    '\n', rendered)
rendered = re.sub(
    r'\n\| Severity \| Count \|\n\|---\|---\|\n(\| [a-z]+ \| — \|\n)+',
    '\n', rendered)

# Remove the static "No lines struck." / "No findings struck." that
# follows the {{STRUCK_*}} placeholder in the template — we already
# rendered the correct value into the placeholder.
if struck_lines_raw:
    # If there ARE struck lines, remove the static fallback text
    rendered = rendered.replace("\nNo lines struck.\n", "\n")
    rendered = rendered.replace("\nNo findings struck.\n", "\n")
else:
    # struck_md is already "No lines struck." — remove the duplicate
    # static line so it doesn't appear twice.
    rendered = re.sub(r'(No lines struck\.)\n+No lines struck\.', r'\1', rendered)
    rendered = re.sub(r'(No findings struck\.)\n+No findings struck\.', r'\1', rendered)

# Strip any remaining {{VAR}} that weren't in our map (safety net)
rendered = re.sub(r'\{\{[A-Z_]+\}\}', '', rendered)

# --- Write output (atomic: tmp + rename) ---
import tempfile, os
output = frontmatter + "\n\n" + rendered.strip() + "\n"
dir_name = os.path.dirname(output_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(output)
os.rename(tmp_path, output_path)
PYEOF

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
  local rel_path="${plan_report_path#$MROOT/}"
  printf 'Council report: %s\n' "$rel_path"
  printf 'Scope: %s\n' "$scope"
  printf 'Preset: %s (%s)\n' "$preset" "$output_shape"

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
    # Finding counts by severity
    local f_critical f_warning f_nitpick
    f_critical=$(jq '[(.findings // [])[] | select(.severity=="critical")] | length' "$judge_output")
    f_warning=$(jq '[(.findings // [])[] | select(.severity=="warning")] | length' "$judge_output")
    f_nitpick=$(jq '[(.findings // [])[] | select(.severity=="nitpick")] | length' "$judge_output")
    printf 'critical: %d  warning: %d  nitpick: %d\n' \
      "$f_critical" "$f_warning" "$f_nitpick"

    # Needs-attention block: critical and warning findings
    local attention_count=$(( f_critical + f_warning ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$judge_output" <<'PYEOF'
import json, sys
raw = json.load(open(sys.argv[1]))
data = raw.get("findings", raw) if isinstance(raw, dict) else raw
for f in data:
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

  # Struck lines count from judge output
  local struck_count
  struck_count=$(jq '(.struck_lines // []) | length' "$judge_output" 2>/dev/null || echo "0")
  printf '\nStruck lines: %d\n' "$struck_count"
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
