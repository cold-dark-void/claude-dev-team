#!/usr/bin/env bash
#
# council/test-concurrency.sh — SPEC-013 CDT-573 (Spawn concurrency cap)
# bite-tests for the council engine spine: the `--concurrency N` flag, the
# fail-closed preflight (exit 64, zero side effects), the plan.concurrency
# field, and the report frontmatter key.
#
# Precedence itself (flag > env > Model map) is T1's contract, tested in
# skills/model-map/concurrency-test.sh. This suite asserts the engine CALLS
# that one helper, carries the resolved value into the plan, and re-implements
# nothing. Named-roster isolation is delegated to the T1 fixture for the same
# reason.
#
# Machine-check: bash skills/council/test-concurrency.sh   (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
PREFLIGHT="$ROOT/skills/council/engine-preflight.sh"
FINALIZE="$ROOT/skills/council/engine-finalize.sh"
CMD="$ROOT/commands/council.md"
SKILL="$ROOT/skills/council/SKILL.md"
TPL_V="$ROOT/skills/council/templates/report-verdict.md"
TPL_F="$ROOT/skills/council/templates/report-finding.md"
MERGE="$ROOT/skills/model-map/resolve-concurrency.sh"
FIX="$ROOT/skills/council/fixtures/finalize-task-id"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

TMP="$(mktemp -d "${TMPDIR:-/tmp}/concurrency-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
STATE="$REPO/.claude/council"
MAP="$REPO/.claude/dev-team/models.local.json"

fail=0
ok()   { echo "OK: $1"; }
bad()  { echo "FAIL: $1" >&2; fail=1; }
want() {  # want <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi
}

# ---- plan <preflight args...> -----------------------------------------------
# Runs in the disposable repo, so the engine state dir and the Model map are
# ours. COUNCIL_CONCURRENCY is scrubbed unless CAP is set (CAP="" = set-empty).
PLANF="$TMP/plan.json"
ERRF="$TMP/err.txt"
RC=0
OUT=""
plan() {
  : > "$PLANF"
  : > "$ERRF"
  if [ -n "${CAP+x}" ]; then
    OUT=$( cd "$REPO" && env "COUNCIL_CONCURRENCY=$CAP" bash "$ENGINE" preflight "$@" 2>"$ERRF" )
  else
    OUT=$( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" preflight "$@" 2>"$ERRF" )
  fi
  RC=$?
  if [ -n "$OUT" ]; then
    printf '%s\n' "$OUT" > "$PLANF" || bad "plan capture failed"
  fi
  return 0
}

expect_rc() { [ "$RC" -eq "$2" ] && ok "$1" || bad "$1 (exit $RC, want $2)"; }

expect_plan() {  # expect_plan <label> <jq-boolean-filter>
  if jq -e "$2" "$PLANF" >/dev/null 2>&1; then ok "$1"; else bad "$1 — plan: $(head -c 240 "$PLANF")"; fi
}

grep_file() {  # grep_file <label> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2 in $3)"; fi
}
ngrep_file() {  # ngrep_file <label> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then bad "$1 (present: $2 in $3)"; else ok "$1"; fi
}
ngrep_code() {  # ngrep_code <label> <fixed-string> <file> — full-line comments stripped
  if sed 's/^[[:space:]]*#.*//' "$3" | grep -qF -- "$2"; then
    bad "$1 (present in code: $2 in $3)"
  else
    ok "$1"
  fi
}

# Side-effect snapshot: engine state dir + the per-run cache dirs preflight
# creates under TMPDIR. A fail-closed preflight leaves both untouched, so the
# snapshots around a failing run MUST compare byte-identical.
snap() {
  { find "$STATE" -mindepth 1 2>/dev/null | sort
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'council-cache-*' 2>/dev/null | sort
  } > "$1"
}
no_side_effects() {  # no_side_effects <label>
  snap "$TMP/snap-after"
  if diff -q "$TMP/snap-before" "$TMP/snap-after" >/dev/null; then
    ok "$1: zero side effects (state dir + cache dirs untouched)"
  else
    bad "$1: mutated state: $(comm -13 "$TMP/snap-before" "$TMP/snap-after" | head -3)"
  fi
}

write_map() {  # write_map <raw-json-value>
  mkdir -p "$(dirname "$MAP")" || { bad "write_map: mkdir failed"; return 1; }
  printf '{\n  "concurrency": %s,\n  "agents": {"ic5": "sonnet"}\n}\n' "$1" > "$MAP" \
    || { bad "write_map: write failed"; return 1; }
}
clear_map() { rm -f "$MAP"; }

# A clean baseline: no map layer, env unset.
clear_map
unset CAP
snap "$TMP/snap-before"

# ---- 1. Unset at every layer -> plan omits the field ------------------------
plan --scope claim --scope-arg "x"
expect_rc "unset cap: preflight exit 0" 0
expect_plan "unset cap: plan has no concurrency key" 'has("concurrency") | not'
jq -S 'del(.cache_dir,.run_id)' "$PLANF" > "$TMP/plan-base.json"
cp "$PLANF" "$TMP/plan-unset.json"

# ---- 2. Empty-string env is unset, not invalid ------------------------------
CAP=""
plan --scope claim --scope-arg "x"
expect_rc "empty-string env: preflight exit 0" 0
expect_plan "empty-string env: plan omits concurrency" 'has("concurrency") | not'
jq -S 'del(.cache_dir,.run_id)' "$PLANF" > "$TMP/plan-empty.json"
if diff -q "$TMP/plan-base.json" "$TMP/plan-empty.json" >/dev/null; then
  ok "empty-string env: plan identical to unset (AC1/AC4)"
else
  bad "empty-string env changed the plan text"
fi
unset CAP

# ---- 3. --concurrency 2 -> plan carries the integer -------------------------
plan --scope claim --scope-arg "x" --concurrency 2
expect_rc "--concurrency 2: preflight exit 0" 0
expect_plan "--concurrency 2: plan.concurrency == 2" '.concurrency == 2'
expect_plan "--concurrency 2: plan.concurrency is a JSON number" '(.concurrency|type) == "number"'
jq -S 'del(.cache_dir,.run_id,.concurrency)' "$PLANF" > "$TMP/plan-c2-strip.json"
if diff -q "$TMP/plan-base.json" "$TMP/plan-c2-strip.json" >/dev/null; then
  ok "--concurrency 2: the cap field is the ONLY plan delta (spawn-fence text unchanged)"
else
  bad "--concurrency 2 changed plan text beyond the cap field"
fi
ngrep_file "capped plan carries no Spawn contract line (T6 owns the fence)" 'Spawn contract:' "$PLANF"
cp "$PLANF" "$TMP/plan-cap.json"

# ---- 4. Flag beats env; env honored; env validated --------------------------
CAP=7 plan --scope claim --scope-arg "x" --concurrency 2
expect_plan "flag beats env" '.concurrency == 2'
CAP=4 plan --scope claim --scope-arg "x"
expect_plan "env honored when the flag is absent" '.concurrency == 4'
CAP=abc
snap "$TMP/snap-before"
plan --scope claim --scope-arg "x"
expect_rc "invalid env: exit 64" 64
want "invalid env: empty stdout" "" "$OUT"
[ -s "$PLANF" ] && bad "invalid env wrote a plan" || ok "invalid env wrote no plan"
no_side_effects "invalid env"
unset CAP

# ---- 5. Model map layer -----------------------------------------------------
write_map '3'
plan --scope claim --scope-arg "x"
expect_rc "valid map key: exit 0" 0
expect_plan "valid map key: plan.concurrency == 3" '.concurrency == 3'
write_map 'null'
plan --scope claim --scope-arg "x"
expect_rc "null map value: exit 0" 0
expect_plan "null map value: plan omits concurrency (unbounded)" 'has("concurrency") | not'
write_map '""'
plan --scope claim --scope-arg "x"
expect_rc "empty-string map value: exit 0" 0
expect_plan "empty-string map value: plan omits concurrency" 'has("concurrency") | not'
snap "$TMP/snap-before"
for badval in '"abc"' '0' '-1' '"2.5"' 'true' '[2]' '{"n":2}'; do
  write_map "$badval"
  plan --scope claim --scope-arg "x"
  expect_rc "invalid stored map key $badval: exit 64" 64
  [ -s "$PLANF" ] && bad "invalid map key $badval wrote a plan"
done
no_side_effects "invalid stored map keys"
clear_map

# ---- 6. Fail-closed flag values ---------------------------------------------
snap "$TMP/snap-before"
for v in 0 -1 abc 2.5 1x " 2" 02 ""; do
  plan --scope claim --scope-arg "x" --concurrency "$v"
  expect_rc "--concurrency '$v': exit 64" 64
  want "--concurrency '$v': empty stdout" "" "$OUT"
  [ -s "$PLANF" ] && bad "--concurrency '$v' wrote a plan"
  grep -q 'concurrency' "$ERRF" \
    || bad "--concurrency '$v': stderr names no concurrency cause: $(head -2 "$ERRF")"
done
plan --scope claim --scope-arg "x" --concurrency
expect_rc "bare --concurrency (missing arg): exit 64" 64
want "bare --concurrency: empty stdout" "" "$OUT"
no_side_effects "fail-closed flag values"
# The cap is orthogonal to scope and tier: a valid cap + light tier resolve both.
plan --scope diff --tier light --concurrency 2
expect_rc "cap is orthogonal to scope + tier" 0
expect_plan "cap + tier: both recorded" '.concurrency == 2 and .council_tier == "light"'
# Existing hard fails are unchanged by this flag.
plan --scope claim --scope-arg "x" --concurrencyy 2
expect_rc "unknown flag still exits 2" 2
plan --scope claim --scope-arg "x" --tier skip
expect_rc "--tier skip hard fail unchanged (exit 2)" 2

# ---- 7. Report frontmatter --------------------------------------------------
report_fm() {  # report_fm <plan-file> <out> <label>
  ( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" finalize \
      --plan-file "$1" --evidence-file "$FIX/evidence.json" \
      --judge-output "$FIX/judge.json" --report-out "$2" \
      >/dev/null 2>"$TMP/finalize-err.txt" )
  RC=$?
  [ "$RC" -eq 0 ] && ok "$3: finalize exit 0" \
    || bad "$3: finalize exit $RC — $(head -3 "$TMP/finalize-err.txt")"
}

report_fm "$TMP/plan-unset.json" "$TMP/unbounded.md" "unset cap"
grep_file "unset cap: FM concurrency unbounded" 'concurrency: "unbounded"' "$TMP/unbounded.md"
report_fm "$TMP/plan-cap.json" "$TMP/cap2.md" "capped run"
grep_file "--concurrency 2: FM concurrency \"2\"" 'concurrency: "2"' "$TMP/cap2.md"

# AC3 — queueing is not a spawn failure: a capped run never degrades.
ngrep_file "capped report emits no CDV-199 marker" 'self-verified — refuters unavailable' "$TMP/cap2.md"
grep_file "capped report keeps verification_mode full" 'verification_mode: "full"' "$TMP/cap2.md"
ngrep_file "capped report carries no Spawn contract line (T6 owns the fence)" 'Spawn contract:' "$TMP/cap2.md"
ngrep_file "unset report carries no Spawn contract line" 'Spawn contract:' "$TMP/unbounded.md"

# Pre-cap plan files still finalize, and report unbounded (forward/back compat).
report_fm "$FIX/plan-unbound.json" "$TMP/legacy.md" "plan without the key"
grep_file "plan without concurrency: FM unbounded" 'concurrency: "unbounded"' "$TMP/legacy.md"

# A hostile plan value (the plan file is LLM-writable) must not break the YAML.
printf '2\ninjected_key: yes' > "$TMP/evil-value.txt"
jq --arg v "$(cat "$TMP/evil-value.txt")" '.concurrency = $v' "$TMP/plan-cap.json" > "$TMP/plan-evil.json"
report_fm "$TMP/plan-evil.json" "$TMP/evil.md" "hostile plan concurrency"
want "hostile plan value renders one concurrency line" "1" "$(grep -c '^concurrency:' "$TMP/evil.md")"
grep_file "hostile plan value fails closed to unbounded" 'concurrency: "unbounded"' "$TMP/evil.md"
ngrep_file "hostile plan value is not emitted raw" 'injected_key: yes' "$TMP/evil.md"

# finding[] shape gets the same key (both canonical templates).
jq '.output_shape = "finding[]" | .preset = "diff-mode"' "$TMP/plan-cap.json" > "$TMP/plan-find.json"
printf '%s\n' '{"findings":[{"file":"a.sh","line":3,"severity":"warning","category":"design","description":"d","suggestion":"s","confidence":90,"tool_use_id":"toolu_1"}]}' > "$TMP/judge-find.json"
( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" finalize \
    --plan-file "$TMP/plan-find.json" --evidence-file "$FIX/evidence.json" \
    --judge-output "$TMP/judge-find.json" --report-out "$TMP/finding.md" \
    >/dev/null 2>&1 )
RC=$?
expect_rc "finding[] finalize exit 0" 0
grep_file "finding[] report FM concurrency" 'concurrency: "2"' "$TMP/finding.md"

# ---- 8. One merge helper — no precedence copy in the engine ------------------
grep_file "preflight resolves the cap through resolve-concurrency.sh" 'resolve-concurrency.sh' "$PREFLIGHT"
ngrep_code "preflight does not read COUNCIL_CONCURRENCY in code" 'COUNCIL_CONCURRENCY' "$PREFLIGHT"
ngrep_code "preflight does not call resolve-model.sh in code" 'resolve-model.sh' "$PREFLIGHT"
grep_file "the merge helper is the map reader" 'resolve-model.sh" --concurrency' "$MERGE"
grep_file "finalize substitutes {{CONCURRENCY}}" '{{CONCURRENCY}}' "$FINALIZE"
grep_file "verdict template owns the FM key" 'concurrency: "{{CONCURRENCY}}"' "$TPL_V"
grep_file "finding template owns the FM key" 'concurrency: "{{CONCURRENCY}}"' "$TPL_F"
grep_file "council.md resolves the cap through the merge helper" 'resolve-concurrency.sh' "$CMD"
ngrep_file "council.md does not read the Model map layer itself" 'models.local.json' "$CMD"
want "council.md names --concurrency at least 4 times" "yes" \
  "$([ "$(grep -c -- '--concurrency' "$CMD")" -ge 4 ] && echo yes || echo no)"
grep_file "council.md usage lists the cap" '[--concurrency N]' "$CMD"
grep_file "council.md argument-hint lists the cap" '[--concurrency N]' "$CMD"
grep_file "engine usage lists the cap" '[--concurrency N]' "$ROOT/skills/council/engine-util.sh"
grep_file "SKILL.md records queueing as non-degradation" 'Queueing is not a spawn failure' "$SKILL"
if [ -e "$STATE/index.json" ]; then bad "test polluted the shared state dir"; else ok "no index row written by these runs"; fi

# ---- 9. The /council § 0.5.1 fence behaves ----------------------------------
# Extract the fence from commands/council.md and run it. Claude Code substitutes
# $ARGUMENTS textually, so this harness performs the same substitution.
# CLAUDE_PLUGIN_ROOT forces plugin-dir.sh at this tree — the fence resolves
# resolve-concurrency.sh through it.
FENCE="$TMP/conc-fence.sh"
RUNF="$TMP/conc-fence-run.sh"
awk '/^### 0\.5\.1/,/^An absent flag leaves/' "$CMD" \
  | awk '/^```bash$/{f=1;next} /^```$/{if(f)exit} f' > "$FENCE"
if [ ! -s "$FENCE" ]; then
  bad "the § 0.5.1 bash fence could not be extracted from council.md"
else
  FENCE_RC=0
  FENCE_OUT=""
  run_fence() {  # run_fence <args-string>
    awk -v a="$1" '{ if ($0 == "$ARGUMENTS") print a; else print }' "$FENCE" > "$RUNF"
    FENCE_OUT=$( cd "$REPO" && env -u COUNCIL_CONCURRENCY CLAUDE_PLUGIN_ROOT="$ROOT" bash "$RUNF" 2>&1 )
    FENCE_RC=$?
  }
  snap "$TMP/snap-before"
  for c in "--diff --concurrency 2" "--diff --concurrency=2" "--diff --concurrency 2 --council-tier=light" "--diff" "--blind --concurrency 3"; do
    run_fence "$c"
    [ "$FENCE_RC" = "0" ] && ok "fence accepts '$c'" || bad "fence rejected '$c' (rc=$FENCE_RC)"
  done
  for c in "--diff --concurrency 0" "--diff --concurrency abc" "--diff --concurrency 2.5" "--diff --concurrency" "--diff --concurrency=" "--blind --concurrency -3"; do
    run_fence "$c"
    if [ "$FENCE_RC" = "64" ] && printf '%s\n' "$FENCE_OUT" | grep -qF 'Usage: /council' \
       && printf '%s\n' "$FENCE_OUT" | grep -qF -- '--concurrency'; then
      ok "fence fails closed 64 + usage on '$c'"
    else
      bad "fence on '$c': rc=$FENCE_RC (want 64 with usage), out=$(printf '%s' "$FENCE_OUT" | head -1)"
    fi
  done
  # Zero side effects: the fence runs before Step 1, so it must create nothing.
  no_side_effects "the § 0.5.1 fence"
fi

# ---- 10. Task-path spawn contract line (T6, AC8) -----------------------------
# The canonical sentence has ONE home: skills/council/spawn-contract.md.
# Every fleet fence cites that path; the test resolves the line from the fence
# file, applies the documented placement/substitution/unset rules, and asserts
# the emitted prompt fixtures. Sites that retype the sentence break AC8.
SCF="$ROOT/skills/council/spawn-contract.md"
SENT='Spawn contract: at most <N> spawns in flight — spawn a batch, await all returns, then the next batch. Never exceed.'
AC8_2='Spawn contract: at most 2 spawns in flight — spawn a batch, await all returns, then the next batch. Never exceed.'
FENCE_PATH='skills/council/spawn-contract.md'

if [ -f "$SCF" ]; then
  ok "the canonical fence exists"
else
  bad "missing canonical fence: $SCF"
fi

# Single copy: the sentence appears exactly once in the fence file.
want "fence carries the AC8 sentence exactly once" "1" "$(grep -cF -- "$SENT" "$SCF")"
# Rules the fence must state (substitution, placement, unset).
grep_file "fence names the carrier (plan.concurrency)" 'plan.concurrency' "$SCF"
grep_file "fence states the placement rule (once per fleet spawn fence)" 'once per fleet spawn fence' "$SCF"
grep_file "fence states the unset rule (no line, fence byte-unchanged)" 'byte-unchanged' "$SCF"
grep_file "fence states the blindness rule (sibling-batch output)" 'sibling-batch output' "$SCF"

# Resolve the canonical line from the fence, the way a fleet fence does.
CANON=$(grep -F -- 'Spawn contract: at most <N> spawns in flight' "$SCF" | head -1)
CAPN=$(jq -r '.concurrency // empty' "$TMP/plan-cap.json")
UNBOUND=$(jq -r '.concurrency // empty' "$TMP/plan-unset.json")
want "capped plan yields the integer carrier" "2" "$CAPN"
want "unset plan yields no carrier value" "" "$UNBOUND"
want "the fence resolves <N>=2 to the exact AC8 line" "$AC8_2" "${CANON//<N>/$CAPN}"

# Emitted-prompt fixtures: one per enumerated fence, capped and uncapped.
SITES="phase2 phase2-5 phase3 phase4 phase5-parts blind"
emit_prompts() {  # emit_prompts <plan-file> <out-dir>
  local n d site
  n=$(jq -r '.concurrency // empty' "$1") || return 1
  d="$2"
  mkdir -p "$d" || return 1
  for site in $SITES; do
    {
      printf 'Fleet instruction (%s): spawn this wave in parallel.\n' "$site" \
        || return 1
      if [ -n "$n" ]; then
        printf '%s\n' "${CANON//<N>/$n}" || return 1
      fi
    } > "$d/$site.md" || return 1
  done
  return 0
}
emit_prompts "$TMP/plan-cap.json" "$TMP/prompt-cap" \
  || bad "emit_prompts (capped) failed"
emit_prompts "$TMP/plan-unset.json" "$TMP/prompt-open" \
  || bad "emit_prompts (unset) failed"

for site in $SITES; do
  want "capped $site fence emits the AC8 line once" "1" \
    "$(grep -cF -- "$AC8_2" "$TMP/prompt-cap/$site.md")"
  want "unset $site fence emits no contract line" "0" \
    "$(grep -cF -- 'Spawn contract:' "$TMP/prompt-open/$site.md")"
done

# Citation-by-path at every enumerated fence; no site retypes the sentence.
cite_n() { grep -cF -- "$FENCE_PATH" "$1"; }  # cite_n <file> -> path mentions
want "phases-0-2.md cites the fence (Phase 2)" "yes" \
  "$([ "$(cite_n "$ROOT/skills/council/phases-0-2.md")" -ge 1 ] && echo yes || echo no)"
want "phases-4-5.md cites the fence 3x (Phases 3, 4, 5 parts)" "3" \
  "$(cite_n "$ROOT/skills/council/phases-4-5.md")"
want "phases-blind.md cites the fence 2x (blind wave, Phase 2.5)" "2" \
  "$(cite_n "$ROOT/skills/council/phases-blind.md")"
want "invocation-contract.md cites the fence" "yes" \
  "$([ "$(cite_n "$ROOT/skills/council/invocation-contract.md")" -ge 1 ] && echo yes || echo no)"
want "SKILL.md cites the fence" "yes" \
  "$([ "$(cite_n "$SKILL")" -ge 1 ] && echo yes || echo no)"
want "council.md cites the fence at every fleet step (≥ 6)" "yes" \
  "$([ "$(cite_n "$CMD")" -ge 6 ] && echo yes || echo no)"

# Only the fence file may carry the sentence in the plugin's markdown surface
# (commands/, skills/). Test suites pin it as an expected-value string; that is
# an assertion, not a second fence.
RETIPEDED=$(grep -rlF --include='*.md' -- 'Spawn contract: at most' \
  "$ROOT/skills" "$ROOT/commands" 2>/dev/null \
  | grep -vF -- "$FENCE_PATH" || true)
want "no markdown site retypes the sentence" "" "$RETIPEDED"

# Out-of-cap fences MUST NOT cite the line: the IC DAG and /kickoff Step 2.
ngrep_file "/kickoff Step 2 finder fan-out is out of the cap" "$FENCE_PATH" \
  "$ROOT/skills/kickoff/SKILL.md"
ngrep_file "the orchestrate IC spawn step is out of the cap" "$FENCE_PATH" \
  "$ROOT/skills/orchestrate/steps/08-execute.md"

# ---- 11. Docs N×X per-run note (T11, AC7 carry-forward) -----------------------
# Every user-facing Surface page that documents the cap carries the
# non-normative machine-total note: the canonical phrase "per-run, not
# machine-wide" plus the `N×X` total (SPEC-013 CDT-573, docs standard T11).
# Docs prose is the shipped surface; the exact sentence form may wrap, so the
# asserts pin the canonical phrase fragment on one line, per file.
DOCS_CAP="docs/commands/bug-hunt.md docs/commands/council.md docs/commands/debug.md docs/commands/orchestrate.md docs/commands/review-and-commit.md docs/commands/setup.md docs/setup.md"
for df in $DOCS_CAP; do
  grep_file "docs carry the per-run phrase: $df" 'per-run, not machine-wide' "$ROOT/$df"
  grep_file "docs carry the N×X machine-total note: $df" 'N×X' "$ROOT/$df"
done
PER_RUN_N=$(grep -rlF --include='*.md' -- 'per-run, not machine-wide' "$ROOT/docs" | wc -l)
want "per-run phrase in exactly 7 docs files" "7" "$PER_RUN_N"
NX_N=$(grep -rlF --include='*.md' -- 'N×X' "$ROOT/docs" | wc -l)
want "N×X note in exactly 7 docs files" "7" "$NX_N"

echo ""
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
echo "VERIFY exit=$fail"
exit "$fail"
