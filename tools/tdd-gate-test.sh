#!/usr/bin/env bash
# tools/tdd-gate-test.sh — wp-1-10-gate-hooks T5, AC F.
# Verifies commands/tdd-gate.md's fence contract (C9) and the emitted
# tdd-gate.sh hook's graduated-enforcement behaviour, hermetically.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$ROOT/tests/lib/skip.sh"
. "$ROOT/tests/lib/hermetic.sh"

require_cmd python3 git bash sed grep

MD="$ROOT/commands/tdd-gate.md"
EXTRACT="$ROOT/skills/init-orchestration/check-hook-templates.sh"
BASH_BIN=$(command -v bash)

hermetic_init

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

check_rc() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass; else fail "$desc: rc=$got want=$want"; fi
}
check_contains() {
  local desc="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass
  else
    fail "$desc: missing '$needle' in $file"
  fi
}
check_not_contains() {
  local desc="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file" 2>/dev/null; then
    fail "$desc: unexpected '$needle' present in $file"
  else
    pass
  fi
}

if [ ! -f "$MD" ]; then
  fail "commands/tdd-gate.md not found at $MD"
  echo
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

# --- static: fence info string, marker text ----------------------------------
check_contains "F: fence marker present" "$MD" 'create `.claude/hooks/tdd-gate.sh` with this content:'
if awk '/create `.claude\/hooks\/tdd-gate.sh` with this content:/{found=1; next} found && /^```/{print; exit}' "$MD" | grep -qx '```bash template'; then
  pass
else
  fail "F: fence after the create-marker is not exactly \`\`\`bash template"
fi

# --- extractor round-trip: shebang first line, bash -n clean -----------------
TDD_HOOK="$WORK/tdd-gate.sh"
bash "$EXTRACT" --extract tdd-gate > "$TDD_HOOK" 2>"$WORK/extract.err"
check_rc "F: extract tdd-gate rc" "$?" "0"
FIRST_LINE=$(head -1 "$TDD_HOOK")
if [ "$FIRST_LINE" = '#!/usr/bin/env bash' ]; then pass; else fail "F: first line='$FIRST_LINE' want shebang"; fi
if bash -n "$TDD_HOOK" 2>"$WORK/bashn.err"; then pass; else fail "F: bash -n failed: $(cat "$WORK/bashn.err")"; fi
chmod +x "$TDD_HOOK"

# --- static: settings JSON matcher, frontmatter, usage, allowed list ---------
check_contains "F: settings JSON matcher" "$MD" '"matcher": "Write|Edit|MultiEdit"'
check_contains "F: frontmatter argument-hint" "$MD" 'argument-hint: "[on|off|status]"'
check_contains "F: Step 2 usage line" "$MD" 'Usage: /tdd-gate [on|off|status]'
check_contains "F: allowed list *.sh" "$MD" '*.sh'
check_contains "F: allowed list Makefile" "$MD" 'Makefile'
check_contains "F: allowed list Taskfile*" "$MD" 'Taskfile*'
check_not_contains "F: no bare chmod +x .claude/hooks/tdd-gate.sh" "$MD" 'chmod +x .claude/hooks/tdd-gate.sh'
check_not_contains "F: no legacy exits-with-code-2 wording" "$MD" 'exits with code 2 (block)'

# chmod_block_ok TEXT: TEXT must assign WTROOT via show-toplevel AND chmod it.
chmod_block_ok() {
  printf '%s' "$1" | grep -qF 'WTROOT=$(git rev-parse --show-toplevel' \
    && printf '%s' "$1" | grep -qF 'chmod +x "$WTROOT/.claude/hooks/tdd-gate.sh"'
}
CHMOD_BLOCK=$(grep -A3 'Make it executable:' "$MD")
if chmod_block_ok "$CHMOD_BLOCK"; then
  pass
else
  fail "F: no single fence assigns WTROOT via show-toplevel AND chmod +x \"\$WTROOT/...\""
fi
# Planted negative control: a chmod-only block must be rejected.
if chmod_block_ok 'chmod +x "$WTROOT/.claude/hooks/tdd-gate.sh"'; then
  fail "F: negative control accepted a block with no WTROOT assignment"
else
  pass
fi

# SPEC-031 dedup identity string (matches SKILL.md).
check_contains "F: dedup identity string" "$MD" '("Write|Edit|MultiEdit", [tdd-gate.sh command])'

# --- functional: graduated enforcement 0,0,2 then Read exits 0 --------------
REPO="$WORK/repo"
mkdir -p "$REPO/src"
( cd "$REPO" && git init -q )
TARGET="$REPO/src/foo.go"

run_hook() {
  local stdin_json="$1" outfile="$2" errfile="$3"
  printf '%s' "$stdin_json" > "$WORK/stdin.json"
  ( cd "$REPO" && "$BASH_BIN" "$TDD_HOOK" < "$WORK/stdin.json" > "$outfile" 2>"$errfile" )
  return $?
}

WRITE_JSON='{"tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"},"session_id":"sess1"}'
run_hook "$WRITE_JSON" "$WORK/w1.out" "$WORK/w1.err"
check_rc "F: Write attempt 1 (hint) rc" "$?" "0"
run_hook "$WRITE_JSON" "$WORK/w2.out" "$WORK/w2.err"
check_rc "F: Write attempt 2 (warning) rc" "$?" "0"
run_hook "$WRITE_JSON" "$WORK/w3.out" "$WORK/w3.err"
check_rc "F: Write attempt 3 (block) rc" "$?" "2"

READ_JSON='{"tool_name":"Read","tool_input":{"file_path":"'"$TARGET"'"},"session_id":"sess1"}'
run_hook "$READ_JSON" "$WORK/r1.out" "$WORK/r1.err"
check_rc "F: Read rc" "$?" "0"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
