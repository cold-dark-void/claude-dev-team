#!/usr/bin/env bash
# compact-transcript-test.sh — SPEC-036 M14 engine isolation (CDT-215 T4).
# Run: bash skills/transcript-mirror/compact-transcript-test.sh
# (cwd = plugin worktree so PDH resolves to feat/CDT-215, not master cache)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Invoked from test.sh as a sibling; also runnable standalone.
# MUST NOT write operator ~/.claude/transcript/. Use TMPDIR + TRANSCRIPT_MIRROR_ROOT.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
cd "$REPO" || exit 1

CT="$HERE/compact-transcript.sh"
CT_PY="$HERE/compact-transcript.py"
REC="$HERE/transcript-mirror.sh"
SYNC="$HERE/transcript-sync.sh"
FIX_TM="$HERE/fixtures"
FIX_SP="$REPO/skills/handoff/fixtures/mirror-spine"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

OPERATOR_HOME="${CDT_OPERATOR_HOME:-$HOME}"
OP_STORE="$OPERATOR_HOME/.claude/transcript"
BEFORE_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
BEFORE_OP_N=$(printf '%s\n' "$BEFORE_OP" | grep -c . || true)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tm-c7-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
STORE="$WORK/store"
SESS="$WORK/sessions"
TMP="$WORK/tmp"
mkdir -p "$FAKE_HOME" "$STORE" "$SESS" "$TMP"

export HOME="$FAKE_HOME"
export TRANSCRIPT_MIRROR_ROOT="$STORE"
export CLAUDE_PROJECTS_DIR="$FAKE_HOME/.claude/projects"
export GROK_SESSIONS_DIR="$SESS"
export TMPDIR="$TMP"
export CLAUDE_PLUGIN_ROOT="$REPO"
unset GROK_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH || true
mkdir -p "$CLAUDE_PROJECTS_DIR"

CWD=$(pwd)
ENC_CLAUDE=${CWD//\//-}

age() { touch -d '2 minutes ago' "$1"; }

sha_file() { sha256sum "$1" | awk '{print $1}'; }

last_ident() {
  python3 - "$1" <<'PY'
import hashlib, json, sys
ident = ""
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for line in f:
        raw = line.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            continue
        uuid = obj.get("uuid")
        if isinstance(uuid, str) and uuid:
            ident = uuid
            continue
        canon = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
        ident = "h:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()
print(ident)
PY
}

plant_claude_src() {
  local sid="$1" src="$2"
  local dest="$CLAUDE_PROJECTS_DIR/$ENC_CLAUDE"
  mkdir -p "$dest"
  cp "$src" "$dest/${sid}.jsonl"
  age "$dest/${sid}.jsonl"
  printf '%s\n' "$dest/${sid}.jsonl"
}

write_store() {
  local sid="$1" main="$2" srcpath="$3"
  mkdir -p "$STORE/$sid/tool_result" "$STORE/$sid/agents/w" \
    "$STORE/$sid/thinking" "$STORE/$sid/injection"
  cp "$main" "$STORE/$sid/main.md"
  local ident hash
  ident=$(last_ident "$srcpath")
  hash=$(sha_file "$STORE/$sid/main.md")
  printf '%s\t%s\t%s\n' "$ident" "$srcpath" "$hash" >"$STORE/$sid/cursor"
  printf 'source: %s\nstarted_mirror: 2026-01-01T00:00:00+00:00\n' "$srcpath" >"$STORE/$sid/meta"
}

plant_hit() {
  local sid="$1" src="$2" main="$3"
  local located
  located=$(plant_claude_src "$sid" "$src")
  write_store "$sid" "$main" "$located"
  printf '%s\n' "$located"
}

check_sid() {
  local sid="$1"
  bash "$SYNC" --check --sid "$sid" 2>"$WORK/chk.err" || true
}

store_fingerprint() {
  local d="$1"
  {
    printf '===tree===\n'
    find "$d" | LC_ALL=C sort
    printf '===files===\n'
    find "$d" -type f | LC_ALL=C sort | while IFS= read -r f; do
      sha256sum "$f"
    done
  }
}

run_ct() {
  local rc=0
  bash "$CT" "$@" >"$WORK/ct.out" 2>"$WORK/ct.err" || rc=$?
  printf '%s' "$rc"
}

run_ct_bin() {
  local bin="$1"
  shift
  local rc=0
  bash "$bin" "$@" >"$WORK/ct.out" 2>"$WORK/ct.err" || rc=$?
  printf '%s' "$rc"
}

invoke_rec() {
  local rc=0
  bash "$REC" "$@" >"$WORK/rec.out" 2>"$WORK/rec.err" || rc=$?
  printf '%s' "$rc"
}

pipe_rec() {
  local rc=0
  printf '%s\n' "$1" | bash "$REC" >"$WORK/rec.out" 2>"$WORK/rec.err" || rc=$?
  printf '%s' "$rc"
}

tail_path() { printf '%s/%s.meaning-tail.md' "$STORE" "$1"; }

copy_aged() {
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  age "$2"
}

# ---------------------------------------------------------------------------
# bash -n + fixtures
# ---------------------------------------------------------------------------
for f in "$CT" "$HERE/compact-transcript-test.sh" "$REC" "$SYNC"; do
  if bash -n "$f"; then
    pass "bash -n $(basename "$f")"
  else
    fail "bash -n $(basename "$f")"
  fi
done
if [ -f "$CT_PY" ] && [ -f "$HERE/strip_main.py" ]; then
  pass "T1 engine files present"
else
  fail "T1 compact-transcript.py/strip_main.py missing"
fi
for f in "$FIX_SP/plain.jsonl" "$FIX_SP/plain-main.md" \
         "$FIX_TM/claude-uuid.jsonl" "$FIX_TM/rewind-truncate.jsonl"; do
  if [ -f "$f" ]; then
    pass "fixture $(basename "$f")"
  else
    fail "missing fixture $f"
  fi
done

printf 'SENTINEL-MUST-NOT-CHANGE\n' >"$WORK/sentinel.md"
SENTINEL_SHA=$(sha_file "$WORK/sentinel.md")
plant_sentinel() {
  cp "$WORK/sentinel.md" "$(tail_path "$1")"
}

# ---------------------------------------------------------------------------
# Case 1+3+4 — hit, store isolation, strip (one plant)
# ---------------------------------------------------------------------------
SID_HIT="c7hit"
LOC_HIT=$(plant_hit "$SID_HIT" "$FIX_SP/plain.jsonl" "$FIX_SP/plain-main.md")
printf '%s\n' 'M3F-SIDECAR-TOOL-BODY must not leak' >"$STORE/$SID_HIT/tool_result/L000001.txt"
printf '%s\n' 'M3F-NEST-BODY must not leak' >"$STORE/$SID_HIT/agents/w/main.md"
printf '%s\n' 'THINK-BODY' >"$STORE/$SID_HIT/thinking/t.txt"
printf '%s\n' 'INJ-BODY' >"$STORE/$SID_HIT/injection/i.txt"

CHK_HIT=$(check_sid "$SID_HIT")
if printf '%s\n' "$CHK_HIT" | grep -q "sid=$SID_HIT status=ok"; then
  pass "C1 --check sid=$SID_HIT status=ok"
else
  fail "C1 --check not ok: out=${CHK_HIT:-<empty>} err=$(head -c 200 "$WORK/chk.err")"
fi

FP_BEFORE=$(store_fingerprint "$STORE/$SID_HIT")
MAIN_SHA_BEFORE=$(sha_file "$STORE/$SID_HIT/main.md")
CUR_BEFORE=$(cat "$STORE/$SID_HIT/cursor")
TAIL_HIT=$(tail_path "$SID_HIT")
[ -e "$TAIL_HIT" ] && fail "C1 tail existed before hit" || pass "C1 no tail before hit"

RC=$(run_ct "$SID_HIT")
if [ "$RC" -eq 0 ]; then
  pass "C1 hit exit 0"
else
  fail "C1 hit rc=$RC err=$(head -c 240 "$WORK/ct.err") out=$(head -c 120 "$WORK/ct.out")"
fi

NLINES=$(wc -l <"$WORK/ct.out" | tr -d ' ')
IFS= read -r GOT_PATH <"$WORK/ct.out" || true
if [ "$NLINES" = "1" ] && [ "$GOT_PATH" = "$TAIL_HIT" ] && [ -f "$TAIL_HIT" ]; then
  pass "C1 stdout absolute tail path"
else
  fail "C1 stdout want=$TAIL_HIT got=${GOT_PATH:-<empty>} nlines=$NLINES exists=$( [ -f "$TAIL_HIT" ] && echo y || echo n )"
fi
case "$GOT_PATH" in
  /*) pass "C1 stdout is absolute" ;;
  *) fail "C1 stdout not absolute: ${GOT_PATH:-<empty>}" ;;
esac

FP_AFTER=$(store_fingerprint "$STORE/$SID_HIT")
MAIN_SHA_AFTER=$(sha_file "$STORE/$SID_HIT/main.md")
CUR_AFTER=$(cat "$STORE/$SID_HIT/cursor")
if [ "$FP_BEFORE" = "$FP_AFTER" ] && [ "$MAIN_SHA_BEFORE" = "$MAIN_SHA_AFTER" ] \
   && [ "$CUR_BEFORE" = "$CUR_AFTER" ]; then
  pass "C3 store isolation (main.md/cursor/sidecars/agents)"
else
  fail "C3 store mutated after hit"
fi
NEST_INSIDE=$(find "$STORE/$SID_HIT" -name '*meaning-tail*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$NEST_INSIDE" = "0" ]; then
  pass "C3 no tail inside sid dir"
else
  fail "C3 tail leaked inside sid dir"
fi

if grep -q '# transcript mirror' "$TAIL_HIT"; then
  fail "C4 tail still has title"
else
  pass "C4 no title"
fi
if grep -qE '^>[[:space:]]*@' "$TAIL_HIT"; then
  fail "C4 tail has ^> @ lines"
else
  pass "C4 no ^> @ lines"
fi
if grep -qF 'M3F-SIDECAR-TOOL-BODY' "$TAIL_HIT" || grep -qF 'M3F-NEST-BODY' "$TAIL_HIT"; then
  fail "C4 tail inlined sidecar/nest body"
else
  pass "C4 no nest/sidecar body"
fi
FIRST=$(head -n 1 "$TAIL_HIT")
case "$FIRST" in
  '## user'|'## assistant') pass "C4 first line heading" ;;
  *) fail "C4 first line not ## user/assistant: ${FIRST:-<empty>}" ;;
esac
if grep -qF 'M3F-PLAIN-USER' "$TAIL_HIT" && grep -qF 'M3F-PLAIN-TIP' "$TAIL_HIT"; then
  pass "C4 meaning-channel text kept"
else
  fail "C4 missing meaning-channel markers"
fi

# Case 7 — overwrite idempotent
SHA_TAIL1=$(sha_file "$TAIL_HIT")
RC=$(run_ct "$SID_HIT")
SHA_TAIL2=$(sha_file "$TAIL_HIT")
if [ "$RC" -eq 0 ] && [ "$SHA_TAIL1" = "$SHA_TAIL2" ]; then
  pass "C7 overwrite idempotent same sha256"
else
  fail "C7 idempotent rc=$RC sha1=$SHA_TAIL1 sha2=$SHA_TAIL2"
fi

# ---------------------------------------------------------------------------
# Case 2 — miss: lag / missing / in-progress / helper absent / empty after strip
# ---------------------------------------------------------------------------
assert_miss() {
  local tag="$1" rc="$2" needle="$3" sid="$4"
  local tail
  tail=$(tail_path "$sid")
  if [ "$rc" -eq 0 ]; then
    fail "$tag MUST NOT exit 0 (fail-open)"
  else
    pass "$tag exit non-zero rc=$rc"
  fi
  if [ "$rc" -eq 1 ]; then
    pass "$tag exit 1"
  else
    fail "$tag rc=$rc want 1 (not transcript-sync fail-open 0; not usage 64) err=$(head -c 200 "$WORK/ct.err")"
  fi
  if grep -q "$needle" "$WORK/ct.err"; then
    pass "$tag stderr names $needle"
  else
    fail "$tag stderr missing '$needle': $(head -c 240 "$WORK/ct.err")"
  fi
  if [ -f "$tail" ] && [ "$(sha_file "$tail")" = "$SENTINEL_SHA" ]; then
    pass "$tag tail not created/updated"
  else
    fail "$tag tail mutated or missing sentinel"
  fi
}

SID_LAG="c7lag"
plant_hit "$SID_LAG" "$FIX_SP/plain.jsonl" "$FIX_SP/plain-main.md" >/dev/null
printf 'wrong-ident\t%s\t%s\n' "$CLAUDE_PROJECTS_DIR/$ENC_CLAUDE/${SID_LAG}.jsonl" \
  "$(sha_file "$STORE/$SID_LAG/main.md")" >"$STORE/$SID_LAG/cursor"
CHK_LAG=$(check_sid "$SID_LAG")
if printf '%s\n' "$CHK_LAG" | grep -q "sid=$SID_LAG status=lag"; then
  pass "C2 lag --check status=lag"
else
  fail "C2 lag --check want status=lag got ${CHK_LAG:-<empty>}"
fi
plant_sentinel "$SID_LAG"
RC=$(run_ct "$SID_LAG")
assert_miss "C2 lag" "$RC" "status=lag" "$SID_LAG"

SID_MISS="c7miss"
plant_claude_src "$SID_MISS" "$FIX_SP/plain.jsonl" >/dev/null
CHK_MISS=$(check_sid "$SID_MISS")
if printf '%s\n' "$CHK_MISS" | grep -q "sid=$SID_MISS status=missing"; then
  pass "C2 missing --check status=missing"
else
  fail "C2 missing --check want status=missing got ${CHK_MISS:-<empty>}"
fi
plant_sentinel "$SID_MISS"
RC=$(run_ct "$SID_MISS")
assert_miss "C2 missing" "$RC" "status=missing" "$SID_MISS"

SID_IP="c7ip"
LOC_IP=$(plant_hit "$SID_IP" "$FIX_SP/plain.jsonl" "$FIX_SP/plain-main.md")
touch "$LOC_IP"
CHK_IP=$(check_sid "$SID_IP")
if printf '%s\n' "$CHK_IP" | grep -q "sid=$SID_IP status=in-progress"; then
  pass "C2 in-progress --check status=in-progress"
else
  fail "C2 in-progress --check want in-progress got ${CHK_IP:-<empty>}"
fi
plant_sentinel "$SID_IP"
RC=$(run_ct "$SID_IP")
assert_miss "C2 in-progress" "$RC" "status=in-progress" "$SID_IP"

SID_HELP="c7help"
plant_hit "$SID_HELP" "$FIX_SP/plain.jsonl" "$FIX_SP/plain-main.md" >/dev/null
plant_sentinel "$SID_HELP"
STUB="$WORK/stub-plugin"
mkdir -p "$STUB/skills/transcript-mirror"
cp "$REPO/skills/plugin-dir.sh" "$STUB/skills/plugin-dir.sh"
cp "$CT" "$CT_PY" "$HERE/strip_main.py" "$STUB/skills/transcript-mirror/"
RC=$(CLAUDE_PLUGIN_ROOT="$STUB" run_ct_bin "$STUB/skills/transcript-mirror/compact-transcript.sh" "$SID_HELP")
assert_miss "C2 helper absent" "$RC" "transcript-sync.sh not found" "$SID_HELP"

SID_EMPTY="c7empty"
MAIN_E="$WORK/empty-main.md"
printf '# transcript mirror\n\n> @tool_result/L000001.txt\n> @agents/w/main.md\n' >"$MAIN_E"
plant_hit "$SID_EMPTY" "$FIX_SP/plain.jsonl" "$MAIN_E" >/dev/null
CHK_E=$(check_sid "$SID_EMPTY")
if printf '%s\n' "$CHK_E" | grep -q "sid=$SID_EMPTY status=ok"; then
  pass "C2 empty-strip --check status=ok"
else
  fail "C2 empty-strip --check not ok: ${CHK_E:-<empty>}"
fi
plant_sentinel "$SID_EMPTY"
RC=$(run_ct "$SID_EMPTY")
assert_miss "C2 empty after strip" "$RC" "empty after strip" "$SID_EMPTY"

# usage / bad sid → 64 (not fail-open 0)
assert_usage() {
  local tag="$1" rc="$2"
  if [ "$rc" -eq 64 ]; then
    pass "$tag exit 64"
  elif [ "$rc" -eq 0 ]; then
    fail "$tag MUST NOT exit 0"
  else
    fail "$tag rc=$rc want 64 err=$(head -c 200 "$WORK/ct.err")"
  fi
}
RC=$(run_ct --bytes)
assert_usage "C2 unknown flag" "$RC"
RC=$(run_ct 'bad/sid')
assert_usage "C2 sid with slash" "$RC"
RC=$(run_ct '.')
assert_usage "C2 sid=." "$RC"
RC=$(run_ct '..')
assert_usage "C2 sid=.." "$RC"

# ---------------------------------------------------------------------------
# Case 5 — cap: fixture >32KiB turns → wc -c ≤ 32768; newest heading present
# ---------------------------------------------------------------------------
SID_CAP="c7cap"
MAIN_CAP="$WORK/cap-main.md"
{
  printf '# transcript mirror\n\n'
  i=1
  while [ "$i" -le 100 ]; do
    printf '## user\n\nOLD-TURN-%s ' "$i"
    head -c 400 /dev/zero | tr '\0' 'x'
    printf '\n\n'
    i=$((i + 1))
  done
  printf '## assistant\n\nNEWEST-CAP-MARKER\n'
} >"$MAIN_CAP"
CAP_MAIN_BYTES=$(wc -c <"$MAIN_CAP" | tr -d ' ')
if [ "$CAP_MAIN_BYTES" -gt 32768 ]; then
  pass "C5 fixture main.md >32KiB ($CAP_MAIN_BYTES)"
else
  fail "C5 fixture too small: $CAP_MAIN_BYTES"
fi
plant_hit "$SID_CAP" "$FIX_SP/plain.jsonl" "$MAIN_CAP" >/dev/null
RC=$(run_ct "$SID_CAP")
TAIL_CAP=$(tail_path "$SID_CAP")
if [ "$RC" -eq 0 ] && [ -f "$TAIL_CAP" ]; then
  pass "C5 cap hit exit 0"
else
  fail "C5 cap rc=$RC err=$(head -c 200 "$WORK/ct.err")"
fi
CAP_BYTES=$(wc -c <"$TAIL_CAP" | tr -d ' ')
if [ "$CAP_BYTES" -le 32768 ]; then
  pass "C5 wc -c <= 32768 ($CAP_BYTES)"
else
  fail "C5 wc -c $CAP_BYTES exceeds 32768"
fi
if grep -qF 'NEWEST-CAP-MARKER' "$TAIL_CAP"; then
  pass "C5 newest heading/body present"
else
  fail "C5 missing NEWEST-CAP-MARKER"
fi
FIRST_CAP=$(head -n 1 "$TAIL_CAP")
case "$FIRST_CAP" in
  '## user'|'## assistant') pass "C5 first line heading" ;;
  *) fail "C5 first line: ${FIRST_CAP:-<empty>}" ;;
esac
if grep -q '# transcript mirror' "$TAIL_CAP" || grep -qE '^>[[:space:]]*@' "$TAIL_CAP"; then
  fail "C5 cap tail has title or @refs"
else
  pass "C5 cap tail stripped"
fi

# ---------------------------------------------------------------------------
# Case 6 — newest-block overflow still ≤ 32768; newest heading present
# ---------------------------------------------------------------------------
SID_OV="c7ov"
MAIN_OV="$WORK/ov-main.md"
{
  printf '# transcript mirror\n\n'
  printf '## user\n\nold turn that must drop\n\n'
  printf '## assistant\n\n'
  printf 'OVERFLOW-NEWEST-MARKER 日本語\n'
  head -c 40000 /dev/zero | tr '\0' 'y'
  printf '\n'
} >"$MAIN_OV"
# newest block size (from last ## heading)
OV_BLOCK_BYTES=$(awk 'BEGIN{p=0} /^## (user|assistant)[ \t]*$/{p=NR} END{print p}' "$MAIN_OV")
OV_NEWEST=$(tail -n +"$OV_BLOCK_BYTES" "$MAIN_OV")
OV_NEWEST_N=$(printf '%s' "$OV_NEWEST" | wc -c | tr -d ' ')
if [ "$OV_NEWEST_N" -gt 32768 ]; then
  pass "C6 newest block alone >32KiB ($OV_NEWEST_N)"
else
  fail "C6 newest block too small: $OV_NEWEST_N"
fi
plant_hit "$SID_OV" "$FIX_SP/plain.jsonl" "$MAIN_OV" >/dev/null
RC=$(run_ct "$SID_OV")
TAIL_OV=$(tail_path "$SID_OV")
if [ "$RC" -eq 0 ] && [ -f "$TAIL_OV" ]; then
  pass "C6 overflow hit exit 0"
else
  fail "C6 overflow rc=$RC err=$(head -c 200 "$WORK/ct.err")"
fi
OV_BYTES=$(wc -c <"$TAIL_OV" | tr -d ' ')
if [ "$OV_BYTES" -le 32768 ]; then
  pass "C6 wc -c <= 32768 ($OV_BYTES)"
else
  fail "C6 wc -c $OV_BYTES exceeds 32768"
fi
FIRST_OV=$(head -n 1 "$TAIL_OV")
if [ "$FIRST_OV" = "## assistant" ]; then
  pass "C6 newest heading present"
else
  fail "C6 first line want ## assistant got ${FIRST_OV:-<empty>}"
fi
if grep -qF 'OVERFLOW-NEWEST-MARKER' "$TAIL_OV"; then
  pass "C6 overflow marker in kept prefix"
else
  fail "C6 missing OVERFLOW-NEWEST-MARKER"
fi
if grep -qF 'old turn that must drop' "$TAIL_OV"; then
  fail "C6 kept older turn-block"
else
  pass "C6 older turn dropped"
fi
if iconv -f UTF-8 -t UTF-8 "$TAIL_OV" >/dev/null 2>"$WORK/iconv.err"; then
  pass "C6 tail valid UTF-8"
else
  fail "C6 invalid UTF-8: $(head -c 120 "$WORK/iconv.err")"
fi

# ---------------------------------------------------------------------------
# Case 8 — recorder/sync do not mutate/create *.meaning-tail.md
# ---------------------------------------------------------------------------
SID_REC="c7rec"
LOC_REC=$(plant_claude_src "$SID_REC" "$FIX_TM/claude-uuid.jsonl")
RC=$(invoke_rec --transcript "$LOC_REC" --sid "$SID_REC")
if [ "$RC" -eq 0 ] && [ -f "$STORE/$SID_REC/main.md" ]; then
  pass "C8 recorder setup exit 0"
else
  fail "C8 recorder setup rc=$RC err=$(head -c 200 "$WORK/rec.err")"
fi
TAIL_REC=$(tail_path "$SID_REC")
printf 'PLANTED-TAIL-RECORDER-MUST-NOT-TOUCH\n' >"$TAIL_REC"
SHA_REC1=$(sha_file "$TAIL_REC")
STOP_JSON=$(jq -nc --arg p "$LOC_REC" --arg s "$SID_REC" \
  '{hook_event_name:"Stop",session_id:$s,transcript_path:$p,reason:"end_turn"}')
RC=$(pipe_rec "$STOP_JSON")
if [ "$RC" -eq 0 ]; then
  pass "C8 Stop tick exit 0"
else
  fail "C8 Stop tick rc=$RC"
fi
SHA_REC2=$(sha_file "$TAIL_REC")
if [ "$SHA_REC1" = "$SHA_REC2" ]; then
  pass "C8 Stop tick tail sha256 unchanged"
else
  fail "C8 Stop tick mutated tail"
fi
bash "$SYNC" --sid "$SID_REC" >"$WORK/sync.out" 2>"$WORK/sync.err" || true
SHA_REC3=$(sha_file "$TAIL_REC")
if [ "$SHA_REC1" = "$SHA_REC3" ] && grep -q 'PLANTED-TAIL-RECORDER-MUST-NOT-TOUCH' "$TAIL_REC"; then
  pass "C8 transcript-sync --sid tail sha256 unchanged"
else
  fail "C8 sync mutated tail err=$(head -c 160 "$WORK/sync.err")"
fi

rm -f "$TAIL_REC"
RC=$(pipe_rec "$STOP_JSON")
bash "$SYNC" --sid "$SID_REC" >"$WORK/sync2.out" 2>"$WORK/sync2.err" || true
if [ -e "$TAIL_REC" ]; then
  fail "C8 Stop/sync created a tail when none existed"
else
  pass "C8 neither creates a tail when none exists"
fi
# extra: no-args sync also must not invent a tail
bash "$SYNC" >"$WORK/sync3.out" 2>"$WORK/sync3.err" || true
if [ -e "$TAIL_REC" ]; then
  fail "C8 no-args sync created a tail"
else
  pass "C8 no-args sync does not create a tail"
fi

# ---------------------------------------------------------------------------
# Case 9 — sid-dir rebuild leaves sibling tail byte-identical
# ---------------------------------------------------------------------------
SID_REB="c7reb"
copy_aged "$FIX_TM/rewind-truncate.jsonl" "$WORK/src/rewind.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/rewind.jsonl" --sid "$SID_REB")
if [ "$RC" -eq 0 ] && grep -q 'rewind user three' "$STORE/$SID_REB/main.md"; then
  pass "C9 rewind initial mirror"
else
  fail "C9 rewind initial rc=$RC"
fi
TAIL_REB=$(tail_path "$SID_REB")
printf 'PLANTED-TAIL-REBUILD-MUST-NOT-TOUCH\n' >"$TAIL_REB"
SHA_REB1=$(sha_file "$TAIL_REB")
MAIN_REB1=$(sha_file "$STORE/$SID_REB/main.md")
head -n 2 "$FIX_TM/rewind-truncate.jsonl" >"$WORK/src/rewind.jsonl"
age "$WORK/src/rewind.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/rewind.jsonl" --sid "$SID_REB")
if [ "$RC" -eq 0 ]; then
  pass "C9 rewind truncate recorder exit 0"
else
  fail "C9 rewind truncate rc=$RC"
fi
MAIN_REB2=$(sha_file "$STORE/$SID_REB/main.md")
if [ "$MAIN_REB1" != "$MAIN_REB2" ] && ! grep -q 'rewind user three' "$STORE/$SID_REB/main.md"; then
  pass "C9 sid-dir rebuilt (main.md changed)"
else
  fail "C9 rebuild did not fire main1=$MAIN_REB1 main2=$MAIN_REB2"
fi
SHA_REB2=$(sha_file "$TAIL_REB")
if [ "$SHA_REB1" = "$SHA_REB2" ] && grep -q 'PLANTED-TAIL-REBUILD-MUST-NOT-TOUCH' "$TAIL_REB"; then
  pass "C9 sibling tail sha256 unchanged across rebuild"
else
  fail "C9 rebuild ate/mutated sibling tail"
fi
# bak glob must not have replaced the tail
if [ -f "$TAIL_REB" ] && [ ! -d "${STORE}/${SID_REB}.meaning-tail.md" ]; then
  pass "C9 tail still a file (not bak-swap)"
else
  fail "C9 tail path is not a regular file after rebuild"
fi

# ---------------------------------------------------------------------------
# Case 10 — operator store untouched
# ---------------------------------------------------------------------------
AFTER_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
AFTER_OP_N=$(printf '%s\n' "$AFTER_OP" | grep -c . || true)
if [ "$BEFORE_OP" = "$AFTER_OP" ]; then
  pass "C10 operator ~/.claude/transcript/ untouched (n=$BEFORE_OP_N)"
else
  fail "C10 operator store changed before_n=$BEFORE_OP_N after_n=$AFTER_OP_N"
  printf 'BEFORE\n%s\nAFTER\n%s\n' "$BEFORE_OP" "$AFTER_OP" >&2
fi
if [ -d "$FAKE_HOME/.claude/transcript" ]; then
  fail "C10 wrote fake HOME transcript (ROOT override ignored?)"
else
  pass "C10 no default-root write under fake HOME"
fi
# suite did write under TRANSCRIPT_MIRROR_ROOT (else isolation is vacuous)
if [ -f "$TAIL_HIT" ] && [ -d "$STORE/$SID_HIT" ]; then
  pass "C10 suite wrote under TRANSCRIPT_MIRROR_ROOT"
else
  fail "C10 suite did not use TRANSCRIPT_MIRROR_ROOT"
fi

printf '\ncompact-transcript-test: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
printf 'operator-store: unchanged n=%s root=%s\n' "$BEFORE_OP_N" "$OP_STORE"
[ "$FAIL" -eq 0 ]
