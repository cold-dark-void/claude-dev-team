#!/usr/bin/env bash
# transcript-mirror/test.sh — SPEC-036 M1–M11 plugin harness (CDT-220 Task 4).
# Machine-check: bash skills/transcript-mirror/test.sh
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# T2 helper remains transcript-sync-test.sh (not invoked here).
#
# Covers: AC3 unregistered no dirs; AC4 Stop/SessionEnd agent-key no-op;
# AC5 updates.jsonl sibling rewrite; AC6 idempotent + rewind; AC8 collapse +
# thinking header + empty-thinking placeholder; AC9 parent: + dedup;
# AC10 never-fired create; AC11 --check exit 0; Grok h: --check status=ok
# after sync; AC2 SessionEnd flushes payload sid only (CDT-221).
# M5a AC1–AC3 long-cwd .cwd reconstruct + AC2 decoy + AC6 lexical-min (CDT-218).
# M4a AC1–AC10 SubagentStop nest + nest-ref commute (CDT-217 T3).
# Tests MUST NOT touch operator ~/.claude/transcript/.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
REC="$HERE/transcript-mirror.sh"
SYNC="$HERE/transcript-sync.sh"
SHIM="$HERE/hook-shim.sh"
SKILL="$HERE/SKILL.md"
FIX="$HERE/fixtures"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

REAL_HOME="${HOME}"
OP_STORE="$REAL_HOME/.claude/transcript"
BEFORE_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tm-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
STORE="$WORK/store"
SESS="$WORK/sessions"
PROJ="$WORK/proj"
TMP="$WORK/tmp"
mkdir -p "$FAKE_HOME" "$SESS" "$PROJ/.claude/hooks" "$TMP"

export HOME="$FAKE_HOME"
export TRANSCRIPT_MIRROR_ROOT="$STORE"
export GROK_SESSIONS_DIR="$SESS"
export TMPDIR="$TMP"
export CLAUDE_PLUGIN_ROOT="$REPO"
unset GROK_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH TRANSCRIPT_PATH || true

age() { touch -d '2 minutes ago' "$1"; }

copy_aged() {
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  age "$2"
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

pipe_rec_root() {
  local root="$1" rc=0
  printf '%s\n' "$2" | TRANSCRIPT_MIRROR_ROOT="$root" bash "$REC" >"$WORK/rec.out" 2>"$WORK/rec.err" || rc=$?
  printf '%s' "$rc"
}

sid_tree() { find "$1" | LC_ALL=C sort; }
sid_sha() {
  find "$1" -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done
}

count_nest_ref() { grep -c -- '^> @agents/worker-1/main.md$' "$1" 2>/dev/null || true; }

walker_bad_ref() {
  local bad=0 line
  while IFS= read -r line; do
    case "$line" in
      '> @thinking/'*|'> @tool_result/'*|'> @injection/'*|'> @agents/'*) ;;
      '> @'*) bad=1 ;;
    esac
  done < "$1"
  printf '%s' "$bad"
}

assert_rc0() {
  if [ "$1" -eq 0 ]; then
    pass "$2"
  else
    fail "$2 rc=$1 err=$(cat "$WORK/rec.err" 2>/dev/null)"
  fi
}

assert_no_block() {
  if grep -q 'decision: block' "$WORK/rec.out" 2>/dev/null; then
    fail "$1 emitted decision: block"
  else
    pass "$1 no decision:block"
  fi
}

PROJ_ABS=$(cd "$PROJ" && pwd)
ENC=$(jq -rn --arg s "$PROJ_ABS" '$s|@uri')

# ---------------------------------------------------------------------------
# M1 — skill YAML + glossary
# ---------------------------------------------------------------------------
if grep -q '^name: transcript-mirror' "$SKILL" && grep -q '^description:' "$SKILL"; then
  pass "M1 SKILL YAML name+description"
else
  fail "M1 SKILL YAML missing name/description"
fi
if grep -q 'Transcript mirror' "$SKILL" && grep -q 'Meaning channel' "$SKILL" \
   && grep -q 'Channel sidecar' "$SKILL"; then
  pass "M1 SKILL glossary terms"
else
  fail "M1 SKILL missing glossary terms"
fi
if grep -qi 'STM packet\|compact seed' "$SKILL" \
   && ! grep -qiE 'main\.md.*(STM packet|compact seed)|(STM packet|compact seed).*main\.md' "$SKILL"; then
  pass "M1 SKILL does not call main.md STM/compact seed"
else
  # MUST NOT call main.md an STM packet — "not an STM packet" is allowed.
  if grep -q 'not an STM packet' "$SKILL" || grep -q 'not a compact seed' "$SKILL"; then
    pass "M1 SKILL STM/compact only as MUST NOT"
  else
    fail "M1 SKILL STM/compact wording"
  fi
fi

# bash -n (never source)
for f in "$REC" "$SYNC" "$SHIM" "$HERE/test.sh"; do
  if bash -n "$f"; then
    pass "bash -n $(basename "$f")"
  else
    fail "bash -n $(basename "$f")"
  fi
done

# Fixtures present
for f in claude-uuid.jsonl grok-chat_history.jsonl grok-updates.jsonl \
         rewind-truncate.jsonl fork-parent.jsonl fork-child.jsonl \
         settings-registered.json never-mirrored.jsonl \
         subagent-child.jsonl parent-with-task.jsonl; do
  if [ -f "$FIX/$f" ]; then
    pass "fixture $f"
  else
    fail "missing fixture $f"
  fi
done

# ---------------------------------------------------------------------------
# AC3 / M3 — unregistered (no stdin, no flags) creates no store dirs
# ---------------------------------------------------------------------------
RC=$(invoke_rec </dev/null)
assert_rc0 "$RC" "AC3 unregistered exit 0"
if [ -d "$STORE" ]; then
  fail "AC3 unregistered created store root $STORE"
else
  pass "AC3 unregistered created no store dirs"
fi
assert_no_block "AC3"

mkdir -p "$STORE"

# ---------------------------------------------------------------------------
# AC4 / M4 / M4a AC1 — Stop/SessionEnd + agent keys are v1 no-ops (no nest).
# Empty agent_id SubagentStop also creates no sid (sanitize reject).
# ---------------------------------------------------------------------------
copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/claude-uuid.jsonl"
SUB_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hook_event_name:"SubagentStop",session_id:"tm-sub",transcript_path:$p,reason:"end_turn"}')
RC=$(pipe_rec "$SUB_JSON")
assert_rc0 "$RC" "AC4 SubagentStop empty agent_id exit 0"
assert_no_block "AC4 SubagentStop empty agent_id"
if [ -e "$STORE/tm-sub" ]; then
  fail "AC4 SubagentStop empty agent_id created sid dir"
else
  pass "AC4 SubagentStop empty agent_id no sid dir"
fi

AGENT_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hookEventName:"Stop",sessionId:"tm-agent",transcriptPath:$p,reason:"end_turn",agent_id:"worker-1"}')
RC=$(pipe_rec "$AGENT_JSON")
assert_rc0 "$RC" "AC4 agent_id exit 0"
assert_no_block "AC4 agent_id"
if [ -e "$STORE/tm-agent" ]; then
  fail "AC4 agent_id created sid dir"
else
  pass "AC4 agent_id no-op (no sid dir)"
fi

AGENT_TYPE_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hook_event_name:"Stop",session_id:"tm-atype",transcript_path:$p,agentType:"explore"}')
RC=$(pipe_rec "$AGENT_TYPE_JSON")
assert_rc0 "$RC" "AC4 agentType exit 0"
assert_no_block "AC4 agentType"
if [ -e "$STORE/tm-atype" ]; then
  fail "AC4 agentType created sid dir"
else
  pass "AC4 agentType no-op"
fi

SE_AGENT_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hookEventName:"SessionEnd",sessionId:"tm-se-agent",transcriptPath:$p,reason:"end_turn",agent_id:"worker-1"}')
RC=$(pipe_rec "$SE_AGENT_JSON")
assert_rc0 "$RC" "AC1 SessionEnd+agent_id exit 0"
assert_no_block "AC1 SessionEnd+agent_id"
if [ -e "$STORE/tm-se-agent" ]; then
  fail "AC1 SessionEnd+agent_id created sid dir"
else
  pass "AC1 SessionEnd+agent_id no-op (no sid dir)"
fi

RC=$(invoke_rec --transcript "$WORK/src/claude-uuid.jsonl" --sid tm-ac4-snap)
assert_rc0 "$RC" "AC4 snapshot parent exit 0"
SNAP_TREE=$(sid_tree "$STORE/tm-ac4-snap")
SNAP_SHA=$(sid_sha "$STORE/tm-ac4-snap")
STOP_SNAP=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hook_event_name:"Stop",session_id:"tm-ac4-snap",transcript_path:$p,reason:"end_turn",agent_id:"worker-1"}')
RC=$(pipe_rec "$STOP_SNAP")
assert_rc0 "$RC" "AC4 Stop+agent_id on existing parent exit 0"
assert_no_block "AC4 Stop+agent_id snapshot"
SNAP_TREE2=$(sid_tree "$STORE/tm-ac4-snap")
SNAP_SHA2=$(sid_sha "$STORE/tm-ac4-snap")
if [ "$SNAP_TREE" = "$SNAP_TREE2" ] && [ "$SNAP_SHA" = "$SNAP_SHA2" ]; then
  pass "AC4 Stop+agent_id parent sid sha256 unchanged"
else
  fail "AC4 Stop+agent_id mutated existing parent sid dir"
fi
if [ -d "$STORE/tm-ac4-snap/agents" ]; then
  fail "AC4 Stop+agent_id created nest under existing parent"
else
  pass "AC4 Stop+agent_id no nest on existing parent"
fi

# ---------------------------------------------------------------------------
# M4 — fail-open: missing transcript logs; append fail leaves cursor
# ---------------------------------------------------------------------------
RC=$(invoke_rec --transcript "$WORK/no-such.jsonl" --sid tm-missing)
assert_rc0 "$RC" "M4 missing transcript exit 0"
if [ -e "$STORE/tm-missing" ]; then
  fail "M4 missing transcript created sid dir"
else
  pass "M4 missing transcript no sid dir"
fi
if grep -q 'no transcript' "$STORE/.errors.log" 2>/dev/null; then
  pass "M4 .errors.log line on missing transcript"
else
  fail "M4 .errors.log missing 'no transcript'"
fi
assert_no_block "M4 missing"

head -n 3 "$FIX/claude-uuid.jsonl" > "$WORK/src/append-fail.jsonl"
age "$WORK/src/append-fail.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/append-fail.jsonl" --sid tm-afail)
assert_rc0 "$RC" "M4 append-fail setup exit 0"
CUR_BEFORE=$(cat "$STORE/tm-afail/cursor" 2>/dev/null || true)
MAIN_BEFORE=$(cat "$STORE/tm-afail/main.md" 2>/dev/null || true)
chmod a-w "$STORE/tm-afail/main.md"
cp "$FIX/claude-uuid.jsonl" "$WORK/src/append-fail.jsonl"
age "$WORK/src/append-fail.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/append-fail.jsonl" --sid tm-afail)
chmod u+w "$STORE/tm-afail/main.md" 2>/dev/null || true
assert_rc0 "$RC" "M4 append-fail recorder exit 0"
CUR_AFTER=$(cat "$STORE/tm-afail/cursor" 2>/dev/null || true)
MAIN_AFTER=$(cat "$STORE/tm-afail/main.md" 2>/dev/null || true)
if [ "$CUR_BEFORE" = "$CUR_AFTER" ]; then
  pass "M4 cursor unchanged when append fails"
else
  fail "M4 cursor advanced on append fail before=${CUR_BEFORE:-<empty>} after=${CUR_AFTER:-<empty>}"
fi
if [ "$MAIN_BEFORE" = "$MAIN_AFTER" ]; then
  pass "M4 main.md unchanged when append fails"
else
  fail "M4 main.md mutated on append fail"
fi
if grep -q 'append failed' "$STORE/.errors.log" 2>/dev/null; then
  pass "M4 .errors.log append failed"
else
  fail "M4 .errors.log missing append failed"
fi

# ---------------------------------------------------------------------------
# M2 — store layout + relative @refs (claude uuid fixture)
# ---------------------------------------------------------------------------
copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/claude-uuid.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/claude-uuid.jsonl" --sid tm-claude)
assert_rc0 "$RC" "M2 claude recorder exit 0"
DIR="$STORE/tm-claude"
MAIN="$DIR/main.md"
for p in "$MAIN" "$DIR/meta" "$DIR/cursor" "$DIR/thinking" "$DIR/tool_result" "$DIR/injection"; do
  if [ -e "$p" ]; then
    pass "M2 has $(basename "$p")"
  else
    fail "M2 missing $(basename "$p")"
  fi
done
if grep -q 'hello from claude fixture' "$MAIN"; then
  pass "M2 meaning channel user text"
else
  fail "M2 missing user text in main.md"
fi
if grep -q "I'll look that up." "$MAIN" && grep -q 'done with claude fixture.' "$MAIN"; then
  pass "M2 meaning channel assistant text"
else
  fail "M2 missing assistant text"
fi
BAD_REF=$(walker_bad_ref "$MAIN")
if [ "$BAD_REF" -eq 0 ]; then
  pass "M2 @refs relative closed taxonomy (+ nest-ref)"
else
  fail "M2 unexpected @ref kind in main.md"
fi
if grep -q "$STORE\|$HOME\|$REAL_HOME" "$MAIN"; then
  fail "M2 main.md contains absolute store/home path"
else
  pass "M2 main.md has no absolute store/home path"
fi

# ---------------------------------------------------------------------------
# AC8 / M7 / M8 — collapse, thinking header, empty-thinking placeholder
# ---------------------------------------------------------------------------
if grep -q '(signature-only, no plaintext)' "$DIR/thinking/"*.txt 2>/dev/null; then
  pass "AC8 empty-thinking placeholder"
else
  fail "AC8 missing signature-only placeholder in thinking/"
fi
THINK_LINE=$(grep -n '^> @thinking/' "$MAIN" | head -1 | cut -d: -f1)
ASST_LINE=$(grep -n '^## assistant' "$MAIN" | head -1 | cut -d: -f1)
if [ -n "${THINK_LINE:-}" ] && [ -n "${ASST_LINE:-}" ] && [ "$ASST_LINE" -lt "$THINK_LINE" ]; then
  pass "AC8 @thinking only after ## assistant"
else
  fail "AC8 thinking header think=${THINK_LINE:-none} asst=${ASST_LINE:-none}"
fi
COLLAPSE_OK=1
awk '
  /^> @tool_result\// { if (tr) { print "DUP"; exit 1 } tr=1; next }
  /^[ \t]*$/ { next }
  { tr=0 }
' "$MAIN" || COLLAPSE_OK=0
if [ "$COLLAPSE_OK" -eq 1 ]; then
  pass "AC8 consecutive @tool_result collapsed"
else
  fail "AC8 consecutive @tool_result not collapsed"
fi
if [ -n "$(ls -A "$DIR/injection" 2>/dev/null)" ]; then
  pass "M7 injection/ sidecar present"
else
  fail "M7 injection/ empty"
fi
if grep -q 'hidden meta reminder\|command-name\|user_query\|Grok project' "$DIR/injection/"*.txt 2>/dev/null; then
  pass "M7 wrappers routed to injection/"
else
  fail "M7 injection sidecar missing wrapper text"
fi
if [ -n "$(ls -A "$DIR/tool_result" 2>/dev/null)" ]; then
  pass "M7 tool_use/tool_result routed to tool_result/"
else
  fail "M7 tool_result/ empty"
fi
if grep -q 'hidden meta reminder' "$MAIN"; then
  fail "M7 isMeta leaked into main.md"
else
  pass "M7 isMeta not in meaning channel"
fi

# ---------------------------------------------------------------------------
# AC6 — Claude uuid idempotent + two-tick == one-shot
# ---------------------------------------------------------------------------
copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/idemp.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/idemp.jsonl" --sid tm-idemp)
assert_rc0 "$RC" "AC6 first run exit 0"
SHA1=$(sha256sum "$STORE/tm-idemp/main.md" | awk '{print $1}')
CUR1=$(cat "$STORE/tm-idemp/cursor")
RC=$(invoke_rec --transcript "$WORK/src/idemp.jsonl" --sid tm-idemp)
assert_rc0 "$RC" "AC6 re-run exit 0"
SHA2=$(sha256sum "$STORE/tm-idemp/main.md" | awk '{print $1}')
CUR2=$(cat "$STORE/tm-idemp/cursor")
if [ "$SHA1" = "$SHA2" ]; then
  pass "AC6 re-run byte-identical main.md"
else
  fail "AC6 re-run mutated main.md"
fi
if [ "$CUR1" = "$CUR2" ]; then
  pass "AC6 re-run cursor unchanged"
else
  fail "AC6 re-run cursor changed"
fi
IDENT=$(printf '%s' "$CUR2" | cut -f1)
SRC=$(printf '%s' "$CUR2" | cut -f2)
HASH=$(printf '%s' "$CUR2" | cut -f3)
if [ "$IDENT" = "c-a2" ] && [ "$SRC" = "$WORK/src/idemp.jsonl" ] && [ -n "$HASH" ]; then
  pass "AC6 cursor uuid + source-path + main-sha"
else
  fail "AC6 cursor fields ident=$IDENT src=$SRC hash=${HASH:-empty}"
fi

# two-phase vs one-shot (same sid name, two roots)
two_tick() { # two_tick <label> <split-lines>
  local label="$1" n="$2"
  local sa="$WORK/store-a-$n" sb="$WORK/store-b-$n" src="$WORK/src/tick-$n.jsonl"
  mkdir -p "$sa" "$sb"
  head -n "$n" "$FIX/claude-uuid.jsonl" > "$src"
  age "$src"
  TRANSCRIPT_MIRROR_ROOT="$sa" bash "$REC" --transcript "$src" --sid tm-ticks >/dev/null 2>&1
  cp "$FIX/claude-uuid.jsonl" "$src"
  age "$src"
  TRANSCRIPT_MIRROR_ROOT="$sa" bash "$REC" --transcript "$src" --sid tm-ticks >/dev/null 2>&1
  copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/tick-full-$n.jsonl"
  TRANSCRIPT_MIRROR_ROOT="$sb" bash "$REC" --transcript "$WORK/src/tick-full-$n.jsonl" --sid tm-ticks >/dev/null 2>&1
  if cmp -s "$sa/tm-ticks/main.md" "$sb/tm-ticks/main.md"; then
    pass "AC6 two-tick == one-shot ($label)"
  else
    fail "AC6 two-tick diverged from one-shot ($label)"
    diff -u "$sa/tm-ticks/main.md" "$sb/tm-ticks/main.md" >&2 || true
  fi
}
two_tick "after user turn" 2
two_tick "after assistant+tool" 3

# ---------------------------------------------------------------------------
# AC5 / M5 — Grok updates.jsonl → sibling chat_history.jsonl
# ---------------------------------------------------------------------------
GROK_DIR="$WORK/grok-sess"
copy_aged "$FIX/grok-chat_history.jsonl" "$GROK_DIR/chat_history.jsonl"
copy_aged "$FIX/grok-updates.jsonl" "$GROK_DIR/updates.jsonl"
SNAKE=$(jq -nc --arg p "$GROK_DIR/updates.jsonl" \
  '{hook_event_name:"Stop",session_id:"tm-grok",transcript_path:$p,reason:"end_turn"}')
RC=$(pipe_rec "$SNAKE")
assert_rc0 "$RC" "AC5 Stop snake_case exit 0"
GMAIN="$STORE/tm-grok/main.md"
GCUR="$STORE/tm-grok/cursor"
if [ -f "$GMAIN" ] && grep -q 'hello from grok fixture' "$GMAIN"; then
  pass "AC5 meaning channel from sibling chat_history"
else
  fail "AC5 missing grok meaning channel (used updates.jsonl?)"
fi
if grep -q 'hello from grok fixture' "$GMAIN"; then
  :
fi
GSRC=$(cut -f2 "$GCUR" 2>/dev/null || true)
if [ "$GSRC" = "$GROK_DIR/chat_history.jsonl" ]; then
  pass "AC5 cursor keys resolved chat_history.jsonl"
else
  fail "AC5 cursor source=$GSRC want=$GROK_DIR/chat_history.jsonl"
fi
if grep -q 'jsonrpc\|session/update' "$GMAIN"; then
  fail "AC5 main.md contains updates.jsonl RPC"
else
  pass "AC5 main.md has no updates.jsonl RPC"
fi
if grep -q 'Grok project instructions' "$GMAIN"; then
  fail "M7 synthetic_reason leaked into main.md"
else
  pass "M7 synthetic_reason not in meaning channel"
fi
if grep -q '(encrypted reasoning, no plaintext)' "$STORE/tm-grok/thinking/"*.txt 2>/dev/null; then
  pass "M7 Grok empty reasoning placeholder"
else
  fail "M7 missing encrypted-reasoning placeholder"
fi
if grep -q '^parent:' "$STORE/tm-grok/meta" 2>/dev/null; then
  fail "M9 Grok invented parent:"
else
  pass "M9 Grok no invented parent:"
fi

# camelCase stdin (Claude path)
copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/camel.jsonl"
CAMEL=$(jq -nc --arg p "$WORK/src/camel.jsonl" \
  '{hookEventName:"Stop",sessionId:"tm-camel",transcriptPath:$p,reason:"end_turn"}')
RC=$(pipe_rec "$CAMEL")
assert_rc0 "$RC" "M5 camelCase Stop exit 0"
if grep -q 'hello from claude fixture' "$STORE/tm-camel/main.md" 2>/dev/null; then
  pass "M5 camelCase stdin parsed"
else
  fail "M5 camelCase stdin did not mirror"
fi

# Stop reason=other no-op; SessionEnd with that reason still flushes
OTHER=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hook_event_name:"Stop",session_id:"tm-other",transcript_path:$p,reason:"other"}')
RC=$(pipe_rec "$OTHER")
assert_rc0 "$RC" "M5 Stop reason=other exit 0"
if [ -e "$STORE/tm-other" ]; then
  fail "M5 Stop reason=other created sid dir"
else
  pass "M5 Stop reason=other no-op"
fi
SE=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hookEventName:"SessionEnd",sessionId:"tm-se",transcriptPath:$p,reason:"other"}')
RC=$(pipe_rec "$SE")
assert_rc0 "$RC" "M5 SessionEnd reason=other exit 0"
if grep -q 'hello from claude fixture' "$STORE/tm-se/main.md" 2>/dev/null; then
  pass "M5 SessionEnd reason=other flushes"
else
  fail "M5 SessionEnd did not flush"
fi

# AC2 / M5 — SessionEnd flushes payload sid only (CDT-221)
copy_aged "$FIX/never-mirrored.jsonl" "$WORK/src/tm-se-a.jsonl"
copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/tm-se-b.jsonl"
SEA=$(jq -nc --arg p "$WORK/src/tm-se-a.jsonl" \
  '{hook_event_name:"SessionEnd",session_id:"tm-se-a",transcript_path:$p,reason:"other"}')
RC=$(pipe_rec "$SEA")
assert_rc0 "$RC" "AC2 SessionEnd payload sid exit 0"
assert_no_block "AC2 SessionEnd"
if [ -f "$STORE/tm-se-a/main.md" ]; then
  pass "AC2 SessionEnd created tm-se-a/main.md"
else
  fail "AC2 SessionEnd did not create tm-se-a/main.md"
fi
if [ -e "$STORE/tm-se-b" ]; then
  fail "AC2 SessionEnd created tm-se-b (payload sid only)"
else
  pass "AC2 SessionEnd did not create tm-se-b"
fi

# Missing Grok reconstructed file: silent no-op
GHOST='{"hook_event_name":"Stop","session_id":"tm-ghost","cwd":"/no/such/cdt220-proj","reason":"end_turn"}'
ERR_BEFORE=$(wc -c < "$STORE/.errors.log" 2>/dev/null || echo 0)
RC=$(pipe_rec "$GHOST")
assert_rc0 "$RC" "M5 missing reconstruct exit 0"
if [ -e "$STORE/tm-ghost" ]; then
  fail "M5 missing reconstruct created sid dir"
else
  pass "M5 missing reconstruct silent no-op"
fi
ERR_AFTER=$(wc -c < "$STORE/.errors.log" 2>/dev/null || echo 0)
if [ "$ERR_BEFORE" = "$ERR_AFTER" ]; then
  pass "M5 missing reconstruct did not log"
else
  fail "M5 missing reconstruct wrote .errors.log"
fi

# ---------------------------------------------------------------------------
# AC6 — Grok rewind truncate rebuilds with no duplicate headers
# ---------------------------------------------------------------------------
copy_aged "$FIX/rewind-truncate.jsonl" "$WORK/src/rewind.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/rewind.jsonl" --sid tm-rewind)
assert_rc0 "$RC" "AC6 rewind initial exit 0"
U3=$(count 'rewind user three' "$STORE/tm-rewind/main.md")
A3=$(count 'rewind asst three' "$STORE/tm-rewind/main.md")
if [ "$U3" -eq 1 ] && [ "$A3" -eq 1 ]; then
  pass "AC6 rewind full mirror once"
else
  fail "AC6 rewind full U3=$U3 A3=$A3"
fi
head -n 2 "$FIX/rewind-truncate.jsonl" > "$WORK/src/rewind.jsonl"
age "$WORK/src/rewind.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/rewind.jsonl" --sid tm-rewind)
assert_rc0 "$RC" "AC6 rewind truncate exit 0"
U1=$(count 'rewind user one' "$STORE/tm-rewind/main.md")
A1=$(count 'rewind asst one' "$STORE/tm-rewind/main.md")
U2=$(count 'rewind user two' "$STORE/tm-rewind/main.md")
U3b=$(count 'rewind user three' "$STORE/tm-rewind/main.md")
HU=$(count '^## user' "$STORE/tm-rewind/main.md")
HA=$(count '^## assistant' "$STORE/tm-rewind/main.md")
if [ "$U1" -eq 1 ] && [ "$A1" -eq 1 ] && [ "$U2" -eq 0 ] && [ "$U3b" -eq 0 ]; then
  pass "AC6 rewind rebuild no dups / dropped tail"
else
  fail "AC6 rewind dups U1=$U1 A1=$A1 U2=$U2 U3=$U3b"
fi
if [ "$HU" -eq 1 ] && [ "$HA" -eq 1 ]; then
  pass "AC6 rewind header counts == remaining turns"
else
  fail "AC6 rewind headers user=$HU asst=$HA"
fi

# insert-before cursor identity is not line-index
head -n 2 "$FIX/rewind-truncate.jsonl" > "$WORK/src/insert.jsonl"
age "$WORK/src/insert.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/insert.jsonl" --sid tm-insert)
assert_rc0 "$RC" "AC6 insert-before setup"
{
  printf '%s\n' '{"type":"user","content":"inserted before cursor","prompt_index":0}'
  cat "$FIX/rewind-truncate.jsonl"
} > "$WORK/src/insert.jsonl"
age "$WORK/src/insert.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/insert.jsonl" --sid tm-insert)
assert_rc0 "$RC" "AC6 insert-before re-run"
IU=$(count 'rewind user one' "$STORE/tm-insert/main.md")
IA=$(count 'rewind asst one' "$STORE/tm-insert/main.md")
if [ "$IU" -eq 1 ] && [ "$IA" -eq 1 ]; then
  pass "AC6 insert-before does not duplicate mirrored text"
else
  fail "AC6 insert-before duplicated IU=$IU IA=$IA"
fi

# ---------------------------------------------------------------------------
# AC9 / M9 — parent: marker + dedup
# ---------------------------------------------------------------------------
copy_aged "$FIX/fork-parent.jsonl" "$WORK/src/fork-parent.jsonl"
copy_aged "$FIX/fork-child.jsonl" "$WORK/src/fork-child.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/fork-parent.jsonl" --sid tm-parent)
assert_rc0 "$RC" "AC9 parent mirror exit 0"
RC=$(invoke_rec --transcript "$WORK/src/fork-child.jsonl" --sid tm-child)
assert_rc0 "$RC" "AC9 child mirror exit 0"
CM="$STORE/tm-child/main.md"
if grep -q '^parent: tm-parent$' "$STORE/tm-child/meta"; then
  pass "AC9 child meta parent: tm-parent"
else
  fail "AC9 child meta missing parent: $(cat "$STORE/tm-child/meta" 2>/dev/null)"
fi
if grep -q 'child-only user turn' "$CM" && grep -q 'child-only assistant turn' "$CM"; then
  pass "AC9 child meaning channel present"
else
  fail "AC9 child missing child-only turns"
fi
if grep -q 'parent user turn' "$CM" || grep -q 'parent assistant turn' "$CM"; then
  fail "AC9 child re-copied parent-mirrored identities"
else
  pass "AC9 child skipped parent-covered identities"
fi

# parent dir missing: still write parent: and mirror full child
STORE_OR="$WORK/store-orphan"
mkdir -p "$STORE_OR"
TRANSCRIPT_MIRROR_ROOT="$STORE_OR" bash "$REC" \
  --transcript "$WORK/src/fork-child.jsonl" --sid tm-child >/dev/null 2>&1
OM="$STORE_OR/tm-child/main.md"
if grep -q '^parent: tm-parent$' "$STORE_OR/tm-child/meta"; then
  pass "AC9 missing-parent still writes parent:"
else
  fail "AC9 missing-parent meta=$(cat "$STORE_OR/tm-child/meta" 2>/dev/null)"
fi
if grep -q 'parent user turn' "$OM" && grep -q 'child-only user turn' "$OM"; then
  pass "AC9 missing-parent mirrors full child"
else
  fail "AC9 missing-parent incomplete child"
fi

# ---------------------------------------------------------------------------
# AC10 / M10 — never-fired Stop + sync --sid creates mirror
# ---------------------------------------------------------------------------
copy_aged "$FIX/never-mirrored.jsonl" "$WORK/src/never-mirrored.jsonl"
if [ -e "$STORE/tm-never" ]; then
  fail "AC10 pre-condition: tm-never already exists"
fi
RC=0
bash "$SYNC" --sid tm-never --transcript "$WORK/src/never-mirrored.jsonl" --cwd "$PROJ_ABS" \
  >"$WORK/sync-never.out" 2>"$WORK/sync-never.err" || RC=$?
if [ "$RC" -eq 0 ] && grep -q 'NEVERFIRE-220' "$STORE/tm-never/main.md" 2>/dev/null; then
  pass "AC10 --sid never-fired creates correct mirror"
else
  fail "AC10 --sid rc=$RC main=$(ls "$STORE/tm-never/main.md" 2>/dev/null || echo missing) err=$(cat "$WORK/sync-never.err")"
fi

# no-args + registered settings locates never-mirrored cwd session
SID_CWD="sess-220-cwd"
mkdir -p "$SESS/$ENC/$SID_CWD"
copy_aged "$FIX/never-mirrored.jsonl" "$SESS/$ENC/$SID_CWD/chat_history.jsonl"
cp "$FIX/settings-registered.json" "$PROJ/.claude/settings.json"
STORE_NA="$WORK/store-na"
mkdir -p "$STORE_NA"
RC=0
TRANSCRIPT_MIRROR_ROOT="$STORE_NA" bash "$SYNC" --cwd "$PROJ_ABS" \
  >"$WORK/sync-na.out" 2>"$WORK/sync-na.err" || RC=$?
if [ "$RC" -eq 0 ] && grep -q 'NEVERFIRE-220' "$STORE_NA/$SID_CWD/main.md" 2>/dev/null; then
  pass "AC10 no-args registered locates never-mirrored cwd session"
else
  fail "AC10 no-args rc=$RC store=$(ls "$STORE_NA" 2>/dev/null) err=$(cat "$WORK/sync-na.err")"
fi

# unregistered no-args must not create
printf '%s\n' '{ "hooks": {} }' > "$PROJ/.claude/settings.json"
SID_UN="sess-220-unreg"
mkdir -p "$SESS/$ENC/$SID_UN"
copy_aged "$FIX/never-mirrored.jsonl" "$SESS/$ENC/$SID_UN/chat_history.jsonl"
STORE_UN="$WORK/store-un"
mkdir -p "$STORE_UN"
RC=0
TRANSCRIPT_MIRROR_ROOT="$STORE_UN" bash "$SYNC" --cwd "$PROJ_ABS" \
  >/dev/null 2>"$WORK/sync-un.err" || RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$STORE_UN/$SID_UN" ]; then
  pass "M10 no-args unregistered does not create cwd session"
else
  fail "M10 unreg rc=$RC store=$(ls -la "$STORE_UN" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# AC11 / M11 — --check exit 0; Grok h: status=ok after sync
# ---------------------------------------------------------------------------
RC=0
CHK=$(bash "$SYNC" --check --sid tm-never --transcript "$WORK/src/never-mirrored.jsonl" --cwd "$PROJ_ABS" \
  2>"$WORK/chk.err") || RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$CHK" | grep -q "sid=tm-never"; then
  pass "AC11 --check exit 0 with lag line"
else
  fail "AC11 --check rc=$RC out=${CHK:-<empty>} err=$(cat "$WORK/chk.err")"
fi
if printf '%s\n' "$CHK" | grep -q 'status=ok'; then
  pass "AC11 --check status=ok after sync"
else
  fail "AC11 --check not ok: $CHK"
fi

# missing-mirror still exit 0
RC=0
CHK_MISS=$(bash "$SYNC" --check --sid tm-miss --transcript "$WORK/src/never-mirrored.jsonl" --cwd "$PROJ_ABS" \
  2>"$WORK/chk-miss.err") || RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$CHK_MISS" | grep -Eq 'status=(missing|lag)'; then
  pass "AC11 --check missing-mirror status"
else
  fail "AC11 missing-check rc=$RC out=${CHK_MISS:-<empty>}"
fi

# Grok h: identity — sync then --check status=ok
copy_aged "$FIX/grok-chat_history.jsonl" "$WORK/src/grok-h.jsonl"
RC=0
bash "$SYNC" --sid tm-h --transcript "$WORK/src/grok-h.jsonl" --cwd "$PROJ_ABS" \
  >/dev/null 2>"$WORK/h.err" || RC=$?
RC2=0
CHK_H=$(bash "$SYNC" --check --sid tm-h --transcript "$WORK/src/grok-h.jsonl" --cwd "$PROJ_ABS" \
  2>"$WORK/h-chk.err") || RC2=$?
HID=""
if [ -f "$STORE/tm-h/cursor" ]; then
  IFS=$'\t' read -r HID _ < "$STORE/tm-h/cursor" || true
fi
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] \
   && printf '%s\n' "$CHK_H" | grep -q 'status=ok' \
   && printf '%s\n' "$HID" | grep -q '^h:'; then
  pass "M11 Grok h: --check status=ok after sync"
else
  fail "M11 Grok h: rc=$RC chk_rc=$RC2 out=${CHK_H:-<empty>} cursor=$HID err=$(cat "$WORK/h.err")"
fi

# growth → lag
printf '%s\n' '{"type":"user","content":"second grok turn","prompt_index":2}' >> "$WORK/src/grok-h.jsonl"
age "$WORK/src/grok-h.jsonl"
RC=0
CHK_LAG=$(bash "$SYNC" --check --sid tm-h --transcript "$WORK/src/grok-h.jsonl" --cwd "$PROJ_ABS" \
  2>"$WORK/lag.err") || RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$CHK_LAG" | grep -q 'status=lag'; then
  pass "AC11 --check source growth status=lag"
else
  fail "AC11 lag rc=$RC out=${CHK_LAG:-<empty>}"
fi

# fail-open: missing file still exit 0
RC=0
bash "$SYNC" --sid no-such --transcript "$WORK/does-not-exist.jsonl" --cwd "$PROJ_ABS" \
  >/dev/null 2>"$WORK/missfile.err" || RC=$?
if [ "$RC" -eq 0 ]; then
  pass "M10 missing transcript still exit 0"
else
  fail "M10 missing-file rc=$RC"
fi

# ---------------------------------------------------------------------------
# M5a — Grok long-cwd .cwd reconstruct (CDT-218 T4)
# GROK_SESSIONS_DIR + TRANSCRIPT_MIRROR_ROOT only. ASCII abs paths.
# ---------------------------------------------------------------------------
seed_grok_unique() {
  mkdir -p "$(dirname "$1")"
  cp "$FIX/grok-chat_history.jsonl" "$1"
  printf '%s\n' "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$2\"}],\"prompt_index\":99}" >> "$1"
  age "$1"
}

PAD="$(printf 'a%.0s' {1..240})"
LONG_CWD="$WORK/p/$PAD"
mkdir -p "$LONG_CWD"
LONG_CWD="$(cd "$LONG_CWD" && pwd)"
LONG_ENC="$(jq -rn --arg s "$LONG_CWD" '$s|@uri')"
if [ "${#LONG_ENC}" -gt 255 ]; then
  pass "M5a AC1 cwd jq @uri length ${#LONG_ENC} >255"
else
  fail "M5a AC1 cwd jq @uri length ${#LONG_ENC} (want >255)"
fi
if [ -e "$SESS/$LONG_ENC" ]; then
  fail "M5a AC1 urlencode-named dir exists (must not)"
else
  pass "M5a AC1 no urlencode-named dir"
fi

mkdir -p "$SESS/short-bucket/tm-long" "$SESS/short-bucket/tm-long-se"
printf '%s\n' "$LONG_CWD" > "$SESS/short-bucket/.cwd"
seed_grok_unique "$SESS/short-bucket/tm-long/chat_history.jsonl" "CDT-218-T4-AC1-LONG-CWD"
seed_grok_unique "$SESS/short-bucket/tm-long-se/chat_history.jsonl" "CDT-218-T4-AC1-SESSIONEND"

DECOY_CWD="$WORK/decoy-project"
mkdir -p "$DECOY_CWD"
DECOY_CWD="$(cd "$DECOY_CWD" && pwd)"
mkdir -p "$SESS/decoy-bucket/tm-long" "$SESS/decoy-bucket/tm-decoy"
printf '%s\n' "$DECOY_CWD" > "$SESS/decoy-bucket/.cwd"
seed_grok_unique "$SESS/decoy-bucket/tm-long/chat_history.jsonl" "CDT-218-T4-AC3-DECOY-TRAP"
seed_grok_unique "$SESS/decoy-bucket/tm-decoy/chat_history.jsonl" "CDT-218-T4-AC2-DECOY-SID"

EMPTY_CWD="$WORK/empty-match-cwd"
mkdir -p "$EMPTY_CWD"
EMPTY_CWD="$(cd "$EMPTY_CWD" && pwd)"
mkdir -p "$SESS/empty-match"
printf '%s\n' "$EMPTY_CWD" > "$SESS/empty-match/.cwd"

# T4.1 AC1 Stop: empty transcript_path, cwd=$LONG_CWD
STOP_LONG=$(jq -nc --arg cwd "$LONG_CWD" \
  '{hook_event_name:"Stop",session_id:"tm-long",transcript_path:"",cwd:$cwd,reason:"end_turn"}')
RC=$(pipe_rec "$STOP_LONG")
assert_rc0 "$RC" "M5a AC1 Stop long-cwd exit 0"
assert_no_block "M5a AC1 Stop"
if grep -q 'CDT-218-T4-AC1-LONG-CWD' "$STORE/tm-long/main.md" 2>/dev/null; then
  pass "M5a AC1 Stop main.md unique string"
else
  fail "M5a AC1 Stop missing unique string main=$(ls "$STORE/tm-long/main.md" 2>/dev/null || echo missing)"
fi
if grep -q 'CDT-218-T4-AC3-DECOY-TRAP' "$STORE/tm-long/main.md" 2>/dev/null; then
  fail "M5a AC1 Stop selected decoy bucket"
else
  pass "M5a AC3 decoy-bucket not selected"
fi
GSRC=$(cut -f2 "$STORE/tm-long/cursor" 2>/dev/null || true)
if [ "$GSRC" = "$SESS/short-bucket/tm-long/chat_history.jsonl" ]; then
  pass "M5a AC1 Stop cursor field 2 resolved chat_history.jsonl"
else
  fail "M5a AC1 Stop cursor src=$GSRC want=$SESS/short-bucket/tm-long/chat_history.jsonl"
fi
if [ -e "$SESS/$LONG_ENC" ]; then
  fail "M5a AC1 reconstruct created urlencode-named dir"
else
  pass "M5a AC1 still no urlencode-named dir"
fi

# T4.2 AC1 SessionEnd: same fixture, new sid, empty path, reason=other
SE_LONG=$(jq -nc --arg cwd "$LONG_CWD" \
  '{hookEventName:"SessionEnd",sessionId:"tm-long-se",transcriptPath:"",cwd:$cwd,reason:"other"}')
RC=$(pipe_rec "$SE_LONG")
assert_rc0 "$RC" "M5a AC1 SessionEnd long-cwd exit 0"
assert_no_block "M5a AC1 SessionEnd"
if grep -q 'CDT-218-T4-AC1-SESSIONEND' "$STORE/tm-long-se/main.md" 2>/dev/null; then
  pass "M5a AC1 SessionEnd flushes unique string"
else
  fail "M5a AC1 SessionEnd did not flush"
fi
GSRC=$(cut -f2 "$STORE/tm-long-se/cursor" 2>/dev/null || true)
if [ "$GSRC" = "$SESS/short-bucket/tm-long-se/chat_history.jsonl" ]; then
  pass "M5a AC1 SessionEnd cursor field 2 resolved chat_history.jsonl"
else
  fail "M5a AC1 SessionEnd cursor src=$GSRC"
fi

# T4.3 AC2: keep tm-ghost; matching .cwd without file; decoy .cwd
if [ -e "$STORE/tm-ghost" ]; then
  fail "M5a AC2 tm-ghost sid dir appeared"
else
  pass "M5a AC2 tm-ghost still absent"
fi
ERR_BEFORE=$(wc -c < "$STORE/.errors.log" 2>/dev/null || echo 0)
MISS_JSON=$(jq -nc --arg cwd "$EMPTY_CWD" \
  '{hook_event_name:"Stop",session_id:"tm-cwd-miss",transcript_path:"",cwd:$cwd,reason:"end_turn"}')
RC=$(pipe_rec "$MISS_JSON")
assert_rc0 "$RC" "M5a AC2 matching .cwd without file exit 0"
if [ -e "$STORE/tm-cwd-miss" ]; then
  fail "M5a AC2 matching .cwd without file created sid dir"
else
  pass "M5a AC2 matching .cwd without file no sid dir"
fi
DECOY_JSON=$(jq -nc --arg cwd "$LONG_CWD" \
  '{hook_event_name:"Stop",session_id:"tm-decoy",transcript_path:"",cwd:$cwd,reason:"end_turn"}')
RC=$(pipe_rec "$DECOY_JSON")
assert_rc0 "$RC" "M5a AC2 decoy .cwd exit 0"
if [ -e "$STORE/tm-decoy" ]; then
  fail "M5a AC2 decoy .cwd created sid dir"
else
  pass "M5a AC2 decoy .cwd no sid dir"
fi
ERR_AFTER=$(wc -c < "$STORE/.errors.log" 2>/dev/null || echo 0)
if [ "$ERR_BEFORE" = "$ERR_AFTER" ]; then
  pass "M5a AC2 .errors.log byte-unchanged"
else
  fail "M5a AC2 .errors.log mutated before=$ERR_BEFORE after=$ERR_AFTER"
fi

# T4.4 AC3: short-cwd Grok reconstruct; urlencode wins; Claude + sibling untouched
seed_grok_unique "$SESS/$ENC/tm-short-recon/chat_history.jsonl" "CDT-218-T4-AC3-SHORT-CWD"
mkdir -p "$SESS/aaa-cwd-marker/tm-short-recon"
printf '%s\n' "$PROJ_ABS" > "$SESS/aaa-cwd-marker/.cwd"
seed_grok_unique "$SESS/aaa-cwd-marker/tm-short-recon/chat_history.jsonl" "CDT-218-T4-AC3-MARKER-TRAP"
SHORT_JSON=$(jq -nc --arg cwd "$PROJ_ABS" \
  '{hook_event_name:"Stop",session_id:"tm-short-recon",transcript_path:"",cwd:$cwd,reason:"end_turn"}')
RC=$(pipe_rec "$SHORT_JSON")
assert_rc0 "$RC" "M5a AC3 short-cwd Grok reconstruct exit 0"
if grep -q 'CDT-218-T4-AC3-SHORT-CWD' "$STORE/tm-short-recon/main.md" 2>/dev/null; then
  pass "M5a AC3 short-cwd Grok meaning channel"
else
  fail "M5a AC3 short-cwd missing unique string"
fi
if grep -q 'CDT-218-T4-AC3-MARKER-TRAP' "$STORE/tm-short-recon/main.md" 2>/dev/null; then
  fail "M5a AC3 short-cwd selected .cwd marker over urlencode"
else
  pass "M5a AC3 urlencode file wins over matching .cwd"
fi
GSRC=$(cut -f2 "$STORE/tm-short-recon/cursor" 2>/dev/null || true)
if [ "$GSRC" = "$SESS/$ENC/tm-short-recon/chat_history.jsonl" ]; then
  pass "M5a AC3 short-cwd cursor field 2 urlencode chat_history.jsonl"
else
  fail "M5a AC3 short-cwd cursor src=$GSRC"
fi
if grep -q 'hello from claude fixture' "$STORE/tm-claude/main.md" 2>/dev/null; then
  pass "M5a AC3 Claude fixture still present"
else
  fail "M5a AC3 Claude fixture missing"
fi
if grep -q 'hello from grok fixture' "$STORE/tm-grok/main.md" 2>/dev/null; then
  pass "M5a AC3 Grok updates.jsonl sibling still present"
else
  fail "M5a AC3 Grok sibling fixture missing"
fi
GSRC=$(cut -f2 "$STORE/tm-grok/cursor" 2>/dev/null || true)
if [ "$GSRC" = "$GROK_DIR/chat_history.jsonl" ]; then
  pass "M5a AC3 updates.jsonl sibling cursor untouched"
else
  fail "M5a AC3 sibling cursor mutated src=$GSRC"
fi

# T4.5 AC6: N matching .cwd+file → lexical-min cursor source-path
PAD6="$(printf 'b%.0s' {1..240})"
LONG6="$WORK/q/$PAD6"
mkdir -p "$LONG6"
LONG6="$(cd "$LONG6" && pwd)"
LONG6_ENC="$(jq -rn --arg s "$LONG6" '$s|@uri')"
if [ "${#LONG6_ENC}" -gt 255 ] && [ ! -e "$SESS/$LONG6_ENC" ]; then
  pass "M5a AC6 cwd @uri length ${#LONG6_ENC} >255, no urlencode dir"
else
  fail "M5a AC6 encode len=${#LONG6_ENC} exists=$( [ -e "$SESS/$LONG6_ENC" ] && echo yes || echo no )"
fi
mkdir -p "$SESS/zzz-dup/tm-dup" "$SESS/aaa-dup/tm-dup"
printf '%s\n' "$LONG6" > "$SESS/zzz-dup/.cwd"
printf '%s\n' "$LONG6" > "$SESS/aaa-dup/.cwd"
seed_grok_unique "$SESS/zzz-dup/tm-dup/chat_history.jsonl" "CDT-218-T4-AC6-ZZZ"
seed_grok_unique "$SESS/aaa-dup/tm-dup/chat_history.jsonl" "CDT-218-T4-AC6-AAA"
DUP_JSON=$(jq -nc --arg cwd "$LONG6" \
  '{hook_event_name:"Stop",session_id:"tm-dup",transcript_path:"",cwd:$cwd,reason:"end_turn"}')
RC=$(pipe_rec "$DUP_JSON")
assert_rc0 "$RC" "M5a AC6 N-match Stop exit 0"
assert_no_block "M5a AC6"
GSRC=$(cut -f2 "$STORE/tm-dup/cursor" 2>/dev/null || true)
if [ "$GSRC" = "$SESS/aaa-dup/tm-dup/chat_history.jsonl" ]; then
  pass "M5a AC6 cursor field 2 lexical-min aaa-dup"
else
  fail "M5a AC6 cursor src=$GSRC want=$SESS/aaa-dup/tm-dup/chat_history.jsonl"
fi
if grep -q 'CDT-218-T4-AC6-AAA' "$STORE/tm-dup/main.md" 2>/dev/null \
   && ! grep -q 'CDT-218-T4-AC6-ZZZ' "$STORE/tm-dup/main.md" 2>/dev/null; then
  pass "M5a AC6 main.md from lexical-min bucket"
else
  fail "M5a AC6 main.md not lexical-min"
fi

# ---------------------------------------------------------------------------
# M4a / CDT-217 T3 — SubagentStop nest (AC2–AC10)
# ---------------------------------------------------------------------------
copy_aged "$FIX/subagent-child.jsonl" "$WORK/src/subagent-child.jsonl"
copy_aged "$FIX/parent-with-task.jsonl" "$WORK/src/parent-with-task.jsonl"
copy_aged "$FIX/fork-parent.jsonl" "$WORK/src/fork-parent.jsonl"
CHILD_SRC="$WORK/src/subagent-child.jsonl"
TASK_SRC="$WORK/src/parent-with-task.jsonl"
TRAIL_SRC="$WORK/src/fork-parent.jsonl"

# T3.3 AC2 / AC2b / AC10 — nest on first SubagentStop; parent main.md absent
NEST_JSON=$(jq -nc --arg p "$CHILD_SRC" \
  '{hook_event_name:"SubagentStop",session_id:"tm-nest",agent_id:"worker-1",agent_transcript_path:$p,reason:"other"}')
RC=$(pipe_rec "$NEST_JSON")
assert_rc0 "$RC" "AC2 SubagentStop exit 0"
assert_no_block "AC2 SubagentStop"
NEST="$STORE/tm-nest/agents/worker-1"
if [ -f "$STORE/tm-nest/main.md" ]; then
  fail "AC2 parent main.md created on SubagentStop"
else
  pass "AC2 parent main.md absent"
fi
for p in "$NEST/main.md" "$NEST/meta" "$NEST/cursor" "$NEST/thinking" "$NEST/tool_result" "$NEST/injection"; do
  if [ -e "$p" ]; then
    pass "AC2 nest has $(basename "$p")"
  else
    fail "AC2 nest missing $(basename "$p")"
  fi
done
if grep -q 'CDT-217-T3-CHILD-UNIQUE' "$NEST/main.md" 2>/dev/null; then
  pass "AC2 nest main.md unique string"
else
  fail "AC2 nest missing unique string"
fi
if grep -q '^parent: tm-nest$' "$NEST/meta" 2>/dev/null; then
  pass "AC2 nest meta parent: tm-nest"
else
  fail "AC2 nest meta missing parent: $(cat "$NEST/meta" 2>/dev/null)"
fi

# AC10 empty path: no nest, no M5a reconstruct (cwd would hit long-cwd bucket)
mkdir -p "$SESS/short-bucket/tm-m5a-skip"
seed_grok_unique "$SESS/short-bucket/tm-m5a-skip/chat_history.jsonl" "CDT-217-T3-M5A-SHOULD-NOT-APPEAR"
EMPTY_JSON=$(jq -nc --arg cwd "$LONG_CWD" \
  '{hook_event_name:"SubagentStop",session_id:"tm-m5a-skip",agent_id:"worker-1",agent_transcript_path:"",transcript_path:"",cwd:$cwd,reason:"other"}')
RC=$(pipe_rec "$EMPTY_JSON")
assert_rc0 "$RC" "AC10 empty path exit 0"
assert_no_block "AC10 empty path"
if [ -e "$STORE/tm-m5a-skip" ]; then
  fail "AC10 empty path created sid dir (M5a reconstruct?)"
else
  pass "AC10 empty path no nest / no M5a sid dir"
fi
if grep -rq 'CDT-217-T3-M5A-SHOULD-NOT-APPEAR' "$STORE" 2>/dev/null; then
  fail "AC10 empty path M5a-reconstructed grok unique string"
else
  pass "AC10 empty path did not reconstruct grok source"
fi

# AC2b missing file: no nest, .errors.log line, exit 0
MISS_JSON=$(jq -nc --arg p "$WORK/no-such-child.jsonl" \
  '{hook_event_name:"SubagentStop",session_id:"tm-miss-child",agent_id:"worker-1",agent_transcript_path:$p,reason:"other"}')
RC=$(pipe_rec "$MISS_JSON")
assert_rc0 "$RC" "AC2b missing file exit 0"
assert_no_block "AC2b missing file"
if [ -e "$STORE/tm-miss-child" ]; then
  fail "AC2b missing file created sid dir"
else
  pass "AC2b missing file no nest"
fi
if grep -q 'no transcript: sid=tm-miss-child' "$STORE/.errors.log" 2>/dev/null; then
  pass "AC2b missing file .errors.log line"
else
  fail "AC2b missing file no .errors.log line"
fi

# T3.4 AC2c — path-escape agent_id: no nest outside $STORE/<sid>/agents/
ESC_JSON=$(jq -nc --arg p "$CHILD_SRC" \
  '{hook_event_name:"SubagentStop",session_id:"tm-esc",agent_id:"../x",agent_transcript_path:$p,reason:"other"}')
STORE_BEFORE=$(find "$STORE" -type f ! -name '.errors.log' | LC_ALL=C sort)
RC=$(pipe_rec "$ESC_JSON")
assert_rc0 "$RC" "AC2c ../x exit 0"
assert_no_block "AC2c ../x"
STORE_AFTER=$(find "$STORE" -type f ! -name '.errors.log' | LC_ALL=C sort)
if [ -e "$STORE/tm-esc" ] || [ -e "$STORE/x" ] || [ -d "$STORE/agents" ]; then
  fail "AC2c ../x wrote sid/escape path"
else
  pass "AC2c ../x no nest"
fi
if [ "$STORE_BEFORE" = "$STORE_AFTER" ]; then
  pass "AC2c ../x no files outside errors.log"
else
  fail "AC2c ../x mutated store files besides .errors.log"
fi

SLASH_JSON=$(jq -nc --arg p "$CHILD_SRC" \
  '{hook_event_name:"SubagentStop",session_id:"tm-slash",agent_id:"a/b",agent_transcript_path:$p,reason:"other"}')
RC=$(pipe_rec "$SLASH_JSON")
assert_rc0 "$RC" "AC2c a/b exit 0"
assert_no_block "AC2c a/b"
if [ -d "$STORE/tm-slash/agents/a" ] || [ -e "$STORE/tm-slash/a" ] || [ -e "$STORE/a" ]; then
  fail "AC2c a/b path-escaped outside agents/<id>/"
else
  pass "AC2c a/b no agents/a/ path-escape"
fi
SLASH_OUT=0
if [ -d "$STORE/tm-slash" ]; then
  while IFS= read -r f; do
    case "$f" in
      "$STORE/tm-slash/agents"|"$STORE/tm-slash/agents/"*) ;;
      *) SLASH_OUT=1 ;;
    esac
  done < <(find "$STORE/tm-slash" -mindepth 1 -print)
fi
if [ "$SLASH_OUT" -eq 0 ]; then
  pass "AC2c a/b nothing outside $STORE/tm-slash/agents/"
else
  fail "AC2c a/b wrote outside $STORE/tm-slash/agents/"
fi

# T3.5 AC3 — commute + spawn-adjacent vs trailing
sub_payload() {
  jq -nc --arg p "$CHILD_SRC" --arg sid "$1" \
    '{hook_event_name:"SubagentStop",session_id:$sid,agent_id:"worker-1",agent_transcript_path:$p,reason:"other"}'
}
par_payload() {
  jq -nc --arg p "$2" --arg sid "$1" \
    '{hook_event_name:"Stop",session_id:$sid,transcript_path:$p,reason:"end_turn"}'
}

run_commute() {
  local parent_src="$1" label="$2"
  local sa="$WORK/store-c3a-$label" sb="$WORK/store-c3b-$label" sid="tm-c3"
  mkdir -p "$sa" "$sb"
  RC=$(pipe_rec_root "$sa" "$(sub_payload "$sid")")
  assert_rc0 "$RC" "AC3 $label sub-then-parent SubagentStop exit 0"
  assert_no_block "AC3 $label sub-then-parent SubagentStop"
  RC=$(pipe_rec_root "$sa" "$(par_payload "$sid" "$parent_src")")
  assert_rc0 "$RC" "AC3 $label sub-then-parent Stop exit 0"
  assert_no_block "AC3 $label sub-then-parent Stop"
  RC=$(pipe_rec_root "$sb" "$(par_payload "$sid" "$parent_src")")
  assert_rc0 "$RC" "AC3 $label parent-then-sub Stop exit 0"
  assert_no_block "AC3 $label parent-then-sub Stop"
  RC=$(pipe_rec_root "$sb" "$(sub_payload "$sid")")
  assert_rc0 "$RC" "AC3 $label parent-then-sub SubagentStop exit 0"
  assert_no_block "AC3 $label parent-then-sub SubagentStop"
  local ma="$sa/$sid/main.md" mb="$sb/$sid/main.md"
  local na="$sa/$sid/agents/worker-1/main.md" nb="$sb/$sid/agents/worker-1/main.md"
  local ca cb
  ca=$(count_nest_ref "$ma")
  cb=$(count_nest_ref "$mb")
  if [ "$ca" = "1" ] && [ "$cb" = "1" ]; then
    pass "AC3 $label exactly one nest-ref both orders"
  else
    fail "AC3 $label nest-ref count a=$ca b=$cb"
  fi
  grep '^> @agents/' "$ma" 2>/dev/null | LC_ALL=C sort > "$WORK/refs-a-$label"
  grep '^> @agents/' "$mb" 2>/dev/null | LC_ALL=C sort > "$WORK/refs-b-$label"
  if cmp -s "$WORK/refs-a-$label" "$WORK/refs-b-$label"; then
    pass "AC3 $label commute nest-ref set"
  else
    fail "AC3 $label commute nest-ref set diverged"
  fi
  if [ -f "$na" ] && [ -f "$nb" ] \
     && grep -q 'CDT-217-T3-CHILD-UNIQUE' "$na" \
     && grep -q 'CDT-217-T3-CHILD-UNIQUE' "$nb"; then
    pass "AC3 $label nest unique string both orders"
  else
    fail "AC3 $label nest missing unique string"
  fi
}

run_commute "$TASK_SRC" "spawn"
SPAWN_MAIN="$WORK/store-c3a-spawn/tm-c3/main.md"
if [ -f "$SPAWN_MAIN" ]; then
  REF_LN=$(grep -n '^> @agents/worker-1/main.md$' "$SPAWN_MAIN" | head -1 | cut -d: -f1)
  TASK_LN=$(grep -n 'spawning worker' "$SPAWN_MAIN" | head -1 | cut -d: -f1)
  AFTER_LN=$(grep -n 'parent after spawn' "$SPAWN_MAIN" | head -1 | cut -d: -f1)
  if [ -n "${REF_LN:-}" ] && [ -n "${TASK_LN:-}" ] && [ -n "${AFTER_LN:-}" ] \
     && [ "$TASK_LN" -lt "$REF_LN" ] && [ "$REF_LN" -lt "$AFTER_LN" ]; then
    pass "AC3 spawn-adjacent nest-ref (after Task, before later turn)"
  else
    fail "AC3 spawn-adjacent place task=${TASK_LN:-none} ref=${REF_LN:-none} after=${AFTER_LN:-none}"
  fi
  BAD_REF=$(walker_bad_ref "$SPAWN_MAIN")
  if [ "$BAD_REF" -eq 0 ]; then
    pass "AC9 walker allows > @agents/ nest-ref"
  else
    fail "AC9 walker rejected > @agents/ nest-ref"
  fi
else
  fail "AC3 spawn commute produced no parent main.md"
fi

run_commute "$TRAIL_SRC" "trail"
TRAIL_MAIN="$WORK/store-c3a-trail/tm-c3/main.md"
if [ -f "$TRAIL_MAIN" ]; then
  REF_LN=$(grep -n '^> @agents/worker-1/main.md$' "$TRAIL_MAIN" | head -1 | cut -d: -f1)
  LAST_LN=$(grep -n 'parent assistant turn' "$TRAIL_MAIN" | head -1 | cut -d: -f1)
  if [ -n "${REF_LN:-}" ] && [ -n "${LAST_LN:-}" ] && [ "$REF_LN" -gt "$LAST_LN" ]; then
    pass "AC3 trailing nest-ref (after last meaning-channel block)"
  else
    fail "AC3 trailing place last=${LAST_LN:-none} ref=${REF_LN:-none}"
  fi
else
  fail "AC3 trail commute produced no parent main.md"
fi

# T3.6 AC7 — parent rebuild preserves agents/ + nest-ref
RC=$(invoke_rec --transcript "$TASK_SRC" --sid tm-reb)
assert_rc0 "$RC" "AC7 parent setup exit 0"
assert_no_block "AC7 parent setup"
REB_NEST=$(jq -nc --arg p "$CHILD_SRC" \
  '{hook_event_name:"SubagentStop",session_id:"tm-reb",agent_id:"worker-1",agent_transcript_path:$p,reason:"other"}')
RC=$(pipe_rec "$REB_NEST")
assert_rc0 "$RC" "AC7 nest setup exit 0"
assert_no_block "AC7 nest setup"
if [ -f "$STORE/tm-reb/agents/worker-1/main.md" ] \
   && grep -q '^> @agents/worker-1/main.md$' "$STORE/tm-reb/main.md"; then
  pass "AC7 pre-rebuild nest + nest-ref present"
else
  fail "AC7 pre-rebuild missing nest or nest-ref"
fi
NEST_SHA=$(sha256sum "$STORE/tm-reb/agents/worker-1/main.md" | awk '{print $1}')
copy_aged "$FIX/parent-with-task.jsonl" "$WORK/src/rebuild-parent-2.jsonl"
RC=$(invoke_rec --transcript "$WORK/src/rebuild-parent-2.jsonl" --sid tm-reb)
assert_rc0 "$RC" "AC7 parent rebuild exit 0"
assert_no_block "AC7 parent rebuild"
if [ -f "$STORE/tm-reb/agents/worker-1/main.md" ]; then
  pass "AC7 agents/worker-1/main.md survived parent rebuild"
else
  fail "AC7 nest wiped by parent rebuild"
fi
NEST_SHA2=$(sha256sum "$STORE/tm-reb/agents/worker-1/main.md" 2>/dev/null | awk '{print $1}')
if [ -n "$NEST_SHA" ] && [ "$NEST_SHA" = "$NEST_SHA2" ]; then
  pass "AC7 nest main.md sha256 unchanged across rebuild"
else
  fail "AC7 nest main.md mutated across rebuild"
fi
if [ "$(count_nest_ref "$STORE/tm-reb/main.md")" = "1" ]; then
  pass "AC7 nest-ref still in parent main.md after rebuild"
else
  fail "AC7 nest-ref missing after parent rebuild"
fi
if grep -q 'CDT-217-T3-CHILD-UNIQUE' "$STORE/tm-reb/agents/worker-1/main.md" 2>/dev/null; then
  pass "AC7 nest unique string survived rebuild"
else
  fail "AC7 nest unique string lost on rebuild"
fi

# T3.7 AC8 — --agent CLI
RC=$(invoke_rec --transcript "$CHILD_SRC" --sid tm-cli --agent worker-1)
assert_rc0 "$RC" "AC8 --transcript --sid --agent exit 0"
assert_no_block "AC8 --agent nest"
if [ -f "$STORE/tm-cli/agents/worker-1/main.md" ] \
   && grep -q 'CDT-217-T3-CHILD-UNIQUE' "$STORE/tm-cli/agents/worker-1/main.md"; then
  pass "AC8 --agent creates nest"
else
  fail "AC8 --agent did not create nest"
fi
CLI_BEFORE=$(find "$STORE" -type f ! -name '.errors.log' | LC_ALL=C sort)
RC=$(invoke_rec --agent worker-1 </dev/null)
assert_rc0 "$RC" "AC8 --agent without --transcript exit 0"
assert_no_block "AC8 --agent without --transcript"
CLI_AFTER=$(find "$STORE" -type f ! -name '.errors.log' | LC_ALL=C sort)
if [ "$CLI_BEFORE" = "$CLI_AFTER" ]; then
  pass "AC8 --agent without --transcript creates nothing"
else
  fail "AC8 --agent without --transcript mutated store"
fi

# T3.8 AC6 / AC9 — walker on rebuilt parent; M5a still green (block above)
BAD_REF=$(walker_bad_ref "$STORE/tm-reb/main.md")
if [ "$BAD_REF" -eq 0 ]; then
  pass "AC9 M2 walker allows > @agents/ on rebuilt parent"
else
  fail "AC9 M2 walker unexpected @ref on rebuilt parent"
fi
if grep -q 'CDT-218-T4-AC1-LONG-CWD' "$STORE/tm-long/main.md" 2>/dev/null; then
  pass "AC9 M5a long-cwd still green after nest tests"
else
  fail "AC9 M5a long-cwd regress after nest tests"
fi

# ---------------------------------------------------------------------------
# M2 — operator ~/.claude/transcript/ untouched
# ---------------------------------------------------------------------------
AFTER_OP="$(find "$OP_STORE" -printf '%T@ %p\n' 2>/dev/null | sort || true)"
if [ "$BEFORE_OP" = "$AFTER_OP" ]; then
  pass "M2 operator ~/.claude/transcript/ untouched"
else
  fail "M2 operator store changed"
  printf 'BEFORE\n%s\nAFTER\n%s\n' "$BEFORE_OP" "$AFTER_OP" >&2
fi
if [ -d "$FAKE_HOME/.claude/transcript" ]; then
  fail "M2 wrote fake HOME transcript (ROOT override ignored?)"
else
  pass "M2 no default-root write under fake HOME"
fi

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
