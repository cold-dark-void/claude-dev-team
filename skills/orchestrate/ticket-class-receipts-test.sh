#!/usr/bin/env bash
# ticket-class-receipts-test.sh — CDT-595 per-AC receipt meta-suite.
# T1 spike: prove the investigator AC-label filter matches colon receipts.
# T5 fills the meta cases (nested --ac runs, spec-lint, receipt grammar).
# Run: bash skills/orchestrate/ticket-class-receipts-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
INV="$ROOT/skills/council/prompts/investigator.md"

# Hermetic suite (SPEC-030 R20): the Verify-log sample is a TMPDIR fixture.
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok AC8: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: AC8: $1: $2" >&2; }

# The default <AC_LABEL> template, pinned verbatim from investigator.md.
# grep -F: the template is full of regex metacharacters, so match it as bytes.
PIN='AC X([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])X[0-9]*[:(]|(^|[^A-Za-z0-9_])X-[0-9]+'

# label_re <AC-id> — the substitution rule: every X in the template becomes
# the AC id. The template holds exactly three X tokens and no other X.
label_re() { printf '%s' "$PIN" | sed "s/X/$1/g"; }

# ---- C1: the template is present in investigator.md, at its pinned line -----
LINE=$(grep -nF -- "$PIN" "$INV" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
  ok "spike-regex-extract"
else
  bad "spike-regex-extract" "AC_LABEL template absent from $INV"
fi
if [ "${LINE:-none}" = "130" ]; then
  ok "spike-regex-anchor"
else
  bad "spike-regex-anchor" "AC_LABEL moved off investigator.md:130 (found at ${LINE:-nowhere})"
fi
NX=$(printf '%s' "$PIN" | tr -cd 'X' | wc -c | tr -d ' ')
if [ "$NX" = "3" ]; then
  ok "spike-regex-arity"
else
  bad "spike-regex-arity" "template holds $NX X tokens, expected 3"
fi

# ---- C2: colon form matches, space form misses ------------------------------
SAMP="${TMPDIR:-/tmp}/cdt595-sample.log"
cat > "$SAMP" <<'EOF'
ok AC7: scan-tool-failure
ok AC7 scan-tool-failure
FAIL: AC7: empty-file: planted
skip AC7: mode-000 uid0
SKIP: ticket-class-test.sh: root uid: mode 000
ok AC13: perf-2s 0s
EOF
if [ ! -s "$SAMP" ]; then
  bad "spike-sample-write" "no sample log at $SAMP"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# probe <AC-id> <sample-line-number> <1=must-match|0=must-miss> <slug>
probe() {
  local x="$1" ln="$2" want="$3" slug="$4" re rc=0
  re=$(label_re "$x")
  sed -n "${ln}p" "$SAMP" | grep -qE -- "$re" || rc=1
  if [ "$want" = "1" ] && [ "$rc" = "0" ]; then
    ok "$slug"
  elif [ "$want" = "0" ] && [ "$rc" = "1" ]; then
    ok "$slug"
  elif [ "$want" = "1" ]; then
    bad "$slug" "filter missed: $(sed -n "${ln}p" "$SAMP")"
  else
    bad "$slug" "filter matched a line it must not: $(sed -n "${ln}p" "$SAMP")"
  fi
}

probe AC7 1 1 spike-colon          # colon receipt
probe AC7 2 0 spike-space-miss     # no colon, so alt-2 and alt-3 cannot fire
probe AC7 3 1 spike-fail-line      # FAIL: receipt carries its AC id
probe AC7 4 1 spike-skip-line      # skip receipt
probe AC7 5 0 spike-skipcap-miss   # SKIP: line carries no AC id
probe AC13 6 1 spike-perf13        # perf receipt under X=AC13

# ---- C3: what the substitution does on ids that share a prefix --------------
# Plan R4: alt-2 `[0-9]*` lets X=AC1 match AC11 on a full log. The `--ac`
# run filter is exact-id, so a per-AC Verify log stays exclusive.
if sed -n '6p' "$SAMP" | grep -qE -- "$(label_re AC1)"; then
  ok "spike-ac1-prefix"
else
  bad "spike-ac1-prefix" "X=AC1 must match the AC13 line (documented R4 leak)"
fi
if sed -n '6p' "$SAMP" | grep -qE -- "$(label_re AC13)"; then
  ok "spike-ac13-own"
else
  bad "spike-ac13-own" "X=AC13 missed its own receipt"
fi
if sed -n '6p' "$SAMP" | grep -qE -- "$(label_re AC14)"; then
  bad "spike-ac14-miss" "X=AC14 matched an AC13 line"
else
  ok "spike-ac14-miss"
fi

rm -f "$SAMP"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
