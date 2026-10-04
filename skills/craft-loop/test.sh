#!/usr/bin/env bash
# craft-loop/test.sh — rv-w3-28 + rv-w3-29 bite-tests: check-program.sh accepts
# every shipped example and rejects a broken fixture, journal-stats.sh reports
# the SPEC-020 open-decision rule, retire/list--all + compaction are specced,
# the library root is single-homed on $MROOT, and backlog-burn uses the
# backlog programmatic write-back.
#
# Machine-check: bash skills/craft-loop/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$HERE/check-program.sh"
STATS="$HERE/journal-stats.sh"
SKILL="$HERE/SKILL.md"
TEMPLATE="$HERE/program-template.md"

pass=0
fail=0
pass_line() { pass=$((pass + 1)); echo "PASS: $1"; }
fail_line() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

# ---- T1: every shipped example passes the validator --------------------------
for ex in "$HERE"/examples/*.md; do
  if bash "$CHECK" --quiet "$ex" 2>"$HERE/.check-err"; then
    pass_line "validator accepts $(basename "$ex")"
  else
    fail_line "validator rejects $(basename "$ex"): $(cat "$HERE/.check-err" | tr '\n' ' ')"
  fi
done
rm -f "$HERE/.check-err"

# ---- T2: a broken fixture fails, naming the violation ------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/craft-loop-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/broken.md" << 'EOF'
---
name: Broken Program
target: sideways
status: archived
created: not-a-date
---
# Objective
do a thing
# Never
- Run git push anywhere
EOF
ERR=$(bash "$CHECK" "$TMP/broken.md" 2>&1 >/dev/null) ; RC=$?
if [ "$RC" -eq 1 ]; then
  pass_line "validator rejects the broken fixture (rc=1)"
else
  fail_line "validator rc=$RC on the broken fixture (want 1)"
fi
MISS=0
printf '%s' "$ERR" | grep -q "missing required section: # Every iteration" || MISS=$((MISS + 1))
printf '%s' "$ERR" | grep -q "missing required section: # Stop when" || MISS=$((MISS + 1))
printf '%s' "$ERR" | grep -q "missing required section: # When blocked" || MISS=$((MISS + 1))
printf '%s' "$ERR" | grep -q "missing required section: # Journal entry schema" || MISS=$((MISS + 1))
printf '%s' "$ERR" | grep -q "target must be loop or goal" || MISS=$((MISS + 1))
printf '%s' "$ERR" | grep -q "status must be ready or retired" || MISS=$((MISS + 1))
printf '%s' "$ERR" | grep -q "created must be YYYY-MM-DD" || MISS=$((MISS + 1))
if [ "$MISS" -eq 0 ]; then
  pass_line "validator names each broken dimension"
else
  fail_line "validator missed $MISS expected violation classes: $ERR"
fi

# ---- T3: loosened-record acceptance ------------------------------------------
sed 's/^- Run git push anywhere$/- loosened: git push — user asked for a push-capable loop/' \
  "$TMP/broken.md" > "$TMP/broken2.md"
if ! printf '%s' "$(cat "$TMP/broken2.md")" | grep -q '^# Objective$'; then
  fail_line "T3 fixture sed failed"
fi
# The loosened record satisfies the push guardrail but the missing headings
# still fail — assert the push violation is gone while others remain.
ERR2=$(bash "$CHECK" "$TMP/broken2.md" 2>&1 >/dev/null)
if printf '%s' "$ERR2" | grep -q "lacks the git push/publish guardrail"; then
  fail_line "loosened record did not satisfy the push guardrail"
else
  pass_line "explicit '- loosened:' record satisfies a default guardrail"
fi

# ---- T4: journal-stats -------------------------------------------------------
cat > "$TMP/x.journal.md" << 'EOF'
# Journal — x
## Iteration 1 — 2026-10-01
- Did: first
- State: n/a
- Next: second
- Decisions needed:
  - [DECISION] open card one
  - [DECISION] closed card
    Answer: resolved already
- Unrelated: line
## Iteration 2 — 2026-10-02
- Did: second
- State: n/a
- Next: third
- Decisions needed:
  - [DECISION] still open two
Answer: column-zero does not close
EOF
SOUT=$(bash "$STATS" "$TMP/x.journal.md")
S_IT=$(printf '%s' "$SOUT" | sed -n 's/^iterations: //p')
S_OPEN=$(printf '%s' "$SOUT" | sed -n 's/^open_decisions: //p')
S_LINES=$(printf '%s' "$SOUT" | sed -n 's/^lines: //p')
if [ "$S_IT" = "2" ] && [ "$S_OPEN" = "2" ] && [ "$S_LINES" = "17" ]; then
  pass_line "journal-stats counts 2 iterations, 2 open decisions, 17 lines"
else
  fail_line "journal-stats: iterations=$S_IT open=$S_OPEN lines=$S_LINES (want 2/2/17)"
fi
# Negative control: a planted open card with an indented Answer beneath is
# closed by the same awk — flip the first card's answer to closed.
sed 's/^  - \[DECISION\] open card one$/  - [DECISION] open card one\n    Answer: now closed/' \
  "$TMP/x.journal.md" > /dev/null 2>&1 # (shape check only; real assert below)
python3 - "$TMP/x.journal.md" << 'PY' 2>/dev/null || true
import sys
p = sys.argv[1]
t = open(p).read().replace("- [DECISION] open card one\n", "- [DECISION] open card one\n    Answer: closed now\n")
open(p, "w").write(t)
PY
S_OPEN2=$(bash "$STATS" "$TMP/x.journal.md" | sed -n 's/^open_decisions: //p')
if [ "$S_OPEN2" = "1" ]; then
  pass_line "journal-stats: an indented Answer closes a card (2 -> 1)"
else
  fail_line "journal-stats indented-Answer close: open=$S_OPEN2 (want 1)"
fi

# ---- T5: SKILL.md static contracts ------------------------------------------
S=$(cat "$SKILL")
T=$(cat "$TEMPLATE")
if printf '%s' "$S" | grep -q 'six slots'; then
  fail_line "SKILL.md still says 'six slots' (5 are listed)"
else
  pass_line "SKILL.md says five slots (CDT-297 10 skills-minor)"
fi
printf '%s' 'restart the six slots' | grep -q 'six slots' \
  && pass_line "negative control: 'six slots' text is detectable" \
  || fail_line "negative control: 'six slots' not detectable"
if printf '%s' "$S" | grep -q 'write `$MROOT/.claude/loops/<name>.md`'; then
  pass_line "craft write path targets \$MROOT/.claude/loops"
else
  fail_line "craft write path is not \$MROOT/.claude/loops (rv-w3-29)"
fi
if printf '%s' "$S" | grep -q 'LOOPS_DIR="$MROOT/.claude/loops"'; then
  pass_line "list fence resolves the \$MROOT loops root"
else
  fail_line "list fence does not resolve \$MROOT/.claude/loops (rv-w3-29)"
fi
for needle in "## Mode: retire" "unless the caller passed \`--all\`" "status: retired" "check-program.sh" "journal-stats.sh" "exceeds **200" "## Summary"; do
  if printf '%s' "$S" | grep -qF -- "$needle"; then
    pass_line "SKILL.md carries: $needle"
  else
    fail_line "SKILL.md missing: $needle"
  fi
done
if printf '%s' "$T" | grep -q "exceeds 200 lines"; then
  pass_line "program-template.md carries the compaction rule"
else
  fail_line "program-template.md missing the compaction rule"
fi

# ---- T6: examples contracts ---------------------------------------------------
BB=$(cat "$HERE/examples/backlog-burn.md")
if printf '%s' "$BB" | grep -q 'close.sh <slug> --status COMPLETED' \
   && printf '%s' "$BB" | grep -q 'Programmatic write-back'; then
  pass_line "backlog-burn closes items via the backlog programmatic write-back"
else
  fail_line "backlog-burn does not use the backlog write-back (rv-w3-29)"
fi
if printf '%s' "$BB" | grep -q 'Mark the item `\[DONE\]`'; then
  fail_line "backlog-burn still hand-marks [DONE] in the index"
else
  pass_line "backlog-burn no longer hand-marks [DONE]"
fi
if printf '%s' "$BB" | grep -q 'never `git commit` it directly\|never stages'; then
  pass_line "backlog-burn forbids committing the backlog index"
else
  fail_line "backlog-burn does not forbid committing the index"
fi
printf '%s' '6. Mark the item `[DONE]` in `.claude/backlog.md`' | grep -q 'Mark the item `\[DONE\]`' \
  && pass_line "negative control: the old [DONE] text is detectable" \
  || fail_line "negative control: old [DONE] text not detectable"
SS=$(cat "$HERE/examples/spec-sync.md")
if printf '%s' "$SS" | grep -q 'spec-sync.ledger.md' \
   && printf '%s' "$SS" | grep -q 'current sweep' \
   && printf '%s' "$SS" | grep -q 'A \*\*current sweep\*\* is one full pass'; then
  pass_line "spec-sync declares the side ledger and defines the current sweep"
else
  fail_line "spec-sync ledger/sweep definitions missing"
fi
if printf '%s' "$SS" | grep -q 'State: <checked>/<total> specs in the current sweep'; then
  pass_line "spec-sync State no longer repeats the full ID list"
else
  fail_line "spec-sync State still repeats the ID list"
fi
GH=$(cat "$HERE/examples/journal-hygiene-goal.md")
if printf '%s' "$GH" | grep -q '^target: goal$'; then
  pass_line "shipped target: goal example exists (journal-hygiene)"
else
  fail_line "no target: goal example (rv-w3-29)"
fi

echo
echo "craft-loop: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
