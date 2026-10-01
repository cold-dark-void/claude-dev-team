#!/usr/bin/env bash
# discover-host.sh dual-host auto-detect (CDT-156 T5 / SPEC-012 OQ2)
# Cases: newest mtime wins; env pin wins; none → exit 1; --env-check skips mtime.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVER="$HERE/discover-host.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/discover-host-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

CWD="$WORK/project"
mkdir -p "$CWD"
CWD="$(cd "$CWD" && pwd)"

CLAUDE_ROOT="$WORK/claude-projects"
GROK_ROOT="$WORK/grok-sessions"
# Dash-encode cwd for Claude project dir (hosts.dash_encode_cwd).
dash_enc() {
  python3 "$HERE/hosts.py" encode-project --cwd "$1"
}
CLAUDE_ENC="$(dash_enc "$CWD")"
GROK_ENC="$(CWD_RAW="$CWD" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
CLAUDE_PDIR="$CLAUDE_ROOT/$CLAUDE_ENC"
GROK_BUCKET="$GROK_ROOT/$GROK_ENC"
mkdir -p "$CLAUDE_PDIR" "$GROK_BUCKET/gsid-old" "$GROK_BUCKET/gsid-new"

printf '{"type":"user"}\n' >"$CLAUDE_PDIR/csid-old.jsonl"
printf '{"type":"user"}\n' >"$CLAUDE_PDIR/csid-new.jsonl"
printf 'old\n' >"$GROK_BUCKET/gsid-old/chat_history.jsonl"
printf 'new\n' >"$GROK_BUCKET/gsid-new/chat_history.jsonl"

# mtime order: claude-old < grok-old < claude-new < grok-new (default newest = grok)
touch -d "2020-01-01 00:00:00" "$CLAUDE_PDIR/csid-old.jsonl"
touch -d "2021-01-01 00:00:00" "$GROK_BUCKET/gsid-old/chat_history.jsonl"
touch -d "2022-01-01 00:00:00" "$CLAUDE_PDIR/csid-new.jsonl"
touch -d "2023-01-01 00:00:00" "$GROK_BUCKET/gsid-new/chat_history.jsonl"

export CLAUDE_PROJECTS_DIR="$CLAUDE_ROOT"
export GROK_SESSIONS_DIR="$GROK_ROOT"
unset GROK_SESSION_ID GROK_TRANSCRIPT_PATH \
  CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID \
  CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH 2>/dev/null || true

if [ -x "$DISCOVER" ]; then
  pass "discover-host.sh executable"
else
  bad "discover-host.sh missing or not executable"
  echo "discover-host-test: $PASS passed, $FAIL failed"
  exit 1
fi

# ---- T1: dual present → newest mtime (grok) ----
set +e
OUT="$("$DISCOVER" --cwd "$CWD" 2>"$WORK/t1.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && echo "$OUT" | grep -q 'host=grok' \
  && echo "$OUT" | grep -q 'session_id=gsid-new' \
  && echo "$OUT" | grep -q "source=mtime" \
  && echo "$OUT" | grep -Fq "path=$GROK_BUCKET/gsid-new/chat_history.jsonl"; then
  pass "T1 dual-host newest mtime picks grok gsid-new"
else
  bad "T1 rc=$RC out=$OUT err=$(cat "$WORK/t1.err")"
fi

# ---- T2: claude newer than grok → claude ----
touch -d "2024-06-01 00:00:00" "$CLAUDE_PDIR/csid-new.jsonl"
set +e
OUT="$("$DISCOVER" --cwd "$CWD" 2>"$WORK/t2.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && echo "$OUT" | grep -q 'host=claude' \
  && echo "$OUT" | grep -q 'session_id=csid-new' \
  && echo "$OUT" | grep -q 'source=mtime'; then
  pass "T2 dual-host newest mtime picks claude when newer"
else
  bad "T2 rc=$RC out=$OUT err=$(cat "$WORK/t2.err")"
fi
# restore grok as newest for later cases
touch -d "2025-01-01 00:00:00" "$GROK_BUCKET/gsid-new/chat_history.jsonl"

# ---- T3: GROK_SESSION_ID pin wins over newer claude ----
touch -d "2030-01-01 00:00:00" "$CLAUDE_PDIR/csid-new.jsonl"
export GROK_SESSION_ID=gsid-old
set +e
OUT="$("$DISCOVER" --cwd "$CWD" 2>"$WORK/t3.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && echo "$OUT" | grep -q 'host=grok' \
  && echo "$OUT" | grep -q 'session_id=gsid-old' \
  && echo "$OUT" | grep -q 'source=env:GROK_SESSION_ID'; then
  pass "T3 GROK_SESSION_ID pin wins over newer claude"
else
  bad "T3 rc=$RC out=$OUT err=$(cat "$WORK/t3.err")"
fi
unset GROK_SESSION_ID

# ---- T4: GROK_TRANSCRIPT_PATH pin ----
export GROK_TRANSCRIPT_PATH="$GROK_BUCKET/gsid-old/chat_history.jsonl"
set +e
OUT="$("$DISCOVER" --cwd "$CWD" 2>"$WORK/t4.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && echo "$OUT" | grep -q 'host=grok' \
  && echo "$OUT" | grep -q 'session_id=gsid-old' \
  && echo "$OUT" | grep -q 'source=env:GROK_TRANSCRIPT_PATH'; then
  pass "T4 GROK_TRANSCRIPT_PATH pin"
else
  bad "T4 rc=$RC out=$OUT err=$(cat "$WORK/t4.err")"
fi
unset GROK_TRANSCRIPT_PATH

# ---- T5: CLAUDE_SESSION_ID pin (no grok env) ----
export CLAUDE_SESSION_ID=csid-old
set +e
OUT="$("$DISCOVER" --cwd "$CWD" 2>"$WORK/t5.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && echo "$OUT" | grep -q 'host=claude' \
  && echo "$OUT" | grep -q 'session_id=csid-old' \
  && echo "$OUT" | grep -q 'source=env:CLAUDE_SESSION_ID'; then
  pass "T5 CLAUDE_SESSION_ID pin"
else
  bad "T5 rc=$RC out=$OUT err=$(cat "$WORK/t5.err")"
fi
unset CLAUDE_SESSION_ID

# ---- T6: --env-check with no env → exit 1 (mtime not used) ----
set +e
OUT="$("$DISCOVER" --cwd "$CWD" --env-check 2>"$WORK/t6.err")"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
  pass "T6 --env-check no pin exits 1"
else
  bad "T6 rc=$RC out=$OUT err=$(cat "$WORK/t6.err")"
fi

# ---- T7: --env-check with GROK pin ----
export GROK_SESSION_ID=gsid-new
set +e
OUT="$("$DISCOVER" --cwd "$CWD" --env-check 2>"$WORK/t7.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'host=grok' \
  && echo "$OUT" | grep -q 'session_id=gsid-new'; then
  pass "T7 --env-check with GROK_SESSION_ID"
else
  bad "T7 rc=$RC out=$OUT err=$(cat "$WORK/t7.err")"
fi
unset GROK_SESSION_ID

# ---- T8: neither host has sessions → exit 1 ----
EMPTY_CWD="$WORK/empty-project"
mkdir -p "$EMPTY_CWD"
EMPTY_CWD="$(cd "$EMPTY_CWD" && pwd)"
set +e
OUT="$("$DISCOVER" --cwd "$EMPTY_CWD" 2>"$WORK/t8.err")"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
  pass "T8 no sessions exit 1"
else
  bad "T8 rc=$RC out=$OUT err=$(cat "$WORK/t8.err")"
fi

# ---- T9: claude-only tree ----
ONLY="$WORK/claude-only-proj"
mkdir -p "$ONLY"
ONLY="$(cd "$ONLY" && pwd)"
ONLY_ENC="$(dash_enc "$ONLY")"
mkdir -p "$CLAUDE_ROOT/$ONLY_ENC"
printf 'x\n' >"$CLAUDE_ROOT/$ONLY_ENC/only-sid.jsonl"
touch -d "2022-01-01 00:00:00" "$CLAUDE_ROOT/$ONLY_ENC/only-sid.jsonl"
set +e
OUT="$("$DISCOVER" --cwd "$ONLY" 2>"$WORK/t9.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && echo "$OUT" | grep -q 'host=claude' \
  && echo "$OUT" | grep -q 'session_id=only-sid'; then
  pass "T9 claude-only host=claude"
else
  bad "T9 rc=$RC out=$OUT err=$(cat "$WORK/t9.err")"
fi

# ---- T10: path with a space survives locate and tab emit ----
SPACE_CWD="$WORK/space dir"
mkdir -p "$SPACE_CWD"
SPACE_CWD="$(cd "$SPACE_CWD" && pwd)"
SPACE_ENC="$(dash_enc "$SPACE_CWD")"
mkdir -p "$CLAUDE_ROOT/$SPACE_ENC"
printf 'space\n' >"$CLAUDE_ROOT/$SPACE_ENC/space-sid.jsonl"
set +e
OUT="$("$DISCOVER" --cwd "$SPACE_CWD" 2>"$WORK/t10.err")"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
  && printf '%s\n' "$OUT" | grep -q 'host=claude' \
  && printf '%s\n' "$OUT" | grep -q 'session_id=space-sid' \
  && printf '%s\n' "$OUT" | grep -F "path=$CLAUDE_ROOT/$SPACE_ENC/space-sid.jsonl" >/dev/null; then
  pass "T10 space in cwd path"
else
  bad "T10 rc=$RC out=$OUT err=$(cat "$WORK/t10.err")"
fi

echo "discover-host-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
