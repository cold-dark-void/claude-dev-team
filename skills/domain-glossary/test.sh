#!/usr/bin/env bash
# domain-glossary/test.sh — CDT-374 bite-tests: load resolves the worktree
# CONTEXT.md first (same file write-back targets), and the write-target table
# rows all carry 3 cells against their 3-column header.
#
# Machine-check: bash skills/domain-glossary/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"

pass=0
fail=0
pass_line() { pass=$((pass + 1)); echo "PASS: $1"; }
fail_line() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

# ---- T1: the load protocol fence reads WTROOT before MROOT -------------------
LOAD_FENCE=$(awk '
  /^## Load protocol/ { on=1; next }
  on && /^```bash$/ { grab=1; next }
  grab && /^```$/ { exit }
  grab { print }
' "$SKILL")
if [ -z "$LOAD_FENCE" ]; then
  fail_line "load-protocol fence extracted"
  echo "domain-glossary: $pass passed, $fail failed"
  exit 1
fi
pass_line "load-protocol fence extracted"

if printf '%s\n' "$LOAD_FENCE" | grep -q 'WTROOT=$(git rev-parse --show-toplevel'; then
  pass_line "load fence resolves WTROOT"
else
  fail_line "load fence resolves WTROOT (CDT-374: WTROOT-first load missing)"
fi
# WTROOT/CONTEXT.md must be consulted before $MROOT/CONTEXT.md.
WT_LINE=$(printf '%s\n' "$LOAD_FENCE" | grep -n '"\$WTROOT/CONTEXT.md"' | head -1 | cut -d: -f1)
M_LINE=$(printf '%s\n' "$LOAD_FENCE" | grep -n '"\$MROOT/CONTEXT.md"' | head -1 | cut -d: -f1)
if [ -n "$WT_LINE" ] && [ -n "$M_LINE" ] && [ "$WT_LINE" -lt "$M_LINE" ]; then
  pass_line "load fence checks WTROOT before MROOT"
else
  fail_line "load fence checks WTROOT before MROOT (got wt=$WT_LINE mroot=$M_LINE)"
fi

# ---- T2: behavior — in a worktree, the load snippet returns the worktree file
TMP=$(mktemp -d "${TMPDIR:-/tmp}/domain-glossary-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
git init -q -b master "$TMP/main"
git -C "$TMP/main" config user.email t@t
git -C "$TMP/main" config user.name t
printf '# glossary main\n' > "$TMP/main/CONTEXT.md"
git -C "$TMP/main" add CONTEXT.md
git -C "$TMP/main" commit -qm init
git -C "$TMP/main" worktree add -q "$TMP/wt" -b feat/glossary
printf '# glossary worktree\n' > "$TMP/wt/CONTEXT.md"
GOT=$(cd "$TMP/wt" && bash -c "$LOAD_FENCE")
if [ "$GOT" = "# glossary worktree" ]; then
  pass_line "load snippet returns the worktree CONTEXT.md inside a worktree"
else
  fail_line "load snippet returns the worktree CONTEXT.md (got [$GOT])"
fi
# Fallback: no worktree copy → main checkout file.
GOT2=$(cd "$TMP/main" && bash -c "$LOAD_FENCE")
if [ "$GOT2" = "# glossary main" ]; then
  pass_line "load snippet falls back to the main checkout CONTEXT.md"
else
  fail_line "load snippet falls back to the main checkout (got [$GOT2])"
fi

# ---- T3: every write-target table row has 3 cells ---------------------------
BAD_ROWS=$(awk '
  /^   \| Situation \| Write path \| Commit \|/ { intable=1; next }
  intable && /^   \|-/ { next }
  intable && /^   \|/ {
    n = gsub(/\|/, "|")
    if (n != 4) print NR ":" $0
    next
  }
  intable && !/^   \|/ { intable=0 }
' "$SKILL")
if [ -z "$BAD_ROWS" ]; then
  pass_line "write-target table rows all have 3 cells"
else
  fail_line "write-target table rows with != 3 cells: $BAD_ROWS"
fi

# ---- T4: negative control — the same check bites a planted 2-cell row -------
PLANTED='   | Only two cells here | missing the commit cell |'
PLANT_BAD=$(printf '%s\n' "$PLANTED" | awk '/^   \|[[:space:]]/ { n = gsub(/\|/, "|"); if (n != 4) print "bad" }')
if [ "$PLANT_BAD" = "bad" ]; then
  pass_line "negative control: 2-cell row is detected by the same check"
else
  fail_line "negative control: 2-cell row not detected"
fi

echo
echo "domain-glossary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
