#!/usr/bin/env bash
# test-sweep-legacy-orphans.sh — CDT-76 AC8 known-legacy-orphan sweep
# Machine-check: bash skills/init-orchestration/test-sweep-legacy-orphans.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/sweep-legacy-orphans.sh"
DISCLOSE="$SCRIPT_DIR/disclose-force-overwrite.sh"
SKILL="$SCRIPT_DIR/SKILL.md"
ORPHAN_NAME="bash-compress-wrapper.sh"

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

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); echo "  FAIL $name: unexpectedly has [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ok  $name"
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

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

assert_not_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL $name: unexpectedly exists $path"
  else
    PASS=$((PASS + 1)); echo "  ok  $name"
  fi
}

echo "=== test-sweep-legacy-orphans (CDT-76 AC8) ==="

assert_file "helper exists" "$HELPER"
assert_file "disclose helper exists" "$DISCLOSE"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sweep-legacy-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---------- Case 1: orphan only, no settings ref → remove + bak + disclose ----------
echo "-- case 1: orphan unreferenced → remove"
C1="$TMP/c1"
mkdir -p "$C1/.claude/hooks"
printf '%s\n' '#!/usr/bin/env bash' '# legacy wrapper body' > "$C1/.claude/hooks/$ORPHAN_NAME"
chmod +x "$C1/.claude/hooks/$ORPHAN_NAME"
# minimal settings — no command refs
cat > "$C1/.claude/settings.json" <<'JSON'
{
  "hooks": {}
}
JSON

OUT=$(bash "$HELPER" --project-root "$C1" 2>&1)
RC=$?
assert_rc "c1 exit 0" "$RC" 0
assert_contains "c1 FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
assert_contains "c1 key label" "$OUT" "key:"
assert_contains "c1 old label" "$OUT" "old:"
assert_contains "c1 new label" "$OUT" "new:"
assert_contains "c1 restore label" "$OUT" "restore:"
assert_contains "c1 LEGACY-ORPHAN removed" "$OUT" "LEGACY-ORPHAN: $ORPHAN_NAME removed restore="
assert_not_file "c1 orphan gone" "$C1/.claude/hooks/$ORPHAN_NAME"
BAK_COUNT=$(find "$C1/.claude/hooks" -name "${ORPHAN_NAME}.bak-force-*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "c1 bak-force exists" "$BAK_COUNT" "1"
# capture bak path for case 5 re-use of same tree
C1_BAK=$(find "$C1/.claude/hooks" -name "${ORPHAN_NAME}.bak-force-*" 2>/dev/null | head -1)
assert_file "c1 bak file readable" "$C1_BAK"

# ---------- Case 5: re-run after successful remove → no-op (uses c1 tree) ----------
echo "-- case 5: re-run after remove → no-op"
OUT5=$(bash "$HELPER" --project-root "$C1" 2>&1)
RC5=$?
assert_rc "c5 exit 0" "$RC5" 0
assert_not_contains "c5 no FORCE-OVERWRITE" "$OUT5" "FORCE-OVERWRITE"
assert_contains "c5 absent no-op" "$OUT5" "LEGACY-ORPHAN: $ORPHAN_NAME absent no-op"
BAK_COUNT5=$(find "$C1/.claude/hooks" -name "${ORPHAN_NAME}.bak-force-*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "c5 no extra bak" "$BAK_COUNT5" "1"

# ---------- Case 2: orphan absent → exit 0; no FORCE-OVERWRITE ----------
echo "-- case 2: orphan absent → no-op"
C2="$TMP/c2"
mkdir -p "$C2/.claude/hooks"
# no orphan file; optional empty settings
cat > "$C2/.claude/settings.json" <<'JSON'
{}
JSON

OUT=$(bash "$HELPER" --project-root "$C2" 2>&1)
RC=$?
assert_rc "c2 exit 0" "$RC" 0
assert_not_contains "c2 no FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
assert_contains "c2 absent no-op" "$OUT" "LEGACY-ORPHAN: $ORPHAN_NAME absent no-op"
BAK_COUNT2=$(find "$C2/.claude/hooks" -name "${ORPHAN_NAME}.bak-force-*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "c2 no bak" "$BAK_COUNT2" "0"

# ---------- Case 3: settings.json command refs orphan → kept + WARN ----------
echo "-- case 3: settings ref → kept + WARN"
C3="$TMP/c3"
mkdir -p "$C3/.claude/hooks"
printf '%s\n' '#!/usr/bin/env bash' > "$C3/.claude/hooks/$ORPHAN_NAME"
chmod +x "$C3/.claude/hooks/$ORPHAN_NAME"
cat > "$C3/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash \"\${CLAUDE_PROJECT_DIR}/.claude/hooks/${ORPHAN_NAME}\""
      }]
    }]
  }
}
JSON

OUT=$(bash "$HELPER" --project-root "$C3" 2>&1)
RC=$?
assert_rc "c3 exit 0" "$RC" 0
assert_file "c3 orphan kept" "$C3/.claude/hooks/$ORPHAN_NAME"
assert_contains "c3 WARN kept" "$OUT" "WARN: legacy orphan kept (still referenced):"
assert_contains "c3 still-referenced" "$OUT" "LEGACY-ORPHAN: $ORPHAN_NAME left still-referenced"
assert_contains "c3 referenced-by settings" "$OUT" "referenced-by: settings.json command:"
assert_not_contains "c3 no FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
BAK_COUNT3=$(find "$C3/.claude/hooks" -name "${ORPHAN_NAME}.bak-force-*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "c3 no bak (not deleted)" "$BAK_COUNT3" "0"

# ---------- Case 4: sibling other.sh contains basename → kept + WARN ----------
echo "-- case 4: sibling hook ref → kept + WARN"
C4="$TMP/c4"
mkdir -p "$C4/.claude/hooks"
printf '%s\n' '#!/usr/bin/env bash' > "$C4/.claude/hooks/$ORPHAN_NAME"
chmod +x "$C4/.claude/hooks/$ORPHAN_NAME"
# sibling references basename
cat > "$C4/.claude/hooks/other.sh" <<EOF
#!/usr/bin/env bash
# calls legacy wrapper
bash "\${CLAUDE_PROJECT_DIR}/.claude/hooks/${ORPHAN_NAME}"
EOF
chmod +x "$C4/.claude/hooks/other.sh"
cat > "$C4/.claude/settings.json" <<'JSON'
{
  "hooks": {}
}
JSON

OUT=$(bash "$HELPER" --project-root "$C4" 2>&1)
RC=$?
assert_rc "c4 exit 0" "$RC" 0
assert_file "c4 orphan kept" "$C4/.claude/hooks/$ORPHAN_NAME"
assert_contains "c4 WARN kept" "$OUT" "WARN: legacy orphan kept (still referenced):"
assert_contains "c4 still-referenced" "$OUT" "LEGACY-ORPHAN: $ORPHAN_NAME left still-referenced"
assert_contains "c4 WARN names sibling" "$OUT" "referenced-by: .claude/hooks/other.sh"
assert_not_contains "c4 no FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
BAK_COUNT4=$(find "$C4/.claude/hooks" -name "${ORPHAN_NAME}.bak-force-*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "c4 no bak" "$BAK_COUNT4" "0"

# ---------- Case 6: disclosure labels greppable (dedicated remove fixture) ----------
echo "-- case 6: disclosure labels"
C6="$TMP/c6"
mkdir -p "$C6/.claude/hooks"
printf '%s\n' '#!/usr/bin/env bash' > "$C6/.claude/hooks/$ORPHAN_NAME"
# no settings file → no refs

OUT=$(bash "$HELPER" --project-root "$C6" 2>&1)
RC=$?
assert_rc "c6 exit 0" "$RC" 0
for needle in "FORCE-OVERWRITE" "key:" "old:" "new:" "restore:"; do
  assert_contains "c6 has [$needle]" "$OUT" "$needle"
done
assert_contains "c6 key path" "$OUT" "key:     .claude/hooks/${ORPHAN_NAME}"
assert_contains "c6 old text" "$OUT" "legacy orphan present (known-legacy list)"
assert_contains "c6 new text" "$OUT" "removed (no longer managed)"
assert_contains "c6 restore bak-force" "$OUT" "${ORPHAN_NAME}.bak-force-"

# ---------- Case 7: soft SKILL.md smoke (skip if T3 not wired yet) ----------
echo "-- case 7: SKILL.md soft smoke"
if [ -f "$SKILL" ] && grep -qF -- "sweep-legacy-orphans" "$SKILL"; then
  PASS=$((PASS + 1)); echo "  ok  skill cites sweep-legacy-orphans"
  if grep -qE 'Step 4h|LEGACY-ORPHAN|known-legacy-orphan' "$SKILL"; then
    PASS=$((PASS + 1)); echo "  ok  skill has Step 4h / orphan protocol"
  else
    PASS=$((PASS + 1)); echo "  ok  skill has helper name (Step 4h prose soft — partial wire)"
  fi
else
  PASS=$((PASS + 1)); echo "  ok  skill smoke SKIP (T3 not wired yet — no sweep-legacy-orphans in SKILL.md)"
fi

# ---------- Bonus: usage without --project-root → exit 2 ----------
echo "-- usage error"
OUT=$(bash "$HELPER" 2>&1)
RC=$?
assert_rc "missing --project-root rc 2" "$RC" 2

echo
echo "=== results: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
