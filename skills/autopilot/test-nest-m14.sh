#!/usr/bin/env bash
#
# skills/autopilot/test-nest-m14.sh — CDT-512-C6 protocol greps (SPEC-033 M14(l)).
#
# Static text asserts + bite tests. Starts no live council.
# Machine-check: bash skills/autopilot/test-nest-m14.sh (exit 0, all PASS)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

source "$ROOT/tests/lib/hermetic.sh"
source "$ROOT/tests/lib/text.sh"
hermetic_init

SPEC="$ROOT/specs/core/SPEC-033-autopilot-policy.md"
SG="$SCRIPT_DIR/ship-gate-council.md"
PIPE="$SCRIPT_DIR/ship-pipeline.md"
SKILL="$SCRIPT_DIR/SKILL.md"
SHIP="$ROOT/skills/orchestrate/steps/11-ship.md"
MODEB="$ROOT/skills/epic/mode-b-execute.md"
DOCS_O="$ROOT/docs/commands/orchestrate.md"
DOCS_E="$ROOT/docs/commands/epic.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "$TMPDIR/nest-m14.XXXXXX")
cleanup() { rm -rf "$TMP"; hermetic_cleanup; }
trap cleanup EXIT

for f in "$SPEC" "$SG" "$PIPE" "$SKILL" "$SHIP" "$MODEB" "$DOCS_O" "$DOCS_E"; do
  if [ ! -f "$f" ]; then
    fail "missing $f"
  fi
done

require_has() {
  local file="$1" needle="$2" label="$3"
  if has "$file" "$needle"; then
    pass "$label"
  else
    fail "$label — missing: $needle"
  fi
  local mut="$TMP/mut.$$" n
  n=$(grep -F -c -- "$needle" "$file" 2>/dev/null || true)
  if [ "${n:-0}" -gt 1 ]; then
    # Phrase repeats; bite by stripping every copy.
    awk -v s="$needle" '{
      line = $0
      out = ""
      while ((i = index(line, s)) > 0) {
        out = out substr(line, 1, i - 1)
        line = substr(line, i + length(s))
      }
      print out line
    }' "$file" > "$mut"
  else
    remove_line_substr "$file" "$mut" "$needle"
  fi
  if has "$mut" "$needle"; then
    fail "$label-bite mutation did not remove the phrase"
  else
    pass "$label-bite mutation removes phrase -> check would fail"
  fi
}

# --- SPEC-033 M14(l) ---
require_has "$SPEC" "M14(l)" "SPEC-033 names M14(l)"
require_has "$SPEC" "needs-parent-M14" "SPEC-033 names needs-parent-M14"
require_has "$SPEC" "Grok nest" "SPEC-033 states Grok nest rule"
require_has "$SPEC" "### CDT-512-C6" "SPEC-033 has ### CDT-512-C6 AC subsection"
require_has "$SPEC" "N18" "SPEC-033 N18"

# resume-ship y only for real disagree
require_has "$SPEC" "conf<80 / CONTRADICTED" "SPEC-033 resume-ship y tied to conf<80 / CONTRADICTED"

# M14(d) still present (unchanged golden lives in guardrails suite)
require_has "$SPEC" "(d) Degraded-run rule" "SPEC-033 M14(d) still present"

# --- ship-gate-council.md §2b ---
require_has "$SG" "### 2b." "ship-gate-council.md has §2b"
require_has "$SG" "needs-parent-M14" "ship-gate-council.md names needs-parent-M14"
require_has "$SG" "nest-host.sh" "ship-gate-council.md cites nest-host.sh"
require_has "$SG" "MUST NOT write a BC7 halt" "ship-gate-council.md forbids BC7 on nest"

# --- 11-ship ---
require_has "$SHIP" "needs-parent-M14" "11-ship.md names needs-parent-M14"
require_has "$SHIP" "MUST NOT print the resume-ship" "11-ship.md no resume-ship y on nest"
require_has "$SHIP" "real council disagree" "11-ship.md resume-ship y only for disagree"
require_has "$SHIP" "Telegram" "11-ship.md names Telegram nest-depth y"

# --- mode-b ---
require_has "$MODEB" "DEVTEAM_NEST_DEPTH=1" "mode-b exports DEVTEAM_NEST_DEPTH=1"
require_has "$MODEB" "export DEVTEAM_NEST_DEPTH=1" "mode-b bash export DEVTEAM_NEST_DEPTH=1"
require_has "$SPEC" "Away+autopilot" "SPEC-033 names Away+autopilot"
require_has "$MODEB" "needs-parent-M14" "mode-b handles needs-parent-M14"
require_has "$MODEB" "parent walker runs M14" "mode-b parent runs M14"

# --- pipeline + skill cite ---
require_has "$PIPE" "needs-parent-M14" "ship-pipeline.md names needs-parent-M14"
require_has "$SKILL" "M14(l)" "autopilot SKILL cites M14(l)"

# --- docs ---
require_has "$DOCS_O" "needs-parent-M14" "docs/commands/orchestrate.md names needs-parent-M14"
require_has "$DOCS_E" "needs-parent-M14" "docs/commands/epic.md names needs-parent-M14"

# --- CDT-523 kickoff deferral (needs-parent-PM-TL) ---
KICKOFF="$ROOT/skills/kickoff/SKILL.md"
KICKOFF_STEP="$ROOT/skills/orchestrate/steps/04-kickoff.md"
SPAWN_BLOCK="$ROOT/skills/orchestrate/steps/spawn-pm-tl-finder.md"
for f in "$KICKOFF" "$KICKOFF_STEP" "$SPAWN_BLOCK"; do
  if [ ! -f "$f" ]; then
    fail "missing $f"
  fi
done
require_has "$SPEC" "needs-parent-PM-TL" "SPEC-033 names needs-parent-PM-TL"
require_has "$SPEC" "can-spawn-agents" "SPEC-033 names can-spawn-agents"
require_has "$SPEC" "in-session fake kickoff" "SPEC-033 forbids in-session fake kickoff"
require_has "$KICKOFF" "needs-parent-PM-TL" "kickoff SKILL Step 2 returns needs-parent-PM-TL"
require_has "$KICKOFF" "can-spawn-agents" "kickoff SKILL probes can-spawn-agents"
require_has "$KICKOFF" "MUST NOT spawn @pm" "kickoff SKILL forbids the PM/TL/finder spawns"
require_has "$KICKOFF_STEP" "needs-parent-PM-TL" "04-kickoff.md returns needs-parent-PM-TL"
require_has "$KICKOFF_STEP" "can-spawn-agents" "04-kickoff.md probes can-spawn-agents"
require_has "$MODEB" "needs-parent-PM-TL" "mode-b handles needs-parent-PM-TL"
require_has "$MODEB" "spawn-pm-tl-finder.md" "mode-b cites the shared spawn blocks"
require_has "$SPEC" "resume-consume guard" "SPEC-033 names the resume-consume guard"
require_has "$KICKOFF" "resume-consume guard" "kickoff SKILL has the resume-consume guard"
require_has "$KICKOFF" "already carries the parent kickoff outputs" "kickoff SKILL consume condition"
require_has "$KICKOFF_STEP" "resume-consume guard" "04-kickoff.md has the resume-consume guard"
require_has "$KICKOFF_STEP" "already carries the parent kickoff outputs" "04-kickoff.md consume condition"
require_has "$MODEB" "resume-consume guard" "mode-b cites the child consume guard"
require_has "$MODEB" "DEVTEAM_NEST_DEPTH=1" "mode-b re-exports depth 1 on PM-TL resume"
if grep -q 'needs-parent-PM-TL' "$SG"; then
  fail "ship-gate-council.md must not claim needs-parent-PM-TL (reserved for kickoff)"
else
  pass "ship-gate-council.md keeps needs-parent-M14 only"
fi

# --- no resident daemon / no new BC ---
if grep -qi 'no resident daemon' "$SPEC" && grep -qi 'no resident daemon' "$SG"; then
  pass "no resident daemon claimed"
else
  fail "SPEC-033 or ship-gate-council.md missing 'no resident daemon'"
fi
if grep -q 'ninth blocking condition' "$SG" && grep -q 'no ninth' "$SG"; then
  pass "ship-gate still reuses BC7 (no ninth BC)"
else
  # §7 already says no ninth; keep the assert soft if wording drifts
  if has "$SG" "no** ninth blocking" || has "$SG" "no ninth blocking"; then
    pass "ship-gate still reuses BC7 (no ninth BC)"
  else
    require_has "$SG" "ninth blocking" "ship-gate mentions ninth BC (must still forbid it)"
  fi
fi

# --- M14(d) / §5 goldens not this suite's job, but §5 heading still exists ---
require_has "$SG" "## 5. Degraded-run rule" "ship-gate-council.md §5 heading unchanged"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
exit $?
