#!/usr/bin/env bash
# finalize-test.sh — CDT-79-3/8 prepass finalize / cache STM packet (SPEC-018 M3d/M7/M8/M11).
# Coverage: cold core+path (T2), cache packet field (T3), HIT serves packet (T4),
# Supersedes second capture (T11), no legacy section-assembly finalize (T9),
# light draft Supersedes tip (T26 / CDT-91 M10c test 32).
# Run: bash skills/handoff/finalize-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/finalize-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SID="cdt79-finalize-test"
LEAF="leaf-uuid-fixture-001"
export HANDOFF_DIR="$WORK/handoff"
mkdir -p "$HANDOFF_DIR"

# ---- T0: fixtures ----
if [ -f "$THRASH" ] && [ -f "$GITBLOB" ] && [ -x "$PREPASS" ]; then ok
else bad "T0 missing fixtures or prepass"; fi

# ---- T1: finalize cold → packet file with three STM headers ----
PACKET="$WORK/packet.md"
OUT="$WORK/t1.stdout"
ERR="$WORK/t1.stderr"
set +e
bash "$PREPASS" finalize \
  --uuid "$SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "$LEAF" \
  --slug thrash-stm \
  --mode cold \
  --packet-out "$PACKET" \
  >"$OUT" 2>"$ERR"
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$PACKET" ]; then ok
else bad "T1 finalize rc=$RC packet_exists=$([ -f "$PACKET" ] && echo y || echo n) err=$(head -c 200 "$ERR")"; fi

if grep -q '## State now' "$PACKET" \
   && grep -q '## Through-line' "$PACKET" \
   && grep -q '## appendix' "$PACKET"; then ok
else bad "T1 packet missing STM headers"; fi

# order: State now before Through-line before appendix
ORDER=$(python3 -c '
import sys
t=open(sys.argv[1]).read()
i1,i2,i3=t.find("## State now"),t.find("## Through-line"),t.find("## appendix")
print("ok" if 0<=i1<i2<i3 else f"bad {i1},{i2},{i3}")
' "$PACKET")
if [ "$ORDER" = "ok" ]; then ok; else bad "T1 header order: $ORDER"; fi

# ---- T2: cold stdout = core only + path cite; no full appendix dump ----
if grep -q '## State now' "$OUT" && grep -q '## Through-line' "$OUT"; then ok
else bad "T2 stdout missing core headers"; fi
if grep -q 'Full packet (appendix):' "$OUT"; then ok
else bad "T2 stdout missing path cite"; fi
# appendix body (git blob content) should not flood stdout
if grep -q '## appendix' "$OUT"; then
  bad "T2 stdout must not include ## appendix section"
else ok; fi
if grep -q 'abc1234 feat: example commit' "$OUT"; then
  bad "T2 git blob leaked into cold stdout"
else ok; fi

# ---- T3: cache written with packet field (not only legacy brief) ----
CACHE="$HANDOFF_DIR/cache/${SID}.json"
if [ -f "$CACHE" ]; then ok; else bad "T3 cache file missing: $CACHE"; fi
CACHE_OK=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
pkt=d.get("packet") or ""
ok = (
  d.get("leaf_uuid")==sys.argv[2]
  and isinstance(pkt,str) and "## State now" in pkt
  and isinstance(d.get("path"),str) and d["path"]
  and "brief" not in d  # new writes use packet only
)
print("ok" if ok else "bad "+json.dumps({k:type(d.get(k)).__name__ for k in ("leaf_uuid","packet","path","brief")}))
' "$CACHE" "$LEAF")
if [ "$CACHE_OK" = "ok" ]; then ok; else bad "T3 cache payload: $CACHE_OK"; fi

# ---- T4: cache-check HIT with --leaf → core + path, not full appendix ----
HIT_OUT="$WORK/t4.stdout"
set +e
bash "$PREPASS" cache-check --uuid "$SID" --leaf "$LEAF" >"$HIT_OUT" 2>"$WORK/t4.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ]; then ok; else bad "T4 cache-check HIT rc=$RC err=$(head -c 200 "$WORK/t4.stderr")"; fi
if grep -q '## State now' "$HIT_OUT" && grep -q '## Through-line' "$HIT_OUT" \
   && grep -q 'Full packet (appendix):' "$HIT_OUT"; then ok
else bad "T4 HIT stdout shape"; fi
if grep -q '## appendix' "$HIT_OUT"; then
  bad "T4 HIT must not dump ## appendix"
else ok; fi

# ---- T5: leaf mismatch → MISS exit 10 ----
set +e
bash "$PREPASS" cache-check --uuid "$SID" --leaf "other-leaf" >/dev/null 2>"$WORK/t5.stderr"
RC=$?
set -e
if [ "$RC" -eq 10 ]; then ok; else bad "T5 leaf mismatch want 10 got $RC"; fi

# ---- T6: warm mode → file written, stdout empty (no core inject) ----
WARM_PKT="$WORK/warm-packet.md"
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-warm" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-warm" \
  --mode warm \
  --packet-out "$WARM_PKT" \
  >"$WORK/t6.stdout" 2>"$WORK/t6.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$WARM_PKT" ] && [ ! -s "$WORK/t6.stdout" ]; then ok
else bad "T6 warm file-only rc=$RC out_bytes=$(wc -c <"$WORK/t6.stdout")"; fi
# CDT-85: warm packet header ties mode + session id (not freeform live-context)
if grep -q 'mode: warm' "$WARM_PKT" \
   && grep -q "session: ${SID}-warm" "$WARM_PKT" \
   && grep -qE '^_mode: warm' "$WARM_PKT"; then ok
else bad "T6b warm mode/session header missing: $(head -5 "$WARM_PKT")"; fi

# ---- T7: events dir contract (miner dir of *.json) ----
EDIR="$WORK/events-dir"
mkdir -p "$EDIR"
# split thrash into two miner-like files
python3 -c '
import json,sys
from pathlib import Path
d=json.load(open(sys.argv[1]))
evs=d["events"] if isinstance(d,dict) else d
mid=len(evs)//2
Path(sys.argv[2],"through_line.json").write_text(json.dumps({"events":evs[:mid]}))
Path(sys.argv[2],"state.json").write_text(json.dumps({"events":evs[mid:]}))
' "$THRASH" "$EDIR"
DIR_PKT="$WORK/dir-packet.md"
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-dir" \
  --events "$EDIR" \
  --git-state "$GITBLOB" \
  --leaf "leaf-dir" \
  --mode cold \
  --packet-out "$DIR_PKT" \
  >"$WORK/t7.stdout" 2>"$WORK/t7.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q '## State now' "$DIR_PKT" && grep -q '## Through-line' "$DIR_PKT"; then ok
else bad "T7 events dir rc=$RC err=$(head -c 200 "$WORK/t7.stderr")"; fi

# ---- T8: legacy brief dual-read on cache-check ----
LEGACY_SID="cdt79-legacy-brief"
mkdir -p "$HANDOFF_DIR/cache"
python3 -c '
import json, sys
from pathlib import Path
pkt = "# Session handoff — STM\n\n## State now\n- decision: keep dual-read\n\n## Through-line\n- ruling: ok\n\n## appendix\n- git: none\n"
Path(sys.argv[1]).write_text(json.dumps({
  "leaf_uuid": "leg-leaf",
  "brief": pkt,
  "path": "/tmp/legacy-packet.md",
}))
' "$HANDOFF_DIR/cache/${LEGACY_SID}.json"
set +e
bash "$PREPASS" cache-check --uuid "$LEGACY_SID" --leaf "leg-leaf" \
  >"$WORK/t8.stdout" 2>"$WORK/t8.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q '## State now' "$WORK/t8.stdout" \
   && grep -q 'Full packet (appendix):' "$WORK/t8.stdout"; then ok
else bad "T8 legacy brief dual-read rc=$RC"; fi

# ---- T9: legacy section-assembly finalize path removed from prepass ----
# (retired M4 brief assembly: no section-spec constant, no dead_ends/open_threads,
#  no --sections flag). Split tokens so suite rg for retired symbols stays clean.
if ! grep -qE 'dead_ends|open_threads' "$PREPASS" \
   && ! grep -q -- '--sections' "$PREPASS" \
   && python3 -c 'import pathlib,sys; t=pathlib.Path(sys.argv[1]).read_text(); sys.exit(0 if ("SECTION"+"_SPEC") not in t else 1)' "$PREPASS"; then ok
else bad "T9 residual legacy finalize assembly paths in prepass.sh"; fi

# ---- T10: auto packet path under HANDOFF_DIR when no --packet-out ----
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-auto" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-auto" \
  --slug auto-slug \
  --mode warm \
  >"$WORK/t10.stdout" 2>"$WORK/t10.stderr"
RC=$?
set -e
AUTO=$(find "$HANDOFF_DIR" -maxdepth 1 -name "*-${SID}-auto-auto-slug.md" | head -1)
if [ "$RC" -eq 0 ] && [ -n "$AUTO" ] && [ -f "$AUTO" ]; then ok
else bad "T10 auto path rc=$RC auto=$AUTO err=$(head -c 200 "$WORK/t10.stderr")"; fi

# ---- T11: auto Supersedes on same-session re-capture (M11 / CDT-79-6) ----
SS_SID="cdt79-supersedes"
set +e
bash "$PREPASS" finalize \
  --uuid "$SS_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-ss-1" \
  --slug tip \
  --mode warm \
  >"$WORK/t11a.stdout" 2>"$WORK/t11a.stderr"
RC1=$?
set -e
FIRST=$(find "$HANDOFF_DIR" -maxdepth 1 -name "*-${SS_SID}-tip.md" ! -name '*-precompact-*' | head -1)
# Ensure second write is a distinct path even in the same minute (collision -N or mtime)
sleep 1
set +e
bash "$PREPASS" finalize \
  --uuid "$SS_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-ss-2" \
  --slug tip \
  --mode warm \
  >"$WORK/t11b.stdout" 2>"$WORK/t11b.stderr"
RC2=$?
set -e
# Second packet: any *-${SS_SID}-tip*.md newer / not equal to FIRST
SECOND=""
for f in "$HANDOFF_DIR"/*-"${SS_SID}"-tip*.md; do
  [ -f "$f" ] || continue
  [ "$f" = "$FIRST" ] && continue
  SECOND="$f"
done
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ -n "$FIRST" ] && [ -n "$SECOND" ] \
   && grep -q "Supersedes: $(basename -- "$FIRST")" "$SECOND"; then ok
else
  bad "T11 supersedes rc1=$RC1 rc2=$RC2 first=$FIRST second=$SECOND body=$(head -c 300 "$SECOND" 2>/dev/null)"
fi

# ---- T12: precompact artifacts excluded from Supersedes scan ----
PC_SID="cdt79-rescue-skip"
# Fake a precompact rescue that must NOT become Supersedes tip
# (name: <session_id>-precompact-<n>.md — no YYYYMMDD-HHmm prefix)
printf '# rescue\n' >"$HANDOFF_DIR/${PC_SID}-precompact-1.md"
# Also a real prior packet (timestamped STM name)
printf '# prior\n## State now\n- x\n' >"$HANDOFF_DIR/20260101-0000-${PC_SID}-prior.md"
set +e
bash "$PREPASS" finalize \
  --uuid "$PC_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-pc" \
  --slug next \
  --mode warm \
  >"$WORK/t12.stdout" 2>"$WORK/t12.stderr"
RC=$?
set -e
PC_PKT=$(find "$HANDOFF_DIR" -maxdepth 1 -name "*-${PC_SID}-next.md" | head -1)
SUP_LINE=$(grep '^Supersedes:' "$PC_PKT" 2>/dev/null | head -1 || true)
if [ "$RC" -eq 0 ] && [ -n "$PC_PKT" ] \
   && [ "$SUP_LINE" = "Supersedes: 20260101-0000-${PC_SID}-prior.md" ]; then ok
else bad "T12 precompact skip rc=$RC pkt=$PC_PKT supersedes=$SUP_LINE"; fi

# ---- T13: slug sanitize [a-z0-9-]+ ≤40; dots/underscores → hyphens ----
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-slug" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-slug" \
  --slug 'Hello_World.Test!!' \
  --mode warm \
  >"$WORK/t13.stdout" 2>"$WORK/t13.stderr"
RC=$?
set -e
SLUG_PKT=$(find "$HANDOFF_DIR" -maxdepth 1 -name "*-${SID}-slug-hello-world-test.md" | head -1)
if [ "$RC" -eq 0 ] && [ -n "$SLUG_PKT" ]; then ok
else bad "T13 slug sanitize rc=$RC pkt=$(ls "$HANDOFF_DIR"/*-${SID}-slug* 2>/dev/null)"; fi

# empty / garbage slug → stm
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-slug2" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-slug2" \
  --slug '!!!' \
  --mode warm \
  >"$WORK/t13b.stdout" 2>"$WORK/t13b.stderr"
RC=$?
set -e
STM_PKT=$(find "$HANDOFF_DIR" -maxdepth 1 -name "*-${SID}-slug2-stm.md" | head -1)
if [ "$RC" -eq 0 ] && [ -n "$STM_PKT" ]; then ok
else bad "T13b fallback stm rc=$RC"; fi

# ---- T14: auto filename matches YYYYMMDD-HHmm-session-slug.md ----
BASE=$(basename -- "$AUTO")
if printf '%s' "$BASE" | grep -Eq '^[0-9]{8}-[0-9]{4}-'"${SID}"'-auto-auto-slug\.md$'; then ok
else bad "T14 filename shape: $BASE"; fi

# ---- T15: cold path must not document allow-in-progress as cold PREPARE_EXTRA ----
# Guard: commands/handoff.md cold PREPARE_EXTRA empty; warm alone sets the flag.
CMD_HANDOFF=$(CDPATH= cd -- "$HERE/../../commands" 2>/dev/null && pwd)/handoff.md
if [ ! -f "$CMD_HANDOFF" ]; then
  CMD_HANDOFF="$HERE/../../commands/handoff.md"
fi
if [ -f "$CMD_HANDOFF" ] \
   && grep -q 'PREPARE_EXTRA=()' "$CMD_HANDOFF" \
   && grep -q 'PREPARE_EXTRA=(--transcript "$TRANSCRIPT" --allow-in-progress)' "$CMD_HANDOFF" \
   && grep -q 'Cold.*MUST NOT\|never.*--allow-in-progress.*cold\|no --transcript, no --allow-in-progress' "$CMD_HANDOFF"; then ok
else bad "T15 cold carve-out docs missing in commands/handoff.md"; fi

# ---- T16: --spine-tokens present → ratio footer (CDT-83 AC1/AC3/AC4) ----
RATIO_PKT="$WORK/ratio-packet.md"
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-ratio" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-ratio" \
  --mode cold \
  --spine-tokens 4000 \
  --packet-out "$RATIO_PKT" \
  >"$WORK/t16.stdout" 2>"$WORK/t16.stderr"
RC=$?
set -e
FOOT=$(grep -E 'packet_tokens' "$RATIO_PKT" | tail -1 || true)
if [ "$RC" -eq 0 ] \
   && printf '%s' "$FOOT" | grep -Eq \
     '^packet_tokens / stripped_spine_tokens: [0-9]+ / 4000 \(ratio [0-9]+\.[0-9]{3}, advisory\)$'; then ok
else bad "T16 cold ratio footer rc=$RC foot=$FOOT err=$(head -c 120 "$WORK/t16.stderr")"; fi

# ---- T17: warm + spine-tokens → same ratio form (CDT-83 AC2) ----
WARM_RATIO="$WORK/warm-ratio.md"
set +e
bash "$PREPASS" finalize \
  --uuid "${SID}-warm-ratio" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-warm-ratio" \
  --mode warm \
  --spine-tokens 2500 \
  --packet-out "$WARM_RATIO" \
  >"$WORK/t17.stdout" 2>"$WORK/t17.stderr"
RC=$?
set -e
WFOOT=$(grep -E 'packet_tokens' "$WARM_RATIO" | tail -1 || true)
if [ "$RC" -eq 0 ] \
   && printf '%s' "$WFOOT" | grep -Eq \
     '^packet_tokens / stripped_spine_tokens: [0-9]+ / 2500 \(ratio [0-9]+\.[0-9]{3}, advisory\)$'; then ok
else bad "T17 warm ratio footer rc=$RC foot=$WFOOT"; fi

# ---- T18: stats unavailable → packet_tokens only; success (CDT-83 AC5) ----
# T1 packet was finalized without --spine-tokens
UFOOT=$(grep -E 'packet_tokens' "$PACKET" | tail -1 || true)
if printf '%s' "$UFOOT" | grep -Eq '^packet_tokens: [0-9]+ \(advisory\)$' \
   && ! grep -q 'stripped_spine_tokens' "$PACKET"; then ok
else bad "T18 unavailable footer shape: $UFOOT"; fi

# ---- T19: production path wires plan.json est_tokens → --spine-tokens (AC6) ----
# T2 stub: parent no longer inlines FIN_ARGS. Spawn payload names
# HANDOFF_SPINE_TOKENS; prepass.sh finalize still forwards the flag.
if [ -f "$CMD_HANDOFF" ] \
   && grep -q 'est_tokens' "$CMD_HANDOFF" \
   && grep -q 'HANDOFF_SPINE_TOKENS=…' "$CMD_HANDOFF" \
   && grep -q 'HANDOFF_SPINE_TOKENS' "$HERE/SKILL.md" \
   && grep -q -- '--spine-tokens "$SPINE_TOKENS"' "$PREPASS"; then ok
else bad "T19 missing est_tokens / spawn HANDOFF_SPINE_TOKENS / prepass --spine-tokens wiring"; fi

# ---- T20: CDT-88 M8b cache events write/read (stem map, raw ids) ----
# T1 finalize with thrash + leaf → cache must include non-empty events map.
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert "events" in d, "missing events key"
ev = d["events"]
assert isinstance(ev, dict) and ev, ev
n = 0
for stem, arr in ev.items():
    assert isinstance(stem, str) and stem.strip(), stem
    assert isinstance(arr, list) and arr, stem
    for e in arr:
        assert isinstance(e, dict) and "id" in e and "kind" in e, e
        # raw miner ids only — no prior: / stem: prefix
        eid = e["id"]
        assert not str(eid).startswith("prior:"), eid
        assert ":" not in str(eid) or not str(eid).startswith(stem + ":"), eid
        assert "_generation" not in e and "_src_index" not in e
        assert "_raw_id" not in e and "_labels" not in e
        n += 1
assert n >= 1, n
# dual-read: load_prior_events namespaces prior:stem:raw
sys.path.insert(0, sys.argv[2])
import assemble as a
prior = a.load_prior_events(sys.argv[1])
assert prior and all(e["id"].startswith("prior:") for e in prior)
assert all(e.get("_generation") == 0 for e in prior)
assert not any("prior:prior:" in e["id"] for e in prior)
print("ok")
' "$CACHE" "$HERE" 2>"$WORK/t20.err" | grep -q ok; then ok
else bad "T20 cache events write/read: $(head -c 300 "$WORK/t20.err")"; fi

# ---- T21: CDT-88 empty/unusable FINALIZE_EVENTS_JSON → omit events key ----
OMIT_SID="${SID}-omit-events"
OMIT_PKT="$WORK/omit-packet.md"
EMPTY_EV="$WORK/empty-events.json"
printf '%s\n' '{}' >"$EMPTY_EV"
set +e
FINALIZE_EVENTS_JSON="$EMPTY_EV" \
bash "$PREPASS" finalize \
  --uuid "$OMIT_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-omit" \
  --mode cold \
  --packet-out "$OMIT_PKT" \
  >"$WORK/t21.stdout" 2>"$WORK/t21.stderr"
RC=$?
set -e
OMIT_CACHE="$HANDOFF_DIR/cache/${OMIT_SID}.json"
if [ "$RC" -eq 0 ] && [ -f "$OMIT_CACHE" ] \
   && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert "events" not in d, list(d.keys())
assert d.get("leaf_uuid")=="leaf-omit"
assert isinstance(d.get("packet"),str) and "## State now" in d["packet"]
print("ok")
' "$OMIT_CACHE" 2>/dev/null | grep -q ok \
   && grep -q 'events=omit' "$WORK/t21.stderr"; then ok
else bad "T21 omit empty events rc=$RC cache=$(head -c 200 "$OMIT_CACHE" 2>/dev/null) err=$(head -c 200 "$WORK/t21.stderr")"; fi

# null / empty list events wrapper also omits
NULL_EV="$WORK/null-events.json"
printf '%s\n' '{"events": null}' >"$NULL_EV"
NULL_SID="${SID}-null-events"
set +e
FINALIZE_EVENTS_JSON="$NULL_EV" \
bash "$PREPASS" finalize \
  --uuid "$NULL_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-null" \
  --mode cold \
  --packet-out "$WORK/null-pkt.md" \
  >"$WORK/t21b.stdout" 2>"$WORK/t21b.stderr"
RC=$?
set -e
NULL_CACHE="$HANDOFF_DIR/cache/${NULL_SID}.json"
if [ "$RC" -eq 0 ] && [ -f "$NULL_CACHE" ] \
   && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "events" not in d; print("ok")' \
        "$NULL_CACHE" 2>/dev/null | grep -q ok; then ok
else bad "T21 null events wrapper still has key"; fi

# ---- T22: CDT-88 legacy cache without events → cache-check HIT still (dual-read) ----
LEGACY_NOEV="${SID}-legacy-noev"
LEGACY_NOEV_LEAF="leg-noev-leaf"
mkdir -p "$HANDOFF_DIR/cache"
python3 -c '
import json, sys
# packet-only cache (pre-M8b shape): no events key
json.dump({
  "leaf_uuid": sys.argv[2],
  "packet": "## State now\n\n- **decision**: legacy no-events packet\n\n## Through-line\n\n## appendix\n",
  "path": "/tmp/legacy-noev.md",
  "created_at": "2026-07-01T00:00:00Z",
}, open(sys.argv[1], "w"))
' "$HANDOFF_DIR/cache/${LEGACY_NOEV}.json" "$LEGACY_NOEV_LEAF"
set +e
bash "$PREPASS" cache-check --uuid "$LEGACY_NOEV" --leaf "$LEGACY_NOEV_LEAF" \
  >"$WORK/t22.stdout" 2>"$WORK/t22.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && grep -q 'legacy no-events packet' "$WORK/t22.stdout" \
   && python3 -c 'import json; d=json.load(open("'"$HANDOFF_DIR"'/cache/'"$LEGACY_NOEV"'.json")); assert "events" not in d'; then ok
else bad "T22 legacy no-events HIT rc=$RC out=$(head -c 200 "$WORK/t22.stdout") err=$(head -c 200 "$WORK/t22.stderr")"; fi

# ---- T23: CDT-91 M10c light finalize → *-draft.md packet, no M8 cache ----
# Auto path (no --packet-out): ends with -draft.md; cache/$SID.json absent.
LIGHT_SID="${SID}-light"
set +e
bash "$PREPASS" finalize \
  --uuid "$LIGHT_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-light-001" \
  --slug light-stm \
  --mode warm \
  --light \
  >"$WORK/t23.stdout" 2>"$WORK/t23.stderr"
RC=$?
set -e
LIGHT_DRAFT=""
for f in "$HANDOFF_DIR"/*-"${LIGHT_SID}"-*-draft.md; do
  [ -f "$f" ] && LIGHT_DRAFT="$f" && break
done
LIGHT_CACHE="$HANDOFF_DIR/cache/${LIGHT_SID}.json"
if [ "$RC" -eq 0 ] && [ -n "$LIGHT_DRAFT" ] && [ -f "$LIGHT_DRAFT" ] \
   && [ ! -e "$LIGHT_CACHE" ] \
   && grep -q '## State now' "$LIGHT_DRAFT" \
   && grep -q 'cached=NO' "$WORK/t23.stderr" \
   && grep -q 'light=1' "$WORK/t23.stderr"; then ok
else bad "T23 light draft/no-cache rc=$RC draft=${LIGHT_DRAFT:-none} cache_exists=$([ -e "$LIGHT_CACHE" ] && echo y || echo n) err=$(head -c 300 "$WORK/t23.stderr")"; fi
# basename must end with -draft.md (stable triage token)
if [ -n "$LIGHT_DRAFT" ] && basename -- "$LIGHT_DRAFT" | grep -qE -- '-draft\.md$'; then ok
else bad "T23 draft basename not *-draft.md: $(basename -- "${LIGHT_DRAFT:-}")"; fi

# ---- T24: HANDOFF_LIGHT=1 env alone enables light (no --light flag) ----
LIGHT_ENV_SID="${SID}-light-env"
set +e
HANDOFF_LIGHT=1 bash "$PREPASS" finalize \
  --uuid "$LIGHT_ENV_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-light-env" \
  --slug light-env \
  --mode warm \
  >"$WORK/t24.stdout" 2>"$WORK/t24.stderr"
RC=$?
set -e
LIGHT_ENV_DRAFT=""
for f in "$HANDOFF_DIR"/*-"${LIGHT_ENV_SID}"-*-draft.md; do
  [ -f "$f" ] && LIGHT_ENV_DRAFT="$f" && break
done
LIGHT_ENV_CACHE="$HANDOFF_DIR/cache/${LIGHT_ENV_SID}.json"
if [ "$RC" -eq 0 ] && [ -n "$LIGHT_ENV_DRAFT" ] && [ -f "$LIGHT_ENV_DRAFT" ] \
   && [ ! -e "$LIGHT_ENV_CACHE" ]; then ok
else bad "T24 HANDOFF_LIGHT=1 rc=$RC draft=${LIGHT_ENV_DRAFT:-none} cache_exists=$([ -e "$LIGHT_ENV_CACHE" ] && echo y || echo n) err=$(head -c 200 "$WORK/t24.stderr")"; fi

# ---- T25: bare warm (no light) still writes cache (regression vs T23) ----
WARM_SID="${SID}-warm-reg"
set +e
bash "$PREPASS" finalize \
  --uuid "$WARM_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-warm-reg" \
  --slug warm-reg \
  --mode warm \
  --packet-out "$WORK/warm-reg.md" \
  >"$WORK/t25.stdout" 2>"$WORK/t25.stderr"
RC=$?
set -e
WARM_CACHE="$HANDOFF_DIR/cache/${WARM_SID}.json"
if [ "$RC" -eq 0 ] && [ -f "$WORK/warm-reg.md" ] && [ -f "$WARM_CACHE" ]; then ok
else bad "T25 bare warm cache regression rc=$RC packet=$([ -f "$WORK/warm-reg.md" ] && echo y || echo n) cache=$([ -f "$WARM_CACHE" ] && echo y || echo n) err=$(head -c 200 "$WORK/t25.stderr")"; fi

# ---- T26: CDT-91 / SPEC-018 test 32 — light draft eligible Supersedes tip ----
# discover_supersedes includes …-draft.md (unlike precompact rescues).
# 1) light draft path is eligible tip for same session uuid
# 2) full second capture sets Supersedes: <draft basename>
# 3) precompact still skipped (planted rescue must not win)
SD_SID="cdt91-supersedes-draft"
set +e
bash "$PREPASS" finalize \
  --uuid "$SD_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-sd-draft" \
  --slug draft-tip \
  --mode warm \
  --light \
  >"$WORK/t26a.stdout" 2>"$WORK/t26a.stderr"
RC1=$?
set -e
SD_DRAFT=""
for f in "$HANDOFF_DIR"/*-"${SD_SID}"-*-draft.md; do
  [ -f "$f" ] && SD_DRAFT="$f" && break
done
# Plant precompact rescue that must NOT become tip (same exclusion as T12)
printf '# rescue\n' >"$HANDOFF_DIR/${SD_SID}-precompact-1.md"
sleep 1
set +e
bash "$PREPASS" finalize \
  --uuid "$SD_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-sd-full" \
  --slug full-tip \
  --mode warm \
  >"$WORK/t26b.stdout" 2>"$WORK/t26b.stderr"
RC2=$?
set -e
SD_FULL=""
for f in "$HANDOFF_DIR"/*-"${SD_SID}"-full-tip.md; do
  [ -f "$f" ] || continue
  [ "$f" = "$SD_DRAFT" ] && continue
  SD_FULL="$f"
done
# Collision path: full-tip.md vs full-tip-N.md
if [ -z "$SD_FULL" ]; then
  for f in "$HANDOFF_DIR"/*-"${SD_SID}"-full-tip*.md; do
    [ -f "$f" ] || continue
    case "$(basename -- "$f")" in
      *-draft.md|*-draft-*.md) continue ;;
    esac
    SD_FULL="$f"
  done
fi
SD_DRAFT_BASE=$(basename -- "${SD_DRAFT:-}")
SUP_LINE=$(grep '^Supersedes:' "$SD_FULL" 2>/dev/null | head -1 || true)
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] \
   && [ -n "$SD_DRAFT" ] && [ -f "$SD_DRAFT" ] \
   && basename -- "$SD_DRAFT" | grep -qE -- '-draft\.md$' \
   && [ -n "$SD_FULL" ] && [ -f "$SD_FULL" ] \
   && [ "$SUP_LINE" = "Supersedes: $SD_DRAFT_BASE" ] \
   && ! printf '%s' "$SUP_LINE" | grep -q precompact; then ok
else
  bad "T26 light draft supersedes rc1=$RC1 rc2=$RC2 draft=${SD_DRAFT:-none} full=${SD_FULL:-none} supersedes=$SUP_LINE"
fi

echo
echo "finalize-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
