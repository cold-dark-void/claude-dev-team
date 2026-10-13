#!/usr/bin/env bash
# agent-blocks-test.sh — CDT-299 bite-tests: the 7 behavioral agents carry the
# managed glossary + hand-back block (skills/agent-memory/glossary-handback.md),
# expanded per agent by sync-includes.py. CDT-558 adds the ADVISORY checks for
# agents/advisor.md + skills/agent-memory/advisor-protocol.md.
#
# Machine-check: bash skills/agent-memory/agent-blocks-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PARTIAL="$HERE/glossary-handback.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

assert_contains() { # assert_contains <name> <hay> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"
  else fail "$1 (missing [$3])"
  fi
}

BEHAVIORAL="pm tech-lead ic5 ic4 devops qa ds"
INTERNAL="finder debugger council-judge council-scribe distiller project-init"

# 1. The partial itself is the single source.
if [ -f "$PARTIAL" ]; then
  pass "glossary-handback.md partial exists"
else
  fail "glossary-handback.md partial exists"
fi

# 2. Every behavioral agent carries its own managed region with the expanded
#    body (CONTEXT.md load + final-message hand-back). Fails on old code:
#    before CDT-299 no agent had the block at all.
for a in $BEHAVIORAL; do
  f="$ROOT/agents/$a.md"
  if [ ! -f "$f" ]; then fail "agents/$a.md exists"; continue; fi
  text=$(cat "$f")
  assert_contains "$a: include marker present" "$text" \
    "<!-- include: skills/agent-memory/glossary-handback.md agent=$a -->"
  assert_contains "$a: expanded region loads CONTEXT.md" "$text" "CONTEXT.md"
  assert_contains "$a: expanded region prefers the worktree copy" "$text" \
    '[ -f "$WTROOT/CONTEXT.md" ]'
  assert_contains "$a: expanded region has the hand-back rule" "$text" \
    "as your final message"
done

# 3. Negative control: internal agents must NOT carry the block (they have no
#    memory/protocol surfaces; the block is a behavioral-agent contract).
for a in $INTERNAL; do
  f="$ROOT/agents/$a.md"
  [ -f "$f" ] || continue
  if printf '%s' "$(cat "$f")" | grep -qF "glossary-handback.md"; then
    fail "internal agent $a must not carry the glossary-handback include"
  else
    pass "internal agent $a has no glossary-handback include (control)"
  fi
done

# 4. Negative control: the managed-region checker would catch a stale copy —
#    plant a drifted region shape and prove the marker greps bite.
DECOY=$(mktemp "${TMPDIR:-/tmp}/agent-blocks-decoy.XXXXXX")
trap 'rm -f "$DECOY"' EXIT
printf '%s\n' 'plain agent body with no managed region' > "$DECOY"
MISS=0
grep -qF "glossary-handback.md" "$DECOY" || MISS=$((MISS + 1))
if [ "$MISS" -eq 1 ]; then
  pass "decoy body without the block is detected (control)"
else
  fail "decoy body without the block is detected (control)"
fi

# 5. CDT-558: advisor is advisory-internal — its own ADVISORY check, never
#    folded into INTERNAL= (AC1–AC5 of `### CDT-558` in SPEC-039).
ADVISORY="advisor"
ADV="$ROOT/agents/advisor.md"
ADV_PARTIAL="$HERE/advisor-protocol.md"

if [ -f "$ADV" ]; then pass "agents/advisor.md exists"; else fail "agents/advisor.md exists"; fi
if [ -f "$ADV_PARTIAL" ]; then pass "advisor-protocol.md partial exists"; else fail "advisor-protocol.md partial exists"; fi

if [ -f "$ADV" ]; then
  text=$(cat "$ADV")
  # AC1: frontmatter.
  assert_contains "advisor: include marker present" "$text" \
    "<!-- include: skills/agent-memory/advisor-protocol.md agent=advisor -->"
  assert_contains "advisor: tools exact" "$text" "tools: Read, Grep, Glob, Bash"
  assert_contains "advisor: model opus" "$text" "model: opus"
  assert_contains "advisor: effort high" "$text" "effort: high"
  assert_contains "advisor: mode subagent" "$text" "mode: subagent"
  # AC2: advisor-protocol.md is the ONLY managed include — no behavioral or
  # internal-agent surfaces (protocol.md, glossary-handback, cortex-load).
  if printf '%s' "$text" | grep -qF "skills/agent-memory/protocol.md"; then
    fail "advisor carries the behavioral protocol.md include"
  else
    pass "advisor has no protocol.md include"
  fi
  if printf '%s' "$text" | grep -qF "glossary-handback.md"; then
    fail "advisor carries the glossary-handback include"
  else
    pass "advisor has no glossary-handback include"
  fi
  if printf '%s' "$text" | grep -qF "cortex-load.md"; then
    fail "advisor carries the cortex-load include"
  else
    pass "advisor has no cortex-load include"
  fi
  # AC3: body contract phrases.
  assert_contains "advisor: ask.sh-only spawn" "$text" "skills/advisor/ask.sh"
  assert_contains "advisor: never routed directly" "$text" "never routed directly"
  assert_contains "advisor: read-only" "$text" "Read-only"
  assert_contains "advisor: advisory-but-logged" "$text" "advisory-but-logged"
  assert_contains "advisor: ruling via final message" "$text" "final message"
  assert_contains "advisor: no-mutating-Bash discipline" "$text" "no writes, no installs"
  # AC2: partial = protocol.md minus directives-load minus cortex fallback.
  ptext=$(cat "$ADV_PARTIAL")
  if printf '%s' "$ptext" | grep -qF "directives.md"; then
    fail "advisor-protocol.md has no directives load"
  else
    pass "advisor-protocol.md has no directives load"
  fi
  assert_contains "advisor-protocol.md fallback loop is memory lessons only" "$ptext" \
    "for TYPE in memory lessons; do"
  if printf '%s' "$ptext" | grep -qF "cortex memory lessons"; then
    fail "advisor-protocol.md dropped cortex from the fallback loop"
  else
    pass "advisor-protocol.md dropped cortex from the fallback loop"
  fi
  assert_contains "advisor-protocol.md keeps the PDH stanza" "$ptext" "plugin-dir.sh"
  # AC2: managed region matches the partial (sync-includes.py check).
  if python3 "$HERE/sync-includes.py" check "$ADV" >/dev/null 2>&1; then
    pass "advisor include region matches its partial (sync-includes.py check)"
  else
    fail "advisor include region drifted from advisor-protocol.md"
  fi
fi

# AC4 negatives: advisor absent from the bootstrap roster, the dashboard list,
# and the pin lists.
for f in agents/project-init.md commands/adjust-agent.md install.sh uninstall.sh; do
  if grep -qw advisor "$ROOT/$f" 2>/dev/null; then
    fail "advisor absent from $f"
  else
    pass "advisor absent from $f"
  fi
done

# AC5: exactly one OWNERS row, owned by SPEC-003.
OWN="$ROOT/specs/OWNERS"
if [ "$(grep -cF 'agents/advisor.md' "$OWN")" -eq 1 ] \
  && grep -qF 'agents/advisor.md	SPEC-003' "$OWN"; then
  pass "specs/OWNERS has exactly one agents/advisor.md -> SPEC-003 row"
else
  fail "specs/OWNERS agents/advisor.md row"
fi

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
