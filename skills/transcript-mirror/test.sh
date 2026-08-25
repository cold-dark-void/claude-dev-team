#!/usr/bin/env bash
# transcript-mirror/test.sh — SPEC-036 M1–M11 plugin harness (CDT-220 Task 4).
# Machine-check: bash skills/transcript-mirror/test.sh
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# T2 helper remains transcript-sync-test.sh (not invoked here).
#
# Covers: AC3 unregistered no dirs; AC4 subagent no-op; AC5 updates.jsonl
# sibling rewrite; AC6 idempotent + rewind; AC8 collapse + thinking header +
# empty-thinking placeholder; AC9 parent: + dedup; AC10 never-fired create;
# AC11 --check exit 0; Grok h: --check status=ok after sync.
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
         settings-registered.json never-mirrored.jsonl; do
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
# AC4 / M4 — SubagentStop and non-empty agent_id are no-ops
# ---------------------------------------------------------------------------
copy_aged "$FIX/claude-uuid.jsonl" "$WORK/src/claude-uuid.jsonl"
SUB_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hook_event_name:"SubagentStop",session_id:"tm-sub",transcript_path:$p,reason:"end_turn"}')
RC=$(pipe_rec "$SUB_JSON")
assert_rc0 "$RC" "AC4 SubagentStop exit 0"
if [ -e "$STORE/tm-sub" ]; then
  fail "AC4 SubagentStop created sid dir"
else
  pass "AC4 SubagentStop no-op (no sid dir)"
fi

AGENT_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hookEventName:"Stop",sessionId:"tm-agent",transcriptPath:$p,reason:"end_turn",agent_id:"worker-1"}')
RC=$(pipe_rec "$AGENT_JSON")
assert_rc0 "$RC" "AC4 agent_id exit 0"
if [ -e "$STORE/tm-agent" ]; then
  fail "AC4 agent_id created sid dir"
else
  pass "AC4 agent_id no-op (no sid dir)"
fi

AGENT_TYPE_JSON=$(jq -nc --arg p "$WORK/src/claude-uuid.jsonl" \
  '{hook_event_name:"Stop",session_id:"tm-atype",transcript_path:$p,agentType:"explore"}')
RC=$(pipe_rec "$AGENT_TYPE_JSON")
assert_rc0 "$RC" "AC4 agentType exit 0"
if [ -e "$STORE/tm-atype" ]; then
  fail "AC4 agentType created sid dir"
else
  pass "AC4 agentType no-op"
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
BAD_REF=0
while IFS= read -r line; do
  case "$line" in
    '> @thinking/'*|'> @tool_result/'*|'> @injection/'*) ;;
    '> @'*) BAD_REF=1 ;;
  esac
done < "$MAIN"
if [ "$BAD_REF" -eq 0 ]; then
  pass "M2 @refs relative closed taxonomy"
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
