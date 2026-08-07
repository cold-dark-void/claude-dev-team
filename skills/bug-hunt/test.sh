#!/usr/bin/env bash
# skills/bug-hunt/test.sh — CDT-136 T1–T16 + CDT-138 T6 C3 + CDT-139 T6 C4
# + CDT-137 C5 surface/docs smoke. Static contracts (SPEC-034 T1–T26 +
# skill/command/docs). Greps committed prompt/docs only — no network, no LLM,
# no live hunt.
# Run: bash skills/bug-hunt/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/bug-hunt.md"
SKILL="$ROOT/skills/bug-hunt/SKILL.md"
SPEC="$ROOT/specs/core/SPEC-034-bug-hunt-workflow.md"
DOCS="$ROOT/docs/commands/bug-hunt.md"
GITIGNORE="$ROOT/.gitignore"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"
FMT="$ROOT/skills/spec-tooling/check-format.sh"
MARKER='self-verified — refuters unavailable'

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

has() {
  # has <file> <pattern> <label>
  local f="$1" pat="$2" label="$3"
  if grep -qE -- "$pat" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (/$pat/ not in $f)"
  fi
}

has_f() {
  # has_f <file> <fixed-string> <label>
  local f="$1" s="$2" label="$3"
  if grep -qF -- "$s" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (fixed string missing in $f)"
  fi
}

# ---- T-pre: surfaces present ------------------------------------------------
if [ -f "$CMD" ]; then ok "commands/bug-hunt.md exists"; else bad "commands/bug-hunt.md missing"; fi
if [ -f "$SKILL" ]; then ok "skills/bug-hunt/SKILL.md exists"; else bad "skills/bug-hunt/SKILL.md missing"; fi
if [ -f "$SPEC" ]; then ok "SPEC-034 exists"; else bad "SPEC-034 missing"; fi

# ---- Frontmatter (YAML name + description) ----------------------------------
fm_ok() {
  local f="$1" label="$2"
  # Starts with ---; has name: and description: before closing ---
  if awk '
    BEGIN { in_fm=0; has_name=0; has_desc=0; closed=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { closed=1; exit }
    in_fm && /^name:[[:space:]]/ { has_name=1 }
    in_fm && /^description:[[:space:]]/ { has_desc=1 }
    END { exit (closed && has_name && has_desc) ? 0 : 1 }
  ' "$f"; then
    ok "$label frontmatter name+description"
  else
    bad "$label missing YAML frontmatter (name/description)"
  fi
}
[ -f "$CMD" ] && fm_ok "$CMD" "command"
[ -f "$SKILL" ] && fm_ok "$SKILL" "skill"

has "$CMD" '^name:[[:space:]]*bug-hunt' "command name: bug-hunt"
has "$SKILL" '^name:[[:space:]]*bug-hunt' "skill name: bug-hunt"

# ---- SKILL stage headers + contracts ----------------------------------------
has "$SKILL" '## Step S0:' "SKILL Step S0"
has "$SKILL" '## Step S1:' "SKILL Step S1"
has "$SKILL" '## Step S2:' "SKILL Step S2"
has "$SKILL" '## Step REPORT:' "SKILL Step REPORT"

has_f "$SKILL" 'confirmed_actionable' "SKILL confirmed_actionable"
has_f "$SKILL" "$MARKER" "SKILL self-verified marker"

# C3 flip: C2 "MUST NOT materialize" → proceed-gated + no stage-4/fix
has_f "$SKILL" 'MUST NOT materialize without proceed' \
  "SKILL MUST NOT materialize without proceed (C3)"
has "$SKILL" 'MUST NOT fix|/orchestrate|/epic|stage-4' \
  "SKILL MUST NOT fix/stage-4/orchestrate"

# Hard walls + compose cites
has_f "$SKILL" '.claude/bug-hunt' "SKILL report dir"
has "$SKILL" 'severity-floor|BH_FLOOR' "SKILL severity-floor"
has "$SKILL" 'Blind-review|blind path|blind-path' "SKILL discover blind compose"
has "$SKILL" 'investigator' "SKILL refute investigator compose"
has_f "$CMD" "$MARKER" "command self-verified marker"
has "$CMD" 'MUST NOT|no backlog materialize without|Hard walls' "command hard walls"
has_f "$CMD" 'skills/bug-hunt/SKILL.md' "command points at skill"

# Templates (T5 + C3 findings-plan + C4 phase handoff)
if [ -f "$HERE/templates/report.md" ]; then ok "templates/report.md exists"
else bad "templates/report.md missing"; fi
if [ -f "$HERE/templates/findings.json" ]; then ok "templates/findings.json exists"
else bad "templates/findings.json missing"; fi
if [ -f "$HERE/templates/findings-plan.md" ]; then ok "templates/findings-plan.md exists"
else bad "templates/findings-plan.md missing"; fi
if [ -f "$HERE/templates/phase-plan.md" ]; then ok "templates/phase-plan.md exists"
else bad "templates/phase-plan.md missing"; fi
if [ -f "$HERE/templates/handoff-phase.md" ]; then ok "templates/handoff-phase.md exists"
else bad "templates/handoff-phase.md missing"; fi

# ---- .gitignore -------------------------------------------------------------
if [ -f "$GITIGNORE" ] && grep -qE '^\.claude/bug-hunt/?$' "$GITIGNORE"; then
  ok ".gitignore has .claude/bug-hunt/"
else
  bad ".gitignore missing .claude/bug-hunt/"
fi

# ---- SPEC-034 T1–T16 (static rg / format) -----------------------------------
# T1 Status DRAFT
has "$SPEC" '^\*\*Status\*\*: DRAFT$' "T1 Status DRAFT"
# T2 Category/Created
has_f "$SPEC" '**Category**: core' "T2 Category core"
has_f "$SPEC" '**Created**: 2026-08-06' "T2 Created 2026-08-06"
# T3 See also
for id in SPEC-013 SPEC-009 SPEC-014 SPEC-025 SPEC-017; do
  has_f "$SPEC" "$id" "T3 cites $id"
done
# T4 Surface
has_f "$SPEC" '/bug-hunt' "T4 /bug-hunt"
has_f "$SPEC" '--severity-floor' "T4 --severity-floor"
has "$SPEC" 'critical' "T4 critical"
has "$SPEC" 'warning' "T4 warning"
has "$SPEC" 'nitpick' "T4 nitpick"
# T5 Stages
has "$SPEC" 'discover' "T5 discover"
has "$SPEC" 'refute' "T5 refute"
has "$SPEC" 'materialize' "T5 materialize"
has "$SPEC" 'handoff' "T5 handoff"
# T6 Locks
has "$SPEC" 'proceed|explicit user' "T6 proceed/materialize lock language"
has "$SPEC" 'fix-phase 0|start fix-phase' "T6 start fix-phase 0"
has "$SPEC" 'no inter-stage user lock|MUST NOT place a user lock|Discover↔refute continuous|no user lock' \
  "T6 no discover↔refute lock"
# T7 Finding model
for f in locator severity description evidence; do
  has_f "$SPEC" "$f" "T7 field $f"
done
has "$SPEC" 'status=confirmed|status.*confirmed' "T7 status=confirmed"
has_f "$SPEC" 'candidate' "T7 candidate"
has_f "$SPEC" 'refuted' "T7 refuted"
has_f "$SPEC" 'confirmed' "T7 confirmed"
# T8 Floor
has "$SPEC" 'below-floor|below the active|never materialize' "T8 below-floor"
has "$SPEC" 'default.*nitpick|omitted.*nitpick|nitpick' "T8 default nitpick"
# T9 Composition
has_f "$SPEC" 'SPEC-013' "T9 SPEC-013"
has_f "$SPEC" 'SPEC-009' "T9 SPEC-009"
has_f "$SPEC" '/orchestrate' "T9 /orchestrate"
has_f "$SPEC" '/epic' "T9 /epic"
# T10 Matrix + non-goals
for s in '/bug-hunt' '/debug' '/council' '/backlog' '/epic' '/orchestrate'; do
  has_f "$SPEC" "$s" "T10 matrix $s"
done
has "$SPEC" 'auto-fix|MUST NOT auto-fix' "T10 no auto-fix"
has "$SPEC" 'mass-create|silently mass-create' "T10 no silent mass-create"
# T11 Format
if [ -f "$FMT" ]; then
  if bash "$FMT" "$SPEC" >/dev/null 2>&1; then ok "T11 check-format exit 0"
  else bad "T11 check-format failed"; fi
else
  bad "T11 check-format.sh missing"
fi
# T12 M31 report path
has "$SPEC" 'M31|\.claude/bug-hunt' "T12 M31/.claude/bug-hunt"
# T13 M32 confirmed_actionable
has "$SPEC" 'M32|confirmed_actionable' "T13 M32/confirmed_actionable"
# T14 M33 discover compose
has "$SPEC" 'M33|blind' "T14 M33/blind"
# T15 M34 refute compose
has "$SPEC" 'M34|investigator' "T15 M34/investigator"
# T16 Covers surface presence (runtime landed)
if [ -f "$CMD" ] && [ -f "$SKILL" ]; then ok "T16 command+skill present"
else bad "T16 missing command or skill"; fi

# ---- CDT-138 C3 contracts (T6 / SPEC T17–T21) --------------------------------
# Plan path -plan.md (AC3 / M39 / OQ1)
has "$SKILL" '-plan\.md' "C3 skill plan path -plan.md"
has_f "$SKILL" 'BH_PLAN' "C3 skill BH_PLAN binding"
has "$CMD" '-plan\.md' "C3 command plan path -plan.md"

# M8 proceed forms (AC4 / OQ2): --proceed flag + typed proceed token
has_f "$SKILL" '--proceed' "C3 skill --proceed flag"
has "$SKILL" 'typed `proceed`|typed proceed|token `proceed`' "C3 skill typed proceed token"
has_f "$CMD" '--proceed' "C3 command --proceed flag"
has "$CMD" 'typed `proceed`|typed proceed' "C3 command typed proceed"

# Programmatic write-back cite (AC5 / M40) — no dual-write fork
has_f "$SKILL" 'Programmatic write-back' "C3 skill Programmatic write-back cite"
has_f "$SKILL" 'skills/backlog/SKILL.md' "C3 skill cites backlog SKILL"
has_f "$SKILL" 'MUST NOT dual-write fork' "C3 skill no dual-write fork"

# M22 phase-done (AC9)
has_f "$SKILL" 'phase-done: materialize — findings plan + bh-quality backlog (M22)' \
  "C3 skill M22 phase-done materialize"
has_f "$SKILL" 'phase-done: materialize — 0 creates (M22)' \
  "C3 skill M22 zero-create phase-done"

# AC10 zero actionable → 0 creates
has_f "$SKILL" '0 confirmed-actionable' "C3 skill AC10 0 confirmed-actionable"
has "$SKILL" '0 creates|zero creates|A==0' "C3 skill AC10 zero creates path"

# S3 step headers present
has "$SKILL" '## Step S3a:|### Step S3a:|## S3a |S3a LOAD' "C3 skill S3a LOAD"
has "$SKILL" 'S3c PLAN|S3c ' "C3 skill S3c PLAN"
has "$SKILL" 'S3d PROCEED|S3d ' "C3 skill S3d PROCEED"
has "$SKILL" 'S3e MATERIALIZE|S3e ' "C3 skill S3e MATERIALIZE"
has "$SKILL" 'S3g PHASE-DONE|S3g ' "C3 skill S3g PHASE-DONE"

# Resume materialize surface
has "$SKILL" 'materialize <' "C3 skill materialize resume usage"
has "$CMD" 'materialize <' "C3 command materialize resume usage"

# SPEC M38–M41 (T18–T21)
has_f "$SPEC" 'M38' "T18 SPEC M38"
has_f "$SPEC" 'M39' "T19 SPEC M39"
has_f "$SPEC" 'M40' "T20 SPEC M40"
has_f "$SPEC" 'M41' "T21 SPEC M41"
has "$SPEC" '-plan\.md' "T19 SPEC -plan.md path"
has "$SPEC" 'programmatic write-back|Programmatic write-back' "T20 SPEC programmatic write-back"
has "$SPEC" 'idempotent' "T21 SPEC idempotent re-materialize"
has_f "$SPEC" '--proceed' "T21 SPEC --proceed"

# ---- CDT-139 C4 contracts (T6 / SPEC T22–T26) --------------------------------
# Handoff surface + resume (AC1 / M42)
has "$SKILL" 'handoff <' "C4 skill handoff resume usage"
has "$CMD" 'handoff <' "C4 command handoff resume usage"
has_f "$SKILL" 'BH_HANDOFF_PATH' "C4 skill BH_HANDOFF_PATH binding"
has_f "$SKILL" 'BH_PHASE_PLAN' "C4 skill BH_PHASE_PLAN binding"
has "$SKILL" '-phase-plan\.md' "C4 skill phase-plan path"
has "$SKILL" 'handoff-phase' "C4 skill handoff-phase path"
has "$CMD" 'handoff' "C4 command handoff surface"

# M9 / M46 start-phase forms (AC5 / OQ5): --start-phase flag + typed token
has_f "$SKILL" '--start-phase' "C4 skill --start-phase flag"
has "$SKILL" 'start-phase-<n>|typed `start-phase|typed start-phase' \
  "C4 skill typed start-phase token"
has_f "$CMD" '--start-phase' "C4 command --start-phase flag"
has "$CMD" 'start-phase-<n>|typed `start-phase|typed start-phase' \
  "C4 command typed start-phase"

# M18 / M45 route rule (AC4): /orchestrate default; /epic when phase_count≥2 ∧ item_count≥2
has_f "$SKILL" 'BH_ROUTE' "C4 skill BH_ROUTE binding"
has "$SKILL" 'phase_count.*2|/epic|M45' "C4 skill M45 epic rule"
has "$SKILL" '/orchestrate' "C4 skill /orchestrate route"
has "$SKILL" '/epic' "C4 skill /epic route"
has_f "$SPEC" 'M18' "C4 SPEC M18 handoff routing"
has "$SPEC" 'phase_count' "C4 SPEC phase_count route rule"

# M23 phase-done full + zero (AC7 / M48)
has_f "$SKILL" 'phase-done: handoff — resume identity + phase templates (M23)' \
  "C4 skill M23 phase-done handoff"
has_f "$SKILL" 'phase-done: handoff — 0 phases (M23)' \
  "C4 skill M23 zero-path phase-done"

# MUST NOT invoke orch/epic + emit-only walls (AC9 / N12 / N13)
has_f "$SKILL" 'MUST NOT invoke engines / fix' \
  "C4 skill MUST NOT invoke engines / fix"
has "$SKILL" 'MUST NOT invoke.*/orchestrate|MUST NOT invoke.*/epic|MUST NOT invoke engines' \
  "C4 skill MUST NOT invoke /orchestrate|/epic"
has_f "$SKILL" 'emit-only' "C4 skill emit-only"
has "$CMD" 'emit-only|MUST NOT invoke' "C4 command emit-only / MUST NOT invoke"
has_f "$SKILL" 'MUST NOT re-enter S1–S3 invent during handoff' \
  "C4 skill N13 no re-S1–S3 invent"

# S4 step headers present
has "$SKILL" '## Step S4:|S4a LOAD' "C4 skill S4 / S4a LOAD"
has "$SKILL" 'S4b BAND|S4b ' "C4 skill S4b BAND"
has "$SKILL" 'S4c ROUTE|S4c ' "C4 skill S4c ROUTE"
has "$SKILL" 'S4d WRITE|S4d ' "C4 skill S4d WRITE"
has "$SKILL" 'S4e LOCK|S4e ' "C4 skill S4e LOCK"
has "$SKILL" 'S4f ARM|S4f ' "C4 skill S4f ARM"
has "$SKILL" 'S4g PHASE-DONE|S4g ' "C4 skill S4g PHASE-DONE"

# Template field contracts (M44 / M47)
TPL_PP="$HERE/templates/phase-plan.md"
TPL_HP="$HERE/templates/handoff-phase.md"
if [ -f "$TPL_PP" ]; then
  for f in hunt_stem plan_path route phase_count item_count; do
    has_f "$TPL_PP" "$f" "C4 phase-plan field $f"
  done
fi
if [ -f "$TPL_HP" ]; then
  for f in phase_id hunt_stem plan_path route band goal invocation_hint \
           closed_count residual_criticals signoff; do
    has_f "$TPL_HP" "$f" "C4 handoff-phase field $f"
  done
fi

# SPEC M42–M48 (T22–T26)
has_f "$SPEC" 'M42' "T22 SPEC M42"
has_f "$SPEC" 'M43' "T23 SPEC M43"
has_f "$SPEC" 'M44' "T24 SPEC M44"
has_f "$SPEC" 'M45' "T25 SPEC M45"
has_f "$SPEC" 'M46' "T25 SPEC M46"
has_f "$SPEC" 'M47' "T24 SPEC M47"
has_f "$SPEC" 'M48' "T26 SPEC M48"
has_f "$SPEC" 'M23' "T26 SPEC M23"
has "$SPEC" 'start-phase' "T25 SPEC start-phase lock forms"
has "$SPEC" 'emit-only' "T26 SPEC emit-only"
has "$SPEC" 'N12|N13' "T26 SPEC N12/N13 walls"
has "$SPEC" 'phase-plan|handoff-phase' "T24 SPEC phase artifacts"
has "$SPEC" 'residual_criticals|closed_count|signoff' "T24 SPEC exit metrics"

# ---- CDT-137 C5 surface + docs smoke (static; no live hunt) -----------------
# AC1 frontmatter already covered above; re-assert command discoverability shape.
has "$CMD" '^name:[[:space:]]*bug-hunt' "C5 command frontmatter name"
has "$CMD" '^description:' "C5 command frontmatter description"
has "$CMD" 'argument-hint:' "C5 command argument-hint"

# AC2 path + severity floor; loud fail invalid (exit 64)
has_f "$CMD" '--severity-floor' "C5 command --severity-floor"
has_f "$SKILL" '--severity-floor' "C5 skill --severity-floor"
has "$CMD" 'exit 64|fails loud|loud fail' "C5 command loud-fail language"
has "$SKILL" 'exit 64' "C5 skill exit 64 on invalid"
has "$SKILL" 'invalid --severity-floor|want critical\|warning\|nitpick' \
  "C5 skill invalid floor message"
has "$SKILL" 'path does not exist|outside project|unreadable|non-existent' \
  "C5 skill path fail language"

# AC3 thin entry drives S0→S4 via skill (C2→C3→C4 sequence)
has_f "$CMD" 'skills/bug-hunt/SKILL.md' "C5 command thin host → skill"
has "$CMD" 'S0 parse|S1 discover|S2 refute|S3 plan|S4 phase' \
  "C5 command sequence pointer S0–S4"
has "$CMD" 'Step 1: Follow the skill|execute it end-to-end' \
  "C5 command Step 1 follow skill"
has "$SKILL" '## Step S0:|## Step S1:|## Step S2:|## Step REPORT:' \
  "C5 skill S0–S2+REPORT steps"
has "$SKILL" 'S3a LOAD|S3c PLAN|S3e MATERIALIZE' "C5 skill S3 pipeline"
has "$SKILL" 'S4a LOAD|S4d WRITE|S4g PHASE-DONE' "C5 skill S4 pipeline"

# AC4 docs page sections
if [ -f "$DOCS" ]; then ok "C5 docs/commands/bug-hunt.md exists"
else bad "C5 docs/commands/bug-hunt.md missing"; fi
has "$DOCS" '## When to use' "C5 docs When to use"
has "$DOCS" '## Arguments' "C5 docs Arguments"
has "$DOCS" '## Stages 1–4' "C5 docs Stages"
has "$DOCS" '## Outputs' "C5 docs Outputs"
has "$DOCS" '## Locks and hard walls' "C5 docs Locks"
has "$DOCS" '## Non-goals' "C5 docs Non-goals"
has "$DOCS" '## Smoke' "C5 docs Smoke section"
has_f "$DOCS" '/debug' "C5 docs vs /debug"
has_f "$DOCS" '/council' "C5 docs vs /council"
has_f "$DOCS" '/orchestrate' "C5 docs vs /orchestrate"
has_f "$DOCS" '-plan.md' "C5 docs plan path"
has "$DOCS" 'handoff-phase|phase-plan' "C5 docs phase handoff stubs"
has "$DOCS" 'backlog' "C5 docs backlog outputs"

# AC5 roster/docs-hub (README rows already required by docs-drift; static assert)
has "$ROOT/README.md" 'bug-hunt' "C5 README surfaces /bug-hunt"
has "$ROOT/docs/README.md" 'bug-hunt' "C5 docs hub links bug-hunt"

# AC6 smoke: narrow-path invocation shape → plan + ≥0 backlog + phase stubs; no fixes
has_f "$CMD" 'Narrow-path smoke shape' "C5 command narrow-path smoke note"
has_f "$DOCS" '/bug-hunt skills/bug-hunt' "C5 docs narrow-path example"
has "$SKILL" 'BH_PLAN|-plan\.md' "C5 skill plan path product"
has "$SKILL" 'BH_PHASE_PLAN|phase-plan' "C5 skill phase-plan product"
has "$SKILL" 'handoff-phase' "C5 skill handoff-phase product"
has "$SKILL" '0 creates|zero creates|A==0' "C5 skill ≥0 backlog (zero path)"
has_f "$SKILL" 'MUST NOT invoke engines / fix' "C5 skill no-fix wall"
has "$CMD" 'MUST NOT invoke|/orchestrate|/epic|edit product code' \
  "C5 command no-fix / no-engine wall"
has "$DOCS" 'no product-code|MUST NOT invoke|/orchestrate' \
  "C5 docs no-fix smoke non-products"
has_f "$DOCS" 'Hard non-products of smoke' "C5 docs smoke non-products header"

# ---- skill-lint (unwaived findings fail) ------------------------------------
if [ -f "$LINT" ]; then
  set +e
  LINT_OUT=$(bash "$LINT" "$CMD" "$SKILL" 2>&1)
  LINT_RC=$?
  set -e
  if [ "$LINT_RC" -eq 0 ]; then
    ok "skill-lint clean (exit 0)"
  else
    # Allow only plan-noted residual waivers already marked lint-ok; unwaived = fail
    bad "skill-lint exit $LINT_RC (want 0 — unwaived findings):"
    echo "$LINT_OUT" | head -20
  fi
else
  bad "check-skill-bash.sh missing"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
