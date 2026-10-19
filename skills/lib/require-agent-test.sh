#!/usr/bin/env bash
# skills/lib/require-agent-test.sh — unit tests for require-agent.sh (SPEC-039 M33).
# Default keeps the 7-name behavioral roster; --memory admits advisor (8 total).
# Run: bash skills/lib/require-agent-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/require-agent.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

expect_rc() { # expect_rc <want-rc> <label> <args...>
  local want="$1" label="$2"; shift 2
  bash "$LIB" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then pass "$label"; else fail "$label (want rc=$want got=$got)"; fi
}

# Default: the 7 behavioral names only.
for a in pm tech-lead ic5 ic4 devops qa ds; do
  expect_rc 0 "default accepts $a" "$a"
done
expect_rc 64 "default rejects advisor" advisor
expect_rc 64 "default rejects distiller" distiller
expect_rc 64 "default rejects sql payload" "pm'; DROP TABLE memories;--"
expect_rc 64 "default rejects empty" ""

# --memory: the 7 plus advisor; other non-behavioral names stay rejected.
for a in pm tech-lead ic5 ic4 devops qa ds; do
  expect_rc 0 "--memory accepts $a" --memory "$a"
done
expect_rc 0 "--memory accepts advisor" --memory advisor
expect_rc 64 "--memory rejects distiller" --memory distiller
expect_rc 64 "--memory rejects council-judge" --memory council-judge
expect_rc 64 "--memory rejects sql payload" --memory "advisor'); DROP TABLE memories;--"
expect_rc 64 "--memory rejects empty" --memory ""

echo ""
echo "require-agent tests: $PASS pass / $FAIL fail"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
