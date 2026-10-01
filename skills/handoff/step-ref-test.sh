#!/usr/bin/env bash
# step-ref-test.sh — CDT-328. A "Step N" token in handoff files must name a
# heading in commands/handoff.md. Run: bash skills/handoff/step-ref-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

HITFILE=$(mktemp "${TMPDIR:-/tmp}/step-ref-hits.XXXXXX")
HEADFILE=$(mktemp "${TMPDIR:-/tmp}/step-ref-heads.XXXXXX")
trap 'rm -f -- "$HITFILE" "$HEADFILE"' EXIT
grep -oE '^## Step [0-9]+[a-z]?' "$CMD" | sed 's/^## //' >"$HEADFILE" || true
if [ -s "$HEADFILE" ]; then ok
else bad "no Step headings in commands/handoff.md"; fi

token_ok() {
  grep -qxF "$1" "$HEADFILE"
}
grep -RnoE --exclude 'step-ref-test.sh' 'Step [0-9]+[a-z]?' \
  "$HERE" "$ROOT/specs/core/SPEC-018-cold-session-handoff.md" "$CMD" >"$HITFILE" 2>/dev/null || true
BAD=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  tok=$(printf '%s\n' "$line" | grep -oE 'Step [0-9]+[a-z]?' | head -1)
  [ -n "$tok" ] || continue
  if token_ok "$tok"; then
    :
  else
    echo "FAIL: $line"
    BAD=$((BAD + 1))
  fi
done <"$HITFILE"
if [ "$BAD" -eq 0 ]; then ok
else bad "$BAD step token(s) do not match a commands/handoff.md heading"; fi

echo "step-ref-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
