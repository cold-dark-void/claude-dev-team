#!/usr/bin/env bash
#
# autopilot/test-m14-verify-chain.sh -- WP 1-15 T10 (AC F). Fixture chain:
# split -> preflight plan claims -> investigator prompt render -> synthetic
# judge output -> finalize -> finalize-meta sidecar ->
# skills/autopilot/ship-gate-verdict.sh.
#
# This suite proves the MAPPING through the pipeline only: a synthetic
# judge output feeds a deterministic outcome to the mapper. It does not
# prove that a live council investigator runs a Verify command and reaches
# that verdict on its own -- the first live proof of that is the WP 1-05
# ship gate (SPEC-033 M14, WP 1-15 kickoff reading (A), Q5).
#
# Step 3 (per-case, node+jq only; steps 1, 2, 4 and 5 stay bash-only):
# renders the investigator prompt for each of the 8 plan.claims[] via
# workflow.js's loadPrompt, with vars set the way runOneInv sets them
# (C4: TOOL_BUDGET = String(claim.tool_budget ?? 5), VERIFY_COMMAND =
# claim.verify ?? ''), then asserts budget/command/exit-marker text on the
# 7 verify claims and the substantive non-M14 shape on the 1 null-verify
# claim -- the same pattern as skills/council/test-verify-prompts.sh.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh) and a private temp
# git repo (the fixture spec and its stub Verify targets are committed into
# it below; the live worktree is never touched).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
SPLIT="$ROOT/skills/council/m14-ac-split.sh"
MAPPER="$ROOT/skills/autopilot/ship-gate-verdict.sh"
WORKFLOW_JS="$ROOT/skills/council/workflow.js"
FIX="$ROOT/skills/autopilot/fixtures/m14-verify-chain"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
fail_msg() { echo "FAIL: $1"; fail=$((fail + 1)); }
ok_eq() {  # ok_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail_msg "$1 (got: $2 | want: $3)"; fi
}

REPO="$HERMETIC_ROOT/repo"
mkdir -p "$REPO/skills/fx"
git init -q "$REPO"
cp "$FIX/wp-fx-spec.md" "$REPO/wp-fx-spec.md"
cp "$FIX"/test-*.sh "$REPO/skills/fx/"
chmod 755 "$REPO"/skills/fx/test-*.sh
git -C "$REPO" add -A
git -C "$REPO" commit -q -m fixtures

TICKET="wp-fx"
SPEC_REL="wp-fx-spec.md"
TRIGGER_ARG="Ship-gate audit for $TICKET. This ships under the ACs at ac-source=$SPEC_REL (section '## Acceptance criteria', subsection '### $TICKET'). Claim under audit: the change ships correctly."

# ==============================================================================
# 1. Split: 8 technical ACs (A-G with a Verify line, H without), 1 process AC
# ==============================================================================
SPLIT_OUT="$( cd "$REPO" && bash "$SPLIT" "$TICKET" "$SPEC_REL" )"
RC_SPLIT=$?
ok_eq "1 split: exit 0" "$RC_SPLIT" "0"
ok_eq "1 split: 8 technical ACs" \
  "$(printf '%s' "$SPLIT_OUT" | jq '[.acs[] | select(.process==false)] | length')" "8"
ok_eq "1 split: 1 process AC" \
  "$(printf '%s' "$SPLIT_OUT" | jq '[.acs[] | select(.process==true)] | length')" "1"
ok_eq "1 split: 7 ACs carry a non-null verify" \
  "$(printf '%s' "$SPLIT_OUT" | jq '[.acs[] | select(.verify != null)] | length')" "7"
ok_eq "1 split: AC A verify" \
  "$(printf '%s' "$SPLIT_OUT" | jq -r '.acs[] | select(.id=="A") | .verify')" \
  "bash skills/fx/test-a.sh"
ok_eq "1 split: AC H verify is null" \
  "$(printf '%s' "$SPLIT_OUT" | jq -c '.acs[] | select(.id=="H") | .verify')" "null"
ok_eq "1 split: AC I is [process] with no verify" \
  "$(printf '%s' "$SPLIT_OUT" | jq -c '.acs[] | select(.id=="I") | {process, verify}')" \
  '{"process":true,"verify":null}'

# ==============================================================================
# 2. Preflight: plan.claims[].verify and .tool_budget (8 with a command,
#    5 without). 8 claims total (the [process] AC never becomes a claim).
# ==============================================================================
PLAN="$HERMETIC_ROOT/plan.json"
( cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg "$TRIGGER_ARG" ) > "$PLAN"
RC_PRE=$?
ok_eq "2 preflight: exit 0" "$RC_PRE" "0"
ok_eq "2 preflight: 8 claims" "$(jq '.claims | length' "$PLAN")" "8"
ok_eq "2 preflight: 7 claims carry a verify command" \
  "$(jq '[.claims[] | select(.verify != null)] | length' "$PLAN")" "7"
ok_eq "2 preflight: 1 claim has verify:null" \
  "$(jq '[.claims[] | select(.verify == null)] | length' "$PLAN")" "1"

BUDGET_MISMATCH=0
for i in $(seq 0 7); do
  V=$(jq -c ".claims[$i].verify" "$PLAN")
  B=$(jq ".claims[$i].tool_budget" "$PLAN")
  if [ "$V" = "null" ]; then
    [ "$B" = "5" ] || BUDGET_MISMATCH=1
  else
    [ "$B" = "8" ] || BUDGET_MISMATCH=1
  fi
done
ok_eq "2 preflight: every claim's tool_budget matches its verify (8 with, 5 without)" \
  "$BUDGET_MISMATCH" "0"

# ==============================================================================
# 3. Render: each plan.claims[] investigator prompt via workflow.js's
#    loadPrompt, with vars set the way runOneInv sets them (C4). node+jq
#    only; the rest of this suite stays bash-only, so this whole step is
#    guarded and skips (exit 77) when either tool is missing.
# ==============================================================================
if ( require_cmd node jq ); then
  RESULTS="$HERMETIC_ROOT/step3-results.json"
  NEGCTRL="$HERMETIC_ROOT/step3-negctrl.txt"
  if COUNCIL_WORKFLOW_JS="$WORKFLOW_JS" \
     COUNCIL_PLAN_FILE="$PLAN" \
     COUNCIL_RESULTS_OUT="$RESULTS" \
     COUNCIL_NEGCTRL_OUT="$NEGCTRL" \
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const { loadPrompt } = await import(pathToFileURL(process.env.COUNCIL_WORKFLOW_JS).href)

const plan = JSON.parse(readFileSync(process.env.COUNCIL_PLAN_FILE, 'utf8'))

// Same vars runOneInv sets per claim (workflow.js C4).
const renderClaim = (c, budgetOverride) => loadPrompt('investigator', {
  CLAIM_TEXT: c.claim || '',
  SOURCE_LOCATOR: c.source_locator || 'unknown',
  RAW_ARTIFACTS: '',
  FLAVOR_DELTA: '',
  CACHE_DIR: '',
  TOOL_BUDGET: budgetOverride != null ? budgetOverride : String(c.tool_budget ?? 5),
  VERIFY_COMMAND: c.verify ?? '',
})

const results = plan.claims.map((c, i) => ({
  index: i,
  ac_id: c.ac_id ?? null,
  verify: c.verify ?? '',
  tool_budget: String(c.tool_budget ?? 5),
  text: renderClaim(c),
}))
writeFileSync(process.env.COUNCIL_RESULTS_OUT, JSON.stringify(results))

// Negative control (required correction 5): render a verify claim with
// TOOL_BUDGET forced to '5' -- the budget-8 checks below must fail on it.
const negSrc = plan.claims.find((c) => c.verify)
if (negSrc) {
  writeFileSync(process.env.COUNCIL_NEGCTRL_OUT, renderClaim(negSrc, '5'))
}
console.log('OK: step3 render done')
JS
  then
    ok "3 render: workflow.js loadPrompt renders all 8 claims"
  else
    fail_msg "3 render: workflow.js loadPrompt render failed"
  fi

  TMP3="$HERMETIC_ROOT/step3-renders"
  mkdir -p "$TMP3"

  # ---- 7 verify claims: budget=8 in all three spots, the C5 has_command
  # wrapper with the claim's own Verify command, VERIFY exit= present, no
  # leftover {{ markers. ------------------------------------------------
  VERIFY_ACS="$TMP3/verify-acs.txt"
  jq -r '.[] | select(.verify != "" and .verify != null) | .ac_id' "$RESULTS" > "$VERIFY_ACS"
  ok_eq "3 render: 7 claims carry a verify command" "$(wc -l < "$VERIFY_ACS" | tr -d ' ')" "7"

  while IFS= read -r ACID; do
    [ -z "$ACID" ] && continue
    TXT="$TMP3/render-$ACID.txt"
    jq -r --arg id "$ACID" '.[] | select(.ac_id==$id) | .text' "$RESULTS" > "$TXT"
    VCMD=$(jq -r --arg id "$ACID" '.[] | select(.ac_id==$id) | .verify' "$RESULTS")

    if grep -qF 'BUDGET of 8 tool calls total' "$TXT" \
      && grep -qF 'after 8 calls' "$TXT" \
      && grep -qF 'NEVER exceed 8 tool calls' "$TXT"; then
      ok "3 render AC $ACID: 8 in all three budget spots"
    else
      fail_msg "3 render AC $ACID: budget=8 not in all three spots"
    fi

    if grep -qF "TMPDIR=\"\$d\" $VCMD >\"\$d.log\" 2>&1; echo \"VERIFY exit=\$?\"" "$TXT"; then
      ok "3 render AC $ACID: has_command wrapper carries $VCMD"
    else
      fail_msg "3 render AC $ACID: has_command wrapper missing/mismatched for $VCMD"
    fi

    if grep -qF 'VERIFY exit=' "$TXT" && ! grep -qF '{{' "$TXT"; then
      ok "3 render AC $ACID: VERIFY exit= present, no leftover {{ markers"
    else
      fail_msg "3 render AC $ACID: missing VERIFY exit= or a leftover {{ marker"
    fi
  done < "$VERIFY_ACS"

  # ---- 1 null-verify claim: the substantive non-M14 shape (no verify-run
  # artifacts, 5-call budget text intact). --------------------------------
  TXT_NULL="$TMP3/render-null.txt"
  jq -r '.[] | select(.verify == "" or .verify == null) | .text' "$RESULTS" > "$TXT_NULL"
  if [ -s "$TXT_NULL" ]; then
    if grep -qF 'VERIFY exit=' "$TXT_NULL" \
      || grep -qF 'VERIFY RUN (M14 per-AC)' "$TXT_NULL" \
      || grep -qF '{{' "$TXT_NULL"; then
      fail_msg "3 render (null verify): leftover verify-run marker/body or unsubstituted {{ }}"
    else
      ok "3 render (null verify): no verify-run marker/body, no leftover {{ markers"
    fi
    if grep -qF 'BUDGET of 5 tool calls total' "$TXT_NULL" \
      && grep -qF 'after 5 calls' "$TXT_NULL" \
      && grep -qF 'NEVER exceed 5 tool calls' "$TXT_NULL"; then
      ok "3 render (null verify): 5-call budget text intact"
    else
      fail_msg "3 render (null verify): 5-call budget text missing/changed"
    fi
  else
    fail_msg "3 render (null verify): empty output"
  fi

  # ---- Negative control: the same budget-8 checks must fail on a verify
  # claim rendered with TOOL_BUDGET forced to '5'. -----------------------
  if [ -s "$NEGCTRL" ]; then
    if grep -qF 'BUDGET of 8 tool calls total' "$NEGCTRL" \
      || grep -qF 'after 8 calls' "$NEGCTRL" \
      || grep -qF 'NEVER exceed 8 tool calls' "$NEGCTRL"; then
      fail_msg "3 negative control: budget-8 phrases leaked into a TOOL_BUDGET=5 render"
    else
      ok "3 negative control: budget-8 checks correctly fail when TOOL_BUDGET=5"
    fi
  else
    fail_msg "3 negative control: empty output"
  fi
fi

# ==============================================================================
# 4. Synthetic judge output: all 8 ACs tagged VERIFIED at 85 -> finalize ->
#    sidecar -> ship-gate-verdict.sh with card #1 -> agree, bump copied.
# ==============================================================================
CARD1="$HERMETIC_ROOT/card1.json"
cat > "$CARD1" <<'CARD1_EOF'
{"gate":"ship-choice","decision":"merge","bump":"patch","decided_by":"auto",
 "blocking_condition":null,"council_tier":null,"grading_reason":null}
CARD1_EOF

JUDGE_ALL="$HERMETIC_ROOT/judge-all-verified.json"
jq '{
  verdicts: [.claims[] | {claim_id: .claim_id, claim: .claim,
    verdict: "VERIFIED", confidence: 85, evidence_blob: "VERIFY exit=0"}],
  struck_lines: []
}' "$PLAN" > "$JUDGE_ALL"

EVIDENCE_ALL="$HERMETIC_ROOT/evidence-all.json"
cat > "$EVIDENCE_ALL" <<'EV_EOF'
[{"tool_use_id": "t1", "raw_blob": "VERIFY exit=0",
  "file_line": "skills/fx/test-a.sh:1", "reproducible_command": "bash skills/fx/test-a.sh"}]
EV_EOF

REPORT_ALL="$HERMETIC_ROOT/report-all.md"
( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN" --evidence-file "$EVIDENCE_ALL" \
    --judge-output "$JUDGE_ALL" --report-out "$REPORT_ALL" \
    > "$HERMETIC_ROOT/finalize-all.out" 2>"$HERMETIC_ROOT/finalize-all.err" )
RC_FIN_ALL=$?
ok_eq "4 finalize (all VERIFIED): exit 0" "$RC_FIN_ALL" "0"

META_ALL="${REPORT_ALL}.finalize-meta.json"
if [ -f "$META_ALL" ]; then
  ok "4 sidecar exists"
else
  fail_msg "4 sidecar exists (not found: $META_ALL)"
fi
ok_eq "4 sidecar.ac_claims length" "$(jq '.ac_claims | length' "$META_ALL")" "8"

VERDICT_ALL="$(bash "$MAPPER" --meta "$META_ALL" --card1 "$CARD1" --tier full)"
RCV_ALL=$?
ok_eq "4 mapper: exit 0" "$RCV_ALL" "0"
ok_eq "4 mapper: decision agree -> merge (card #1's decision)" \
  "$(printf '%s' "$VERDICT_ALL" | jq -r '.decision')" "merge"
ok_eq "4 mapper: blocking_condition null" \
  "$(printf '%s' "$VERDICT_ALL" | jq -c '.blocking_condition')" "null"
ok_eq "4 mapper: confidence == 85" "$(printf '%s' "$VERDICT_ALL" | jq '.confidence')" "85"
ok_eq "4 mapper: bump copied from card #1" \
  "$(printf '%s' "$VERDICT_ALL" | jq -r '.bump')" "patch"

# ==============================================================================
# 5. Same, with AC A's verdict CONTRADICTED (its bundle holds "VERIFY exit=1")
#    -> blocking_condition=7, confidence=0. A distinct --report-out avoids
#    reusing (and overwriting) step 4's sidecar.
# ==============================================================================
JUDGE_ONE_BAD="$HERMETIC_ROOT/judge-one-bad.json"
jq '{
  verdicts: [.claims[] | {claim_id: .claim_id, claim: .claim,
    verdict: (if .ac_id == "A" then "CONTRADICTED" else "VERIFIED" end),
    confidence: (if .ac_id == "A" then 20 else 85 end),
    evidence_blob: (if .ac_id == "A" then "VERIFY exit=1" else "VERIFY exit=0" end)}],
  struck_lines: []
}' "$PLAN" > "$JUDGE_ONE_BAD"

EVIDENCE_ONE_BAD="$HERMETIC_ROOT/evidence-one-bad.json"
cat > "$EVIDENCE_ONE_BAD" <<'EV_EOF'
[{"tool_use_id": "t1", "raw_blob": "VERIFY exit=1",
  "file_line": "skills/fx/test-a.sh:1", "reproducible_command": "bash skills/fx/test-a.sh"},
 {"tool_use_id": "t2", "raw_blob": "VERIFY exit=0",
  "file_line": "skills/fx/test-b.sh:1", "reproducible_command": "bash skills/fx/test-b.sh"}]
EV_EOF

REPORT_BAD="$HERMETIC_ROOT/report-bad.md"
( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN" --evidence-file "$EVIDENCE_ONE_BAD" \
    --judge-output "$JUDGE_ONE_BAD" --report-out "$REPORT_BAD" \
    > "$HERMETIC_ROOT/finalize-bad.out" 2>"$HERMETIC_ROOT/finalize-bad.err" )
RC_FIN_BAD=$?
ok_eq "5 finalize (AC A CONTRADICTED): exit 0" "$RC_FIN_BAD" "0"

META_BAD="${REPORT_BAD}.finalize-meta.json"

VERDICT_BAD="$(bash "$MAPPER" --meta "$META_BAD" --card1 "$CARD1" --tier full)"
RCV_BAD=$?
ok_eq "5 mapper: exit 0" "$RCV_BAD" "0"
ok_eq "5 mapper: decision halt" "$(printf '%s' "$VERDICT_BAD" | jq -r '.decision')" "halt"
ok_eq "5 mapper: blocking_condition == 7" \
  "$(printf '%s' "$VERDICT_BAD" | jq -c '.blocking_condition')" "7"
ok_eq "5 mapper: confidence == 0" "$(printf '%s' "$VERDICT_BAD" | jq '.confidence')" "0"
case "$(printf '%s' "$VERDICT_BAD" | jq -r '.rationale')" in
  *"A=CONTRADICTED"*) ok "5 mapper: rationale names AC A's CONTRADICTED verdict" ;;
  *) fail_msg "5 mapper: rationale missing A=CONTRADICTED: $VERDICT_BAD" ;;
esac

# ==============================================================================
# 6. Bundle-conformance check (SPEC-033 wp-1-16-m14-finder-recipe AC E): a
#    test-only bash+jq helper re-runs each fixture bundle's
#    reproducible_command in a private repo and requires byte-equality with
#    raw_blob (the matched verify bundle instead needs a real exit 0 and a
#    VERIFY exit=0 line), an AC-bullet quote anchored on the split's own
#    .line (TL M7 / 10b gap 4), and every named token -- backtick spans,
#    path:N, Case N, AC X -- from that quote, counted only in bundles other
#    than the quote itself (TL H2/D11; numbered sub-clauses are advisory,
#    no cap). A corrupted-blob, a wrong-line, a missing-token and an
#    elision set must all fail it, each pinned to its own CC-FAIL reason
#    (TL L2 / 10b gap 2). Then the same meta-shape feeds
#    ship-gate-verdict.sh directly (all ACs >=80 -> no BC7; one AC at 79 ->
#    blocking_condition 7).
# ==============================================================================
RECIPE_FIX="$FIX/recipe"

# ---- extract_tokens <quote-text>: three of the four C4 token classes --
# backtick spans stripped of their backticks, path:N locators, "Case N",
# "AC X" -- one per output line, deduped. Numbered sub-clauses `(n)` are
# NOT extracted: TL H2/D11 narrows the judge cap (and this oracle) to the
# four mechanical classes, because no oracle can check a finder-chosen key
# phrase for a sub-clause. Every `grep -oE` call is guarded with `|| true`
# (a no-match rc=1 must not abort the pipeline under `pipefail`). ---------
extract_tokens() {
  local q="$1"
  {
    printf '%s\n' "$q" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//' || true
    printf '%s\n' "$q" | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' || true
    printf '%s\n' "$q" | grep -oE 'Case [0-9]+' || true
    printf '%s\n' "$q" | grep -oE 'AC [A-Z]' || true
  } | sort -u
}

# ---- conformance_check <repo> <bundles.json> <spec> <ticket>: prints
# "CC-FAIL: ..." per violation, returns 0 iff every AC E requirement holds.
# Ground truth -- the technical AC ids, each one's own Verify command and
# its own source .line -- comes from a real $SPLIT run on <spec>/<ticket>
# inside <repo>, never from this bundle set's own tags, so a whole AC
# missing its bundles, or a quote anchored on the wrong occurrence of a
# repeated id, is caught too. Each AC's quote bundle and its "other"
# bundles are found in ONE scan (TL M6: no double scan) and reused by both
# the quote-presence check and the token-coverage check below. Read-only
# otherwise: runs each bundle's reproducible_command with cwd=<repo>. -----
conformance_check() {
  local repo="$1" bundles="$2" spec="$3" ticket="$4"
  local rc=0
  local n
  n=$(jq 'length' "$bundles") || { echo "CC-FAIL: $bundles is not a JSON array"; return 1; }

  local split_out
  split_out=$( cd "$repo" && bash "$SPLIT" "$ticket" "$spec" 2>&1 ) \
    || { echo "CC-FAIL: $SPLIT failed on $ticket/$spec: $split_out"; return 1; }
  local ac_ids
  ac_ids=$(printf '%s' "$split_out" | jq -r '.acs[] | select(.process==false) | .id')

  # ---- One pass per AC: locate the bundle whose raw_blob's first line is
  # anchored on "<ac_line>: - **<id>.**" (the split's own .line for this
  # ticket, not just any occurrence of the bullet); everything else for
  # that AC becomes its "other" evidence. Parallel indexed arrays, not
  # associative arrays — bash 3.2 has no declare -A (CDT-271 macOS lane).
  # --------------------------------
  local -a ac_arr quote_arr other_arr
  ac_arr=() ; quote_arr=() ; other_arr=()
  local ac ac_line i bac blob first_line qi=0

  for ac in $ac_ids; do
    ac_arr+=("$ac")
    quote_arr+=("")
    other_arr+=("")
    ac_line=$(printf '%s' "$split_out" | jq -r --arg id "$ac" '.acs[] | select(.id==$id) | .line')
    for i in $(seq 0 $((n - 1))); do
      bac=$(jq -r ".[$i].ac_id" "$bundles")
      [ "$bac" = "$ac" ] || continue
      blob=$(jq -r ".[$i].raw_blob" "$bundles")
      first_line=$(printf '%s\n' "$blob" | awk 'NR==1')
      if [ -z "${quote_arr[$qi]}" ] && printf '%s' "$first_line" | grep -qE "^${ac_line}: - \*\*${ac}\.\*\*"; then
        quote_arr[$qi]="$blob"
      else
        other_arr[$qi]="${other_arr[$qi]}
$blob"
      fi
    done
    if [ -z "${quote_arr[$qi]}" ]; then
      echo "CC-FAIL: AC $ac: no bundle quotes the AC bullet at its source line ($ac_line)"
      rc=1
    fi
    qi=$((qi + 1))
  done

  # ---- Per-AC: the bundle matching its Verify command (from the split,
  # not a self-declared "kind" tag) exits 0 and its raw_blob holds
  # VERIFY exit=0. ----------------------------------------------------------
  local ac_verify match_count vblob vgot vgot_rc
  for ac in $ac_ids; do
    ac_verify=$(printf '%s' "$split_out" | jq -r --arg id "$ac" '.acs[] | select(.id==$id) | .verify // ""')
    [ -z "$ac_verify" ] && continue
    match_count=$(jq -r --arg cmd "$ac_verify" '[.[] | select(.reproducible_command==$cmd)] | length' "$bundles")
    if [ "$match_count" -eq 0 ]; then
      echo "CC-FAIL: AC $ac: no bundle matches its Verify command ($ac_verify)"
      rc=1
      continue
    fi
    vblob=$(jq -r --arg cmd "$ac_verify" '[.[] | select(.reproducible_command==$cmd) | .raw_blob][0]' "$bundles")
    vgot=$( cd "$repo" && bash -c "$ac_verify" 2>&1 )
    vgot_rc=$?
    if [ "$vgot_rc" -ne 0 ]; then
      echo "CC-FAIL: AC $ac verify bundle: reproducible_command exited $vgot_rc, want 0"
      rc=1
    fi
    case "$vblob" in
      *"VERIFY exit=0"*) : ;;
      *) echo "CC-FAIL: AC $ac verify bundle: raw_blob has no VERIFY exit=0 line"; rc=1 ;;
    esac
  done

  # ---- Byte-equality: every bundle other than an AC's own matched verify
  # bundle must re-run byte-equal to raw_blob. ------------------------------
  local cmd want got
  for i in $(seq 0 $((n - 1))); do
    ac=$(jq -r ".[$i].ac_id" "$bundles")
    cmd=$(jq -r ".[$i].reproducible_command" "$bundles")
    want=$(jq -r ".[$i].raw_blob" "$bundles")
    ac_verify=$(printf '%s' "$split_out" | jq -r --arg id "$ac" '(.acs[]? | select(.id==$id) | .verify) // ""')
    if [ -n "$ac_verify" ] && [ "$cmd" = "$ac_verify" ]; then
      continue
    fi
    got=$( cd "$repo" && bash -c "$cmd" 2>&1 )
    if [ "$got" != "$want" ]; then
      echo "CC-FAIL: AC $ac bundle ($cmd): re-run does not byte-equal raw_blob"
      rc=1
    fi
  done

  # ---- Token coverage: each token in the AC's own quote (reused from the
  # single scan above) has a bundle line, other than the quote itself,
  # that holds it (TL H2/D11: never inside the quote bundle, which
  # trivially holds every token it names). ----------------------------------
  local tok ti=0
  for ac in $ac_ids; do
    [ -z "${quote_arr[$ti]}" ] && { ti=$((ti + 1)); continue; }
    while IFS= read -r tok || [ -n "$tok" ]; do
      [ -z "$tok" ] && continue
      if ! printf '%s\n' "${other_arr[$ti]}" | grep -qF -- "$tok"; then
        echo "CC-FAIL: AC $ac: token '$tok' has no bundle line"
        rc=1
      fi
    done < <(extract_tokens "${quote_arr[$ti]}")
    ti=$((ti + 1))
  done

  # ---- Elision: no raw_blob line is exactly ..., [...] or … ---------------
  local all_blob line
  all_blob=$(jq -r '.[].raw_blob' "$bundles")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '...'|'[...]'|'…')
        echo "CC-FAIL: elision line '$line' present in a raw_blob"
        rc=1
        ;;
    esac
  done <<< "$all_blob"

  return "$rc"
}

# ---- cc_assert <label> <bundles> <spec> <ticket> <zero|nonzero> <want-CC-FAIL-count> [<needle> ...]
# One assertion helper for every conformance_check call below (TL M6: one
# place, not six copy-pasted if/else blocks). Checks the exit code, the
# EXACT count of CC-FAIL lines (TL L2 / 10b gap 2: proves the failure is
# isolated to the branch(es) named, not incidental collateral) and that
# each given needle is one of those CC-FAIL lines. ------------------------
cc_assert() {
  local label="$1" bundles="$2" spec="$3" ticket="$4" want="$5" want_count="$6"
  shift 6
  local out rc got_count good=1 needle
  out=$(conformance_check "$REPO2" "$bundles" "$spec" "$ticket" 2>&1)
  rc=$?
  got_count=$(printf '%s\n' "$out" | grep -c '^CC-FAIL' || true)
  if [ "$want" = zero ] && [ "$rc" -ne 0 ]; then good=0; fi
  if [ "$want" = nonzero ] && [ "$rc" -eq 0 ]; then good=0; fi
  if [ "$got_count" != "$want_count" ]; then good=0; fi
  for needle in "$@"; do
    printf '%s\n' "$out" | grep -qF -- "$needle" || good=0
  done
  if [ "$good" -eq 1 ]; then
    ok "6 conformance_check: $label"
  else
    fail_msg "6 conformance_check: $label (rc=$rc CC-FAIL-count=$got_count want=$want_count out=[$out])"
  fi
}

# ---- Fixture setup: a fresh private repo, the recipe fixtures committed
# into it (including the two-subsection decoy spec for the M7/gap4
# negative below), then each Verify stub run once to a FIXED
# <ac>.verify.log (never a mktemp path in a fixture bundle -- C3's <LOG>
# names this fixed path, so a re-run of the filter bundle is
# deterministic). ----------------------------------------------------------
REPO2="$HERMETIC_ROOT/repo-recipe"
mkdir -p "$REPO2/skills/fx"
git init -q "$REPO2"
cp "$RECIPE_FIX/wp-rx-spec.md" "$REPO2/wp-rx-spec.md"
cp "$RECIPE_FIX/wp-rx-two-subsections-spec.md" "$REPO2/wp-rx-two-subsections-spec.md"
cp "$RECIPE_FIX"/skills/fx/test-rx-a.sh "$RECIPE_FIX"/skills/fx/test-rx-b.sh "$RECIPE_FIX"/skills/fx/test-rx-c.sh \
   "$RECIPE_FIX/skills/fx/test-other-a.sh" "$REPO2/skills/fx/"
chmod 755 "$REPO2"/skills/fx/*.sh
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m fixtures

for ac_pair in "A:test-rx-a.sh" "B:test-rx-b.sh" "C:test-rx-c.sh"; do
  ac_id="${ac_pair%%:*}"
  script="${ac_pair#*:}"
  ( cd "$REPO2" && bash "skills/fx/$script" > "$REPO2/$ac_id.verify.log" 2>&1 )
  rc=$?
  echo "VERIFY exit=$rc" >> "$REPO2/$ac_id.verify.log"
done

# ---- 1. The conformant set passes. ---------------------------------------
cc_assert "conformant bundle set passes" \
  "$RECIPE_FIX/bundles-pass.json" "wp-rx-spec.md" "wp-rx" zero 0

# ---- 2. One elision line fails, and only that check. ----------------------
BUNDLES_FAIL_ELISION="$HERMETIC_ROOT/bundles-fail-elision.json"
jq '. + [{"ac_id":"A","kind":"token","reproducible_command":"printf -- '"'"'...\\n'"'"'","raw_blob":"..."}]' \
  "$RECIPE_FIX/bundles-pass.json" > "$BUNDLES_FAIL_ELISION"
cc_assert "a set with one elision line fails" \
  "$BUNDLES_FAIL_ELISION" "wp-rx-spec.md" "wp-rx" nonzero 1 "elision line"

# ---- 3. Negative control (planted, not a committed fixture): corrupt one
# committed raw_blob so it no longer byte-equals a re-run, and confirm the
# byte-equality branch itself -- not some other check -- is what catches
# it (hazard checklist: every static/comparison check needs a control). ---
BUNDLES_CORRUPT="$HERMETIC_ROOT/bundles-corrupt-blob.json"
jq '(.[0].raw_blob) |= . + " CORRUPTED"' "$RECIPE_FIX/bundles-pass.json" > "$BUNDLES_CORRUPT"
cc_assert "a corrupted raw_blob fails the byte-equality check" \
  "$BUNDLES_CORRUPT" "wp-rx-spec.md" "wp-rx" nonzero 1 "does not byte-equal"

# ---- 4. Two-subsection baseline (TL M7 / 10b gap 4): the same 3 ACs,
# re-quoted at their own (shifted) .line inside the decoy spec, must still
# pass whole -- otherwise the wrong-line negative below could pass for the
# wrong reason (a broken anchor regex failing every quote, not just the
# mis-anchored one). --------------------------------------------------------
QA_TS=$(cd "$REPO2" && awk -v n=16 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR": "$0}' wp-rx-two-subsections-spec.md)
QB_TS=$(cd "$REPO2" && awk -v n=19 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR": "$0}' wp-rx-two-subsections-spec.md)
QC_TS=$(cd "$REPO2" && awk -v n=22 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR": "$0}' wp-rx-two-subsections-spec.md)
BUNDLES_TS_PASS="$HERMETIC_ROOT/bundles-two-subsections-pass.json"
jq --arg qa_cmd "awk -v n=16 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR\": \"\$0}' wp-rx-two-subsections-spec.md" --arg qa_blob "$QA_TS" \
   --arg qb_cmd "awk -v n=19 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR\": \"\$0}' wp-rx-two-subsections-spec.md" --arg qb_blob "$QB_TS" \
   --arg qc_cmd "awk -v n=22 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR\": \"\$0}' wp-rx-two-subsections-spec.md" --arg qc_blob "$QC_TS" \
   'map(
      if .ac_id=="A" and .kind=="quote" then .reproducible_command=$qa_cmd | .raw_blob=$qa_blob
      elif .ac_id=="B" and .kind=="quote" then .reproducible_command=$qb_cmd | .raw_blob=$qb_blob
      elif .ac_id=="C" and .kind=="quote" then .reproducible_command=$qc_cmd | .raw_blob=$qc_blob
      else . end)' "$RECIPE_FIX/bundles-pass.json" > "$BUNDLES_TS_PASS"
cc_assert "two-subsection baseline (re-quoted at the shifted lines) passes" \
  "$BUNDLES_TS_PASS" "wp-rx-two-subsections-spec.md" "wp-rx" zero 0

# ---- 5. Wrong-line negative: AC A's quote bundle instead quotes the
# OTHER subsection's "- **A.**" decoy bullet (same id, wrong line) --
# fails, isolated to AC A's quote-anchor check. -----------------------------
WRONG_QUOTE=$'10: - **A.** this bullet belongs to a different ticket and must never be quoted\n11:   for wp-rx\n12:   Verify: bash skills/fx/test-other-a.sh'
BUNDLES_WRONG_LINE="$HERMETIC_ROOT/bundles-wrong-line.json"
jq --arg cmd "awk -v n=10 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR\": \"\$0}' wp-rx-two-subsections-spec.md" \
   --arg blob "$WRONG_QUOTE" \
   'map(if .ac_id=="A" and .kind=="quote" then .reproducible_command=$cmd | .raw_blob=$blob else . end)' \
   "$BUNDLES_TS_PASS" > "$BUNDLES_WRONG_LINE"
cc_assert "a quote anchored on the wrong occurrence of a repeated AC id fails" \
  "$BUNDLES_WRONG_LINE" "wp-rx-two-subsections-spec.md" "wp-rx" nonzero 1 "AC A: no bundle quotes"

# ---- 6. Missing-token negative (TL M8 / 10b gap 5): remove the "Case 2"
# token from the private repo's test-rx-a.sh (commit it, as the fail-exit
# mutation below does) and record its grep bundle with an empty raw_blob,
# so the token stays named in the AC's own quote (spec text, untouched)
# but is absent from every OTHER bundle -- fails, isolated to token
# coverage. -----------------------------------------------------------------
sed -i.bak "s/exercises Case 2 of the parser/exercises the parser's second branch/" "$REPO2/skills/fx/test-rx-a.sh" && rm -f "$REPO2/skills/fx/test-rx-a.sh.bak"
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m "remove the Case 2 literal from test-rx-a.sh"
BUNDLES_FAIL_TOKEN="$HERMETIC_ROOT/bundles-fail-token.json"
jq 'map(if .ac_id=="A" and .kind=="token" and (.reproducible_command | contains("Case 2"))
        then .raw_blob = ""
        else . end)' "$RECIPE_FIX/bundles-pass.json" > "$BUNDLES_FAIL_TOKEN"
cc_assert "a token with no bundle line anywhere in the repo fails" \
  "$BUNDLES_FAIL_TOKEN" "wp-rx-spec.md" "wp-rx" nonzero 1 "token 'Case 2' has no bundle line"

# ---- 7. Verify-stub-at-exit-1 negative (10b gap 2): swap AC A's Verify
# script in $REPO2 for the failing variant (lines 1-3 byte-identical to
# the passing stub; only the echo message and exit code change) and
# commit (the split requires a clean worktree), then check. Run last --
# it overwrites the whole file, superseding the Case 2 mutation above.
# Fails on exactly the two verify-bundle checks (exit code, VERIFY exit=0
# line), not on token coverage (the unmutated comment lines still match). -
cp "$RECIPE_FIX/skills/fx/test-rx-a-fail.sh" "$REPO2/skills/fx/test-rx-a.sh"
chmod 755 "$REPO2/skills/fx/test-rx-a.sh"
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m "swap AC A verify to the failing variant"
BUNDLES_FAIL_EXIT="$HERMETIC_ROOT/bundles-fail-exit.json"
jq 'map(if .ac_id=="A" and .kind=="verify"
        then .raw_blob = "VERIFY exit=1\nVERIFY log=/tmp/verify.fx7k2p.log\nPASS=0 FAIL=1"
        else . end)' "$RECIPE_FIX/bundles-pass.json" > "$BUNDLES_FAIL_EXIT"
cc_assert "a Verify stub at exit 1 fails on the exit branch only" \
  "$BUNDLES_FAIL_EXIT" "wp-rx-spec.md" "wp-rx" nonzero 2 \
  "exited 1, want 0" "no VERIFY exit=0 line"

# ---- ship-gate-verdict.sh on the recipe's synthetic finalize-meta:
# every AC at >=80 -> blocking_condition null; one AC at 79 -> 7. Reuses
# card #1 (decision merge, bump patch) from step 4. -----------------------
VERDICT_RX_PASS="$(bash "$MAPPER" --meta "$RECIPE_FIX/meta-pass.json" --card1 "$CARD1" --tier full)"
RCV_RX_PASS=$?
ok_eq "6 mapper (recipe meta-pass): exit 0" "$RCV_RX_PASS" "0"
ok_eq "6 mapper (recipe meta-pass): blocking_condition null" \
  "$(printf '%s' "$VERDICT_RX_PASS" | jq -c '.blocking_condition')" "null"

VERDICT_RX_FAIL="$(bash "$MAPPER" --meta "$RECIPE_FIX/meta-fail.json" --card1 "$CARD1" --tier full)"
RCV_RX_FAIL=$?
ok_eq "6 mapper (recipe meta-fail): exit 0" "$RCV_RX_FAIL" "0"
ok_eq "6 mapper (recipe meta-fail): blocking_condition == 7" \
  "$(printf '%s' "$VERDICT_RX_FAIL" | jq -c '.blocking_condition')" "7"

# ==============================================================================
echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
