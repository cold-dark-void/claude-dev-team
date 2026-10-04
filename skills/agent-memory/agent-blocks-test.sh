#!/usr/bin/env bash
# agent-blocks-test.sh — CDT-299 bite-tests: the 7 behavioral agents carry the
# managed glossary + hand-back block (skills/agent-memory/glossary-handback.md),
# expanded per agent by sync-includes.py.
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

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
