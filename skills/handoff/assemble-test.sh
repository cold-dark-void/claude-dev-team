#!/usr/bin/env bash
# assemble-test.sh — SPEC-018 M3c/M3d STM packet assemble (CDT-79-2 / CDT-79-8).
# Coverage: invent-guard (T4), section order State now→Through-line→appendix (T1),
# print-core shape (T11), Supersedes header (T7), Product surfaces + Open ship
# gaps in State now (T29–T31 / CDT-198).
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

# ---- T21: CDT-88 load_prior_events namespaces prior:stem:id, gen=0 ----
PRIOR_CACHE="$WORK/prior-cache.json"
python3 -c '
import json, sys
path = sys.argv[1]
json.dump({
  "leaf_uuid": "leaf-old",
  "events": {
    "through_line": [
      {"id": "p1", "kind": "decision", "text": "PRIOR decision keep me", "order": 99},
      {"id": "p2", "kind": "fact", "text": "PRIOR fact body unique", "order": 50}
    ],
    "state": [
      {"id": "s1", "kind": "open", "text": "PRIOR open item", "order": 10}
    ]
  }
}, open(path, "w"))
' "$PRIOR_CACHE"

if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_prior_events("'"$PRIOR_CACHE"'")
ids = sorted(e["id"] for e in evs)
assert ids == ["prior:state:s1", "prior:through_line:p1", "prior:through_line:p2"], ids
assert all(e.get("_generation") == 0 for e in evs)
assert {e["_raw_id"] for e in evs} == {"p1", "p2", "s1"}
# bare stem map
bare = a.load_prior_events  # reload via temp
import json, tempfile, os
p = "'"$WORK"'/prior-bare.json"
json.dump({"ws": [{"id": "x", "kind": "open", "text": "bare"}]}, open(p, "w"))
b = a.load_prior_events(p)
assert len(b) == 1 and b[0]["id"] == "prior:ws:x" and b[0]["_generation"] == 0
# missing / bad → soft empty
assert a.load_prior_events("'"$WORK"'/no-such-prior.json") == []
assert a.load_prior_events("") == []
print("ok")
' 2>"$WORK/t21.err" | grep -q ok; then ok
else bad "T21 load_prior_events: $(head -c 300 "$WORK/t21.err")"; fi

# ---- T22: CDT-88 order trap — both order=1; gen primary; State now tail=delta ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
# Trap: equal order fields must NOT put delta before prior (generation primary).
prior = [{
  "id": "prior:through_line:p1", "kind": "decision",
  "text": "old decision", "order": 1, "_generation": 0, "_src_index": 0,
  "_raw_id": "p1", "workstream": "default",
}]
delta = [{
  "id": "through_line:d1", "kind": "decision",
  "text": "new decision from delta", "order": 1, "_generation": 1,
  "_src_index": 0, "_raw_id": "d1", "workstream": "default",
}]
ordered = a.order_events(prior + delta)
assert ordered[0]["id"].startswith("prior:"), ordered
assert ordered[1]["id"] == "through_line:d1", ordered
# State now decisions from ordered log — tail is delta (latest)
st = a.select_state_now(ordered)
assert st["decisions"][-1]["id"] == "through_line:d1", st["decisions"]
assert st["decisions"][0]["id"].startswith("prior:"), st["decisions"]
# merge_events tags gen and preserves order trap
merged = a.merge_events(
  [{**prior[0]}],
  [{k: v for k, v in delta[0].items() if k != "_generation"}],
)
assert merged[0]["id"].startswith("prior:")
assert merged[-1]["id"] == "through_line:d1"
st2 = a.select_state_now(merged)
assert st2["decisions"][-1]["id"] == "through_line:d1"
print("ok")
' 2>"$WORK/t22.err" | grep -q ok; then ok
else bad "T22 order trap: $(head -c 300 "$WORK/t22.err")"; fi

# ---- T23: CDT-88 merge dedup keeps prior verbatim text ----
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
prior = a.load_prior_events("'"$PRIOR_CACHE"'")
# delta restates PRIOR decision with different wording case/spacing? exact body match:
delta = [{
  "id": "d1", "kind": "decision",
  "text": "PRIOR decision keep me", "order": 1,
}]
# namespace like load_events
delta[0] = a.validate_event(delta[0])
delta[0]["_raw_id"] = "d1"
delta[0]["id"] = "through_line:d1"
delta[0]["_src_index"] = 0
merged = a.merge_events(prior, delta)
# body match → one survivor, prior id kept
hits = [e for e in merged if a.normalize_text(a.event_body(e)) == a.normalize_text("PRIOR decision keep me")]
assert len(hits) == 1, hits
assert hits[0]["id"] == "prior:through_line:p1", hits[0]
assert hits[0]["text"] == "PRIOR decision keep me"
# unique delta-only would survive; unique prior too
assert any(e["id"] == "prior:through_line:p2" for e in merged)
print("ok")
' 2>"$WORK/t23.err" | grep -q ok; then ok
else bad "T23 merge prior-wins: $(head -c 300 "$WORK/t23.err")"; fi

# ---- T24: CDT-88 events-out stem map round-trip (raw ids) ----
DELTA_DIR="$WORK/delta-ev"
mkdir -p "$DELTA_DIR"
python3 -c '
import json, sys
d = sys.argv[1]
json.dump({"events":[
  {"id":"d1","kind":"decision","text":"delta only decision","order":1},
  {"id":"d2","kind":"fact","text":"PRIOR fact body unique","order":2}
]}, open(d+"/through_line.json","w"))
' "$DELTA_DIR"
EVENTS_OUT="$WORK/events-out.json"
PKT_MERGE="$WORK/merge-pkt.md"
if python3 "$ASM" \
    --events "$DELTA_DIR" \
    --prior-events "$PRIOR_CACHE" \
    --events-out "$EVENTS_OUT" \
    --session-uuid "merge-t24" \
    --out "$PKT_MERGE" 2>"$WORK/t24.err"; then ok
else bad "T24 CLI merge failed: $(head -c 200 "$WORK/t24.err")"; fi

if python3 -c '
import json, sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
m = json.load(open("'"$EVENTS_OUT"'"))
assert isinstance(m, dict)
# stems present; raw ids only (no prior: / stem: prefix on id)
for stem, arr in m.items():
    assert isinstance(arr, list), stem
    for ev in arr:
        assert ":" not in ev["id"] or not ev["id"].startswith("prior:"), ev
        assert not ev["id"].startswith(stem + ":"), ev
        assert "_generation" not in ev and "_src_index" not in ev
        assert "_raw_id" not in ev and "_labels" not in ev
# prior fact body unique collapsed with delta restatement → one fact
facts = [e for arr in m.values() for e in arr if e["kind"]=="fact" and "PRIOR fact" in e.get("text","")]
assert len(facts) == 1, facts
# round-trip: reload prior from events-out shape
rt = a.load_prior_events("'"$EVENTS_OUT"'")  # bare stem map
assert all(e["id"].startswith("prior:") for e in rt)
assert all(e["_generation"] == 0 for e in rt)
# no double prior:prior:
assert not any("prior:prior:" in e["id"] for e in rt)
print("ok")
' 2>"$WORK/t24b.err" | grep -q ok; then ok
else bad "T24 events-out shape: $(head -c 300 "$WORK/t24b.err")"; fi

# packet has prior decision + delta-only decision
if grep -q 'PRIOR decision keep me' "$PKT_MERGE" \
   && grep -q 'delta only decision' "$PKT_MERGE"; then ok
else bad "T24 merge packet missing prior/delta bodies"; fi

# ---- T25: CDT-88 no prior → cold identity (packet match baseline thrash) ----
# Strip captured_at (wall-clock) before compare; structure + body must match.
BASE_A="$WORK/cold-a.md"
BASE_B="$WORK/cold-b.md"
python3 "$ASM" \
    --events "$THRASH" \
    --git "$GITBLOB" \
    --annotations "$ANN" \
    --spine-tokens 4000 \
    --session-uuid "sess-thrash" \
    --leaf-uuid "leaf-abc" \
    --slug "thrash" \
    --supersedes "20260720-1000-sess-thrash-stm.md" \
    --out "$BASE_A" 2>/dev/null
# --events-out alone must not change packet body
python3 "$ASM" \
    --events "$THRASH" \
    --git "$GITBLOB" \
    --annotations "$ANN" \
    --spine-tokens 4000 \
    --session-uuid "sess-thrash" \
    --leaf-uuid "leaf-abc" \
    --slug "thrash" \
    --supersedes "20260720-1000-sess-thrash-stm.md" \
    --events-out "$WORK/cold-events-out.json" \
    --out "$BASE_B" 2>/dev/null
if python3 -c '
import re, sys
def norm(p):
    t = open(p).read()
    t = re.sub(r"captured_at: \S+", "captured_at: <TS>", t)
    return t
a, b, o = sys.argv[1], sys.argv[2], sys.argv[3]
na, nb, no = norm(a), norm(b), norm(o)
assert na == nb, "events-out drifted packet"
assert na == no, "cold re-run drifted from T1 thrash baseline"
# no prior flags in CLI → no prior: ids in body (none should appear)
assert "prior:" not in na
print("ok")
' "$BASE_A" "$BASE_B" "$OUT" 2>"$WORK/t25.err" | grep -q ok; then ok
else bad "T25 cold identity drift: $(head -c 200 "$WORK/t25.err")"; fi

# load_events must not force _generation
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$THRASH"'")
assert all("_generation" not in e for e in evs), "load_events forced generation"
# load_merged without prior == load_events ids
m = a.load_merged_events("'"$THRASH"'")
assert [e["id"] for e in m] == [e["id"] for e in evs]
m2 = a.load_merged_for_summary("'"$THRASH"'")
assert [e["id"] for e in m2] == [e["id"] for e in evs]
print("ok")
' 2>/dev/null | grep -q ok; then ok
else bad "T25 load_events gen / load_merged"; fi

# ---- T26: CDT-88 cross-gen ids — same bare tl-e1 → prior:… vs stem:…; invent-guard ----
XGEN_PRIOR="$WORK/xgen-prior.json"
XGEN_DELTA="$WORK/xgen-delta"
mkdir -p "$XGEN_DELTA"
python3 -c '
import json, sys
# Both gens bare miner id tl-e1 under through_line stem
json.dump({
  "leaf_uuid": "leaf-xgen",
  "events": {
    "through_line": [
      {"id": "tl-e1", "kind": "decision", "text": "cross-gen PRIOR body", "order": 1}
    ]
  }
}, open(sys.argv[1], "w"))
json.dump({"events": [
  {"id": "tl-e1", "kind": "decision", "text": "cross-gen DELTA body", "order": 1}
]}, open(sys.argv[2] + "/through_line.json", "w"))
' "$XGEN_PRIOR" "$XGEN_DELTA"

if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
prior = a.load_prior_events("'"$XGEN_PRIOR"'")
delta = a.load_events("'"$XGEN_DELTA"'")
assert [e["id"] for e in prior] == ["prior:through_line:tl-e1"], prior
assert [e["id"] for e in delta] == ["through_line:tl-e1"], delta
assert prior[0]["_raw_id"] == "tl-e1" and delta[0]["_raw_id"] == "tl-e1"
merged = a.merge_events(prior, delta)
ids = [e["id"] for e in merged]
assert "prior:through_line:tl-e1" in ids, ids
assert "through_line:tl-e1" in ids, ids
# distinct bodies → both survive dedup
assert len(merged) == 2, merged
# invent-guard: annotation on prior namespaced id lands; bare drops
anns = [
  {"event_id": "prior:through_line:tl-e1", "labels": ["FROM_PRIOR"]},
  {"event_id": "tl-e1", "labels": ["BARE_DROP"]},
  {"event_id": "through_line:tl-e1", "labels": ["FROM_DELTA"]},
]
_, applied, dropped = a.apply_annotations(merged, anns)
assert applied == 2, applied
assert dropped == 1, dropped
by = {e["id"]: e for e in merged}
assert "FROM_PRIOR" in (by["prior:through_line:tl-e1"].get("_labels") or [])
assert "BARE_DROP" not in (by["prior:through_line:tl-e1"].get("_labels") or [])
assert "BARE_DROP" not in (by["through_line:tl-e1"].get("_labels") or [])
assert "FROM_DELTA" in (by["through_line:tl-e1"].get("_labels") or [])
# load_merged_events same id space
m2 = a.load_merged_events("'"$XGEN_DELTA"'", prior="'"$XGEN_PRIOR"'")
assert {e["id"] for e in m2} == {"prior:through_line:tl-e1", "through_line:tl-e1"}
print("ok")
' 2>"$WORK/t26.err" | grep -q ok; then ok
else bad "T26 cross-gen ids: $(head -c 400 "$WORK/t26.err")"; fi

# CLI packet: both bodies present; labels via annotations file
XGEN_ANN="$WORK/xgen-ann.json"
python3 -c '
import json, sys
json.dump({"annotations": [
  {"event_id": "prior:through_line:tl-e1", "labels": ["FROM_PRIOR"]},
  {"event_id": "tl-e1", "labels": ["BARE_DROP"]},
]}, open(sys.argv[1], "w"))
' "$XGEN_ANN"
XGEN_PKT="$WORK/xgen-pkt.md"
XGEN_ERR="$WORK/xgen.err"
if python3 "$ASM" \
    --events "$XGEN_DELTA" \
    --prior-events "$XGEN_PRIOR" \
    --annotations "$XGEN_ANN" \
    --session-uuid "xgen-t26" \
    --out "$XGEN_PKT" 2>"$XGEN_ERR"; then ok
else bad "T26 CLI xgen failed: $(head -c 200 "$XGEN_ERR")"; fi

if grep -q 'cross-gen PRIOR body' "$XGEN_PKT" \
   && grep -q 'cross-gen DELTA body' "$XGEN_PKT" \
   && grep -q '\[FROM_PRIOR\]' "$XGEN_PKT" \
   && ! grep -q 'BARE_DROP' "$XGEN_PKT" \
   && grep -q 'assemble: annotation drop unknown event_id: tl-e1' "$XGEN_ERR"; then ok
else bad "T26 packet/labels/bare-drop: $(head -c 200 "$XGEN_ERR")"; fi

# ---- T27: CDT-91 light preset — meta light:true + honesty; mode stays warm ----
LIGHT_HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'
LIGHT_PKT="$WORK/light-warm.md"
LIGHT_OFF="$WORK/light-off.md"
if python3 "$ASM" --events "$THRASH" --session-uuid "light-s" --leaf-uuid "light-leaf" \
     --mode warm --light --out "$LIGHT_PKT" 2>/dev/null \
   && grep -qE '^_mode: warm · light: true' "$LIGHT_PKT" \
   && grep -q 'light: true' "$LIGHT_PKT" \
   && grep -qF "$LIGHT_HONESTY" "$LIGHT_PKT" \
   && grep -q '^mode: warm$' "$LIGHT_PKT" \
   && ! grep -qE 'mode: warm-light|UNMINED' "$LIGHT_PKT"; then ok
else bad "T27 light warm meta+honesty"; fi

# API: light=True on cold mode still keeps mode:cold (assemble does not invent warm-light)
if python3 -c '
import sys
sys.path.insert(0,"'"$HERE"'")
import assemble as a
evs = a.load_events("'"$THRASH"'")
pkt = a.assemble_packet(evs, mode="cold", light=True, session_uuid="lc", leaf_uuid="ll")
assert "mode: cold" in pkt
assert "light: true" in pkt
assert a.LIGHT_HONESTY in pkt
assert "warm-light" not in pkt
assert "UNMINED" not in pkt
# bare (no light): no light meta / honesty
pkt0 = a.assemble_packet(evs, mode="warm", session_uuid="w0")
assert "light: true" not in pkt0
assert a.LIGHT_HONESTY not in pkt0
print("ok")
' 2>/dev/null | grep -q ok; then ok
else bad "T27 light API mode preserve + bare omit"; fi

# CLI without --light must not emit light markers
if python3 "$ASM" --events "$THRASH" --session-uuid "light-off" --mode warm --out "$LIGHT_OFF" 2>/dev/null \
   && ! grep -q 'light: true' "$LIGHT_OFF" \
   && ! grep -qF "$LIGHT_HONESTY" "$LIGHT_OFF" \
   && grep -q '^mode: warm$' "$LIGHT_OFF"; then ok
else bad "T27 bare warm must omit light meta"; fi

# ---- T28: CDT-94 gen-3 prior id collision — load-time #N uniquify (RED before T1) ----
# Fixture mimics post–gen-2 events_for_cache: two through_line rows share raw id tl-e1
# with distinct bodies; state stem has a unique raw (non-collision pocket).
G3_PRIOR="$WORK/g3-prior.json"
G3_NOCOLL="$WORK/g3-nocoll.json"
G3_MULTI="$WORK/g3-multi.json"
python3 -c '
import json, sys
# poisoned gen-3 cache: duplicate raw tl-e1 under through_line + unique state id
json.dump({
  "leaf_uuid": "leaf-g3",
  "events": {
    "through_line": [
      {"id": "tl-e1", "kind": "decision", "text": "gen1 prior body", "order": 1},
      {"id": "tl-e1", "kind": "decision", "text": "gen2 delta body", "order": 1}
    ],
    "state": [
      {"id": "s-unique", "kind": "open", "text": "unique state body", "order": 1}
    ]
  }
}, open(sys.argv[1], "w"))
# AC5: single-row prior — no collision, no #N, no collision stderr
json.dump({
  "events": {
    "through_line": [
      {"id": "tl-e1", "kind": "decision", "text": "solo prior body", "order": 1}
    ]
  }
}, open(sys.argv[2], "w"))
# AC8 multi-hop: raws already include a #2 form plus another bare collision
json.dump({
  "events": {
    "through_line": [
      {"id": "tl-e1", "kind": "decision", "text": "hop body A", "order": 1},
      {"id": "tl-e1#2", "kind": "decision", "text": "hop body B", "order": 1},
      {"id": "tl-e1", "kind": "decision", "text": "hop body C", "order": 1}
    ]
  }
}, open(sys.argv[3], "w"))
' "$G3_PRIOR" "$G3_NOCOLL" "$G3_MULTI"

if python3 -c '
import io, sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a

# --- AC1/AC3: dual raw tl-e1 → unique ids + stderr diagnostic ---
err = io.StringIO()
_old = sys.stderr
sys.stderr = err
try:
    prior = a.load_prior_events("'"$G3_PRIOR"'")
finally:
    sys.stderr = _old
err_s = err.getvalue()

# load order: stems sorted → state first, then through_line
tl = [e for e in prior if e["id"].startswith("prior:through_line:")]
st = [e for e in prior if e["id"].startswith("prior:state:")]
assert len(tl) == 2, ("want 2 through_line rows", [e["id"] for e in prior])
assert [e["id"] for e in tl] == [
    "prior:through_line:tl-e1",
    "prior:through_line:tl-e1#2",
], [e["id"] for e in tl]
assert [e.get("_raw_id") for e in tl] == ["tl-e1", "tl-e1#2"], [e.get("_raw_id") for e in tl]
assert tl[0]["text"] == "gen1 prior body" and tl[1]["text"] == "gen2 delta body"
assert len({e["id"] for e in prior}) == len(prior), ("ids not unique", [e["id"] for e in prior])

# stderr non-empty; collision token + #2
assert err_s.strip(), "expected non-empty stderr on collision"
assert "collision" in err_s.lower() or "prior id" in err_s.lower(), err_s
assert "#2" in err_s, err_s
assert "assemble:" in err_s, err_s

# --- AC2: annotation targeting — base hits first body only; #2 hits second only ---
anns = [
    {"event_id": "prior:through_line:tl-e1", "labels": ["L_BASE"], "rank": 1},
    {"event_id": "prior:through_line:tl-e1#2", "labels": ["L_HASH2"], "rank": 2},
    {"event_id": "tl-e1", "labels": ["BARE_DROP"]},
]
_, applied, dropped = a.apply_annotations(prior, anns)
assert applied == 2, applied
assert dropped == 1, dropped
by = {e["id"]: e for e in prior}
assert "L_BASE" in (by["prior:through_line:tl-e1"].get("_labels") or [])
assert "L_HASH2" not in (by["prior:through_line:tl-e1"].get("_labels") or [])
assert "L_HASH2" in (by["prior:through_line:tl-e1#2"].get("_labels") or [])
assert "L_BASE" not in (by["prior:through_line:tl-e1#2"].get("_labels") or [])
# by_id must retain both bodies (no last-wins collapse)
assert by["prior:through_line:tl-e1"]["text"] == "gen1 prior body"
assert by["prior:through_line:tl-e1#2"]["text"] == "gen2 delta body"

# --- AC5 non-collision pocket: unique raw loads without #n; no collision stderr ---
assert len(st) == 1 and st[0]["id"] == "prior:state:s-unique"
assert st[0].get("_raw_id") == "s-unique"
assert "#n" not in st[0]["id"] and not st[0]["id"].endswith("#2")

err2 = io.StringIO()
sys.stderr = err2
try:
    solo = a.load_prior_events("'"$G3_NOCOLL"'")
finally:
    sys.stderr = _old
err2_s = err2.getvalue()
assert [e["id"] for e in solo] == ["prior:through_line:tl-e1"], [e["id"] for e in solo]
assert solo[0].get("_raw_id") == "tl-e1"
assert "collision" not in err2_s.lower(), err2_s

# --- AC8 multi-hop: tl-e1, tl-e1#2, tl-e1 → …#3 for third ---
err3 = io.StringIO()
sys.stderr = err3
try:
    multi = a.load_prior_events("'"$G3_MULTI"'")
finally:
    sys.stderr = _old
err3_s = err3.getvalue()
mids = [e["id"] for e in multi]
assert mids == [
    "prior:through_line:tl-e1",
    "prior:through_line:tl-e1#2",
    "prior:through_line:tl-e1#3",
], mids
assert [e.get("_raw_id") for e in multi] == ["tl-e1", "tl-e1#2", "tl-e1#3"]
assert len(set(mids)) == 3
assert err3_s.strip() and ("#3" in err3_s or "collision" in err3_s.lower()), err3_s
# soft: re-cache + reload still unique (events_for_cache may re-poison raws; load re-uniquifies)
cached = a.events_for_cache(multi)
import json, tempfile, os
p = "'"$WORK"'/g3-recache.json"
json.dump({"events": cached}, open(p, "w"))
err4 = io.StringIO()
sys.stderr = err4
try:
    again = a.load_prior_events(p)
finally:
    sys.stderr = _old
aids = [e["id"] for e in again]
assert len(aids) == len(set(aids)), ("multi-hop re-load not unique", aids)
assert len(aids) == 3, aids

print("ok")
' 2>"$WORK/t28.err" | grep -q ok; then ok
else bad "T28 gen-3 prior id collision: $(head -c 500 "$WORK/t28.err")"; fi

# ---- T29: CDT-198 / M3d — Product surfaces + Open ship gaps required in State now ----
# Thrash packet (no tagged facets) MUST still carry both subsection headings in
# the State now slice (before ## Through-line). Appendix-only = fail.
if python3 -c '
import sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a
t = open("'"$OUT"'").read()
i = t.find("## State now")
j = t.find("## Through-line")
k = t.find("## appendix")
assert 0 <= i < j < k, (i, j, k)
sn = t[i:j]
ap = t[k:]
assert "### Product surfaces" in sn, "Product surfaces missing from State now"
assert "### Open ship gaps" in sn, "Open ship gaps missing from State now"
assert "### Product surfaces" not in ap or sn.count("### Product surfaces") >= 1
# headings must not appear only after Through-line
assert t.find("### Product surfaces") < j
assert t.find("### Open ship gaps") < j
assert a.state_now_contract_ok(t)
print("ok")
' 2>"$WORK/t29.err" | grep -q ok; then ok
else bad "T29 thrash State now required sections: $(head -c 400 "$WORK/t29.err")"; fi

# T29b: appendix-only / missing headings are not a valid packet
if python3 -c '
import sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a
missing = "# STM\n\n## State now\n\n### Decisions\n\n## Through-line\n\n## appendix\n"
assert a.state_now_contract_ok(missing) is False
appendix_only = (
    "# STM\n\n## State now\n\n### Decisions\n\n## Through-line\n\n"
    "## appendix\n\n### Product surfaces\n\n### Open ship gaps\n"
)
assert a.state_now_contract_ok(appendix_only) is False
empty = ""
assert a.state_now_contract_ok(empty) is False
print("ok")
' 2>"$WORK/t29b.err" | grep -q ok; then ok
else bad "T29b contract rejects missing/appendix-only: $(head -c 400 "$WORK/t29b.err")"; fi

# T29c: assemble MUST NOT emit a packet that fails the contract (raises)
if python3 -c '
import sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a
# helper used by assemble_packet — stripped md is a defect
try:
    a.ensure_state_now_contract("# STM\n## State now\n## Through-line\n## appendix\n")
except a.AssembleError:
    print("ok")
else:
    raise SystemExit("expected AssembleError on missing sections")
' 2>"$WORK/t29c.err" | grep -q ok; then ok
else bad "T29c ensure_state_now_contract: $(head -c 400 "$WORK/t29c.err")"; fi

# ---- T30: fixture names primary + non-product → both strings in State now ----
PS_DIR="$FIX/events-product-surfaces"
PS_PKT="$WORK/product-surfaces.md"
PS_CORE="$WORK/product-surfaces.core"
if [ -f "$PS_DIR/through_line.json" ] && [ -f "$PS_DIR/state.json" ]; then ok
else bad "T30 missing events-product-surfaces fixture"; fi

if python3 "$ASM" \
    --events "$PS_DIR" \
    --git "$GITBLOB" \
    --session-uuid "sess-surfaces" \
    --mode cold \
    --out "$PS_PKT" \
    --print-core >"$PS_CORE" 2>"$WORK/t30.err"; then ok
else bad "T30 CLI assemble fixture failed: $(head -c 300 "$WORK/t30.err")"; fi

if python3 -c '
import sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a
pkt = open("'"$PS_PKT"'").read()
core = open("'"$PS_CORE"'").read()
sn = pkt.split("## Through-line")[0]
ap = pkt.split("## appendix", 1)[-1]
primary = "match --ui SPA"
nonprod = "Fyne desktop"
gap = "settings persistence unshipped"
assert primary in sn, sn
assert nonprod in sn, sn
assert gap in sn, sn
# compact-seed core (print-core / extract_core) carries both strings
assert primary in core and nonprod in core, core
assert "## appendix" not in core
# appendix-only would fail: strings must not live only after Through-line
assert pkt.find(primary) < pkt.find("## Through-line")
assert pkt.find(nonprod) < pkt.find("## Through-line")
assert a.state_now_contract_ok(pkt)
# mechanical select
evs = a.load_events("'"$PS_DIR"'")
st = a.select_state_now(evs)
prim = " ".join(a.event_body(e) for e in st["product_surfaces_primary"])
unf = " ".join(a.event_body(e) for e in st["product_surfaces_unfinished"])
gaps = " ".join(a.event_body(e) for e in st["ship_gaps"])
assert primary in prim
assert nonprod in unf
assert gap in gaps
# facet survives validate + cache round-trip (M8b)
cached = a.events_for_cache(evs)
flat = [e for arr in cached.values() for e in arr]
assert any(e.get("facet") == "product_surface" and e.get("surface_class") == "primary" for e in flat)
assert any(e.get("facet") == "product_surface" and e.get("surface_class") == "unfinished" for e in flat)
assert any(e.get("facet") == "ship_gap" for e in flat)
assert len(a.EVENT_KINDS) == 7
print("ok")
' 2>"$WORK/t30b.err" | grep -q ok; then ok
else bad "T30 fixture strings in State now: $(head -c 400 "$WORK/t30b.err")"; fi

# ---- T31: light path same fixture + honesty line unchanged (M10c / CDT-198) ----
LIGHT_HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'
PS_LIGHT="$WORK/product-surfaces-light.md"
if python3 "$ASM" \
    --events "$PS_DIR" \
    --git "$GITBLOB" \
    --session-uuid "sess-surfaces-light" \
    --mode warm \
    --light \
    --out "$PS_LIGHT" 2>"$WORK/t31.err"; then ok
else bad "T31 light assemble failed: $(head -c 300 "$WORK/t31.err")"; fi

if python3 -c '
import sys
sys.path.insert(0, "'"$HERE"'")
import assemble as a
pkt = open("'"$PS_LIGHT"'").read()
sn = pkt.split("## Through-line")[0]
assert "### Product surfaces" in sn
assert "### Open ship gaps" in sn
assert "match --ui SPA" in sn
assert "Fyne desktop" in sn
assert "settings persistence unshipped" in sn
assert "light: true" in pkt
assert a.LIGHT_HONESTY in pkt
assert a.LIGHT_HONESTY == "light preset: reduced-cost mine, no annotation; not AC-16-scored."
assert "UNMINED" not in pkt
assert a.state_now_contract_ok(pkt)
# header order unchanged
assert pkt.find("## State now") < pkt.find("## Through-line") < pkt.find("## appendix")
print("ok")
' 2>"$WORK/t31b.err" | grep -q ok; then ok
else bad "T31 light State now + honesty: $(head -c 400 "$WORK/t31b.err")"; fi

# ---- summary ----
echo "assemble-test: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
