#!/usr/bin/env bash
# brainstorm/test.sh — rv-w3-27 + CDT-297[10 brainstorm] bite-tests: plans are
# saved under the main checkout's $MROOT/.claude/plans, the Step 4b CONTEXT.md
# commit asks first, round-skipping respects an explicit "just build it", and
# skill and docs agree on the rounds.
#
# Machine-check: bash skills/brainstorm/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
DOCS="$ROOT/docs/commands/brainstorm.md"

pass=0
fail=0
pass_line() { pass=$((pass + 1)); echo "PASS: $1"; }
fail_line() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

S=$(cat "$SKILL")
D=$(cat "$DOCS")

# T1 — Step 4 saves under $MROOT/.claude/plans (the /debug + /refactor root).
if printf '%s' "$S" | grep -q 'PLAN="$MROOT/.claude/plans/'; then
  pass_line "Step 4 plans root is \$MROOT/.claude/plans"
else
  fail_line "Step 4 plans root is not \$MROOT/.claude/plans (rv-w3-27)"
fi
# The old WTROOT-local save fence must be gone from Step 4.
if printf '%s' "$S" | grep -q '^WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)$' \
   && printf '%s' "$S" | grep -q '# Save to .claude/plans/'; then
  fail_line "old comment-only WTROOT save fence still present"
else
  pass_line "old no-op save fence removed (Step 4 is real)"
fi

# T2 — Step 4b asks before the CONTEXT.md commit.
if printf '%s' "$S" | grep -q 'Commit CONTEXT.md to <branch>? (y/n)'; then
  pass_line "Step 4b commit has a confirmation gate"
else
  fail_line "Step 4b commit runs without a confirmation gate (rv-w3-27)"
fi
# The gate must precede the commit fence inside Step 4b.
GATE_LINE=$(printf '%s' "$S" | grep -n 'Commit CONTEXT.md to <branch>? (y/n)' | head -1 | cut -d: -f1)
COMMIT_LINE=$(printf '%s' "$S" | grep -n 'git -C "$WTROOT" commit -m "context:' | head -1 | cut -d: -f1)
if [ -n "$GATE_LINE" ] && [ -n "$COMMIT_LINE" ] && [ "$GATE_LINE" -lt "$COMMIT_LINE" ]; then
  pass_line "confirmation gate precedes the commit fence"
else
  fail_line "confirmation gate does not precede the commit fence (gate=$GATE_LINE commit=$COMMIT_LINE)"
fi

# T3 — round-skipping: the old NEVER-skip rule is gone, the compress rule is in.
if printf '%s' "$S" | grep -q 'NEVER skip default rounds'; then
  fail_line "old 'NEVER skip default rounds' rule still present (CDT-297/rv-w3-27)"
else
  pass_line "old 'NEVER skip default rounds' rule removed"
fi
if printf '%s' "$S" | grep -q 'compress the remaining rounds into ONE batched message'; then
  pass_line "explicit-request compression rule present"
else
  fail_line "explicit-request compression rule missing"
fi
# Round 4 stays conditional (the contradiction source is the pair, not the heading).
if printf '%s' "$S" | grep -q '### Round 4: Alternatives (if the problem is still ambiguous)'; then
  pass_line "Round 4 stays conditional"
else
  fail_line "Round 4 conditional heading changed unexpectedly"
fi

# T4 — skill and docs agree on the rounds.
if printf '%s' "$D" | grep -q 'All four rounds run even if you say'; then
  fail_line "docs still claim all four rounds always run"
else
  pass_line "docs no longer claim all four rounds always run"
fi
if printf '%s' "$D" | grep -q 'Three rounds always run'; then
  pass_line "docs state the 3+conditional-round shape"
else
  fail_line "docs do not state the 3+conditional-round shape"
fi
# Docs name the main checkout's plans root like the skill does.
if printf '%s' "$D" | grep -q "main checkout's \`.claude/plans/"; then
  pass_line "docs name the main-checkout plans root"
else
  fail_line "docs plans-root wording not aligned"
fi

# T5 — negative control: the banned old rule text bites a planted fixture.
PLANT='NEVER skip default rounds when mode is default'
printf '%s' "$PLANT" | grep -q 'NEVER skip default rounds' \
  && pass_line "negative control: banned rule text is detectable" \
  || fail_line "negative control: banned rule text not detectable"

echo
echo "brainstorm: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
