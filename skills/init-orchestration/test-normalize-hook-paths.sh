#!/usr/bin/env bash
# test-normalize-hook-paths.sh — CDT-69 Step 1 absolute/relative hook path upgrade
# Machine-check: bash skills/init-orchestration/test-normalize-hook-paths.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/normalize-hook-paths.sh"
DISCLOSE="$SCRIPT_DIR/disclose-force-overwrite.sh"
SKILL="$SCRIPT_DIR/SKILL.md"

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

echo "=== test-normalize-hook-paths (CDT-69) ==="

assert_file "helper exists" "$HELPER"
assert_file "disclose helper exists" "$DISCLOSE"
assert_file "SKILL.md exists" "$SKILL"

# ---------- Protocol grep: skill must document absolute-path upgrade + disclosure ----------
echo "-- protocol grep"
for needle in \
  "absolute" \
  "CLAUDE_PROJECT_DIR" \
  "FORCE-OVERWRITE" \
  "normalize-hook-paths.sh" \
  "/.claude/hooks/"
do
  if grep -qF -- "$needle" "$SKILL"; then
    PASS=$((PASS + 1)); echo "  ok  skill has [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL skill missing [$needle]"
  fi
done

# Absolute-path rewrite must be documented (not only relative)
if grep -qE 'bash .*\$\{?CLAUDE_PROJECT_DIR\}?' "$SKILL" \
   && grep -qiE 'absolute[- ]path' "$SKILL"; then
  PASS=$((PASS + 1)); echo "  ok  skill documents absolute-path rewrite"
else
  FAIL=$((FAIL + 1)); echo "  FAIL skill missing absolute-path rewrite docs"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/normalize-hook-paths-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
mkdir -p "$PROJ/.claude/hooks"
# Fake hook scripts (existence not required for rewrite, but mirrors real layout)
for h in bash-compress memory-capture stop-review task-completed; do
  : > "$PROJ/.claude/hooks/${h}.sh"
  chmod +x "$PROJ/.claude/hooks/${h}.sh"
done

# ---------- Absolute paths under project root → CLAUDE_PROJECT_DIR ----------
echo "-- absolute path rewrite"
cat > "$PROJ/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash \"$PROJ/.claude/hooks/bash-compress.sh\""
      }]
    }],
    "PostToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$PROJ/.claude/hooks/memory-capture.sh\""
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$PROJ/.claude/hooks/stop-review.sh\""
      }]
    }],
    "TaskCompleted": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$PROJ/.claude/hooks/task-completed.sh\""
      }]
    }]
  }
}
JSON

OUT=$(bash "$HELPER" --settings "$PROJ/.claude/settings.json" --project-root "$PROJ" 2>&1)
RC=$?
assert_rc "absolute rewrite rc 0" "$RC" 0
assert_contains "absolute discloses FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
assert_contains "absolute discloses key" "$OUT" "key:"
assert_contains "absolute discloses old" "$OUT" "old:"
assert_contains "absolute discloses new" "$OUT" "new:"
assert_contains "absolute discloses restore" "$OUT" "restore:"
assert_contains "absolute new form bash-compress" "$OUT" 'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-compress.sh"'

# settings written
GOT=$(python3 -c "
import json
d=json.load(open('$PROJ/.claude/settings.json'))
cmds=[]
for ev, entries in (d.get('hooks') or {}).items():
  for e in entries or []:
    for h in e.get('hooks') or []:
      cmds.append(h.get('command',''))
print('\n'.join(cmds))
")
assert_contains "settings bash-compress anchored" "$GOT" \
  'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-compress.sh"'
assert_contains "settings memory-capture anchored" "$GOT" \
  'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/memory-capture.sh"'
assert_contains "settings stop-review anchored" "$GOT" \
  'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/stop-review.sh"'
assert_contains "settings task-completed anchored" "$GOT" \
  'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/task-completed.sh"'
assert_not_contains "no absolute path remains" "$GOT" "$PROJ/.claude/hooks"

# ---------- Idempotent: already anchored → no-op ----------
echo "-- already anchored no-op"
OUT=$(bash "$HELPER" --settings "$PROJ/.claude/settings.json" --project-root "$PROJ" 2>&1)
RC=$?
assert_rc "anchored no-op rc 1" "$RC" 1
assert_eq "anchored no-op silent" "$OUT" ""

# ---------- Relative paths also rewritten ----------
echo "-- relative path rewrite"
cat > "$PROJ/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash .claude/hooks/stop-review.sh"
      }]
    }]
  }
}
JSON

OUT=$(bash "$HELPER" --settings "$PROJ/.claude/settings.json" --project-root "$PROJ" 2>&1)
RC=$?
assert_rc "relative rewrite rc 0" "$RC" 0
assert_contains "relative discloses" "$OUT" "FORCE-OVERWRITE"
GOT=$(python3 -c "import json; d=json.load(open('$PROJ/.claude/settings.json')); print(d['hooks']['Stop'][0]['hooks'][0]['command'])")
assert_eq "relative rewritten" "$GOT" \
  'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/stop-review.sh"'

# ---------- Foreign absolute path (outside project root) left alone ----------
echo "-- foreign absolute not rewritten"
cat > "$PROJ/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"/other/place/.claude/hooks/stop-review.sh\""
      }]
    }]
  }
}
JSON

OUT=$(bash "$HELPER" --settings "$PROJ/.claude/settings.json" --project-root "$PROJ" 2>&1)
RC=$?
assert_rc "foreign abs rc 1 (no rewrite)" "$RC" 1
GOT=$(python3 -c "import json; d=json.load(open('$PROJ/.claude/settings.json')); print(d['hooks']['Stop'][0]['hooks'][0]['command'])")
assert_eq "foreign abs unchanged" "$GOT" \
  'bash "/other/place/.claude/hooks/stop-review.sh"'

# ---------- dry-run: disclose but do not write ----------
echo "-- dry-run"
cat > "$PROJ/.claude/settings.json" <<JSON
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$PROJ/.claude/hooks/stop-review.sh\""
      }]
    }]
  }
}
JSON
BEFORE=$(cat "$PROJ/.claude/settings.json")
OUT=$(bash "$HELPER" --settings "$PROJ/.claude/settings.json" --project-root "$PROJ" --dry-run 2>&1)
RC=$?
assert_rc "dry-run rc 0" "$RC" 0
assert_contains "dry-run discloses" "$OUT" "FORCE-OVERWRITE"
AFTER=$(cat "$PROJ/.claude/settings.json")
assert_eq "dry-run no write" "$AFTER" "$BEFORE"

# ---------- missing settings ----------
echo "-- errors"
OUT=$(bash "$HELPER" --settings "$TMP/nope.json" --project-root "$PROJ" 2>&1)
RC=$?
assert_rc "missing settings rc 2" "$RC" 2

echo
echo "=== results: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
