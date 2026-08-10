#!/usr/bin/env bash
# hosts.py Grok adapter unit tests (CDT-156 T6 / AC6)
# locate (newest/by-id/missing) + scoring normalize + handoff skip tool_result
# Run: bash skills/transcript-parse/test-hosts.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-hosts.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Locate suite (T2) — re-run dedicated script so one entrypoint covers AC6
# ---------------------------------------------------------------------------
set +e
LOC_OUT=$(bash "$HERE/hosts-grok-locate-test.sh" 2>&1)
LOC_RC=$?
set -e
if [ "$LOC_RC" -eq 0 ]; then
  # Count "PASS " lines from child (avoid double-counting its summary)
  LOC_N=$(printf '%s\n' "$LOC_OUT" | grep -c '^PASS ' || true)
  i=0
  while [ "$i" -lt "${LOC_N:-0}" ]; do
    pass "locate-suite[$i]"
    i=$((i + 1))
  done
  pass "hosts-grok-locate-test.sh exit 0 ($LOC_N cases)"
else
  bad "hosts-grok-locate-test.sh failed rc=$LOC_RC"
  printf '%s\n' "$LOC_OUT" >&2
fi

# ---------------------------------------------------------------------------
# Normalize scoring (T3) — fixture grok-chat-scoring.jsonl
# ---------------------------------------------------------------------------
FIX="$HERE/fixtures/grok-chat-scoring.jsonl"
if [ ! -f "$FIX" ]; then
  bad "missing fixture $FIX"
else
  NORM_OUT="$WORK/scoring.jsonl"
  set +e
  python3 "$HERE/grok_normalize.py" \
    --in "$FIX" \
    --out "$NORM_OUT" \
    --cwd /home/proj \
    --session-id "cdt156-norm" \
    --mode scoring >"$WORK/norm-stdout.txt" 2>"$WORK/norm-stderr.txt"
  NRC=$?
  set -e
  if [ "$NRC" -ne 0 ]; then
    bad "scoring normalize exit $NRC err=$(cat "$WORK/norm-stderr.txt")"
  else
    pass "scoring normalize exit 0"
  fi

  # Assert via Python on normalized feed
  set +e
  python3 - "$NORM_OUT" <<'PY'
import json, sys
path = sys.argv[1]
rows = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

assert rows, "empty normalize output"

# unique uuids
uuids = [r.get("uuid") for r in rows]
assert all(isinstance(u, str) and u for u in uuids), uuids
assert len(uuids) == len(set(uuids)), f"duplicate uuids: {uuids}"
# stable shape <session>-L<n>
assert all(u.startswith("cdt156-norm-L") for u in uuids), uuids

tool_results = []
tool_uses = []
for r in rows:
    content = (r.get("message") or {}).get("content") or []
    if not isinstance(content, list):
        continue
    for b in content:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_result":
            tool_results.append(b)
        if b.get("type") == "tool_use":
            tool_uses.append(b)

assert tool_results, "expected tool_result blocks in scoring mode"

# exit:1 → is_error true; exit:0 → false; no exit line → false
by_id = {b.get("tool_use_id"): b for b in tool_results}
assert by_id.get("call-bash-err", {}).get("is_error") is True, by_id.get("call-bash-err")
assert by_id.get("call-write-1", {}).get("is_error") is False, by_id.get("call-write-1")
assert by_id.get("call-sr-1", {}).get("is_error") is False, by_id.get("call-sr-1")
assert by_id.get("call-bash-ok", {}).get("is_error") is False, by_id.get("call-bash-ok")
assert by_id.get("call-read-1", {}).get("is_error") is False, by_id.get("call-read-1")

names = {b.get("id"): b.get("name") for b in tool_uses}
assert names.get("call-write-1") == "Write", names
assert names.get("call-sr-1") == "Edit", names
# unmapped names pass through
assert names.get("call-bash-err") == "run_terminal_command", names

# system/reasoning/backend_tool_call skipped — no raw type system lines
assert all(r.get("type") in ("user", "assistant") for r in rows)

# meta synthetic_reason → isMeta
meta_users = [r for r in rows if r.get("isMeta")]
assert meta_users, "expected isMeta on synthetic project_instructions user"

print("norm-ok")
PY
  NRC=$?
  set -e
  if [ "$NRC" -eq 0 ]; then
    pass "scoring: is_error exit:1/0 + Write/Edit map + unique uuids"
  else
    bad "scoring normalize assertions failed"
  fi

  # hosts.py normalize CLI path
  set +e
  HOST_OUT=$(python3 "$HERE/hosts.py" normalize \
    --host grok \
    --source "$FIX" \
    --cwd /home/proj \
    --session-id cdt156-cli \
    --mode scoring 2>"$WORK/hosts-norm.err")
  HRC=$?
  set -e
  if [ "$HRC" -eq 0 ] && [ -n "$HOST_OUT" ] && [ -f "$HOST_OUT" ]; then
    set +e
    python3 - "$HOST_OUT" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
tr = 0
for r in rows:
    content = (r.get("message") or {}).get("content") or []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                tr += 1
assert tr >= 1, "hosts normalize scoring must keep tool_result"
print("hosts-norm-ok")
PY
    HRC2=$?
    set -e
    if [ "$HRC2" -eq 0 ]; then
      pass "hosts.py normalize scoring emits tool_result"
    else
      bad "hosts.py normalize missing tool_result in $HOST_OUT"
    fi
  else
    bad "hosts.py normalize rc=$HRC out=$HOST_OUT err=$(cat "$WORK/hosts-norm.err")"
  fi
fi

# ---------------------------------------------------------------------------
# Handoff mode — 0 tool_result
# ---------------------------------------------------------------------------
if [ -f "$FIX" ]; then
  HAND_OUT="$WORK/handoff.jsonl"
  set +e
  python3 "$HERE/grok_normalize.py" \
    --in "$FIX" \
    --out "$HAND_OUT" \
    --cwd /home/proj \
    --session-id "cdt156-hand" \
    --mode handoff >"$WORK/hand-stdout.txt" 2>"$WORK/hand-stderr.txt"
  HRC=$?
  set -e
  if [ "$HRC" -ne 0 ]; then
    bad "handoff normalize exit $HRC err=$(cat "$WORK/hand-stderr.txt")"
  else
    set +e
    python3 - "$HAND_OUT" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert rows
tr = 0
for r in rows:
    content = (r.get("message") or {}).get("content") or []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                tr += 1
assert tr == 0, f"handoff must emit 0 tool_result, got {tr}"
# still has user + assistant
assert any(r.get("type") == "user" for r in rows)
assert any(r.get("type") == "assistant" for r in rows)
print("handoff-ok")
PY
    HRC=$?
    set -e
    if [ "$HRC" -eq 0 ]; then
      pass "handoff mode 0 tool_result"
    else
      bad "handoff mode still has tool_result"
    fi
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
