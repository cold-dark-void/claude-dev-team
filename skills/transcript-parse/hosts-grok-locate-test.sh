#!/usr/bin/env bash
# hosts.py Grok cwd-bucket locate (CDT-156 T2)
# Unit-style: temp sessions tree — newest + by-id + missing + GROK_TRANSCRIPT_PATH.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hosts-grok-locate.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SESS="$WORK/sessions"
CWD="$WORK/project"
mkdir -p "$CWD"
# Absolute cwd for bucket encoding (matches live Grok layout).
CWD="$(cd "$CWD" && pwd)"

# Encode cwd the same way hosts.py does (quote safe='').
ENC="$(CWD_RAW="$CWD" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
BUCKET="$SESS/$ENC"
mkdir -p "$BUCKET/sid-old" "$BUCKET/sid-new" "$BUCKET/sid-target"

printf 'old\n' >"$BUCKET/sid-old/chat_history.jsonl"
printf 'new\n' >"$BUCKET/sid-new/chat_history.jsonl"
printf 'target\n' >"$BUCKET/sid-target/chat_history.jsonl"

# Ensure mtime order: old < target < new
touch -d "2020-01-01 00:00:00" "$BUCKET/sid-old/chat_history.jsonl"
touch -d "2021-06-15 12:00:00" "$BUCKET/sid-target/chat_history.jsonl"
touch -d "2022-12-31 23:59:59" "$BUCKET/sid-new/chat_history.jsonl"

# Different cwd bucket must not win newest
OTHER_CWD="$WORK/other"
mkdir -p "$OTHER_CWD"
OTHER_CWD="$(cd "$OTHER_CWD" && pwd)"
OTHER_ENC="$(CWD_RAW="$OTHER_CWD" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
mkdir -p "$SESS/$OTHER_ENC/sid-other"
printf 'other\n' >"$SESS/$OTHER_ENC/sid-other/chat_history.jsonl"
touch -d "2030-01-01 00:00:00" "$SESS/$OTHER_ENC/sid-other/chat_history.jsonl"

export PATH="$HERE:$PATH"
unset GROK_TRANSCRIPT_PATH GROK_SESSIONS_DIR || true

HOSTS_PY=(python3 "$HERE/hosts.py")

# ---- by-id ----
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --session-id sid-target --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$BUCKET/sid-target/chat_history.jsonl" ]; then
  pass "by-id finds sid-target under cwd bucket"
else
  bad "by-id rc=$RC out=$OUT expected=$BUCKET/sid-target/chat_history.jsonl"
fi

# ---- newest ----
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$BUCKET/sid-new/chat_history.jsonl" ]; then
  pass "newest mtime under cwd bucket only"
else
  bad "newest rc=$RC out=$OUT expected=$BUCKET/sid-new/chat_history.jsonl"
fi

# ---- missing id ----
set +e
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --session-id no-such-sid --sessions-dir "$SESS" 2>"$WORK/miss.err")"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
  pass "missing id → exit 1 empty stdout"
else
  bad "missing id rc=$RC out=$OUT err=$(cat "$WORK/miss.err")"
fi

# ---- missing cwd bucket ----
EMPTY_CWD="$WORK/empty-cwd"
mkdir -p "$EMPTY_CWD"
EMPTY_CWD="$(cd "$EMPTY_CWD" && pwd)"
set +e
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$EMPTY_CWD" --sessions-dir "$SESS" 2>"$WORK/empty.err")"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
  pass "empty cwd bucket → exit 1"
else
  bad "empty bucket rc=$RC out=$OUT err=$(cat "$WORK/empty.err")"
fi

# ---- GROK_TRANSCRIPT_PATH honor (under root) ----
export GROK_TRANSCRIPT_PATH="$BUCKET/sid-old/chat_history.jsonl"
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$BUCKET/sid-old/chat_history.jsonl" ]; then
  pass "GROK_TRANSCRIPT_PATH pin under sessions root"
else
  bad "env pin rc=$RC out=$OUT"
fi

# ---- GROK_TRANSCRIPT_PATH outside root ignored ----
OUTSIDE="$WORK/outside/chat_history.jsonl"
mkdir -p "$(dirname "$OUTSIDE")"
printf 'outside\n' >"$OUTSIDE"
export GROK_TRANSCRIPT_PATH="$OUTSIDE"
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$BUCKET/sid-new/chat_history.jsonl" ]; then
  pass "outside GROK_TRANSCRIPT_PATH ignored → newest"
else
  bad "outside env rc=$RC out=$OUT"
fi
unset GROK_TRANSCRIPT_PATH

# ---- import API ----
python3 - <<PY
import os, sys
sys.path.insert(0, "$HERE")
from hosts import locate, urlencode_cwd, HOSTS
assert "grok" in HOSTS
enc = urlencode_cwd("$CWD")
assert enc == "$ENC", (enc, "$ENC")
p = locate("grok", "sid-target", "$CWD", sessions_dir="$SESS")
assert p == "$BUCKET/sid-target/chat_history.jsonl", p
p2 = locate("grok", None, "$CWD", sessions_dir="$SESS")
assert p2 == "$BUCKET/sid-new/chat_history.jsonl", p2
assert locate("grok", "missing", "$CWD", sessions_dir="$SESS") is None
print("import-ok")
PY
if [ $? -eq 0 ]; then pass "import API locate/urlencode_cwd"; else bad "import API"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
