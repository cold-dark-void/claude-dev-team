#!/usr/bin/env bash
#
# skills/council/test-forward-claim.sh — CDT-589-C4 (SPEC-013 § CDT-589-C4
# AC3/AC4/AC5/AC6/AC7/AC8, Test 27). The Forward claim fixture matrix:
# engine-side, hermetic, deterministic, never LLM-live. Every guard case feeds
# a committed plan / evidence / judge triple to `engine.sh finalize` and
# asserts all three observable outputs: the report text, the finalize-meta
# sidecar JSON, and the stdout counts.
#
# Layers covered:
#   AC7(a-e) the engine guard: `[forward] ` + scope==plan +
#            CONTRADICTED/FABRICATED -> UNVERIFIED at min(conf, 79) with a
#            `forward-claim-guard:` Audit Trail line
#   AC5      the guard keys on prefix + scope + taxonomy ONLY: a native
#            UNVERIFIED >= 80 on a tagged claim is NOT clamped
#   AC4/AC8  report_labels.label_verdict prefix-tolerant text matching, the
#            `[forward] ` report heading, and struck_count reflecting the guard
#   AC6      scope exclusion: scope==claim (M14 ship-gate), scope==diff, and
#            finding[] runs never gain the guard
#   AC3      composeRawArtifacts (workflow.js) is the identity for an untagged
#            claim, appends forward-claim-addendum.txt for a tagged one, and is
#            a no-op outside plan scope; the addendum is absent from
#            investigator.md and from every flavor file
#   AC4      planClaimLine accepts prefixed claim text
#   AC9      no new phase, spawn, or claim-budget consumer; Phase 4 and the
#            investigator prompt stay claim-blind
#
# Fixtures: skills/council/fixtures/forward-claim/. The AC7(c) goldens in
# fixtures/forward-claim/goldens/ were generated ONCE from the BASE engine at
# commit c02c915 (pre-T1..T3) — `git archive c02c915 | tar -x`, run in a
# private temp git repo — never from the live engine. The report golden holds
# <TIMESTAMP> where the render clock lands (frontmatter created_at + the
# Timestamp row); the sidecar carries no clock value, so it is byte-exact.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); every engine.sh call
# runs with cwd inside its own temp git repo, so .claude/council/ writes land
# there, never under the real MROOT.
#
# CDT-589-C4 per-AC run receipts (CDT-595 pattern, tests/lib/ac-receipt.sh):
# every check prints its `OK:` prose line AND a `ok AC<n>: <slug>` receipt
# (failures add `FAIL: AC<n>: <slug>: <detail>` on stderr) once a `set_ac`
# block is active. `--ac AC<n>` runs the whole fixture matrix (the engine
# runs are the setup) and prints only that AC's receipts plus the subset
# aggregate; the last stdout line of any run is `PASS=<n> FAIL=<m>` and the
# count of `^ok ` lines equals n. Each engine finalize is a direct run
# exhibit: a `CMD:` line with the fixture paths and a `CMD exit=` code.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

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

ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/forward-claim"
ADDENDUM="$ROOT/skills/council/forward-claim-addendum.txt"
INVESTIGATOR="$ROOT/skills/council/prompts/investigator.md"
PHASE4BRIEF="$ROOT/skills/council/prompts/phase4-brief.md"
WORKFLOW_JS="$ROOT/skills/council/workflow.js"
REPORT_LABELS="$ROOT/skills/council/report_labels.py"
FINALIZE="$ROOT/skills/council/engine-finalize.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forward-claim.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"

# slugify <label> — receipt slug from a prose label ([a-z0-9-] only).
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9-]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}
# The prose line keeps the pre-receipt output contract; the receipt is the
# CDT-589-C4 addition (tests/lib/ac-receipt.sh grammar).
ok() {
  echo "OK: $1"
  if [ -n "${CUR_AC:-}" ] && want_ac; then
    PASS=$(( PASS + 1 ))
    printf 'ok %s: %s\n' "$CUR_AC" "$(slugify "$1")"
  fi
}
bad() {
  echo "FAIL: $1"
  if [ -n "${CUR_AC:-}" ] && want_ac; then
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL: %s: %s: %s\n' "$CUR_AC" "$(slugify "$1")" failed >&2
  fi
}
ok_eq() {  # ok_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2 | want: $3)"; fi
}
has() {  # has <label> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
hasnt() {  # hasnt <label> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then bad "$1 (present: $2)"; else ok "$1"; fi
}

# Claim texts used across the plan-scope fixtures (byte-exact).
FWD_CLAIM='[forward] Step 3 adds flag --fwd-demo to skills/council/engine.sh'
BARE_CLAIM='Step 3 adds flag --fwd-demo to skills/council/engine.sh'
GUARD_PREFIX='forward-claim-guard:'

# run_finalize <name> <plan-path> <evidence-path> <judge-path>
# Sets REPORT / META / OUT / RC for the assertion block that follows. The
# engine run is echoed as a CMD: / CMD exit= pair — a direct run exhibit of
# the engine-side fixture (never LLM-live).
run_finalize() {
  local name="$1" plan="$2" evidence="$3" judge="$4"
  REPORT="$TMP/$name.md"
  META="$REPORT.finalize-meta.json"
  OUT="$TMP/$name.stdout"
  rm -f "$REPORT" "$META"
  printf 'CMD: bash skills/council/engine.sh finalize --plan-file %s --evidence-file %s --judge-output %s\n' \
    "${plan#"$ROOT"/}" "${evidence#"$ROOT"/}" "${judge#"$ROOT"/}"
  ( cd "$REPO" && bash "$ENGINE" finalize \
      --plan-file "$plan" \
      --evidence-file "$evidence" \
      --judge-output "$judge" \
      --report-out "$REPORT" ) >"$OUT" 2>&1
  RC=$?
  printf 'CMD exit=%s\n' "$RC"
  if [ "$RC" -eq 0 ]; then ok "$name: finalize exit 0"; else
    bad "$name: finalize exit $RC"
    sed 's/^/    /' "$OUT"
  fi
}

# audit_section <report> — the rendered "## Audit Trail — Struck Lines" body.
audit_section() {
  sed -n '/^## Audit Trail — Struck Lines/,/^## /p' "$1"
}

# exhibit_audit <report> — echo the guard line verbatim from the Audit Trail:
# a direct run exhibit holding the forward-claim-guard: token and the struck
# verdict/confidence facts (never starts with "ok ", so it cannot shift the
# `^ok ` count).
exhibit_audit() {
  printf 'exhibit: audit trail: %s\n' \
    "$(audit_section "$1" | grep -F -- "$GUARD_PREFIX" | head -1 | sed 's/^[[:space:]]*//')"
}

# halt_count <meta> [claim-prefix] — the Step 6c halt predicate over the
# sidecar (skills/orchestrate/steps/06-design.md): unstruck CONTRADICTED or
# FABRICATED with confidence >= 80, or unstruck UNVERIFIED with confidence
# >= 80. With a prefix argument, only verdicts whose claim carries it.
halt_count() {
  local meta="$1" pref="${2:-}"
  jq -r --arg pref "$pref" '
    [ (.unstruck_verdicts // [])[]
      | select($pref == "" or (.claim | startswith($pref)))
      | select(((.verdict == "CONTRADICTED" or .verdict == "FABRICATED")
                and .confidence >= 80)
               or (.verdict == "UNVERIFIED" and .confidence >= 80))
    ] | length' "$meta"
}

# =============================================================================
# 1. AC7(a) tagged plan claim refuted on absence -> guard fires, caps at 79
# =============================================================================
set_ac AC7
run_finalize a-tagged "$FIX/plan-tagged.json" "$FIX/evidence-absence.json" "$FIX/judge-contradicted.json"
set_ac AC8
has "1 heading shows the [forward] prefix" "### Claim c0: $FWD_CLAIM" "$REPORT"
set_ac AC7
has "1 verdict is UNVERIFIED at 79/100" "**UNVERIFIED** — confidence: 79/100" "$REPORT"
hasnt "1 no CONTRADICTED badge survives" "**CONTRADICTED**" "$REPORT"
if audit_section "$REPORT" | grep -qF -- \
   "$GUARD_PREFIX struck CONTRADICTED on [forward] claim c0 (pre-implementation bytes inadmissible in plan scope)"; then
  ok "1 the guard line is named in the Audit Trail (AC8)"
else
  bad "1 the guard line is named in the Audit Trail (AC8)"
fi
exhibit_audit "$REPORT"
ok_eq "1 summary table counts no CONTRADICTED" \
  "$(grep -F '| CONTRADICTED |' "$REPORT")" "| CONTRADICTED | 0 |"
set_ac AC8
ok_eq "1 sidecar struck_count == 1 (guard line counted, AC8)" "$(jq -r .struck_count "$META")" "1"
printf 'exhibit: finalize-meta.json struck_count and the struck lines reflect the guard\n'
printf 'exhibit: %s\n' "$(grep -m1 '^## Audit Trail' "$REPORT")"
set_ac AC7
ok_eq "1 sidecar verdict is UNVERIFIED" \
  "$(jq -r '.unstruck_verdicts[0].verdict' "$META")" "UNVERIFIED"
ok_eq "1 sidecar confidence capped at 79" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "79"
ok_eq "1 sidecar keeps the tagged claim text" \
  "$(jq -r '.unstruck_verdicts[0].claim' "$META")" "$FWD_CLAIM"
ok_eq "1 sidecar verdict_counts.CONTRADICTED == 0" \
  "$(jq -r '.verdict_counts.CONTRADICTED' "$META")" "0"
set_ac AC9
ok_eq "1 the row is rewritten, not dropped (AC9: no claim-budget loss)" \
  "$(jq -r .unstruck_verdict_count "$META")" "1"
set_ac AC7
ok_eq "1 sidecar max_verdict_confidence == 79" \
  "$(jq -r .max_verdict_confidence "$META")" "79"
ok_eq "1 stdout counts UNVERIFIED 1 / CONTRADICTED 0" \
  "$(grep -F 'PARTIALLY_VERIFIED:' "$OUT" | sed 's/.*UNVERIFIED/UNVERIFIED/')" \
  "UNVERIFIED: 1  CONTRADICTED: 0  FABRICATED: 0"
set_ac AC8
ok_eq "1 stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"
set_ac AC5
ok_eq "1 Step 6c halt list is empty for the tagged claim" "$(halt_count "$META")" "0"
printf 'exhibit: the rewritten verdict is UNVERIFIED at confidence <= 79 — it cannot trip the Step 6c halt list\n'

# =============================================================================
# 2. AC7(b) identical claim text WITHOUT the prefix -> CONTRADICTED survives
# =============================================================================
set_ac AC7
run_finalize b-untagged "$FIX/plan-untagged.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-contradicted-untagged.json"
has "2 heading is untagged" "### Claim c0: $BARE_CLAIM" "$REPORT"
has "2 verdict survives as CONTRADICTED at 92/100" "**CONTRADICTED** — confidence: 92/100" "$REPORT"
hasnt "2 no guard line" "$GUARD_PREFIX" "$REPORT"
ok_eq "2 Audit Trail says nothing was struck" \
  "$(audit_section "$REPORT" | grep -F 'No lines struck.' | head -1)" "No lines struck."
ok_eq "2 sidecar struck_count == 0" "$(jq -r .struck_count "$META")" "0"
ok_eq "2 sidecar verdict survives as CONTRADICTED" \
  "$(jq -r '.unstruck_verdicts[0].verdict' "$META")" "CONTRADICTED"
ok_eq "2 sidecar confidence untouched" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "92"
ok_eq "2 stdout counts CONTRADICTED 1" \
  "$(grep -F 'PARTIALLY_VERIFIED:' "$OUT" | sed 's/.*UNVERIFIED/UNVERIFIED/')" \
  "UNVERIFIED: 0  CONTRADICTED: 1  FABRICATED: 0"
ok_eq "2 stdout Struck lines == 0" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "0"
ok_eq "2 the untagged claim is fully refutable (halt list == 1, AC2)" \
  "$(halt_count "$META")" "1"
printf 'exhibit: the untagged claim stays fully refutable: CONTRADICTED at 92 survives and the Step 6c halt list holds it\n'

# =============================================================================
# 3. AC7(c) same text as an M14 ship-gate claim -> unchanged vs the BASE engine
# =============================================================================
set_ac AC7
run_finalize c-m14-control "$FIX/plan-m14-control.json" "$FIX/evidence-m14-control.json" \
  "$FIX/judge-m14-control.json"
hasnt "3 no guard line in the M14 control report" "$GUARD_PREFIX" "$REPORT"
has "3 M14 heading keeps the [AC-A] prefix" "### Claim c0: [AC-A] $BARE_CLAIM" "$REPORT"
has "3 M14 verdict survives as CONTRADICTED" "**CONTRADICTED** — confidence: 92/100" "$REPORT"
ok_eq "3 M14 sidecar struck_count == 0" "$(jq -r .struck_count "$META")" "0"
ok_eq "3 the M14 split keys survive (ac_source)" \
  "$(jq -r .ac_source "$META")" "specs/core/SPEC-FIX.md"
ok_eq "3 the M14 split keys survive (ac_claims)" \
  "$(jq -c .ac_claims "$META")" '[{"claim_id":"c0","ac_id":"A"}]'
# Byte-equality vs the pre-change engine. The report holds the run clock; the
# sidecar holds none.
NORM="$TMP/c-m14-control.normalized.md"
sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TIMESTAMP>/g' \
  "$REPORT" > "$NORM"
if cmp -s "$NORM" "$FIX/goldens/m14-control.report.golden.md"; then
  ok "3 report byte-equal to the BASE-engine golden (c02c915)"
else
  bad "3 report differs from the BASE-engine golden"
  diff "$FIX/goldens/m14-control.report.golden.md" "$NORM" | head -20
fi
if cmp -s "$META" "$FIX/goldens/m14-control.finalize-meta.golden.json"; then
  ok "3 sidecar byte-equal to the BASE-engine golden (c02c915)"
else
  bad "3 sidecar differs from the BASE-engine golden"
  diff "$FIX/goldens/m14-control.finalize-meta.golden.json" "$META" | head -20
fi
ok_eq "3 stdout Struck lines == 0" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "0"
printf 'exhibit: the M14 ship-gate control is unchanged: struck_count=0, no forward-claim-guard: line, CONTRADICTED 92 stands\n'

# =============================================================================
# 4. AC7(d) tagged claim refuted on an UNSCHEDULED file -> guard still fires.
#    Documented over-inclusive backstop: the guard keys on prefix + scope +
#    taxonomy only. The judge rule is the admissible-refutation layer.
# =============================================================================
set_ac AC7
run_finalize d-unscheduled "$FIX/plan-tagged-unscheduled.json" "$FIX/evidence-unscheduled.json" \
  "$FIX/judge-contradicted-unscheduled.json"
has "4 guard fires on an unscheduled-file refutation" "$GUARD_PREFIX" "$REPORT"
set_ac AC8
if audit_section "$REPORT" | grep -qF -- "$GUARD_PREFIX struck CONTRADICTED on [forward] claim c0"; then
  ok "4 the Audit Trail names the discarded refutation (c0)"
else
  bad "4 the Audit Trail names the discarded refutation (c0)"
fi
exhibit_audit "$REPORT"
ok_eq "4 sidecar struck_count == 1" "$(jq -r .struck_count "$META")" "1"
set_ac AC7
has "4 verdict rewritten to UNVERIFIED at 79/100" "**UNVERIFIED** — confidence: 79/100" "$REPORT"
ok_eq "4 sidecar verdict is UNVERIFIED" \
  "$(jq -r '.unstruck_verdicts[0].verdict' "$META")" "UNVERIFIED"
ok_eq "4 sidecar confidence capped from 91 to 79" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "79"
ok_eq "4 stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"
ok_eq "4 Step 6c halt list is empty" "$(halt_count "$META")" "0"

# =============================================================================
# 5. AC7(e) XYZ-434-shaped replay: two tagged claims at 88 / 92, plus one
#    untagged factual claim that MUST stay refutable
# =============================================================================
set_ac AC7
run_finalize e-xyz-434 "$FIX/plan-xyz-434.json" "$FIX/evidence-xyz-434.json" "$FIX/judge-xyz-434.json"
ok_eq "5 two guard lines (one per tagged claim)" \
  "$(grep -cF -- "$GUARD_PREFIX" "$REPORT")" "2"
has "5 guard names c0" "$GUARD_PREFIX struck CONTRADICTED on [forward] claim c0" "$REPORT"
has "5 guard names c1" "$GUARD_PREFIX struck CONTRADICTED on [forward] claim c1" "$REPORT"
has "5 c0 heading shows the tag" \
  '### Claim c0: [forward] Task T3 adds the --fwd-demo flag to skills/council/engine.sh' "$REPORT"
has "5 c1 heading shows the tag" \
  '### Claim c1: [forward] Task T4 lands skills/council/test-forward-claim.sh' "$REPORT"
set_ac AC8
ok_eq "5 sidecar struck_count == 2 (AC8)" "$(jq -r .struck_count "$META")" "2"
set_ac AC7
ok_eq "5 no tagged claim leaves as CONTRADICTED/FABRICATED" \
  "$(jq -r '[.unstruck_verdicts[] | select(.claim | startswith("[forward] "))
             | select(.verdict=="CONTRADICTED" or .verdict=="FABRICATED")] | length' "$META")" "0"
ok_eq "5 no tagged claim leaves as UNVERIFIED >= 80" \
  "$(jq -r '[.unstruck_verdicts[] | select(.claim | startswith("[forward] "))
             | select(.confidence >= 80)] | length' "$META")" "0"
ok_eq "5 the Step 6c halt list is empty for the tagged claims" \
  "$(halt_count "$META" "[forward] ")" "0"
ok_eq "5 the untagged c2 keeps CONTRADICTED at 91 (guard is targeted)" \
  "$(jq -r '.unstruck_verdicts[] | select(.claim | startswith("tools/deploy.sh"))
             | "\(.verdict):\(.confidence)"' "$META")" "CONTRADICTED:91"
ok_eq "5 stdout counts UNVERIFIED 2 / CONTRADICTED 1" \
  "$(grep -F 'PARTIALLY_VERIFIED:' "$OUT" | sed 's/.*UNVERIFIED/UNVERIFIED/')" \
  "UNVERIFIED: 2  CONTRADICTED: 1  FABRICATED: 0"
ok_eq "5 stdout Struck lines == 2" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "2"
exhibit_audit "$REPORT"
printf 'exhibit: the XYZ-434 replay leaves no blocking verdict on tagged claims: no CONTRADICTED/FABRICATED, no UNVERIFIED >= 80\n'

# =============================================================================
# 6. AC5 FABRICATED is rewritten too
# =============================================================================
set_ac AC5
run_finalize f-fabricated "$FIX/plan-tagged.json" "$FIX/evidence-absence.json" "$FIX/judge-fabricated.json"
has "6 the guard names the FABRICATED verdict" \
  "$GUARD_PREFIX struck FABRICATED on [forward] claim c0" "$REPORT"
has "6 FABRICATED rewritten to UNVERIFIED at 79/100" "**UNVERIFIED** — confidence: 79/100" "$REPORT"
hasnt "6 no FABRICATED badge survives" "**FABRICATED**" "$REPORT"
ok_eq "6 sidecar verdict is UNVERIFIED" \
  "$(jq -r '.unstruck_verdicts[0].verdict' "$META")" "UNVERIFIED"
ok_eq "6 sidecar caps 97 to 79" "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "79"
ok_eq "6 sidecar verdict_counts.FABRICATED == 0" "$(jq -r '.verdict_counts.FABRICATED' "$META")" "0"
ok_eq "6 sidecar struck_count == 1" "$(jq -r .struck_count "$META")" "1"
ok_eq "6 stdout counts FABRICATED 0" \
  "$(grep -F 'PARTIALLY_VERIFIED:' "$OUT" | sed 's/.*UNVERIFIED/UNVERIFIED/')" \
  "UNVERIFIED: 1  CONTRADICTED: 0  FABRICATED: 0"
ok_eq "6 stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"
exhibit_audit "$REPORT"
printf 'exhibit: scope==plan + [forward] prefix + the CONTRADICTED/FABRICATED taxonomy is the whole key: FABRICATED is rewritten to UNVERIFIED at 79\n'

# =============================================================================
# 7. AC5 the predicate stays narrow: a NATIVE UNVERIFIED at 95 on a tagged
#    claim is not a CONTRADICTED/FABRICATED, so the guard does not touch it
# =============================================================================
set_ac AC5
run_finalize g-unverified-high "$FIX/plan-tagged.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-unverified-high.json"
hasnt "7 a native UNVERIFIED gains no guard line" "$GUARD_PREFIX" "$REPORT"
has "7 a native UNVERIFIED keeps 95/100" "**UNVERIFIED** — confidence: 95/100" "$REPORT"
ok_eq "7 sidecar struck_count == 0" "$(jq -r .struck_count "$META")" "0"
ok_eq "7 sidecar confidence not capped" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "95"
ok_eq "7 a native UNVERIFIED >= 80 still blocks Step 6c" "$(halt_count "$META")" "1"
ok_eq "7 stdout Struck lines == 0" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "0"
printf 'exhibit: a native UNVERIFIED 95 on a tagged claim is untouched — the guard covers only CONTRADICTED/FABRICATED, min(conf, 79) is not a clamp-to-79\n'

# =============================================================================
# 8. AC4/AC8 prefix-tolerant text-equality: the verdict carries the UNTAGGED
#    text and no claim_id, over a two-claim plan (so the sole-claim fallback
#    cannot rescue it). The claim record wins: the heading shows the tag, and
#    the guard fires through that match.
# =============================================================================
set_ac AC4
run_finalize h-text-match "$FIX/plan-tagged-two-claims.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-contradicted-bare-text.json"
has "8 an untagged verdict text matches the tagged claim record" \
  "### Claim c0: $FWD_CLAIM" "$REPORT"
hasnt "8 the sibling claim is not relabeled" "### Claim unmatched:" "$REPORT"
printf 'exhibit: matching order: claim_id first, then text-equality with [forward] optional on either side — heading resolved from the tagged record:\n'
printf 'exhibit: heading: %s\n' "$(grep -m1 '^### Claim c0:' "$REPORT")"
set_ac AC5
has "8 the guard fires through the text match" "$GUARD_PREFIX" "$REPORT"
set_ac AC4
ok_eq "8 sidecar struck_count == 1" "$(jq -r .struck_count "$META")" "1"
ok_eq "8 sidecar verdict capped to UNVERIFIED 79" \
  "$(jq -r '.unstruck_verdicts[0] | "\(.verdict):\(.confidence)"' "$META")" "UNVERIFIED:79"
# SPEC-013 Phase 6 "Finalize-meta sidecar": unstruck_verdicts stays a plain
# copy of the judge verdicts, so it keeps the raw (untagged) text the judge
# emitted, while the report heading shows the resolved tagged record.
ok_eq "8 sidecar keeps the judge's raw untagged claim text" \
  "$(jq -r '.unstruck_verdicts[0].claim' "$META")" "$BARE_CLAIM"
ok_eq "8 stdout counts no CONTRADICTED" \
  "$(grep -F 'PARTIALLY_VERIFIED:' "$OUT" | sed 's/.*UNVERIFIED/UNVERIFIED/')" \
  "UNVERIFIED: 1  CONTRADICTED: 0  FABRICATED: 0"
ok_eq "8 stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"
ok_eq "8 Step 6c halt list is empty" "$(halt_count "$META")" "0"

# 8b. The mirror case: the verdict carries the tag, the plan record does not.
#     Matching is prefix-optional on EITHER side, the record's text wins for
#     the heading, and the guard fires on the verdict's own tag.
set_ac AC4
run_finalize h2-tagged-verdict-text "$FIX/plan-untagged.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-tagged-text.json"
has "8b heading shows the untagged claim record" "### Claim c0: $BARE_CLAIM" "$REPORT"
has "8b the guard fires on the verdict's own tag" "$GUARD_PREFIX" "$REPORT"
ok_eq "8b sidecar verdict capped to UNVERIFIED 79" \
  "$(jq -r '.unstruck_verdicts[0] | "\(.verdict):\(.confidence)"' "$META")" "UNVERIFIED:79"
ok_eq "8b stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"

# =============================================================================
# 9. AC4 claim_id-first matching is unchanged: an empty verdict claim still
#    routes through the tagged claim record
# =============================================================================
set_ac AC4
run_finalize i-claim-id "$FIX/plan-tagged.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-contradicted-bare-id.json"
has "9 the claim_id match resolves the tagged text" "### Claim c0: $FWD_CLAIM" "$REPORT"
has "9 the guard fires on the claim_id match" "$GUARD_PREFIX" "$REPORT"
ok_eq "9 sidecar verdict capped to UNVERIFIED 79" \
  "$(jq -r '.unstruck_verdicts[0] | "\(.verdict):\(.confidence)"' "$META")" "UNVERIFIED:79"
ok_eq "9 sidecar struck_count == 1" "$(jq -r .struck_count "$META")" "1"
ok_eq "9 stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"

# =============================================================================
# 10. AC6 scope exclusion: the same tagged text at scope=claim gets no guard
#     (the single-claim ship-gate / task-gate shape)
# =============================================================================
set_ac AC6
run_finalize j-scope-claim "$FIX/plan-claim-scope-tagged.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-contradicted.json"
hasnt "10 no guard line at scope=claim" "$GUARD_PREFIX" "$REPORT"
has "10 CONTRADICTED survives at scope=claim" "**CONTRADICTED** — confidence: 92/100" "$REPORT"
ok_eq "10 sidecar struck_count == 0" "$(jq -r .struck_count "$META")" "0"
ok_eq "10 sidecar confidence not capped" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "92"
ok_eq "10 stdout Struck lines == 0" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "0"
printf 'exhibit: scope=claim (the M14 ship-gate / Step 8-9 task-gate shape): no guard, CONTRADICTED 92 survives\n'

# 11. AC6 scope exclusion at scope=diff (the same tagged claim record).
set_ac AC6
sed 's/"scope": "claim"/"scope": "diff"/' "$FIX/plan-claim-scope-tagged.json" \
  > "$TMP/plan-scope-diff.json"
run_finalize k-scope-diff "$TMP/plan-scope-diff.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-contradicted.json"
hasnt "11 no guard line at scope=diff" "$GUARD_PREFIX" "$REPORT"
has "11 CONTRADICTED survives at scope=diff" "**CONTRADICTED** — confidence: 92/100" "$REPORT"
ok_eq "11 sidecar struck_count == 0" "$(jq -r .struck_count "$META")" "0"
ok_eq "11 stdout Struck lines == 0" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "0"

# =============================================================================
# 12. AC6 finding[] shape at scope=plan: the guard no-ops, no crash
# =============================================================================
set_ac AC6
run_finalize l-findings "$FIX/plan-tagged-findings.json" "$FIX/evidence-absence.json" \
  "$FIX/judge-findings.json"
hasnt "12 a finding[] run gains no guard line" "$GUARD_PREFIX" "$REPORT"
ok_eq "12 finding[] sidecar struck_count == 0" "$(jq -r .struck_count "$META")" "0"
ok_eq "12 finding[] sidecar verdict_counts stays null" \
  "$(jq -r '.verdict_counts | type' "$META")" "null"
ok_eq "12 finding[] sidecar unstruck_verdicts stays null" \
  "$(jq -r '.unstruck_verdicts | type' "$META")" "null"
ok_eq "12 finding[] sidecar warning count" "$(jq -r '.finding_counts.warning' "$META")" "1"
ok_eq "12 stdout severity counts" "$(grep -F 'critical: ' "$OUT")" \
  "critical: 0  warning: 1  nitpick: 0"
ok_eq "12 stdout Struck lines == 0" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "0"
printf 'exhibit: finding[] shape at scope=plan: the guard no-ops (struck_count=0), no crash\n'

# =============================================================================
# 13. AC3 seam: the addendum file is the one home; investigator.md stays clean
# =============================================================================
set_ac AC3
ADD_BODY="$(cat "$ADDENDUM")"
ok_eq "13 the addendum body is the canonical sentence" "$ADD_BODY" \
  "FORWARD CLAIM RULE: this claim is tagged [forward]. Absence of the described code in current bytes is not evidence. Do not treat that absence as contradiction. Ground bundles in plan, spec, task-graph, and AC-coverage citations."
hasnt "13 investigator.md does not carry the addendum" "FORWARD CLAIM RULE" "$INVESTIGATOR"
hasnt "13 investigator.md does not name the tag" "[forward] " "$INVESTIGATOR"
FLAV_HITS="$(grep -rlF 'FORWARD CLAIM RULE' "$ROOT/skills/council/flavors/" 2>/dev/null | wc -l | tr -d ' ')"
ok_eq "13 no flavor file carries the addendum" "$FLAV_HITS" "0"
ok_eq "13 no new flavor file for the tag" \
  "$(ls "$ROOT/skills/council/flavors/" | grep -c 'forward' | tr -d ' ')" "0"
printf 'exhibit: the addendum home is skills/council/forward-claim-addendum.txt; investigator.md and every flavor stay clean (no new preset)\n'

# =============================================================================
# 14. AC3 composeRawArtifacts + AC4 planClaimLine (workflow.js)
# =============================================================================
# set_ac_for_14 <js-label> — route each numbered sub-check to the AC it
# evidences: 14.1-14.6 prefix keying helpers (AC1), 14.7-14.11 the compose
# seam (AC3), 14.12 non-plan scopes (AC6), 14.13-14.16 the locator and the
# verbatim fixture record (AC4).
set_ac_for_14() {
  case "$1" in
    '14.1 '*|'14.2 '*|'14.3 '*|'14.4 '*|'14.5 '*|'14.6 '*) set_ac AC1 ;;
    '14.7 '*|'14.8 '*|'14.9 '*|'14.10 '*|'14.11 '*) set_ac AC3 ;;
    '14.12 '*) set_ac AC6 ;;
    '14.13 '*|'14.14 '*|'14.15 '*|'14.16 '*) set_ac AC4 ;;
  esac
}
if ( require_cmd node ); then
  JS_OUT="$TMP/workflow-js.txt"
  if COUNCIL_WF="$WORKFLOW_JS" COUNCIL_ADD="$ADDENDUM" COUNCIL_PLAN="$FIX/plan-tagged.json" \
     node --input-type=module >"$JS_OUT" 2>&1 <<'JS'
import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const wf = await import(pathToFileURL(process.env.COUNCIL_WF).href)
const addendum = readFileSync(process.env.COUNCIL_ADD, 'utf8').trimEnd()
const tagged = '[forward] Step 3 adds flag --fwd-demo to skills/council/engine.sh'
const bare = 'Step 3 adds flag --fwd-demo to skills/council/engine.sh'
const raw = 'line one of the artifacts\nline two\n'
let bad = 0
const say = (label, good, extra) => {
  console.log((good ? 'OK: ' : 'FAIL: ') + label + (good ? '' : ' ' + JSON.stringify(extra)))
  if (!good) bad++
}

say('14.1 isForwardClaim accepts the 10-char prefix', wf.isForwardClaim(tagged) === true)
say('14.2 isForwardClaim rejects the untagged text', wf.isForwardClaim(bare) === false)
say('14.3 isForwardClaim rejects [forward] with no trailing space',
  wf.isForwardClaim('[forward]no-space') === false)
say('14.4 isForwardClaim rejects a non-string', wf.isForwardClaim(undefined) === false)
say('14.5 stripForwardPrefix drops the tag', wf.stripForwardPrefix(tagged) === bare)
say('14.6 stripForwardPrefix keeps an untagged string', wf.stripForwardPrefix(bare) === bare)

// AC3: the untagged plan-scope artifacts value is the identity.
say('14.7 composeRawArtifacts is the identity for an untagged claim',
  wf.composeRawArtifacts(raw, bare, 'plan') === raw,
  wf.composeRawArtifacts(raw, bare, 'plan'))
say('14.8 composeRawArtifacts identity for an empty artifacts value',
  wf.composeRawArtifacts('', bare, 'plan') === '')
// AC3: the tagged plan-scope artifacts value is that value plus the addendum.
const composed = wf.composeRawArtifacts(raw, tagged, 'plan')
say('14.9 composeRawArtifacts appends the addendum on its own line',
  composed === raw + '\n' + addendum, composed)
say('14.10 composeRawArtifacts keeps every artifact byte', composed.startsWith(raw))
say('14.11 composeRawArtifacts with no artifacts emits the addendum alone',
  wf.composeRawArtifacts('', tagged, 'plan') === addendum)
// AC6: every non-plan scope is the identity, tag present or not.
for (const scope of ['claim', 'diff', 'session', 'from-retro', undefined]) {
  say(`14.12 composeRawArtifacts is the identity at scope=${scope}`,
    wf.composeRawArtifacts(raw, tagged, scope) === raw,
    wf.composeRawArtifacts(raw, tagged, scope))
}
// AC4: the locator strips the tag before the line search.
const lines = []
for (let i = 1; i <= 60; i++) lines.push('filler line ' + i)
lines[52] = '- ' + bare
const input = lines.join('\n') + '\n'
say('14.13 planClaimLine resolves a tagged claim to the unprefixed plan line',
  wf.planClaimLine(input, tagged) === 53, wf.planClaimLine(input, tagged))
say('14.14 planClaimLine still resolves the untagged claim',
  wf.planClaimLine(input, bare) === 53)
say('14.15 planClaimLine returns 0 for an absent tagged claim',
  wf.planClaimLine(input, '[forward] nothing in this plan') === 0)
// AC4: the tag rides verbatim into Phase 2.5 CLAIM_TEXT / Phase 5 claims.
const claimText = JSON.parse(readFileSync(process.env.COUNCIL_PLAN, 'utf8')).claims[0].claim
say('14.16 the fixture claim record keeps the prefix verbatim', claimText === tagged, claimText)

process.exit(bad === 0 ? 0 : 1)
JS
  then
    while IFS= read -r line; do
      case "$line" in
        OK:*)   set_ac_for_14 "${line#OK: }"; ok "${line#OK: }" ;;
        FAIL:*) set_ac_for_14 "${line#FAIL: }"; bad "${line#FAIL: }" ;;
      esac
    done < "$JS_OUT"
    printf 'exhibit: the workflow.js seam functions are isForwardClaim / stripForwardPrefix / composeRawArtifacts / planClaimLine\n'
  else
    bad "14 the workflow.js compose / locator checks failed"
    sed 's/^/    /' "$JS_OUT"
  fi
else
  echo "SKIP: 14 workflow.js checks — missing command: node"
fi

# =============================================================================
# 15. AC4 report_labels.label_verdict: `[forward] ` optional on either side,
#     claim_id-first matching unchanged
# =============================================================================
set_ac AC4
if ( require_cmd python3 ); then
  PY_OUT="$TMP/report-labels.txt"
  if COUNCIL_REPORT_LABELS="$REPORT_LABELS" python3 - >"$PY_OUT" 2>&1 <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location(
    "report_labels", os.environ["COUNCIL_REPORT_LABELS"])
rl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rl)

TAG = "[forward] "
tagged = TAG + "Step 3 adds flag --fwd-demo"
bare = "Step 3 adds flag --fwd-demo"
claims = [{"claim_id": "c0", "claim": tagged},
          {"claim_id": "c1", "claim": "an untagged sibling"}]
bad = 0


def say(label, good, extra=""):
    global bad
    print(("OK: " if good else "FAIL: ") + label + ("" if good else " " + repr(extra)))
    if not good:
        bad += 1


say("15.1 strip_forward_prefix drops the tag", rl.strip_forward_prefix(tagged) == bare)
say("15.2 strip_forward_prefix keeps an untagged string", rl.strip_forward_prefix(bare) == bare)
say("15.3 strip_forward_prefix maps a non-string to ''", rl.strip_forward_prefix(None) == "")
say("15.4 claim_id match wins and returns the tagged record text",
    rl.label_verdict({"claim_id": "c0", "claim": "ignored"}, claims) == ("c0", tagged))
say("15.5 exact text equality matches first",
    rl.label_verdict({"claim": tagged}, claims) == ("c0", tagged))
say("15.6 an untagged verdict text matches the tagged record (prefix optional)",
    rl.label_verdict({"claim": bare}, claims) == ("c0", tagged))
say("15.7 a tagged verdict text matches an untagged record",
    rl.label_verdict({"claim": TAG + "an untagged sibling"}, claims)
    == ("c1", "an untagged sibling"))
say("15.8 no match falls through to unmatched",
    rl.label_verdict({"claim": "no such claim"}, claims) == ("unmatched", "no such claim"))
say("15.9 a claim_id of '?' is treated as absent (WP 1-15 F5)",
    rl.label_verdict({"claim_id": "?", "claim": bare}, claims) == ("c0", tagged))
say("15.10 the sole-claim rule is unchanged",
    rl.label_verdict({"claim": "anything"}, [{"claim_id": "", "claim": tagged}])
    == ("c0", tagged))
sys.exit(0 if bad == 0 else 1)
PY
  then
    while IFS= read -r line; do
      case "$line" in
        OK:*)   ok "${line#OK: }" ;;
        FAIL:*) bad "${line#FAIL: }" ;;
      esac
    done < "$PY_OUT"
  else
    bad "15 the report_labels.py prefix-tolerant checks failed"
    sed 's/^/    /' "$PY_OUT"
  fi
else
  echo "SKIP: 15 report_labels.py checks — missing command: python3"
fi

# =============================================================================
# 16. AC7(a) in the live Step 6c shape: plan scope with NO plan.claims[].
#     Phase 1 puts the tagged claim in the evidence file's extracted_claims, so
#     the claim list, the heading, and the guard all resolve through that path.
# =============================================================================
set_ac AC7
run_finalize p-extracted "$FIX/plan-tagged-no-claims.json" "$FIX/evidence-tagged-extracted.json" \
  "$FIX/judge-contradicted.json"
has "16 Extracted Claims lists the tagged claim id + text" \
  "1. **recommendation** — c0: $FWD_CLAIM (source: plans/sample.md:Task Map:12)" "$REPORT"
has "16 the heading shows the tag through the evidence claim list" \
  "### Claim c0: $FWD_CLAIM" "$REPORT"
has "16 the guard fires on the evidence-file claim list" "$GUARD_PREFIX" "$REPORT"
has "16 the verdict is capped to UNVERIFIED at 79/100" "**UNVERIFIED** — confidence: 79/100" "$REPORT"
set_ac AC8
ok_eq "16 sidecar struck_count == 1" "$(jq -r .struck_count "$META")" "1"
set_ac AC7
ok_eq "16 sidecar verdict is UNVERIFIED" \
  "$(jq -r '.unstruck_verdicts[0].verdict' "$META")" "UNVERIFIED"
ok_eq "16 stdout counts no CONTRADICTED" \
  "$(grep -F 'PARTIALLY_VERIFIED:' "$OUT" | sed 's/.*UNVERIFIED/UNVERIFIED/')" \
  "UNVERIFIED: 1  CONTRADICTED: 0  FABRICATED: 0"
ok_eq "16 stdout Struck lines == 1" "$(grep -F 'Struck lines:' "$OUT" | tr -dc '0-9')" "1"
ok_eq "16 Step 6c halt list is empty" "$(halt_count "$META")" "0"
exhibit_audit "$REPORT"
printf 'exhibit: the guard fires through the evidence-file claim list too; the rewritten row stays in the verdict counts (no claim-budget loss)\n'

# =============================================================================
# 17. AC5/AC9/AC10 static shape of the guard and the claim-blind prompts
# =============================================================================
set_ac AC5
GUARD_BLOCK="$(awk '/# --- Forward claim guard/,/^# --- Format verdicts/' "$FINALIZE")"
ok_eq "17 the guard has exactly one prefix constant" \
  "$(printf '%s\n' "$GUARD_BLOCK" | grep -cF 'FORWARD_CLAIM_PREFIX = ')" "1"
ok_eq "17 the prefix constant is the 10-char tag" \
  "$(printf '%s\n' "$GUARD_BLOCK" | grep -F 'FORWARD_CLAIM_PREFIX = ' | sed -E 's/.*= (.*)/\1/')" \
  '"[forward] "'
ok_eq "17 the guard cap is 79" \
  "$(printf '%s\n' "$GUARD_BLOCK" | grep -F 'FORWARD_CLAIM_CAP = ' | sed -E 's/.*= (.*)/\1/')" "79"
case "$GUARD_BLOCK" in
  *'output_shape == "verdict[]" and plan.get("scope") == "plan"'*)
    ok "17 the guard keys on verdict[] + scope==plan only" ;;
  *) bad "17 the guard keys on verdict[] + scope==plan only" ;;
esac
case "$GUARD_BLOCK" in
  *'"CONTRADICTED", "FABRICATED"'*) ok "17 the guard covers exactly the two blocking terms" ;;
  *) bad "17 the guard covers exactly the two blocking terms" ;;
esac
printf 'exhibit: %s\n' "$(printf '%s\n' "$GUARD_BLOCK" | grep -F 'FORWARD_CLAIM_CAP' | head -1 | sed 's/^[[:space:]]*//')"
printf 'exhibit: the guard keys on scope==plan + the [forward] prefix + the CONTRADICTED/FABRICATED taxonomy only:\n'
printf 'exhibit: %s\n' "$(printf '%s\n' "$GUARD_BLOCK" | grep -F 'output_shape == "verdict[]"' | head -1 | sed 's/^[[:space:]]*//')"
if printf '%s\n' "$GUARD_BLOCK" | grep -qiE 'task_graph|task-map|taskgraph'; then
  bad "17 the guard does not re-derive task-graph membership (AC10)"
else
  ok "17 the guard does not re-derive task-graph membership (AC10)"
fi
if printf '%s\n' "$GUARD_BLOCK" | grep -qE 'for [a-z_]+ in .*claims'; then
  bad "17 no classifier infers the tag from claim wording (AC1)"
else
  ok "17 no classifier infers the tag from claim wording (AC1)"
fi
if grep -qF 'basis is pre-implementation bytes is inadmissible' \
  "$ROOT/skills/council/prompts/judge.md"; then
  ok "17 the judge rule names pre-implementation bytes inadmissible (AC5)"
else
  bad "17 the judge rule names pre-implementation bytes inadmissible (AC5)"
fi
printf 'exhibit: judge.md: a refutation of a [forward] claim whose sole basis is pre-implementation bytes is inadmissible — the verdict comes from plan-internal evidence\n'
set_ac AC9
hasnt "17 investigator.md stays Forward-claim-blind (AC9)" "forward" "$INVESTIGATOR"
hasnt "17 phase4-brief.md stays Forward-claim-blind (AC9)" "forward" "$PHASE4BRIEF"
# No classifier script for the tag anywhere in the engine.
set_ac AC10
CLS="$(grep -rlE '\[\[ .*forward.* ==|forward-classifier' "$ROOT/skills/council/" \
  --include='*.sh' 2>/dev/null | grep -v test- | wc -l | tr -d ' ')"
ok_eq "17 no bash classifier script keys the tag" "$CLS" "0"
set_ac AC9
ok_eq "17 no Phase 8 exists in the council protocol (AC9)" \
  "$(grep -c 'Phase 8' "$ROOT/skills/council/SKILL.md")" "0"

# =============================================================================
# 18. Determinism + the floor/cap interaction. The guard is a pure function of
#     (prefix, scope, verdict, confidence): same inputs, same bytes, twice.
#     A float confidence floors before it caps.
# =============================================================================
set_ac AC7
run_finalize r-determinism-a "$FIX/plan-xyz-434.json" "$FIX/evidence-xyz-434.json" "$FIX/judge-xyz-434.json"
cp "$REPORT" "$TMP/det-a.md"; cp "$META" "$TMP/det-a.json"; cp "$OUT" "$TMP/det-a.out"
run_finalize r-determinism-b "$FIX/plan-xyz-434.json" "$FIX/evidence-xyz-434.json" "$FIX/judge-xyz-434.json"
if cmp -s "$META" "$TMP/det-a.json"; then
  ok "18 sidecar is byte-identical across two runs (deterministic)"
else
  bad "18 sidecar differs across two runs"
  diff "$TMP/det-a.json" "$META" | head -10
fi
if cmp -s <(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/' "$TMP/det-a.md") \
          <(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/' "$REPORT"); then
  ok "18 report is byte-identical across two runs (deterministic)"
else
  bad "18 report differs across two runs"
fi
# The only stdout difference between the two runs is the --report-out name.
norm_stdout() { sed -E "s#$TMP/r-determinism-[ab]\.md#<REPORT>#g" "$1"; }
ok_eq "18 stdout is byte-identical across two runs (deterministic)" \
  "$(cmp -s <(norm_stdout "$TMP/det-a.out") <(norm_stdout "$OUT") && echo same)" "same"
printf 'exhibit: the guard is deterministic: same fixture triple, byte-identical sidecar and report twice\n'

set_ac AC5
sed 's/"confidence": 92,/"confidence": 92.7,/' "$FIX/judge-contradicted.json" > "$TMP/judge-float.json"
run_finalize s-float-conf "$FIX/plan-tagged.json" "$FIX/evidence-absence.json" "$TMP/judge-float.json"
ok_eq "18 a float confidence caps to 79, not 92" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "79"
ok_eq "18 the guard names the original verdict on a float row" \
  "$(grep -cF -- "$GUARD_PREFIX struck CONTRADICTED on [forward] claim c0" "$REPORT")" "1"
sed 's/"confidence": 42,/"confidence": 42,/' "$FIX/judge-contradicted.json" \
  | sed 's/"confidence": 92,/"confidence": 42,/' > "$TMP/judge-low.json"
run_finalize t-low-conf "$FIX/plan-tagged.json" "$FIX/evidence-absence.json" "$TMP/judge-low.json"
ok_eq "18 a confidence under the cap is left alone (min, not a clamp-to-79)" \
  "$(jq -r '.unstruck_verdicts[0].confidence' "$META")" "42"
has "18 the guard still fires under the cap" "$GUARD_PREFIX" "$REPORT"
has "18 the verdict renders as UNVERIFIED at 42/100" "**UNVERIFIED** — confidence: 42/100" "$REPORT"

# Guard: never wrote into the real worktree .claude/council
if [ -f "$ROOT/.claude/council/index.json" ] \
   && grep -q 'fwd-tagged\|fwd-untagged\|fwd-xyz-434\|fwd-m14-control\|fwd-scope-claim\|fwd-tagged-findings' \
        "$ROOT/.claude/council/index.json" 2>/dev/null; then
  bad "guard: polluted $ROOT/.claude/council/index.json"
else
  ok "guard: no live-repo index pollution"
fi

echo
ac_finish
