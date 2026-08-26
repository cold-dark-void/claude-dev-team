#!/usr/bin/env bash
# summarize-transcript-test.sh — SPEC-036 M15 overlay isolation (CDT-214 T1).
# Run: bash skills/transcript-mirror/summarize-transcript-test.sh
# (cwd = plugin worktree so PDH resolves to feat/CDT-214, not master cache)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Suite is RED until T3: missing summarize-transcript.sh is FAIL, not skip.
# MUST NOT write operator ~/.claude/transcript/. Use TMPDIR + TRANSCRIPT_MIRROR_ROOT.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
cd "$REPO" || exit 1

ST="$HERE/summarize-transcript.sh"
RO="$HERE/reapply-overlay.sh"
REC="$HERE/transcript-mirror.sh"
SYNC="$HERE/transcript-sync.sh"
FIX_TM="$HERE/fixtures"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

OPERATOR_HOME="${CDT_OPERATOR_HOME:-$HOME}"
OP_STORE="$OPERATOR_HOME/.claude/transcript"
BEFORE_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
BEFORE_OP_N=$(printf '%s\n' "$BEFORE_OP" | grep -c . || true)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tm-c8-test.XXXXXX")
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

# Default seam stub: always shorter than an 8192+ payload.
cat >"$WORK/stub.sh" <<'EOF'
#!/usr/bin/env bash
set -u
prefix=$(head -c 40)
cat >/dev/null
printf 'STUB:%s\n' "$prefix"
EOF
chmod +x "$WORK/stub.sh"
export SUMMARIZE_TRANSCRIPT_CMD="$WORK/stub.sh"

cat >"$WORK/stub-fail.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 1
EOF
chmod +x "$WORK/stub-fail.sh"

cat >"$WORK/stub-echo.sh" <<'EOF'
#!/usr/bin/env bash
cat
EOF
chmod +x "$WORK/stub-echo.sh"

CWD=$(pwd)
ENC_CLAUDE=${CWD//\//-}

age() { touch -d '2 minutes ago' "$1"; }

sha_file() { sha256sum "$1" | awk '{print $1}'; }

last_ident() {
  jq -r 'select(.uuid | type == "string" and length > 0) | .uuid' "$1" \
    | awk 'NF { x=$0 } END { print x }'
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

run_st() {
  local rc=0
  bash "$ST" "$@" >"$WORK/st.out" 2>"$WORK/st.err" || rc=$?
  printf '%s' "$rc"
}

run_st_bin() {
  local bin="$1"
  shift
  local rc=0
  bash "$bin" "$@" >"$WORK/st.out" 2>"$WORK/st.err" || rc=$?
  printf '%s' "$rc"
}

invoke_rec() {
  local rc=0
  bash "$REC" "$@" >"$WORK/rec.out" 2>"$WORK/rec.err" || rc=$?
  printf '%s' "$rc"
}

heading_count() {
  grep -cE '^## (user|assistant)[[:space:]]*$' "$1" 2>/dev/null || true
}

extract_turn_block() {
  local main="$1" n="$2"
  awk -v n="$n" '
    /^## (user|assistant)[[:space:]]*$/ {
      c++
      if (inblk && c > n) exit
      if (c == n) inblk=1
    }
    inblk { print }
  ' "$main"
}

# Write exactly n UTF-8 bytes ending with a newline. Prefix is marker + newline.
write_payload_bytes() {
  local dest="$1" n="$2" marker="$3"
  local prefix plen pad
  prefix=$(printf '%s\n' "$marker")
  plen=$(printf '%s' "$prefix" | wc -c | tr -d ' ')
  if [ "$n" -lt "$plen" ]; then
    printf 'write_payload_bytes: n=%s < prefix %s\n' "$n" "$plen" >&2
    return 1
  fi
  {
    printf '%s' "$prefix"
    if [ "$n" -gt "$plen" ]; then
      pad=$((n - plen))
      if [ "$pad" -eq 1 ]; then
        printf '\n'
      else
        head -c $((pad - 1)) /dev/zero | tr '\0' 'x'
        printf '\n'
      fi
    fi
  } >"$dest"
  local got
  got=$(wc -c <"$dest" | tr -d ' ')
  [ "$got" -eq "$n" ]
}

write_two_turn_main() {
  local dest="$1" userf="$2" asstf="$3"
  {
    printf '# transcript mirror\n\n'
    printf '## user\n'
    cat "$userf"
    printf '## assistant\n'
    cat "$asstf"
  } >"$dest"
}

write_oversize_jsonl() {
  local dest="$1" uid="$2" aid="$3" marker="$4"
  mkdir -p "$(dirname "$dest")"
  {
    printf '%s' "{\"uuid\":\"${uid}\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\""
    printf '%s' "$marker"
    head -c 8200 /dev/zero | tr '\0' 'x'
    printf '%s\n' '"}]}}'
    printf '%s\n' "{\"uuid\":\"${aid}\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"undersize assistant\"}]}}"
  } >"$dest"
  age "$dest"
}

count_verbatim_refs() {
  grep -cE '^>[[:space:]]*@verbatim/' "$1" 2>/dev/null || true
}

assert_usage() {
  local tag="$1" rc="$2"
  if [ "$rc" -eq 64 ]; then
    pass "$tag exit 64"
  elif [ "$rc" -eq 0 ]; then
    fail "$tag MUST NOT exit 0"
  else
    fail "$tag rc=$rc want 64 err=$(head -c 200 "$WORK/st.err")"
  fi
}

assert_miss() {
  local tag="$1" rc="$2" sid="$3" main_sha="${4:-}"
  local main="$STORE/$sid/main.md"
  if [ "$rc" -eq 0 ]; then
    fail "$tag MUST NOT exit 0 (fail-open)"
  elif [ "$rc" -eq 1 ]; then
    pass "$tag exit 1"
  else
    fail "$tag rc=$rc want 1 err=$(head -c 200 "$WORK/st.err")"
  fi
  if [ -n "$main_sha" ] && [ -f "$main" ]; then
    if [ "$(sha_file "$main")" = "$main_sha" ]; then
      pass "$tag main.md sha256 unchanged"
    else
      fail "$tag main.md mutated"
    fi
  fi
  if [ -e "$STORE/$sid/verbatim" ]; then
    fail "$tag created verbatim/"
  else
    pass "$tag no verbatim/ created"
  fi
}

assert_sidecar_dirs() {
  local sid="$1" tag="$2"
  local d name bad=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name=$(basename "$d")
    case "$name" in
      thinking|tool_result|injection|agents|verbatim) ;;
      *)
        bad=1
        printf 'unexpected sid dir %s\n' "$name" >&2
        ;;
    esac
  done < <(find "$STORE/$sid" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  if [ "$bad" -eq 0 ]; then
    pass "$tag sidecar dirs thinking|tool_result|injection + optional agents|verbatim"
  else
    fail "$tag unexpected sidecar dir under $sid"
  fi
  for name in thinking tool_result injection; do
    if [ -d "$STORE/$sid/$name" ]; then
      pass "$tag has $name/"
    else
      fail "$tag missing $name/"
    fi
  done
}

tail_path() { printf '%s/%s.meaning-tail.md' "$STORE" "$1"; }

# ---------------------------------------------------------------------------
# T1.1 harness + bash -n
# ---------------------------------------------------------------------------
if bash -n "$HERE/summarize-transcript-test.sh"; then
  pass "T1.1 bash -n summarize-transcript-test.sh"
else
  fail "T1.1 bash -n summarize-transcript-test.sh"
fi
if [ -f "$ST" ] && bash -n "$ST"; then
  pass "T1.1 bash -n summarize-transcript.sh"
else
  fail "T1.1 bash -n summarize-transcript.sh (missing or syntax)"
fi
for f in "$REC" "$SYNC"; do
  if bash -n "$f"; then
    pass "T1.1 bash -n $(basename "$f")"
  else
    fail "T1.1 bash -n $(basename "$f")"
  fi
done
if [ -f "$FIX_TM/claude-uuid.jsonl" ]; then
  pass "T1.1 fixture claude-uuid.jsonl"
else
  fail "T1.1 missing fixture claude-uuid.jsonl"
fi

# ---------------------------------------------------------------------------
# T1.2 plant helper — --check status=ok
# ---------------------------------------------------------------------------
SID_OK="t12ok"
MAIN_OK="$WORK/t12-main.md"
printf '# transcript mirror\n\n## user\n\nhello plant\n\n## assistant\n\nok\n' >"$MAIN_OK"
LOC_OK=$(plant_hit "$SID_OK" "$FIX_TM/claude-uuid.jsonl" "$MAIN_OK")
CHK_OK=$(check_sid "$SID_OK")
if printf '%s\n' "$CHK_OK" | grep -q "sid=$SID_OK status=ok"; then
  pass "T1.2 --check sid=$SID_OK status=ok"
else
  fail "T1.2 --check not ok: out=${CHK_OK:-<empty>} err=$(head -c 200 "$WORK/chk.err")"
fi
if [ -f "$STORE/$SID_OK/main.md" ] && [ -f "$STORE/$SID_OK/cursor" ] \
   && [ -f "$STORE/$SID_OK/meta" ] && [ -d "$STORE/$SID_OK/thinking" ] \
   && [ -d "$STORE/$SID_OK/tool_result" ] && [ -d "$STORE/$SID_OK/injection" ]; then
  pass "T1.2 planted main.md/cursor/meta/sidecar dirs"
else
  fail "T1.2 plant missing store entries"
fi

# ---------------------------------------------------------------------------
# T1.3 AC3 miss + usage 64
# ---------------------------------------------------------------------------
SID_NONE="t13none"
RC=$(run_st --sid "$SID_NONE")
assert_miss "T1.3 no store" "$RC" "$SID_NONE" ""

SID_MISS="t13miss"
plant_claude_src "$SID_MISS" "$FIX_TM/claude-uuid.jsonl" >/dev/null
CHK_MISS=$(check_sid "$SID_MISS")
if printf '%s\n' "$CHK_MISS" | grep -q "sid=$SID_MISS status=missing"; then
  pass "T1.3 missing --check status=missing"
else
  fail "T1.3 missing --check want status=missing got ${CHK_MISS:-<empty>}"
fi
RC=$(run_st --sid "$SID_MISS")
assert_miss "T1.3 missing" "$RC" "$SID_MISS" ""

SID_LAG="t13lag"
plant_hit "$SID_LAG" "$FIX_TM/claude-uuid.jsonl" "$MAIN_OK" >/dev/null
printf 'wrong-ident\t%s\t%s\n' "$CLAUDE_PROJECTS_DIR/$ENC_CLAUDE/${SID_LAG}.jsonl" \
  "$(sha_file "$STORE/$SID_LAG/main.md")" >"$STORE/$SID_LAG/cursor"
CHK_LAG=$(check_sid "$SID_LAG")
if printf '%s\n' "$CHK_LAG" | grep -q "sid=$SID_LAG status=lag"; then
  pass "T1.3 lag --check status=lag"
else
  fail "T1.3 lag --check want status=lag got ${CHK_LAG:-<empty>}"
fi
MAIN_LAG_SHA=$(sha_file "$STORE/$SID_LAG/main.md")
RC=$(run_st --sid "$SID_LAG")
assert_miss "T1.3 lag" "$RC" "$SID_LAG" "$MAIN_LAG_SHA"

SID_IP="t13ip"
LOC_IP=$(plant_hit "$SID_IP" "$FIX_TM/claude-uuid.jsonl" "$MAIN_OK")
touch "$LOC_IP"
CHK_IP=$(check_sid "$SID_IP")
if printf '%s\n' "$CHK_IP" | grep -q "sid=$SID_IP status=in-progress"; then
  pass "T1.3 in-progress --check status=in-progress"
else
  fail "T1.3 in-progress --check want in-progress got ${CHK_IP:-<empty>}"
fi
MAIN_IP_SHA=$(sha_file "$STORE/$SID_IP/main.md")
RC=$(run_st --sid "$SID_IP")
assert_miss "T1.3 in-progress" "$RC" "$SID_IP" "$MAIN_IP_SHA"

# helper missing / no line (CLI absent → FAIL, not skip)
SID_HELP="t13help"
plant_hit "$SID_HELP" "$FIX_TM/claude-uuid.jsonl" "$MAIN_OK" >/dev/null
MAIN_HELP_SHA=$(sha_file "$STORE/$SID_HELP/main.md")
if [ ! -f "$ST" ]; then
  fail "T1.3 helper-missing CLI absent"
  fail "T1.3 no-line CLI absent"
else
  STUB_PLUG="$WORK/stub-plugin"
  mkdir -p "$STUB_PLUG/skills/transcript-mirror"
  cp "$REPO/skills/plugin-dir.sh" "$STUB_PLUG/skills/plugin-dir.sh"
  cp "$ST" "$STUB_PLUG/skills/transcript-mirror/"
  if [ -f "$HERE/summarize-transcript.py" ]; then
    cp "$HERE/summarize-transcript.py" "$STUB_PLUG/skills/transcript-mirror/"
  fi
  RC=$(CLAUDE_PLUGIN_ROOT="$STUB_PLUG" run_st_bin \
    "$STUB_PLUG/skills/transcript-mirror/summarize-transcript.sh" --sid "$SID_HELP")
  assert_miss "T1.3 helper-missing" "$RC" "$SID_HELP" "$MAIN_HELP_SHA"

  printf '#!/usr/bin/env bash\nprintf "decoy=1\\n"\nexit 0\n' \
    >"$STUB_PLUG/skills/transcript-mirror/transcript-sync.sh"
  chmod +x "$STUB_PLUG/skills/transcript-mirror/transcript-sync.sh"
  RC=$(CLAUDE_PLUGIN_ROOT="$STUB_PLUG" run_st_bin \
    "$STUB_PLUG/skills/transcript-mirror/summarize-transcript.sh" --sid "$SID_HELP")
  assert_miss "T1.3 no-line" "$RC" "$SID_HELP" "$MAIN_HELP_SHA"
fi

TREE_BEFORE=$(find "$STORE" | LC_ALL=C sort)
RC=$(run_st)
assert_usage "T1.3 no-args" "$RC"
RC=$(run_st --restore T000001)
assert_usage "T1.3 --sid missing" "$RC"
RC=$(run_st --bytes)
assert_usage "T1.3 unknown flag" "$RC"
RC=$(run_st --sid t13u --restore)
assert_usage "T1.3 --restore without turn-id" "$RC"
RC=$(run_st --sid 'bad/sid')
assert_usage "T1.3 sid with slash" "$RC"
TREE_AFTER=$(find "$STORE" | LC_ALL=C sort)
if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
  pass "T1.3 usage did not write store"
else
  fail "T1.3 usage mutated store"
fi

# ---------------------------------------------------------------------------
# T1.4 oversized user + undersized assistant
# ---------------------------------------------------------------------------
SID_OV="t14ov"
if ! write_payload_bytes "$WORK/t14-user.payload" 8193 "OVERSIZE-USER-MARKER"; then
  fail "T1.4 could not write 8193-byte user payload"
fi
if ! write_payload_bytes "$WORK/t14-asst.payload" 64 "UNDERSIZE-ASST-MARKER"; then
  fail "T1.4 could not write undersize assistant payload"
fi
USER_PAY_SHA=$(sha_file "$WORK/t14-user.payload")
USER_PAY_N=$(wc -c <"$WORK/t14-user.payload" | tr -d ' ')
if [ "$USER_PAY_N" -gt 8192 ]; then
  pass "T1.4 user payload >8192 ($USER_PAY_N)"
else
  fail "T1.4 user payload too small: $USER_PAY_N"
fi
write_two_turn_main "$WORK/t14-main.md" "$WORK/t14-user.payload" "$WORK/t14-asst.payload"
plant_hit "$SID_OV" "$FIX_TM/claude-uuid.jsonl" "$WORK/t14-main.md" >/dev/null
CHK_OV=$(check_sid "$SID_OV")
if printf '%s\n' "$CHK_OV" | grep -q "sid=$SID_OV status=ok"; then
  pass "T1.4 --check status=ok"
else
  fail "T1.4 --check not ok: ${CHK_OV:-<empty>}"
fi
ASST_BEFORE=$(extract_turn_block "$STORE/$SID_OV/main.md" 2)
HEAD_BEFORE=$(heading_count "$STORE/$SID_OV/main.md")
IFS=$'\t' read -r OV_C1 OV_C2 OV_C3 <"$STORE/$SID_OV/cursor" || true

RC=$(run_st --sid "$SID_OV")
if [ "$RC" -eq 0 ]; then
  pass "T1.4 overlay exit 0"
else
  fail "T1.4 overlay rc=$RC err=$(head -c 240 "$WORK/st.err") out=$(head -c 120 "$WORK/st.out")"
fi
NLINES=$(wc -l <"$WORK/st.out" | tr -d ' ')
IFS= read -r GOT_OUT <"$WORK/st.out" || true
if [ "$NLINES" = "1" ] && [ "$GOT_OUT" = "sid=$SID_OV replaced=1" ]; then
  pass "T1.4 stdout sid=$SID_OV replaced=1"
else
  fail "T1.4 stdout want 'sid=$SID_OV replaced=1' got=${GOT_OUT:-<empty>} nlines=$NLINES"
fi

MAIN_OV="$STORE/$SID_OV/main.md"
if grep -qE '^## user[[:space:]]*$' "$MAIN_OV"; then
  pass "T1.4 oversized heading kept"
else
  fail "T1.4 missing ## user heading"
fi
if grep -q '^STUB:' "$MAIN_OV"; then
  pass "T1.4 stub summary in main.md"
else
  fail "T1.4 missing stub summary"
fi
VREF_N=$(count_verbatim_refs "$MAIN_OV")
if [ "$VREF_N" = "1" ] && grep -qE '^>[[:space:]]*@verbatim/T000001.txt$' "$MAIN_OV"; then
  pass "T1.4 exactly one > @verbatim/T000001.txt"
else
  fail "T1.4 verbatim @ref count=$VREF_N (want 1 T000001)"
fi
VTXT="$STORE/$SID_OV/verbatim/T000001.txt"
VSUM="$STORE/$SID_OV/verbatim/T000001.sum"
if [ -f "$VTXT" ] && [ "$(sha_file "$VTXT")" = "$USER_PAY_SHA" ]; then
  pass "T1.4 .txt bytes equal pre-replacement payload"
else
  fail "T1.4 .txt mismatch or missing"
fi
if [ -f "$VSUM" ] && grep -q '^STUB:' "$VSUM"; then
  pass "T1.4 .sum holds summary"
else
  fail "T1.4 .sum missing or not summary"
fi
ASST_AFTER=$(extract_turn_block "$MAIN_OV" 2)
if [ "$ASST_BEFORE" = "$ASST_AFTER" ] && printf '%s\n' "$ASST_AFTER" | grep -qF 'UNDERSIZE-ASST-MARKER'; then
  pass "T1.4 undersized assistant byte-identical"
else
  fail "T1.4 undersized assistant mutated"
fi
HEAD_AFTER=$(heading_count "$MAIN_OV")
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
  pass "T1.4 no heading add/drop"
else
  fail "T1.4 heading count $HEAD_BEFORE -> $HEAD_AFTER"
fi
if grep -qF '[summarization failed]' "$MAIN_OV"; then
  fail "T1.4 wrote [summarization failed]"
else
  pass "T1.4 no summarization-failed placeholder"
fi

# ---------------------------------------------------------------------------
# T1.5 idempotent second --sid
# ---------------------------------------------------------------------------
FP_OV=$(store_fingerprint "$STORE/$SID_OV")
RC=$(run_st --sid "$SID_OV")
if [ "$RC" -eq 0 ]; then
  pass "T1.5 second overlay exit 0"
else
  fail "T1.5 second overlay rc=$RC err=$(head -c 200 "$WORK/st.err")"
fi
IFS= read -r GOT5 <"$WORK/st.out" || true
if [ "$GOT5" = "sid=$SID_OV replaced=0" ]; then
  pass "T1.5 stdout replaced=0"
else
  fail "T1.5 stdout want replaced=0 got=${GOT5:-<empty>}"
fi
FP_OV2=$(store_fingerprint "$STORE/$SID_OV")
if [ "$FP_OV" = "$FP_OV2" ]; then
  pass "T1.5 store sha256 unchanged"
else
  fail "T1.5 store mutated on second overlay"
fi

# ---------------------------------------------------------------------------
# T1.10 M7 sidecar dirs + no fourth kind string (while overlay present)
# ---------------------------------------------------------------------------
assert_sidecar_dirs "$SID_OV" "T1.10"
FOURTH=$(git grep -nE 'thinking[[:space:]]*\|[[:space:]]*tool_result[[:space:]]*\|[[:space:]]*injection[[:space:]]*\|' \
  -- specs/core/SPEC-036-transcript-mirror.md \
     skills/transcript-mirror \
     docs/commands/transcript-mirror.md \
     CONTEXT.md \
     ':!skills/transcript-mirror/summarize-transcript-test.sh' \
  2>/dev/null || true)
if [ -z "$FOURTH" ]; then
  pass "T1.10 no fourth kind string in taxonomy pipes"
else
  fail "T1.10 fourth kind string: $(printf '%s\n' "$FOURTH" | head -c 200)"
fi

# ---------------------------------------------------------------------------
# T1.6 restore
# ---------------------------------------------------------------------------
IFS=$'\t' read -r PRE_C1 PRE_C2 PRE_C3 <"$STORE/$SID_OV/cursor" || true
ASST_PRE_R=$(extract_turn_block "$MAIN_OV" 2)
RC=$(run_st --sid "$SID_OV" --restore T000001)
if [ "$RC" -eq 0 ]; then
  pass "T1.6 restore exit 0"
else
  fail "T1.6 restore rc=$RC err=$(head -c 240 "$WORK/st.err") out=$(head -c 120 "$WORK/st.out")"
fi
NLINES6=$(wc -l <"$WORK/st.out" | tr -d ' ')
IFS= read -r GOT6 <"$WORK/st.out" || true
if [ "$NLINES6" = "1" ] && [ "$GOT6" = "sid=$SID_OV restored=T000001" ]; then
  pass "T1.6 stdout sid=$SID_OV restored=T000001"
else
  fail "T1.6 stdout want restored=T000001 got=${GOT6:-<empty>} nlines=$NLINES6"
fi
if grep -qF 'OVERSIZE-USER-MARKER' "$MAIN_OV" && ! grep -q '^STUB:' "$MAIN_OV"; then
  pass "T1.6 spliced original payload"
else
  fail "T1.6 payload not spliced back"
fi
VREF_R=$(count_verbatim_refs "$MAIN_OV")
if [ "$VREF_R" = "0" ]; then
  pass "T1.6 dropped @verbatim/ ref"
else
  fail "T1.6 still has @verbatim/ count=$VREF_R"
fi
if [ -e "$VTXT" ] || [ -e "$VSUM" ]; then
  fail "T1.6 .txt/.sum not deleted"
else
  pass "T1.6 deleted .txt/.sum"
fi
ASST_POST_R=$(extract_turn_block "$MAIN_OV" 2)
if [ "$ASST_PRE_R" = "$ASST_POST_R" ]; then
  pass "T1.6 other turn untouched"
else
  fail "T1.6 assistant turn mutated on restore"
fi
IFS=$'\t' read -r POST_C1 POST_C2 POST_C3 <"$STORE/$SID_OV/cursor" || true
MAIN_R_SHA=$(sha_file "$MAIN_OV")
if [ "$POST_C1" = "$PRE_C1" ] && [ "$POST_C2" = "$PRE_C2" ]; then
  pass "T1.6 cursor fields 1-2 unchanged"
else
  fail "T1.6 cursor ident/path changed"
fi
if [ "$POST_C3" = "$MAIN_R_SHA" ]; then
  pass "T1.6 cursor field 3 matches main.md"
else
  fail "T1.6 cursor field 3 mismatch"
fi

FP_MISS=$(store_fingerprint "$STORE/$SID_OV")
RC=$(run_st --sid "$SID_OV" --restore T000099)
if [ "$RC" -eq 1 ]; then
  pass "T1.6 missing turn-id exit 1"
else
  fail "T1.6 missing turn-id rc=$RC want 1"
fi
FP_MISS2=$(store_fingerprint "$STORE/$SID_OV")
if [ "$FP_MISS" = "$FP_MISS2" ]; then
  pass "T1.6 missing turn-id store byte-identical"
else
  fail "T1.6 missing turn-id mutated store"
fi

# ---------------------------------------------------------------------------
# T1.7 cursor + next recorder increment
# ---------------------------------------------------------------------------
SID_INC="t17inc"
write_oversize_jsonl "$WORK/src/t17.jsonl" t17-u1 t17-a1 T17-OVERSIZE
LOC_INC=$(plant_claude_src "$SID_INC" "$WORK/src/t17.jsonl")
RC=$(invoke_rec --transcript "$LOC_INC" --sid "$SID_INC")
if [ "$RC" -eq 0 ] && [ -f "$STORE/$SID_INC/main.md" ]; then
  pass "T1.7 recorder plant exit 0"
else
  fail "T1.7 recorder plant rc=$RC err=$(head -c 200 "$WORK/rec.err")"
fi
CHK_INC=$(check_sid "$SID_INC")
if printf '%s\n' "$CHK_INC" | grep -q "sid=$SID_INC status=ok"; then
  pass "T1.7 --check status=ok"
else
  fail "T1.7 --check not ok: ${CHK_INC:-<empty>}"
fi
RC=$(run_st --sid "$SID_INC")
if [ "$RC" -eq 0 ]; then
  pass "T1.7 overlay exit 0"
else
  fail "T1.7 overlay rc=$RC err=$(head -c 200 "$WORK/st.err")"
fi
IFS=$'\t' read -r INC_C1 INC_C2 INC_C3 <"$STORE/$SID_INC/cursor" || true
INC_MAIN_SHA=$(sha_file "$STORE/$SID_INC/main.md")
if [ "$INC_C3" = "$INC_MAIN_SHA" ]; then
  pass "T1.7 cursor field 3 == sha256sum main.md"
else
  fail "T1.7 cursor field 3 mismatch after overlay"
fi
HEAD_INC=$(heading_count "$STORE/$SID_INC/main.md")
FP_VER=$(store_fingerprint "$STORE/$SID_INC/verbatim" 2>/dev/null || true)
printf '%s\n' '{"uuid":"t17-extra","type":"user","message":{"role":"user","content":[{"type":"text","text":"T17-EXTRA-TURN"}]}}' >>"$LOC_INC"
age "$LOC_INC"
RC=$(invoke_rec --transcript "$LOC_INC" --sid "$SID_INC")
if [ "$RC" -eq 0 ]; then
  pass "T1.7 increment recorder exit 0"
else
  fail "T1.7 increment recorder rc=$RC"
fi
HEAD_INC2=$(heading_count "$STORE/$SID_INC/main.md")
if [ "$HEAD_INC2" -eq $((HEAD_INC + 1)) ]; then
  pass "T1.7 no duplicate headings (count $HEAD_INC -> $HEAD_INC2)"
else
  fail "T1.7 heading count $HEAD_INC -> $HEAD_INC2 want +1"
fi
if grep -qF 'T17-EXTRA-TURN' "$STORE/$SID_INC/main.md"; then
  pass "T1.7 new turn text present"
else
  fail "T1.7 extra JSONL line not appended"
fi
if grep -qE '^>[[:space:]]*@verbatim/T000003.txt$' "$STORE/$SID_INC/main.md"; then
  fail "T1.7 new turn was summarized"
else
  pass "T1.7 new turn verbatim (not summarized)"
fi
if grep -qF 'STUB:T17-EXTRA-TURN' "$STORE/$SID_INC/main.md"; then
  fail "T1.7 extra turn ran through stub"
else
  pass "T1.7 extra turn not stubbed"
fi
FP_VER2=$(store_fingerprint "$STORE/$SID_INC/verbatim" 2>/dev/null || true)
if [ "$FP_VER" = "$FP_VER2" ]; then
  pass "T1.7 verbatim/ unchanged"
else
  fail "T1.7 verbatim/ mutated on increment"
fi

# ---------------------------------------------------------------------------
# T1.8 rebuild re-apply; verbatim + meaning-tail survive; no LLM
# ---------------------------------------------------------------------------
SID_REB="t18reb"
write_oversize_jsonl "$WORK/src/t18.jsonl" t18-u1 t18-a1 T18-OVERSIZE
LOC_REB=$(plant_claude_src "$SID_REB" "$WORK/src/t18.jsonl")
RC=$(invoke_rec --transcript "$LOC_REB" --sid "$SID_REB")
if [ "$RC" -eq 0 ] && [ -f "$STORE/$SID_REB/main.md" ]; then
  pass "T1.8 recorder plant exit 0"
else
  fail "T1.8 recorder plant rc=$RC"
fi
RC=$(run_st --sid "$SID_REB")
if [ "$RC" -eq 0 ]; then
  pass "T1.8 overlay exit 0"
else
  fail "T1.8 overlay rc=$RC err=$(head -c 200 "$WORK/st.err")"
fi
TAIL_REB=$(tail_path "$SID_REB")
printf 'PLANTED-TAIL-REBUILD-MUST-NOT-TOUCH\n' >"$TAIL_REB"
SHA_TAIL1=$(sha_file "$TAIL_REB")
VTXT_REB="$STORE/$SID_REB/verbatim/T000001.txt"
if [ -f "$VTXT_REB" ]; then
  SHA_VTXT1=$(sha_file "$VTXT_REB")
  pass "T1.8 planted verbatim T000001.txt"
else
  SHA_VTXT1=""
  fail "T1.8 overlay did not write verbatim/T000001.txt"
fi
HEAD_REB=$(heading_count "$STORE/$SID_REB/main.md")
printf '\nJUNK-REBUILD-MARKER\n' >>"$STORE/$SID_REB/main.md"
SAVED_SEAM="$SUMMARIZE_TRANSCRIPT_CMD"
unset SUMMARIZE_TRANSCRIPT_CMD || true
RC=$(invoke_rec --transcript "$LOC_REB" --sid "$SID_REB")
export SUMMARIZE_TRANSCRIPT_CMD="$SAVED_SEAM"
if [ "$RC" -eq 0 ]; then
  pass "T1.8 rebuild recorder exit 0"
else
  fail "T1.8 rebuild recorder rc=$RC"
fi
if [ -f "$VTXT_REB" ] && [ -n "$SHA_VTXT1" ] && [ "$(sha_file "$VTXT_REB")" = "$SHA_VTXT1" ]; then
  pass "T1.8 verbatim/*.txt sha256 unchanged"
else
  fail "T1.8 verbatim/ eaten or rewritten"
fi
if [ -f "$TAIL_REB" ] && [ "$(sha_file "$TAIL_REB")" = "$SHA_TAIL1" ] \
   && grep -q 'PLANTED-TAIL-REBUILD-MUST-NOT-TOUCH' "$TAIL_REB"; then
  pass "T1.8 meaning-tail sha256 unchanged"
else
  fail "T1.8 rebuild ate/mutated sibling meaning-tail"
fi
if grep -q '^STUB:' "$STORE/$SID_REB/main.md" \
   && grep -qE '^>[[:space:]]*@verbatim/T000001.txt$' "$STORE/$SID_REB/main.md"; then
  pass "T1.8 main.md has summary+@ref again (no LLM)"
else
  fail "T1.8 overlay not re-applied without LLM"
fi
if grep -qF 'JUNK-REBUILD-MARKER' "$STORE/$SID_REB/main.md"; then
  fail "T1.8 junk hash-mismatch marker survived rebuild"
else
  pass "T1.8 rebuild replaced mutated main.md"
fi
HEAD_REB2=$(heading_count "$STORE/$SID_REB/main.md")
if [ "$HEAD_REB" = "$HEAD_REB2" ]; then
  pass "T1.8 no duplicate headings after rebuild"
else
  fail "T1.8 heading count $HEAD_REB -> $HEAD_REB2"
fi
IFS=$'\t' read -r REB_C1 REB_C2 REB_C3 <"$STORE/$SID_REB/cursor" || true
REB_MAIN_SHA=$(sha_file "$STORE/$SID_REB/main.md")
if [ "$REB_C3" = "$REB_MAIN_SHA" ]; then
  pass "T1.8 cursor field 3 matches post-reapply main.md"
else
  fail "T1.8 cursor field 3 mismatch after rebuild"
fi
if [ -f "$TAIL_REB" ] && [ ! -d "$TAIL_REB" ]; then
  pass "T1.8 meaning-tail still a file (not bak-swap)"
else
  fail "T1.8 meaning-tail path is not a regular file after rebuild"
fi

# ---------------------------------------------------------------------------
# T1.9 AC10 exact 8192 / stub fail / stub not-shorter
# ---------------------------------------------------------------------------
SID_EQ="t19eq"
if ! write_payload_bytes "$WORK/t19-eq.payload" 8192 "EXACT-8192-MARKER"; then
  fail "T1.9 could not write 8192-byte payload"
fi
EQ_N=$(wc -c <"$WORK/t19-eq.payload" | tr -d ' ')
if [ "$EQ_N" -eq 8192 ]; then
  pass "T1.9 payload exactly 8192"
else
  fail "T1.9 payload $EQ_N want 8192"
fi
write_two_turn_main "$WORK/t19-eq-main.md" "$WORK/t19-eq.payload" "$WORK/t14-asst.payload"
plant_hit "$SID_EQ" "$FIX_TM/claude-uuid.jsonl" "$WORK/t19-eq-main.md" >/dev/null
FP_EQ=$(store_fingerprint "$STORE/$SID_EQ")
RC=$(run_st --sid "$SID_EQ")
if [ "$RC" -eq 0 ]; then
  pass "T1.9 exact 8192 exit 0"
else
  fail "T1.9 exact 8192 rc=$RC want 0 err=$(head -c 200 "$WORK/st.err")"
fi
IFS= read -r GOT_EQ <"$WORK/st.out" || true
if [ "$GOT_EQ" = "sid=$SID_EQ replaced=0" ]; then
  pass "T1.9 exact 8192 stdout replaced=0"
else
  fail "T1.9 exact 8192 stdout got=${GOT_EQ:-<empty>}"
fi
FP_EQ2=$(store_fingerprint "$STORE/$SID_EQ")
if [ "$FP_EQ" = "$FP_EQ2" ]; then
  pass "T1.9 exact 8192 store byte-identical"
else
  fail "T1.9 exact 8192 store mutated"
fi
if [ -e "$STORE/$SID_EQ/verbatim" ]; then
  fail "T1.9 exact 8192 created verbatim/"
else
  pass "T1.9 exact 8192 not eligible (no verbatim/)"
fi

SID_FAIL="t19fail"
write_two_turn_main "$WORK/t19-fail-main.md" "$WORK/t14-user.payload" "$WORK/t14-asst.payload"
plant_hit "$SID_FAIL" "$FIX_TM/claude-uuid.jsonl" "$WORK/t19-fail-main.md" >/dev/null
FP_FAIL=$(store_fingerprint "$STORE/$SID_FAIL")
RC=$(SUMMARIZE_TRANSCRIPT_CMD="$WORK/stub-fail.sh" run_st --sid "$SID_FAIL")
if [ "$RC" -eq 0 ]; then
  pass "T1.9 stub-fail overlay exit 0"
else
  fail "T1.9 stub-fail rc=$RC want 0 (per-turn verbatim)"
fi
FP_FAIL2=$(store_fingerprint "$STORE/$SID_FAIL")
if [ "$FP_FAIL" = "$FP_FAIL2" ]; then
  pass "T1.9 stub-fail turn left verbatim"
else
  fail "T1.9 stub-fail mutated store"
fi
if grep -qF '[summarization failed]' "$STORE/$SID_FAIL/main.md"; then
  fail "T1.9 stub-fail wrote [summarization failed]"
else
  pass "T1.9 stub-fail no [summarization failed]"
fi

SID_ECHO="t19echo"
write_two_turn_main "$WORK/t19-echo-main.md" "$WORK/t14-user.payload" "$WORK/t14-asst.payload"
plant_hit "$SID_ECHO" "$FIX_TM/claude-uuid.jsonl" "$WORK/t19-echo-main.md" >/dev/null
FP_ECHO=$(store_fingerprint "$STORE/$SID_ECHO")
RC=$(SUMMARIZE_TRANSCRIPT_CMD="$WORK/stub-echo.sh" run_st --sid "$SID_ECHO")
if [ "$RC" -eq 0 ]; then
  pass "T1.9 stub-echo overlay exit 0"
else
  fail "T1.9 stub-echo rc=$RC want 0"
fi
FP_ECHO2=$(store_fingerprint "$STORE/$SID_ECHO")
if [ "$FP_ECHO" = "$FP_ECHO2" ]; then
  pass "T1.9 stub-echo left verbatim (not shorter)"
else
  fail "T1.9 stub-echo mutated store"
fi
if grep -qE '^>[[:space:]]*@verbatim/' "$STORE/$SID_ECHO/main.md"; then
  fail "T1.9 stub-echo wrote @verbatim/ despite not-shorter summary"
else
  pass "T1.9 stub-echo no @verbatim/"
fi

# ---------------------------------------------------------------------------
# T1.11 nests OUT
# ---------------------------------------------------------------------------
SID_NEST="t111nest"
write_two_turn_main "$WORK/t111-parent.md" "$WORK/t14-user.payload" "$WORK/t14-asst.payload"
plant_hit "$SID_NEST" "$FIX_TM/claude-uuid.jsonl" "$WORK/t111-parent.md" >/dev/null
NEST_MAIN="$STORE/$SID_NEST/agents/w/main.md"
write_two_turn_main "$NEST_MAIN" "$WORK/t14-user.payload" "$WORK/t14-asst.payload"
NEST_SHA=$(sha_file "$NEST_MAIN")
RC=$(run_st --sid "$SID_NEST")
if [ "$RC" -eq 0 ]; then
  pass "T1.11 parent overlay exit 0"
else
  fail "T1.11 parent overlay rc=$RC err=$(head -c 200 "$WORK/st.err")"
fi
if [ "$(sha_file "$NEST_MAIN")" = "$NEST_SHA" ]; then
  pass "T1.11 nest main.md sha256 unchanged"
else
  fail "T1.11 nest main.md mutated"
fi
if grep -qE '^>[[:space:]]*@verbatim/' "$STORE/$SID_NEST/main.md" \
   && ! grep -qE '^>[[:space:]]*@verbatim/' "$NEST_MAIN"; then
  pass "T1.11 overlay parent only"
else
  fail "T1.11 parent missing @ref or nest gained @ref"
fi
if [ -e "$STORE/$SID_NEST/agents/w/verbatim" ]; then
  fail "T1.11 invented nest verbatim/"
else
  pass "T1.11 no nest verbatim/"
fi

# ---------------------------------------------------------------------------
# T1.12 planted *.meaning-tail.md isolation
# ---------------------------------------------------------------------------
SID_TAIL="t112tail"
write_two_turn_main "$WORK/t112-main.md" "$WORK/t14-user.payload" "$WORK/t14-asst.payload"
plant_hit "$SID_TAIL" "$FIX_TM/claude-uuid.jsonl" "$WORK/t112-main.md" >/dev/null
TAIL_T=$(tail_path "$SID_TAIL")
printf 'PLANTED-TAIL-OVERLAY-RESTORE-MUST-NOT-TOUCH\n' >"$TAIL_T"
SHA_T1=$(sha_file "$TAIL_T")
RC=$(run_st --sid "$SID_TAIL")
if [ "$RC" -eq 0 ]; then
  pass "T1.12 overlay exit 0"
else
  fail "T1.12 overlay rc=$RC"
fi
if [ "$(sha_file "$TAIL_T")" = "$SHA_T1" ]; then
  pass "T1.12 meaning-tail sha256 unchanged after overlay"
else
  fail "T1.12 overlay mutated meaning-tail"
fi
RC=$(run_st --sid "$SID_TAIL" --restore T000001)
if [ "$RC" -eq 0 ]; then
  pass "T1.12 restore exit 0"
else
  fail "T1.12 restore rc=$RC"
fi
if [ "$(sha_file "$TAIL_T")" = "$SHA_T1" ] \
   && grep -q 'PLANTED-TAIL-OVERLAY-RESTORE-MUST-NOT-TOUCH' "$TAIL_T"; then
  pass "T1.12 meaning-tail sha256 unchanged after restore"
else
  fail "T1.12 restore mutated meaning-tail"
fi

# ---------------------------------------------------------------------------
# T2.4 reapply-overlay.sh direct (until T4 wires rebuild)
# ---------------------------------------------------------------------------
if [ -f "$RO" ] && bash -n "$RO"; then
  pass "T2.4 bash -n reapply-overlay.sh"
else
  fail "T2.4 bash -n reapply-overlay.sh (missing or syntax)"
fi
if [ -f "$RO" ]; then
  PYHIT=$(grep -n python3 "$RO" || true)
  SEAMHIT=$(grep -n SUMMARIZE_TRANSCRIPT_CMD "$RO" || true)
  if [ -z "$PYHIT" ]; then
    pass "T2.4 no python3 in reapply-overlay.sh"
  else
    fail "T2.4 python3 string present: $PYHIT"
  fi
  if [ -z "$SEAMHIT" ]; then
    pass "T2.4 no SUMMARIZE_TRANSCRIPT_CMD in reapply-overlay.sh"
  else
    fail "T2.4 seam string present: $SEAMHIT"
  fi
else
  fail "T2.4 no python3 in reapply-overlay.sh (missing)"
  fail "T2.4 no SUMMARIZE_TRANSCRIPT_CMD in reapply-overlay.sh (missing)"
fi

run_ro() {
  local rc=0
  bash "$RO" "$@" >"$WORK/ro.out" 2>"$WORK/ro.err" || rc=$?
  printf '%s' "$rc"
}

if [ -f "$RO" ]; then
  RC=$(run_ro)
  if [ "$RC" -eq 64 ]; then
    pass "T2.4 no-args exit 64"
  else
    fail "T2.4 no-args rc=$RC want 64"
  fi
  RC=$(run_ro a b)
  if [ "$RC" -eq 64 ]; then
    pass "T2.4 extra-args exit 64"
  else
    fail "T2.4 extra-args rc=$RC want 64"
  fi
  RC=$(run_ro "$WORK/t24-missing")
  if [ "$RC" -eq 1 ]; then
    pass "T2.4 missing main.md exit 1"
  else
    fail "T2.4 missing main.md rc=$RC want 1"
  fi
else
  fail "T2.4 no-args CLI absent"
  fail "T2.4 extra-args CLI absent"
  fail "T2.4 missing main.md CLI absent"
fi

SID_RO="$WORK/t24-sid"
mkdir -p "$SID_RO/verbatim" "$SID_RO/thinking" "$SID_RO/tool_result" "$SID_RO/injection"
cat >"$SID_RO/main.md" <<'EOF'
# transcript mirror

## user
USER-PAYLOAD-LINE
## assistant

> @thinking/L2.txt

ASST-PAYLOAD-LINE

> @tool_result/L2-call.txt
> @agents/w/main.md
EOF
printf 'USER-PAYLOAD-LINE\n' >"$SID_RO/verbatim/T000001.txt"
printf 'SUM-USER\n' >"$SID_RO/verbatim/T000001.sum"
printf 'ASST-PAYLOAD-LINE\n' >"$SID_RO/verbatim/T000002.txt"
printf 'SUM-ASST\n' >"$SID_RO/verbatim/T000002.sum"
printf 'ghost-payload\n' >"$SID_RO/verbatim/T000099.txt"
printf 'GHOST-SUM\n' >"$SID_RO/verbatim/T000099.sum"
printf 'no-sum-payload\n' >"$SID_RO/verbatim/T000003.txt"
cat >"$WORK/t24-want.md" <<'EOF'
# transcript mirror

## user
SUM-USER
> @verbatim/T000001.txt
## assistant

> @thinking/L2.txt

SUM-ASST
> @verbatim/T000002.txt

> @tool_result/L2-call.txt
> @agents/w/main.md
EOF
SHA_TXT1=$(sha_file "$SID_RO/verbatim/T000001.txt")
SHA_TXT2=$(sha_file "$SID_RO/verbatim/T000002.txt")
SAVED_SEAM_RO="${SUMMARIZE_TRANSCRIPT_CMD-}"
unset SUMMARIZE_TRANSCRIPT_CMD || true
if [ -f "$RO" ]; then
  RC=$(run_ro "$SID_RO")
else
  RC=127
fi
if [ -n "${SAVED_SEAM_RO}" ]; then
  export SUMMARIZE_TRANSCRIPT_CMD="$SAVED_SEAM_RO"
fi
if [ "$RC" -eq 0 ]; then
  pass "T2.4 overlay exit 0"
else
  fail "T2.4 overlay rc=$RC err=$(head -c 240 "$WORK/ro.err" 2>/dev/null || true)"
fi
if cmp -s "$SID_RO/main.md" "$WORK/t24-want.md"; then
  pass "T2.4 main.md summary+@ref; leading/trailing @refs kept"
else
  fail "T2.4 main.md mismatch got=$(head -c 400 "$SID_RO/main.md")"
fi
VREF_RO=$(count_verbatim_refs "$SID_RO/main.md")
if [ "$VREF_RO" = "2" ] \
   && grep -qE '^>[[:space:]]*@verbatim/T000001.txt$' "$SID_RO/main.md" \
   && grep -qE '^>[[:space:]]*@verbatim/T000002.txt$' "$SID_RO/main.md"; then
  pass "T2.4 exactly one @verbatim/ per overlaid turn"
else
  fail "T2.4 verbatim @ref count=$VREF_RO"
fi
if grep -q 'GHOST-SUM\|USER-PAYLOAD-LINE\|ASST-PAYLOAD-LINE' "$SID_RO/main.md"; then
  fail "T2.4 leftover payload or ghost heading 99"
else
  pass "T2.4 skipped missing heading T000099; payloads replaced"
fi
if [ "$(sha_file "$SID_RO/verbatim/T000001.txt")" = "$SHA_TXT1" ] \
   && [ "$(sha_file "$SID_RO/verbatim/T000002.txt")" = "$SHA_TXT2" ]; then
  pass "T2.4 verbatim .txt bytes unchanged"
else
  fail "T2.4 reapply mutated .txt"
fi
SHA_RO1=$(sha_file "$SID_RO/main.md")
if [ -f "$RO" ]; then
  RC=$(run_ro "$SID_RO")
else
  RC=127
fi
SHA_RO2=$(sha_file "$SID_RO/main.md")
if [ "$RC" -eq 0 ] && [ "$SHA_RO1" = "$SHA_RO2" ]; then
  pass "T2.4 second run idempotent (same main.md bytes)"
else
  fail "T2.4 second run rc=$RC sha $SHA_RO1 -> $SHA_RO2"
fi

# ---------------------------------------------------------------------------
# operator store untouched
# ---------------------------------------------------------------------------
AFTER_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
AFTER_OP_N=$(printf '%s\n' "$AFTER_OP" | grep -c . || true)
if [ "$BEFORE_OP" = "$AFTER_OP" ]; then
  pass "T1 operator ~/.claude/transcript/ untouched (n=$BEFORE_OP_N)"
else
  fail "T1 operator store changed before_n=$BEFORE_OP_N after_n=$AFTER_OP_N"
  printf 'BEFORE\n%s\nAFTER\n%s\n' "$BEFORE_OP" "$AFTER_OP" >&2
fi
if [ -d "$FAKE_HOME/.claude/transcript" ]; then
  fail "T1 wrote fake HOME transcript (ROOT override ignored?)"
else
  pass "T1 no default-root write under fake HOME"
fi
if [ -d "$STORE/$SID_OK" ]; then
  pass "T1 suite wrote under TRANSCRIPT_MIRROR_ROOT"
else
  fail "T1 suite did not use TRANSCRIPT_MIRROR_ROOT"
fi

printf '\nsummarize-transcript-test: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
printf 'operator-store: unchanged n=%s root=%s\n' "$BEFORE_OP_N" "$OP_STORE"
[ "$FAIL" -eq 0 ]
