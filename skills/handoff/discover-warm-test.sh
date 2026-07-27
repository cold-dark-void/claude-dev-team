#!/usr/bin/env bash
# discover-warm-test.sh — CDT-79-6 warm session JSONL discovery (SPEC-018 M10).
# Run: bash skills/handoff/discover-warm-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DISCOVER="$HERE/discover-warm.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/discover-warm-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Isolate env so ambient session vars cannot leak into tests.
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
export CLAUDE_PROJECTS_DIR="$WORK/projects"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj-a" "$CLAUDE_PROJECTS_DIR/proj-b"
# Disable assemble locate fallback unless a test opts in.
export DISCOVER_ASSEMBLE="$WORK/no-such-assemble.py"

SID="warm-disc-sess-001"
OLD="$CLAUDE_PROJECTS_DIR/proj-a/${SID}.jsonl"
NEW="$CLAUDE_PROJECTS_DIR/proj-b/${SID}.jsonl"
printf '{"type":"user","uuid":"u1"}\n' >"$OLD"
printf '{"type":"user","uuid":"u2"}\n' >"$NEW"
# Older mtime on OLD, newer on NEW
touch -d "2020-01-01 00:00:00" "$OLD" 2>/dev/null \
  || touch -t 202001010000 "$OLD"
touch "$NEW"

# ---- T0: script present ----
if [ -x "$DISCOVER" ]; then ok; else bad "T0 discover-warm.sh missing/not executable"; fi

# ---- T1: CLAUDE_SESSION_ID + stem newest mtime ----
export CLAUDE_SESSION_ID="$SID"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t1.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$SID" ] && [ "$GOT_TR" = "$NEW" ]; then ok
else bad "T1 newest stem rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t1.err")"; fi
unset CLAUDE_SESSION_ID

# ---- T2: SESSION_ID fallback ----
export SESSION_ID="$SID"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t2.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$SID" ]; then ok
else bad "T2 SESSION_ID rc=$RC sid=$GOT_SID"; fi
unset SESSION_ID

# ---- T3: CLAUDE_TRANSCRIPT_PATH wins over stem ----
export CLAUDE_SESSION_ID="$SID"
export CLAUDE_TRANSCRIPT_PATH="$OLD"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t3.err")
RC=$?
set -e
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
# realpath may resolve; compare basenames / -ef
if [ "$RC" -eq 0 ] && [ -f "$GOT_TR" ] && [ "$GOT_TR" -ef "$OLD" ]; then ok
else bad "T3 transcript env override tr=$GOT_TR want=$OLD"; fi
unset CLAUDE_TRANSCRIPT_PATH CLAUDE_SESSION_ID

# ---- T4: derive session id from transcript basename when ids unset ----
export CLAUDE_TRANSCRIPT_PATH="$NEW"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t4.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$SID" ]; then ok
else bad "T4 derive sid from path rc=$RC sid=$GOT_SID err=$(cat "$WORK/t4.err")"; fi
unset CLAUDE_TRANSCRIPT_PATH

# ---- T5: missing everything → exit 1 + clear message ----
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t5.err")
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -qi 'could not resolve this session' "$WORK/t5.err"; then ok
else bad "T5 empty env want rc=1 clear msg got rc=$RC err=$(cat "$WORK/t5.err")"; fi

# ---- T6: id set but no jsonl → exit 1 ----
export CLAUDE_SESSION_ID="no-such-session-zzz"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t6.err")
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -qi 'could not locate transcript' "$WORK/t6.err"; then ok
else bad "T6 missing jsonl rc=$RC err=$(cat "$WORK/t6.err")"; fi
unset CLAUDE_SESSION_ID

# ---- T7: unsafe session id rejected ----
export CLAUDE_SESSION_ID='evil/../id'
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t7.err")
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -qi 'unsafe' "$WORK/t7.err"; then ok
else bad "T7 unsafe id rc=$RC err=$(cat "$WORK/t7.err")"; fi
unset CLAUDE_SESSION_ID

# ---- T8: CLAUDE_SESSION_ID beats SESSION_ID ----
export CLAUDE_SESSION_ID="$SID"
export SESSION_ID="other-should-lose"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t8.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$SID" ]; then ok
else bad "T8 precedence CLAUDE_SESSION_ID wins got=$GOT_SID"; fi
unset CLAUDE_SESSION_ID SESSION_ID

# ---- T9: fail diagnostic bans freeform live-context (CDT-85 AC-8) ----
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t9.err")
RC=$?
set -e
if [ "$RC" -eq 1 ] \
   && grep -qi 'could not resolve this session' "$WORK/t9.err" \
   && grep -qi 'freeform' "$WORK/t9.err" \
   && grep -qiE 'Non-Claude|Grok' "$WORK/t9.err"; then ok
else bad "T9 honesty diagnostic rc=$RC err=$(cat "$WORK/t9.err")"; fi

# ---- T10: write session-id bridge on success (CDT-85 AC-4) ----
export CLAUDE_SESSION_ID="$SID"
export HANDOFF_BRIDGE="$WORK/bridge-write.json"
rm -f "$HANDOFF_BRIDGE"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t10.err")
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$HANDOFF_BRIDGE" ] \
   && grep -q "\"session_id\": \"$SID\"" "$HANDOFF_BRIDGE" \
   && grep -q 'transcript_path' "$HANDOFF_BRIDGE" \
   && grep -q 'discover-warm' "$HANDOFF_BRIDGE"; then ok
else bad "T10 bridge write rc=$RC bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null) err=$(cat "$WORK/t10.err")"; fi
unset CLAUDE_SESSION_ID HANDOFF_BRIDGE

# ---- T11: read session-id from bridge when env empty (CDT-85) ----
export HANDOFF_BRIDGE="$WORK/bridge-read.json"
# Point bridge at NEW transcript path
python3 -c '
import json, sys
json.dump({
  "session_id": sys.argv[1],
  "transcript_path": sys.argv[2],
  "updated_at": "2026-07-26T00:00:00Z",
  "source": "test",
}, open(sys.argv[3], "w"), indent=2)
' "$SID" "$NEW" "$HANDOFF_BRIDGE"
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
# Hide projects dir so stem search cannot win without bridge
export CLAUDE_PROJECTS_DIR="$WORK/projects-empty"
mkdir -p "$CLAUDE_PROJECTS_DIR"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t11.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$SID" ] && [ -f "$GOT_TR" ] && [ "$GOT_TR" -ef "$NEW" ]; then ok
else bad "T11 bridge read rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t11.err")"; fi
# restore projects dir for remaining tests
export CLAUDE_PROJECTS_DIR="$WORK/projects"
unset HANDOFF_BRIDGE

# ---- T12: cwd-newest project dir bridge when env empty (CDT-85) ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH HANDOFF_BRIDGE HANDOFF_DIR
export CLAUDE_PROJECTS_DIR="$WORK/projects"
# Encode a fake abs cwd into projects layout
FAKE_CWD="$WORK/fake-proj"
mkdir -p "$FAKE_CWD"
ENC=$(printf '%s' "$FAKE_CWD" | sed 's|/|-|g')
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENC"
CW_SID="cwd-bridge-sess-99"
CW_TR="$CLAUDE_PROJECTS_DIR/$ENC/${CW_SID}.jsonl"
printf '{"type":"user","uuid":"cw1"}\n' >"$CW_TR"
export CLAUDE_CWD="$FAKE_CWD"
# Isolate bridge write
export HANDOFF_BRIDGE="$WORK/bridge-cwd.json"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t12.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$CW_SID" ] && [ -f "$GOT_TR" ] && [ "$GOT_TR" -ef "$CW_TR" ]; then ok
else bad "T12 cwd-newest rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t12.err")"; fi
unset CLAUDE_CWD HANDOFF_BRIDGE

echo
echo "discover-warm-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
