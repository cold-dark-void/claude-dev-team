#!/usr/bin/env bash
# WP 1-14 T4 (AC G) — non-M14 preflight plans are byte-for-byte unchanged.
#
# Golden fixtures were generated ONCE from the BASE engine at commit
# 1898468 (skills/council/engine.sh, pre-WP-1-14), run from an isolated
# temp git repo — never from the live, in-edit engine. See
# skills/council/fixtures/non-m14-plan/*.golden.json.
#
# This suite re-runs the SAME preflight invocations against the current
# engine.sh and asserts the normalized plan JSON is identical under `jq -S`
# (C2: "non-M14 plan byte-for-byte unchanged"). It is re-verified by T3 and
# T12 after the M14 split lands, to prove that change is additive-only.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/non-m14-plan"
INVESTIGATOR="$ROOT/skills/council/prompts/investigator.md"
WORKFLOW_JS="$ROOT/skills/council/workflow.js"
fail=0

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

TMP="$(mktemp -d "${TMPDIR:-/tmp}/non-m14-plan-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"
git -c user.name=t -c user.email=t@t.invalid init -q "$REPO"

ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

# Normalize the SAME way the golden fixtures were built: drop the
# per-run-random keys, and collapse the MROOT prefix + UTC date in
# report_path to placeholders so the comparison is stable across runs.
NORMALIZE='
  . as $in
  | ($in.mroot) as $m
  | ($in.report_path | sub($m; "<MROOT>") | sub("[0-9]{4}-[0-9]{2}-[0-9]{2}"; "<DATE>")) as $rp
  | ($in | del(.run_id,.cache_dir) | .mroot = "<MROOT>" | .report_path = $rp)
'

# check_case <name> <scope-arg> [engine-flags...]
check_case() {
  local name="$1"; shift
  local scope_arg="$1"; shift
  local out rc norm golden
  out="$(cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg "$scope_arg" "$@" 2>"$TMP/$name.err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_msg "$name: preflight exit $rc (want 0); stderr: $(cat "$TMP/$name.err")"
    return
  fi
  norm="$(printf '%s' "$out" | jq -S "$NORMALIZE")"
  golden="$(jq -S . "$FIX/$name.golden.json")"
  if [ "$norm" = "$golden" ]; then
    ok "$name: plan unchanged vs BASE golden"
  else
    fail_msg "$name: plan differs from BASE golden"
    diff <(printf '%s\n' "$golden") <(printf '%s\n' "$norm") | head -40
  fi
  if printf '%s' "$norm" | jq -e '.claim_budget==10' >/dev/null 2>&1; then
    ok "$name: claim_budget==10"
  else
    fail_msg "$name: claim_budget != 10"
  fi
  if printf '%s' "$norm" | jq -e '(has("claims") or has("ac_source") or has("process_acs"))' >/dev/null 2>&1; then
    fail_msg "$name: unexpected M14 key present (claims/ac_source/process_acs)"
  else
    ok "$name: no M14 keys (claims/ac_source/process_acs)"
  fi
}

# ---- Case 1: plain claim -----------------------------------------------------
check_case plain-claim "Fix the widget renderer to handle null input."

# ---- Case 2: claim with --tier light -----------------------------------------
check_case tier-light "Fix the widget renderer." --tier light

# ---- Case 3: --why ------------------------------------------------------------
check_case why-flag "Fix the widget renderer." --why

# ---- Case 4: OLD M14 envelope (no ac-source= token) --------------------------
check_case old-m14-envelope "Ship-gate audit for CDT-999. Claim under audit: the widget renders correctly."

# ---- Case 5: claim holding ac-source= but not the M14 trigger prefix --------
check_case ac-source-no-prefix "Please review this claim: ac-source=specs/core/SPEC-999-foo.md is mentioned but not as a trigger."

# ---- Investigator prompt: byte-exact non-M14 render (precondition 1, AC E) --
# Identity substitution for every non-section var (each var maps to its own
# {{VAR}} placeholder, a no-op), plus explicit TOOL_BUDGET='5' and
# VERIFY_COMMAND='' (the non-M14 call-site values). The section blocks then
# remove {{#VERIFY_COMMAND}}...{{/VERIFY_COMMAND}} entirely (empty), so the
# result must equal extractPromptBody() of the investigator.md at cbee656,
# byte-for-byte — no Verify: line existed there to add TOOL_BUDGET/
# VERIFY_COMMAND placeholders to begin with.
if ( require_cmd node ); then
  RENDER_OUT="$TMP/render-non-m14.txt"
  FIXTURE_OUT="$TMP/fixture-body.txt"
  if COUNCIL_RENDER_OUT="$RENDER_OUT" \
     COUNCIL_FIXTURE_OUT="$FIXTURE_OUT" \
     COUNCIL_FIXTURE_PATH="$FIX/investigator.cbee656.md" \
     COUNCIL_WORKFLOW_JS="$WORKFLOW_JS" \
     node --input-type=module <<'JS'
import { writeFileSync, readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const { loadPrompt, extractPromptBody } = await import(pathToFileURL(process.env.COUNCIL_WORKFLOW_JS).href)

const rendered = loadPrompt('investigator', {
  CLAIM_TEXT: '{{CLAIM_TEXT}}',
  SOURCE_LOCATOR: '{{SOURCE_LOCATOR}}',
  RAW_ARTIFACTS: '{{RAW_ARTIFACTS}}',
  FLAVOR_DELTA: '{{FLAVOR_DELTA}}',
  CACHE_DIR: '{{CACHE_DIR}}',
  TOOL_BUDGET: '5',
  VERIFY_COMMAND: '',
})
writeFileSync(process.env.COUNCIL_RENDER_OUT, rendered)

const fixtureMd = readFileSync(process.env.COUNCIL_FIXTURE_PATH, 'utf8')
writeFileSync(process.env.COUNCIL_FIXTURE_OUT, extractPromptBody(fixtureMd))
console.log('OK: non-m14 byte-exact render prepared')
JS
  then
    if diff -q "$RENDER_OUT" "$FIXTURE_OUT" >/dev/null 2>&1; then
      ok "investigator.md: non-M14 render byte-exact vs cbee656 fixture"
    else
      fail_msg "investigator.md: non-M14 render differs from cbee656 fixture"
      diff "$FIXTURE_OUT" "$RENDER_OUT" | head -40
    fi
  else
    fail_msg "investigator.md: non-M14 render script failed"
  fi
fi


if [ "$fail" -eq 0 ]; then
  echo "PASS: test-non-m14-plan.sh"
  exit 0
else
  echo "FAIL: test-non-m14-plan.sh"
  exit 1
fi
