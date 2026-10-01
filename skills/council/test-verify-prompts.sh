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
#
# WP 1-16 (M14 finder recipe, AC A-D) extends this file with:
#   - the RECIPE STEP 1-3 render shape and the C5 wording on the M14 render
#     (AC A, AC B);
#   - a fixture-driven test that extracts the C1 (quote) and C3 (filter)
#     command lines from the rendered prompt, substitutes their literal
#     placeholders, and runs them for real against
#     skills/council/fixtures/m14-finder-recipe/{spec-two-subsections.md,
#     verify-log.txt} (AC C);
#   - the three judge.md finder-recipe confidence caps (C6) plus a
#     byte-identity golden check that the five WP 1-15 VERIFY EVIDENCE
#     bullets are unchanged from 38bc739 (AC D).
#
# WP 1-16 T1 review fix pass (TL review + 10b spec check) further extends
# this file with: H1 Step 3 bounded/scoped-grep checks (default one call
# against the Verify test file, explicit path:N command, scoped fallback,
# never unscoped); H2/D11 the narrowed judge cap 2 (token classes, outside
# the Step 1 quote bundle); H3/gap1 a judge_cap helper that pins EACH cap's
# own <=79 threshold (not the file-wide phrase, which the frozen WP 1-15
# bullet also holds) with a rewrite-to-<=90 bite; M2 the real-shape summary
# alternatives (`pass=`/`fail=`/`^PASS:`) in the filter regex and fixture;
# M3 the pinned, executed C2 verify-run line (catches M1's `|| true` fix);
# M5 the non-M14 byte-identity golden now renders through the REAL
# loadPrompt (a temp copy of workflow.js), not a bash/awk mirror; L1
# in-suite negative controls on the render checks.
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
  # ---- WP 1-16 M5 (TL review): real-code golden setup ----------------------
  # loadPrompt cannot be invoked from this agent's own shell (an interpreter
  # this host blocks outside a repo suite), so the 38bc739 golden below is
  # rendered with the REAL loadPrompt, inside the SAME heredoc that already
  # runs this suite's own render: a scratch copy of workflow.js (it imports
  # only workflow-schemas.js, which itself has no imports) alongside the
  # pinned 38bc739 investigator.md. Replaces the earlier bash/awk mirror
  # (TL review M5) — this is the real render, not a second implementation.
  WF_DIR="$TMP/wf"
  mkdir -p "$WF_DIR/prompts"
  cp "$ROOT/skills/council/workflow.js" "$WF_DIR/workflow.js"
  cp "$ROOT/skills/council/workflow-schemas.js" "$WF_DIR/workflow-schemas.js"
  git show 38bc739:skills/council/prompts/investigator.md > "$WF_DIR/prompts/investigator.md"
  RENDER_GOLDEN_NONM14="$TMP/render-golden-non-m14.txt"

  if COUNCIL_RENDER_OUT_M14="$RENDER_M14" \
     COUNCIL_RENDER_OUT_NONM14="$RENDER_NONM14" \
     COUNCIL_RENDER_OUT_GOLDEN_NONM14="$RENDER_GOLDEN_NONM14" \
     COUNCIL_WF_GOLDEN="$WF_DIR/workflow.js" \
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

// M5 (TL review): the SAME non-M14 vars as above, through the REAL
// loadPrompt of a scratch copy of workflow.js pointed at the pinned
// 38bc739 investigator.md — not a bash/awk mirror of the render logic.
const goldenMod = await import(process.env.COUNCIL_WF_GOLDEN)
const golden = goldenMod.loadPrompt('investigator', {
  CLAIM_TEXT: 'the widget renders correctly',
  SOURCE_LOCATOR: 'specs/core/SPEC-999.md:12',
  RAW_ARTIFACTS: '',
  FLAVOR_DELTA: '',
  CACHE_DIR: '/tmp/cache',
  TOOL_BUDGET: '5',
  VERIFY_COMMAND: '',
})
writeFileSync(process.env.COUNCIL_RENDER_OUT_GOLDEN_NONM14, golden)
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

  # ---- WP 1-16 AC A: RECIPE STEP 1-3 render shape --------------------------
  if [ -s "$RENDER_M14" ]; then
    L1="$(grep -n 'RECIPE STEP 1' "$RENDER_M14" | head -1 | cut -d: -f1)"
    L2="$(grep -n 'RECIPE STEP 2' "$RENDER_M14" | head -1 | cut -d: -f1)"
    L3="$(grep -n 'RECIPE STEP 3' "$RENDER_M14" | head -1 | cut -d: -f1)"
    if [ -n "${L1:-}" ] && [ -n "${L2:-}" ] && [ -n "${L3:-}" ] \
      && [ "$L1" -lt "$L2" ] && [ "$L2" -lt "$L3" ]; then
      ok "AC A: M14 render holds RECIPE STEP 1, 2, 3 in order"
    else
      fail_msg "AC A: RECIPE STEP 1-3 missing or out of order (L1=${L1:-} L2=${L2:-} L3=${L3:-})"
    fi

    # L1 (TL review): in-suite negative control -- re-run the SAME ordering
    # logic against a render copy with RECIPE STEP 2 removed, and confirm
    # it now fails. Proves the check above is not vacuously true.
    MUT_STEP2="$TMP/render-m14.no-step2.txt"
    grep -v 'RECIPE STEP 2' "$RENDER_M14" > "$MUT_STEP2"
    ML1="$(grep -n 'RECIPE STEP 1' "$MUT_STEP2" | head -1 | cut -d: -f1)"
    ML2="$(grep -n 'RECIPE STEP 2' "$MUT_STEP2" | head -1 | cut -d: -f1)"
    ML3="$(grep -n 'RECIPE STEP 3' "$MUT_STEP2" | head -1 | cut -d: -f1)"
    if [ -n "${ML1:-}" ] && [ -n "${ML2:-}" ] && [ -n "${ML3:-}" ] \
      && [ "$ML1" -lt "$ML2" ] && [ "$ML2" -lt "$ML3" ]; then
      fail_msg "L1 bite: removing RECIPE STEP 2 left the order check passing (test bug)"
    else
      ok "L1 bite: removing RECIPE STEP 2 fails the order check"
    fi

    C1_EXPECTED="$(cat <<'C1EOF'
    awk -v n=<N> 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR": "$0}' <PATH>
C1EOF
)"
    if grep -qF -- "$C1_EXPECTED" "$RENDER_M14"; then
      ok "AC A: exact C1 quote-command line present"
    else
      fail_msg "AC A: exact C1 quote-command line missing from the M14 render"
    fi

    # L1 bite: a one-character mutation inside the pinned awk script must
    # break the exact-match check (proves it is not a loose prefix match).
    MUT_C1="$TMP/render-m14.mut-c1.txt"
    sed 's/NR==n{p=1}/NR==n{p=2}/' "$RENDER_M14" > "$MUT_C1"
    if grep -qF -- "$C1_EXPECTED" "$MUT_C1"; then
      fail_msg "L1 bite: mutating the C1 awk script left the exact-match check passing"
    else
      ok "L1 bite: mutating the C1 awk script fails the exact-match check"
    fi

    PATHN_EXPECTED="$(cat <<'PNEOF'
    awk 'NR==<N>{print FILENAME":"NR": "$0}' <PATH>
PNEOF
)"
    if grep -qF -- "$PATHN_EXPECTED" "$RENDER_M14"; then
      ok "AC A: exact path:N locator command present (H1)"
    else
      fail_msg "AC A: exact path:N locator command missing from the M14 render (H1)"
    fi

    # Flatten for the remaining phrase checks below: several of these wrap
    # across two physical lines in the prose, so a single-line grep -F would
    # silently never match -- on old OR new content (a vacuous-check class
    # this review round caught twice). Joining with a space first gives
    # every check real fail-closed power.
    RENDER_M14_FLAT="$(tr '\n' ' ' < "$RENDER_M14")"
    m14_has() { printf '%s' "$RENDER_M14_FLAT" | grep -qF -- "$1"; }

    if m14_has 'a backtick span' \
      && m14_has '`path:N` locator' \
      && m14_has '`Case N` or `AC X` reference' \
      && m14_has 'numbered' && m14_has 'sub-clause' \
      && m14_has 'grep -nF -e'; then
      ok "AC A: Step 3 names the four token classes and the grep -nF -e form"
    else
      fail_msg "AC A: Step 3 token-class wording missing or incomplete"
    fi

    # H1 (TL review): the default is ONE call against the Verify test file
    # for every non-path:N token; a scoped multi-e git grep is a FALLBACK
    # only, and the render never offers the old unscoped `git grep -nF -e
    # '<T>'` (one token, repo-wide) form the review flagged as unbounded.
    if m14_has 'ONE call against the Verify test file' \
      && m14_has "grep's complete output is its bundle's raw_blob" \
      && m14_has 'Never run an unscoped `git grep`' \
      && m14_has "git grep -nF -e '<T1>' -e '<T2>' -- <PATH>"; then
      ok "AC A: Step 3 defaults to one bounded call, scoped fallback only, never unscoped (H1)"
    else
      fail_msg "AC A: Step 3 missing the bounded-default / scoped-fallback wording (H1)"
    fi
    if m14_has "git grep -nF -e '<T>'"; then
      fail_msg "AC A: the old unscoped 'git grep -nF -e <T>' (one token, repo-wide) form is still present (H1)"
    else
      ok "AC A: the old unscoped one-token git grep form is gone (H1)"
    fi

    if m14_has 'cite the test lines and one diff hunk'; then
      fail_msg "AC A: forbidden string 'cite the test lines and one diff hunk' still present"
    else
      ok "AC A: no 'cite the test lines and one diff hunk'"
    fi
    # L1 bite: a render copy with the forbidden phrase re-added must trip
    # the negative check above (proves it is not vacuously always-absent).
    MUT_DIFFHUNK="$TMP/render-m14.diffhunk.txt"
    cp "$RENDER_M14" "$MUT_DIFFHUNK"
    echo 'cite the test lines and one diff hunk that back the claim.' >> "$MUT_DIFFHUNK"
    if tr '\n' ' ' < "$MUT_DIFFHUNK" | grep -qF 'cite the test lines and one diff hunk'; then
      ok "L1 bite: a render copy with the forbidden phrase re-added fails the negative check"
    else
      fail_msg "L1 bite: the negative check missed a re-added forbidden phrase (test bug)"
    fi

    if m14_has 'Paste each matched line verbatim into its own bundle'; then
      fail_msg "AC A: forbidden string 'Paste each matched line...' still present (H1)"
    else
      ok "AC A: no 'Paste each matched line verbatim' (H1)"
    fi
  fi

  # ---- WP 1-16 AC B: C5 wording, no 'the last 40' --------------------------
  if [ -s "$RENDER_M14" ]; then
    if grep -qF 'the last 40' "$RENDER_M14"; then
      fail_msg "AC B: forbidden string 'the last 40' still present in the M14 render"
    else
      ok "AC B: no 'the last 40' in the M14 render"
    fi
    if grep -qF 'raw_blob is the complete output of its own reproducible_command' "$RENDER_M14"; then
      ok "AC B: raw_blob-is-complete-output wording present"
    else
      fail_msg "AC B: missing raw_blob-is-complete-output wording"
    fi
    if grep -qF 'This rule replaces PROCEDURE step 5 (snippet plus 3 lines of context) for this claim.' "$RENDER_M14"; then
      ok "AC B: PROCEDURE-step-5-replacement wording present"
    else
      fail_msg "AC B: missing PROCEDURE-step-5-replacement wording"
    fi
    if grep -qF 'No raw_blob holds a line that is only ..., [...] or …, and no text added after the output.' "$RENDER_M14"; then
      ok "AC B: no-elision wording present"
    else
      fail_msg "AC B: missing no-elision wording"
    fi
    if grep -qF 'The filter output is a separate bundle.' "$RENDER_M14"; then
      ok "AC B: filter-output-is-a-separate-bundle wording present"
    else
      fail_msg "AC B: missing filter-output-is-a-separate-bundle wording"
    fi
    if grep -qF "(the claim's own command, unchanged" "$RENDER_M14" && grep -qF 'VERIFY exit=<n>' "$RENDER_M14"; then
      ok "AC B: verify bundle keeps reproducible_command equal to the claim's command and holds VERIFY exit="
    else
      fail_msg "AC B: missing the reproducible_command-equality / VERIFY exit= statement"
    fi
  fi

  # verify:null render (this IS the non-M14 render) has no verify-run
  # artifacts left over and the 5-call non-M14 budget text intact.
  if [ -s "$RENDER_NONM14" ]; then
    if grep -qF '{{#VERIFY_COMMAND}}' "$RENDER_NONM14" \
      || grep -qF '{{/VERIFY_COMMAND}}' "$RENDER_NONM14" \
      || grep -qF 'VERIFY exit=' "$RENDER_NONM14" \
      || grep -qF 'VERIFY RUN (M14 per-AC)' "$RENDER_NONM14" \
      || grep -qF 'RECIPE STEP' "$RENDER_NONM14"; then
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

  # ---- WP 3-02 F-20: cache section is read-only -------------------------
  # WP 1-16 AC A froze the whole non-M14 render against 38bc739. That freeze
  # included the investigator-written cache (mkdir, sha256sum, Bash-cat as a
  # tool_use_id). CDT-275 F-20 removed that write path, so the whole-file
  # cmp cannot hold. The verify-budget checks above still pin the M14
  # section. This check pins the new cache contract and fails if the old
  # write protocol returns.
  if [ -s "$RENDER_NONM14" ] \
    && grep -qF 'You MUST NOT mkdir, write, or run sha256sum.' "$RENDER_NONM14" \
    && grep -qF 'tool_use_id for those bytes.' "$RENDER_NONM14" \
    && ! grep -qF 'mkdir -p CACHE_DIR' "$RENDER_NONM14" \
    && ! grep -qF 'Bash may write ONLY under' "$RENDER_NONM14" \
    && ! grep -qF 'sha256sum | awk' "$RENDER_NONM14"; then
    ok "AC A: non-M14 cache section is read-only (no sha256sum, no mkdir)"
  else
    fail_msg "AC A: non-M14 cache section still tells the investigator to write"
  fi

  # ---- WP 1-16 M3 (TL review): C2 is pinned and executed, not just implied --
  C2_EXPECTED="$(cat <<'C2EOF'
    base="/tmp/cache"; d=$(mktemp -d "${base:-${TMPDIR:-/tmp}}/verify.XXXXXX") && cd "$(git rev-parse --show-toplevel)" && { TMPDIR="$d" bash skills/fx/test-a.sh >"$d.log" 2>&1; echo "VERIFY exit=$?" | tee -a "$d.log"; echo "VERIFY log=$d.log"; grep -E '^(FAIL|SKIP)|(FAIL|SKIP):|PASS=|FAIL=|[Pp]ass=|[Ff]ail=|^PASS:|[0-9]+ passed|[0-9]+ failed' "$d.log" || true; }
C2EOF
)"
  C2_LINE="$(grep -m1 '^    base="' "$RENDER_M14")"
  if [ "$C2_LINE" = "$C2_EXPECTED" ]; then
    ok "M3: exact C2 verify-run line present (pinned, not just implied)"
  else
    fail_msg "M3: C2 verify-run line differs from the pinned expectation"
    diff <(printf '%s\n' "$C2_EXPECTED") <(printf '%s\n' "$C2_LINE") || true
  fi

  if [ -n "$C2_LINE" ]; then
    # Substitute a REAL writable dir for CACHE_DIR and a deterministic stub
    # for VERIFY_COMMAND, then actually run it (catches M1: a clean stub
    # pass with no FAIL/SKIP/summary line must not make this call exit 1).
    C2_EXEC="${C2_LINE//\/tmp\/cache/$TMP}"
    C2_EXEC="${C2_EXEC//bash skills\/fx\/test-a.sh/true}"
    C2_OUT="$(eval "$C2_EXEC" 2>"$TMP/m3.err")"
    C2_RC=$?
    if [ "$C2_RC" -eq 0 ]; then
      ok "M3: the executed C2 call exits 0 on a clean stub pass with no summary line (M1)"
    else
      fail_msg "M3: the executed C2 call exited $C2_RC on a clean stub pass (M1 not fixed)"
      [ -s "$TMP/m3.err" ] && cat "$TMP/m3.err" >&2
    fi
    if printf '%s\n' "$C2_OUT" | grep -qF 'VERIFY exit=0'; then
      ok "M3: executed C2 call printed VERIFY exit=0"
    else
      fail_msg "M3: executed C2 call did not print VERIFY exit=0"
    fi
    C2_LOGPATH="$(printf '%s\n' "$C2_OUT" | sed -n 's/^VERIFY log=//p' | head -1)"
    if [ -n "$C2_LOGPATH" ] && [ -f "$C2_LOGPATH" ]; then
      ok "M3: the VERIFY log= path exists on disk"
    else
      fail_msg "M3: the VERIFY log= path is missing or does not exist ($C2_LOGPATH)"
    fi
    C2_DDIR="${C2_LOGPATH%.log}"
    case "$C2_LOGPATH" in
      "$C2_DDIR"/*)
        fail_msg "M3: the VERIFY log path is nested inside its own TMPDIR, not a sibling"
        ;;
      *)
        ok "M3: the VERIFY log path is a sibling of its TMPDIR, not nested inside it"
        ;;
    esac
  else
    fail_msg "M3: could not extract the C2 line to execute"
  fi

  # ---- WP 1-16 AC C: run the extracted C1/C3 lines on real fixtures -------
  FIX_DIR="$ROOT/skills/council/fixtures/m14-finder-recipe"
  SPEC_FIX="$FIX_DIR/spec-two-subsections.md"
  LOG_FIX="$FIX_DIR/verify-log.txt"
  if [ -s "$RENDER_M14" ] && [ -f "$SPEC_FIX" ] && [ -f "$LOG_FIX" ]; then
    C1_LINE="$(grep -m1 '^    awk -v n=' "$RENDER_M14")"
    C3_LINE="$(grep -m1 "^    grep -nE '<AC_LABEL>" "$RENDER_M14")"
    if [ -n "$C1_LINE" ] && [ -n "$C3_LINE" ]; then
      ok "AC C: extracted the C1 (awk) and C3 (grep -nE '<AC_LABEL>) lines from the M14 render"
    else
      fail_msg "AC C: could not extract the C1 or C3 line from the M14 render"
    fi

    if [ -n "$C1_LINE" ]; then
      # Second "- **A.**" bullet in the fixture spec is on line 12.
      N=12
      C1_CMD="${C1_LINE//<N>/$N}"
      C1_CMD="${C1_CMD//<PATH>/$SPEC_FIX}"
      ACTUAL_QUOTE="$(eval "$C1_CMD" 2>"$TMP/c1.err")"
      EXPECTED_QUOTE="$(cat <<QEOF
12: - **A.** Second subsection's AC A bullet is the true target: its own
13:   two lines of continuation text belong in the quote output and
14:   nothing from the next bullet.
15:   Verify: bash skills/fx/test-a2.sh
QEOF
)"
      if [ "$ACTUAL_QUOTE" = "$EXPECTED_QUOTE" ]; then
        ok "AC C: C1 quote command prints only the second AC A bullet + continuation"
      else
        fail_msg "AC C: C1 quote command output mismatch"
        diff <(printf '%s\n' "$EXPECTED_QUOTE") <(printf '%s\n' "$ACTUAL_QUOTE") || true
        [ -s "$TMP/c1.err" ] && cat "$TMP/c1.err" >&2
      fi
    fi

    if [ -n "$C3_LINE" ]; then
      LABEL_REGEX='AC A([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])A[0-9]*[:(]|(^|[^A-Za-z0-9_])A-[0-9]+'
      C3_CMD="${C3_LINE//<AC_LABEL>/$LABEL_REGEX}"
      C3_CMD="${C3_CMD//<LOG>/$LOG_FIX}"
      ACTUAL_FILTER="$(eval "$C3_CMD" 2>"$TMP/c3.err")"
      c3_ok=1
      for expect in \
        'AC A: quote command located source line 12' \
        'AC A: continuation captured through line 15' \
        'AC A: filter regex compiled against the log' \
        'FAIL: skills/fx/test-a2.sh failed at line 9' \
        'SKIP: skills/fx/test-a1.sh skipped (no docker)' \
        'PASS=3 FAIL=1' \
        'pass=65 fail=0' \
        'PASS: test-workflow-static.sh' \
        'VERIFY exit=1'
      do
        if ! printf '%s\n' "$ACTUAL_FILTER" | grep -qF -- "$expect"; then
          fail_msg "AC C: C3 filter output missing expected line: $expect"
          c3_ok=0
        fi
      done
      if printf '%s\n' "$ACTUAL_FILTER" | grep -qF 'noise line'; then
        fail_msg "AC C: C3 filter output leaked a noise line (filter did not filter)"
        c3_ok=0
      fi
      if [ "$c3_ok" -eq 1 ]; then
        ok "AC C: C3 filter command prints every AC/FAIL/SKIP/summary/exit line, no noise"
      fi
      [ -s "$TMP/c3.err" ] && cat "$TMP/c3.err" >&2
    fi
  else
    fail_msg "AC C: prerequisites missing (render or fixtures)"
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
  'bundle to read) MUST get confidence <=79'

if grep -qF 'is not enough by itself. A pass alone' "$JUDGE_MD"; then
  ok "judge.md: a pass alone is not enough"
else
  fail_msg "judge.md: missing the pass-alone-is-not-enough rule"
fi
judge_bite "pass-alone" \
  '       - A "VERIFY exit=0" line is not enough by itself. A pass alone' \
  'is not enough by itself. A pass alone'

# ---- WP 1-16 AC D: judge finder-recipe caps (C6), via one judge_cap helper --
# H3 / 10b gap 1 (TL review): the old check+bite blocks grepped judge.md as
# a whole for "MUST get confidence <=79" and each cap's own key phrase
# separately -- both stayed green even when every cap was rewritten to
# <=90, because the frozen WP 1-15 bullet (judge.md:113) also holds the
# literal "MUST get confidence <=79" substring. judge_cap extracts each
# cap's OWN bullet (joined across its wrapped lines) and pins the
# threshold ON THAT bullet specifically, with a rewrite-to-<=90 bite.
judge_cap_extract() {
  local first_line="$1" src="$2"
  awk -v first="$first_line" '
    $0==first {p=1}
    p {printf "%s ", $0}
    p && /\.$/ {exit}
  ' "$src" | sed 's/  */ /g'
}

judge_cap() {
  local label="$1" first_line="$2" key_phrase="$3"
  local extract
  extract="$(judge_cap_extract "$first_line" "$JUDGE_MD")"
  if [ -z "$extract" ]; then
    fail_msg "judge_cap $label: could not extract the cap bullet (anchor not found)"
    return
  fi
  if printf '%s' "$extract" | grep -qF -- "$key_phrase" \
    && printf '%s' "$extract" | grep -qF 'MUST get confidence <=79.'; then
    ok "judge.md: $label cap holds its key phrase and the pinned <=79 threshold"
  else
    fail_msg "judge.md: $label cap missing its key phrase or the pinned <=79 threshold"
  fi

  local bitten
  bitten="$(mktemp "$TMP/judge.cap-bite.XXXXXX")"
  awk -v first="$first_line" '
    $0==first {p=1}
    p {if (/\.$/) {p=0}; next}
    {print}
  ' "$JUDGE_MD" > "$bitten"
  if grep -qF -- "$key_phrase" "$bitten"; then
    fail_msg "bite: removing the $label cap left its key phrase present"
  else
    ok "bite: removing the $label cap fails its own grep"
  fi

  local weakened w_extract
  weakened="$(mktemp "$TMP/judge.cap-weak.XXXXXX")"
  awk -v first="$first_line" '
    $0==first {p=1}
    p {gsub(/<=79/, "<=90")}
    {print}
    p && /\.$/ {p=0}
  ' "$JUDGE_MD" > "$weakened"
  w_extract="$(judge_cap_extract "$first_line" "$weakened")"
  if printf '%s' "$w_extract" | grep -qF 'MUST get confidence <=79.'; then
    fail_msg "bite: weakening the $label cap to <=90 left the pinned <=79 check passing"
  else
    ok "bite: weakening the $label cap to <=90 fails the pinned-threshold check"
  fi
}

judge_cap "missing-quote" \
  '       - When no bundle quotes the AC bullet at the claim'"'"'s source_locator' \
  "no bundle quotes the AC bullet at the claim's source_locator"

judge_cap "unmatched-token" \
  '       - When a token of class backtick span, `path:N`, `Case N` or `AC X`' \
  'has no bundle, other than the Step 1 quote, with a line that holds it'

judge_cap "elision" \
  '       - When a raw_blob holds a line that is only ..., [...] or …, the' \
  'a raw_blob holds a line that is only ..., [...] or …'

if grep -qF 'is advisory evidence' "$JUDGE_MD" \
  && grep -qF 'carries no cap' "$JUDGE_MD"; then
  ok "judge.md: a numbered sub-clause is advisory evidence and carries no cap (D11)"
else
  fail_msg "judge.md: missing the numbered-sub-clause advisory-only note (D11)"
fi
judge_bite "advisory-sub-clause" \
  '       A numbered sub-clause named in that quote is advisory evidence' \
  'is advisory evidence'

if grep -qF 'These caps can only lower a confidence; they do not change SPEC-033 M14(b).' "$JUDGE_MD"; then
  ok "judge.md: finder-recipe caps closing sentence present"
else
  fail_msg "judge.md: missing the finder-recipe caps closing sentence"
fi
judge_bite "finder-cap-closing-sentence" \
  '       These caps can only lower a confidence; they do not change SPEC-033 M14(b).' \
  'These caps can only lower a confidence'

# ---- WP 1-16 AC D: five WP 1-15 bullets byte-identical to 38bc739 ---------
extract_verify_evidence() {
  awk '/VERIFY EVIDENCE \(M14 per-AC/{p=1} p{print} p && /^[[:space:]]*evidence\.$/{exit}' "$1"
}
GOLDEN_JUDGE="$TMP/judge.38bc739.md"
if git show 38bc739:skills/council/prompts/judge.md > "$GOLDEN_JUDGE" 2>"$TMP/git-show.err"; then
  GOLD_EXTRACT="$(extract_verify_evidence "$GOLDEN_JUDGE")"
  NEW_EXTRACT="$(extract_verify_evidence "$JUDGE_MD")"
  if [ "$GOLD_EXTRACT" = "$NEW_EXTRACT" ]; then
    ok "judge.md: the five WP 1-15 verify-evidence bullets are byte-identical to 38bc739"
  else
    fail_msg "judge.md: the five WP 1-15 verify-evidence bullets drifted from 38bc739"
    diff <(printf '%s\n' "$GOLD_EXTRACT") <(printf '%s\n' "$NEW_EXTRACT") || true
  fi
else
  fail_msg "could not git show 38bc739:skills/council/prompts/judge.md: $(cat "$TMP/git-show.err")"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: test-verify-prompts.sh"
  exit 0
else
  echo "FAIL: test-verify-prompts.sh"
  exit 1
fi
