#!/usr/bin/env bash
# assemble-quality-test.sh — SPEC-018 Test 37 / CDT-201 packet quality.
# Coverage: AC1–AC8, AC10 display, AC12, AC13 SHOULD (advisory).
# Run: bash skills/handoff/assemble-quality-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
ASM="$HERE/assemble.py"
FIX="$HERE/fixtures"
QFIX="$FIX/events-quality"
GITBLOB="$FIX/git-state.txt"
PQ="$HERE/packet_quality.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/assemble-quality.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

copy_quality() {
  mkdir -p "$1"
  cp "$QFIX/through_line.json" "$QFIX/state.json" "$1/"
}

# ---- T0: fixtures + imports ----
if [ -f "$ASM" ] && [ -f "$PQ" ]; then ok; else bad "T0 missing assemble/packet_quality"; fi
if [ -f "$QFIX/through_line.json" ] && [ -f "$QFIX/state.json" ]; then ok
else bad "T0 missing events-quality through_line/state"; fi
if [ -f "$QFIX/no-summary/through_line.json" ] && [ -f "$QFIX/duplication/state.json" ]; then ok
else bad "T0 missing no-summary/duplication fixtures"; fi
if python3 -c "
import sys
sys.path.insert(0, '$HERE')
import packet_quality as q, assemble as a
assert q.SUMMARY_MAX == 800
assert q.WHERE_WE_ARE_HEADING == '### Where we are'
assert a.QUOTE_MAX == 200
print('ok')
" 2>/dev/null | grep -q ok; then ok; else bad "T0 import SUMMARY_MAX/WHERE_WE_ARE"; fi

# ---- Tq: packet_quality bite-tests (validate_summary / load / remainder) ----
if python3 -c "
import json, os, sys
sys.path.insert(0, '$HERE')
import packet_quality as q
evs = [{'id': 'e1', '_raw_id': 'raw1'}, {'id': 'through_line:tl-e1', '_raw_id': 'tl-e1'}]
assert q.known_cite_ids(evs) == {'e1', 'raw1', 'through_line:tl-e1', 'tl-e1'}
ok, prose, reason = q.validate_summary('Hi {e1}.', [{'id': 'e1'}])
assert ok and prose == 'Hi.' and reason == 'ok'
assert q.validate_summary('Hi {nope}.', [{'id': 'e1'}]) == (False, None, 'unknown token')
assert q.validate_summary('Hi {e1}. No cite here.', [{'id': 'e1'}]) == (False, None, 'uncited sentence')
assert q.validate_summary(123, evs)[0] is False and q.validate_summary(123, evs)[2] == 'non-str'
long = 'x' * 801
assert q.validate_summary(long, evs) == (False, None, 'too long')
assert q.validate_summary('', evs)[0] is False
# raw id cite
ok, prose, _ = q.validate_summary('Used {tl-e1}.', evs)
assert ok and 'tl-e1' not in prose and '{' not in prose
st = {
  'product_surfaces_primary': [{'id': 'a'}],
  'product_surfaces_unfinished': [{'id': 'b'}],
  'ship_gaps': [{'id': 'c'}],
  'decisions': [{'id': 'd'}],
  'hypotheses': [{'id': 'e'}],
  'opens': [{'id': 'f'}],
}
assert q.occupied_ids(st) == {'a', 'b', 'c', 'd', 'e', 'f'}
ordered = [{'id': 'a'}, {'id': 'x'}, {'id': 'c'}, {'id': 'y'}]
assert [e['id'] for e in q.remainder_events(ordered, q.occupied_ids(st))] == ['x', 'y']
print('ok')
" 2>"$WORK/tq.err" | grep -q ok; then ok; else bad "Tq packet_quality bites: $(head -c 300 "$WORK/tq.err")"; fi

# ---- TAC1: CLI quality packet ----
QPKT="$WORK/quality.md"
QERR="$WORK/quality.err"
if python3 "$ASM" \
    --events "$QFIX" \
    --git "$GITBLOB" \
    --session-uuid "sess-quality" \
    --mode cold \
    --out "$QPKT" \
    --events-out "$WORK/quality-events-out.json" \
    2>"$QERR"; then ok
else bad "TAC1 CLI quality assemble failed: $(head -c 200 "$QERR")"; fi
if [ -s "$QPKT" ]; then ok; else bad "TAC1 empty quality packet"; fi

# ---- AC1: ship_gap body once + inline ↳ ----
if python3 -c "
import sys
sys.path.insert(0, '$HERE')
import assemble as a
pkt = open('$QPKT').read()
body = 'settings persistence unshipped (quality-gap)'
assert pkt.count(body) == 1, pkt.count(body)
sn = pkt.split('## Through-line')[0]
gaps = sn.split('### Open ship gaps', 1)[1].split('### Decisions', 1)[0]
assert body in gaps
assert '↳' in gaps
assert 'transcript:L88' in gaps
opens = sn.split('### Open', 1)[1]
# first ### Open after Open ship gaps already consumed; use last Open block
opens = sn.rsplit('### Open', 1)[-1]
assert body not in opens
assert a.state_now_contract_ok(pkt)
print('ok')
" 2>"$WORK/ac1.err" | grep -q ok; then ok; else bad "AC1 ship_gap once+↳: $(head -c 300 "$WORK/ac1.err")"; fi

# ---- AC2: product_surface ↳ on Product surfaces; untagged open under Open ----
if python3 -c "
pkt = open('$QPKT').read()
sn = pkt.split('## Through-line')[0]
ps = sn.split('### Product surfaces', 1)[1].split('### Open ship gaps', 1)[0]
assert 'match --ui SPA quality-surface' in ps
assert '↳' in ps
assert 'file:skills/handoff/assemble.py' in ps
dec = sn.split('### Decisions', 1)[1].split('### Hypotheses', 1)[0]
assert 'quality-surface' not in dec
opens = sn.rsplit('### Open', 1)[-1]
assert 'untagged open stays under Open (quality)' in opens
gaps = sn.split('### Open ship gaps', 1)[1].split('### Decisions', 1)[0]
assert 'untagged open stays under Open (quality)' not in gaps
print('ok')
" 2>"$WORK/ac2.err" | grep -q ok; then ok; else bad "AC2 facet buckets: $(head -c 300 "$WORK/ac2.err")"; fi

# ---- AC3/AC10: remainder groups cache+assemble; ruling prefers text ----
if python3 -c "
pkt = open('$QPKT').read()
tl = pkt.split('## Through-line', 1)[1].split('## appendix', 1)[0]
assert '### cache' in tl and '### assemble' in tl
assert 'killed: goja too slow is false' in tl
assert 'picked goja — option 1 of 3' in tl
assert 'quality-fact' in tl
assert '- **ruling**: 1' not in pkt
assert pkt.count('picked goja — option 1 of 3') == 1
# State now occupancy not copied into Through-line
assert 'quality-gap' not in tl
assert 'quality-surface' not in tl
assert 'untagged open stays under Open' not in tl
assert 'Ship SPA as the primary UX (quality)' not in tl
assert 'Remainder grouping needs two workstreams' not in tl
print('ok')
" 2>"$WORK/ac3.err" | grep -q ok; then ok; else bad "AC3 remainder/ruling: $(head -c 300 "$WORK/ac3.err")"; fi

# ---- AC4/AC5: appendix leftover only; Pointers heading absent; no id leak ----
if python3 -c "
import sys
sys.path.insert(0, '$HERE')
import assemble as a
pkt = open('$QPKT').read()
ap = pkt.split('## appendix', 1)[1]
assert '### Kill catalog' in ap
assert '_none_' in ap.split('### Kill catalog', 1)[1].split('###', 1)[0]
assert '### Facts' not in ap
assert '### Pointers (courtesy)' not in pkt
evs = a.load_events('$QFIX')
for e in evs:
    assert e['id'] not in pkt, 'namespaced id leaked: ' + e['id']
assert 'through_line:tl-ruling' not in pkt
assert '{through_line:' not in pkt
print('ok')
" 2>"$WORK/ac5.err" | grep -q ok; then ok; else bad "AC4/AC5 appendix/Pointers: $(head -c 300 "$WORK/ac5.err")"; fi

# ---- AC6: valid summary → Where we are first; tokens stripped ----
if python3 -c "
pkt = open('$QPKT').read()
sn = pkt.split('## Through-line')[0]
i_state = sn.find('## State now')
i_where = sn.find('### Where we are')
i_ps = sn.find('### Product surfaces')
assert 0 <= i_state < i_where < i_ps, (i_state, i_where, i_ps)
block = sn.split('### Where we are', 1)[1].split('### Product surfaces', 1)[0]
assert 'Picked goja' in block
assert 'Cache kill landed' in block
assert '{' not in block
assert 'through_line:tl-ruling' not in block
assert 'tl-ruling' not in block
print('ok')
" 2>"$WORK/ac6.err" | grep -q ok; then ok; else bad "AC6 Where we are: $(head -c 300 "$WORK/ac6.err")"; fi

# ---- AC7/AC8 invalid summaries: unknown / uncited / >800 / non-str → omit + packet valid ----
UNK="$WORK/unknown"; copy_quality "$UNK"
python3 -c '
import json,sys
p=sys.argv[1]+"/through_line.json"
o=json.load(open(p)); o["summary"]="Unknown cite {totally-unknown}."; json.dump(o, open(p,"w"))
' "$UNK"
if python3 "$ASM" --events "$UNK" --out "$WORK/unk.md" 2>"$WORK/unk.err" \
   && grep -q 'assemble: omit summary:' "$WORK/unk.err" \
   && ! grep -q '### Where we are' "$WORK/unk.md" \
   && grep -q '## State now' "$WORK/unk.md"; then ok
else bad "AC7 unknown id: $(head -c 200 "$WORK/unk.err")"; fi

UNC="$WORK/uncited"; copy_quality "$UNC"
python3 -c '
import json,sys
p=sys.argv[1]+"/through_line.json"
o=json.load(open(p))
o["summary"]="Picked goja {through_line:tl-ruling}. This sentence has no cite."
json.dump(o, open(p,"w"))
' "$UNC"
if python3 "$ASM" --events "$UNC" --out "$WORK/unc.md" 2>"$WORK/unc.err" \
   && grep -q 'assemble: omit summary:' "$WORK/unc.err" \
   && ! grep -q '### Where we are' "$WORK/unc.md"; then ok
else bad "AC7 uncited sentence: $(head -c 200 "$WORK/unc.err")"; fi

LONG="$WORK/over800"; copy_quality "$LONG"
python3 -c '
import json,sys
p=sys.argv[1]+"/through_line.json"
o=json.load(open(p))
o["summary"]=("x"*790)+" {through_line:tl-ruling}."
assert len(o["summary"].strip())>800
json.dump(o, open(p,"w"))
' "$LONG"
if python3 "$ASM" --events "$LONG" --out "$WORK/long.md" 2>"$WORK/long.err" \
   && grep -q 'assemble: omit summary:' "$WORK/long.err" \
   && ! grep -q '### Where we are' "$WORK/long.md"; then ok
else bad "AC8 >800: $(head -c 200 "$WORK/long.err")"; fi

NON="$WORK/nonstr"; copy_quality "$NON"
python3 -c '
import json,sys
p=sys.argv[1]+"/through_line.json"
o=json.load(open(p)); o["summary"]=42; json.dump(o, open(p,"w"))
' "$NON"
if python3 "$ASM" --events "$NON" --out "$WORK/nonstr.md" 2>"$WORK/nonstr.err" \
   && ! grep -q '### Where we are' "$WORK/nonstr.md" \
   && grep -q '## State now' "$WORK/nonstr.md"; then ok
else bad "AC8 non-str: $(head -c 200 "$WORK/nonstr.err")"; fi

# validate_summary non-str reason + assemble_packet stderr
if python3 -c "
import io, sys
sys.path.insert(0, '$HERE')
import assemble as a, packet_quality as q
assert q.validate_summary(42, [{'id':'e'}])[2] == 'non-str'
evs = a.load_events('$QFIX')
err = io.StringIO()
_old = sys.stderr
sys.stderr = err
try:
    pkt = a.assemble_packet(evs, summary=42)
finally:
    sys.stderr = _old
assert '### Where we are' not in pkt
assert 'assemble: omit summary: non-str' in err.getvalue()
print('ok')
" 2>"$WORK/nonstr2.err" | grep -q ok; then ok
else bad "AC8 assemble_packet non-str: $(head -c 200 "$WORK/nonstr2.err")"; fi

# ---- AC8 both-files: through_line wins; state-only used when TL missing ----
BOTH="$WORK/both-win"; copy_quality "$BOTH"
python3 -c '
import json,sys
d=sys.argv[1]
tl=json.load(open(d+"/through_line.json")); st=json.load(open(d+"/state.json"))
tl["summary"]="TLWIN {through_line:tl-ruling}."
st["summary"]="STATEWIN {sg-persist}."
json.dump(tl, open(d+"/through_line.json","w")); json.dump(st, open(d+"/state.json","w"))
' "$BOTH"
if python3 "$ASM" --events "$BOTH" --out "$WORK/both.md" 2>"$WORK/both.err" \
   && grep -q '### Where we are' "$WORK/both.md" \
   && grep -q 'TLWIN' "$WORK/both.md" \
   && ! grep -q 'STATEWIN' "$WORK/both.md"; then ok
else bad "AC8 through_line win: $(head -c 200 "$WORK/both.err")"; fi

STONLY="$WORK/state-only"; copy_quality "$STONLY"
python3 -c '
import json,sys
d=sys.argv[1]
tl=json.load(open(d+"/through_line.json")); st=json.load(open(d+"/state.json"))
tl.pop("summary", None)
st["summary"]="STATEONLY {op-untagged}."
json.dump(tl, open(d+"/through_line.json","w")); json.dump(st, open(d+"/state.json","w"))
' "$STONLY"
if python3 "$ASM" --events "$STONLY" --out "$WORK/stonly.md" 2>"$WORK/stonly.err" \
   && grep -q '### Where we are' "$WORK/stonly.md" \
   && grep -q 'STATEONLY' "$WORK/stonly.md"; then ok
else bad "AC8 state-only summary: $(head -c 200 "$WORK/stonly.err")"; fi

if python3 -c "
import os, json, sys
sys.path.insert(0, '$HERE')
import packet_quality as q
assert q.load_wrapper_summary('$BOTH').startswith('TLWIN')
assert q.load_wrapper_summary('$STONLY').startswith('STATEONLY')
assert q.load_wrapper_summary('$QFIX/no-summary') is None
assert q.load_wrapper_summary('') is None
# chunk-summarizer ignored
p='$WORK/chunk.json'
json.dump({'chunk_index': 0, 'summary': 'chunk md not events'}, open(p,'w'))
assert q.load_wrapper_summary(p) is None
print('ok')
" 2>"$WORK/load.err" | grep -q ok; then ok
else bad "AC8 load_wrapper_summary: $(head -c 200 "$WORK/load.err")"; fi

# ---- AC12: JSON without summary still assembles; no Where we are ----
NS_PKT="$WORK/no-summary.md"
if python3 "$ASM" --events "$QFIX/no-summary" --out "$NS_PKT" 2>"$WORK/ns.err" \
   && grep -q '## State now' "$NS_PKT" \
   && grep -q 'AC12 JSON without summary still assembles' "$NS_PKT" \
   && ! grep -q '### Where we are' "$NS_PKT"; then ok
else bad "AC12 no-summary: $(head -c 200 "$WORK/ns.err")"; fi

# ---- M8b cache schema: events-out has no wrapper summary ----
if python3 -c "
import json
m = json.load(open('$WORK/quality-events-out.json'))
assert isinstance(m, dict)
assert 'summary' not in m
for stem, arr in m.items():
    assert isinstance(arr, list), stem
    for ev in arr:
        assert 'summary' not in ev
        assert not str(ev.get('id','')).startswith('through_line:')
print('ok')
" 2>"$WORK/eo.err" | grep -q ok; then ok
else bad "AC12 events-out summary leak: $(head -c 200 "$WORK/eo.err")"; fi

# ---- single-section: each unique body in exactly one ## section ----
if python3 -c "
pkt = open('$QPKT').read()
i1, i2, i3 = pkt.find('## State now'), pkt.find('## Through-line'), pkt.find('## appendix')
sn, tl, ap = pkt[i1:i2], pkt[i2:i3], pkt[i3:]
bodies = [
  'settings persistence unshipped (quality-gap)',
  'match --ui SPA quality-surface',
  'untagged open stays under Open (quality)',
  'picked goja — option 1 of 3',
  'killed: goja too slow is false',
  'Ship SPA as the primary UX (quality)',
  'Remainder grouping needs two workstreams (quality)',
  'forkedFrom is a dict not a pointer (quality-fact)',
]
for b in bodies:
    hits = [name for name, s in (('sn', sn), ('tl', tl), ('ap', ap)) if b in s]
    assert len(hits) == 1, (b, hits)
print('ok')
" 2>"$WORK/ss.err" | grep -q ok; then ok
else bad "single-section occupancy: $(head -c 300 "$WORK/ss.err")"; fi

# ---- ## order + empty remainder _no events_ + leftover appendix ----
if python3 -c "
import sys
sys.path.insert(0, '$HERE')
import assemble as a
pkt = open('$QPKT').read()
assert pkt.find('## State now') < pkt.find('## Through-line') < pkt.find('## appendix')
# empty remainder
evs = [
  {'id': 'd1', 'kind': 'decision', 'text': 'only state occupancy'},
  {'id': 'o1', 'kind': 'open', 'text': 'only an open'},
]
p = a.assemble_packet(evs)
tl = p.split('## Through-line', 1)[1].split('## appendix', 1)[0]
assert '_no events_' in tl
assert '### cache' not in tl
print('ok')
" 2>"$WORK/ord.err" | grep -q ok; then ok
else bad "order/empty remainder: $(head -c 200 "$WORK/ord.err")"; fi

# ---- T10 successor: remainder grouping only when >1 workstream ----
if python3 -c "
import sys
sys.path.insert(0, '$HERE')
import assemble as a
two = a.assemble_packet([
  {'id': 'd1', 'kind': 'decision', 'text': 'dec stays in state'},
  {'id': 'k1', 'kind': 'killed', 'quote': 'kill cache body', 'workstream': 'cache'},
  {'id': 'k2', 'kind': 'killed', 'quote': 'kill assemble body', 'workstream': 'assemble'},
])
tl = two.split('## Through-line', 1)[1].split('## appendix', 1)[0]
assert '### cache' in tl and '### assemble' in tl
one = a.assemble_packet([
  {'id': 'd1', 'kind': 'decision', 'text': 'dec stays in state'},
  {'id': 'k1', 'kind': 'killed', 'quote': 'only one remainder ws', 'workstream': 'cache'},
])
tl1 = one.split('## Through-line', 1)[1].split('## appendix', 1)[0]
assert '### cache' not in tl1
assert 'only one remainder ws' in tl1
print('ok')
" 2>"$WORK/t10.err" | grep -q ok; then ok
else bad "remainder workstream grouping: $(head -c 200 "$WORK/t10.err")"; fi

# ---- M10c honesty / light markers unchanged ----
LIGHT_HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'
if python3 "$ASM" --events "$QFIX" --session-uuid "q-light" --mode warm --light \
     --out "$WORK/q-light.md" 2>/dev/null \
   && grep -qF "$LIGHT_HONESTY" "$WORK/q-light.md" \
   && grep -q 'light: true' "$WORK/q-light.md" \
   && grep -q '^mode: warm$' "$WORK/q-light.md" \
   && ! grep -q 'UNMINED' "$WORK/q-light.md" \
   && ! grep -q '### Pointers (courtesy)' "$WORK/q-light.md"; then ok
else bad "light honesty/Pointers"; fi

# ---- AC13 SHOULD 50% (advisory): duplication fixture vs pre-change 3-copy ----
DUP_PKT="$WORK/dup.md"
DUP_BODY='QUALITY-DUP-GAP:'
if python3 "$ASM" --events "$QFIX/duplication" --git "$GITBLOB" \
     --out "$DUP_PKT" 2>"$WORK/dup.err"; then ok
else bad "AC13 duplication assemble: $(head -c 200 "$WORK/dup.err")"; fi

if python3 -c "
pkt = open('$DUP_PKT').read()
body = 'QUALITY-DUP-GAP:'
assert pkt.count(body) == 1, pkt.count(body)
assert '↳' in pkt and 'transcript:L201' in pkt
assert '### Pointers (courtesy)' not in pkt
# Event-rendered bullets only (exclude git, header/footer, headings, placeholders).
# Pre-change dual-render: ship_gap in Open ship gaps + Open + Through-line;
# other occupied events in State now + Through-line.
i = pkt.find('## State now')
j = pkt.find('### Code state (git)')
er = pkt[i:j]
blocks, cur, take = [], [], False
for ln in er.splitlines():
    if ln.startswith('- **') and '_unspecified_' not in ln:
        if cur:
            blocks.append('\n'.join(cur))
        cur = [ln]
        take = True
    elif take and ln.strip().startswith('↳'):
        cur.append(ln)
        take = False
    else:
        take = False
if cur:
    blocks.append('\n'.join(cur))
assert blocks
gap = [b for b in blocks if body in b]
other = [b for b in blocks if body not in b]
assert len(gap) == 1
cur_md = '\n'.join(blocks)
pre_md = '\n'.join(gap * 3 + other * 2)
ratio = len(cur_md) / len(pre_md) if pre_md else 1.0
open('$WORK/ac13.ratio','w').write('%.4f %d %d\n' % (ratio, len(cur_md), len(pre_md)))
print('ok')
" 2>"$WORK/ac13.err" | grep -q ok; then ok
else bad "AC13 duplication once+↳: $(head -c 300 "$WORK/ac13.err")"; fi

# SHOULD: event-rendered ≤ 50% of reconstructed dual-render (advisory, not fail-closed)
if [ -f "$WORK/ac13.ratio" ]; then
  RATIO=$(awk '{print $1}' "$WORK/ac13.ratio")
  # awk: ratio <= 0.5 ?
  if awk -v r="$RATIO" 'BEGIN { exit (r+0 <= 0.5) ? 0 : 1 }'; then
    ok
  else
    echo "WARN: AC13 SHOULD 50% missed ratio=$RATIO (advisory, not fail-closed)"
    ok
  fi
else
  echo "WARN: AC13 SHOULD 50% skipped (no ratio file, advisory)"
  ok
fi

# ---- summary ----
echo "assemble-quality-test: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
