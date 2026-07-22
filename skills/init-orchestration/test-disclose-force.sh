#!/usr/bin/env bash
# test-disclose-force.sh — CDT-51 AC5 force-overwrite disclosure (SPEC-005)
# Machine-check: bash skills/init-orchestration/test-disclose-force.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/disclose-force-overwrite.sh"
SKILL="$SCRIPT_DIR/SKILL.md"
SETUP="$SCRIPT_DIR/../../commands/setup.md"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: got=[$got] want=[$want]"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing [$needle]"
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

assert_rc() {
  local name="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: rc=$got want=$want"
  fi
}

echo "=== test-disclose-force (SPEC-005 / CDT-51 AC5) ==="

assert_file "helper exists" "$HELPER"
assert_file "SKILL.md exists" "$SKILL"
assert_file "setup.md exists" "$SETUP"

# ---------- Protocol grep: skill must document disclosure on force ----------
echo "-- protocol grep"
for needle in \
  "FORCE-OVERWRITE" \
  "key:" \
  "old:" \
  "new:" \
  "restore:" \
  "permissions.defaultMode" \
  "disclose-force-overwrite.sh" \
  "Forced + silent = FAIL"
do
  if grep -qF -- "$needle" "$SKILL"; then
    PASS=$((PASS + 1)); echo "  ok  skill has [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL skill missing [$needle]"
  fi
done

if grep -qF -- "disclose-force-overwrite.sh" "$SETUP"; then
  PASS=$((PASS + 1)); echo "  ok  setup.md references helper"
else
  FAIL=$((FAIL + 1)); echo "  FAIL setup.md missing helper ref"
fi

# ---------- Helper: print mode ----------
echo "-- helper print mode"
OUT=$(bash "$HELPER" --key permissions.defaultMode --old bypassPermissions --new dontAsk 2>&1)
RC=$?
assert_rc "print mode rc 0 (change)" "$RC" 0
assert_contains "print FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
assert_contains "print key" "$OUT" "key:     permissions.defaultMode"
assert_contains "print old" "$OUT" "old:     bypassPermissions"
assert_contains "print new" "$OUT" "new:     dontAsk"
assert_contains "print restore" "$OUT" "restore: permissions.defaultMode"

OUT=$(bash "$HELPER" --key permissions.defaultMode --old dontAsk --new dontAsk 2>&1)
RC=$?
assert_rc "print mode rc 1 (same)" "$RC" 1
assert_eq "print mode silent on same" "$OUT" ""

# ---------- Helper: settings mode ----------
echo "-- helper settings mode"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/disclose-force-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/settings.json" <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "allow": ["Bash(*)"]
  },
  "sandbox": {
    "enabled": false,
    "autoAllowBashIfSandboxed": true
  }
}
JSON

OUT=$(bash "$HELPER" \
  --settings "$TMP/settings.json" \
  --key permissions.defaultMode \
  --new dontAsk \
  --backup-dir "$TMP/bak" 2>&1)
RC=$?
assert_rc "settings force rc 0" "$RC" 0
assert_contains "settings old bypass" "$OUT" "old:     bypassPermissions"
assert_contains "settings new dontAsk" "$OUT" "new:     dontAsk"
assert_contains "settings key" "$OUT" "key:     permissions.defaultMode"
assert_contains "settings restore backup path" "$OUT" "settings.force-permissions_defaultMode"

# backup file written
BAK_COUNT=$(find "$TMP/bak" -name 'settings.force-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "backup created" "$BAK_COUNT" "1"

# same value → no-op
OUT=$(bash "$HELPER" \
  --settings "$TMP/settings.json" \
  --key permissions.defaultMode \
  --new bypassPermissions 2>&1)
RC=$?
assert_rc "settings no-op rc 1" "$RC" 1
assert_eq "settings no-op silent" "$OUT" ""

# boolean sandbox key
OUT=$(bash "$HELPER" \
  --settings "$TMP/settings.json" \
  --key sandbox.enabled \
  --new true 2>&1)
RC=$?
assert_rc "sandbox.enabled force rc 0" "$RC" 0
assert_contains "sandbox old false" "$OUT" "old:     false"
assert_contains "sandbox new true" "$OUT" "new:     true"

# missing settings file → no-op (greenfield)
OUT=$(bash "$HELPER" \
  --settings "$TMP/nope.json" \
  --key permissions.defaultMode \
  --new dontAsk 2>&1)
RC=$?
assert_rc "missing settings rc 1" "$RC" 1

# usage error
set +e
OUT=$(bash "$HELPER" 2>&1)
RC=$?
set -e
assert_rc "usage rc 2" "$RC" 2

echo "=== results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
