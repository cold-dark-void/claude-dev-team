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
#
# CDT-589-C4 per-AC run receipts (SPEC-013 § CDT-589-C4, CDT-595 pattern):
# checks inside a `set_ac` block print `ok AC<n>: <slug>` receipts (failures
# `FAIL: AC<n>: <slug>: <detail>` on stderr); `--ac AC<n>` runs that AC's
# checks and prints the subset aggregate. The last stdout line of any run is
# `PASS=<n> FAIL=<m>`; the count of `^ok ` lines equals n. The `OK:`/`FAIL:`
# prose lines and the golden-case output are kept for back-compat. AC3 binds
# the Forward claim seam, AC6 the scope exclusions.
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
# shellcheck source=../../tests/lib/ac-receipt.sh
. "$ROOT/tests/lib/ac-receipt.sh"
hermetic_init
parse_ac_args "$@"
PASS=0
FAIL=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/non-m14-plan-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"
git -c user.name=t -c user.email=t@t.invalid init -q "$REPO"

# slugify <label> — receipt slug from a prose label ([a-z0-9-] only).
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9-]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}
ok() {
  echo "OK: $1"
  # Receipt only for checks inside a set_ac block (CDT-589-C4 retrofit);
  # the pre-existing golden and byte-pin checks stay prose-only.
  if [ -n "${CUR_AC:-}" ] && want_ac; then
    PASS=$(( PASS + 1 ))
    printf 'ok %s: %s\n' "$CUR_AC" "$(slugify "$1")"
  fi
}
fail_msg() {
  echo "FAIL: $1"
  fail=1
  if [ -n "${CUR_AC:-}" ] && want_ac; then
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL: %s: %s: %s\n' "$CUR_AC" "$(slugify "$1")" failed >&2
  fi
}

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

# ---- CDT-589-C4 AC3: the Forward claim seam is engine-side, never a prompt --
# The prohibition lives only in forward-claim-addendum.txt and is composed into
# {{RAW_ARTIFACTS}} per claim. investigator.md and every flavor stay clean.
set_ac AC3
ADDENDUM="$ROOT/skills/council/forward-claim-addendum.txt"
ADDENDUM_BODY="$(cat "$ADDENDUM" 2>/dev/null)"
if [ ! -s "$ADDENDUM" ] || [ -z "$ADDENDUM_BODY" ]; then
  fail_msg "forward-claim-addendum.txt is missing or empty (the named seam)"
else
  ok "forward-claim-addendum.txt exists as the named seam"
fi
printf 'exhibit: the named seam is skills/council/forward-claim-addendum.txt, composed into per-claim {{RAW_ARTIFACTS}} when scope==plan and the claim text starts with [forward] \n'
if grep -qiF 'FORWARD CLAIM RULE' "$INVESTIGATOR"; then
  fail_msg "investigator.md carries the Forward claim addendum (AC3)"
else
  ok "investigator.md does not carry the Forward claim addendum"
fi
if grep -qiF '[forward] ' "$INVESTIGATOR"; then
  fail_msg "investigator.md names the [forward] tag (AC3)"
else
  ok "investigator.md does not name the [forward] tag"
fi
FLAV_HITS="$(grep -rliF 'FORWARD CLAIM RULE' "$ROOT/skills/council/flavors/" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$FLAV_HITS" = "0" ]; then
  ok "no flavor file carries the addendum (flavors byte-unchanged)"
else
  fail_msg "$FLAV_HITS flavor file(s) carry the addendum"
fi
NEW_PRESET="$(ls "$ROOT/skills/council/flavors/" 2>/dev/null | grep -c 'forward' | tr -d ' ')"
if [ "$NEW_PRESET" = "0" ]; then
  ok "no new flavor file or preset for the tag (AC3)"
else
  fail_msg "$NEW_PRESET new forward-named flavor/preset file(s) (AC3)"
fi
printf 'exhibit: no new flavor file, no new preset — investigator.md renders byte-identical to today for untagged claims\n'

# ---- CDT-589-C4 AC3: composeRawArtifacts keeps the untagged render exact ----
# Same substitution set as the byte-pin above, but the RAW_ARTIFACTS value now
# goes through composeRawArtifacts for an UNTAGGED plan-scope claim. The result
# MUST equal the cbee656 body byte-for-byte (identity seam), and the TAGGED
# claim's render must be exactly that prompt plus the addendum text.
if ( require_cmd node ); then
  COMP_OUT="$TMP/compose-render.txt"
  COMP_TAG_OUT="$TMP/compose-render-tagged.txt"
  if COUNCIL_ADD="$ADDENDUM" \
     COUNCIL_RENDER_OUT="$COMP_OUT" \
     COUNCIL_TAG_OUT="$COMP_TAG_OUT" \
     COUNCIL_FIXTURE_OUT="$TMP/fixture-body2.txt" \
     COUNCIL_FIXTURE_PATH="$FIX/investigator.cbee656.md" \
     COUNCIL_WORKFLOW_JS="$WORKFLOW_JS" \
     node --input-type=module <<'JS'
import { writeFileSync, readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const { loadPrompt, extractPromptBody, composeRawArtifacts } =
  await import(pathToFileURL(process.env.COUNCIL_WORKFLOW_JS).href)

const addendum = readFileSync(process.env.COUNCIL_ADD, 'utf8').trimEnd()
const bare = 'Step 3 adds flag --fwd-demo to skills/council/engine.sh'
const tagged = '[forward] ' + bare
const artifacts = 'artifacts line 1\nartifacts line 2'
// Identity substitution for every non-section var, exactly as the byte-pin
// above does, so a diff here can only be the seam's own effect.
const identityRender = (raw) => loadPrompt('investigator', {
  CLAIM_TEXT: '{{CLAIM_TEXT}}',
  SOURCE_LOCATOR: '{{SOURCE_LOCATOR}}',
  RAW_ARTIFACTS: raw,
  FLAVOR_DELTA: '{{FLAVOR_DELTA}}',
  CACHE_DIR: '{{CACHE_DIR}}',
  TOOL_BUDGET: '5',
  VERIFY_COMMAND: '',
})

// Untagged: the composed value is the identity, so the render equals the
// cbee656 body under the same identity substitution used by the byte-pin.
writeFileSync(process.env.COUNCIL_RENDER_OUT,
  identityRender(composeRawArtifacts('{{RAW_ARTIFACTS}}', bare, 'plan')))
// Tagged: CLAIM_TEXT keeps the prefix and the artifacts gain the addendum.
const taggedRender = loadPrompt('investigator', {
  CLAIM_TEXT: tagged,
  SOURCE_LOCATOR: 'plans/sample.md:Task Map:12',
  RAW_ARTIFACTS: composeRawArtifacts(artifacts, tagged, 'plan'),
  FLAVOR_DELTA: '{{FLAVOR_DELTA}}',
  CACHE_DIR: '',
  TOOL_BUDGET: '5',
  VERIFY_COMMAND: '',
})
writeFileSync(process.env.COUNCIL_TAG_OUT, taggedRender)
writeFileSync(process.env.COUNCIL_FIXTURE_OUT,
  extractPromptBody(readFileSync(process.env.COUNCIL_FIXTURE_PATH, 'utf8')))
console.log('OK: forward-claim compose renders prepared')
JS
  then
    if diff -q "$COMP_OUT" "$TMP/fixture-body2.txt" >/dev/null 2>&1; then
      ok "untagged plan-scope render through composeRawArtifacts is byte-exact vs cbee656"
    else
      fail_msg "untagged plan-scope render through composeRawArtifacts differs from cbee656"
      diff "$TMP/fixture-body2.txt" "$COMP_OUT" | head -20
    fi
    if grep -qF "FORWARD CLAIM RULE" "$COMP_TAG_OUT" \
       && grep -qF "$ADDENDUM_BODY" "$COMP_TAG_OUT"; then
      ok "tagged plan-scope render carries the addendum body"
    else
      fail_msg "tagged plan-scope render does not carry the addendum body"
    fi
    if grep -qF 'artifacts line 1' "$COMP_TAG_OUT" && grep -qF '[forward] ' "$COMP_TAG_OUT"; then
      ok "tagged render keeps the artifacts and the tagged CLAIM_TEXT verbatim"
    else
      fail_msg "tagged render lost the artifacts or the tagged CLAIM_TEXT"
    fi
    if diff -q "$COMP_TAG_OUT" "$TMP/fixture-body2.txt" >/dev/null 2>&1; then
      fail_msg "tagged render is identical to the untagged render (seam is inert)"
    else
      ok "tagged render differs from the untagged render (the seam is live)"
    fi
    printf 'exhibit: untagged plan-scope render is byte-identical to the cbee656 body; the tagged render appends the forward-claim-addendum.txt body under scope==plan only\n'
  else
    fail_msg "composeRawArtifacts render script failed"
  fi
fi

# ---- CDT-589-C4 AC6: M14 claim records never carry the [forward] tag -------
# The per-AC split (SPEC-013 Phase 1) builds claim text from a fixed template.
# Run the real trigger and prove no claim gained the tag, so the finalize guard
# (plan scope only) can never fire on a ship-gate run.
set_ac AC6
M14_SPEC="$ROOT/skills/council/fixtures/m14-split/valid-spec.md"
if [ ! -f "$M14_SPEC" ]; then
  fail_msg "M14 split fixture missing: $M14_SPEC"
else
  ok "M14 split fixture is present for the scope-exclusion case"
fi
cp "$M14_SPEC" "$REPO/valid-spec.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "m14 split fixture for the forward-claim scope exclusion"
M14_ARG="Ship-gate audit for wp-e2e-split. This ships under the ACs at ac-source=valid-spec.md (section '## Acceptance criteria', subsection '### wp-e2e-split'). Claim under audit: the change ships correctly."
M14_OUT="$( cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg "$M14_ARG" 2>"$TMP/m14.err" )"
M14_RC=$?
if [ "$M14_RC" -ne 0 ]; then
  fail_msg "M14 control preflight exit $M14_RC (want 0); stderr: $(cat "$TMP/m14.err")"
else
  ok "M14 control preflight exit 0 (the split fired)"
  if printf '%s' "$M14_OUT" | jq -e '.claims | length >= 1' >/dev/null 2>&1; then
    ok "M14 control produced claims[] (the split path is live)"
  else
    fail_msg "M14 control produced no claims[] — the split did not fire"
  fi
  TAGGED_N="$(printf '%s' "$M14_OUT" | jq -r '[.claims[] | select(.claim | startswith("[forward] "))] | length')"
  if [ "$TAGGED_N" = "0" ]; then
    ok "M14 claim records carry no [forward] prefix (AC6)"
  else
    fail_msg "$TAGGED_N M14 claim record(s) carry the [forward] prefix"
  fi
  M14_SCOPE="$(printf '%s' "$M14_OUT" | jq -r '.scope')"
  if [ "$M14_SCOPE" = "claim" ]; then
    ok "M14 control plan scope is claim (the guard's scope test excludes it)"
  else
    fail_msg "M14 control plan scope is $M14_SCOPE (want claim)"
  fi
fi

M14_PLAN_JSON="$TMP/m14-plan.json"
printf '%s' "$M14_OUT" > "$M14_PLAN_JSON"
if ( require_cmd node ); then
  NOOP_JS="$(COUNCIL_WF="$WORKFLOW_JS" COUNCIL_M14_PLAN="$M14_PLAN_JSON" node --input-type=module <<'JS'
import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
const { composeRawArtifacts } = await import(pathToFileURL(process.env.COUNCIL_WF).href)
const plan = JSON.parse(readFileSync(process.env.COUNCIL_M14_PLAN, 'utf8'))
const tagged = '[forward] Step 3 adds flag --fwd-demo to skills/council/engine.sh'
let bad = 0
// AC6: compose is a no-op at scope=claim — even for a tagged claim text, and
// for every claim record an M14 split emits.
if (composeRawArtifacts('raw artifacts', tagged, plan.scope) !== 'raw artifacts') {
  console.log('FAIL: composeRawArtifacts fired at scope=' + plan.scope)
  bad++
}
for (const c of plan.claims || []) {
  if (composeRawArtifacts('raw artifacts', c.claim, plan.scope) !== 'raw artifacts') {
    console.log('FAIL: composeRawArtifacts fired on M14 claim ' + c.claim_id)
    bad++
  }
}
// AC6: every non-plan scope is the identity — diff-mode, transcript-slice
// (session), --from-retro — tag present or not.
for (const scope of ['diff', 'session', 'from-retro']) {
  if (composeRawArtifacts('raw artifacts', tagged, scope) !== 'raw artifacts') {
    console.log('FAIL: composeRawArtifacts fired at scope=' + scope)
    bad++
  }
}
if (bad === 0) console.log('OK: composeRawArtifacts is a no-op at scope=claim')
process.exit(bad === 0 ? 0 : 1)
JS
)"
  if [ $? -eq 0 ] && printf '%s\n' "$NOOP_JS" | grep -q '^OK: composeRawArtifacts is a no-op at scope=claim'; then
    ok "composeRawArtifacts is a no-op at scope=claim (M14 ship-gate, AC6)"
  else
    fail_msg "composeRawArtifacts scope=claim no-op check failed"
    printf '%s\n' "$NOOP_JS" | sed 's/^/    /'
  fi
  if printf '%s\n' "$NOOP_JS" | grep -q 'FAIL:'; then
    fail_msg "composeRawArtifacts fired outside plan scope (AC6 scope exclusions)"
  else
    ok "composeRawArtifacts is a no-op at scope=diff, session (transcript-slice), from-retro (AC6)"
  fi
  printf 'exhibit: diff-mode / transcript-slice (scope=session) / --from-retro: no tag, no addendum, no guard\n'
  printf 'exhibit: scope=claim is the orchestrate Step 8/9 per-task council (task gate) and M14 ship-gate shape: the compose is a no-op and the guard cannot fire\n'
fi

# ---- CDT-589-C4 AC6: the split script itself emits no tagged claim ----------
# m14-ac-split.sh output (acs[]) is the M14 claim source; run it directly on
# the committed fixture and show its stdout carries no [forward] prefix.
printf 'CMD: env M14_AC_SOURCE=worktree bash skills/council/m14-ac-split.sh wp-e2e-split skills/council/fixtures/m14-split/valid-spec.md\n'
SPLIT_OUT="$(M14_AC_SOURCE=worktree bash "$ROOT/skills/council/m14-ac-split.sh" \
  wp-e2e-split skills/council/fixtures/m14-split/valid-spec.md 2>"$TMP/split.err")"
SPLIT_RC=$?
printf 'CMD exit=%s\n' "$SPLIT_RC"
if [ "$SPLIT_RC" -eq 0 ] && printf '%s' "$SPLIT_OUT" | grep -q '"acs"'; then
  if printf '%s' "$SPLIT_OUT" | grep -qF '[forward] '; then
    fail_msg "m14-ac-split.sh output carries a [forward] tag (AC6)"
  else
    ok "m14-ac-split.sh acs[] carries no [forward] tag; the split path fails closed as today (AC6)"
  fi
  printf 'exhibit: m14-ac-split.sh acs ids: %s\n' "$(printf '%s' "$SPLIT_OUT" | jq -c '[.acs[].id]' 2>/dev/null)"
else
  fail_msg "m14-ac-split.sh direct run failed: rc=$SPLIT_RC $(cat "$TMP/split.err")"
fi

# ---- CDT-589-C4 AC6: --blind gains no Forward claim machinery ---------------
if grep -qiF 'forward' "$ROOT/skills/council/phases-blind.md"; then
  fail_msg "phases-blind.md gained Forward claim machinery (--blind, AC6)"
else
  ok "phases-blind.md carries no Forward claim machinery (--blind, AC6)"
fi
printf 'exhibit: --blind adds no tag, no addendum, no guard; the guard keys on scope==plan + the [forward] prefix + CONTRADICTED/FABRICATED only\n'

# ---- CDT-589-C4 AC6: Task path and --workflow path share the predicate ------
if grep -qi 'forward-claim addendum' "$ROOT/commands/council.md" \
  && grep -qF 'composeRawArtifacts' "$WORKFLOW_JS"; then
  ok "Task path (commands/council.md) and --workflow path (workflow.js) apply the same predicate (AC6)"
else
  fail_msg "Task-path / --workflow-path predicate parity broken (AC6)"
fi
printf 'exhibit: Task path: commands/council.md Forward claim addendum block; --workflow path: workflow.js composeRawArtifacts; one guard: engine-finalize.sh\n'


if [ "$fail" -eq 0 ]; then
  echo "PASS: test-non-m14-plan.sh"
else
  echo "FAIL: test-non-m14-plan.sh"
  FAIL=$(( FAIL + 1 ))
fi
ac_finish
