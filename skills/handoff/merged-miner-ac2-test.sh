#!/usr/bin/env bash
# merged-miner-ac2-test.sh — CDT-89 AC2 planted kinds through finalize/assemble.
#
# Proves the post-mine contract (no live LLM):
#   planted through_line.json + state.json → finalize → packet contains
#   killed, ruling, open (plus hyp/decision/fact/conflict markers).
#
# Kind partition (merged miner output contract):
#   through_line.json ⊆ {hypothesis, killed, ruling, decision, fact}
#   state.json        ⊆ {open, conflict}
#
# Live LLM mine of fixtures/spine-mineable-mini.txt is AC2b/manual only.
# Run: bash skills/handoff/merged-miner-ac2-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
PLANTED="$FIX/events-merged-planted"
SPINE="$FIX/spine-mineable-mini.txt"
GITBLOB="$FIX/git-state.txt"
TL="$PLANTED/through_line.json"
ST="$PLANTED/state.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/merged-miner-ac2.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export HANDOFF_DIR="$WORK/handoff"
mkdir -p "$HANDOFF_DIR"

# ---- T0: fixtures present ----
if [ -f "$TL" ] && [ -f "$ST" ] && [ -f "$SPINE" ] && [ -f "$GITBLOB" ] \
   && [ -x "$PREPASS" ]; then ok
else bad "T0 missing planted fixtures or prepass"; fi

# ---- T1: kind partition ceilings on planted miner output ----
PART=$(python3 -c '
import json,sys
TL_OK={"hypothesis","killed","ruling","decision","fact"}
ST_OK={"open","conflict"}
tl=json.load(open(sys.argv[1]))["events"]
st=json.load(open(sys.argv[2]))["events"]
tl_kinds={e["kind"] for e in tl}
st_kinds={e["kind"] for e in st}
errs=[]
if not tl_kinds <= TL_OK:
  errs.append(f"through_line bad kinds={tl_kinds-TL_OK}")
if not st_kinds <= ST_OK:
  errs.append(f"state bad kinds={st_kinds-ST_OK}")
# AC2 requires planted kill/ruling in through_line and open in state
need_tl={"killed","ruling"}
need_st={"open"}
if not need_tl <= tl_kinds:
  errs.append(f"through_line missing {need_tl-tl_kinds}")
if not need_st <= st_kinds:
  errs.append(f"state missing {need_st-st_kinds}")
# cross-partition leaks
if tl_kinds & ST_OK:
  errs.append(f"through_line has state kinds {tl_kinds & ST_OK}")
if st_kinds & TL_OK:
  errs.append(f"state has through_line kinds {st_kinds & TL_OK}")
print("ok" if not errs else "; ".join(errs))
' "$TL" "$ST")
if [ "$PART" = "ok" ]; then ok
else bad "T1 partition: $PART"; fi

# ---- T2: finalize on planted events dir → STM packet ----
PACKET="$WORK/packet.md"
OUT="$WORK/t2.stdout"
ERR="$WORK/t2.stderr"
SID="cdt89-ac2-planted"
set +e
bash "$PREPASS" finalize \
  --uuid "$SID" \
  --events "$PLANTED" \
  --git-state "$GITBLOB" \
  --leaf "leaf-ac2-planted" \
  --slug ac2-planted \
  --mode cold \
  --packet-out "$PACKET" \
  >"$OUT" 2>"$ERR"
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$PACKET" ]; then ok
else bad "T2 finalize rc=$RC err=$(head -c 200 "$ERR")"; fi

if grep -q '## State now' "$PACKET" \
   && grep -q '## Through-line' "$PACKET" \
   && grep -q '## appendix' "$PACKET"; then ok
else bad "T2 missing STM headers"; fi

# ---- T3: packet retains planted killed / ruling / open markers ----
# Markers are unique substrings from events-merged-planted (mine-path contract).
need_kill='AC2-KILL: dual full-spine miners waste tokens'
need_ruling='AC2-RULING: one merged miner only'
need_open='AC2-OPEN: does chunked path still one-read'
if grep -Fq "$need_kill" "$PACKET"; then ok
else bad "T3 packet missing killed marker"; fi
if grep -Fq "$need_ruling" "$PACKET"; then ok
else bad "T3 packet missing ruling marker"; fi
if grep -Fq "$need_open" "$PACKET"; then ok
else bad "T3 packet missing open marker"; fi

# Kind labels present for the three AC2 kinds
if grep -qE '\*\*killed\*\*' "$PACKET" \
   && grep -qE '\*\*ruling\*\*' "$PACKET" \
   && grep -qE '\*\*open\*\*' "$PACKET"; then ok
else bad "T3 packet missing kind labels killed/ruling/open"; fi

# ---- T4: bonus planted kinds survive (hyp + decision; conflict in through-line body) ----
if grep -Fq 'AC2-HYP:' "$PACKET" \
   && grep -Fq 'AC2-DEC:' "$PACKET" \
   && grep -Fq 'AC2-CONFLICT:' "$PACKET"; then ok
else bad "T4 secondary planted markers missing"; fi

# ---- T5: spine fixture documents planted thrash (source of golden events) ----
if grep -q 'AC2-KILL' "$SPINE" \
   && grep -q 'AC2-RULING' "$SPINE" \
   && grep -q 'AC2-OPEN' "$SPINE"; then ok
else bad "T5 spine-mineable-mini missing planted thrash cues"; fi

# ---- T6: CDT-93 — load_events namespaces planted ids; union unique ----
if python3 -c '
import sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a
evs = a.load_events("'"$PLANTED"'")
ids = [e["id"] for e in evs]
assert len(ids) == len(set(ids)), ids
assert all(":" in i for i in ids), ids
stems = {i.split(":", 1)[0] for i in ids}
assert "through_line" in stems and "state" in stems, stems
assert {e.get("_raw_id") for e in evs} == {"p1","p2","p3","p4","p5","p6","p7"}
print("ok")
' 2>/dev/null | grep -q ok; then ok
else bad "T6 planted load_events union uniqueness"; fi

echo
echo "merged-miner-ac2-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
