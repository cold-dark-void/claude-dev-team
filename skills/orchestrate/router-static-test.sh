#!/usr/bin/env bash
# router-static-test.sh — CDT-199 PR1: /orchestrate SKILL.md is a ≤80-line router.
# Greps committed protocol only (no network, no LLM).
# Run: bash skills/orchestrate/router-static-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
STEPS="$HERE/steps"

# Hermetic suite (SPEC-030 R20): AC E (T17) runs the cycle-gate
# fences as live git commands, so this suite must not touch the caller's
# git state.
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ---- T0: SKILL.md exists + YAML name ----
if [ -f "$SKILL" ] && grep -q '^name: orchestrate$' "$SKILL"; then ok
else bad "T0 SKILL.md missing or name: orchestrate absent"; fi

# ---- T1: router ≤80 lines (always-on inject cap) ----
N=$(wc -l < "$SKILL" | tr -d ' ')
if [ "$N" -le 80 ]; then ok
else bad "T1 SKILL.md is $N lines (must be ≤80 router)"; fi

# ---- T2: load-only-current-phase contract ----
if grep -qiE 'read steps/|current (step|phase)' "$SKILL" \
  && grep -qiE 'do not Read every|only the current|not.*every steps' "$SKILL"; then
  ok
else
  bad "T2 SKILL.md missing load-only-current-phase protocol"
fi

# ---- T3: step index files exist ----
EXPECTED='
00-resolve.md
01-fetch.md
02-scope.md
03-worktree.md
04-kickoff.md
05-questions.md
06-design.md
07-tasks.md
08-execute.md
09-review.md
10-qa.md
11-ship.md
12-wrap.md
cross-cutting.md
'
missing=""
for f in $EXPECTED; do
  [ -f "$STEPS/$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then ok
else bad "T3 missing step files:$missing"; fi

# ---- T4: no new file >1000 lines ----
over=""
while IFS= read -r path; do
  ln=$(wc -l < "$path" | tr -d ' ')
  if [ "$ln" -gt 1000 ]; then
    over="$over $(basename "$path"):$ln"
  fi
done <<EOF
$(find "$HERE" -type f -name '*.md' ! -path '*/fixtures/*')
EOF
if [ -z "$over" ]; then ok
else bad "T4 files over 1000 lines:$over"; fi

# ---- T5: monolith gone from always-on path ----
# Router must not embed the Step 8 spawn body or Step 11 ship template.
if ! grep -q 'Spawn @<agent> for Task' "$SKILL" \
  && ! grep -q 'gh pr create --title' "$SKILL"; then
  ok
else
  bad "T5 SKILL.md still embeds spawn/ship monolith bodies"
fi

# ---- T6: user-visible MUST protocol still in steps/ ----
NEEDLES='
You do NOT write code
assert-release-allowed
history dirty — rewrite needed
Orchestration complete
requires_council
self-answer.md
ensure-ticket-worktree
PM kickoff is mandatory
check-ship-history.sh
--autopilot=master
--council-tier
--resume-ship
Passive notifications
'
miss=""
# newline-safe: read line by line
while IFS= read -r needle; do
  [ -n "$needle" ] || continue
  if ! grep -rqF -- "$needle" "$STEPS"; then
    miss="$miss | $needle"
  fi
done <<EOF
$NEEDLES
EOF
if [ -z "$miss" ]; then ok
else bad "T6 protocol needles missing from steps/:$miss"; fi

# ---- T7: no commands/orchestrate.md embed of the skill ----
if [ -f "$ROOT/commands/orchestrate.md" ]; then
  bad "T7 commands/orchestrate.md exists — must not embed the skill monolith"
else
  ok
fi

# ---- T8: SKILL.md lists --tier=light|standard|full (SPEC-009 CDT-206) ----
# Accept --tier=light|standard|full or --tier=<light|standard|full> on the Arguments line.
if grep -qE -- '--tier=<?light\|standard\|full>?' "$SKILL"; then ok
else bad "T8 SKILL.md missing --tier=light|standard|full (or equivalent Arguments line)"; fi

# ---- T9: per-tier table + light step map (SPEC-009 CDT-210) ----
# standard and full near a markdown table; light row names the real light path.
if grep -E '^\|' "$SKILL" | grep -q 'standard' \
  && grep -E '^\|' "$SKILL" | grep -q 'full' \
  && grep -E '^\|' "$SKILL" | grep -qiE 'light' \
  && grep -E '^\|' "$SKILL" | grep -iE 'light' | grep -qiE 'scoper-planner' \
  && grep -E '^\|' "$SKILL" | grep -iE 'light' | grep -qiE 'skip DAG|one IC4|single-pass'; then
  ok
else
  bad "T9 SKILL.md missing per-tier table (standard/full/light + light step map)"
fi

# ---- T10: ORCH_TIER binding + light-branch form (SPEC-009 CDT-207+) ----
# Binding lives in 00-resolve.md. Later children MAY branch on exactly
# `[ "$ORCH_TIER" = "light" ]` in allowed step files. NEVER `!=`.
# Allow: 02-scope.md, 04–10, 12-wrap.md.
# FORBID: 01-fetch.md, 03-worktree.md, 11-ship.md.
# 02-scope.md may also use `[ "$ORCH_TIER" = "null" ]` (C5 auto-size) or ORCH_TIER=.
t10_fail=""
if ! grep -q 'ORCH_TIER=' "$STEPS/00-resolve.md"; then
  t10_fail="$t10_fail 00-resolve.md missing ORCH_TIER="
fi
t10_allow='02-scope.md 04-kickoff.md 05-questions.md 06-design.md 07-tasks.md 08-execute.md 09-review.md 10-qa.md 12-wrap.md'
t10_forbid='01-fetch.md 03-worktree.md 11-ship.md'
for f in $t10_forbid; do
  if grep -q 'ORCH_TIER' "$STEPS/$f"; then
    t10_fail="$t10_fail FORBID:$f"
  fi
done
for f in "$STEPS"/*.md; do
  base=$(basename "$f")
  [ "$base" = "00-resolve.md" ] && continue
  case " $t10_allow " in
    *" $base "*) continue ;;
  esac
  if grep -q 'ORCH_TIER' "$f"; then
    t10_fail="$t10_fail leaked:$base"
  fi
done
for f in $t10_allow; do
  path="$STEPS/$f"
  grep -q 'ORCH_TIER' "$path" || continue
  if grep 'ORCH_TIER' "$path" | grep -q '!='; then
    t10_fail="$t10_fail $f has !="
  fi
  while IFS= read -r line; do
    echo "$line" | grep -q 'ORCH_TIER' || continue
    case "$line" in
      *'[ "$ORCH_TIER" = "light" ]'*) continue ;;
    esac
    if [ "$f" = "02-scope.md" ]; then
      case "$line" in
        *'[ "$ORCH_TIER" = "null" ]'*) continue ;;
        *ORCH_TIER=*) continue ;;
      esac
    fi
    t10_fail="$t10_fail $f bad-form"
  done < "$path"
done
if [ -z "$t10_fail" ]; then ok
else bad "T10$t10_fail"; fi

# ---- T11: spawn-site identity (omit/standard/full else-branch) ----
# Else/default sections MUST still contain today's spawn sites.
t11_fail=""
for n in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ! grep -qE "^\\| $n \\|" "$SKILL"; then
    t11_fail="$t11_fail | missing step $n row"
  fi
done
if ! grep -q 'PM agent' "$STEPS/04-kickoff.md" \
  && ! grep -q '@pm' "$STEPS/04-kickoff.md"; then
  t11_fail="$t11_fail | 04-kickoff.md missing PM spawn"
fi
if ! grep -q 'Tech Lead agent' "$STEPS/04-kickoff.md" \
  && ! grep -q '@tech-lead' "$STEPS/04-kickoff.md"; then
  t11_fail="$t11_fail | 04-kickoff.md missing Tech Lead spawn"
fi
if ! grep -q 'Spawn @' "$STEPS/08-execute.md" \
  && ! grep -qi 'spawn the Claude IC' "$STEPS/08-execute.md"; then
  t11_fail="$t11_fail | 08-execute.md missing spawn instruction"
fi
if ! grep -q '@qa' "$STEPS/10-qa.md" \
  && ! grep -qi 'spawn QA' "$STEPS/10-qa.md"; then
  t11_fail="$t11_fail | 10-qa.md missing QA spawn"
fi
if ! grep -qi 'Tech Lead review' "$STEPS/09-review.md"; then
  t11_fail="$t11_fail | 09-review.md missing Tech Lead review"
fi
if ! grep -q 'task-graph.md' "$STEPS/07-tasks.md"; then
  t11_fail="$t11_fail | 07-tasks.md missing task-graph.md citation"
fi
if ! grep -q 'check-cycle' "$HERE/task-graph.md" 2>/dev/null; then
  t11_fail="$t11_fail | task-graph.md missing DAG check-cycle"
fi
if ! grep -q 'reviewed 3+ times' "$STEPS/09-review.md"; then
  t11_fail="$t11_fail | 09-review.md missing 3-round deadloop"
fi
if [ -z "$t11_fail" ]; then ok
else bad "T11 spawn-site identity:$t11_fail"; fi

# ---- T12: light-branch exact test (C2–C4 = steps 4–10 + 12) ----
t12_fail=""
for f in 04-kickoff.md 05-questions.md 06-design.md 07-tasks.md 08-execute.md 09-review.md 10-qa.md 12-wrap.md; do
  if ! grep -Fq '[ "$ORCH_TIER" = "light" ]' "$STEPS/$f"; then
    t12_fail="$t12_fail $f"
  fi
done
if ! grep -qi 'scoper-planner' "$STEPS/04-kickoff.md"; then
  t12_fail="$t12_fail 04 missing scoper-planner"
fi
if ! grep -qi 'skip DAG' "$STEPS/07-tasks.md" && ! grep -qi 'skip DAG and task-store' "$STEPS/07-tasks.md"; then
  t12_fail="$t12_fail 07 missing skip DAG"
fi
if ! grep -q 'Spawn @ic4' "$STEPS/08-execute.md"; then
  t12_fail="$t12_fail 08 missing Spawn @ic4"
fi
if ! grep -qi 'single-pass' "$STEPS/09-review.md"; then
  t12_fail="$t12_fail 09 missing single-pass"
fi
if ! grep -qi 'do not spawn `@qa`' "$STEPS/10-qa.md" && ! grep -qi 'do not spawn @qa' "$STEPS/10-qa.md"; then
  t12_fail="$t12_fail 10 missing no-qa-spawn"
fi
if ! grep -qi 'skip Step 12b' "$STEPS/12-wrap.md"; then
  t12_fail="$t12_fail 12 missing wrap-lite"
fi
if ! grep -Fq '[ "$ORCH_TIER" = "null" ]' "$STEPS/02-scope.md"; then
  t12_fail="$t12_fail 02 missing null-test"
fi
if ! grep -q 'S → light' "$STEPS/02-scope.md"; then
  t12_fail="$t12_fail 02 missing S→light"
fi
if [ -z "$t12_fail" ]; then ok
else bad "T12 light-branch:$t12_fail"; fi

# ---- T13: CDT-242 Recommended-agent legal set includes devops and ds (06 + 07) ----
t13_fail=""
for f in 06-design.md 07-tasks.md; do
  if ! grep -qE 'Recommended agent: <ic4\|ic5\|qa\|devops\|ds>' "$STEPS/$f"; then
    t13_fail="$t13_fail $f"
  fi
done
if [ -z "$t13_fail" ]; then ok
else bad "T13 Recommended-agent devops|ds missing:$t13_fail"; fi

# ---- T14: CDT-244 Step 6c + classifier (AC8) ----
# 06-design.md: Step 6c, /council --plan, flavors/security.md
# kickoff SKILL: token list + ticket_class emit; MUST NOT invoke /council
# orchestrate SKILL / 00-resolve / parse-flags: no --security flag
KICKOFF="$ROOT/skills/kickoff/SKILL.md"
PARSE="$ROOT/skills/autopilot/parse-flags.sh"
t14_fail=""
if ! grep -q 'Step 6c' "$STEPS/06-design.md"; then
  t14_fail="$t14_fail 06 missing Step 6c"
fi
if ! grep -q '/council --plan' "$STEPS/06-design.md"; then
  t14_fail="$t14_fail 06 missing /council --plan"
fi
if ! grep -q 'flavors/security.md' "$STEPS/06-design.md"; then
  t14_fail="$t14_fail 06 missing flavors/security.md"
fi
for tok in auth-secrets oauth oidc jwt csrf pii ssn apikey 'private key' 'api key' ticket_class; do
  if ! grep -qF -- "$tok" "$KICKOFF"; then
    t14_fail="$t14_fail kickoff missing token:$tok"
  fi
done
if ! grep -q 'MUST NOT invoke' "$KICKOFF"; then
  t14_fail="$t14_fail kickoff missing MUST NOT invoke"
fi
if grep -qE '/council --plan|/council "' "$KICKOFF"; then
  t14_fail="$t14_fail kickoff invokes /council"
fi
for f in "$SKILL" "$STEPS/00-resolve.md" "$PARSE"; do
  if grep -q -- '--security' "$f"; then
    t14_fail="$t14_fail --security in $(basename "$f")"
  fi
done
if [ -z "$t14_fail" ]; then ok
else bad "T14 AC8:$t14_fail"; fi

# ---- T15: CDT-244 council Phase 2 flavor-append (AC9) ----
COUNCIL="$ROOT/commands/council.md"
t15_fail=""
if ! grep -q 'Phase 2' "$COUNCIL"; then
  t15_fail="$t15_fail missing Phase 2"
fi
if ! grep -qiE 'MAY append.*plan\.flavors|append flavor names to `?plan\.flavors' "$COUNCIL"; then
  t15_fail="$t15_fail missing MAY append plan.flavors"
fi
if ! grep -qi 'output_shape_constraint' "$COUNCIL"; then
  t15_fail="$t15_fail missing output_shape_constraint"
fi
if ! grep -qiE 'investigator\.md output schema always wins' "$COUNCIL"; then
  t15_fail="$t15_fail missing investigator schema wins"
fi
if [ -z "$t15_fail" ]; then ok
else bad "T15 AC9:$t15_fail"; fi



# ---- T16: WP 1-07 AC D — Step 7 task-graph protocol lives in one file ----
TASK_GRAPH="$HERE/task-graph.md"
t16_fail=""
if [ ! -f "$TASK_GRAPH" ]; then
  t16_fail="$t16_fail missing task-graph.md"
else
  if ! grep -q 'skills/orchestrate/task-graph.md' "$STEPS/07-tasks.md"; then
    t16_fail="$t16_fail 07-tasks.md missing task-graph.md path citation"
  fi
  if ! grep -q 'skills/orchestrate/task-graph.md' "$ROOT/skills/kickoff/SKILL.md"; then
    t16_fail="$t16_fail kickoff/SKILL.md missing task-graph.md path citation"
  fi
  if grep -qF '"$TASK_STORE" create' "$STEPS/07-tasks.md"; then
    t16_fail="$t16_fail 07-tasks.md still holds \"\$TASK_STORE\" create"
  fi
  if grep -qF '"$TASK_STORE" create' "$ROOT/skills/kickoff/SKILL.md"; then
    t16_fail="$t16_fail kickoff/SKILL.md still holds \"\$TASK_STORE\" create"
  fi
  if grep -q 'check-cycle' "$STEPS/07-tasks.md"; then
    t16_fail="$t16_fail 07-tasks.md still holds check-cycle"
  fi
  if grep -q 'check-cycle' "$ROOT/skills/kickoff/SKILL.md"; then
    t16_fail="$t16_fail kickoff/SKILL.md still holds check-cycle"
  fi
  if ! grep -qF '"$TASK_STORE" create' "$TASK_GRAPH"; then
    t16_fail="$t16_fail task-graph.md missing \"\$TASK_STORE\" create call"
  fi
  if ! grep -q -- '--plan-ordinal' "$TASK_GRAPH" || ! grep -q -- '--taskcreate-id' "$TASK_GRAPH"; then
    t16_fail="$t16_fail task-graph.md missing --plan-ordinal/--taskcreate-id"
  fi
  p1_line=$(grep -n '^## Phase 1' "$TASK_GRAPH" | head -n1 | cut -d: -f1)
  p2_line=$(grep -n '^## Phase 2' "$TASK_GRAPH" | head -n1 | cut -d: -f1)
  if [ -z "$p1_line" ] || [ -z "$p2_line" ] || [ "$p1_line" -ge "$p2_line" ]; then
    t16_fail="$t16_fail task-graph.md Phase 1 does not precede Phase 2"
  fi
  for f in "$STEPS/07-tasks.md" "$ROOT/skills/kickoff/SKILL.md" "$TASK_GRAPH"; do
    if grep -qF '<ISSUE-ID>-N' "$f"; then
      t16_fail="$t16_fail $(basename "$f") maps Task N to <ISSUE-ID>-N"
    fi
  done
  for f in "$STEPS/07-tasks.md" "$ROOT/skills/kickoff/SKILL.md" "$TASK_GRAPH"; do
    if grep -qiE 're-?mark[a-z]* (every|each|the)? ?dependents? as ready' "$f"; then
      t16_fail="$t16_fail $(basename "$f") says a wrong dep key re-marks dependents as ready"
    fi
  done
fi
if [ -z "$t16_fail" ]; then ok
else bad "T16 AC D:$t16_fail"; fi

# ---- T17: WP 1-07 AC E — task-graph.md cycle pre-gate fences actually run ----
t17_fail=""
if [ ! -f "$TASK_GRAPH" ]; then
  t17_fail="missing task-graph.md"
else
  extract_fence() {
    # $1 = heading regex, $2 = file
    awk -v pat="$1" '
      $0 ~ pat { found=1 }
      found && /^```/ { c++; if (c==1) { inblock=1; next }; if (c==2) { exit } }
      inblock { print }
    ' "$2"
  }
  WRITE_FENCE=$(extract_fence '^## Cycle pre-gate . write fence' "$TASK_GRAPH")
  CHECK_FENCE=$(extract_fence '^## Cycle pre-gate . check fence' "$TASK_GRAPH")
  if [ -z "$WRITE_FENCE" ] || [ -z "$CHECK_FENCE" ]; then
    t17_fail="could not extract both fences by heading"
  else
    T17_TMP=$(mktemp -d "${TMPDIR:-/tmp}/router-t17.XXXXXX")
    (
      cd "$T17_TMP" || exit 1
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q .
      mkdir -p skills
      : > skills/plugin-dir.sh
      chmod +x skills/plugin-dir.sh
      run_pair() {
        # $1 = fixture JSON (single line), $2 = write-fence text, $3 = check-fence text
        w=$(printf '%s\n' "$2" | sed \
          -e 's/<ISSUE-ID>/T-1/g' \
          -e "s#<JSON array:.*#$1#")
        c=$(printf '%s\n' "$3" | sed \
          -e 's/<ISSUE-ID>/T-1/g' \
          -e 's/<Kickoff|Orchestrate>/Test/g')
        printf '%s\n' "$w" > w.sh
        printf '%s\n' "$c" > c.sh
        timeout 20 env CLAUDE_PLUGIN_ROOT="$ROOT" bash w.sh || return 90
        timeout 20 env CLAUDE_PLUGIN_ROOT="$ROOT" bash c.sh
      }
      run_pair '[{"task_id":"1","depends_on":[]},{"task_id":"2","depends_on":["1"]}]' "$WRITE_FENCE" "$CHECK_FENCE" > acyclic.out 2>&1
      echo "acyclic_rc=$?" >> acyclic.out
      run_pair '[{"task_id":"1","depends_on":["2"]},{"task_id":"2","depends_on":["1"]}]' "$WRITE_FENCE" "$CHECK_FENCE" > cyclic.out 2>&1
      echo "cyclic_rc=$?" >> cyclic.out
      cat acyclic.out cyclic.out > "$T17_TMP/combined.out"
    )
    ACY_RC=$(grep -o 'acyclic_rc=[0-9]*' "$T17_TMP/combined.out" 2>/dev/null | cut -d= -f2)
    CYC_RC=$(grep -o 'cyclic_rc=[0-9]*' "$T17_TMP/combined.out" 2>/dev/null | cut -d= -f2)
    if [ "$ACY_RC" != "0" ]; then
      t17_fail="$t17_fail acyclic-case-rc=$ACY_RC"
    fi
    if [ -z "$CYC_RC" ] || [ "$CYC_RC" = "0" ]; then
      t17_fail="$t17_fail cyclic-case-did-not-fail(rc=$CYC_RC)"
    fi
    if ! grep -q 'circular dependency detected' "$T17_TMP/combined.out"; then
      t17_fail="$t17_fail missing 'circular dependency detected'"
    fi
    if ! grep -q 'cycle:' "$T17_TMP/combined.out"; then
      t17_fail="$t17_fail missing 'cycle:' text"
    fi
    rm -rf "$T17_TMP"
  fi
fi
if [ -z "$t17_fail" ]; then ok
else bad "T17 AC E:$t17_fail"; fi

# ---- T18: WP 1-07 AC F — check-fence branches print + exit; no "# halt" stand-in ----
t18_fail=""
if [ ! -f "$TASK_GRAPH" ]; then
  t18_fail="missing task-graph.md"
else
  if ! grep -q 'circular dependency detected' "$TASK_GRAPH"; then
    t18_fail="$t18_fail missing circular-dependency message"
  fi
  if ! grep -q 'cycle gate could not run' "$TASK_GRAPH"; then
    t18_fail="$t18_fail missing cycle-gate-could-not-run message"
  fi
  if ! grep -qE '^[[:space:]]*exit ' "$TASK_GRAPH"; then
    t18_fail="$t18_fail missing an actual exit statement"
  fi
  if grep -qF '# halt' "$TASK_GRAPH"; then
    t18_fail="$t18_fail '# halt' comment stands in for exit"
  fi
  if ! grep -qi 'Do NOT call TaskCreate' "$TASK_GRAPH"; then
    t18_fail="$t18_fail prose does not forbid TaskCreate after a halt"
  fi
fi
if [ -z "$t18_fail" ]; then ok
else bad "T18 AC F:$t18_fail"; fi

# ---- T19: WP 1-07 AC M — 08-execute ready-set --issue; mirror lives in cross-cutting.md ----
t19_fail=""
if ! grep -qF 'ready-set --issue' "$STEPS/08-execute.md"; then
  t19_fail="$t19_fail 08-execute.md missing ready-set --issue"
fi
if grep -qE 'ready-set)[[:space:]]*$' "$STEPS/08-execute.md"; then
  t19_fail="$t19_fail 08-execute.md still calls bare ready-set (no --issue)"
fi
if grep -qF '"$TASK_STORE" update-status' "$STEPS/09-review.md"; then
  t19_fail="$t19_fail 09-review.md still holds the task-store mirror fence"
fi
if ! grep -qF '"$TASK_STORE" update-status' "$STEPS/cross-cutting.md"; then
  t19_fail="$t19_fail cross-cutting.md missing the task-store mirror fence"
fi
STANDUP_SKILL="$ROOT/skills/standup/SKILL.md"
if [ -f "$STANDUP_SKILL" ]; then
  standup_calls=$(grep -nF 'bash "$DAG_LIB" ready-set' "$STANDUP_SKILL")
  if [ -z "$standup_calls" ]; then
    t19_fail="$t19_fail standup/SKILL.md missing a dag-lib.sh ready-set call"
  elif printf '%s\n' "$standup_calls" | grep -q -- '--issue'; then
    t19_fail="$t19_fail standup/SKILL.md ready-set call passes --issue (must stay cross-issue)"
  fi
fi
if [ -z "$t19_fail" ]; then ok
else bad "T19 AC M:$t19_fail"; fi

# ---- T20: WP 1-07 AC N — ship window record ----
t20_fail=""
SHIP="$STEPS/11-ship.md"
squash_block=$(awk '/^cd <main-repo-path>$/{print; f=1; next} f{print} f && /^git merge --squash <branch>$/{exit}' "$SHIP")
if ! printf '%s\n' "$squash_block" | grep -qF 'SHIP_START=$(git rev-parse HEAD)'; then
  t20_fail="$t20_fail squash fence missing SHIP_START=\$(git rev-parse HEAD)"
fi
if ! printf '%s\n' "$squash_block" | grep -qF 'echo "SHIP_START=$SHIP_START"'; then
  t20_fail="$t20_fail squash fence missing echo SHIP_START=\$SHIP_START"
fi
cd_line=$(printf '%s\n' "$squash_block" | grep -n 'cd <main-repo-path>' | tail -n1 | cut -d: -f1)
start_line=$(printf '%s\n' "$squash_block" | grep -n 'SHIP_START=\$(git rev-parse HEAD)' | tail -n1 | cut -d: -f1)
merge_line=$(printf '%s\n' "$squash_block" | grep -n 'git merge --squash <branch>' | tail -n1 | cut -d: -f1)
if [ -n "$cd_line" ] && [ -n "$start_line" ] && [ -n "$merge_line" ]; then
  if [ "$start_line" -le "$cd_line" ] || [ "$merge_line" -le "$start_line" ]; then
    t20_fail="$t20_fail SHIP_START not between cd and squash"
  fi
else
  t20_fail="$t20_fail could not locate cd/SHIP_START/squash lines"
fi
if ! awk '/^```bash template$/{tag=NR} /CHECK_SHIP=/{print tag; exit}' "$SHIP" | grep -qv '^$'; then
  t20_fail="$t20_fail ship-history check fence not tagged bash template"
fi
if ! grep -qF 'SHIP_START="<SHIP_START>"' "$SHIP"; then
  t20_fail="$t20_fail check fence missing SHIP_START=\"<SHIP_START>\""
fi
if grep -qF '${SHIP_START:-' "$SHIP"; then
  t20_fail="$t20_fail check fence reads \${SHIP_START:-...} from an earlier shell"
fi
if grep -n 'assert-release-allowed' "$SHIP" | grep -qiE 'on exit 64|exits 64'; then
  t20_fail="$t20_fail an assert-release-allowed line still says exit(s) 64"
fi
if [ -z "$t20_fail" ]; then ok
else bad "T20 AC N:$t20_fail"; fi

# ---- T21: WP 1-07 AC O — no "§ below/above"; Stint-end in cross-cutting.md; pointer paragraphs name their home file ----
t21_fail=""
if grep -lE '§ below|§ above' "$STEPS"/*.md >/dev/null 2>&1; then
  t21_fail="$t21_fail has section-below/above: $(grep -lE '§ below|§ above' "$STEPS"/*.md | xargs -n1 basename | tr '\n' ',')"
fi
if grep -q '### Stint-end outcome emit' "$STEPS/08-execute.md"; then
  t21_fail="$t21_fail Stint-end outcome emit block still in 08-execute.md"
fi
if ! grep -q '### Stint-end outcome emit' "$STEPS/cross-cutting.md"; then
  t21_fail="$t21_fail Stint-end outcome emit block missing from cross-cutting.md"
fi
for f in "$STEPS"/*.md; do
  base=$(basename "$f")
  bad_paras=$(awk -v basefile="$base" '
    BEGIN { para="" }
    /^[[:space:]]*$/ {
      if (para != "") check(para)
      para=""
      next
    }
    { para = para " " $0 }
    END { if (para != "") check(para) }
    function check(p) {
      if (basefile != "cross-cutting.md" \
          && (p ~ /Stint-end outcome emit/ || p ~ /Task-store status mirror/ || p ~ /Passive notifications/) \
          && p !~ /cross-cutting\.md/) {
        print "missing-cross-cutting"
      }
      if (basefile != "11-ship.md" && p ~ /Linear lifecycle/ && p !~ /11-ship\.md/) {
        print "missing-11-ship"
      }
    }
  ' "$f")
  if [ -n "$bad_paras" ]; then
    t21_fail="$t21_fail $base:$(printf '%s' "$bad_paras" | tr '\n' '+')"
  fi
done
if [ -z "$t21_fail" ]; then ok
else bad "T21 AC O:$t21_fail"; fi


# ---- Harness self-check: the suite defines 22 checks (T0-T21). A total
# below 22 means a check was skipped silently (stale copy of this file, an
# early return, or an environment-dependent short-circuit) — turn that into
# an explicit failure instead of a quietly-smaller PASS count.
EXPECTED_CHECKS=22
RUN_TOTAL=$((PASS + FAIL))
if [ "$RUN_TOTAL" -ne "$EXPECTED_CHECKS" ]; then
  bad "harness ran $RUN_TOTAL checks, expected $EXPECTED_CHECKS (a check did not run)"
fi
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
