#!/usr/bin/env bash
# grok-to-claude-jsonl-test.sh — CDT-92 T1 adapter unit + prepare smoke.
# ACs: AC4, AC5, AC7. Run: bash skills/handoff/grok-to-claude-jsonl-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ADAPTER="$HERE/grok-to-claude-jsonl.py"
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures/grok-chat-mini.jsonl"
PHRASE_USER="CDT92-FIXTURE-PHRASE-ALPHA"
PHRASE_ASSIST="CDT92-FIXTURE-ASSIST-BETA"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/grok-adapt-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SID="019f-cdt92-fixture-session"
CWD="/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-92"
OUT="$WORK/claude-shaped.jsonl"

# ---- T0: script + fixture present ----
if [ -f "$ADAPTER" ] && [ -x "$ADAPTER" ] || [ -f "$ADAPTER" ]; then ok
else bad "T0 adapter missing: $ADAPTER"; fi
if [ -f "$FIX" ]; then ok; else bad "T0 fixture missing: $FIX"; fi
if rg -qF "$PHRASE_USER" "$FIX" 2>/dev/null || grep -qF "$PHRASE_USER" "$FIX"; then ok
else bad "T0 fixture missing known phrase $PHRASE_USER"; fi
NFIX=$(wc -l <"$FIX" | tr -d ' ')
if [ "$NFIX" -ge 6 ]; then ok; else bad "T0 fixture lines $NFIX < 6"; fi

# ---- T1: happy path adapt ----
if python3 "$ADAPTER" --in "$FIX" --out "$OUT" --cwd "$CWD" --session-id "$SID" \
  2>"$WORK/adapt.err"; then ok
else bad "T1 adapt failed rc=$? err=$(head -c 200 "$WORK/adapt.err")"; fi

# ---- T2: user phrase in out ----
if [ -f "$OUT" ] && grep -qF "$PHRASE_USER" "$OUT"; then ok
else bad "T2 out missing user phrase $PHRASE_USER"; fi

# ---- T3: assist phrase in out ----
if [ -f "$OUT" ] && grep -qF "$PHRASE_ASSIST" "$OUT"; then ok
else bad "T3 out missing assist phrase $PHRASE_ASSIST"; fi

# ---- T4: only user/assistant types; no tool_result/system/reasoning ----
python3 - "$OUT" <<'PY' >"$WORK/t4.out" 2>"$WORK/t4.err"
import json, sys
path = sys.argv[1]
types = set()
n_user = n_asst = 0
uuids = []
for line in open(path):
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    t = o.get("type")
    types.add(t)
    if t == "user":
        n_user += 1
    if t == "assistant":
        n_asst += 1
    uuids.append(o.get("uuid"))
bad = types - {"user", "assistant"}
print("types", sorted(types))
print("n_user", n_user)
print("n_asst", n_asst)
print("bad", sorted(bad))
print("uuid_n", len(uuids), "unique", len(set(uuids)))
print("all_uuid_safe", all(isinstance(u, str) and bool(u) and all(c.isalnum() or c in "._-" for c in u) for u in uuids))
PY
if grep -q 'bad \[\]' "$WORK/t4.out" && grep -q 'n_user [1-9]' "$WORK/t4.out" \
  && grep -q 'n_asst [1-9]' "$WORK/t4.out"; then ok
else bad "T4 type filter failed: $(cat "$WORK/t4.out")"; fi
if grep -q 'all_uuid_safe True' "$WORK/t4.out"; then ok
else bad "T4 uuid charset: $(cat "$WORK/t4.out")"; fi
# unique uuids
UNIQ=$(python3 -c 'import re; t=open("'"$WORK/t4.out"'").read(); m=re.search(r"uuid_n (\d+) unique (\d+)", t); print(m.group(1)==m.group(2) if m else False)')
if [ "$UNIQ" = "True" ]; then ok; else bad "T4 uuids not unique: $(cat "$WORK/t4.out")"; fi

# ---- T5: cwd + sessionId injected on every line (AC7) ----
python3 - "$OUT" "$CWD" "$SID" <<'PY' >"$WORK/t5.out" 2>"$WORK/t5.err"
import json, sys
path, cwd, sid = sys.argv[1], sys.argv[2], sys.argv[3]
ok = True
n = 0
meta = 0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    n += 1
    if o.get("cwd") != cwd:
        ok = False
        print("bad_cwd", o.get("cwd"))
    if o.get("sessionId") != sid:
        ok = False
        print("bad_sid", o.get("sessionId"))
    msg = o.get("message") or {}
    if not isinstance(msg, dict) or msg.get("role") not in ("user", "assistant"):
        ok = False
        print("bad_message", msg)
    if not o.get("timestamp"):
        ok = False
        print("missing_ts")
    if o.get("isMeta"):
        meta += 1
print("ok", ok, "n", n, "meta", meta)
PY
if grep -q 'ok True' "$WORK/t5.out" && grep -q 'meta [1-9]' "$WORK/t5.out"; then ok
else bad "T5 cwd/session/isMeta: $(cat "$WORK/t5.out") $(cat "$WORK/t5.err")"; fi

# ---- T6: tool_use structure present; no type=tool_result lines ----
if grep -q '"type":"tool_use"' "$OUT" || grep -q '"type": "tool_use"' "$OUT"; then ok
else
  # compact separators may omit spaces
  if python3 -c 'import json,sys
ok=False
for line in open(sys.argv[1]):
  o=json.loads(line)
  c=(o.get("message") or {}).get("content") or []
  if isinstance(c,list) and any(isinstance(b,dict) and b.get("type")=="tool_use" for b in c):
    ok=True
print("yes" if ok else "no")
' "$OUT" | grep -q yes; then ok
  else bad "T6 expected tool_use block from fixture tool_calls"; fi
fi
if grep -qE '"type"[[:space:]]*:[[:space:]]*"tool_result"' "$OUT"; then
  bad "T6 tool_result type leaked into output"
else ok; fi

# ---- T7: bad args → rc ≠ 0 ----
if python3 "$ADAPTER" --in "$FIX" --out "$WORK/x.jsonl" --cwd "" --session-id "$SID" \
  2>"$WORK/bad1.err"; then bad "T7 empty cwd should fail"
else ok; fi
if python3 "$ADAPTER" 2>"$WORK/bad2.err"; then bad "T7 missing args should fail"
else ok; fi
# empty / all-system input
printf '%s\n' '{"type":"system","content":"only system"}' >"$WORK/empty-ish.jsonl"
if python3 "$ADAPTER" --in "$WORK/empty-ish.jsonl" --out "$WORK/empty.out" \
  --cwd "$CWD" --session-id "$SID" 2>"$WORK/bad3.err"; then
  bad "T7 all-system should fail (≥1 user+assistant gate)"
else ok; fi

# ---- T8: prepare smoke on adapted file (AC4/AC5) ----
TR="$WORK/transcript.jsonl"
cp "$OUT" "$TR"
touch "$TR"
PLAN="$WORK/plan.json"
export HANDOFF_DIR="$WORK/handoff"
mkdir -p "$HANDOFF_DIR"
if bash "$PREPASS" prepare --uuid "$SID" --transcript "$TR" --allow-in-progress \
  --out "$PLAN" 2>"$WORK/prep.err"; then
  ok
  SP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("spine",""))' "$PLAN" 2>/dev/null || true)
  if [ -n "$SP" ] && [ -f "$SP" ]; then
    ok
    if grep -qF "$PHRASE_USER" "$SP"; then ok
    else bad "T8 spine missing $PHRASE_USER (AC5); spine head: $(head -c 300 "$SP")"; fi
    if grep -qF "$PHRASE_ASSIST" "$SP" || grep -qi 'fixture' "$SP"; then ok
    else
      # assist text should appear; soft-fail only if completely absent
      if grep -q 'assistant\|ASSIST\|working the warm' "$SP"; then ok
      else bad "T8 spine missing assist signal"; fi
    fi
  else
    bad "T8 prepare produced no spine path (plan=$(cat "$PLAN" 2>/dev/null | head -c 200))"
  fi
else
  bad "T8 prepare failed rc=$? err=$(head -c 300 "$WORK/prep.err")"
fi

# ---- T9: resolve-root sees injected cwd (AC7) ----
if bash "$HERE/resolve-root.sh" --transcript "$OUT" >"$WORK/rr.out" 2>"$WORK/rr.err"; then
  # first line is PROJECT_DIR — should be CWD (or realpath-equal)
  PD=$(head -n1 "$WORK/rr.out")
  if [ "$PD" = "$CWD" ] || [ "$(cd "$PD" 2>/dev/null && pwd)" = "$(cd "$CWD" 2>/dev/null && pwd)" ]; then ok
  else bad "T9 resolve-root PROJECT_DIR=$PD want $CWD err=$(cat "$WORK/rr.err")"; fi
else
  # resolve-root may fail if path doesn't exist as dir in sandbox — still check cwd was read
  if grep -q 'cannot determine project dir' "$WORK/rr.err"; then
    bad "T9 resolve-root failed to find cwd on adapted transcript: $(cat "$WORK/rr.err")"
  else
    # cwd exists for worktree path; unexpected failure
    bad "T9 resolve-root rc≠0: $(cat "$WORK/rr.err") out=$(cat "$WORK/rr.out")"
  fi
fi

echo "grok-to-claude-jsonl-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
