#!/usr/bin/env bash
# assemble-quality-test.sh — SPEC-018 Test 37 + Test 38 / CDT-202 packet quality.
# Coverage: Test 37 AC1–AC8, AC10, AC12, AC13 SHOULD; Test 38 AC1–AC8
# prefix-collapse + leftover Kill placeholder (CDT-202).
# Run: bash skills/handoff/assemble-quality-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
ASM="$HERE/assemble.py"
FIX="$HERE/fixtures"
QFIX="$FIX/events-quality"
DFIX="$QFIX/dedup-residuals"
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

# Sole non-blank lines under ### Kill catalog before next ###.
kc_lines() {
  python3 -c '
import sys
p = open(sys.argv[1]).read()
s = p.split("## appendix", 1)[1].split("### Kill catalog", 1)[1].split("###", 1)[0]
print("\n".join(x.strip() for x in s.splitlines() if x.strip()))
' "$1"
}

# ---- T0: fixtures + imports ----
if [ -f "$ASM" ] && [ -f "$PQ" ]; then ok; else bad "T0 missing assemble/packet_quality"; fi
if [ -f "$QFIX/through_line.json" ] && [ -f "$QFIX/state.json" ]; then ok
else bad "T0 missing events-quality through_line/state"; fi
if [ -f "$QFIX/no-summary/through_line.json" ] && [ -f "$QFIX/duplication/state.json" ]; then ok
else bad "T0 missing no-summary/duplication fixtures"; fi
_t0m=
for _d in ac1-prefix ac2-short ac4-twin ac5-distinct ac6-crosskind ac7-zero-killed ac8-trio; do
  [ -f "$DFIX/$_d/state.json" ] && [ -f "$DFIX/$_d/through_line.json" ] || _t0m="$_t0m $_d"
done
if [ -z "$_t0m" ]; then ok; else bad "T0 missing dedup-residuals:$_t0m"; fi
unset _t0m _d
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
kc = ap.split('### Kill catalog', 1)[1].split('###', 1)[0]
kcl = [ln.strip() for ln in kc.splitlines() if ln.strip()]
assert kcl == ['_none not already shown above_'], kcl
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

# ---- Test 38 / CDT-202: prefix-collapse + leftover Kill placeholder ----
NONE='_none_'
NONE_SHOWN='_none not already shown above_'
SHORT_OPEN='Out of scope still: light-as-default, PDH orchestrator-cost cut.'
LONG_OPEN='Out of scope still: light-as-default, PDH orchestrator-cost cut. Say if you want those filed.'
AC2_SHORT='Need a short prefix under forty chars.'
AC2_LONG='Need a short prefix under forty chars plus more.'
AC5_OPEN='Untagged open for AC5 distinct, no conflict twin'
AC5_CF='Conflict: miner vs assemble on leftover wording'
AC6_BODY='Same body must survive across killed and hypothesis'
AC7_OPEN='AC7 zero killed events anywhere in the assembled set'

for case in ac1-prefix ac2-short ac4-twin ac5-distinct ac6-crosskind ac7-zero-killed ac8-trio; do
  if python3 "$ASM" --events "$DFIX/$case" --git "$GITBLOB" \
      --session-uuid "sess-$case" --mode cold \
      --out "$WORK/$case.md" 2>"$WORK/$case.err"; then ok
  else bad "T38 CLI $case: $(head -c 160 "$WORK/$case.err")"; fi
done

# AC1: same-kind prefix ≥40 → one ship-gap bullet, longer body, earliest id
if python3 -c "
pkt = open('$WORK/ac1-prefix.md').read()
sn = pkt.split('## Through-line')[0]
gaps = sn.split('### Open ship gaps', 1)[1].split('### Decisions', 1)[0]
bullets = [ln for ln in gaps.splitlines() if ln.startswith('- **')]
assert len(bullets) == 1, bullets
assert '$LONG_OPEN' in bullets[0]
assert pkt.count('$LONG_OPEN') == 1
assert 'Say if you want those filed.' in gaps
assert '- **conflict**:' not in pkt
print('ok')
" 2>"$WORK/t38-ac1.err" | grep -q ok; then ok
else bad "T38 AC1 prefix-collapse: $(head -c 300 "$WORK/t38-ac1.err")"; fi

# AC1: same-kind prefix MUST NOT emit assemble: stderr
if ! grep -q 'assemble:' "$WORK/ac1-prefix.err"; then ok
else bad "T38 AC1 prefix stderr: $(head -c 200 "$WORK/ac1-prefix.err")"; fi

# AC1 leftover Kill: killed already in Through-line
if [ "$(kc_lines "$WORK/ac1-prefix.md")" = "$NONE_SHOWN" ]; then ok
else bad "T38 AC1 leftover placeholder: $(kc_lines "$WORK/ac1-prefix.md")"; fi

# State now empty placeholders unchanged (not leftover wording)
if python3 -c "
pkt = open('$WORK/ac1-prefix.md').read()
sn = pkt.split('## Through-line')[0]
for h in ('### Decisions', '### Hypotheses (alive)', '### Open'):
    rest = sn.rsplit(h, 1)[-1]
    # ### Open is last; rsplit on ### Open ship gaps is earlier
    if h == '### Open':
        rest = sn.rsplit('### Open', 1)[-1]
    body = rest.split('###', 1)[0] if h != '### Open' else rest
    lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
    assert lines == ['_none_'], (h, lines)
print('ok')
" 2>"$WORK/t38-ph.err" | grep -q ok; then ok
else bad "T38 State now placeholders: $(head -c 300 "$WORK/t38-ph.err")"; fi

# AC2: punct-stripped shorter ≤39 → both survive
if python3 -c "
pkt = open('$WORK/ac2-short.md').read()
sn = pkt.split('## Through-line')[0]
opens = sn.rsplit('### Open', 1)[-1]
assert '$AC2_SHORT' in opens
assert '$AC2_LONG' in opens
assert opens.count('- **open**:') == 2
print('ok')
" 2>"$WORK/t38-ac2.err" | grep -q ok; then ok
else bad "T38 AC2 short prefix: $(head -c 300 "$WORK/t38-ac2.err")"; fi

# AC4: conflict twin of open dropped; open once
if python3 -c "
pkt = open('$WORK/ac4-twin.md').read()
assert pkt.count('$LONG_OPEN') == 1
assert '- **conflict**:' not in pkt
sn = pkt.split('## Through-line')[0]
gaps = sn.split('### Open ship gaps', 1)[1].split('### Decisions', 1)[0]
assert '$LONG_OPEN' in gaps
print('ok')
" 2>"$WORK/t38-ac4.err" | grep -q ok; then ok
else bad "T38 AC4 twin drop: $(head -c 300 "$WORK/t38-ac4.err")"; fi

# AC4 stderr: one assemble: line containing conflict and open
if python3 -c "
err = open('$WORK/ac4-twin.err').read()
hits = [ln for ln in err.splitlines()
        if 'assemble:' in ln and 'conflict' in ln and 'open' in ln]
assert len(hits) == 1, hits
print('ok')
" 2>"$WORK/t38-ac4e.err" | grep -q ok; then ok
else bad "T38 AC4 stderr: $(head -c 200 "$WORK/ac4-twin.err") $(head -c 200 "$WORK/t38-ac4e.err")"; fi

# AC5: distinct conflict (no open twin) still renders + unrelated open
if python3 -c "
pkt = open('$WORK/ac5-distinct.md').read()
assert '$AC5_OPEN' in pkt
assert '$AC5_CF' in pkt
assert '- **conflict**:' in pkt
sn = pkt.split('## Through-line')[0]
opens = sn.rsplit('### Open', 1)[-1]
assert '$AC5_OPEN' in opens
tl = pkt.split('## Through-line', 1)[1].split('## appendix', 1)[0]
assert '$AC5_CF' in tl
print('ok')
" 2>"$WORK/t38-ac5.err" | grep -q ok; then ok
else bad "T38 AC5 distinct conflict: $(head -c 300 "$WORK/t38-ac5.err")"; fi

# AC6: same body killed+hypothesis MUST NOT collapse (not open/conflict)
if python3 -c "
pkt = open('$WORK/ac6-crosskind.md').read()
body = '$AC6_BODY'
assert pkt.count(body) == 2
assert '- **hypothesis**:' in pkt
assert '- **killed**:' in pkt
print('ok')
" 2>"$WORK/t38-ac6.err" | grep -q ok; then ok
else bad "T38 AC6 cross-kind keep: $(head -c 300 "$WORK/t38-ac6.err")"; fi

# AC7: ≥1 killed shown elsewhere → leftover exact already-shown (ac1)
if [ "$(kc_lines "$WORK/ac1-prefix.md")" = "$NONE_SHOWN" ]; then ok
else bad "T38 AC7 killed-elsewhere: $(kc_lines "$WORK/ac1-prefix.md")"; fi

# AC7: zero killed → exact _none_ (not already-shown substring)
if [ "$(kc_lines "$WORK/ac7-zero-killed.md")" = "$NONE" ]; then ok
else bad "T38 AC7 zero-killed: $(kc_lines "$WORK/ac7-zero-killed.md")"; fi

if python3 -c "
pkt = open('$WORK/ac7-zero-killed.md').read()
assert '$AC7_OPEN' in pkt
assert '- **killed**:' not in pkt
ap = pkt.split('## appendix', 1)[1]
assert '### Facts' not in ap
print('ok')
" 2>"$WORK/t38-ac7.err" | grep -q ok; then ok
else bad "T38 AC7 zero packet: $(head -c 300 "$WORK/t38-ac7.err")"; fi

# AC8: v1.9.0 trio + through_line killed
if python3 -c "
pkt = open('$WORK/ac8-trio.md').read()
sn = pkt.split('## Through-line')[0]
gaps = sn.split('### Open ship gaps', 1)[1].split('### Decisions', 1)[0]
bullets = [ln for ln in gaps.splitlines() if ln.startswith('- **')]
assert len(bullets) == 1, bullets
assert '$LONG_OPEN' in bullets[0]
assert pkt.count('$LONG_OPEN') == 1
assert '- **conflict**:' not in pkt
tl = pkt.split('## Through-line', 1)[1].split('## appendix', 1)[0]
assert 'killed: ac8 trio kill already in through-line' in tl
print('ok')
" 2>"$WORK/t38-ac8.err" | grep -q ok; then ok
else bad "T38 AC8 trio: $(head -c 300 "$WORK/t38-ac8.err")"; fi

if [ "$(kc_lines "$WORK/ac8-trio.md")" = "$NONE_SHOWN" ]; then ok
else bad "T38 AC8 leftover placeholder: $(kc_lines "$WORK/ac8-trio.md")"; fi

# packet_dedup unit bites — import FAIL until T2 is expected (tests-first)
if python3 -c "
import io, sys
sys.path.insert(0, '$HERE')
import packet_dedup as d
assert d.PREFIX_MIN == 40
assert d.PUNCT_STRIP == '.?!;:,'
assert d.NONE == '_none_'
assert d.NONE_ALREADY_SHOWN == '_none not already shown above_'
SHORT = '''$SHORT_OPEN'''
LONG = '''$LONG_OPEN'''
ps, pl = d.punct_strip_norm(SHORT), d.punct_strip_norm(LONG)
assert len(ps) >= 40
assert pl.startswith(ps) and pl != ps
a = [
  {'id': '1', 'kind': 'open', 'text': SHORT, 'order': 1},
  {'id': '2', 'kind': 'open', 'text': LONG, 'order': 2},
]
assert len(d.exact_dedup(a)) == 2
pc = d.prefix_collapse(list(a))
assert len(pc) == 1 and pc[0]['id'] == '1' and pc[0]['text'] == LONG
s39, s39l = '''$AC2_SHORT''', '''$AC2_LONG'''
assert len(d.punct_strip_norm(s39)) <= 39
b = [{'id': '1', 'kind': 'open', 'text': s39}, {'id': '2', 'kind': 'open', 'text': s39l}]
assert len(d.prefix_collapse(b)) == 2
err = io.StringIO()
tw = [{'id': 'o', 'kind': 'open', 'text': LONG}, {'id': 'c', 'kind': 'conflict', 'text': LONG}]
out = d.drop_open_conflict_twins(tw, err=err)
assert [e['kind'] for e in out] == ['open']
e = err.getvalue()
assert 'assemble:' in e and 'conflict' in e and 'open' in e
err2 = io.StringIO()
trio = [
  {'id': 's', 'kind': 'open', 'text': SHORT, 'facet': 'ship_gap'},
  {'id': 'l', 'kind': 'open', 'text': LONG, 'facet': 'ship_gap'},
  {'id': 'c', 'kind': 'conflict', 'text': LONG},
]
col = d.collapse_events(trio, err=err2)
assert len(col) == 1 and col[0]['kind'] == 'open' and col[0]['text'] == LONG
assert 'assemble:' in err2.getvalue()
assert d.kill_catalog_placeholder([], [{'kind': 'killed'}]) == d.NONE_ALREADY_SHOWN
assert d.kill_catalog_placeholder([], [{'kind': 'open'}]) == d.NONE
kh = [
  {'id': 'h', 'kind': 'hypothesis', 'text': 'same body xx'},
  {'id': 'k', 'kind': 'killed', 'text': 'same body xx'},
]
assert len(d.collapse_events(kh)) == 2
print('ok')
" 2>"$WORK/t38-unit.err" | grep -q ok; then ok
else bad "T38 packet_dedup units: $(head -c 300 "$WORK/t38-unit.err")"; fi

# ---- summary ----
echo "assemble-quality-test: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
