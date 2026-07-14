#!/usr/bin/env bash
# friction-capture-test.sh — unit tests for friction-capture.sh (SPEC-012 M1–M3/M7).
# Run: bash skills/retro-gate/friction-capture-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CAPTURE="$ROOT/.claude/hooks/friction-capture.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

[ -f "$CAPTURE" ] || { echo "FAIL: missing $CAPTURE"; exit 1; }

# Isolated ledger via FRICTION_LEDGER; still need a git repo for MROOT.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/friction-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/friction.jsonl"
export FRICTION_LEDGER="$LEDGER"
# Run capture from a real git worktree so MROOT resolves (FRICTION_LEDGER overrides path).
cd "$ROOT" || exit 1

feed() {
  # feed <json-string> — invoke capture; ignore exit (must be 0)
  local json="$1"
  local rc
  printf '%s' "$json" | bash "$CAPTURE" >/dev/null 2>"$TMP/err"
  rc=$?
  echo "$rc"
}

# ---- M1: append one line with schema keys only ----
rm -f "$LEDGER"
RC=$(feed '{"session_id":"sess-a","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"false"},"tool_result":"SECRET_CANARY_BODY_XYZ"}')
if [ "$RC" != "0" ]; then
  bad "M1 exit want 0 got $RC err=$(cat "$TMP/err")"
elif [ ! -f "$LEDGER" ]; then
  bad "M1 ledger not created"
else
  N=$(wc -l < "$LEDGER" | tr -d ' ')
  if [ "$N" != "1" ]; then
    bad "M1 want 1 line got $N"
  else
    if python3 -c '
import json,sys
d=json.loads(open(sys.argv[1]).read())
need={"ts","session_id","event","tool","path"}
if set(d.keys())!=need: sys.exit(2)
if d["session_id"]!="sess-a": sys.exit(3)
if d["event"]!="PostToolUseFailure": sys.exit(4)
if d["tool"]!="Bash": sys.exit(5)
if d["path"]!="": sys.exit(6)
' "$LEDGER" 2>/dev/null; then
      ok "M1 append schema keys"
    else
      bad "M1 schema mismatch: $(cat "$LEDGER")"
    fi
  fi
fi

# ---- M2: no payload bodies / canary ----
rm -f "$LEDGER"
CANARY="CANARY_MULTI_KB_$(python3 -c 'print("X"*4096)')"
RC=$(feed "{\"session_id\":\"sess-b\",\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x.py\",\"content\":\"$CANARY\"},\"tool_result\":\"$CANARY\",\"error\":\"$CANARY\"}")
if [ "$RC" != "0" ]; then
  bad "M2 exit want 0 got $RC"
elif grep -q 'CANARY' "$LEDGER" 2>/dev/null; then
  bad "M2 canary leaked into ledger: $(head -c 200 "$LEDGER")"
else
  if python3 -c '
import json,sys
d=json.loads(open(sys.argv[1]).read())
assert d["tool"]=="Write"
assert d["path"]=="/tmp/x.py"
assert set(d.keys())=={"ts","session_id","event","tool","path"}
' "$LEDGER" 2>/dev/null; then
    ok "M2 no body fields / canary absent"
  else
    bad "M2 path/tool extract failed: $(cat "$LEDGER")"
  fi
fi

# ---- path from tool_input.path fallback ----
rm -f "$LEDGER"
RC=$(feed '{"session_id":"sess-c","hook_event_name":"PermissionDenied","tool_name":"Edit","tool_input":{"path":"/p/q.rs"}}')
if python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read()); sys.exit(0 if d.get("path")=="/p/q.rs" and d.get("event")=="PermissionDenied" else 1)' "$LEDGER" 2>/dev/null; then
  ok "path key + PermissionDenied event"
else
  bad "path fallback: $(cat "$LEDGER" 2>/dev/null)"
fi

# ---- StopFailure (no tool) ----
rm -f "$LEDGER"
RC=$(feed '{"session_id":"sess-d","hook_event_name":"StopFailure","reason":"rate_limit SECRET"}')
if python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read()); sys.exit(0 if d.get("event")=="StopFailure" and d.get("tool")=="" and "SECRET" not in open(sys.argv[1]).read() else 1)' "$LEDGER" 2>/dev/null; then
  ok "StopFailure no tool / no reason body"
else
  bad "StopFailure: $(cat "$LEDGER" 2>/dev/null)"
fi

# ---- skip empty session_id ----
rm -f "$LEDGER"
RC=$(feed '{"session_id":"","hook_event_name":"PostToolUseFailure","tool_name":"Bash"}')
if [ "$RC" != "0" ]; then
  bad "empty session_id exit want 0 got $RC"
elif [ -f "$LEDGER" ] && [ -s "$LEDGER" ]; then
  bad "empty session_id should not append"
else
  ok "empty session_id skips append"
fi

# ---- M3: line rotation keeps newest ----
rm -f "$LEDGER"
export FRICTION_LEDGER_MAX_LINES=3
export FRICTION_LEDGER_MAX_BYTES=1000000
for i in 1 2 3 4 5; do
  feed "{\"session_id\":\"rot\",\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"T$i\"}" >/dev/null
done
N=$(wc -l < "$LEDGER" | tr -d ' ')
LAST=$(tail -1 "$LEDGER")
if [ "$N" -le 3 ] && echo "$LAST" | grep -q '"tool":"T5"'; then
  ok "M3 line rotation keeps newest (n=$N)"
else
  bad "M3 line rotation n=$N last=$LAST full=$(cat "$LEDGER")"
fi
unset FRICTION_LEDGER_MAX_LINES FRICTION_LEDGER_MAX_BYTES

# ---- M3: byte rotation ----
rm -f "$LEDGER"
export FRICTION_LEDGER_MAX_LINES=10000
export FRICTION_LEDGER_MAX_BYTES=200
# each line ~100+ bytes with long tool name padding
for i in 1 2 3 4 5 6 7 8; do
  feed "{\"session_id\":\"byt\",\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"TOOL_PAD_$(printf '%03d' $i)_XXXXXXXX\"}" >/dev/null
done
SZ=$(wc -c < "$LEDGER" | tr -d ' ')
N=$(wc -l < "$LEDGER" | tr -d ' ')
if [ "$SZ" -le 200 ] && [ "$N" -ge 1 ]; then
  ok "M3 byte rotation size=$SZ lines=$N"
else
  bad "M3 byte rotation size=$SZ (want <=200) lines=$N"
fi
unset FRICTION_LEDGER_MAX_LINES FRICTION_LEDGER_MAX_BYTES

# ---- M7: unwritable ledger dir → exit 0 ----
export FRICTION_LEDGER="/proc/does-not-exist-friction/ledger.jsonl"
RC=$(feed '{"session_id":"x","hook_event_name":"PostToolUseFailure","tool_name":"Bash"}')
if [ "$RC" = "0" ]; then
  ok "M7 unwritable ledger exit 0"
else
  bad "M7 want exit 0 got $RC"
fi
export FRICTION_LEDGER="$LEDGER"

# ---- unparseable JSON → exit 0 ----
RC=$(feed 'NOT JSON{{{')
if [ "$RC" = "0" ]; then
  ok "unparseable JSON exit 0"
else
  bad "unparseable want 0 got $RC"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
