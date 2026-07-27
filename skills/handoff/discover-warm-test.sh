#!/usr/bin/env bash
# discover-warm-test.sh — CDT-79-6 / CDT-85 / CDT-92 warm session discovery.
# Run: bash skills/handoff/discover-warm-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DISCOVER="$HERE/discover-warm.sh"
FIXTURE="$HERE/fixtures/grok-chat-mini.jsonl"
ADAPTER="$HERE/grok-to-claude-jsonl.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/discover-warm-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Isolate env so ambient session vars / live Grok sessions cannot leak.
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH GROK_CWD CLAUDE_CWD
unset HANDOFF_BRIDGE HANDOFF_DIR
export CLAUDE_PROJECTS_DIR="$WORK/projects"
export GROK_SESSIONS_DIR="$WORK/grok-sessions"
export GROK_ADAPTER="$ADAPTER"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj-a" "$CLAUDE_PROJECTS_DIR/proj-b" "$GROK_SESSIONS_DIR"
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

# =====================================================================
# CDT-92 dual-host (Grok) cases — append only; Claude T0–T12 must stay green
# =====================================================================

# Helper: install fixture chat_history under GROK_SESSIONS_DIR/<urlenc>/<sid>/
install_grok_session() {
  local sid="$1" dest_dir enc cwd
  cwd="${2:-$WORK/fake-grok-cwd}"
  mkdir -p "$cwd"
  enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$cwd")
  dest_dir="$GROK_SESSIONS_DIR/$enc/$sid"
  mkdir -p "$dest_dir"
  cp "$FIXTURE" "$dest_dir/chat_history.jsonl"
  printf '%s\n' "$dest_dir/chat_history.jsonl"
}

# ---- T13: GROK_TRANSCRIPT_PATH → sid from parent dir; prepare-ready has phrase ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH HANDOFF_BRIDGE HANDOFF_DIR CLAUDE_CWD
export GROK_SESSIONS_DIR="$WORK/grok-sessions"
export CLAUDE_PROJECTS_DIR="$WORK/projects-empty-t13"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$GROK_SESSIONS_DIR"
G13_SID="grok-t13-sess-001"
G13_CWD="$WORK/fake-grok-cwd-t13"
G13_SRC=$(install_grok_session "$G13_SID" "$G13_CWD")
export GROK_TRANSCRIPT_PATH="$G13_SRC"
export GROK_CWD="$G13_CWD"
export HANDOFF_BRIDGE="$WORK/bridge-t13.json"
rm -f "$HANDOFF_BRIDGE"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t13.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G13_SID" ] && [ -f "$GOT_TR" ] \
   && grep -q 'message' "$GOT_TR" \
   && grep -q 'CDT92-FIXTURE-PHRASE-ALPHA' "$GOT_TR"; then ok
else bad "T13 GROK_TRANSCRIPT_PATH rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t13.err")"; fi
unset GROK_TRANSCRIPT_PATH GROK_CWD HANDOFF_BRIDGE

# ---- T14: cwd-newest Grok mtime wins among sessions ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH HANDOFF_BRIDGE
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t14"
export CLAUDE_PROJECTS_DIR="$WORK/projects-empty-t14"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$GROK_SESSIONS_DIR"
G14_CWD="$WORK/fake-grok-cwd-t14"
G14_OLD_SID="grok-t14-old"
G14_NEW_SID="grok-t14-new"
G14_OLD=$(install_grok_session "$G14_OLD_SID" "$G14_CWD")
G14_NEW=$(install_grok_session "$G14_NEW_SID" "$G14_CWD")
touch -d "2020-01-01 00:00:00" "$G14_OLD" 2>/dev/null || touch -t 202001010000 "$G14_OLD"
touch "$G14_NEW"
export GROK_CWD="$G14_CWD"
export HANDOFF_BRIDGE="$WORK/bridge-t14.json"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t14.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G14_NEW_SID" ] && [ -f "$GOT_TR" ]; then ok
else bad "T14 cwd-newest Grok rc=$RC sid=$GOT_SID want=$G14_NEW_SID err=$(cat "$WORK/t14.err")"; fi
unset GROK_CWD HANDOFF_BRIDGE

# ---- T15: stale Claude bridge loses to live Grok (AC3) ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t15"
export CLAUDE_PROJECTS_DIR="$WORK/projects-t15"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj-a" "$GROK_SESSIONS_DIR"
# Stale Claude bridge pointing at Claude jsonl
CLAUDE_STALE_SID="claude-stale-bridge-99"
CLAUDE_STALE_TR="$CLAUDE_PROJECTS_DIR/proj-a/${CLAUDE_STALE_SID}.jsonl"
printf '{"type":"user","uuid":"stale"}\n' >"$CLAUDE_STALE_TR"
export HANDOFF_BRIDGE="$WORK/bridge-t15-stale.json"
python3 -c '
import json, sys
json.dump({
  "session_id": sys.argv[1],
  "transcript_path": sys.argv[2],
  "updated_at": "2020-01-01T00:00:00Z",
  "source": "stale-claude",
  "host": "claude",
}, open(sys.argv[3], "w"), indent=2)
' "$CLAUDE_STALE_SID" "$CLAUDE_STALE_TR" "$HANDOFF_BRIDGE"
# Live Grok session for cwd
G15_SID="grok-t15-live"
G15_CWD="$WORK/fake-grok-cwd-t15"
G15_SRC=$(install_grok_session "$G15_SID" "$G15_CWD")
export GROK_CWD="$G15_CWD"
# Also plant Claude cwd-newest so Claude path would resolve if Grok skipped
export CLAUDE_CWD="$G15_CWD"
ENC15=$(printf '%s' "$G15_CWD" | sed 's|/|-|g')
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENC15"
printf '{"type":"user","uuid":"cwd-claude"}\n' \
  >"$CLAUDE_PROJECTS_DIR/$ENC15/claude-cwd-tip.jsonl"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t15.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G15_SID" ] && [ -f "$GOT_TR" ] \
   && grep -q 'CDT92-FIXTURE-PHRASE-ALPHA' "$GOT_TR" \
   && [ "$GOT_SID" != "$CLAUDE_STALE_SID" ]; then ok
else bad "T15 AC3 Grok over stale Claude bridge rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t15.err")"; fi
# Bridge rewritten to Grok id
if [ -f "$HANDOFF_BRIDGE" ] \
   && grep -q "\"session_id\": \"$G15_SID\"" "$HANDOFF_BRIDGE" \
   && grep -q '"host": "grok"' "$HANDOFF_BRIDGE"; then ok
else bad "T15b bridge rewrite to Grok bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null)"; fi
unset GROK_CWD CLAUDE_CWD HANDOFF_BRIDGE

# ---- T16: CLAUDE_TRANSCRIPT_PATH pointing at Grok chat_history (AC2.2) ----
unset CLAUDE_SESSION_ID SESSION_ID TRANSCRIPT_PATH GROK_SESSION_ID GROK_TRANSCRIPT_PATH
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t16"
export CLAUDE_PROJECTS_DIR="$WORK/projects-empty-t16"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$GROK_SESSIONS_DIR"
G16_SID="grok-t16-via-claude-env"
G16_CWD="$WORK/fake-grok-cwd-t16"
G16_SRC=$(install_grok_session "$G16_SID" "$G16_CWD")
export CLAUDE_TRANSCRIPT_PATH="$G16_SRC"
export GROK_CWD="$G16_CWD"
export HANDOFF_BRIDGE="$WORK/bridge-t16.json"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t16.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G16_SID" ] && [ -f "$GOT_TR" ] \
   && grep -q 'CDT92-FIXTURE-PHRASE-ALPHA' "$GOT_TR"; then ok
else bad "T16 CLAUDE_TRANSCRIPT_PATH=Grok chat_history rc=$RC sid=$GOT_SID err=$(cat "$WORK/t16.err")"; fi
unset CLAUDE_TRANSCRIPT_PATH GROK_CWD HANDOFF_BRIDGE

# ---- T17: Claude-only path still works when no Grok (AC9 regression) ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH GROK_CWD CLAUDE_CWD
export GROK_SESSIONS_DIR="$WORK/grok-sessions-empty-t17"
export CLAUDE_PROJECTS_DIR="$WORK/projects"
mkdir -p "$GROK_SESSIONS_DIR"
export CLAUDE_SESSION_ID="$SID"
export HANDOFF_BRIDGE="$WORK/bridge-t17.json"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t17.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$SID" ] && [ -f "$GOT_TR" ] && [ "$GOT_TR" -ef "$NEW" ]; then ok
else bad "T17 Claude-only regression rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t17.err")"; fi
# host=claude on bridge
if [ -f "$HANDOFF_BRIDGE" ] && grep -q '"host": "claude"' "$HANDOFF_BRIDGE"; then ok
else bad "T17b bridge host=claude bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null)"; fi
unset CLAUDE_SESSION_ID HANDOFF_BRIDGE

# ---- T18: bridge host + source path on Grok success (AC12/AC13) ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t18"
export CLAUDE_PROJECTS_DIR="$WORK/projects-empty-t18"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$GROK_SESSIONS_DIR"
G18_SID="grok-t18-bridge"
G18_CWD="$WORK/fake-grok-cwd-t18"
G18_SRC=$(install_grok_session "$G18_SID" "$G18_CWD")
export GROK_SESSION_ID="$G18_SID"
export GROK_CWD="$G18_CWD"
export HANDOFF_BRIDGE="$WORK/bridge-t18.json"
rm -f "$HANDOFF_BRIDGE"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t18.err")
RC=$?
set -e
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ -f "$HANDOFF_BRIDGE" ] \
   && grep -q "\"session_id\": \"$G18_SID\"" "$HANDOFF_BRIDGE" \
   && grep -q '"host": "grok"' "$HANDOFF_BRIDGE" \
   && grep -q 'chat_history.jsonl' "$HANDOFF_BRIDGE" \
   && ! grep -q 'handoff-grok-adapt' "$HANDOFF_BRIDGE" \
   && [ -f "$GOT_TR" ] && grep -q 'message' "$GOT_TR"; then ok
else bad "T18 bridge source+host rc=$RC bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null) tr=$GOT_TR err=$(cat "$WORK/t18.err")"; fi
unset GROK_SESSION_ID GROK_CWD HANDOFF_BRIDGE

# ---- T19: neither host resolvable → fail hard (AC10) ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH GROK_CWD CLAUDE_CWD HANDOFF_BRIDGE HANDOFF_DIR
export GROK_SESSIONS_DIR="$WORK/grok-sessions-empty-t19"
export CLAUDE_PROJECTS_DIR="$WORK/projects-empty-t19"
mkdir -p "$GROK_SESSIONS_DIR" "$CLAUDE_PROJECTS_DIR"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t19.err")
RC=$?
set -e
if [ "$RC" -eq 1 ] \
   && grep -qi 'could not resolve this session' "$WORK/t19.err" \
   && grep -qi 'freeform' "$WORK/t19.err" \
   && grep -qiE 'Grok|GROK_' "$WORK/t19.err"; then ok
else bad "T19 neither host rc=$RC err=$(cat "$WORK/t19.err")"; fi

# ---- T20: live CLAUDE_SESSION_ID beats Grok cwd-newest (no hijack) ----
# Dual-present: same cwd has Grok chat_history AND resolvable Claude session.
# Bare /handoff in live Claude must not mine yesterday's Grok tip.
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t20"
export CLAUDE_PROJECTS_DIR="$WORK/projects-t20"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj-live" "$GROK_SESSIONS_DIR"
G20_CWD="$WORK/fake-dual-cwd-t20"
G20_GROK_SID="grok-sid-stale-111"
G20_CLAUDE_SID="claude-sid-live-999"
G20_SRC=$(install_grok_session "$G20_GROK_SID" "$G20_CWD")
# Make Grok tip "newer" so a pure mtime heuristic would prefer it
touch "$G20_SRC"
CLAUDE_LIVE_TR="$CLAUDE_PROJECTS_DIR/proj-live/${G20_CLAUDE_SID}.jsonl"
printf '{"type":"user","uuid":"live-claude-u1","message":{"role":"user","content":"LIVE-CLAUDE-SESSION"}}\n' \
  >"$CLAUDE_LIVE_TR"
touch -d "2020-01-01 00:00:00" "$CLAUDE_LIVE_TR" 2>/dev/null \
  || touch -t 202001010000 "$CLAUDE_LIVE_TR"
export CLAUDE_SESSION_ID="$G20_CLAUDE_SID"
export GROK_CWD="$G20_CWD"
export CLAUDE_CWD="$G20_CWD"
export HANDOFF_BRIDGE="$WORK/bridge-t20.json"
rm -f "$HANDOFF_BRIDGE"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t20.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G20_CLAUDE_SID" ] \
   && [ "$GOT_TR" = "$CLAUDE_LIVE_TR" ] \
   && [ "$GOT_SID" != "$G20_GROK_SID" ]; then ok
else bad "T20 Claude env beats Grok cwd rc=$RC sid=$GOT_SID want=$G20_CLAUDE_SID tr=$GOT_TR err=$(cat "$WORK/t20.err")"; fi
if [ -f "$HANDOFF_BRIDGE" ] && grep -q '"host": "claude"' "$HANDOFF_BRIDGE" \
   && grep -q "\"session_id\": \"$G20_CLAUDE_SID\"" "$HANDOFF_BRIDGE"; then ok
else bad "T20b bridge host=claude bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null)"; fi
unset CLAUDE_SESSION_ID GROK_CWD CLAUDE_CWD HANDOFF_BRIDGE

# ---- T21: GROK_SESSION_ID still wins over CLAUDE_SESSION_ID (explicit Grok) ----
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH
unset GROK_TRANSCRIPT_PATH
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t21"
export CLAUDE_PROJECTS_DIR="$WORK/projects-t21"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj-a" "$GROK_SESSIONS_DIR"
G21_CWD="$WORK/fake-dual-cwd-t21"
G21_GROK_SID="grok-sid-explicit-222"
G21_CLAUDE_SID="claude-sid-also-333"
G21_SRC=$(install_grok_session "$G21_GROK_SID" "$G21_CWD")
printf '{"type":"user","uuid":"c21"}\n' \
  >"$CLAUDE_PROJECTS_DIR/proj-a/${G21_CLAUDE_SID}.jsonl"
export GROK_SESSION_ID="$G21_GROK_SID"
export CLAUDE_SESSION_ID="$G21_CLAUDE_SID"
export GROK_CWD="$G21_CWD"
export HANDOFF_BRIDGE="$WORK/bridge-t21.json"
rm -f "$HANDOFF_BRIDGE"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t21.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G21_GROK_SID" ] && [ -f "$GOT_TR" ] \
   && grep -q 'CDT92-FIXTURE-PHRASE-ALPHA' "$GOT_TR"; then ok
else bad "T21 explicit GROK_SESSION_ID wins rc=$RC sid=$GOT_SID err=$(cat "$WORK/t21.err")"; fi
if [ -f "$HANDOFF_BRIDGE" ] && grep -q '"host": "grok"' "$HANDOFF_BRIDGE"; then ok
else bad "T21b bridge host=grok bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null)"; fi
unset GROK_SESSION_ID CLAUDE_SESSION_ID GROK_CWD HANDOFF_BRIDGE

# ---- T22: chat_history outside GROK_SESSIONS_DIR is not a Grok source ----
unset CLAUDE_SESSION_ID SESSION_ID TRANSCRIPT_PATH GROK_SESSION_ID GROK_TRANSCRIPT_PATH
export GROK_SESSIONS_DIR="$WORK/grok-sessions-t22"
export CLAUDE_PROJECTS_DIR="$WORK/projects-t22"
mkdir -p "$GROK_SESSIONS_DIR" "$CLAUDE_PROJECTS_DIR/proj-a"
G22_CLAUDE_SID="claude-sid-t22"
printf '{"type":"user","uuid":"t22"}\n' \
  >"$CLAUDE_PROJECTS_DIR/proj-a/${G22_CLAUDE_SID}.jsonl"
OUTSIDE="$WORK/outside-t22/chat_history.jsonl"
mkdir -p "$(dirname "$OUTSIDE")"
cp "$FIXTURE" "$OUTSIDE"
export CLAUDE_TRANSCRIPT_PATH="$OUTSIDE"
export CLAUDE_SESSION_ID="$G22_CLAUDE_SID"
export HANDOFF_BRIDGE="$WORK/bridge-t22.json"
rm -f "$HANDOFF_BRIDGE"
set +e
OUT=$(bash "$DISCOVER" 2>"$WORK/t22.err")
RC=$?
set -e
GOT_SID=$(printf '%s\n' "$OUT" | sed -n '1p')
GOT_TR=$(printf '%s\n' "$OUT" | sed -n '2p')
# Outside path must not be accepted as Grok (no host:grok / no adapt). Claude sid wins.
# (CLAUDE_TRANSCRIPT_PATH still wins for Claude resolve_transcript path precedence —
# that is separate; the bug was treating any chat_history basename as Grok.)
if [ "$RC" -eq 0 ] && [ "$GOT_SID" = "$G22_CLAUDE_SID" ] \
   && ! printf '%s' "$GOT_TR" | grep -q 'handoff-grok-adapt'; then ok
else bad "T22 outside chat_history not Grok rc=$RC sid=$GOT_SID tr=$GOT_TR err=$(cat "$WORK/t22.err")"; fi
if [ -f "$HANDOFF_BRIDGE" ] && grep -q '"host": "claude"' "$HANDOFF_BRIDGE" \
   && ! grep -q '"host": "grok"' "$HANDOFF_BRIDGE"; then ok
else bad "T22b bridge host=claude bridge=$(cat "$HANDOFF_BRIDGE" 2>/dev/null)"; fi
unset CLAUDE_TRANSCRIPT_PATH CLAUDE_SESSION_ID HANDOFF_BRIDGE

# Restore defaults for cleanliness
export CLAUDE_PROJECTS_DIR="$WORK/projects"
export GROK_SESSIONS_DIR="$WORK/grok-sessions"

echo
echo "discover-warm-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
