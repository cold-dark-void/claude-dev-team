#!/usr/bin/env bash
# WP 1-15 T4 (AC D, half) — the M14 verify render.
#
# Hermetic. Asserts the investigator template's {{TOOL_BUDGET}} /
# {{VERIFY_COMMAND}} section-block rendering (SPEC-013 Engine Architecture;
# SPEC-033 M14(a)/(g)) on the Workflow path, and the registration gate
# (check-template-vars.sh) plus commands/council.md substitution blocks.
#
# Judge-prompt verify-evidence assertions (Design 5, AC D judge half) are
# added to this same file by Task 5 (skills/council/prompts/judge.md).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

COUNCIL_MD="$ROOT/commands/council.md"
fail=0

ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-prompts-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

# ---- Workflow-path render (JS host) -----------------------------------------
if ( require_cmd node jq ); then
  RENDER_M14="$TMP/render-m14.txt"
  RENDER_NONM14="$TMP/render-non-m14.txt"
  if COUNCIL_RENDER_OUT_M14="$RENDER_M14" \
     COUNCIL_RENDER_OUT_NONM14="$RENDER_NONM14" \
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs'
import { loadPrompt } from './skills/council/workflow.js'

const m14 = loadPrompt('investigator', {
  CLAIM_TEXT: 'the widget renders correctly',
  SOURCE_LOCATOR: 'specs/core/SPEC-999.md:12',
  RAW_ARTIFACTS: '',
  FLAVOR_DELTA: '',
  CACHE_DIR: '/tmp/cache',
  TOOL_BUDGET: '8',
  VERIFY_COMMAND: 'bash skills/fx/test-a.sh',
})
writeFileSync(process.env.COUNCIL_RENDER_OUT_M14, m14)

const nonM14 = loadPrompt('investigator', {
  CLAIM_TEXT: 'the widget renders correctly',
  SOURCE_LOCATOR: 'specs/core/SPEC-999.md:12',
  RAW_ARTIFACTS: '',
  FLAVOR_DELTA: '',
  CACHE_DIR: '/tmp/cache',
  TOOL_BUDGET: '5',
  VERIFY_COMMAND: '',
})
writeFileSync(process.env.COUNCIL_RENDER_OUT_NONM14, nonM14)
console.log('OK: render done')
JS
  then
    ok "workflow.js: loadPrompt renders (M14, non-M14)"
  else
    fail_msg "workflow.js: loadPrompt render failed"
  fi

  if [ -s "$RENDER_M14" ]; then
    if grep -qF 'VERIFY exit=' "$RENDER_M14" \
      && grep -qF 'bash skills/fx/test-a.sh' "$RENDER_M14" \
      && grep -qF '600000' "$RENDER_M14" \
      && ! grep -qF '{{#VERIFY_COMMAND}}' "$RENDER_M14" \
      && ! grep -qF '{{/VERIFY_COMMAND}}' "$RENDER_M14" \
      && ! grep -qF '{{TOOL_BUDGET}}' "$RENDER_M14" \
      && ! grep -qF '{{VERIFY_COMMAND}}' "$RENDER_M14"; then
      ok "M14 render: wrapper, VERIFY exit=, 600000, no unsubstituted placeholders/markers"
    else
      fail_msg "M14 render: missing wrapper/exit/timeout, or a placeholder/marker leaked"
    fi
    if [ "$(grep -c 'BUDGET of 8 tool calls total\|after 8 calls\|NEVER exceed 8 tool calls' "$RENDER_M14")" -eq 3 ]; then
      ok "M14 render: 8 in all three budget spots"
    else
      fail_msg "M14 render: budget=8 not in all three spots"
    fi
  else
    fail_msg "M14 render: empty output"
  fi

  # verify:null render (this IS the non-M14 render) has no verify-run
  # artifacts left over and the 5-call non-M14 budget text intact.
  if [ -s "$RENDER_NONM14" ]; then
    if grep -qF '{{#VERIFY_COMMAND}}' "$RENDER_NONM14" \
      || grep -qF '{{/VERIFY_COMMAND}}' "$RENDER_NONM14" \
      || grep -qF 'VERIFY exit=' "$RENDER_NONM14" \
      || grep -qF 'VERIFY RUN (M14 per-AC)' "$RENDER_NONM14"; then
      fail_msg "non-M14 render: leftover verify-run marker/body"
    else
      ok "non-M14 render (verify:null): no verify-run marker/body left"
    fi
    if grep -qF 'BUDGET of 5 tool calls total' "$RENDER_NONM14" \
      && grep -qF 'after 5 calls' "$RENDER_NONM14" \
      && grep -qF 'NEVER exceed 5 tool calls' "$RENDER_NONM14"; then
      ok "non-M14 render: 5-call budget text intact"
    else
      fail_msg "non-M14 render: 5-call budget text missing/changed"
    fi
  else
    fail_msg "non-M14 render: empty output"
  fi
fi

# ---- check-template-vars.sh (both paths' registration) ---------------------
if bash "$ROOT/skills/council/check-template-vars.sh" >"$TMP/ctv.out" 2>&1; then
  ok "check-template-vars.sh exits 0"
else
  fail_msg "check-template-vars.sh failed: $(cat "$TMP/ctv.out")"
fi

# ---- commands/council.md: both investigator blocks name both new vars ------
n_tool_budget=$(grep -c '{{TOOL_BUDGET}}' "$COUNCIL_MD")
n_verify_command=$(grep -c '{{VERIFY_COMMAND}}' "$COUNCIL_MD")
if [ "$n_tool_budget" -ge 2 ] && [ "$n_verify_command" -ge 2 ]; then
  ok "commands/council.md: {{TOOL_BUDGET}} and {{VERIFY_COMMAND}} named in both investigator blocks"
else
  fail_msg "commands/council.md: {{TOOL_BUDGET}}/{{VERIFY_COMMAND}} missing from one or both investigator blocks (tool_budget=$n_tool_budget verify_command=$n_verify_command)"
fi

# ---- judge.md: verify-evidence rules (Task 5, AC D judge half) ------------
JUDGE_MD="$ROOT/skills/council/prompts/judge.md"

# judge_bite <label> <line-to-remove> <pattern-that-should-then-be-absent>
# Planted-negative control: removing the named line from a copy of judge.md
# must make its own grep fail. If it doesn't, the assertion above is
# checking something too broad to catch a real regression.
judge_bite() {
  local label="$1" match_line="$2" check_pattern="$3"
  local bitten
  bitten="$(mktemp "$TMP/judge.bite.XXXXXX")"
  grep -vF "$match_line" "$JUDGE_MD" > "$bitten"
  if grep -qF "$check_pattern" "$bitten"; then
    fail_msg "bite: removing the $label line left its own grep passing"
  else
    ok "bite: removing the $label line fails its own grep"
  fi
}

if grep -qF 'non-zero <n> (77 is a skip; treat' "$JUDGE_MD" \
  && grep -qF 'evidence AGAINST the claim. Do not issue' "$JUDGE_MD"; then
  ok "judge.md: non-zero VERIFY exit is evidence against"
else
  fail_msg "judge.md: missing the non-zero evidence-against rule"
fi
judge_bite "non-zero-exit" \
  '       - A "VERIFY exit=<n>" line with a non-zero <n> (77 is a skip; treat' \
  'non-zero <n> (77 is a skip; treat'

if grep -qF 'Any raw_blob line that starts with "SKIP:"' "$JUDGE_MD" \
  && grep -qF 'is a skip at ANY exit code' "$JUDGE_MD" \
  && grep -qF 'guard can print it and still exit 0' "$JUDGE_MD"; then
  ok "judge.md: a raw_blob line starting with SKIP: is a skip at any exit code"
else
  fail_msg "judge.md: missing the SKIP:-anchored skip-line rule"
fi
judge_bite "skip-line" \
  '         format) is a skip at ANY exit code (a suite'"'"'s own require_cmd' \
  'is a skip at ANY exit code'

if grep -qF 'A verify bundle (its reproducible_command equals' "$JUDGE_MD" \
  && grep -qF 'is a timeout. It is also evidence AGAINST' "$JUDGE_MD"; then
  ok "judge.md: timeout rule is scoped to a verify bundle with no VERIFY exit= line"
else
  fail_msg "judge.md: missing the scoped timeout rule"
fi
judge_bite "timeout" \
  '         is a timeout. It is also evidence AGAINST the claim, for the' \
  'is a timeout. It is also evidence AGAINST'

if grep -qF 'NO verify bundle at all in' "$JUDGE_MD" \
  && grep -qF 'MUST get confidence <=79' "$JUDGE_MD"; then
  ok "judge.md: a claim with verify and no verify bundle at all stays below 80"
else
  fail_msg "judge.md: missing the below-80 rule for a missing verify bundle"
fi
judge_bite "no-bundle-below-80" \
  '         bundle to read) MUST get confidence <=79 — a missing verify run' \
  'MUST get confidence <=79'

if grep -qF 'is not enough by itself. A pass alone' "$JUDGE_MD"; then
  ok "judge.md: a pass alone is not enough"
else
  fail_msg "judge.md: missing the pass-alone-is-not-enough rule"
fi
judge_bite "pass-alone" \
  '       - A "VERIFY exit=0" line is not enough by itself. A pass alone' \
  'is not enough by itself. A pass alone'

if [ "$fail" -eq 0 ]; then
  echo "PASS: test-verify-prompts.sh"
  exit 0
else
  echo "FAIL: test-verify-prompts.sh"
  exit 1
fi
