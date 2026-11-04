#!/usr/bin/env bash
# skills/autopilot/classify-test.sh — SPEC-041 AC3–AC7 ship-gate classifier.
#
# Extracts classify.md's one executable fence (tests/lib/fence.sh fence_nth)
# and drives it with simulated in-session stage-0/stage-1 answers against
# hermetic fixture repos (the LLM judgments arrive as substituted inputs; the
# fence carries every mechanical rule: validation, veto, card, output). Plus
# static prose bites on classify.md / ship-pipeline.md / SKILL.md ordering.
#
# Matrix (SPEC-041 ## Test rows):
#   - no-code-change (stage 0): zero tag/card side effects, veto never reached
#   - patch / minor decided bumps: explicit CLASSIFY_BUMP, zero cards written
#   - would-be major -> halt (non-enum for stage 1)
#   - failure modes (empty, non-enum, malformed, absent) -> halt + exactly one
#     card per halt
#   - veto matrix: patch+Surface -> minor; minor+Surface -> minor stands;
#     halt+Surface -> halt stands (never rescued); nested path is no Surface
#   - base ref = resolved push target (stale-ref variant keeps patch)
#   - append-card/read-cards round-trip: schema_version 1 shape, rationale
#     evidence (raw response + veto), halt-card fields
#   - zero tag side effects on skip/halt paths; stage-0 junk is machinery 64
#   - AC3: the fence decides with the release skill surface absent (R9)
#   - AC4/M20: CLASSIFY_JOURNAL conditions map into the closed M20 enum (R10)
#   - AC7: empty diff vs baseline (no code commits at the gate) -> zero tags
#     (R11)
#   - AC3 no-spawn: the fence decides under a PATH with no agent CLI (R19)
#   - AC8 veto-call: the fence's veto runs skills/release/detect-surfaces.sh
#     through the plugin-dir.sh Tier-0 force root (R20)
#
# CLAUDE_PLUGIN_ROOT=$ROOT (plugin-dir.sh Tier 0 force) resolves the shared
# helpers from any cwd. Writes only under a hermetic TMPDIR.
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLASSIFY="${CLASSIFY:-$ROOT/skills/autopilot/classify.md}"
SHIP_PIPELINE="${SHIP_PIPELINE:-$ROOT/skills/autopilot/ship-pipeline.md}"
SKILL="${SKILL:-$ROOT/skills/autopilot/SKILL.md}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/text.sh
. "$ROOT/tests/lib/text.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
unset AUTOPILOT_ITERATION_CAP AUTOPILOT_WALLCLOCK_CAP AUTOPILOT_BUDGET_META

pass=0
fail=0
pass_line() { echo "PASS: $1"; pass=$((pass + 1)); }
fail_line() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

TICKET="CDT-TEST-1"
RUN_ID="run-classify-1"
LEDGER_REL=".claude/autopilot/$TICKET.jsonl"

FENCE=$(fence_nth "$CLASSIFY" "## 4. The one executable fence" 1)
if [ -n "$FENCE" ]; then
  pass_line "structural: classify.md §4 holds one executable fence"
else
  echo "HARNESS ERROR: no fence under classify.md §4 — aborting suite" >&2
  exit 2
fi

# ---- fixtures ---------------------------------------------------------------

# build_fixture <mode> — mode: plain | surface | nested | nodiff.
#   base commit A (README only) -> stale commit S on main (already contains
#   commands/new-surface.md) -> feat branch from A: skills/code.sh plus, per
#   mode, the Surface variant. nodiff: no commit past base — the item has no
#   code commits at the gate (empty diff vs baseline, AC7). Resolved push
#   target = origin/main -> A; the stale ref origin/stale -> S bites "base
#   ref = resolved push target".
build_fixture() {
  local mode="$1" dir base
  dir=$(mktemp -d "$TMPDIR/classify-fx.XXXXXX")
  git -C "$dir" init -q -b main 2>/dev/null || { git -C "$dir" init -q; git -C "$dir" checkout -q -b main; }
  git -C "$dir" config user.email t@t.invalid
  git -C "$dir" config user.name t
  echo base > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm base
  base=$(git -C "$dir" rev-parse HEAD)
  mkdir -p "$dir/commands"
  printf 'stale surface\n' > "$dir/commands/new-surface.md"
  git -C "$dir" add commands
  git -C "$dir" commit -qm stale
  git -C "$dir" update-ref refs/remotes/origin/stale "$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" checkout -q -b feat "$base"
  if [ "$mode" != "nodiff" ]; then
    mkdir -p "$dir/skills"
    printf '#!/usr/bin/env bash\ntrue\n' > "$dir/skills/code.sh"
    git -C "$dir" add skills
    git -C "$dir" commit -qm "code change"
  fi
  case "$mode" in
    surface)
      mkdir -p "$dir/commands"
      printf -- '---\nname: new-surface\ndescription: x\n---\nbody\n' > "$dir/commands/new-surface.md"
      git -C "$dir" add commands
      git -C "$dir" commit -qm "new surface"
      ;;
    nested)
      mkdir -p "$dir/commands/sub"
      printf 'nested\n' > "$dir/commands/sub/nested.md"
      git -C "$dir" add commands
      git -C "$dir" commit -qm "nested"
      ;;
  esac
  git -C "$dir" update-ref refs/remotes/origin/main "$base"
  printf '%s' "$dir"
}

# subst_fence — substitute every §2 input; fence text arrives on stdin.
subst_fence() {
  sed \
    -e "s|<baseline-ref>|$1|g" \
    -e "s|<stage0-code-bearing>|$2|g" \
    -e "s|<stage1-answer>|$3|g" \
    -e "s|<stage0-evidence>|$4|g" \
    -e "s|<stage1-reason>|$5|g" \
    -e "s|<workflow>|orchestrate|g" \
    -e "s|<ticket_id>|$TICKET|g" \
    -e "s|<run_id>|$RUN_ID|g" \
    -e "s|<iteration>|3|g" \
    -e "s|<run_start_epoch>|1700000000|g"
}

# run_classify <fx> <baseline-ref> <stage0> <stage1> <s0-evidence> <s1-reason> [EXTRA=env]
# Runs the substituted fence in a fresh bash at the fixture cwd (fence_exec);
# sets RUN_RC and globals RUN_OUT / RUN_ERR. The optional 7th argument is one
# extra NAME=value for the fence environment (the AC3 no-spawn PATH).
run_classify() {
  local fx="$1" ref="$2" s0="$3" s1="$4" s0ev="$5" s1r="$6" pfx sub
  # CLASSIFY_PLUGIN_ROOT overrides the plugin root the fence resolves against
  # (the no-release stub of R9); defaults to the real root.
  local croot="${CLASSIFY_PLUGIN_ROOT:-$ROOT}"
  sub=$(printf '%s' "$FENCE" | subst_fence "$ref" "$s0" "$s1" "$s0ev" "$s1r")
  if [ -z "$sub" ]; then
    echo "HARNESS ERROR: substitution emptied the fence — aborting suite" >&2
    exit 2
  fi
  pfx=$(mktemp "$TMPDIR/classify-run.XXXXXX")
  if [ $# -ge 7 ]; then
    fence_exec "$pfx" "$fx" "$sub" "CLAUDE_PLUGIN_ROOT=$croot" "$7"
  else
    fence_exec "$pfx" "$fx" "$sub" "CLAUDE_PLUGIN_ROOT=$croot"
  fi
  RUN_OUT=$(cat "$pfx.out" 2>/dev/null)
  RUN_ERR=$(cat "$pfx.err" 2>/dev/null)
  rm -f "$pfx" "$pfx.sh" "$pfx.out" "$pfx.err"
}

ledger_path() { printf '%s/%s' "$1" "$LEDGER_REL"; }
ledger_exists() { [ -f "$(ledger_path "$1")" ]; }
card_count() {  # card_count <fx> — ledger length, 0 when absent
  if ledger_exists "$1"; then
    ( cd "$1" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null | jq 'length' )
  else
    printf '0\n'
  fi
}
tag_count() { git -C "$1" tag | wc -l | tr -d ' '; }

# ---- R1: stage 0 No — zero side effects, veto never reached -----------------

FX=$(build_fixture plain)
mkdir -p "$FX/commands"
printf -- '---\nname: untracked-surface\ndescription: u\n---\nu\n' > "$FX/commands/untracked-surface.md"
run_classify "$FX" "origin/main" "no" "patch" "docs only" "n/a"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=no-code$'; then
  pass_line "stage-0 no: decision no-code, rc 0 (untracked Surface present but veto never reached)"
else
  fail_line "stage-0 no: expected no-code rc 0 — got rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -2)"
fi
if printf '%s' "$RUN_OUT" | grep -q 'CLASSIFY_BUMP\|CLASSIFY_CARD'; then
  fail_line "stage-0 no: no bump/card output expected"
else
  pass_line "stage-0 no: no bump/card output"
fi
if [ "$(card_count "$FX")" = "0" ] && [ "$(tag_count "$FX")" = "0" ]; then
  pass_line "stage-0 no: zero cards, zero tags (AC7)"
else
  fail_line "stage-0 no: side effects found — cards=$(card_count "$FX") tags=$(tag_count "$FX")"
fi
run_classify "$FX" "origin/main" "yes" "patch" "docs only" "n/a"
if printf '%s' "$RUN_OUT" | grep -q 'untracked-surface.md'; then
  pass_line "stage-0 yes: the same untracked Surface reaches the veto (stage-0 exit is the only guard)"
else
  fail_line "stage-0 yes: veto did not see the untracked Surface"
fi
rm -rf "$FX"

# ---- R2: decided patch / minor — explicit bump, zero cards ------------------

FX=$(build_fixture plain)
run_classify "$FX" "origin/main" "yes" "patch" "one helper script" "code-bearing, no new Surface"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=decided$' \
  && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=patch$'; then
  pass_line "decided patch: explicit CLASSIFY_BUMP=patch"
else
  fail_line "decided patch: unexpected — rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -3)"
fi
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_VETO=none$' \
  && ! printf '%s' "$RUN_OUT" | grep -q 'CLASSIFY_CARD'; then
  pass_line "decided patch: veto none, no card printed"
else
  fail_line "decided patch: expected VETO=none and no CLASSIFY_CARD"
fi
if [ "$(card_count "$FX")" = "0" ]; then
  pass_line "decided patch: classify writes zero cards (evidence rides the Stage-1 envelope)"
else
  fail_line "decided patch: classify wrote cards"
fi
run_classify "$FX" "origin/main" "yes" "minor" "code-bearing" "minor-class"
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=minor$' && [ "$(card_count "$FX")" = "0" ]; then
  pass_line "decided minor: CLASSIFY_BUMP=minor, zero cards"
else
  fail_line "decided minor: unexpected — out=$(printf '%s' "$RUN_OUT" | head -3)"
fi
rm -rf "$FX"

# ---- R3: would-be major -> halt (non-enum for stage 1) ----------------------

FX=$(build_fixture plain)
run_classify "$FX" "origin/main" "yes" "major" "breaking schema change" "would-be major"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=halt$' \
  && [ "$(card_count "$FX")" = "1" ]; then
  pass_line "would-be major: halt outcome, exactly one card (never emitted as a bump)"
else
  fail_line "would-be major: rc=$RUN_RC cards=$(card_count "$FX")"
fi
HALT_CARD=$( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null )
assert_card() {  # assert_card <json> <jq-filter> <label>
  if printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; then
    pass_line "$3"
  else
    fail_line "$3 (filter: $2)"
  fi
}
assert_card "$HALT_CARD" '.[0].schema_version == 1' "round-trip: schema_version 1 (M13 frozen envelope)"
assert_card "$HALT_CARD" '.[0].type == "autopilot_decision"' "round-trip: type autopilot_decision"
assert_card "$HALT_CARD" '.[0].gate == "ship-choice" and .[0].decision == "halt"' "round-trip: ship-choice halt card (M10)"
assert_card "$HALT_CARD" '.[0].bump == null' "round-trip: bump null on halt (M10)"
assert_card "$HALT_CARD" '.[0].blocking_condition == 7' "round-trip: BC7 ordinal on a cannot-answer halt"
assert_card "$HALT_CARD" '.[0].confidence == 0 and .[0].decided_by == "auto"' "round-trip: confidence 0, decided_by auto"
if printf '%s' "$HALT_CARD" | jq -r '.[0].rationale' | grep -q 'raw="major"'; then
  pass_line "round-trip: rationale carries the redacted raw response"
else
  fail_line "round-trip: rationale missing raw response"
fi
if [ "$(tag_count "$FX")" = "0" ]; then
  pass_line "halt path: zero tags (AC7)"
else
  fail_line "halt path: tag side effect found"
fi
rm -rf "$FX"

# ---- R4: failure modes — empty / malformed / non-enum / junk ----------------

FX=$(build_fixture plain)
CARD_TOTAL=0
ALL_OK=1
# expect_halt <label> <stage1-answer> — halt rc 0, exactly one new card.
expect_halt() {
  run_classify "$FX" "origin/main" "yes" "$2" "evidence" "reason"
  CARD_TOTAL=$((CARD_TOTAL + 1))
  if [ "$RUN_RC" -ne 0 ] || ! printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=halt$'; then
    ALL_OK=0
    fail_line "failure mode $1: expected halt rc 0 — rc=$RUN_RC"
  fi
  if [ "$(card_count "$FX")" != "$CARD_TOTAL" ]; then
    ALL_OK=0
    fail_line "failure mode $1: expected exactly $CARD_TOTAL cards after run"
  fi
}
expect_halt empty ""
expect_halt malformed "patch minor"
expect_halt non-enum "Patch"
expect_halt junk "ship"
if [ "$ALL_OK" = "1" ]; then
  pass_line "failure modes: empty/malformed/non-enum/junk all fail-closed halt with exactly one card each (M7)"
fi
run_classify "$FX" "origin/main" "yes" "" "evidence" "reason"
if printf '%s' "$( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null )" \
  | jq -r '.[-1].rationale' | grep -q 'raw=""'; then
  pass_line "absent response: halt card records the empty raw response"
else
  fail_line "absent response: rationale missing raw=\"\""
fi
run_classify "$FX" "origin/main" "maybe" "patch" "evidence" "reason"
if [ "$RUN_RC" -eq 64 ] && ! printf '%s' "$RUN_OUT" | grep -q 'CLASSIFY_DECISION' \
  && [ "$(card_count "$FX")" = "5" ]; then
  pass_line "stage-0 junk input: machinery exit 64, no decision line, no card (§3b discipline)"
else
  fail_line "stage-0 junk input: rc=$RUN_RC cards=$(card_count "$FX")"
fi
rm -rf "$FX"

# ---- R5: veto matrix (Surface present vs resolved push target) --------------

FX=$(build_fixture surface)
run_classify "$FX" "origin/main" "yes" "patch" "helper + surface" "patch-class LLM answer"
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=minor$' \
  && printf '%s' "$RUN_OUT" | grep -q 'raised to minor' \
  && printf '%s' "$RUN_OUT" | grep -q 'commands/new-surface.md'; then
  pass_line "veto: LLM patch + new Surface -> minor (raised), Surface path recorded"
else
  fail_line "veto: patch not raised — out=$(printf '%s' "$RUN_OUT" | head -4)"
fi
run_classify "$FX" "origin/main" "yes" "minor" "helper + surface" "minor-class LLM answer"
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=minor$' \
  && printf '%s' "$RUN_OUT" | grep -q 'minor stands'; then
  pass_line "veto: LLM minor + new Surface -> minor stands (no demotion)"
else
  fail_line "veto: minor did not stand — out=$(printf '%s' "$RUN_OUT" | head -4)"
fi
run_classify "$FX" "origin/main" "yes" "halt" "helper + surface" "needs a human"
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=halt$' && [ "$(card_count "$FX")" = "1" ] \
  && ( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null ) \
       | jq -r '.[0].rationale' | grep -q 'halt stands — new Surface recorded: commands/new-surface.md'; then
  pass_line "veto: LLM halt + new Surface -> halt stands (never rescued), veto in card rationale"
else
  fail_line "veto: halt was rescued or veto missing from rationale"
fi
rm -rf "$FX"

# ---- R6: base ref = resolved push target (stale ref keeps patch) ------------

FX=$(build_fixture surface)
run_classify "$FX" "origin/stale" "yes" "patch" "helper" "patch vs stale ref"
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=patch$'; then
  pass_line "base ref bite: diff vs the stale ref (Surface already there) keeps patch"
else
  fail_line "base ref bite: stale-ref run did not keep patch"
fi
rm -rf "$FX"

# ---- R7: nested command path is not a Surface -------------------------------

FX=$(build_fixture nested)
run_classify "$FX" "origin/main" "yes" "patch" "nested file" "patch-class"
if printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=patch$' \
  && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_VETO=none$'; then
  pass_line "nested commands/sub/*.md is not a new Surface (patch stands)"
else
  fail_line "nested path wrongly vetoed"
fi
rm -rf "$FX"

# ---- R9: AC3 — the fence never invokes /release (release skill absent) ------

# Stub plugin root: carries the helpers the fence resolves (plugin-dir.sh +
# detect-surfaces.sh) but NO release skill surface — no skills/release/SKILL.md
# and no commands/. If the fence reached for /release it could not resolve it.
STUB_NR=$(mktemp -d "$TMPDIR/classify-norelease.XXXXXX")
mkdir -p "$STUB_NR/skills/release"
cp "$ROOT/skills/release/detect-surfaces.sh" "$STUB_NR/skills/release/detect-surfaces.sh"
cat > "$STUB_NR/skills/plugin-dir.sh" <<'PDH_STUB'
#!/usr/bin/env bash
# stub: `file <rel>` resolves against the stub root (this script's dir/..).
[ "$1" = "file" ] || exit 1
_root=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$_root/$2" ] && { printf '%s\n' "$_root/$2"; exit 0; }
exit 1
PDH_STUB
if [ ! -f "$STUB_NR/skills/release/SKILL.md" ] && [ ! -e "$STUB_NR/commands" ]; then
  pass_line "no-release stub: the release skill surface is absent (no SKILL.md, no commands/)"
else
  fail_line "no-release stub: fixture unexpectedly carries a release surface"
fi
FX=$(build_fixture plain)
CLASSIFY_PLUGIN_ROOT="$STUB_NR" run_classify "$FX" "origin/main" "yes" "patch" \
  "one helper script" "no release skill present"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=decided$' \
  && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=patch$'; then
  pass_line "AC3 no-release: classify decided patch rc 0 with /release absent — the fence never invokes it"
else
  fail_line "AC3 no-release: rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -3)"
fi
unset CLASSIFY_PLUGIN_ROOT
rm -rf "$FX" "$STUB_NR"

# ---- R10: AC4/M20 — the journal condition maps into the closed enum ---------

in_m20() { # in_m20 <token> — member of the closed M20 outcome enum (SPEC-040)?
  local t
  for t in closed shipped pr-stopped deferred asked-answered; do
    [ "$t" = "$1" ] && return 0
  done
  return 1
}
journal_outcome() { # journal_outcome <CLASSIFY_JOURNAL line> -> JO_OUT / JO_RC
  local jargs
  jargs=${1#CLASSIFY_JOURNAL=}
  JO_OUT=$(cd "$TMPDIR" && bash "$ROOT/skills/backlog/sweep.sh" $jargs 2>/dev/null)
  JO_RC=$?
}

FX=$(build_fixture plain)
run_classify "$FX" "origin/main" "yes" "major" "breaking" "would-be major"
JLINE=$(printf '%s' "$RUN_OUT" | grep '^CLASSIFY_JOURNAL=' | head -1)
if [ -n "$JLINE" ]; then
  pass_line "M20 journal: the halt path prints a CLASSIFY_JOURNAL line for the caller (sweep 9e)"
else
  fail_line "M20 journal: no CLASSIFY_JOURNAL line on the halt path"
fi
journal_outcome "$JLINE"
if [ "$JO_RC" -eq 0 ] && [ "$JO_OUT" = "pr-stopped" ] && in_m20 "$JO_OUT"; then
  pass_line "M20 journal: halt condition auto-classify-halt maps to outcome pr-stopped (member of the closed M20 enum)"
else
  fail_line "M20 journal: walk-outcome rc=$JO_RC out=$JO_OUT"
fi
if in_m20 "auto-classify-halt"; then
  fail_line "M20 journal: the condition name leaked into the outcome enum"
else
  pass_line "M20 journal: auto-classify-halt is a halt name, not an outcome value (enum stays closed)"
fi
run_classify "$FX" "origin/main" "no" "patch" "docs only" "n/a"
JLINE=$(printf '%s' "$RUN_OUT" | grep '^CLASSIFY_JOURNAL=' | head -1)
journal_outcome "$JLINE"
if [ "$JO_RC" -eq 0 ] && [ "$JO_OUT" = "pr-stopped" ] && in_m20 "$JO_OUT"; then
  pass_line "M20 journal: stage-0 condition auto-stage-0-no-code maps to outcome pr-stopped (member of the closed M20 enum)"
else
  fail_line "M20 journal: stage-0 mapping rc=$JO_RC out=$JO_OUT (line=$JLINE)"
fi
rm -rf "$FX"

# ---- R11: AC7 — no code commits at the gate (empty diff) -> zero tags -------

FX=$(build_fixture nodiff)
if git -C "$FX" diff --quiet origin/main && [ -z "$(git -C "$FX" status --porcelain)" ]; then
  pass_line "AC7 no-code-commits fixture: empty diff vs baseline (origin/main), clean tree"
else
  fail_line "AC7 no-code-commits fixture: diff vs baseline is not empty"
fi
run_classify "$FX" "origin/main" "no" "patch" "nothing code-bearing" "n/a"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=no-code$' \
  && [ "$(tag_count "$FX")" = "0" ] && [ "$(card_count "$FX")" = "0" ]; then
  pass_line "AC7 no-code-commits: item with no code commits at the gate -> zero tags, zero cards"
else
  fail_line "AC7 no-code-commits: rc=$RUN_RC tags=$(tag_count "$FX") cards=$(card_count "$FX")"
fi
run_classify "$FX" "origin/main" "yes" "patch" "empty diff" "n/a"
if [ "$(tag_count "$FX")" = "0" ] && [ "$(card_count "$FX")" = "0" ]; then
  pass_line "AC7 no-code-commits: even a decided answer on an empty diff creates zero tags (tags only at the caller's fold)"
else
  fail_line "AC7 no-code-commits: decided-on-empty-diff tagged — tags=$(tag_count "$FX")"
fi
rm -rf "$FX"

# ---- R12: AC3 — the baseline is the RESOLVED push target (N3a) --------------
# Attempt-2 strike: the fixture baseline was a literal 'origin/main'. Here the
# fixture repo carries a refs/remotes/origin/HEAD symbolic ref and the
# classification is driven against the RESOLVED target (git symbolic-ref),
# exhibited in run output.

FX=$(build_fixture surface)
git -C "$FX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
RESOLVED=$(git -C "$FX" symbolic-ref refs/remotes/origin/HEAD)
if [ "$RESOLVED" = "refs/remotes/origin/main" ]; then
  pass_line "AC3 resolved push target: fixture baseline resolves via git symbolic-ref refs/remotes/origin/HEAD -> $RESOLVED (not a literal)"
else
  fail_line "AC3 resolved push target: symbolic-ref resolved to '$RESOLVED'"
fi
run_classify "$FX" "$RESOLVED" "yes" "patch" "helper + surface" "patch-class on the resolved push target"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=minor$' \
  && printf '%s' "$RUN_OUT" | grep -q 'commands/new-surface.md'; then
  pass_line "AC3 resolved push target: in-session classification ran against $RESOLVED — the veto resolved the Surface through it (patch raised to minor)"
else
  fail_line "AC3 resolved push target: rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -3)"
fi
rm -rf "$FX"

# ---- R13: AC3 — no re-run at fold; Stage 0 precedes Stage 1 (behavioral) ----
# A classify SENTINEL (the fence body prepended with an invocation recorder)
# proves the fold path with an explicitly decided bump never re-classifies;
# an ordered run log exhibits Stage-0/Stage-1 output preceding the Stage-1
# card write in the same flow.

FX=$(build_fixture plain)
SENT_LOG="$TMPDIR/classify-sentinel.$$.log"
: > "$SENT_LOG"
sub=$(printf '%s' "$FENCE" | subst_fence "origin/main" "yes" "patch" "one helper script" "code-bearing, no new Surface")
INST=$(printf 'printf "classify-fence-invoked\\n" >> "%s"\n%s\n' "$SENT_LOG" "$sub")
PFX=$(mktemp "$TMPDIR/classify-sent.XXXXXX")
fence_exec "$PFX" "$FX" "$INST" "CLAUDE_PLUGIN_ROOT=$ROOT"
SENT_OUT=$(cat "$PFX.out" 2>/dev/null)
rm -f "$PFX" "$PFX.sh" "$PFX.out" "$PFX.err"
SENT_BUMP=$(printf '%s' "$SENT_OUT" | sed -n 's/^CLASSIFY_BUMP=//p')
SENT_EV=$(printf '%s' "$SENT_OUT" | sed -n 's/^CLASSIFY_EVIDENCE=//p')
if [ "$(grep -c classify-fence-invoked "$SENT_LOG")" = "1" ] && [ "$SENT_BUMP" = "patch" ]; then
  pass_line "AC3 sentinel: pre-fold classification ran exactly once (sentinel count 1, decided bump=patch)"
else
  fail_line "AC3 sentinel: count=$(grep -c classify-fence-invoked "$SENT_LOG") bump=$SENT_BUMP"
fi
# Fold step: card #1 written via the Stage-1 writer with the decided bump
# passed EXPLICITLY — the classification itself is not re-run.
ORD="$TMPDIR/classify-order.$$.log"
: > "$ORD"
printf '1 stage-1 classify run: CLASSIFY_EVIDENCE=%s\n' "$SENT_EV" >> "$ORD"
if ( cd "$FX" && bash "$ROOT/skills/autopilot/append-card.sh" \
      orchestrate "$TICKET" ship-choice proceed auto "$SENT_BUMP" 90 null \
      "$RUN_ID" 3 10 orchestrator "$SENT_EV" ); then
  printf '2 stage-1 card write: bump=%s passed explicitly\n' "$SENT_BUMP" >> "$ORD"
  pass_line "AC3 fold: the fold with the explicitly decided bump succeeded (card #1 written with bump=patch)"
else
  fail_line "AC3 fold: append-card rejected the explicitly decided bump"
fi
if [ "$(grep -c classify-fence-invoked "$SENT_LOG")" = "1" ]; then
  pass_line "AC3 no-re-classify-at-fold: classify sentinel invoked exactly once — the fold did NOT re-run classification"
else
  fail_line "AC3 no-re-classify-at-fold: sentinel count became $(grep -c classify-fence-invoked "$SENT_LOG")"
fi
if [ "$(sed -n '1p' "$ORD" | grep -c '^1 stage-1 classify run: CLASSIFY_EVIDENCE=')" = "1" ] \
  && [ "$(sed -n '2p' "$ORD" | grep -c '^2 stage-1 card write:')" = "1" ] \
  && ( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null ) \
       | jq -r '.[0].rationale' | grep -qF "$SENT_EV"; then
  pass_line "AC3 stage ordering: Stage-0/Stage-1 classify output precedes the Stage-1 card write in the same run, and card #1 rationale carries it"
else
  fail_line "AC3 stage ordering: order log or rationale mismatch — $(cat "$ORD")"
fi
rm -rf "$FX" "$ORD" "$SENT_LOG"

# ---- R14: AC4 — halt path end-to-end: escalation, walk continues, no fold ----

FX=$(build_fixture plain)
HEAD0=$(git -C "$FX" rev-parse HEAD)
run_classify "$FX" "origin/main" "yes" "" "evidence" "reason"
if [ "$RUN_RC" -eq 0 ] \
  && ( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null ) \
       | jq -e '.[0].decision == "halt" and .[0].blocking_condition == 7' >/dev/null 2>&1; then
  pass_line "AC4 halt path end-to-end: escalation raised — the halt card (decision=halt, blocking_condition=7) is the escalation record"
else
  fail_line "AC4 halt path: rc=$RUN_RC or no BC7 escalation card"
fi
JLINE=$(printf '%s' "$RUN_OUT" | grep '^CLASSIFY_JOURNAL=' | head -1)
journal_outcome "$JLINE"
if [ "$JO_RC" -eq 0 ] && [ "$JO_OUT" = "pr-stopped" ]; then
  pass_line "AC4 halt path: the walk continues — walk-outcome --halt auto-classify-halt rc 0, outcome=pr-stopped"
else
  fail_line "AC4 halt path walk: rc=$JO_RC out=$JO_OUT"
fi
if [ "$(tag_count "$FX")" = "0" ] && [ "$(git -C "$FX" rev-parse HEAD)" = "$HEAD0" ]; then
  pass_line "AC4 halt path: no tag, no fold — zero tags and HEAD unchanged ($HEAD0)"
else
  fail_line "AC4 halt path: tag or fold side effect — tags=$(tag_count "$FX")"
fi
rm -rf "$FX"

# ---- R15: AC5 — the veto runs AFTER the LLM, on the same baseline diff ------
# A stub detect-surfaces records the ref it vetoes and the sha of the diff it
# sees; the LLM stage's diff (the same substituted baseline) is recorded
# before the fence runs. Ordering and identity are read from the shared run
# log, then the stub delegates to the real helper so the veto still applies.

FX=$(build_fixture surface)
STUB_V=$(mktemp -d "$TMPDIR/classify-veto.XXXXXX")
mkdir -p "$STUB_V/skills/release"
cp "$ROOT/skills/release/detect-surfaces.sh" "$STUB_V/skills/release/detect-surfaces-real.sh"
chmod +x "$STUB_V/skills/release/detect-surfaces-real.sh"
cat > "$STUB_V/skills/release/detect-surfaces.sh" <<WEOF
#!/usr/bin/env bash
# test stub: record the veto's ref + diff sha, then delegate to the real helper.
_log="$STUB_V/veto.log"
_ref=""
[ "\$1" = "--against" ] && _ref="\$2"
printf 'veto --against %s\n' "\$_ref" >> "\$_log"
printf 'veto-diff-sha %s\n' "\$(git diff --no-renames "\$_ref" | git hash-object --stdin)" >> "\$_log"
exec "$STUB_V/skills/release/detect-surfaces-real.sh" "\$@"
WEOF
cat > "$STUB_V/skills/plugin-dir.sh" <<'PDH_STUB'
#!/usr/bin/env bash
# stub: `file <rel>` resolves against the stub root (this script's dir/..).
[ "$1" = "file" ] || exit 1
_root=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$_root/$2" ] && { printf '%s\n' "$_root/$2"; exit 0; }
exit 1
PDH_STUB
VETO_LOG="$STUB_V/veto.log"
# LLM stage record: the diff the substituted stage-1 answer judged, written
# to the shared run log BEFORE the fence (and therefore the veto) runs.
LLM_SHA=$(git -C "$FX" diff --no-renames origin/main | git hash-object --stdin)
printf 'llm-stage diff-sha %s answer=patch baseline=origin/main\n' "$LLM_SHA" > "$VETO_LOG"
CLASSIFY_PLUGIN_ROOT="$STUB_V" run_classify "$FX" "origin/main" "yes" "patch" \
  "helper + surface" "patch-class LLM answer"
LLM_LINE=$(grep -n '^llm-stage' "$VETO_LOG" | head -1 | cut -d: -f1)
VETO_LINE=$(grep -n '^veto --against' "$VETO_LOG" | head -1 | cut -d: -f1)
VSHA=$(sed -n 's/^veto-diff-sha //p' "$VETO_LOG" | head -1)
VREF=$(sed -n 's/^veto --against //p' "$VETO_LOG" | head -1)
if [ -n "$LLM_LINE" ] && [ -n "$VETO_LINE" ] && [ "$VETO_LINE" -gt "$LLM_LINE" ]; then
  pass_line "AC5 ordering: the veto (detect-surfaces --against) ran AFTER the LLM stage in the same run (run-log line $VETO_LINE > $LLM_LINE)"
else
  fail_line "AC5 ordering: llm line=$LLM_LINE veto line=$VETO_LINE"
fi
if [ "$VREF" = "origin/main" ] && [ "$VSHA" = "$LLM_SHA" ] \
  && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=minor$'; then
  pass_line "AC5 same-diff: the veto's diff (sha ${VSHA:-none}) is the LLM-classified baseline diff (sha $LLM_SHA) against $VREF — and it raised patch to minor"
else
  fail_line "AC5 same-diff: veto ref=$VREF sha=$VSHA llm sha=$LLM_SHA out=$(printf '%s' "$RUN_OUT" | head -2)"
fi
rm -rf "$FX" "$STUB_V"

# ---- R16: AC6 — the Stage-1 envelope: one decided-bump card with evidence ----

FX=$(build_fixture surface)
run_classify "$FX" "origin/main" "yes" "patch" "helper + surface" "patch-class LLM answer"
S1_BUMP=$(printf '%s' "$RUN_OUT" | sed -n 's/^CLASSIFY_BUMP=//p')
S1_EV=$(printf '%s' "$RUN_OUT" | sed -n 's/^CLASSIFY_EVIDENCE=//p')
if ( cd "$FX" && bash "$ROOT/skills/autopilot/append-card.sh" \
      orchestrate "$TICKET" ship-choice proceed auto "$S1_BUMP" 90 null \
      "$RUN_ID" 3 10 orchestrator "$S1_EV" ); then
  S1_CARDS=$( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null \
    | jq '[.[] | select(.gate == "ship-choice" and .decision == "proceed")]' )
  if [ "$(printf '%s' "$S1_CARDS" | jq 'length')" = "1" ] \
    && printf '%s' "$S1_CARDS" | jq -e ".[0].bump == \"$S1_BUMP\"" >/dev/null 2>&1 \
    && printf '%s' "$S1_CARDS" | jq -r '.[0].rationale' | grep -qF 'stage0=code-bearing (helper + surface)' \
    && printf '%s' "$S1_CARDS" | jq -r '.[0].rationale' | grep -qF 'patch raised to minor — new Surface: commands/new-surface.md'; then
    pass_line "AC6 stage-1 round-trip: exactly one decided-bump ship-choice card #1 (written by the Stage-1 writer, NOT the classify fence) with bump=$S1_BUMP and rationale carrying the classification evidence + veto result"
  else
    fail_line "AC6 stage-1 round-trip: cards=$(printf '%s' "$S1_CARDS" | jq -c '.')"
  fi
else
  fail_line "AC6 stage-1 round-trip: append-card rejected the Stage-1 envelope"
fi
rm -rf "$FX"

# ---- R17: AC6 — bump:"auto" is invalid at every consuming surface -----------

# (a) the card writer
FX=$(build_fixture plain)
AC6_ERR=$( cd "$FX" && bash "$ROOT/skills/autopilot/append-card.sh" \
      orchestrate "$TICKET" ship-choice proceed auto auto 90 null \
      "$RUN_ID" 3 10 orchestrator "bump auto is invalid" 2>&1 )
AC6_RC=$?
if [ "$AC6_RC" = "64" ] && printf '%s\n' "$AC6_ERR" | grep -q '^error: .*bump'; then
  pass_line "AC6 bump:auto invalid — append-card (decision-card writer) rejects bump=auto"
else
  fail_line "AC6 bump:auto invalid: append-card did not reject bump=auto"
fi
rm -rf "$FX"
# (b) the fold-argv feed: a stage-1 answer of `auto` is non-enum -> fail-closed
# halt; no CLASSIFY_BUMP=auto is ever printed for the fold argv builder.
FX=$(build_fixture plain)
run_classify "$FX" "origin/main" "yes" "auto" "evidence" "auto is not a bump"
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=halt$' \
  && ! printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP='; then
  pass_line "AC6 bump:auto invalid — the classify fence (fold-argv feed) fail-closes stage1=auto to halt; no CLASSIFY_BUMP=auto printed"
else
  fail_line "AC6 bump:auto invalid: classify feed rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -3)"
fi
rm -rf "$FX"
# (c) the epic --release flag path
if ! bash "$ROOT/skills/epic/parse-flags.sh" --worktree --release auto >/dev/null 2>&1 \
  && [ "$(bash "$ROOT/skills/epic/parse-flags.sh" --worktree --release auto >/dev/null 2>&1; echo $?)" = "64" ]; then
  pass_line "AC6 bump:auto invalid — epic parse-flags --release auto rejected (rc 64; auto is not a --release bump, the token rides the BC5 --autopilot reroute)"
else
  fail_line "AC6 bump:auto invalid: epic parse-flags --release auto not rejected"
fi
# (d) the epic resume/state path: --autopilot=auto over a null durable
# release_bump is a hard 64 (seal-intent persists at init only).
EPI_REJ="$HERMETIC_ROOT/epic-rej.$$"
mkdir -p "$EPI_REJ"
git init -q "$EPI_REJ"
EPI2_OUT=$(cd "$EPI_REJ" && EPIC_ROOT="$EPI_REJ" bash "$ROOT/skills/epic/epic-lib.sh" \
  init EPIC-SPEC041-N --title t --mode orchestrate 2>&1)
EPI2_RC=$?
EPI2_OUT=$(cd "$EPI_REJ" && EPIC_ROOT="$EPI_REJ" bash "$ROOT/skills/epic/epic-lib.sh" \
  resolve-resume-flags EPIC-SPEC041-N --autopilot=auto 2>&1)
EPI2_RC=$?
if [ "$EPI2_RC" = "64" ]; then
  pass_line "AC6 bump:auto invalid — epic resolve-resume-flags --autopilot=auto over a null durable release_bump rejected (rc 64; no session-only bump)"
else
  fail_line "AC6 bump:auto invalid: resolve-resume-flags rc=$EPI2_RC out=$EPI2_OUT"
fi
rm -rf "$EPI_REJ"

# ---- R18: AC7 — positive: tags on a decided {patch, minor} bump -------------
# The fold path's tag command is /release Step 6's fence (skills/release/
# SKILL.md). Run it in a fixture repo with the decided bump's version
# substituted explicitly, and exhibit the created tag (name + commit).

TAG_FENCE=$(fence_nth "$ROOT/skills/release/SKILL.md" "## Step 6: Tag and push" 1)
if [ -n "$TAG_FENCE" ]; then
  FX=$(mktemp -d "$TMPDIR/classify-fold.XXXXXX")
  git -C "$FX" init -q -b main 2>/dev/null || { git -C "$FX" init -q; git -C "$FX" checkout -q -b main; }
  git -C "$FX" config user.email t@t.invalid
  git -C "$FX" config user.name t
  mkdir -p "$FX/.claude-plugin"
  printf '{"name":"t","version":"1.7.36"}\n' > "$FX/.claude-plugin/plugin.json"
  printf '%s\n' '### v1.7.36' > "$FX/CHANGELOG.md"
  git -C "$FX" add .claude-plugin/plugin.json CHANGELOG.md
  git -C "$FX" commit -qm "fix: v1.7.36 — baseline"
  # decided patch: the fold commit carries 1.7.37, the Step-6 fence tags it
  printf '{"name":"t","version":"1.7.37"}\n' > "$FX/.claude-plugin/plugin.json"
  printf '%s\n' '### v1.7.37' > "$FX/CHANGELOG.md"
  git -C "$FX" add .claude-plugin/plugin.json CHANGELOG.md
  git -C "$FX" commit -qm "fix: v1.7.37 — fold (decided patch)"
  PFX=$(mktemp "$TMPDIR/classify-tag.XXXXXX")
  fence_exec "$PFX" "$FX" "$(printf '%s' "$TAG_FENCE" | sed 's/vX\.Y\.Z/v1.7.37/g')"
  rm -f "$PFX" "$PFX.sh" "$PFX.out" "$PFX.err"
  P_TAG=$(git -C "$FX" tag --points-at HEAD)
  P_SHA=$(git -C "$FX" rev-parse v1.7.37 2>/dev/null)
  if [ "$P_TAG" = "v1.7.37" ] && [ -n "$P_SHA" ] && [ "$P_SHA" = "$(git -C "$FX" rev-parse HEAD)" ]; then
    pass_line "AC7 positive: the fold path Step-6 tag fence with the decided patch created tag v1.7.37 at the fold commit $P_SHA"
  else
    fail_line "AC7 positive patch: tag=$P_TAG sha=$P_SHA"
  fi
  # decided minor: the next fold commit carries 1.8.0, tagged v1.8.0
  printf '{"name":"t","version":"1.8.0"}\n' > "$FX/.claude-plugin/plugin.json"
  printf '%s\n' '### v1.8.0' > "$FX/CHANGELOG.md"
  git -C "$FX" add .claude-plugin/plugin.json CHANGELOG.md
  git -C "$FX" commit -qm "feat: v1.8.0 — fold (decided minor)"
  PFX=$(mktemp "$TMPDIR/classify-tag.XXXXXX")
  fence_exec "$PFX" "$FX" "$(printf '%s' "$TAG_FENCE" | sed 's/vX\.Y\.Z/v1.8.0/g')"
  rm -f "$PFX" "$PFX.sh" "$PFX.out" "$PFX.err"
  M_TAG=$(git -C "$FX" tag --points-at HEAD)
  M_SHA=$(git -C "$FX" rev-parse v1.8.0 2>/dev/null)
  if [ "$M_TAG" = "v1.8.0" ] && [ -n "$M_SHA" ] && [ "$M_SHA" = "$(git -C "$FX" rev-parse HEAD)" ]; then
    pass_line "AC7 positive: the fold path Step-6 tag fence with the decided minor created tag v1.8.0 at the fold commit $M_SHA (pairing the zero-tag cases above)"
  else
    fail_line "AC7 positive minor: tag=$M_TAG sha=$M_SHA"
  fi
  rm -rf "$FX"
else
  fail_line "AC7 positive: no fence under '## Step 6: Tag and push' in skills/release/SKILL.md"
fi

# ---- R19: AC3 no-spawn — in-session classification, no spawned agent -------
# AC3: the ship-gate bump is decided "in-session (LLM judgment, no spawned
# agent)". Run-output proof: the fence decides under a PATH that carries every
# tool it needs (bash, git, jq, coreutils) and resolves NO agent CLI. A fence
# that shelled out to an agent would die on the missing binary. The negative
# control (the same PATH with git removed) shows that PATH is load-bearing: the
# run really executes its subprocesses there.

BIN_MIN=$(mktemp -d "$TMPDIR/classify-bin.XXXXXX")
for t in bash git jq sed awk grep cut tr head tail wc sort dirname basename cat \
         env mktemp mkdir cp rm touch ls find xargs date chmod; do
  tp=$(command -v "$t" 2>/dev/null) || continue
  [ -x "$tp" ] && ln -s "$tp" "$BIN_MIN/$t"
done
NS_CLEAN=1
for a in claude grok codex opencode aider cursor; do
  if env PATH="$BIN_MIN" bash -c "command -v $a" >/dev/null 2>&1; then
    NS_CLEAN=0
    fail_line "AC3 no-spawn: agent CLI '$a' resolves on the minimal PATH — fixture is not a no-spawn PATH"
  fi
done
if [ "$NS_CLEAN" = "1" ]; then
  pass_line "AC3 no-spawn: fixture PATH carries $(ls "$BIN_MIN" | wc -l | tr -d ' ') tools and resolves no agent CLI (claude/grok/codex/opencode/aider/cursor all absent)"
fi
FX=$(build_fixture surface)
run_classify "$FX" "origin/main" "yes" "patch" "helper + surface" \
  "patch-class in-session, no agent CLI available" "PATH=$BIN_MIN"
NS_BUMP=$(printf '%s' "$RUN_OUT" | sed -n 's/^CLASSIFY_BUMP=//p')
if [ "$RUN_RC" -eq 0 ] && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION=decided$' \
  && [ "$NS_BUMP" = "minor" ]; then
  pass_line "AC3 no-spawn: fence decided with no agent CLI on PATH (rc 0, decision emitted: CLASSIFY_DECISION=decided CLASSIFY_BUMP=$NS_BUMP — the mechanical veto ran on that PATH)"
else
  fail_line "AC3 no-spawn: rc=$RUN_RC bump=$NS_BUMP out=$(printf '%s' "$RUN_OUT" | head -3) err=$(printf '%s' "$RUN_ERR" | head -3)"
fi
# Negative control: drop git from the same PATH — the fence MUST fail closed
# (machinery 64, no decision), proving the green run above used this PATH.
BIN_NOGIT=$(mktemp -d "$TMPDIR/classify-nogit.XXXXXX")
cp -a "$BIN_MIN"/. "$BIN_NOGIT"/
rm -f "$BIN_NOGIT/git"
run_classify "$FX" "origin/main" "yes" "patch" "helper + surface" \
  "negative control: git absent from PATH" "PATH=$BIN_NOGIT"
if [ "$RUN_RC" -eq 64 ] && ! printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_DECISION='; then
  pass_line "AC3 no-spawn: negative control — the same fence on the same PATH with git removed exits 64 with no decision, so the no-spawn run really executed on that PATH"
else
  fail_line "AC3 no-spawn: negative control rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -2)"
fi
# Advisory source assert: the extracted fence carries no agent-spawn machinery.
NS_SRC=$(printf '%s\n' "$FENCE" \
  | grep -Eic 'TaskCreate|Task\(|SendMessage|subagent|spawn|(^|[[:space:]])(claude|grok|codex|opencode)[[:space:]]|--model' || true)
if [ "$NS_SRC" = "0" ]; then
  pass_line "AC3 no-spawn: fence source holds no agent-spawn machinery (advisory)"
else
  fail_line "AC3 no-spawn: fence source carries agent-spawn machinery in $NS_SRC line(s)"
fi
rm -rf "$FX" "$BIN_MIN" "$BIN_NOGIT"

# ---- R20: AC8 veto-call — the fence's veto runs the shared helper -----------
# AC8: "Both check-bump-class.sh and the ship-gate veto call the helper". R15's
# stub records the veto's ref + diff sha; this case proves the resolved path
# itself: the stub root carries the REAL skills/plugin-dir.sh and a stub at
# skills/release/detect-surfaces.sh that appends its argv to a marker log, then
# execs the real helper. CLAUDE_PLUGIN_ROOT is the plugin-dir.sh Tier-0 force
# (see the file header), so the fence's DETECT binding lands on the stub.

FX=$(build_fixture surface)
STUB_VC=$(mktemp -d "$TMPDIR/classify-vetocall.XXXXXX")
mkdir -p "$STUB_VC/skills/release" "$STUB_VC/skills/autopilot"
cp "$ROOT/skills/plugin-dir.sh" "$STUB_VC/skills/plugin-dir.sh"
cp "$ROOT/skills/autopilot/budget-check.sh" "$STUB_VC/skills/autopilot/budget-check.sh"
cp "$ROOT/skills/autopilot/append-card.sh" "$STUB_VC/skills/autopilot/append-card.sh"
cp "$ROOT/skills/release/detect-surfaces.sh" "$STUB_VC/skills/release/detect-surfaces-real.sh"
chmod +x "$STUB_VC/skills/release/detect-surfaces-real.sh"
cat > "$STUB_VC/skills/release/detect-surfaces.sh" <<WEOF
#!/usr/bin/env bash
# test stub: record the caller's argv in the marker log, then exec the real
# shared helper so the veto path still runs end to end.
printf 'detect-surfaces.sh %s\n' "\$*" >> "$STUB_VC/detect-called.log"
exec "$STUB_VC/skills/release/detect-surfaces-real.sh" "\$@"
WEOF
CLASSIFY_PLUGIN_ROOT="$STUB_VC" run_classify "$FX" "origin/main" "yes" "patch" \
  "helper + surface" "patch-class LLM answer"
VC_MARK=$(head -1 "$STUB_VC/detect-called.log" 2>/dev/null)
if [ -s "$STUB_VC/detect-called.log" ] \
  && printf '%s' "$VC_MARK" | grep -q -- '--against origin/main' \
  && printf '%s' "$RUN_OUT" | grep -q '^CLASSIFY_BUMP=minor$' \
  && printf '%s' "$RUN_OUT" | grep -q 'raised to minor'; then
  pass_line "AC8 veto-call: fence veto invoked detect-surfaces.sh (marker: --against origin/main; first marker line '$VC_MARK'; veto still raised patch->minor, rc $RUN_RC)"
else
  fail_line "AC8 veto-call: marker='$(head -1 "$STUB_VC/detect-called.log" 2>/dev/null)' rc=$RUN_RC out=$(printf '%s' "$RUN_OUT" | head -2)"
fi
rm -rf "$FX" "$STUB_VC"

# ---- R8: prose bites — ordering, no stage-0 filter, journal mapping ---------

S0_BLOCKS=$(fence_blocks "$CLASSIFY" "### a. Stage 0")
if [ -z "$S0_BLOCKS" ]; then
  pass_line "prose: stage-0 subsection carries no executable filter (M8 — pure judgment)"
else
  fail_line "prose: stage-0 subsection holds a bash fence (deterministic filter?)"
fi
if has "$CLASSIFY" "MUST NOT add a path-glob"; then
  pass_line "prose: classify.md states the M8 no-filter rule"
else
  fail_line "prose: M8 no-filter rule missing from classify.md"
fi
if has "$CLASSIFY" "MUST NOT" && has "$CLASSIFY" "re-run classification at fold time"; then
  pass_line "prose: classify.md forbids re-classification at fold (M5)"
else
  fail_line "prose: fold-time re-classification ban missing"
fi
if has "$CLASSIFY" "auto-stage-0-no-code" && has "$CLASSIFY" "auto-classify-halt"; then
  pass_line "prose: journal condition names present (mapped via walk-outcome, M20 enum closed)"
else
  fail_line "prose: journal condition names missing"
fi
for needle in "Stage 0 — Classify" "walk-outcome --halt auto-classify-halt" \
  "pr-stopped" "/release <decided bump>" "never re-classified at fold"; do
  if has "$SHIP_PIPELINE" "$needle"; then
    pass_line "prose: ship-pipeline.md carries '$needle'"
  else
    fail_line "prose: ship-pipeline.md missing '$needle'"
  fi
done
S0_LINE=$(grep -n '^## Stage 0 — Classify' "$SHIP_PIPELINE" | head -1 | cut -d: -f1)
S1_LINE=$(grep -n '^## Stage 1 — Decide' "$SHIP_PIPELINE" | head -1 | cut -d: -f1)
if [ -n "$S0_LINE" ] && [ -n "$S1_LINE" ] && [ "$S0_LINE" -lt "$S1_LINE" ]; then
  pass_line "prose: ship-pipeline.md orders Stage 0 before Stage 1 (pre-ship-choice)"
else
  fail_line "prose: Stage 0 not ordered before Stage 1"
fi
S1_BODY=$(md_section "$SHIP_PIPELINE" "## Stage 1 — Decide")
if printf '%s' "$S1_BODY" | grep -q 'rationale' && printf '%s' "$S1_BODY" | grep -qi 'evidence' \
  && printf '%s' "$S1_BODY" | grep -qi 'veto'; then
  pass_line "prose: ship-pipeline.md Stage 1 states card #1 rationale carries the classification evidence + veto result (AC6)"
else
  fail_line "prose: ship-pipeline.md Stage 1 missing evidence+veto rationale line"
fi
if has "$SKILL" "classify.md" && has "$SKILL" "Stage 0 classify"; then
  pass_line "prose: SKILL.md carries the classify contract pointer + gate ordering"
else
  fail_line "prose: SKILL.md pointer/ordering missing"
fi

# ---- summary ----------------------------------------------------------------

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
