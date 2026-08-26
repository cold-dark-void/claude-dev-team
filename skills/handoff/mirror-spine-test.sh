#!/usr/bin/env bash
# mirror-spine-test.sh — SPEC-018 M3f / Test 40 (CDT-216 T1).
# Run: bash skills/handoff/mirror-spine-test.sh
# Consume asserts (T1.4/T1.7/T1.8) are RED until T2 prepass M3f.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PREPASS="$HERE/prepass.sh"
ADAPTER="$HERE/grok-to-claude-jsonl.py"
SYNC="$HERE/../transcript-mirror/transcript-sync.sh"
FIX="$HERE/fixtures/mirror-spine"
DELTA="$HERE/fixtures/delta-two-stage.jsonl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mirror-spine-test.XXXXXX")
REAL_HOME="${HOME}"
OP_STORE="$REAL_HOME/.claude/transcript"
BEFORE_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
STORE="$WORK/store"
SESS="$WORK/sessions"
TMP="$WORK/tmp"
HANDOFF="$WORK/handoff"
mkdir -p "$FAKE_HOME" "$STORE" "$SESS" "$TMP" "$HANDOFF"

export HOME="$FAKE_HOME"
export TRANSCRIPT_MIRROR_ROOT="$STORE"
export CLAUDE_PROJECTS_DIR="$FAKE_HOME/.claude/projects"
export GROK_SESSIONS_DIR="$SESS"
export TMPDIR="$TMP"
export HANDOFF_DIR="$HANDOFF"
unset HANDOFF_FULL GROK_TRANSCRIPT_PATH CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID || true
mkdir -p "$CLAUDE_PROJECTS_DIR"

CWD=$(pwd)
ENC_CLAUDE=${CWD//\//-}
ENC_GROK=$(python3 -c 'import os,urllib.parse,sys; print(urllib.parse.quote(os.path.abspath(sys.argv[1]), safe=""))' "$CWD")

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

last_uuid() {
  python3 -c 'import json,sys
leaf=""
for line in open(sys.argv[1], encoding="utf-8"):
    line=line.strip()
    if not line: continue
    o=json.loads(line)
    u=o.get("uuid")
    if isinstance(u,str) and u: leaf=u
print(leaf)' "$1"
}

json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$1" "$2"; }

spine_path() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("spine") or "")' "$1"; }

has_key() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
keys=sys.argv[2].split(".")
cur=d
for k in keys:
    if not isinstance(cur,dict) or k not in cur:
        print("no"); raise SystemExit
    cur=cur[k]
print("yes")' "$1" "$2"
}

tr_copy() {
  local sid src dest
  sid="$1"
  src="$2"
  dest="$WORK/tr/${sid}.jsonl"
  mkdir -p "$WORK/tr"
  cp "$src" "$dest"
  printf '%s\n' "$dest"
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
  mkdir -p "$STORE/$sid/tool_result" "$STORE/$sid/agents/w"
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

run_prep() {
  local sid="$1" tr="$2" out="$3"
  shift 3
  bash "$PREPASS" prepare --uuid "$sid" --transcript "$tr" \
    --allow-in-progress --out "$out" "$@" >"$WORK/prep.out" 2>"$WORK/prep.err"
}

assert_no_origin() {
  local plan="$1" tag="$2"
  if [ "$(has_key "$plan" "spine_origin")" = "no" ]; then ok
  else bad "$tag spine_origin present: $(json_get "$plan" spine_origin)"; fi
  if [ "$(has_key "$plan" "stats.mirror_sid")" = "no" ]; then ok
  else bad "$tag stats.mirror_sid present"; fi
}

# ---- T1.2 fixtures present ----
for f in plain.jsonl plain-main.md fork-child.jsonl fork-child-main.md grok-chat.jsonl; do
  if [ -f "$FIX/$f" ]; then ok
  else bad "T1.2 missing fixture $FIX/$f"; fi
done
if grep -qF 'M3F-PLAIN-USER' "$FIX/plain.jsonl" && grep -qF 'M3F-PLAIN-USER' "$FIX/plain-main.md"; then ok
else bad "T1.2 plain meaning-channel marker"; fi
if grep -qF 'M3F-PREFIX-FACT' "$FIX/fork-child.jsonl" && ! grep -qF 'M3F-PREFIX-FACT' "$FIX/fork-child-main.md"; then ok
else bad "T1.2 fork suffix-only must omit prefix fact"; fi
if grep -q '> @tool_result/L000001.txt' "$FIX/plain-main.md" \
   && grep -q '> @agents/w/main.md' "$FIX/plain-main.md" \
   && grep -q '# transcript mirror' "$FIX/plain-main.md"; then ok
else bad "T1.2 plain-main.md missing title/@refs"; fi
if [ -f "$DELTA" ]; then ok; else bad "T1.2 missing $DELTA"; fi

PLAIN_TIP=$(last_uuid "$FIX/plain.jsonl")
FORK_TIP=$(last_uuid "$FIX/fork-child.jsonl")
if [ "$PLAIN_TIP" = "m3f-plain-tip" ]; then ok; else bad "T1.2 plain tip $PLAIN_TIP"; fi

# ---- T1.3 identity: empty store → JSONL-only; no spine_origin ----
SID_ID="00000000-0000-4000-8000-m3fid"
TR_ID=$(tr_copy "$SID_ID" "$FIX/plain.jsonl")
PLAN_ID="$WORK/id.json"
PLAN_ID2="$WORK/id2.json"
if run_prep "$SID_ID" "$TR_ID" "$PLAN_ID"; then ok
else bad "T1.3 prepare failed rc=$? err=$(head -c 240 "$WORK/prep.err")"; fi
if run_prep "$SID_ID" "$TR_ID" "$PLAN_ID2"; then ok
else bad "T1.3 second prepare failed"; fi
SP_ID=$(spine_path "$PLAN_ID")
SP_ID2=$(spine_path "$PLAN_ID2")
if [ -n "$SP_ID" ] && [ -f "$SP_ID" ] && [ -f "$SP_ID2" ]; then
  SHA_ID=$(sha_file "$SP_ID")
  SHA_ID2=$(sha_file "$SP_ID2")
  if [ "$SHA_ID" = "$SHA_ID2" ]; then ok
  else bad "T1.3 spine sha mismatch $SHA_ID vs $SHA_ID2"; fi
else
  bad "T1.3 missing spine path"
  SHA_ID=""
fi
if [ -f "$PLAN_ID" ]; then
  assert_no_origin "$PLAN_ID" "T1.3"
  LEAF_ID=$(json_get "$PLAN_ID" leaf_uuid)
  if [ "$LEAF_ID" = "$PLAIN_TIP" ]; then ok
  else bad "T1.3 leaf_uuid=$LEAF_ID want $PLAIN_TIP"; fi
  if grep -qF 'M3F-PLAIN-USER' "$SP_ID"; then ok
  else bad "T1.3 JSONL spine missing M3F-PLAIN-USER"; fi
fi

# ---- T1.4 hit plant: --check ok then consume (RED until T2) ----
SID_HIT="00000000-0000-4000-8000-m3fhit"
TR_HIT=$(tr_copy "$SID_HIT" "$FIX/plain.jsonl")
LOC_HIT=$(plant_hit "$SID_HIT" "$FIX/plain.jsonl" "$FIX/plain-main.md")
printf '%s\n' 'M3F-SIDECAR-TOOL-BODY must not leak' >"$STORE/$SID_HIT/tool_result/L000001.txt"
printf '%s\n' 'M3F-NEST-BODY must not leak' >"$STORE/$SID_HIT/agents/w/main.md"
CHK_HIT=$(check_sid "$SID_HIT")
if printf '%s\n' "$CHK_HIT" | grep -q "sid=$SID_HIT status=ok"; then ok
else bad "T1.4 --check not ok: out=${CHK_HIT:-<empty>} err=$(head -c 200 "$WORK/chk.err")"; fi

PLAN_HIT="$WORK/hit.json"
if run_prep "$SID_HIT" "$TR_HIT" "$PLAN_HIT"; then ok
else bad "T1.4 prepare failed rc=$? err=$(head -c 240 "$WORK/prep.err")"; fi
SP_HIT=""
if [ -f "$PLAN_HIT" ]; then
  LEAF_HIT=$(json_get "$PLAN_HIT" leaf_uuid)
  if [ "$LEAF_HIT" = "$PLAIN_TIP" ]; then ok
  else bad "T1.4 leaf_uuid=$LEAF_HIT want JSONL tip $PLAIN_TIP"; fi
  ORIGIN=$(json_get "$PLAN_HIT" spine_origin)
  if [ "$ORIGIN" = "mirror" ]; then ok
  else bad "T1.4 consume spine_origin=$ORIGIN want mirror"; fi
  MSID=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("stats") or {}).get("mirror_sid") or "")' "$PLAN_HIT")
  if [ "$MSID" = "$SID_HIT" ]; then ok
  else bad "T1.4 consume stats.mirror_sid=$MSID want $SID_HIT"; fi
  SP_HIT=$(spine_path "$PLAN_HIT")
fi
if [ -n "$SP_HIT" ] && [ -f "$SP_HIT" ]; then
  if grep -qF 'M3F-PLAIN-USER' "$SP_HIT"; then ok
  else bad "T1.4 spine missing M3F-PLAIN-USER"; fi
  if grep -qE '^## user' "$SP_HIT" && grep -qE '^## assistant' "$SP_HIT"; then ok
  else bad "T1.4 consume spine missing ## user/## assistant (mirror markdown)"; fi
  if grep -qE '^>[[:space:]]*@' "$SP_HIT"; then bad "T1.4 spine has > @ ref lines"
  else ok; fi
  if grep -qF 'M3F-SIDECAR-TOOL-BODY' "$SP_HIT" || grep -qF 'M3F-NEST-BODY' "$SP_HIT"; then
    bad "T1.4 spine leaked sidecar/nest body"
  else ok; fi
  if grep -q '# transcript mirror' "$SP_HIT"; then bad "T1.4 spine still has # transcript mirror"
  else ok; fi
else
  bad "T1.4 missing hit spine"
fi

# ---- T1.5 force JSONL: applied --since-leaf + HANDOFF_FULL=1 ----
SID_D="00000000-0000-4000-8000-m3fdelta"
TR_D=$(tr_copy "$SID_D" "$DELTA")
MAIN_D="$WORK/delta-main.md"
cat >"$MAIN_D" <<'EOF'
# transcript mirror

## user

M3F-MIRROR-WOULD-HIT full session from main.md
EOF
plant_hit "$SID_D" "$DELTA" "$MAIN_D" >/dev/null
CHK_D=$(check_sid "$SID_D")
if printf '%s\n' "$CHK_D" | grep -q "sid=$SID_D status=ok"; then ok
else bad "T1.5 --check not ok: ${CHK_D:-<empty>}"; fi
PLAN_D="$WORK/delta.json"
if run_prep "$SID_D" "$TR_D" "$PLAN_D" --since-leaf delta-a4; then ok
else bad "T1.5 since-leaf prepare failed err=$(head -c 200 "$WORK/prep.err")"; fi
if [ -f "$PLAN_D" ]; then
  assert_no_origin "$PLAN_D" "T1.5 since-leaf"
  SLA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"].get("since_leaf_applied"))' "$PLAN_D")
  if [ "$SLA" = "True" ]; then ok; else bad "T1.5 since_leaf_applied=$SLA want True"; fi
  SP_D=$(spine_path "$PLAN_D")
  if [ -n "$SP_D" ] && grep -qF 'MARKER_DELTA_ONLY' "$SP_D" && ! grep -qF 'M3F-MIRROR-WOULD-HIT' "$SP_D"; then ok
  else bad "T1.5 since-leaf spine not JSONL delta"; fi
fi

SID_F="00000000-0000-4000-8000-m3ffull"
TR_F=$(tr_copy "$SID_F" "$FIX/plain.jsonl")
plant_hit "$SID_F" "$FIX/plain.jsonl" "$FIX/plain-main.md" >/dev/null
CHK_F=$(check_sid "$SID_F")
if printf '%s\n' "$CHK_F" | grep -q "sid=$SID_F status=ok"; then ok
else bad "T1.5 full --check not ok: ${CHK_F:-<empty>}"; fi
PLAN_F="$WORK/full.json"
export HANDOFF_FULL=1
if run_prep "$SID_F" "$TR_F" "$PLAN_F"; then ok
else bad "T1.5 HANDOFF_FULL prepare failed"; fi
unset HANDOFF_FULL
if [ -f "$PLAN_F" ]; then
  assert_no_origin "$PLAN_F" "T1.5 HANDOFF_FULL"
fi

# ---- T1.6 fork: suffix-only + forkedFrom → JSONL (prefix fact) ----
SID_FK="00000000-0000-4000-8000-m3ffork"
TR_FK=$(tr_copy "$SID_FK" "$FIX/fork-child.jsonl")
plant_hit "$SID_FK" "$FIX/fork-child.jsonl" "$FIX/fork-child-main.md" >/dev/null
CHK_FK=$(check_sid "$SID_FK")
if printf '%s\n' "$CHK_FK" | grep -q "sid=$SID_FK status=ok"; then ok
else bad "T1.6 --check not ok: ${CHK_FK:-<empty>}"; fi
PLAN_FK="$WORK/fork.json"
if run_prep "$SID_FK" "$TR_FK" "$PLAN_FK"; then ok
else bad "T1.6 fork prepare failed err=$(head -c 200 "$WORK/prep.err")"; fi
if [ -f "$PLAN_FK" ]; then
  assert_no_origin "$PLAN_FK" "T1.6 fork"
  LEAF_FK=$(json_get "$PLAN_FK" leaf_uuid)
  if [ "$LEAF_FK" = "$FORK_TIP" ]; then ok
  else bad "T1.6 leaf_uuid=$LEAF_FK want $FORK_TIP"; fi
  SP_FK=$(spine_path "$PLAN_FK")
  if [ -n "$SP_FK" ] && grep -qF 'M3F-PREFIX-FACT' "$SP_FK"; then ok
  else bad "T1.6 consume spine missing M3F-PREFIX-FACT (suffix-only would drop it)"; fi
fi

# meta parent: without JSONL forkedFrom
SID_PAR="00000000-0000-4000-8000-m3fpar"
TR_PAR=$(tr_copy "$SID_PAR" "$FIX/plain.jsonl")
LOC_PAR=$(plant_hit "$SID_PAR" "$FIX/plain.jsonl" "$FIX/fork-child-main.md")
printf 'parent: m3f-parent\n' >>"$STORE/$SID_PAR/meta"
CHK_PAR=$(check_sid "$SID_PAR")
if printf '%s\n' "$CHK_PAR" | grep -q "sid=$SID_PAR status=ok"; then ok
else bad "T1.6 parent --check not ok: ${CHK_PAR:-<empty>}"; fi
PLAN_PAR="$WORK/parent.json"
if run_prep "$SID_PAR" "$TR_PAR" "$PLAN_PAR"; then ok
else bad "T1.6 parent: prepare failed"; fi
if [ -f "$PLAN_PAR" ]; then
  assert_no_origin "$PLAN_PAR" "T1.6 parent"
  SP_PAR=$(spine_path "$PLAN_PAR")
  if [ -n "$SP_PAR" ] && grep -qF 'M3F-PLAIN-USER' "$SP_PAR"; then ok
  else bad "T1.6 parent: JSONL marker missing (consumed suffix-only?)"; fi
fi

# stem ≠ sid
SID_ST="00000000-0000-4000-8000-m3fstem"
mkdir -p "$WORK/tr"
cp "$FIX/plain.jsonl" "$WORK/tr/other-stem.jsonl"
plant_hit "$SID_ST" "$FIX/plain.jsonl" "$FIX/plain-main.md" >/dev/null
CHK_ST=$(check_sid "$SID_ST")
if printf '%s\n' "$CHK_ST" | grep -q "sid=$SID_ST status=ok"; then ok
else bad "T1.6 stem --check not ok: ${CHK_ST:-<empty>}"; fi
PLAN_ST="$WORK/stem.json"
if run_prep "$SID_ST" "$WORK/tr/other-stem.jsonl" "$PLAN_ST"; then ok
else bad "T1.6 stem≠sid prepare failed"; fi
if [ -f "$PLAN_ST" ]; then
  assert_no_origin "$PLAN_ST" "T1.6 stem"
fi

# ---- T1.7 nest-ref: hit spine MUST NOT contain @agents/ ----
if [ -n "$SP_HIT" ] && [ -f "$SP_HIT" ]; then
  if grep -qF '@agents/' "$SP_HIT"; then bad "T1.7 hit spine contains @agents/"
  else ok; fi
else
  bad "T1.7 no hit spine to inspect"
fi

# ---- T1.8 Grok: --check ok MAY set spine_origin; leaf = adapter <sid>-L<n> ----
SID_G="cdt216-m3f-grok"
HIST="$SESS/$ENC_GROK/$SID_G/chat_history.jsonl"
mkdir -p "$(dirname "$HIST")"
cp "$FIX/grok-chat.jsonl" "$HIST"
age "$HIST"
MAIN_G="$WORK/grok-main.md"
cat >"$MAIN_G" <<'EOF'
# transcript mirror

## user

Please investigate grok warm mirror. Marker: M3F-GROK-USER

## assistant

Understood. Working the grok warm path. Marker: M3F-GROK-ASSIST
EOF
write_store "$SID_G" "$MAIN_G" "$HIST"
ADAPTED="$WORK/tr/${SID_G}.jsonl"
mkdir -p "$WORK/tr"
if python3 "$ADAPTER" --in "$HIST" --out "$ADAPTED" --cwd "$CWD" --session-id "$SID_G" \
  2>"$WORK/adapt.err"; then ok
else bad "T1.8 adapter failed err=$(head -c 200 "$WORK/adapt.err")"; fi
G_TIP=$(last_uuid "$ADAPTED")
case "$G_TIP" in
  *-L[0-9]*) ok ;;
  *) bad "T1.8 adapter tip not <sid>-L<n>: $G_TIP" ;;
esac
CHK_G=$(check_sid "$SID_G")
if printf '%s\n' "$CHK_G" | grep -q "sid=$SID_G status=ok"; then ok
else bad "T1.8 --check not ok: ${CHK_G:-<empty>} err=$(head -c 200 "$WORK/chk.err")"; fi
PLAN_G="$WORK/grok.json"
if run_prep "$SID_G" "$ADAPTED" "$PLAN_G"; then ok
else bad "T1.8 grok prepare failed err=$(head -c 200 "$WORK/prep.err")"; fi
if [ -f "$PLAN_G" ]; then
  LEAF_G=$(json_get "$PLAN_G" leaf_uuid)
  if [ "$LEAF_G" = "$G_TIP" ]; then ok
  else bad "T1.8 leaf_uuid=$LEAF_G want adapter tip $G_TIP"; fi
  CUR_G=$(awk -F '\t' '{print $1}' "$STORE/$SID_G/cursor")
  if [ "$LEAF_G" != "$CUR_G" ]; then ok
  else bad "T1.8 leaf_uuid must not equal grok cursor ident $CUR_G"; fi
  ORIGIN_G=$(json_get "$PLAN_G" spine_origin)
  if [ "$ORIGIN_G" = "mirror" ]; then ok
  else bad "T1.8 consume spine_origin=$ORIGIN_G want mirror"; fi
  MSID_G=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("stats") or {}).get("mirror_sid") or "")' "$PLAN_G")
  if [ "$MSID_G" = "$SID_G" ]; then ok
  else bad "T1.8 consume stats.mirror_sid=$MSID_G want $SID_G"; fi
fi

# T1.8b: discover-warm mktemp handoff-grok-adapt.XXXXXX.jsonl is not stem≠sid fork.
# other-stem.jsonl (T1.6) still forces JSONL.
if [ -n "${ADAPTED:-}" ] && [ -f "$ADAPTED" ]; then
  ADAPT_TMP=$(mktemp "$TMP/handoff-grok-adapt.XXXXXX.jsonl")
  cp "$ADAPTED" "$ADAPT_TMP"
  BASE_GA=$(basename "$ADAPT_TMP")
  case "$BASE_GA" in
    handoff-grok-adapt.*.jsonl) ok ;;
    *) bad "T1.8b tempfile name $BASE_GA want handoff-grok-adapt.*.jsonl" ;;
  esac
  PLAN_GA="$WORK/grok-adapt.json"
  if run_prep "$SID_G" "$ADAPT_TMP" "$PLAN_GA"; then ok
  else bad "T1.8b grok-adapt prepare failed err=$(head -c 200 "$WORK/prep.err")"; fi
  if [ -f "$PLAN_GA" ]; then
    ORIGIN_GA=$(json_get "$PLAN_GA" spine_origin)
    if [ "$ORIGIN_GA" = "mirror" ]; then ok
    else bad "T1.8b consume spine_origin=$ORIGIN_GA want mirror (adapt tempfile not fork)"; fi
    LEAF_GA=$(json_get "$PLAN_GA" leaf_uuid)
    if [ "$LEAF_GA" = "$G_TIP" ]; then ok
    else bad "T1.8b leaf_uuid=$LEAF_GA want adapter tip $G_TIP"; fi
    case "$LEAF_GA" in
      *-L[0-9]*) ok ;;
      *) bad "T1.8b leaf_uuid not <sid>-L<n>: $LEAF_GA" ;;
    esac
    CUR_GA=$(awk -F '\t' '{print $1}' "$STORE/$SID_G/cursor")
    if [ "$LEAF_GA" != "$CUR_GA" ]; then ok
    else bad "T1.8b leaf_uuid must not equal grok cursor ident $CUR_GA"; fi
  fi
else
  bad "T1.8b skipped — adapted jsonl missing"
fi

# ---- T1.9 not-ok: lag / missing / in-progress → JSONL ----
SID_LAG="00000000-0000-4000-8000-m3flag"
TR_LAG=$(tr_copy "$SID_LAG" "$FIX/plain.jsonl")
plant_hit "$SID_LAG" "$FIX/plain.jsonl" "$FIX/plain-main.md" >/dev/null
# cursor ident ≠ last source uuid
printf 'wrong-ident\t%s\t%s\n' "$CLAUDE_PROJECTS_DIR/$ENC_CLAUDE/${SID_LAG}.jsonl" \
  "$(sha_file "$STORE/$SID_LAG/main.md")" >"$STORE/$SID_LAG/cursor"
CHK_LAG=$(check_sid "$SID_LAG")
if printf '%s\n' "$CHK_LAG" | grep -q "sid=$SID_LAG status=lag"; then ok
else bad "T1.9 lag --check want status=lag got ${CHK_LAG:-<empty>}"; fi
PLAN_LAG="$WORK/lag.json"
if run_prep "$SID_LAG" "$TR_LAG" "$PLAN_LAG"; then ok
else bad "T1.9 lag prepare failed"; fi
if [ -f "$PLAN_LAG" ]; then
  assert_no_origin "$PLAN_LAG" "T1.9 lag"
  SP_LAG=$(spine_path "$PLAN_LAG")
  if [ -n "$SP_LAG" ] && [ -n "$SHA_ID" ] && [ "$(sha_file "$SP_LAG")" = "$SHA_ID" ]; then ok
  else bad "T1.9 lag spine sha != JSONL identity"; fi
fi

SID_MISS="00000000-0000-4000-8000-m3fmiss"
TR_MISS=$(tr_copy "$SID_MISS" "$FIX/plain.jsonl")
plant_claude_src "$SID_MISS" "$FIX/plain.jsonl" >/dev/null
CHK_MISS=$(check_sid "$SID_MISS")
if printf '%s\n' "$CHK_MISS" | grep -q "sid=$SID_MISS status=missing"; then ok
else bad "T1.9 missing --check want status=missing got ${CHK_MISS:-<empty>}"; fi
PLAN_MISS="$WORK/miss.json"
if run_prep "$SID_MISS" "$TR_MISS" "$PLAN_MISS"; then ok
else bad "T1.9 missing prepare failed"; fi
if [ -f "$PLAN_MISS" ]; then
  assert_no_origin "$PLAN_MISS" "T1.9 missing"
fi

SID_IP="00000000-0000-4000-8000-m3fip"
TR_IP=$(tr_copy "$SID_IP" "$FIX/plain.jsonl")
LOC_IP=$(plant_hit "$SID_IP" "$FIX/plain.jsonl" "$FIX/plain-main.md")
touch "$LOC_IP"
CHK_IP=$(check_sid "$SID_IP")
if printf '%s\n' "$CHK_IP" | grep -q "sid=$SID_IP status=in-progress"; then ok
else bad "T1.9 in-progress --check want in-progress got ${CHK_IP:-<empty>}"; fi
PLAN_IP="$WORK/ip.json"
if run_prep "$SID_IP" "$TR_IP" "$PLAN_IP"; then ok
else bad "T1.9 in-progress prepare failed"; fi
if [ -f "$PLAN_IP" ]; then
  assert_no_origin "$PLAN_IP" "T1.9 in-progress"
fi

# ---- T1.10 empty strip: title + @refs only → JSONL fallback ----
SID_E="00000000-0000-4000-8000-m3fempty"
TR_E=$(tr_copy "$SID_E" "$FIX/plain.jsonl")
MAIN_E="$WORK/empty-main.md"
cat >"$MAIN_E" <<'EOF'
# transcript mirror

> @tool_result/L000001.txt
> @agents/w/main.md
EOF
plant_hit "$SID_E" "$FIX/plain.jsonl" "$MAIN_E" >/dev/null
CHK_E=$(check_sid "$SID_E")
if printf '%s\n' "$CHK_E" | grep -q "sid=$SID_E status=ok"; then ok
else bad "T1.10 --check not ok: ${CHK_E:-<empty>}"; fi
PLAN_E="$WORK/empty.json"
if run_prep "$SID_E" "$TR_E" "$PLAN_E"; then ok
else bad "T1.10 empty-strip prepare failed"; fi
if [ -f "$PLAN_E" ]; then
  assert_no_origin "$PLAN_E" "T1.10 empty-strip"
  SP_E=$(spine_path "$PLAN_E")
  if [ -n "$SP_E" ] && grep -qF 'M3F-PLAIN-USER' "$SP_E"; then ok
  else bad "T1.10 empty strip must JSONL-fallback (missing M3F-PLAIN-USER)"; fi
fi

# MUST NOT write operator ~/.claude/transcript/
AFTER_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
if [ "$BEFORE_OP" = "$AFTER_OP" ]; then ok
else bad "wrote operator ~/.claude/transcript/"; fi

echo "mirror-spine-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
