#!/usr/bin/env bash
# kickoff/test-static.sh — WP 5-01 kickoff contract greps and tier map.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
DOCS="$ROOT/docs/commands/kickoff.md"
INIT="$ROOT/skills/init-orchestration/SKILL.md"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

if grep -qF 'echo "\n## Task Map' "$SKILL"; then
  bad "CDT-381 echo Task Map form still present"
else ok; fi

if grep -qF "printf '\\n## Task Map\\n\\n' >> \"\$MROOT/.claude/plans/<plan-file>.md\"" "$SKILL"; then ok
else bad "CDT-381 printf Task Map line missing"; fi

if grep -qF 'requires_council:' "$SKILL"; then ok
else bad "TaskCreate template missing requires_council"; fi

if grep -qF 'unknown --tier, or unknown --council-tier' "$SKILL"; then ok
else bad "exit-64 comment omits --tier / --council-tier"; fi

VERIFY=$(grep -cF 'Verify: bash <test file>' "$SKILL" || true)
if [ "${VERIFY:-0}" -ge 2 ]; then ok
else bad "kickoff writer pair lacks the Verify sentence (count=$VERIFY)"; fi

if grep -qF 'does not create a worktree' "$DOCS"; then
  bad "docs still say kickoff does not create a worktree"
else ok; fi

# CDT-373: plan home is absolute $MROOT/.claude/plans, not the worktree.
if grep -qF 'plan file (in the worktree)' "$SKILL"; then
  bad "Task Map still says the plan file is in the worktree"
else ok; fi
if grep -qF 'WRITES the spec, plan, or CONTEXT.md' "$SKILL"; then
  bad "WT_PATH write rule still includes the plan"
else ok; fi
if grep -qF 'The spec, plan, and CONTEXT.md live on' "$SKILL"; then
  bad "visibility paragraph still puts the plan on the ticket branch"
else ok; fi
if grep -qF 'spec/plan/CONTEXT.md work land on the ticket branch' "$SKILL"; then
  bad "Step 1b still lands the plan on the ticket branch"
else ok; fi
if grep -qF 'Write the plan only to absolute `$MROOT/.claude/plans`' "$SKILL"; then ok
else bad "WT_PATH section missing the absolute plan-home rule"; fi
if grep -qF 'Plan:   $MROOT/.claude/plans/' "$DOCS"; then ok
else bad "kickoff docs example plan path is not absolute \$MROOT"; fi
if grep -qF 'saved to absolute `$MROOT/.claude/plans/' "$DOCS"; then ok
else bad "kickoff docs step 6 plan path is not absolute \$MROOT"; fi
for needle in 'Step 1b' 'Step 4b' 'Worktree:' 'Branch:'; do
  if grep -qF "$needle" "$DOCS"; then ok
  else bad "docs/commands/kickoff.md missing $needle"; fi
done

# Tier map (markers absent on the old skill → fail).
MAP=$(awk '
  $0 == "# wp501-tier-map" { p = 1; next }
  $0 == "# /wp501-tier-map" { p = 0 }
  p { print }
' "$SKILL")
if [ -z "$MAP" ]; then
  bad "tier map markers missing"
else
  ok
  run_map() {
    local json=$1 script rc out
    script=$(mktemp "${TMPDIR:-/tmp}/kickoff-tier-map.XXXXXX")
    {
      echo '#!/usr/bin/env bash'
      printf 'AP_JSON=%q\n' "$json"
      printf '%s\n' "$MAP"
      echo 'printf "%s %s\n" "$KICKOFF_TIER" "${REQUIRES_COUNCIL:-}"'
    } > "$script"
    out=$(bash "$script" 2>"$script.err")
    rc=$?
    rm -f "$script" "$script.err"
    printf '%s\n' "$rc" "$out"
  }
  got=$(run_map '{"tier":"null","council_tier":"full"}')
  if [ "$(printf '%s\n' "$got" | head -n1)" -eq 0 ] \
    && [ "$(printf '%s\n' "$got" | tail -n1)" = "null true" ]; then ok
  else bad "council full should set requires_council true ($got)"; fi
  got=$(run_map '{"tier":"light","council_tier":"skip"}')
  if [ "$(printf '%s\n' "$got" | head -n1)" -eq 0 ] \
    && [ "$(printf '%s\n' "$got" | tail -n1)" = "light false" ]; then ok
  else bad "council skip should set requires_council false ($got)"; fi
  got=$(run_map '{"tier":"null","council_tier":"null"}')
  if [ "$(printf '%s\n' "$got" | head -n1)" -eq 0 ] \
    && [ "$(printf '%s\n' "$got" | tail -n1)" = "null false" ]; then ok
  else bad "omitted council tier should set requires_council false ($got)"; fi
  got=$(run_map '{"tier":"nope","council_tier":"null"}')
  if [ "$(printf '%s\n' "$got" | head -n1)" -eq 64 ]; then ok
  else bad "unknown --tier must exit 64 ($got)"; fi
  got=$(run_map '{"tier":"null","council_tier":"huge"}')
  if [ "$(printf '%s\n' "$got" | head -n1)" -eq 64 ]; then ok
  else bad "unknown --council-tier must exit 64 ($got)"; fi
fi

# parse-flags rejects an unknown --tier before kickoff reads JSON.
PARSE="$ROOT/skills/autopilot/parse-flags.sh"
if bash "$PARSE" --tier=nope >/dev/null 2>&1; then
  bad "parse-flags accepted --tier=nope"
else
  rc=$?
  if [ "$rc" -eq 64 ]; then ok
  else bad "parse-flags --tier=nope rc=$rc want 64"; fi
fi

# F25 prose. The Step 9 summary on the old file omits escalation-gate.sh.
SUM=$(awk '
  index($0, "### Step 9: Summary") == 1 { p = 1; next }
  p && /^## / { exit }
  p { print }
' "$INIT")
if printf '%s\n' "$SUM" | grep -qF 'escalation-gate.sh'; then ok
else bad "Step 9 summary omits escalation-gate.sh"; fi
if printf '%s\n' "$SUM" | grep -qF 'uncomment test runner'; then
  bad "Step 9 still says uncomment test runner"
else ok; fi
if grep -qF 'exits 0 by default' "$INIT"; then
  bad "init-orchestration still says exits 0 by default"
else ok; fi
if grep -qF 'taskcompleted-hook-spike.md' "$INIT"; then
  bad "spike-plan path still cited"
else ok; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
