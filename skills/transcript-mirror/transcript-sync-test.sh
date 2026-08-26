#!/usr/bin/env bash
# transcript-sync CLI tests (SPEC-036 M10–M11 / CDT-220 Task 2 + CDT-221 T1 + CDT-218 T3).
# Run: bash skills/transcript-mirror/transcript-sync-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SYNC="$HERE/transcript-sync.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

REAL_HOME="${HOME}"
OP_STORE="$REAL_HOME/.claude/transcript"
BEFORE_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tm-sync-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
STORE="$WORK/store"
SESS="$WORK/sessions"
PROJ="$WORK/proj"
TMP="$WORK/tmp"
mkdir -p "$FAKE_HOME" "$STORE" "$SESS" "$PROJ/.claude/hooks" "$TMP"

export HOME="$FAKE_HOME"
export TRANSCRIPT_MIRROR_ROOT="$STORE"
export GROK_SESSIONS_DIR="$SESS"
export TMPDIR="$TMP"
unset CLAUDE_PLUGIN_ROOT || true

age() { touch -d '2 minutes ago' "$1"; }

# Claude-shaped JSONL the recorder will turn into main.md (uuid identities).
write_mini() {
  local dest="$1"
  cat >"$dest" <<'EOF'
{"uuid": "tm-u1", "type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "hello from sync fixture"}]}}
{"uuid": "tm-a1", "type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "hi from assistant"}]}}
EOF
  age "$dest"
}

# Grok chat_history.jsonl — no uuid; identity is h:+SHA-256(jq -S -c).
write_grok_nouuid() {
  local dest="$1"
  cat >"$dest" <<'EOF'
{"type": "user", "content": [{"type": "text", "text": "grok nouuid user café"}], "prompt_index": 1}
{"type": "assistant", "content": "grok nouuid assistant 日本語", "model_id": "fixture"}
EOF
  age "$dest"
}

write_opt_in() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
}

seed_store() {
  mkdir -p "$1/$2"
  printf '## user\n\nseed %s\n' "$2" >"$1/$2/main.md"
}

urlenc_cwd() {
  CWD_RAW="$(cd "$1" && pwd)" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
}

claude_pdir() {
  local abs
  abs="$(cd "$1" && pwd)"
  printf '%s/.claude/projects/%s\n' "$HOME" "${abs//\//-}"
}

ENC="$(CWD_RAW="$(cd "$PROJ" && pwd)" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)"
PROJ_ABS="$(cd "$PROJ" && pwd)"
BUCKET="$SESS/$ENC"

# ---------------------------------------------------------------------------
# M10 — --sid on never-mirrored fixture creates main.md
# ---------------------------------------------------------------------------
SID1="sess-220-a"
write_mini "$WORK/$SID1.jsonl"
set +e
OUT1="$("$SYNC" --sid "$SID1" --transcript "$WORK/$SID1.jsonl" --cwd "$PROJ_ABS" 2>"$WORK/sid1.err")"
RC1=$?
set -e
if [ "$RC1" -eq 0 ] && [ -f "$STORE/$SID1/main.md" ] \
   && grep -q 'hello from sync fixture' "$STORE/$SID1/main.md"; then
  pass "M10 --sid never-mirrored creates main.md"
else
  bad "M10 --sid rc=$RC1 main=$(ls -l "$STORE/$SID1/main.md" 2>/dev/null || echo missing) err=$(cat "$WORK/sid1.err")"
fi

# ---------------------------------------------------------------------------
# M11 — --check exits 0 with a lag line
# ---------------------------------------------------------------------------
set +e
CHK1="$("$SYNC" --check --sid "$SID1" --transcript "$WORK/$SID1.jsonl" --cwd "$PROJ_ABS" 2>"$WORK/chk1.err")"
RC_CHK1=$?
set -e
if [ "$RC_CHK1" -eq 0 ] && printf '%s\n' "$CHK1" | grep -q "sid=$SID1"; then
  pass "M11 --check exit 0 lag line (synced)"
else
  bad "M11 --check rc=$RC_CHK1 out=${CHK1:-<empty>} err=$(cat "$WORK/chk1.err")"
fi

# Missing-mirror --check still prints a lag/missing line.
SID_MISS="sess-220-miss"
write_mini "$WORK/$SID_MISS.jsonl"
set +e
CHK_MISS="$("$SYNC" --check --sid "$SID_MISS" --transcript "$WORK/$SID_MISS.jsonl" --cwd "$PROJ_ABS" 2>"$WORK/chk-miss.err")"
RC_MISS=$?
set -e
if [ "$RC_MISS" -eq 0 ] && printf '%s\n' "$CHK_MISS" | grep -Eq "sid=$SID_MISS.*(status=missing|status=lag|missing)"; then
  pass "M11 --check missing-mirror lag line"
else
  bad "M11 missing-check rc=$RC_MISS out=${CHK_MISS:-<empty>} err=$(cat "$WORK/chk-miss.err")"
fi

# Growth after cursor → lag
printf '%s\n' '{"uuid": "tm-u2", "type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "second turn"}]}}' >>"$WORK/$SID1.jsonl"
age "$WORK/$SID1.jsonl"
set +e
CHK_LAG="$("$SYNC" --check --sid "$SID1" --transcript "$WORK/$SID1.jsonl" --cwd "$PROJ_ABS" 2>"$WORK/chk-lag.err")"
RC_LAG=$?
set -e
if [ "$RC_LAG" -eq 0 ] && printf '%s\n' "$CHK_LAG" | grep -q "status=lag"; then
  pass "M11 --check source growth status=lag"
else
  bad "M11 lag rc=$RC_LAG out=${CHK_LAG:-<empty>} err=$(cat "$WORK/chk-lag.err")"
fi

# ---------------------------------------------------------------------------
# M10 — in-progress source (freshness 9) skipped
# ---------------------------------------------------------------------------
SID_FRESH="sess-220-fresh"
write_mini "$WORK/$SID_FRESH.jsonl"
touch "$WORK/$SID_FRESH.jsonl"   # mtime now → freshness exit 9
set +e
"$SYNC" --sid "$SID_FRESH" --transcript "$WORK/$SID_FRESH.jsonl" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/fresh.err"
RC_FRESH=$?
set -e
if [ "$RC_FRESH" -eq 0 ] && [ ! -f "$STORE/$SID_FRESH/main.md" ]; then
  pass "M10 freshness 9 skipped (no main.md)"
else
  bad "M10 fresh rc=$RC_FRESH main=$(ls "$STORE/$SID_FRESH/main.md" 2>/dev/null || echo none) err=$(cat "$WORK/fresh.err")"
fi

# --check on in-progress still exit 0 with a line
set +e
CHK_F="$("$SYNC" --check --sid "$SID_FRESH" --transcript "$WORK/$SID_FRESH.jsonl" --cwd "$PROJ_ABS" 2>"$WORK/chk-fresh.err")"
RC_CF=$?
set -e
if [ "$RC_CF" -eq 0 ] && printf '%s\n' "$CHK_F" | grep -q "status=in-progress"; then
  pass "M11 --check in-progress line"
else
  bad "M11 in-progress-check rc=$RC_CF out=${CHK_F:-<empty>} err=$(cat "$WORK/chk-fresh.err")"
fi

# ---------------------------------------------------------------------------
# M10 — always pass --sid: Grok chat_history basename must not become store key
# ---------------------------------------------------------------------------
SID_GROK="sess-220-grok"
mkdir -p "$BUCKET/$SID_GROK"
write_mini "$BUCKET/$SID_GROK/chat_history.jsonl"
set +e
"$SYNC" --transcript "$BUCKET/$SID_GROK/chat_history.jsonl" --sid "$SID_GROK" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/grok.err"
RC_GROK=$?
set -e
if [ "$RC_GROK" -eq 0 ] && [ -f "$STORE/$SID_GROK/main.md" ] && [ ! -e "$STORE/chat_history" ] \
   && [ ! -e "$STORE/chat_history.jsonl" ]; then
  pass "M10 Grok --sid store key is session id not chat_history"
else
  bad "M10 grok rc=$RC_GROK store=$(ls "$STORE" 2>/dev/null) err=$(cat "$WORK/grok.err")"
fi

# Derive sid from parent dir when --sid omitted but path is chat_history.jsonl
SID_DERIVE="sess-220-derive"
mkdir -p "$BUCKET/$SID_DERIVE"
write_mini "$BUCKET/$SID_DERIVE/chat_history.jsonl"
set +e
"$SYNC" --transcript "$BUCKET/$SID_DERIVE/chat_history.jsonl" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/derive.err"
RC_DER=$?
set -e
if [ "$RC_DER" -eq 0 ] && [ -f "$STORE/$SID_DERIVE/main.md" ] && [ ! -e "$STORE/chat_history" ]; then
  pass "M10 Grok path-only still keys store by parent sid"
else
  bad "M10 derive rc=$RC_DER store=$(ls "$STORE" 2>/dev/null) err=$(cat "$WORK/derive.err")"
fi

# ---------------------------------------------------------------------------
# M11 — Grok h: identity: json.dumps+"\n" == jq -S -c (incl. unicode);
#        no-uuid fixture sync then --check → status=ok
# ---------------------------------------------------------------------------
UJSON='{"type":"user","content":"café 日本語 🎉"}'
JQ_OUT=$(printf '%s\n' "$UJSON" | jq -S -c .)
DUMPS_NL=$(UJSON="$UJSON" python3 - <<'PY'
import json, os
obj = json.loads(os.environ["UJSON"])
print(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False), end="\n")
PY
)
if [ "$JQ_OUT" = "$DUMPS_NL" ]; then
  pass "M11 json.dumps+NL byte-identical to jq -S -c (unicode)"
else
  bad "M11 dumps vs jq mismatch jq=$(printf '%s' "$JQ_OUT" | od -An -tx1) dumps=$(printf '%s' "$DUMPS_NL" | od -An -tx1)"
fi

LINE_HASH=$(printf '%s\n' "$UJSON" | jq -S -c . | sha256sum | awk '{print $1}')
PY_HASH=$(UJSON="$UJSON" SYNC_PY="$HERE/transcript-sync.py" python3 - <<'PY'
import importlib.util, os, sys
path = os.environ["SYNC_PY"]
spec = importlib.util.spec_from_file_location("tsync", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
ident = mod.record_ident(os.environ["UJSON"])
print(ident[2:] if ident.startswith("h:") else ident, end="")
PY
)
if [ "$LINE_HASH" = "$PY_HASH" ]; then
  pass "M11 record_ident matches jq -S -c|sha256sum (unicode)"
else
  bad "M11 ident hash jq=$LINE_HASH py=$PY_HASH"
fi

SID_NU="sess-220-nouuid"
mkdir -p "$BUCKET/$SID_NU"
write_grok_nouuid "$BUCKET/$SID_NU/chat_history.jsonl"
set +e
"$SYNC" --transcript "$BUCKET/$SID_NU/chat_history.jsonl" --sid "$SID_NU" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/nouuid.err"
RC_NU=$?
CHK_NU="$("$SYNC" --check --sid "$SID_NU" --transcript "$BUCKET/$SID_NU/chat_history.jsonl" --cwd "$PROJ_ABS" 2>"$WORK/nouuid-chk.err")"
RC_NUC=$?
set -e
CUR_ID=""
if [ -f "$STORE/$SID_NU/cursor" ]; then
  IFS=$'\t' read -r CUR_ID _ < "$STORE/$SID_NU/cursor" || true
fi
if [ "$RC_NU" -eq 0 ] && [ "$RC_NUC" -eq 0 ] \
   && printf '%s\n' "$CHK_NU" | grep -q "status=ok" \
   && printf '%s\n' "$CUR_ID" | grep -q '^h:'; then
  pass "M11 Grok no-uuid sync then --check status=ok"
else
  bad "M11 nouuid rc=$RC_NU chk_rc=$RC_NUC out=${CHK_NU:-<empty>} cursor=$CUR_ID err=$(cat "$WORK/nouuid.err") chkerr=$(cat "$WORK/nouuid-chk.err")"
fi

# ---------------------------------------------------------------------------
# M10 — no-args + settings fixture locates never-mirrored cwd session
# ---------------------------------------------------------------------------
SID_CWD="sess-220-cwd"
mkdir -p "$BUCKET/$SID_CWD"
write_mini "$BUCKET/$SID_CWD/chat_history.jsonl"
touch -d '90 seconds ago' "$BUCKET/$SID_CWD/chat_history.jsonl"
cat >"$PROJ/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
# Isolate store so no-args does not just refresh earlier sids.
STORE2="$WORK/store2"
mkdir -p "$STORE2"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE2" "$SYNC" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/noargs.err"
RC_NA=$?
set -e
if [ "$RC_NA" -eq 0 ] && [ -f "$STORE2/$SID_CWD/main.md" ]; then
  pass "M10 no-args registered locates never-mirrored cwd session"
else
  bad "M10 no-args rc=$RC_NA store2=$(ls "$STORE2" 2>/dev/null) err=$(cat "$WORK/noargs.err")"
fi

# Unregistered cwd must not create never-mirrored sid (only refresh existing).
cat >"$PROJ/.claude/settings.json" <<'EOF'
{ "hooks": {} }
EOF
SID_UNREG="sess-220-unreg"
mkdir -p "$BUCKET/$SID_UNREG"
write_mini "$BUCKET/$SID_UNREG/chat_history.jsonl"
STORE3="$WORK/store3"
mkdir -p "$STORE3"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE3" "$SYNC" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/unreg.err"
RC_UN=$?
set -e
if [ "$RC_UN" -eq 0 ] && [ ! -e "$STORE3/$SID_UNREG" ]; then
  pass "M10 no-args unregistered does not create cwd session"
else
  bad "M10 unreg rc=$RC_UN store3=$(ls -la "$STORE3" 2>/dev/null) err=$(cat "$WORK/unreg.err")"
fi

# settings.local.json also counts as registered
SID_LOCAL="sess-220-local"
mkdir -p "$BUCKET/$SID_LOCAL"
write_mini "$BUCKET/$SID_LOCAL/chat_history.jsonl"
touch -d '70 seconds ago' "$BUCKET/$SID_LOCAL/chat_history.jsonl"
rm -f "$PROJ/.claude/settings.json"
cat >"$PROJ/.claude/settings.local.json" <<'EOF'
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "bash .claude/hooks/transcript-mirror.sh" }
        ]
      }
    ]
  }
}
EOF
STORE4="$WORK/store4"
mkdir -p "$STORE4"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE4" "$SYNC" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/local.err"
RC_LO=$?
set -e
if [ "$RC_LO" -eq 0 ] && [ -f "$STORE4/$SID_LOCAL/main.md" ]; then
  pass "M10 settings.local.json registers cwd locate"
else
  bad "M10 local rc=$RC_LO store4=$(ls "$STORE4" 2>/dev/null) err=$(cat "$WORK/local.err")"
fi

# Fail-open: always exit 0 even on missing file
set +e
"$SYNC" --sid no-such --transcript "$WORK/does-not-exist.jsonl" --cwd "$PROJ_ABS" >/dev/null 2>"$WORK/missfile.err"
RC_MF=$?
set -e
if [ "$RC_MF" -eq 0 ]; then
  pass "M10 missing transcript still exit 0"
else
  bad "M10 missing-file rc=$RC_MF err=$(cat "$WORK/missfile.err")"
fi

# ---------------------------------------------------------------------------
# CDT-221 T1 — all-cwd targeting (M10 AC1/AC13, M11 AC8/AC10/AC11)
# Isolated --cwd so leftover sess-220-* Grok files cannot become newest.
# ---------------------------------------------------------------------------
PROJ221="$WORK/proj221"
mkdir -p "$PROJ221/.claude/hooks"
PROJ221_ABS="$(cd "$PROJ221" && pwd)"
ENC221="$(urlenc_cwd "$PROJ221")"
BUCKET221="$SESS/$ENC221"
CLAUDE221="$(claude_pdir "$PROJ221")"
write_opt_in "$PROJ221"

reset_221() {
  rm -rf "$BUCKET221" "$CLAUDE221"
  mkdir -p "$BUCKET221" "$CLAUDE221"
}

# AC1 Grok two-sid: older never-mirrored + newer already has store dir.
reset_221
SID_G_OLD="tm-221-g-old"
SID_G_NEW="tm-221-g-new"
mkdir -p "$BUCKET221/$SID_G_OLD" "$BUCKET221/$SID_G_NEW"
write_mini "$BUCKET221/$SID_G_OLD/chat_history.jsonl"
write_mini "$BUCKET221/$SID_G_NEW/chat_history.jsonl"
touch -d '3 minutes ago' "$BUCKET221/$SID_G_OLD/chat_history.jsonl"
touch -d '2 minutes ago' "$BUCKET221/$SID_G_NEW/chat_history.jsonl"
STORE_G2="$WORK/store-ac1-grok"
mkdir -p "$STORE_G2"
seed_store "$STORE_G2" "$SID_G_NEW"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE_G2" "$SYNC" --cwd "$PROJ221_ABS" >/dev/null 2>"$WORK/ac1-grok.err"
RC_G2=$?
set -e
if [ "$RC_G2" -eq 0 ] && [ -f "$STORE_G2/$SID_G_OLD/main.md" ]; then
  pass "M10 AC1 Grok two-sid no-args creates older sid"
else
  bad "M10 AC1 Grok two-sid rc=$RC_G2 store=$(ls "$STORE_G2" 2>/dev/null) err=$(cat "$WORK/ac1-grok.err")"
fi

# AC1 Claude two-jsonl: older never-mirrored + newer already has store dir.
reset_221
SID_C_OLD="tm-221-c-old"
SID_C_NEW="tm-221-c-new"
write_mini "$CLAUDE221/$SID_C_OLD.jsonl"
write_mini "$CLAUDE221/$SID_C_NEW.jsonl"
touch -d '3 minutes ago' "$CLAUDE221/$SID_C_OLD.jsonl"
touch -d '2 minutes ago' "$CLAUDE221/$SID_C_NEW.jsonl"
STORE_C2="$WORK/store-ac1-claude"
mkdir -p "$STORE_C2"
seed_store "$STORE_C2" "$SID_C_NEW"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE_C2" "$SYNC" --cwd "$PROJ221_ABS" >/dev/null 2>"$WORK/ac1-claude.err"
RC_C2=$?
set -e
if [ "$RC_C2" -eq 0 ] && [ -f "$STORE_C2/$SID_C_OLD/main.md" ]; then
  pass "M10 AC1 Claude two-jsonl no-args creates older sid"
else
  bad "M10 AC1 Claude two-jsonl rc=$RC_C2 store=$(ls "$STORE_C2" 2>/dev/null) err=$(cat "$WORK/ac1-claude.err")"
fi

# AC13 dual-host: one Claude *.jsonl + one Grok chat_history.jsonl.
reset_221
SID_D_C="tm-221-d-claude"
SID_D_G="tm-221-d-grok"
write_mini "$CLAUDE221/$SID_D_C.jsonl"
mkdir -p "$BUCKET221/$SID_D_G"
write_mini "$BUCKET221/$SID_D_G/chat_history.jsonl"
STORE_D="$WORK/store-ac13"
mkdir -p "$STORE_D"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE_D" "$SYNC" --cwd "$PROJ221_ABS" >/dev/null 2>"$WORK/ac13.err"
RC_D=$?
set -e
if [ "$RC_D" -eq 0 ] && [ -f "$STORE_D/$SID_D_C/main.md" ] && [ -f "$STORE_D/$SID_D_G/main.md" ]; then
  pass "M10 AC13 dual-host no-args creates both sids"
else
  bad "M10 AC13 dual-host rc=$RC_D store=$(ls "$STORE_D" 2>/dev/null) err=$(cat "$WORK/ac13.err")"
fi

# --check lists ALL cwd-bucket sids (not newest only).
reset_221
SID_CHK_A="tm-221-chk-a"
SID_CHK_B="tm-221-chk-b"
mkdir -p "$BUCKET221/$SID_CHK_A" "$BUCKET221/$SID_CHK_B"
write_mini "$BUCKET221/$SID_CHK_A/chat_history.jsonl"
write_mini "$BUCKET221/$SID_CHK_B/chat_history.jsonl"
touch -d '3 minutes ago' "$BUCKET221/$SID_CHK_A/chat_history.jsonl"
touch -d '2 minutes ago' "$BUCKET221/$SID_CHK_B/chat_history.jsonl"
STORE_CHK="$WORK/store-chk-all"
mkdir -p "$STORE_CHK"
set +e
CHK_ALL="$(TRANSCRIPT_MIRROR_ROOT="$STORE_CHK" "$SYNC" --check --cwd "$PROJ221_ABS" 2>"$WORK/chk-all.err")"
RC_CA=$?
set -e
N_CA=$(printf '%s\n' "$CHK_ALL" | grep -c '^sid=' || true)
if [ "$RC_CA" -eq 0 ] && [ "$N_CA" -eq 2 ] \
   && printf '%s\n' "$CHK_ALL" | grep -q "sid=$SID_CHK_A" \
   && printf '%s\n' "$CHK_ALL" | grep -q "sid=$SID_CHK_B"; then
  pass "M11 --check lists ALL cwd-bucket sids"
else
  bad "M11 --check-all rc=$RC_CA n=$N_CA out=${CHK_ALL:-<empty>} err=$(cat "$WORK/chk-all.err")"
fi

# AC11 --check scope: store sid whose source is another cwd MUST NOT print.
reset_221
OTHER="$WORK/other-proj"
mkdir -p "$OTHER/.claude"
OTHER_ABS="$(cd "$OTHER" && pwd)"
ENC_O="$(urlenc_cwd "$OTHER")"
BUCKET_O="$SESS/$ENC_O"
SID_OTHER="tm-221-other"
mkdir -p "$BUCKET_O/$SID_OTHER"
write_mini "$BUCKET_O/$SID_OTHER/chat_history.jsonl"
STORE_SC="$WORK/store-ac11"
mkdir -p "$STORE_SC"
set +e
TRANSCRIPT_MIRROR_ROOT="$STORE_SC" "$SYNC" --sid "$SID_OTHER" \
  --transcript "$BUCKET_O/$SID_OTHER/chat_history.jsonl" --cwd "$OTHER_ABS" \
  >/dev/null 2>"$WORK/ac11-seed.err"
RC_SC_SEED=$?
CHK_SC="$(TRANSCRIPT_MIRROR_ROOT="$STORE_SC" "$SYNC" --check --cwd "$PROJ221_ABS" 2>"$WORK/ac11.err")"
RC_SC=$?
set -e
if [ "$RC_SC_SEED" -eq 0 ] && [ -f "$STORE_SC/$SID_OTHER/main.md" ] \
   && [ "$RC_SC" -eq 0 ] && ! printf '%s\n' "$CHK_SC" | grep -q "sid=$SID_OTHER"; then
  pass "M11 AC11 --check does not list other-cwd store sid"
else
  bad "M11 AC11 rc=$RC_SC seed_rc=$RC_SC_SEED out=${CHK_SC:-<empty>} err=$(cat "$WORK/ac11.err") seederr=$(cat "$WORK/ac11-seed.err")"
fi

# AC8: no sid dir, no .errors.log → --check status=missing, exit 0.
reset_221
SID_MISS8="tm-221-miss"
mkdir -p "$BUCKET221/$SID_MISS8"
write_mini "$BUCKET221/$SID_MISS8/chat_history.jsonl"
STORE_M8="$WORK/store-ac8"
mkdir -p "$STORE_M8"
set +e
CHK_M8="$(TRANSCRIPT_MIRROR_ROOT="$STORE_M8" "$SYNC" --check --cwd "$PROJ221_ABS" 2>"$WORK/ac8.err")"
RC_M8=$?
set -e
if [ "$RC_M8" -eq 0 ] \
   && [ ! -e "$STORE_M8/.errors.log" ] \
   && [ ! -e "$STORE_M8/$SID_MISS8" ] \
   && printf '%s\n' "$CHK_M8" | grep -q "sid=$SID_MISS8 status=missing"; then
  pass "M11 AC8 --check missing without errors.log"
else
  bad "M11 AC8 rc=$RC_M8 out=${CHK_M8:-<empty>} errors.log=$(ls "$STORE_M8/.errors.log" 2>/dev/null || echo none) err=$(cat "$WORK/ac8.err")"
fi

# AC10: touch source (freshness 9) → --check in-progress; write no-args no sid dir.
reset_221
SID_PROG="tm-221-prog"
mkdir -p "$BUCKET221/$SID_PROG"
write_mini "$BUCKET221/$SID_PROG/chat_history.jsonl"
touch "$BUCKET221/$SID_PROG/chat_history.jsonl"
STORE_P="$WORK/store-ac10"
mkdir -p "$STORE_P"
set +e
CHK_P="$(TRANSCRIPT_MIRROR_ROOT="$STORE_P" "$SYNC" --check --cwd "$PROJ221_ABS" 2>"$WORK/ac10-chk.err")"
RC_PCHK=$?
TRANSCRIPT_MIRROR_ROOT="$STORE_P" "$SYNC" --cwd "$PROJ221_ABS" >/dev/null 2>"$WORK/ac10-write.err"
RC_PWR=$?
set -e
if [ "$RC_PCHK" -eq 0 ] && [ "$RC_PWR" -eq 0 ] \
   && printf '%s\n' "$CHK_P" | grep -q "sid=$SID_PROG status=in-progress" \
   && [ ! -e "$STORE_P/$SID_PROG" ]; then
  pass "M11 AC10 --check in-progress; write skips sid dir"
else
  bad "M11 AC10 chk_rc=$RC_PCHK wr_rc=$RC_PWR out=${CHK_P:-<empty>} store=$(ls "$STORE_P" 2>/dev/null) chkerr=$(cat "$WORK/ac10-chk.err") wrerr=$(cat "$WORK/ac10-write.err")"
fi

# ---------------------------------------------------------------------------
# CDT-218 T3 — M5a AC5: opted-in --check enumerates long-cwd via grok_cwd_bucket
# Shared fixture under $SESS (not ~/.grok/sessions). Prefer --check first so
# doctor lag can map stdout (no doctor code change).
# ---------------------------------------------------------------------------
PAD="$(printf 'a%.0s' {1..230})"
LONG_CWD="$WORK/p/$PAD"
mkdir -p "$LONG_CWD"
LONG_CWD="$(cd "$LONG_CWD" && pwd)"
LONG_ENC="$(jq -rn --arg s "$LONG_CWD" '$s|@uri')"
write_opt_in "$LONG_CWD"

SID_L="tm-218-long"
SRC_L="$SESS/short-bucket/$SID_L/chat_history.jsonl"
mkdir -p "$SESS/short-bucket/$SID_L"
printf '%s\n' "$LONG_CWD" >"$SESS/short-bucket/.cwd"
cat >"$SRC_L" <<'EOF'
{"type": "user", "content": [{"type": "text", "text": "cdt-218-long-cwd-sync-unique"}]}
{"type": "assistant", "content": "cdt-218-long-cwd-ack"}
EOF
age "$SRC_L"

DECOY_CWD="$WORK/decoy-218"
mkdir -p "$DECOY_CWD"
DECOY_CWD="$(cd "$DECOY_CWD" && pwd)"
SID_DECOY="tm-218-decoy"
mkdir -p "$SESS/decoy-bucket/$SID_DECOY"
printf '%s\n' "$DECOY_CWD" >"$SESS/decoy-bucket/.cwd"
write_mini "$SESS/decoy-bucket/$SID_DECOY/chat_history.jsonl"

if [ "${#LONG_ENC}" -gt 255 ] && [ ! -e "$SESS/$LONG_ENC" ]; then
  pass "M5a AC5 long-cwd @uri ${#LONG_ENC} >255; no urlencode-named dir"
else
  bad "M5a AC5 encode len=${#LONG_ENC} urlencode_dir=$( [ -e "$SESS/$LONG_ENC" ] && echo yes || echo no )"
fi

STORE_L="$WORK/store-cdt218-long"
mkdir -p "$STORE_L"
set +e
CHK_L="$(TRANSCRIPT_MIRROR_ROOT="$STORE_L" "$SYNC" --check --cwd "$LONG_CWD" 2>"$WORK/cdt218-chk.err")"
RC_L=$?
set -e
WANT_MISS="sid=$SID_L status=missing source=$SRC_L"
WANT_OK="sid=$SID_L status=ok source=$SRC_L"
if [ "$RC_L" -eq 0 ] \
   && { printf '%s\n' "$CHK_L" | grep -qxF "$WANT_MISS" || printf '%s\n' "$CHK_L" | grep -qxF "$WANT_OK"; } \
   && ! printf '%s\n' "$CHK_L" | grep -q "sid=$SID_DECOY"; then
  pass "M5a AC5 --check long-cwd sid source=.cwd jsonl"
else
  bad "M5a AC5 --check rc=$RC_L out=${CHK_L:-<empty>} err=$(cat "$WORK/cdt218-chk.err")"
fi

if grep -q 'grok_cwd_bucket(' "$HERE/transcript-sync.py" \
   && ! grep -qE '_cwd_marker_text|_grok_marker_buckets' "$HERE/transcript-sync.py"; then
  pass "M5a AC5 enumerate via grok_cwd_bucket (no second engine)"
else
  bad "M5a AC5 transcript-sync.py must call grok_cwd_bucket; must not reimplement .cwd scan"
fi

# ---------------------------------------------------------------------------
# M2 — operator ~/.claude/transcript/ untouched
# ---------------------------------------------------------------------------
AFTER_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
if [ "$BEFORE_OP" = "$AFTER_OP" ]; then
  pass "M2 operator ~/.claude/transcript/ untouched"
else
  bad "M2 operator store changed"
  printf 'BEFORE\n%s\nAFTER\n%s\n' "$BEFORE_OP" "$AFTER_OP" >&2
fi
if [ -d "$FAKE_HOME/.claude/transcript" ]; then
  bad "M2 wrote fake HOME transcript (ROOT override ignored?)"
else
  pass "M2 no default-root write under fake HOME"
fi

# bash -n
set +e
bash -n "$SYNC"
RC_N=$?
set -e
if [ "$RC_N" -eq 0 ]; then
  pass "bash -n transcript-sync.sh"
else
  bad "bash -n transcript-sync.sh rc=$RC_N"
fi

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
