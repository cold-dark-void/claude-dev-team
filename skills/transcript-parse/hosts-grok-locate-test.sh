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

# =============================================================================
# M5a long-cwd .cwd locate (CDT-218 T1) — GROK_SESSIONS_DIR fixture only
# =============================================================================
export GROK_SESSIONS_DIR="$SESS"
OP_GROK="$(printf '%s' "$HOME/.grok/sessions")"

# T1.1 — _cwd_marker_text: UTF-8, one trailing LF/CR/CRLF, missing/unreadable → None
python3 - <<PY
import os, sys
sys.path.insert(0, "$HERE")
from hosts import _cwd_marker_text

mark = os.path.join("$WORK", "marker.cwd")
assert _cwd_marker_text(os.path.join("$WORK", "no-such.cwd")) is None

with open(mark, "w", encoding="utf-8") as f:
    f.write("foo\n")
assert _cwd_marker_text(mark) == "foo"

with open(mark, "w", encoding="utf-8") as f:
    f.write("foo")
assert _cwd_marker_text(mark) == "foo"

with open(mark, "wb") as f:
    f.write(b"foo\r\n")
assert _cwd_marker_text(mark) == "foo"

with open(mark, "wb") as f:
    f.write(b"foo\r")
assert _cwd_marker_text(mark) == "foo"

with open(mark, "w", encoding="utf-8") as f:
    f.write("foo\n\n")
assert _cwd_marker_text(mark) == "foo\n"

with open(mark, "w", encoding="utf-8") as f:
    f.write(" foo \n")
assert _cwd_marker_text(mark) == " foo "

with open(mark, "wb") as f:
    f.write(b"\xff\xfe")
assert _cwd_marker_text(mark) is None
print("cwd-marker-ok")
PY
if [ $? -eq 0 ]; then pass "T1.1 _cwd_marker_text strip/missing/unreadable"; else bad "T1.1 _cwd_marker_text"; fi

# AC1 cwd: ASCII abs path whose jq @uri encoding is >255 bytes. Do NOT mkdir $SESS/$ENC.
PAD="$(printf 'a%.0s' {1..220})"
LONG_CWD="$WORK/p/$PAD"
mkdir -p "$LONG_CWD"
LONG_CWD="$(cd "$LONG_CWD" && pwd)"
LONG_ENC="$(jq -rn --arg s "$LONG_CWD" '$s|@uri')"
LONG_ENC_PY="$(CWD_RAW="$LONG_CWD" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
if [ "$LONG_ENC" = "$LONG_ENC_PY" ] && [ "${#LONG_ENC}" -gt 255 ]; then
  pass "AC1 cwd jq @uri length ${#LONG_ENC} >255 and quote match"
else
  bad "AC1 encode jq=${#LONG_ENC} py=${#LONG_ENC_PY} match=$( [ "$LONG_ENC" = "$LONG_ENC_PY" ] && echo yes || echo no )"
fi

mkdir -p "$SESS/short-bucket/sid-long"
printf '%s\n' "$LONG_CWD" >"$SESS/short-bucket/.cwd"
printf 'ac1-long-cwd-unique-string\n' >"$SESS/short-bucket/sid-long/chat_history.jsonl"

DECOY_CWD="$WORK/decoy-project"
mkdir -p "$DECOY_CWD"
DECOY_CWD="$(cd "$DECOY_CWD" && pwd)"
mkdir -p "$SESS/decoy-bucket/sid-long"
printf '%s\n' "$DECOY_CWD" >"$SESS/decoy-bucket/.cwd"
printf 'ac3-decoy-trap\n' >"$SESS/decoy-bucket/sid-long/chat_history.jsonl"

# Nested .cwd under the bucket must not be a locate target (bucket-root only).
mkdir -p "$SESS/short-bucket/sid-long/nested"
printf '%s\n' "$LONG_CWD" >"$SESS/short-bucket/sid-long/nested/.cwd"
printf 'nested-trap\n' >"$SESS/short-bucket/sid-long/nested/chat_history.jsonl"

# Must not create or require the urlencode-named directory.
if [ -e "$SESS/$LONG_ENC" ]; then
  bad "AC1 urlencode-named dir exists (must not)"
else
  pass "AC1 no urlencode-named dir"
fi

OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$LONG_CWD" --session-id sid-long --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$SESS/short-bucket/sid-long/chat_history.jsonl" ]; then
  pass "AC1 locate by-id returns .cwd bucket file"
else
  bad "AC1 by-id rc=$RC out=$OUT expected=$SESS/short-bucket/sid-long/chat_history.jsonl"
fi
case "$OUT" in
  "$OP_GROK"*) bad "AC1 walked operator $OP_GROK" ;;
esac

# grok_cwd_bucket → lexical-min marker bucket (short-bucket)
python3 - <<PY
import os, sys
sys.path.insert(0, "$HERE")
from hosts import grok_cwd_bucket, locate, _grok_marker_buckets
long_cwd = "$LONG_CWD"
sess = "$SESS"
b = grok_cwd_bucket(long_cwd, sessions_dir=sess)
assert b == os.path.join(sess, "short-bucket"), b
assert not os.path.isdir(os.path.join(sess, "$LONG_ENC"))
p = locate("grok", "sid-long", long_cwd, sessions_dir=sess)
want = os.path.join(sess, "short-bucket", "sid-long", "chat_history.jsonl")
assert p == want, p
# newest follows grok_cwd_bucket (only short-bucket)
p2 = locate("grok", None, long_cwd, sessions_dir=sess)
assert p2 == want, p2
buckets = _grok_marker_buckets(long_cwd, sess)
assert buckets == [os.path.join(sess, "short-bucket")], buckets
op = os.path.expanduser("~/.grok/sessions")
assert p is not None and not p.startswith(op + os.sep)
print("ac1-import-ok")
PY
if [ $? -eq 0 ]; then pass "AC1 grok_cwd_bucket + newest + marker list"; else bad "AC1 grok_cwd_bucket import"; fi

# AC3 — decoy bucket for another cwd is not selected; urlencode file still wins on short cwd
mkdir -p "$SESS/aaa-cwd-marker/sid-target"
printf '%s\n' "$CWD" >"$SESS/aaa-cwd-marker/.cwd"
printf 'urlencode-trap\n' >"$SESS/aaa-cwd-marker/sid-target/chat_history.jsonl"
touch -d "2035-01-01 00:00:00" "$SESS/aaa-cwd-marker/sid-target/chat_history.jsonl"

OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --session-id sid-target --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$BUCKET/sid-target/chat_history.jsonl" ]; then
  pass "AC3 urlencode file wins over matching .cwd bucket"
else
  bad "AC3 urlencode-win rc=$RC out=$OUT"
fi

OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$CWD" --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$BUCKET/sid-new/chat_history.jsonl" ]; then
  pass "AC3 newest still urlencode cwd bucket (marker trap ignored)"
else
  bad "AC3 newest rc=$RC out=$OUT"
fi

OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$LONG_CWD" --session-id sid-long --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$SESS/short-bucket/sid-long/chat_history.jsonl" ]; then
  pass "AC3 decoy-bucket not selected for long cwd"
else
  bad "AC3 decoy rc=$RC out=$OUT"
fi

# AC2 — None × ghost cwd / matching .cwd without file / decoy cwd
GHOST_CWD="$WORK/ghost-cwd"
mkdir -p "$GHOST_CWD"
GHOST_CWD="$(cd "$GHOST_CWD" && pwd)"
GHOST_ENC="$(CWD_RAW="$GHOST_CWD" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
set +e
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$GHOST_CWD" --session-id sid-long --sessions-dir "$SESS" 2>"$WORK/ghost.err")"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
  pass "AC2 ghost cwd → None"
else
  bad "AC2 ghost rc=$RC out=$OUT err=$(cat "$WORK/ghost.err")"
fi

EMPTY_CWD="$WORK/empty-match-cwd"
mkdir -p "$EMPTY_CWD"
EMPTY_CWD="$(cd "$EMPTY_CWD" && pwd)"
mkdir -p "$SESS/empty-match/nested-bucket/sid-empty"
printf '%s\n' "$EMPTY_CWD" >"$SESS/empty-match/.cwd"
printf '%s\n' "$EMPTY_CWD" >"$SESS/empty-match/nested-bucket/.cwd"
printf 'nested-walk-trap\n' >"$SESS/empty-match/nested-bucket/sid-empty/chat_history.jsonl"
# .cwd as a file at sessions root must not count
printf '%s\n' "$EMPTY_CWD" >"$SESS/.cwd"

set +e
OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$EMPTY_CWD" --session-id sid-empty --sessions-dir "$SESS" 2>"$WORK/empty-match.err")"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
  pass "AC2 matching .cwd without file (no walk) → None"
else
  bad "AC2 empty-match rc=$RC out=$OUT err=$(cat "$WORK/empty-match.err")"
fi

OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$LONG_CWD" --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" != "$SESS/decoy-bucket/sid-long/chat_history.jsonl" ]; then
  pass "AC2 decoy path not returned for long cwd newest"
else
  bad "AC2 decoy-newest rc=$RC out=$OUT"
fi

python3 - <<PY
import os, sys
sys.path.insert(0, "$HERE")
from hosts import locate, grok_cwd_bucket
sess = "$SESS"
assert locate("grok", "sid-long", "$GHOST_CWD", sessions_dir=sess) is None
assert locate("grok", "sid-empty", "$EMPTY_CWD", sessions_dir=sess) is None
assert locate("grok", None, "$EMPTY_CWD", sessions_dir=sess) is None
b = grok_cwd_bucket("$GHOST_CWD", sessions_dir=sess)
assert b == os.path.join(sess, "$GHOST_ENC"), b
assert not os.path.isdir(b)
print("ac2-import-ok")
PY
if [ $? -eq 0 ]; then pass "AC2 import None × ghost/empty + ghost bucket path"; else bad "AC2 import"; fi

# AC6 — N matching .cwd+file → lexical-min
PAD6="$(printf 'b%.0s' {1..220})"
LONG6="$WORK/q/$PAD6"
mkdir -p "$LONG6"
LONG6="$(cd "$LONG6" && pwd)"
LONG6_ENC="$(jq -rn --arg s "$LONG6" '$s|@uri')"
if [ "${#LONG6_ENC}" -gt 255 ] && [ ! -e "$SESS/$LONG6_ENC" ]; then
  pass "AC6 cwd @uri length ${#LONG6_ENC} >255, no urlencode dir"
else
  bad "AC6 encode len=${#LONG6_ENC} exists=$( [ -e "$SESS/$LONG6_ENC" ] && echo yes || echo no )"
fi
mkdir -p "$SESS/zzz-dup/sid-dup" "$SESS/aaa-dup/sid-dup"
printf '%s\n' "$LONG6" >"$SESS/zzz-dup/.cwd"
printf '%s\n' "$LONG6" >"$SESS/aaa-dup/.cwd"
printf 'ac6-zzz\n' >"$SESS/zzz-dup/sid-dup/chat_history.jsonl"
printf 'ac6-aaa\n' >"$SESS/aaa-dup/sid-dup/chat_history.jsonl"

OUT="$("${HOSTS_PY[@]}" locate --host grok --cwd "$LONG6" --session-id sid-dup --sessions-dir "$SESS")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$SESS/aaa-dup/sid-dup/chat_history.jsonl" ]; then
  pass "AC6 N matches → lexical-min aaa-dup"
else
  bad "AC6 by-id rc=$RC out=$OUT expected=$SESS/aaa-dup/sid-dup/chat_history.jsonl"
fi

python3 - <<PY
import os, sys
sys.path.insert(0, "$HERE")
from hosts import grok_cwd_bucket, locate, _grok_marker_buckets
sess = "$SESS"
long6 = "$LONG6"
buckets = _grok_marker_buckets(long6, sess)
assert buckets == [
    os.path.join(sess, "aaa-dup"),
    os.path.join(sess, "zzz-dup"),
], buckets
assert grok_cwd_bucket(long6, sessions_dir=sess) == os.path.join(sess, "aaa-dup")
p = locate("grok", "sid-dup", long6, sessions_dir=sess)
assert p == os.path.join(sess, "aaa-dup", "sid-dup", "chat_history.jsonl"), p
print("ac6-import-ok")
PY
if [ $? -eq 0 ]; then pass "AC6 grok_cwd_bucket lexical-min + marker sort"; else bad "AC6 import"; fi

# T1.4: urlencode *directory* exists without the sid file → by-id still uses marker
FB_CWD="$WORK/fb-cwd"
mkdir -p "$FB_CWD"
FB_CWD="$(cd "$FB_CWD" && pwd)"
FB_ENC="$(CWD_RAW="$FB_CWD" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
mkdir -p "$SESS/$FB_ENC" "$SESS/marker-fb/sid-fb"
printf '%s\n' "$FB_CWD" >"$SESS/marker-fb/.cwd"
printf 't14-marker-file\n' >"$SESS/marker-fb/sid-fb/chat_history.jsonl"

python3 - <<PY
import os, sys
sys.path.insert(0, "$HERE")
from hosts import grok_cwd_bucket, locate
sess = "$SESS"
cwd = "$FB_CWD"
enc_dir = os.path.join(sess, "$FB_ENC")
assert os.path.isdir(enc_dir)
assert grok_cwd_bucket(cwd, sessions_dir=sess) == enc_dir
assert locate("grok", None, cwd, sessions_dir=sess) is None
p = locate("grok", "sid-fb", cwd, sessions_dir=sess)
assert p == os.path.join(sess, "marker-fb", "sid-fb", "chat_history.jsonl"), p
print("t14-ok")
PY
if [ $? -eq 0 ]; then pass "T1.4 urlencode dir miss file → marker by-id; newest follows bucket"; else bad "T1.4 fallback split"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
