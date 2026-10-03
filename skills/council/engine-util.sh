# council/engine-util.sh — shared helpers sourced by engine.sh (L-10).
# Pure function definitions only; no side effects at source time.

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

