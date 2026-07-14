#!/usr/bin/env bash
# webhook-test.sh — bite-tests for skills/notify/webhook.sh (CDV-210)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WH="$HERE/webhook.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# --- unset URL: silent no-op, exit 0 ---
unset AGENT_WEBHOOK_URL
out=$(bash "$WH" task_complete 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unset URL exit 0 silent" || bad "unset URL rc=$rc out='$out'"

# --- empty URL ---
export AGENT_WEBHOOK_URL=""
out=$(bash "$WH" task_complete 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "empty URL exit 0 silent" || bad "empty URL rc=$rc out='$out'"

# --- missing event with URL set ---
export AGENT_WEBHOOK_URL="http://127.0.0.1:1/nope"
out=$(bash "$WH" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "missing event exit 0" || bad "missing event rc=$rc"

# --- unreachable URL: fail-open exit 0 ---
export AGENT_WEBHOOK_URL="http://127.0.0.1:1/nope"
out=$(bash "$WH" error "boom" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "unreachable URL fail-open exit 0" || bad "unreachable URL rc=$rc out='$out'"

# --- dry-run payload shape ---
export AGENT_WEBHOOK_URL="http://example.invalid/hook"
export NOTIFY_DRY_RUN=1
export NOTIFY_SOURCE=orchestrate
export NOTIFY_AGENT=ic4
export NOTIFY_TASK=CDV-210-1
export NOTIFY_TICKET=CDV-210
payload=$(bash "$WH" task_complete "done ok" 2>/dev/null)
rc=$?
unset NOTIFY_DRY_RUN NOTIFY_SOURCE NOTIFY_AGENT NOTIFY_TASK NOTIFY_TICKET

if [ "$rc" -ne 0 ]; then
  bad "dry-run exit $rc"
else
  ok "dry-run exit 0"
  echo "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("event") == "task_complete", d
assert "time" in d and d["time"].endswith("Z"), d
assert d.get("source") == "orchestrate", d
assert d.get("agent") == "ic4", d
assert d.get("task") == "CDV-210-1", d
assert d.get("ticket") == "CDV-210", d
assert d.get("detail") == "done ok", d
' 2>/dev/null && ok "dry-run payload fields" || bad "dry-run payload shape: $payload"
fi

# --- detail truncated to 500 ---
export AGENT_WEBHOOK_URL="http://example.invalid/hook"
export NOTIFY_DRY_RUN=1
long=$(python3 -c 'print("x"*600)')
payload=$(bash "$WH" task_blocked "$long" 2>/dev/null)
rc=$?
unset NOTIFY_DRY_RUN
if [ "$rc" -ne 0 ]; then
  bad "truncate exit $rc"
else
  dlen=$(echo "$payload" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("detail","")))' 2>/dev/null)
  [ "$dlen" = "500" ] && ok "detail truncated to 500" || bad "detail len=$dlen"
fi

# --- optional fields omitted when empty ---
export AGENT_WEBHOOK_URL="http://example.invalid/hook"
export NOTIFY_DRY_RUN=1
unset NOTIFY_AGENT NOTIFY_TASK NOTIFY_TICKET NOTIFY_SOURCE
payload=$(bash "$WH" qa_pass 2>/dev/null)
echo "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["event"] == "qa_pass"
assert "agent" not in d and "task" not in d and "ticket" not in d and "detail" not in d
assert d.get("source") == "orchestrate"
' 2>/dev/null && ok "optional fields omitted" || bad "optional fields: $payload"
unset NOTIFY_DRY_RUN AGENT_WEBHOOK_URL

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
