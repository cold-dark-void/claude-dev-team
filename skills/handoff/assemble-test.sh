#!/usr/bin/env bash
# assemble-test.sh — SPEC-018 M3c/M3d STM packet assemble (CDT-79-2 / CDT-79-8).
# Coverage: invent-guard (T4), section order State now→Through-line→appendix (T1),
# print-core shape (T11), Supersedes header (T7).
# Run: bash skills/handoff/assemble-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
ASM="$HERE/assemble.py"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"
ANN="$FIX/annotations-sample.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/assemble-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- T0: fixtures + module import ----
if [ ! -f "$ASM" ]; then bad "missing assemble.py"; else ok; fi
if [ ! -f "$THRASH" ]; then bad "missing events-thrash.json"; else ok; fi
if [ ! -f "$GITBLOB" ]; then bad "missing git-state.txt"; else ok; fi
if python3 -c "import sys; sys.path.insert(0,'$HERE'); import assemble as a; assert len(a.EVENT_KINDS)==7; assert a.QUOTE_MAX==200" 2>/dev/null; then
  ok
else
  bad "T0 import EVENT_KINDS/QUOTE_MAX"
fi

# ---- T1: CLI thrash → packet; section order ----
OUT="$WORK/packet.md"
if python3 "$ASM" \
    --events "$THRASH" \
    --git "$GITBLOB" \
    --annotations "$ANN" \
    --spine-tokens 4000 \
    --session-uuid "sess-thrash" \
    --leaf-uuid "leaf-abc" \
    --slug "thrash" \
    --supersedes "20260720-1000-sess-thrash-stm.md" \
    --out "$OUT" 2>"$WORK/cli.err"; then
  ok
else
  bad "T1 CLI assemble failed: $(head -c 200 "$WORK/cli.err")"
fi

if [ -s "$OUT" ]; then ok; else bad "T1 empty packet"; fi

# section order: State now before Through-line before appendix
ORDER=$(python3 -c '
import re,sys
t=open(sys.argv[1]).read()
i1=t.find("## State now")
i2=t.find("## Through-line")
i3=t.find("## appendix")
print("ok" if 0<=i1<i2<i3 else f"bad {i1},{i2},{i3}")
' "$OUT")
if [ "$ORDER" = "ok" ]; then ok; else bad "T1 section order: $ORDER"; fi

# ---- T2: dedup — e5 and e5-dup same killed body → one kill line for that quote ----
KILL_N=$(python3 -c '
import re,sys
t=open(sys.argv[1]).read()
# count exact load-bearing kill quote once in through-line+catalog
q="killed: messageUuid is self-ref, not a pointer across files"
print(t.count(q))
' "$OUT")
if [ "$KILL_N" -ge 1 ] && [ "$KILL_N" -le 2 ]; then
  # once in Through-line + once in Kill catalog = 2 max
  ok
else
  bad "T2 dedup kill quote count=$KILL_N (want 1-2)"
fi

# python-level: dedup_events collapses to one
if python3 -c '
import json,sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
raw=json.load(open("'"$THRASH"'"))["events"]
evs=[a.validate_event(e) for e in raw]
evs=[e for e in evs if e]
evs=a.order_events([{**e,"_src_index":i} for i,e in enumerate(evs)])
d=a.dedup_events(evs)
# two identical killed bodies should collapse
kills=[e for e in d if e["kind"]=="killed" and "messageUuid" in a.event_body(e)]
assert len(kills)==1, kills
# duplicate hypothesis text e1/e15 collapse
hyps=[e for e in d if e["kind"]=="hypothesis" and "Race in cache" in a.event_body(e)]
assert len(hyps)==1, hyps
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T2 python dedup"; fi

# ---- T3: State now mechanical — alive hyps exclude killed; decisions+opens present ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a, json
raw=json.load(open("'"$THRASH"'"))["events"]
evs=[]
for i,r in enumerate(raw):
    e=a.validate_event(r)
    if e:
        e["_src_index"]=i
        evs.append(e)
evs=a.dedup_events(a.order_events(evs))
st=a.select_state_now(evs)
bodies=lambda xs: [a.normalize_text(a.event_body(e)) for e in xs]
# killed hyps must not appear in State now hypotheses
for b in bodies(st["hypotheses"]):
    assert "messageuuid" not in b or "cross-file" not in b
    assert "token budget hard-fail" not in b
# surviving hyps present
alive=" ".join(bodies(st["hypotheses"]))
assert "race in cache" in alive
assert "prepass drops sidechain" in alive
# decisions present
assert any("event-log mine" in a.event_body(e) for e in st["decisions"])
# all opens
assert len(st["opens"])>=2
# packet has State now subsections not freeform essay keys
t=open("'"$OUT"'").read()
assert "### Decisions" in t and "### Hypotheses (alive)" in t and "### Open" in t
assert "## Convergence" not in t and "## Dead ends" not in t
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T3 State now mechanical"; fi

# ---- T4: invent-guard — unknown event_id dropped; known labels applied ----
if grep -q '\[PRIORITY\]' "$OUT" && grep -q '\[INFERRED\]' "$OUT"; then ok
else bad "T4 known labels not applied"; fi
if grep -q 'e-does-not-exist' "$OUT"; then bad "T4 unknown event_id leaked"; else ok; fi
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs=[{"id":"e1","kind":"open","text":"x","workstream":"default","_src_index":0}]
evs=[a.validate_event(e) or e for e in evs]
anns=[{"event_id":"e1","labels":["OPEN"]},{"event_id":"nope","labels":["X"]}]
_, applied, dropped = a.apply_annotations(evs, anns)
assert applied==1 and dropped==1
assert "OPEN" in (evs[0].get("_labels") or [])
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T4 apply_annotations counts"; fi

# ---- T5: quote cap 200 ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
assert a.QUOTE_MAX==200
long="R"*250
assert len(a.truncate_quote(long))==200
assert a.truncate_quote(long).endswith("…")
assert a.truncate_quote("short")=="short"
ev={"id":"r1","kind":"ruling","quote":"Q"*300,"text":"t","workstream":"default","_src_index":0}
ev=a.validate_event(ev)
pkt=a.assemble_packet([ev])
# rendered body must not contain 201+ consecutive Q
import re
assert not re.search(r"Q{201,}", pkt), "over-cap quote leaked"
assert "Q"*50 in pkt  # still present truncated
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T5 quote cap"; fi

# ---- T6: footer ratio when spine_tokens provided ----
if grep -q 'packet_tokens / stripped_spine_tokens: ' "$OUT" \
   && grep -q '4000' "$OUT" \
   && grep -q 'advisory' "$OUT"; then ok
else bad "T6 footer ratio missing"; fi

# ---- T7: Supersedes header ----
if grep -q 'Supersedes: 20260720-1000-sess-thrash-stm.md' "$OUT"; then ok
else bad "T7 Supersedes header missing"; fi

# ---- T8: git blob accepted without live git ----
if grep -q 'abc1234 feat: example commit' "$OUT" \
   && grep -q '### Code state (git)' "$OUT"; then ok
else bad "T8 git blob not in appendix"; fi

# ---- T9: invalid kind / missing fields dropped (never invent) ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
assert a.validate_event({"id":"x","kind":"essay","text":"no"}) is None
assert a.validate_event({"id":"x","kind":"open"}) is None  # no text/quote
assert a.validate_event({"kind":"open","text":"no id"}) is None
assert a.validate_event({"id":"x","kind":"open","text":"ok"})["workstream"]=="default"
# 7 kinds only
assert len(a.EVENT_KINDS)==7
pkt=a.assemble_packet([
  {"id":"bad","kind":"nope","text":"x"},
  {"id":"g","kind":"open","text":"real open"},
])
assert "real open" in pkt
assert "nope" not in pkt
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T9 validate/drop"; fi

# ---- T10: multi-workstream through-line groups ----
if grep -q '### cache' "$OUT" && grep -q '### assemble' "$OUT"; then ok
else bad "T10 workstream groups missing"; fi

# ---- T11: --print-core omits appendix body ----
CORE="$WORK/core.md"
python3 "$ASM" --events "$THRASH" --git "$GITBLOB" --print-core --out "$CORE" >"$WORK/core.stdout" 2>/dev/null
if grep -q '## State now' "$WORK/core.stdout" \
   && grep -q '## Through-line' "$WORK/core.stdout" \
   && ! grep -q '## appendix' "$WORK/core.stdout" \
   && grep -q 'Full packet (appendix):' "$WORK/core.stdout"; then ok
else bad "T11 print-core shape"; fi

# ---- T12: normalize is casefold+whitespace for dedup only ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
assert a.normalize_text("  Foo   BAR ")=="foo bar"
a1=a.validate_event({"id":"1","kind":"fact","text":"Hello World"})
a2=a.validate_event({"id":"2","kind":"fact","text":"hello   world"})
a1["_src_index"]=0; a2["_src_index"]=1
d=a.dedup_events([a1,a2])
assert len(d)==1
assert d[0]["text"]=="Hello World"  # display original kept
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T12 normalize dedup"; fi

# ---- T13: dir of event files ----
mkdir -p "$WORK/evdir"
python3 -c '
import json, sys
d = sys.argv[1]
json.dump({"events":[{"id":"a","kind":"open","text":"from-a","order":1}]}, open(d+"/a.json","w"))
json.dump({"events":[{"id":"b","kind":"decision","text":"from-b","order":2}]}, open(d+"/b.json","w"))
' "$WORK/evdir"
if python3 "$ASM" --events "$WORK/evdir" --out "$WORK/dirpkt.md" 2>/dev/null \
   && grep -q 'from-a' "$WORK/dirpkt.md" \
   && grep -q 'from-b' "$WORK/dirpkt.md"; then ok
else bad "T13 dir events load"; fi

# ---- T14: no --spine-tokens → packet_tokens only (CDT-83 AC5/AC7) ----
NO_ST="$WORK/no-spine-tokens.md"
if python3 "$ASM" --events "$THRASH" --git "$GITBLOB" --out "$NO_ST" 2>/dev/null; then
  F=$(grep -E 'packet_tokens' "$NO_ST" | tail -1 || true)
  if printf '%s' "$F" | grep -Eq '^packet_tokens: [0-9]+ \(advisory\)$' \
     && ! grep -q 'stripped_spine_tokens' "$NO_ST"; then ok
  else bad "T14 unavailable footer: $F"
  fi
else
  bad "T14 assemble without --spine-tokens failed"
fi

# ---- T6 form check (present): exact advisory ratio shape (CDT-83 AC3) ----
if grep -Eq \
  '^packet_tokens / stripped_spine_tokens: [0-9]+ / 4000 \(ratio [0-9]+\.[0-9]{3}, advisory\)$' \
  "$OUT"; then ok
else bad "T6b exact ratio form: $(grep packet_tokens "$OUT" | tail -1)"
fi

# ---- T15: CDT-81 — transcript ref bare L<n> OR already-prefixed; never double ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
assert a.fmt_pointer({"type":"transcript","ref":"L977"}) == "transcript:L977"
assert a.fmt_pointer({"type":"transcript","ref":"977"}) == "transcript:L977"
assert a.fmt_pointer({"type":"transcript","ref":"transcript:L977"}) == "transcript:L977"
assert a.fmt_pointer({"type":"transcript","ref":"transcript:977"}) == "transcript:L977"
assert a.fmt_pointer({"type":"transcript","ref":"TRANSCRIPT:L42","note":"n"}) == "transcript:L42 (n)"
# bare fixture form still single-prefix
assert a.fmt_pointer({"type":"transcript","ref":"L1204","note":"user correction"}) == "transcript:L1204 (user correction)"
# no double-render substring
for ref in ("L977","transcript:L977","transcript:977"):
    tok = a.fmt_pointer({"type":"transcript","ref":ref})
    assert "transcript:Ltranscript:" not in tok, tok
    assert tok.count("transcript:") == 1, tok
# packet with prefixed miner ref must not double-render
ev = a.validate_event({
    "id":"p1","kind":"ruling",
    "quote":"stop doubling transcript pointers",
    "pointers":[{"type":"transcript","ref":"transcript:L977","note":"dogfood"}],
})
assert ev is not None
pkt = a.assemble_packet([ev])
assert "transcript:L977" in pkt
assert "transcript:Ltranscript:" not in pkt
assert pkt.count("transcript:L977") >= 1
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T15 CDT-81 transcript ref normalize"; fi

# thrash fixture (bare L1204) renders single prefix only
if grep -q 'transcript:L1204' "$OUT" \
   && ! grep -q 'transcript:Ltranscript:' "$OUT"; then ok
else bad "T15 thrash fixture double-prefix or missing L1204"; fi

# ---- T16: mode header honesty (CDT-85) — warm vs cold vs omit ----
MODE_W="$WORK/mode-warm.md"
MODE_C="$WORK/mode-cold.md"
MODE_O="$WORK/mode-omit.md"
if python3 "$ASM" --events "$THRASH" --session-uuid "m-warm" --mode warm --out "$MODE_W" 2>/dev/null \
   && grep -qE '^_mode: warm' "$MODE_W" \
   && grep -q '^mode: warm$' "$MODE_W" \
   && grep -q 'session: m-warm' "$MODE_W"; then ok
else bad "T16 warm mode header"; fi
if python3 "$ASM" --events "$THRASH" --session-uuid "m-cold" --mode cold --out "$MODE_C" 2>/dev/null \
   && grep -qE '^_mode: cold' "$MODE_C" \
   && grep -q '^mode: cold$' "$MODE_C"; then ok
else bad "T16 cold mode header"; fi
if python3 "$ASM" --events "$THRASH" --session-uuid "m-omit" --out "$MODE_O" 2>/dev/null \
   && ! grep -qE '^_mode:' "$MODE_O" \
   && ! grep -qE '^mode: (cold|warm)$' "$MODE_O"; then ok
else bad "T16 omit mode must not invent header"; fi

# ---- T17: CDT-93 display hygiene — pointer index uses _raw_id, not stem:id ----
# State now / Through-line / kill catalog never emit event ids (render_event_line);
# only appendix pointer index does — must strip namespace via _raw_id.
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$THRASH"'")
assert any(":" in e["id"] and e.get("_raw_id") for e in evs), "expected namespaced ids"
pkt = a.assemble_packet(evs, git_blob="x")
# namespaced form must not appear in user-facing packet text
for e in evs:
    assert e["id"] not in pkt, "namespaced id leaked: " + e["id"]
# raw ids appear only in pointer index lines
assert any(line.startswith("- e4:") for line in pkt.splitlines()), pkt
assert "### Pointers (courtesy)" in pkt
# State now / Through-line lines are kind-bodied, not id-prefixed
sn = pkt.split("## Through-line")[0]
assert "- **" in sn
assert not any(
    line.startswith("- e") and ":" in line.split(" ", 1)[0]
    for line in sn.splitlines()
    if line.startswith("- e")
)
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T17 pointer index display hygiene (_raw_id)"; fi

# multi-file dir: stem namespace internal only
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$WORK"'/evdir")
assert {e["id"] for e in evs} == {"a:a", "b:b"}
assert {e["_raw_id"] for e in evs} == {"a", "b"}
pkt = a.assemble_packet(evs)
# no events with pointers in evdir → no pointer index; still no stem leak in body
assert "a:a" not in pkt and "b:b" not in pkt
print("ok")
' 2>/dev/null | grep -q ok; then ok; else bad "T17b multi-file id not in packet body"; fi

# ---- T18: CDT-93 AC1 — cross-file bare-id collision + namespaced annotation ----
COLL_DIR="$FIX/events-id-collision"
COLL_ANN="$FIX/annotations-collision.json"
if [ -f "$COLL_DIR/through_line.json" ] && [ -f "$COLL_DIR/state.json" ] \
   && [ -f "$COLL_ANN" ]; then ok
else bad "T18 missing collision fixtures"; fi

if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$COLL_DIR"'")
ids = [e["id"] for e in evs]
assert len(ids) == len(set(ids)), ids
assert "through_line:e1" in ids
assert "state:e1" in ids
stems = {e["id"].split(":", 1)[0] for e in evs}
assert "through_line" in stems and "state" in stems, stems
raws = {e.get("_raw_id") for e in evs}
assert raws == {"e1"}, raws
# AC1: apply only happy namespaced annotation → TL labeled, state not
happy = [{"event_id": "through_line:e1", "labels": ["PRIORITY"], "rank": 1}]
_, applied, dropped = a.apply_annotations(evs, happy)
assert applied == 1 and dropped == 0
by = {e["id"]: e for e in evs}
assert "PRIORITY" in (by["through_line:e1"].get("_labels") or [])
assert not (by["state:e1"].get("_labels") or [])
print("ok")
' 2>/dev/null | grep -q ok; then ok
else bad "T18 AC1 collision load+label"; fi

# CLI packet: through_line body carries [PRIORITY]; state body does not; bare trap absent
COLL_PKT="$WORK/collision.md"
COLL_ERR="$WORK/collision.err"
if python3 "$ASM" \
    --events "$COLL_DIR" \
    --annotations "$COLL_ANN" \
    --session-uuid "coll-ac1" \
    --out "$COLL_PKT" 2>"$COLL_ERR"; then ok
else bad "T18 CLI collision assemble failed: $(head -c 200 "$COLL_ERR")"; fi

if python3 -c '
import sys
t=open(sys.argv[1]).read()
tl = [ln for ln in t.splitlines() if "COLLISION-TL" in ln]
st = [ln for ln in t.splitlines() if "COLLISION-ST" in ln]
assert tl and "[PRIORITY]" in tl[0], tl
assert st and "[PRIORITY]" not in st[0] and "[BARE_TRAP]" not in st[0], st
assert "[BARE_TRAP]" not in t
print("ok")
' "$COLL_PKT" 2>/dev/null | grep -q ok; then ok
else bad "T18 packet label targeting"; fi

# ---- T19: CDT-93 trap + happy — bare event_id dropped; namespaced lands ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$COLL_DIR"'")
anns = a.load_annotations("'"$COLL_ANN"'")
for e in evs:
    e.pop("_labels", None)
_, applied, dropped = a.apply_annotations(evs, anns)
assert applied == 1, applied
assert dropped == 1, dropped
by = {e["id"]: e for e in evs}
assert "PRIORITY" in (by["through_line:e1"].get("_labels") or [])
assert "BARE_TRAP" not in (by["through_line:e1"].get("_labels") or [])
assert not (by["state:e1"].get("_labels") or [])
print("ok")
' 2>"$WORK/t19.err" | grep -q ok; then ok
else bad "T19 apply counts: $(head -c 200 "$WORK/t19.err")"; fi

# stderr drop message for bare e1 (CLI path uses same annotations file)
if grep -q 'assemble: annotation drop unknown event_id: e1' "$COLL_ERR"; then ok
else bad "T19 missing bare drop on stderr: $(cat "$COLL_ERR")"; fi

# ---- T20: CDT-93 union uniqueness after load_events on collision dir ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$COLL_DIR"'")
ids = [e["id"] for e in evs]
assert len(ids) == len(set(ids)), ids
assert len(ids) >= 2
print("ok")
' 2>/dev/null | grep -q ok; then ok
else bad "T20 union uniqueness"; fi

# ---- summary ----
echo "assemble-test: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
