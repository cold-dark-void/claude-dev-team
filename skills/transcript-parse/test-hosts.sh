#!/usr/bin/env bash
# hosts.py Grok adapter unit tests (CDT-156 T6 / AC6)
# locate (newest/by-id/missing) + scoring normalize + handoff skip tool_result
# Run: bash skills/transcript-parse/test-hosts.sh
set -euo pipefail

# CDT-285: GNU/BSD-safe mtime helpers (touch -d / find -printf are absent on macOS).
# shellcheck source=../../tests/lib/mtimes.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../tests/lib/mtimes.sh"
# shellcheck source=../../tests/lib/path.sh
. "$HERE/../../tests/lib/path.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-hosts.XXXXXX")"
cleanup() { rm -rf "$WORK"; hermetic_cleanup; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Locate suite (T2) — re-run dedicated script so one entrypoint covers AC6
# ---------------------------------------------------------------------------
set +e
LOC_OUT=$(bash "$HERE/hosts-grok-locate-test.sh" 2>&1)
LOC_RC=$?
set -e
if [ "$LOC_RC" -eq 0 ]; then
  # One parent result. Do not re-count the child suite's PASS lines.
  pass "hosts-grok-locate-test.sh exit 0"
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

# CDT-309 — direct <sid>.jsonl does not open a sibling transcript.
PROJ="$HOME/.claude/projects/wp402"
mkdir -p "$PROJ"
SIDF="wp402-direct"
printf '%s\n' '{"type":"user","uuid":"wp402-direct","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"hi"}}' > "$PROJ/${SIDF}.jsonl"
printf 'not json\n' > "$PROJ/poison.jsonl"
chmod 000 "$PROJ/poison.jsonl" || true
SCAN="$WORK/scan.log"
: > "$SCAN"
set +e
OUT=$(ASSEMBLE_SCAN_LOG="$SCAN" python3 "$HERE/assemble.py" locate "$SIDF" 2>"$WORK/loc.err")
LRC=$?
set -e
chmod 644 "$PROJ/poison.jsonl" 2>/dev/null || true
# Both sides canonical: locate returns its own (collapsed) spelling while $PROJ
# carries hermetic HOME's trailing-slash `//` (macOS lane).
if [ "$LRC" -eq 0 ] \
   && [ "$(path_canon "$OUT")" = "$(path_canon "$PROJ/${SIDF}.jsonl")" ] \
   && [ ! -s "$SCAN" ]; then
  pass "direct hit does not scan siblings"
else
  bad "direct hit rc=$LRC out=$OUT scan=$(cat "$SCAN" 2>/dev/null) err=$(head -c 160 "$WORK/loc.err")"
fi

# W1-13 — a dict uuid does not abort assemble; the string uuid survives.
DICT="$WORK/dict-uuid.jsonl"
printf '%s\n' '{"uuid":{"x":1},"timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"bad"}}' > "$DICT"
printf '%s\n' '{"uuid":"ok-uuid","timestamp":"2020-01-01T00:00:01.000Z","message":{"role":"user","content":"good"}}' >> "$DICT"
set +e
python3 "$HERE/assemble.py" assemble-file "$DICT" >"$WORK/dict.out" 2>"$WORK/dict.err"
DRC=$?
set -e
if [ "$DRC" -eq 0 ] && grep -q 'ok-uuid' "$WORK/dict.out" && ! grep -q '"x": 1' "$WORK/dict.out" && ! grep -q '"x":1' "$WORK/dict.out"; then
  pass "dict uuid skipped"
else
  bad "dict uuid rc=$DRC err=$(head -c 160 "$WORK/dict.err")"
fi

# W1-13 — utf-8 transcripts under LC_ALL=C.
UNI="$WORK/uni.jsonl"
printf '%s\n' '{"uuid":"u-uni","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"héllo"}}' > "$UNI"
set +e
UOUT=$(LC_ALL=C python3 "$HERE/assemble.py" assemble-file "$UNI" 2>"$WORK/uni.err")
URC=$?
set -e
if [ "$URC" -eq 0 ] && printf '%s\n' "$UOUT" | grep -q 'héllo'; then
  pass "utf-8 under LC_ALL=C"
else
  bad "utf-8 under LC_ALL=C rc=$URC"
fi

# CDT-277 F20 — is_error reads only the first line.
set +e
python3 - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from grok_normalize import is_error_from_content
assert is_error_from_content("exit: 1\n") is True
assert is_error_from_content("exit: 0\n") is False
assert is_error_from_content("notes mention exit: 1 later\n") is False
assert is_error_from_content("ok\nexit: 1\n") is False
PY
FRC=$?
set -e
if [ "$FRC" -eq 0 ]; then
  pass "F20 is_error is the first line only"
else
  bad "F20 is_error first-line rc=$FRC"
fi

# W1-13 — cold prepare calls assemble.locate once.
UUID="11111111-1111-4111-8111-111111111111"
PDIR="$HOME/.claude/projects/-wp402"
mkdir -p "$PDIR"
printf '%s\n' "{\"type\":\"user\",\"uuid\":\"$UUID\",\"timestamp\":\"2020-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}" > "$PDIR/$UUID.jsonl"
touch_ago "$PDIR/$UUID.jsonl" 120
LOG="$WORK/locate.log"
: > "$LOG"
set +e
(
  cd "$WORK" || exit 1
  ASSEMBLE_LOCATE_LOG="$LOG" bash "$HERE/../handoff/prepass.sh" prepare --uuid "$UUID" >"$WORK/prep.out" 2>"$WORK/prep.err"
)
set -e
N=$(grep -c '^locate$' "$LOG" || true)
if [ "$N" -eq 1 ]; then
  pass "cold prepare locates once"
else
  bad "cold prepare locate count=$N err=$(head -c 200 "$WORK/prep.err")"
fi

# WP 4-05 — dash-encode, .. session id, mixed timestamps, locate parameter.
set +e
python3 - "$HERE" "$WORK" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import assemble
import hosts
from grok_normalize import normalize_to_file, sanitize_session_id

cwd = "/tmp/my.proj/.worktrees/wt_1"
enc = hosts.dash_encode_cwd(cwd)
assert "." not in enc and "_" not in enc, enc
assert enc == os.path.abspath(cwd).replace("/", "-").replace(".", "-").replace("_", "-"), enc

safe = sanitize_session_id("foo..bar")
assert ".." not in safe, safe
assert safe == "foo-bar", safe

src = os.path.join(sys.argv[2], "mix.jsonl")
with open(src, "w", encoding="utf-8") as fh:
    fh.write('{"type":"user","content":"first","timestamp":"2026-09-01T00:00:00Z"}\n')
    fh.write('{"type":"assistant","content":"second"}\n')
    fh.write('{"type":"user","content":"third","timestamp":"2026-09-01T00:00:02Z"}\n')
out = os.path.join(sys.argv[2], "mix-out.jsonl")
normalize_to_file(src, cwd="/tmp/proj", session_id="foo..bar", mode="scoring", out_path=out)
rows = [__import__("json").loads(line) for line in open(out, encoding="utf-8") if line.strip()]
assert [r["message"]["content"][0]["text"] for r in rows] == ["first", "second", "third"]
assert rows[1]["timestamp"] >= rows[0]["timestamp"], rows[1]["timestamp"]
assert rows[2]["timestamp"] >= rows[1]["timestamp"]
assert all(r["sessionId"] == "foo-bar" for r in rows), rows[0]["sessionId"]

root = os.path.join(sys.argv[2], "projects-param")
os.makedirs(root)
uid = "param-sid-1"
os.makedirs(os.path.join(root, "proj"))
path = os.path.join(root, "proj", uid + ".jsonl")
with open(path, "w", encoding="utf-8") as fh:
    fh.write('{"uuid":"%s","timestamp":"2020-01-01T00:00:00Z"}\n' % uid)
found = assemble.locate(uid, projects_dir=root)
# Both sides canonical: locate returns its own spelling of the same file.
assert os.path.realpath(found) == os.path.realpath(path), found
# The module global is unchanged by the parameter.
assert assemble.PROJECTS_DIR != root
PY
PRC=$?
set -e
if [ "$PRC" -eq 0 ]; then
  pass "WP405 encode, sanitize, timestamp, locate parameter"
else
  bad "WP405 encode/sanitize/timestamp/locate rc=$PRC"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
