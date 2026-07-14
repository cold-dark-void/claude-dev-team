#!/usr/bin/env bash
#
# council/external-reviewer.sh — optional external investigator slot (CDV-207)
#
# Detects and invokes an external AI CLI (codex → gemini) as one additional
# investigator. Never hard-fails solely because the CLI is missing or errors:
# every subcommand exits 0 with a JSON status of available|skipped|ok|error.
#
# Subcommands:
#   detect  [--prefer auto|codex|gemini]
#           Emit detection JSON on stdout.
#   run     [--tool auto|codex|gemini] [--claim TEXT] [--artifacts-file PATH]
#           [--output-shape verdict[]|finding[]] [--out PATH]
#           Invoke CLI (if available), normalize stdout → evidence_bundle/findings.
#   normalize --tool TOOL --raw-file PATH [--output-shape SHAPE] [--command TEXT]
#           Pure parse of a raw CLI blob (unit-testable, no network).
#
# Spec: specs/core/SPEC-013 (SHOULD external diversity). Flavor: flavors/external.md

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: external-reviewer.sh <detect|run|normalize> [options]

  detect   [--prefer auto|codex|gemini]
  run      [--tool auto|codex|gemini] [--claim TEXT] [--artifacts-file PATH]
           [--output-shape verdict[]|finding[]] [--out PATH]
  normalize --tool TOOL --raw-file PATH [--output-shape SHAPE] [--command TEXT]

Exit: always 0 for missing CLI / invoke failure (status in JSON). Exit 2 = usage.
USAGE
}

# ---- emit helpers -----------------------------------------------------------
emit_json() {
  # shellcheck disable=SC2016
  jq -n "$@"
}

# ---- detect -----------------------------------------------------------------
# Preference order: codex then gemini (first available wins) unless --prefer
# pins a single tool.
detect_tool() {
  local prefer="${1:-auto}"
  case "$prefer" in
    auto|codex|gemini) ;;
    *)
      echo "external-reviewer.sh: invalid --prefer: $prefer (want auto|codex|gemini)" >&2
      exit 2
      ;;
  esac

  local tool="" reason=""
  if [ "$prefer" = "auto" ] || [ "$prefer" = "codex" ]; then
    if command -v codex >/dev/null 2>&1; then
      tool="codex"
    elif [ "$prefer" = "codex" ]; then
      reason="codex not found in PATH"
    fi
  fi
  if [ -z "$tool" ] && { [ "$prefer" = "auto" ] || [ "$prefer" = "gemini" ]; }; then
    if command -v gemini >/dev/null 2>&1; then
      tool="gemini"
    elif [ "$prefer" = "gemini" ]; then
      reason="gemini not found in PATH"
    fi
  fi

  if [ -n "$tool" ]; then
    emit_json \
      --arg status "available" \
      --arg tool "$tool" \
      --arg prefer "$prefer" \
      --arg reason "" \
      '{status:$status, tool:$tool, prefer:$prefer, reason:$reason}'
  else
    [ -n "$reason" ] || reason="no external CLI found (looked for: codex, gemini)"
    echo "external-reviewer: skip — $reason" >&2
    emit_json \
      --arg status "skipped" \
      --argjson tool "null" \
      --arg prefer "$prefer" \
      --arg reason "$reason" \
      '{status:$status, tool:$tool, prefer:$prefer, reason:$reason}'
  fi
}

cmd_detect() {
  local prefer="auto"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefer) prefer="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "external-reviewer.sh detect: unknown flag: $1" >&2; exit 2 ;;
    esac
  done
  detect_tool "$prefer"
}

# ---- normalize --------------------------------------------------------------
# Map free-form CLI stdout into evidence_bundle (+ optional findings[]).
# tool_use_id is synthetic: external:<tool>:<sha256-of-raw-prefix>
normalize_raw() {
  local tool="$1" raw_file="$2" shape="${3:-verdict[]}" cmd="${4:-}"
  if [ ! -f "$raw_file" ] || [ ! -r "$raw_file" ]; then
    echo "external-reviewer.sh: raw file not readable: $raw_file" >&2
    exit 2
  fi
  case "$tool" in
    codex|gemini|external|mock) ;;
    *)
      echo "external-reviewer.sh: unknown tool for normalize: $tool" >&2
      exit 2
      ;;
  esac
  case "$shape" in
    'verdict[]'|'finding[]') ;;
    *)
      echo "external-reviewer.sh: invalid --output-shape: $shape" >&2
      exit 2
      ;;
  esac

  if [ -z "$cmd" ]; then
    case "$tool" in
      codex) cmd="codex review|exec (external investigator)" ;;
      gemini) cmd="gemini (external investigator)" ;;
      *) cmd="external:$tool" ;;
    esac
  fi

  # Hash first 64k for stable id; empty file still gets a deterministic id.
  local hash
  hash=$(head -c 65536 -- "$raw_file" | sha256sum | awk '{print $1}')
  local tool_use_id="external:${tool}:${hash:0:16}"

  # Best-effort file:line extraction from common review formats.
  # Prefer first path:line hit; else "external:review".
  local file_line
  file_line=$(grep -oE '[A-Za-z0-9_./+-]+\.(md|sh|js|ts|py|go|rs|json|ya?ml|toml):[0-9]+' \
    -- "$raw_file" 2>/dev/null | head -1 || true)
  [ -n "$file_line" ] || file_line="external:review"

  local raw_blob
  raw_blob=$(cat -- "$raw_file")

  # Finding-shape: try to lift structured bullets into findings[]; always
  # still emit evidence_bundle so Phase 4/5 can consume either shape.
  if [ "$shape" = "finding[]" ]; then
    jq -n \
      --arg tool "$tool" \
      --arg status "ok" \
      --arg tool_use_id "$tool_use_id" \
      --arg raw_blob "$raw_blob" \
      --arg file_line "$file_line" \
      --arg cmd "$cmd" \
      --arg hash "$hash" \
      '
      def severity_of:
        if test("(?i)critical|blocker|must fix|security") then "critical"
        elif test("(?i)nit|style|typo|minor") then "nitpick"
        else "warning" end;
      def category_of:
        if test("(?i)security|auth|pii|injection") then "security"
        elif test("(?i)compliance|agents\\.md|claude\\.md") then "compliance"
        elif test("(?i)simplif|dead code|unused|over-?engineer") then "simplification"
        elif test("(?i)maintain|naming|coupling|quality") then "quality"
        else "logic" end;
      ($raw_blob
        | split("\n")
        | map(select(test("^\\s*([-*•]|\\d+\\.)\\s+|^(CRITICAL|WARNING|NIT|BLOCKER|FINDING)\\b"; "i")))
        | map({
            file: (capture("(?<f>[A-Za-z0-9_./+-]+\\.[A-Za-z0-9]+):(?<l>[0-9]+)") | .f // "unknown"),
            line: ((capture("(?<f>[A-Za-z0-9_./+-]+\\.[A-Za-z0-9]+):(?<l>[0-9]+)") | .l // "0") | tonumber),
            severity: severity_of,
            category: category_of,
            description: (sub("^\\s*([-*•]|\\d+\\.)\\s+"; "") | sub("^(CRITICAL|WARNING|NIT|BLOCKER|FINDING)[:\\s-]*"; ""; "i")),
            suggestion: "",
            confidence: 80,
            tool_use_id: $tool_use_id
          })
        | map(select(.description | length > 0))
      ) as $findings
      | {
          status: $status,
          tool: $tool,
          reason: "",
          investigator: ("external:" + $tool),
          evidence_bundle: {
            tool_use_id: $tool_use_id,
            raw_blob: $raw_blob,
            file_line: $file_line,
            reproducible_command: $cmd,
            investigator: ("external:" + $tool)
          },
          findings: $findings
        }
      '
  else
    jq -n \
      --arg tool "$tool" \
      --arg status "ok" \
      --arg tool_use_id "$tool_use_id" \
      --arg raw_blob "$raw_blob" \
      --arg file_line "$file_line" \
      --arg cmd "$cmd" \
      '{
        status: $status,
        tool: $tool,
        reason: "",
        investigator: ("external:" + $tool),
        evidence_bundle: {
          tool_use_id: $tool_use_id,
          raw_blob: $raw_blob,
          file_line: $file_line,
          reproducible_command: $cmd,
          investigator: ("external:" + $tool)
        },
        findings: []
      }'
  fi
}

cmd_normalize() {
  local tool="" raw_file="" shape="verdict[]" cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tool) tool="${2:-}"; shift 2 ;;
      --raw-file) raw_file="${2:-}"; shift 2 ;;
      --output-shape) shape="${2:-}"; shift 2 ;;
      --command) cmd="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "external-reviewer.sh normalize: unknown flag: $1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$tool" ] || [ -z "$raw_file" ]; then
    echo "external-reviewer.sh normalize: requires --tool and --raw-file" >&2
    exit 2
  fi
  normalize_raw "$tool" "$raw_file" "$shape" "$cmd"
}

# ---- run --------------------------------------------------------------------
# Build a short review prompt from claim + optional artifacts (truncated).
build_prompt() {
  local claim="$1" artifacts_file="$2" shape="$3"
  local art=""
  if [ -n "$artifacts_file" ] && [ -f "$artifacts_file" ]; then
    # Cap artifacts so CLI argv/stdin stays bounded.
    art=$(head -c 48000 -- "$artifacts_file" 2>/dev/null || true)
  fi
  cat <<PROMPT
You are an external council investigator (flavor: external). Review the
subject below with material evidence only — cite file:line when possible.
Do not propose commits or modify files. Output a concise review.

Output shape target: ${shape}
- For finding[]: bullet findings with file:line, severity, and description.
- For verdict[]: evidence for/against the claim with file:line citations.

CLAIM / SUBJECT:
${claim}

RAW ARTIFACTS (may be truncated):
${art:-"(none supplied — use repository context available to you)"}
PROMPT
}

invoke_codex() {
  local prompt="$1" shape="$2" out_file="$3"
  local cmd_str=""
  # Diff/finding reviews: prefer dedicated review subcommand over uncommitted tree.
  # Claim/verdict: non-interactive exec, read-only sandbox.
  if [ "$shape" = "finding[]" ]; then
    cmd_str="codex review --uncommitted -"
    # Prompt on stdin via `-`
    printf '%s\n' "$prompt" | codex review --uncommitted - >"$out_file" 2>"${out_file}.err"
  else
    cmd_str="codex exec -s read-only -"
    printf '%s\n' "$prompt" | codex exec -s read-only - >"$out_file" 2>"${out_file}.err"
  fi
  printf '%s' "$cmd_str"
}

invoke_gemini() {
  local prompt="$1" shape="$2" out_file="$3"
  # Gemini CLI surface varies; use prompt positional / stdin when available.
  # Prefer non-interactive: `gemini -p <prompt>` is the common pattern.
  local cmd_str="gemini -p <prompt>"
  if gemini --help 2>&1 | grep -qE -- '-p |--prompt'; then
    gemini -p "$prompt" >"$out_file" 2>"${out_file}.err"
  else
    cmd_str="gemini (stdin)"
    printf '%s\n' "$prompt" | gemini >"$out_file" 2>"${out_file}.err"
  fi
  printf '%s' "$cmd_str"
}

emit_skip() {
  local reason="$1" tool="${2:-}"
  echo "external-reviewer: skip — $reason" >&2
  if [ -n "$tool" ]; then
    emit_json \
      --arg status "skipped" \
      --arg tool "$tool" \
      --arg reason "$reason" \
      '{status:$status, tool:$tool, reason:$reason, evidence_bundle:null, findings:[]}'
  else
    emit_json \
      --arg status "skipped" \
      --argjson tool "null" \
      --arg reason "$reason" \
      '{status:$status, tool:$tool, reason:$reason, evidence_bundle:null, findings:[]}'
  fi
}

emit_error() {
  local reason="$1" tool="${2:-}"
  echo "external-reviewer: error — $reason (continuing without external slot)" >&2
  if [ -n "$tool" ]; then
    emit_json \
      --arg status "error" \
      --arg tool "$tool" \
      --arg reason "$reason" \
      '{status:$status, tool:$tool, reason:$reason, evidence_bundle:null, findings:[]}'
  else
    emit_json \
      --arg status "error" \
      --argjson tool "null" \
      --arg reason "$reason" \
      '{status:$status, tool:$tool, reason:$reason, evidence_bundle:null, findings:[]}'
  fi
}

cmd_run() {
  local tool_pref="auto" claim="" artifacts_file="" shape="verdict[]" out_path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tool) tool_pref="${2:-}"; shift 2 ;;
      --claim) claim="${2:-}"; shift 2 ;;
      --artifacts-file) artifacts_file="${2:-}"; shift 2 ;;
      --output-shape) shape="${2:-}"; shift 2 ;;
      --out) out_path="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "external-reviewer.sh run: unknown flag: $1" >&2; exit 2 ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    emit_error "jq is required but not found"
    return 0
  fi

  local det
  det=$(detect_tool "$tool_pref")
  local status tool
  status=$(printf '%s' "$det" | jq -r '.status')
  tool=$(printf '%s' "$det" | jq -r '.tool // empty')
  if [ "$status" != "available" ] || [ -z "$tool" ]; then
    local reason
    reason=$(printf '%s' "$det" | jq -r '.reason // "no external CLI"')
    # detect_tool already printed skip notice; re-emit run-shaped JSON
    emit_json \
      --arg status "skipped" \
      --argjson tool "null" \
      --arg reason "$reason" \
      '{status:$status, tool:$tool, reason:$reason, evidence_bundle:null, findings:[]}'
    return 0
  fi

  local prompt raw_tmp cmd_str rc=0
  prompt=$(build_prompt "$claim" "$artifacts_file" "$shape")
  raw_tmp=$(mktemp "${TMPDIR:-/tmp}/council-ext-raw.XXXXXX") \
    || { emit_error "mktemp failed"; return 0; }

  set +e
  case "$tool" in
    codex) cmd_str=$(invoke_codex "$prompt" "$shape" "$raw_tmp"); rc=$? ;;
    gemini) cmd_str=$(invoke_gemini "$prompt" "$shape" "$raw_tmp"); rc=$? ;;
    *) cmd_str=""; rc=127 ;;
  esac
  set -e

  if [ "$rc" -ne 0 ] || [ ! -s "$raw_tmp" ]; then
    local err=""
    [ -f "${raw_tmp}.err" ] && err=$(head -c 500 -- "${raw_tmp}.err" 2>/dev/null || true)
    rm -f -- "$raw_tmp" "${raw_tmp}.err"
    emit_error "CLI invoke failed (rc=$rc)${err:+: $err}" "$tool"
    return 0
  fi

  local normalized
  normalized=$(normalize_raw "$tool" "$raw_tmp" "$shape" "$cmd_str")
  rm -f -- "$raw_tmp" "${raw_tmp}.err"

  if [ -n "$out_path" ]; then
    printf '%s\n' "$normalized" >"$out_path"
  fi
  printf '%s\n' "$normalized"
}

# ---- main -------------------------------------------------------------------
if [ $# -lt 1 ]; then
  usage
  exit 2
fi

sub="$1"; shift
case "$sub" in
  detect)    cmd_detect "$@" ;;
  run)       cmd_run "$@" ;;
  normalize) cmd_normalize "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "external-reviewer.sh: unknown subcommand: $sub" >&2
    usage
    exit 2
    ;;
esac
exit 0
