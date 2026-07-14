#!/usr/bin/env bash
# precompact-test.sh — SPEC-018 M12–M18 bite-tests (spec tests 13–19).
# Run: bash skills/handoff/precompact-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CAPTURE="$HERE/precompact-capture.sh"
PREPASS="$HERE/prepass.sh"
ASSEMBLE="$ROOT/skills/transcript-parse/assemble.py"
FRESHNESS="$ROOT/skills/transcript-parse/freshness.sh"
RESCUE_HOOK="$ROOT/.claude/hooks/precompact-rescue.sh"
POINTER_HOOK="$ROOT/.claude/hooks/rescue-pointer.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

SID="00000000-0000-4000-8000-00000000cafe"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/precompact-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Fake repo the hook writes into — NEVER this repo's real .claude/handoff/.
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
HDIR="$REPO/.claude/handoff"

# Fixture transcript: 4 good message lines (u1..u4), one fat toolUseResult
# sentinel, ONE truncated final line (mid-write simulation, no newline).
TR="$WORK/${SID}.jsonl"
mkfixture() {
  PAD=$(head -c 2000 /dev/zero | tr '\0' 'x')
  : > "$TR"
  printf '%s\n' '{"uuid":"u1","timestamp":"2026-07-03T10:00:00Z","type":"user","message":{"role":"user","content":[{"type":"text","text":"the real bug is in the parser"}]}}' >> "$TR"
  printf '%s\n' '{"uuid":"u2","timestamp":"2026-07-03T10:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"testing hypothesis A"},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/a.txt"}}]}}' >> "$TR"
  printf '%s\n' "{\"uuid\":\"u3\",\"timestamp\":\"2026-07-03T10:00:10Z\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"tool result\"}]},\"toolUseResult\":\"FIXTURE_TOOL_PAYLOAD_XYZ_${PAD}\"}" >> "$TR"
  printf '%s\n' '{"uuid":"u4","timestamp":"2026-07-03T10:00:15Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hypothesis A is wrong; converged on parser fix"}]}}' >> "$TR"
  printf '%s' '{"uuid":"u5","timestamp":"2026-07-03T10:00:2' >> "$TR"
}
mkfixture

hook_json() {
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"PreCompact","trigger":"%s"}' \
    "$SID" "$TR" "${1:-auto}"
}
run_capture() {   # run_capture [trigger] — rc in $?, stderr in $WORK/cap.err
  ( cd "$REPO" && hook_json "${1:-auto}" | bash "$CAPTURE" 2>"$WORK/cap.err" )
}

# ---- T1/T2: assemble-file mode (M12 locate-skip + truncated-tail drop) ----
OUT="$WORK/asm.out"
if python3 "$ASSEMBLE" assemble-file "$TR" > "$OUT" 2>/dev/null \
   && [ "$(wc -l < "$OUT")" -eq 4 ] && grep -q '"u1"' "$OUT" \
   && head -c 100000 "$OUT" | grep -qv '"u5"'; then ok; else bad "T1 assemble-file: 4 deduped lines, truncated u5 dropped"; fi
if python3 "$ASSEMBLE" assemble-file "$WORK/nope.jsonl" >/dev/null 2>&1; then
  bad "T2 assemble-file missing file must fail"; else ok; fi

# ---- T3/T4: freshness guard default vs carve-out (M9/M14) ----
touch "$TR"
sh "$FRESHNESS" check "$TR" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 9 ]; then ok; else bad "T3 default guard: fresh file must exit 9 (got $RC)"; fi
sh "$FRESHNESS" check "$TR" --allow-in-progress >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "T4 carve-out: fresh file + flag must exit 0 (got $RC)"; fi

# ---- T5/T6: prepass plumbing — M9 intact without the flag, capture with it ----
touch "$TR"
bash "$PREPASS" prepare --uuid "$SID" --transcript "$TR" --out "$WORK/p1.json" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 9 ]; then ok; else bad "T5 --transcript alone must still hit M9 exit 9 (got $RC)"; fi
touch "$TR"
if bash "$PREPASS" prepare --uuid "$SID" --transcript "$TR" --allow-in-progress \
     --out "$WORK/p2.json" >/dev/null 2>&1 \
   && [ -f "$WORK/p2.json" ] \
   && SP=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("spine",""))' "$WORK/p2.json") \
   && [ -n "$SP" ] && grep -q '\[L1\]' "$SP" \
   && grep -qv 'FIXTURE_TOOL_PAYLOAD_XYZ' "$SP"; then ok
else bad "T6 prepare --transcript --allow-in-progress: spine built, payload stripped"; fi

# ---- T7: carve-out unreachable from user-invoked paths (M14, static) ----
if grep -q 'allow-in-progress' "$ROOT/commands/handoff.md" "$ROOT/commands/retro.md" 2>/dev/null; then
  bad "T7 carve-out flag leaked into a user-invoked command"; else ok; fi

# ---- T8: capture happy path on a MID-WRITE transcript (M12/M14, spec test 13/15) ----
touch "$TR"
run_capture manual; RC=$?
ART="$HDIR/${SID}-precompact-001.md"
if [ "$RC" -eq 0 ] && [ -f "$ART" ] && grep -q '\[L1\]' "$ART" \
   && grep -q "/handoff $SID" "$ART" && grep -q 'trigger: manual' "$ART"; then ok
else bad "T8 capture: artifact with pointers + recovery line (rc=$RC)"; fi
for H in '## Convergence' '## Dead-ends' '## Code-state' '## Open-threads' '## Basics'; do
  if grep -q "^$H" "$ART" 2>/dev/null; then bad "T8b artifact must NOT contain M4 heading: $H"; else ok; fi
done
if grep -q 'FIXTURE_TOOL_PAYLOAD_XYZ' "$ART" 2>/dev/null; then
  bad "T8c artifact must not carry raw toolUseResult payload"; else ok; fi

# ---- T9: fail-open (M17, spec test 18) — bad transcript, garbage stdin ----
( cd "$REPO" && printf '{"session_id":"%s","transcript_path":"/nope/missing.jsonl","trigger":"auto"}' "$SID" \
  | bash "$CAPTURE" 2>"$WORK/cap9.err" ); RC=$?
if [ "$RC" -eq 0 ] && [ -s "$WORK/cap9.err" ]; then ok; else bad "T9 bad transcript: exit 0 + stderr (rc=$RC)"; fi
if [ "$RC" -eq 2 ]; then bad "T9b MUST NEVER exit 2"; else ok; fi
( cd "$REPO" && printf 'not json at all' | bash "$CAPTURE" 2>/dev/null ); RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "T9c garbage stdin: exit 0 (rc=$RC)"; fi

# ---- T10: retention N=3, warm brief + cache untouched (M15, spec test 16) ----
mkdir -p "$HDIR/cache"
printf 'warm brief sentinel\n' > "$HDIR/${SID}-warm-test.md"
printf '{"leaf_uuid":"u4","brief":"x"}\n' > "$HDIR/cache/${SID}.json"
for i in 1 2 3 4; do touch "$TR"; ( cd "$REPO" && hook_json auto \
  | HANDOFF_PRECOMPACT_MAX_PER_SESSION=3 bash "$CAPTURE" 2>/dev/null ); done
N=$(find "$HDIR" -maxdepth 1 -name "${SID}-precompact-*.md" | wc -l)
if [ "$N" -eq 3 ] && [ -f "$HDIR/${SID}-precompact-005.md" ] \
   && [ ! -f "$HDIR/${SID}-precompact-001.md" ]; then ok
else bad "T10 retention: want newest 3 of 5 (have $N)"; fi
if [ -f "$HDIR/${SID}-warm-test.md" ] && [ -f "$HDIR/cache/${SID}.json" ]; then ok
else bad "T10b prune touched a warm brief or the M8 cache"; fi

# ---- T11/T12: surfacing pointer, not dump (M16, spec test 17) ----
MARKER="$HDIR/.rescue-pointer.json"
if [ -f "$MARKER" ]; then ok; else bad "T11 marker missing after capture"; fi
PTR_OUT=$( cd "$REPO" && printf '{"hook_event_name":"PostCompact"}' | bash "$POINTER_HOOK" 2>/dev/null )
if printf '%s' "$PTR_OUT" | grep -q "precompact-005" \
   && printf '%s' "$PTR_OUT" | grep -q "/handoff $SID" && [ -f "$MARKER" ]; then ok
else bad "T11b PostCompact: pointer line printed, marker kept"; fi
SS_OUT=$( cd "$REPO" && printf '{"hook_event_name":"SessionStart"}' | bash "$POINTER_HOOK" 2>/dev/null )
if printf '%s' "$SS_OUT" | grep -q "/handoff $SID" && [ ! -f "$MARKER" ]; then ok
else bad "T11c SessionStart: pointer printed, marker consumed"; fi
SS2=$( cd "$REPO" && printf '{"hook_event_name":"SessionStart"}' | bash "$POINTER_HOOK" 2>/dev/null )
if [ -z "$SS2" ]; then ok; else bad "T11d second SessionStart must print nothing"; fi
if printf '%s' "$PTR_OUT" | grep -q 'the real bug is in the parser'; then
  bad "T12 surfacing dumped artifact content"; else ok; fi
if [ "$(printf '%s\n' "$PTR_OUT" | wc -l)" -le 2 ]; then ok; else bad "T12b pointer must be ~1 line"; fi

# ---- T13: shim graceful absence (M18, spec test 19) ----
mkdir -p "$WORK/norepo" "$WORK/nohome"
( cd "$WORK/norepo" && printf '%s' "$(hook_json)" \
  | HOME="$WORK/nohome" CLAUDE_PROJECT_DIR="$WORK/norepo" bash "$RESCUE_HOOK" 2>"$WORK/shim.err" ); RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "T13 shim without plugin must exit 0 (rc=$RC)"; fi

# ---- T14: registration + templates (M13, spec test 14) ----
SETTINGS="$ROOT/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); h=d.get("hooks",{}); sys.exit(0 if "PreCompact" in h and "PostCompact" in h and "SessionStart" in h else 1)' "$SETTINGS" 2>/dev/null; then ok
  else bad "T14 settings.json missing PreCompact/PostCompact/SessionStart"; fi
  if python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cmds = []
for ev in ("PreCompact", "PostCompact", "SessionStart"):
    for grp in d.get("hooks", {}).get(ev, []):
        for h in grp.get("hooks", []):
            cmds.append(h.get("command", ""))
bad = [c for c in cmds if "|" in c or "${CLAUDE_PROJECT_DIR}" not in c]
sys.exit(1 if (bad or not cmds) else 0)
PY
  then ok; else bad "T14b new hook commands: no pipes + CLAUDE_PROJECT_DIR-anchored"; fi
else
  echo "SKIP T14 (.claude/settings.json absent on this machine)"
fi
if bash "$ROOT/skills/init-orchestration/check-hook-templates.sh" >/dev/null 2>&1; then ok
else bad "T14c check-hook-templates.sh must pass"; fi

echo "---"
echo "precompact tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
