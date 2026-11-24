#!/usr/bin/env bash
# CDT-605 AC1-AC5/AC7 — skills/council/verify-span-coverage.sh
#
# The pre-judge-wave span audit mirrors the four mechanical CDT-537 judge caps
# (quote presence; token coverage excluding the Step-1 quote bundle; HEAD
# admissibility; elision lines) so a token-coverage gap surfaces BEFORE the
# judge wave is spawned and billed. This suite pins:
#   AC1 — the all-covered fixture (backtick spans incl. one holding `"`,
#         `Case N`, `AC X`, `path:N`) exits 0 with one summary line
#   AC2 — each cap has its own failing fixture, and each fixture exits 0 when
#         the matching SPAN_CHECK_* seam is flipped off (bite checks), plus a
#         bite on the `path:N` `/`-or-`.` guard
#   AC3 — uncovered output: JSON records naming claim_id, ac_id, token_class,
#         token on stdout; the first stderr line is `span-audit: case N: …`
#   AC4 — exit 0 covered / 8 uncovered / 64 usage-structural, and the
#         `engine.sh span-audit` subcommand propagates all three unchanged
#   AC5 — a claim with verify: null is skipped without error
#   AC7 — bash/awk/jq/sed only: no interpreter invocation in the deliverable
#
# The C5 contract is pinned too: a span holding a double quote is covered by a
# bundle read with `jq -r` (case 1) and the fixture proves `jq -c` would
# false-negative on the same bundle.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); every call runs in an
# isolated temp git repo and pins --head, so the audit is never
# worktree-dependent. No live council run, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
require_cmd jq
hermetic_init

fail=0
ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-span-coverage-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

VSC="$ROOT/skills/council/verify-span-coverage.sh"
FIX="$ROOT/skills/council/fixtures/verify-span-coverage"
ENGINE="$ROOT/skills/council/engine.sh"

if [ ! -f "$VSC" ]; then
  echo "FAIL: verify-span-coverage.sh is missing"
  exit 1
fi
if [ ! -f "$FIX/spec.md" ]; then
  echo "FAIL: missing fixture $FIX/spec.md"
  exit 1
fi

# ---- Fixture repo: spec.md at the root, one pinned commit -------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
cp "$FIX/spec.md" "$REPO/spec.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "fixture: CDT-605 span-audit spec"
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
# A second, unrelated sha — the C5 stale-HEAD class.
STALE_SHA=$(git -C "$REPO" commit -q --allow-empty -m stale >/dev/null 2>&1; git -C "$REPO" rev-parse HEAD)
git -C "$REPO" reset -q --hard "$HEAD_SHA"

# ---- Fixture JSON builders --------------------------------------------------
# The Step-1 quote bundle: the exact output of the recipe-awk quote command at
# spec.md:7, file_line = SOURCE_LOCATOR (investigator.md RECIPE STEP 1).
QUOTE_BLOB='7: - **A.** `engine.sh span-audit` exits 0 when every token of the quote — the
8:   spans `span-audit` and `raw "blob"`, the locators
9:   skills/council/engine.sh:85 and skills/council/engine-util.sh:20, plus the
10:   run Case 7 and the reference AC B — has a bundle line that holds it.
11:   Verify: bash skills/council/test-span-fixture.sh'

# claims_a: c0 = the AC A verify-claim, c1 = a verify-null claim (AC5).
CLAIMS_A="$TMP/claims-a.json"
jq -n \
  --arg loc "spec.md:7" \
  '[
    {claim_id: "c0", ac_id: "A", claim: "[AC-A] span audit", source_locator: $loc,
     claim_type: "factual", verify: "bash skills/council/test-span-fixture.sh", tool_budget: 8},
    {claim_id: "c1", ac_id: "B", claim: "[AC-B] no verify", source_locator: "spec.md:12",
     claim_type: "factual", verify: null, tool_budget: 5}
  ]' > "$CLAIMS_A"

# claims_fp: the false-positive AC (spec.md:17) — host:12, 14:32, v2:1.
CLAIMS_FP="$TMP/claims-fp.json"
jq -n --arg loc "spec.md:17" \
  '[{claim_id: "c0", ac_id: "A", claim: "[AC-A] false positives", source_locator: $loc,
     verify: "bash skills/council/test-span-fixture.sh"}]' > "$CLAIMS_FP"

# claims_null: only a verify-null claim.
CLAIMS_NULL="$TMP/claims-null.json"
jq -n '[{claim_id: "c0", ac_id: "B", source_locator: "spec.md:12", verify: null}]' \
  > "$CLAIMS_NULL"

# b <tool_use_id> <claim_id> <file_line> <cmd> <raw_blob> — one bundle object.
b() {
  jq -n --arg t "$1" --arg c "$2" --arg f "$3" --arg r "$4" --arg b "$5" \
    '{tool_use_id: $t, claim_id: $c, file_line: $f, reproducible_command: $r, raw_blob: $b}'
}

# The full covering set: every AC-A token has a non-quote admissible bundle line.
b_quote="$(b quote_1 c0 "spec.md:7" \
  "awk -v n=7 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR\": \"\$0}' spec.md" \
  "$QUOTE_BLOB")"
b_verify="$(b verify_1 c0 "spec.md:1" "bash skills/council/test-span-fixture.sh" \
  "HEAD=$HEAD_SHA
VERIFY exit=0
Case 7: PASS
AC B: PASS")"
b_loc1="$(b awk_1 c0 "skills/council/engine.sh:85" \
  "awk 'NR==85{print FILENAME\":\"NR\": \"\$0}' skills/council/engine.sh" \
  'skills/council/engine.sh:85:   span-audit)   cmd_span_audit "$@" ;;')"
b_grep="$(b grep_1 c0 "skills/council/engine.sh:1" \
  "grep -nF -e 'engine.sh span-audit' -e 'span-audit' -- skills/council/engine.sh" \
  '4:engine.sh span-audit — the pre-judge span audit gate')"
b_loc2="$(b awk_2 c0 "skills/council/engine-util.sh:20" \
  "awk 'NR==20{print FILENAME\":\"NR\": \"\$0}' skills/council/engine-util.sh" \
  'skills/council/engine-util.sh:20: Subcommands:')"
b_span="$(b grep_2 c0 "spec.md:8" \
  "grep -nF -e 'raw \"blob\"' -- spec.md" \
  '8:   spans `span-audit` and `raw "blob"`, the locators')"

BUNDLES_A="$TMP/bundles-a.json"
jq -n --argjson q "$b_quote" --argjson v "$b_verify" --argjson l1 "$b_loc1" \
      --argjson g "$b_grep" --argjson l2 "$b_loc2" --argjson s "$b_span" \
  '[$q, $v, $l1, $g, $l2, $s]' > "$BUNDLES_A"

# The quote-only set for the false-positive claim.
BUNDLES_FP="$TMP/bundles-fp.json"
FP_BLOB=$(awk -v n=17 'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR": "$0}' "$FIX/spec.md")
jq -n --arg b "$FP_BLOB" \
  '[{tool_use_id: "quote_1", claim_id: "c0", file_line: "spec.md:17",
     reproducible_command: "awk -v n=17 … spec.md", raw_blob: $b}]' > "$BUNDLES_FP"

# ---- Runner -----------------------------------------------------------------
# vsc <want-rc> <label> <claims> <bundles> [extra flags...] — runs the
# verifier from inside $REPO, keeping stdout in VSC_OUT and stderr in VSC_ERR.
VSC_RC=0; VSC_OUT=""; VSC_ERR=""; VSC_SCRIPT="$VSC"
vsc() {
  local want="$1" label="$2" claims="$3" bundles="$4"; shift 4
  VSC_OUT="$TMP/vsc.out"; VSC_ERR="$TMP/vsc.err"
  ( cd "$REPO" && bash "$VSC_SCRIPT" --claims "$claims" --bundles "$bundles" \
      --head "$HEAD_SHA" "$@" ) >"$VSC_OUT" 2>"$VSC_ERR"
  VSC_RC=$?
  if [ "$VSC_RC" = "$want" ]; then ok "$label (rc=$VSC_RC)"; return 0; fi
  fail_msg "$label (want rc=$want, got $VSC_RC)"
  sed 's/^/    out: /' "$VSC_OUT"
  sed 's/^/    err: /' "$VSC_ERR"
  return 0
}

# drop <out> <tool_use_id> <src> — a bundle-set copy without one bundle.
drop() {
  jq --arg t "$2" 'map(select(.tool_use_id != $t))' "$3" > "$1"
}
# with <out> <src> <bundle-json> — a bundle-set copy plus one bundle.
with() {
  jq --argjson x "$3" '. + [$x]' "$2" > "$1"
}

# assert_record <label> <token_class> <token> — the uncovered JSON carries it.
assert_record() {
  if jq -e --arg k "$2" --arg t "$3" \
       'any(.[]; .token_class == $k and .token == $t
            and .claim_id == "c0" and .ac_id == "A")' "$VSC_OUT" >/dev/null 2>&1; then
    ok "$1"
  else
    fail_msg "$1 — records: $(jq -c . "$VSC_OUT" 2>/dev/null)"
  fi
}

# =============================================================================
# 1. AC1 — the all-covered fixture exits 0, one summary line, silent stderr
# =============================================================================
vsc 0 "1 all-covered fixture (backtick spans, path:N, Case N, AC X)" "$CLAIMS_A" "$BUNDLES_A"
if [ "$(wc -l < "$VSC_OUT")" = "1" ] && grep -qF 'span-audit: covered' "$VSC_OUT"; then
  ok "1 covered run prints exactly one summary line"
else
  fail_msg "1 covered run summary: $(cat "$VSC_OUT")"
fi
if [ -s "$VSC_ERR" ]; then
  fail_msg "1 covered run wrote stderr: $(cat "$VSC_ERR")"
else
  ok "1 covered run is silent on stderr"
fi
if grep -qF '6 admissible bundle(s)' "$VSC_OUT"; then
  ok "1 summary reports the admissible bundle count"
else
  fail_msg "1 summary bundle count: $(cat "$VSC_OUT")"
fi

# The C5 contract, pinned on the same fixture: the `raw "blob"` span IS in the
# bundle read with jq -r, and a jq -c read of the same bundle would not hold it.
if jq -r '.[].raw_blob' "$BUNDLES_A" | grep -qF -- 'raw "blob"'; then
  ok "1 C5: jq -r extraction holds the span containing a double quote"
else
  fail_msg "1 C5: jq -r extraction lost the double-quoted span"
fi
if jq -c '.[].raw_blob' "$BUNDLES_A" | grep -qF -- 'raw "blob"'; then
  fail_msg "1 C5 bite: the fixture's span survives jq -c — the fixture is not a -c case"
else
  ok "1 C5 bite: the same span is invisible to jq -c (the class the verifier must survive)"
fi

# AC5 — verify-null-only claim set: audited set is empty, exit 0.
vsc 0 "5 verify-null claim is skipped" "$CLAIMS_NULL" "$BUNDLES_A"
if grep -qF '0 audited claim(s)' "$VSC_OUT"; then
  ok "5 skipped claim reports 0 audited claims"
else
  fail_msg "5 audited-count line: $(cat "$VSC_OUT")"
fi

# =============================================================================
# 2. Cap (a) quote presence — case 1
# =============================================================================
B_QM="$TMP/bundles-no-quote.json"
drop "$B_QM" quote_1 "$BUNDLES_A"
vsc 8 "2a missing Step-1 quote bundle is uncovered" "$CLAIMS_A" "$B_QM"
first_err="$(head -1 "$VSC_ERR")"
case "$first_err" in
  "span-audit: case 1: "*) ok "2a first stderr line is the case-1 contract line" ;;
  *) fail_msg "2a first stderr line: $first_err" ;;
esac
assert_record "2a record names claim c0 / AC A / class quote" "quote" "spec.md:7"
# A quote bundle anchored on a different path is not this claim's quote.
B_QMIS="$TMP/bundles-misanchored-quote.json"
jq --arg t "spec.md:99" 'map(if .tool_use_id == "quote_1" then .file_line = "other.md:7" else . end)' \
  "$BUNDLES_A" > "$B_QMIS"
vsc 8 "2a quote bundle anchored on another path is not the quote" "$CLAIMS_A" "$B_QMIS"

# =============================================================================
# 3. Cap (b) token coverage — case 2, one record per uncovered token class
# =============================================================================
B_SPAN="$TMP/bundles-no-span.json"
drop "$B_SPAN" grep_1 "$BUNDLES_A"
vsc 8 "3a uncovered backtick span is uncovered" "$CLAIMS_A" "$B_SPAN"
first_err="$(head -1 "$VSC_ERR")"
case "$first_err" in
  "span-audit: case 2: "*) ok "3a first stderr line is the case-2 contract line" ;;
  *) fail_msg "3a first stderr line: $first_err" ;;
esac
assert_record "3a record names the backtick span" "backtick" "engine.sh span-audit"
# Coverage is per token, not per bundle: `span-audit` is also held by the
# grep_2 bundle, so dropping grep_1 alone must not report it.
if jq -e 'length == 1' "$VSC_OUT" >/dev/null 2>&1; then
  ok "3a a token another bundle still covers stays covered"
else
  fail_msg "3a expected exactly 1 record: $(jq -c . "$VSC_OUT")"
fi

B_SPANS="$TMP/bundles-no-spans.json"
jq 'map(select(.tool_use_id != "grep_1" and .tool_use_id != "grep_2"))' \
  "$BUNDLES_A" > "$B_SPANS"
vsc 8 "3a2 dropping every span-covering bundle reports each span" "$CLAIMS_A" "$B_SPANS"
assert_record "3a2 engine.sh span-audit record" "backtick" "engine.sh span-audit"
assert_record "3a2 raw-blob span record" "backtick" "raw \"blob\""
# `span-audit` stays covered: the b_loc1 dispatch line holds it.
if jq -e 'length == 2' "$VSC_OUT" >/dev/null 2>&1; then
  ok "3a2 uncovered list is machine-routable JSON with exactly 2 records"
else
  fail_msg "3a2 uncovered list: $(cat "$VSC_OUT")"
fi

B_CS="$TMP/bundles-no-case-ac.json"
drop "$B_CS" verify_1 "$BUNDLES_A"
vsc 8 "3b uncovered Case N / AC X tokens are uncovered" "$CLAIMS_A" "$B_CS"
assert_record "3b Case N token class record" "Case N" "Case 7"
assert_record "3b AC X token class record" "AC X" "AC B"

B_PN="$TMP/bundles-no-pathn.json"
drop "$B_PN" awk_2 "$BUNDLES_A"
vsc 8 "3c uncovered path:N token is uncovered" "$CLAIMS_A" "$B_PN"
assert_record "3c path:N token class record" "path:N" "skills/council/engine-util.sh:20"

# The exclusion rule: `raw "blob"` is held by the Step-1 quote bundle itself.
# Dropping its only non-quote bundle MUST still report it — coverage from the
# quote bundle does not count.
B_QONLY="$TMP/bundles-quote-only.json"
drop "$B_QONLY" grep_2 "$BUNDLES_A"
vsc 8 "3d a token held only by the quote bundle is uncovered" "$CLAIMS_A" "$B_QONLY"
assert_record "3d the quote bundle's own span is reported" "backtick" "raw \"blob\""
if printf '%s\n' "$QUOTE_BLOB" | grep -qF -- 'raw "blob"'; then
  ok "3d fixture sanity: the quote bundle does hold that span"
else
  fail_msg "3d fixture: the quote bundle does not hold the span"
fi

# =============================================================================
# 4. Cap (c) HEAD admissibility — the C5 stale-HEAD rule
# =============================================================================
b_stale="$(b grep_3 c0 "spec.md:9" "grep -nF -e 'engine-util.sh' -- spec.md" \
  "HEAD=$STALE_SHA
9:   skills/council/engine.sh:85 and skills/council/engine-util.sh:20, plus the")"
# Drop the bundle that covers the engine-util.sh:20 locator and replace it with
# one whose run output is at a stale HEAD: the token loses its only coverage.
B_STALE="$TMP/bundles-stale.json"
jq --argjson x "$b_stale" 'map(select(.tool_use_id != "awk_2")) + [$x]' "$BUNDLES_A" > "$B_STALE"
vsc 8 "4b stale-HEAD bundle is inadmissible" "$CLAIMS_A" "$B_STALE"
first_err="$(head -1 "$VSC_ERR")"
case "$first_err" in
  "span-audit: case 3: "*) ok "4b first stderr line is the case-3 contract line" ;;
  *) fail_msg "4b first stderr line: $first_err" ;;
esac
if jq -e --arg s "$STALE_SHA" 'any(.[]; .token_class == "HEAD" and .token == $s)' "$VSC_OUT" >/dev/null; then
  ok "4b record names the offending stale sha"
else
  fail_msg "4b stale-sha record: $(jq -c . "$VSC_OUT")"
fi
assert_record "4b the token it alone covered becomes uncovered" "path:N" "skills/council/engine-util.sh:20"
# A short --head (7 hex) admits a bundle naming the full sha it prefixes.
SHORT_HEAD=$(printf '%s' "$HEAD_SHA" | cut -c1-7)
VSC_HEAD="$SHORT_HEAD"
( cd "$REPO" && bash "$VSC" --claims "$CLAIMS_A" --bundles "$BUNDLES_A" \
    --head "$SHORT_HEAD" ) >"$TMP/short.out" 2>"$TMP/short.err"
if [ $? -eq 0 ]; then ok "4c a 7-hex --head prefixes the bundles' full sha"; else
  fail_msg "4c short --head run: $(cat "$TMP/short.err")"
fi

# =============================================================================
# 5. Cap (d) elision lines — case 4
# =============================================================================
b_elided="$(b grep_4 c0 "spec.md:1" "sed -n '7,11p' spec.md" \
  "7: - **A.** \`engine.sh span-audit\` exits 0 when every token of the quote — the
...
8:   spans \`span-audit\` and \`raw \"blob\"\`, the locators")"
B_EL="$TMP/bundles-elision.json"
jq --argjson x "$b_elided" '. + [$x]' "$BUNDLES_A" > "$B_EL"
vsc 8 "5 elision line is uncovered work" "$CLAIMS_A" "$B_EL"
if grep -qF 'span-audit: case 4:' "$VSC_ERR"; then
  ok "5 case-4 stderr line names the elision"
else
  fail_msg "5 case-4 stderr line: $(cat "$VSC_ERR")"
fi
if jq -e 'any(.[]; .token_class == "elision" and .token == "...")' "$VSC_OUT" >/dev/null; then
  ok "5 record names the elision marker"
else
  fail_msg "5 elision record: $(jq -c . "$VSC_OUT")"
fi

# =============================================================================
# 6. AC2 bite checks — removing a check makes its own fixture pass
# =============================================================================
bite() {  # bite <label> <seam> <fixture-claims> <fixture-bundles>
  local label="$1" seam="$2" claims="$3" bundles="$4"
  local mut="$TMP/mut-$seam.sh"
  sed "s/^$seam=1$/$seam=0/" "$VSC" > "$mut"
  if ! grep -q "^$seam=0\$" "$mut"; then
    fail_msg "$label — the $seam seam is not sed-addressable (test bug)"
    return 0
  fi
  ( cd "$REPO" && bash "$mut" --claims "$claims" --bundles "$bundles" \
      --head "$HEAD_SHA" ) >"$TMP/bite.out" 2>"$TMP/bite.err"
  local rc=$?
  if [ "$rc" = 0 ]; then
    ok "bite: disabling $seam makes the $label fixture pass"
  else
    fail_msg "bite: disabling $seam left the $label fixture failing (rc=$rc)"
    sed 's/^/    err: /' "$TMP/bite.err"
  fi
  rm -f -- "$mut"
}
bite "quote presence" SPAN_CHECK_QUOTE "$CLAIMS_A" "$B_QM"
bite "token coverage" SPAN_CHECK_TOKENS "$CLAIMS_A" "$B_SPAN"
bite "HEAD admissibility" SPAN_CHECK_HEAD "$CLAIMS_A" "$B_STALE"
bite "elision line" SPAN_CHECK_ELISION "$CLAIMS_A" "$B_EL"

# Bite on the path:N false-positive guard: dropping the `/`-or-`.` requirement
# must turn the host:12 / 14:32 / v2:1 AC into uncovered locator tokens.
MUT_PN="$TMP/mut-pathn.sh"
sed 's%&& (index(p1, "/") > 0 || index(p1, ".") > 0)) {%) {%' "$VSC" > "$MUT_PN"
if cmp -s "$VSC" "$MUT_PN"; then
  fail_msg "bite: the path:N guard is not sed-addressable (test bug)"
else
  # The mutant needs its own fixture: with the guard off, host:12 becomes a
  # locator token the quote-only bundle set cannot cover.
  ( cd "$REPO" && bash "$MUT_PN" --claims "$CLAIMS_FP" --bundles "$BUNDLES_FP" \
      --head "$HEAD_SHA" ) >"$TMP/mut-pn.out" 2>"$TMP/mut-pn.err"
  if [ $? -eq 8 ] \
    && jq -e 'any(.[]; .token == "host:12")' "$TMP/mut-pn.out" >/dev/null 2>&1; then
    ok "bite: dropping the path:N guard turns host:12 into a locator token"
  else
    fail_msg "bite: path:N guard mutant (out: $(cat "$TMP/mut-pn.out"))"
  fi
fi
# The unmutated verifier passes the same fixture: no locator token is extracted.
vsc 0 "6 host:12 / 14:32 / v2:1 are not locator tokens" "$CLAIMS_FP" "$BUNDLES_FP"

# =============================================================================
# 7. AC4 — usage / structural 64, and the engine subcommand propagates
# =============================================================================
bash "$VSC" --bundles "$BUNDLES_A" >"$TMP/u1.err" 2>&1
[ $? -eq 64 ] && grep -qF 'usage: span-audit' "$TMP/u1.err" \
  && ok "7 missing --claims exits 64 with the usage line" \
  || fail_msg "7 missing --claims contract"
bash "$VSC" --claims "$CLAIMS_A" --bundles "$BUNDLES_A" --nope >"$TMP/u2.err" 2>&1
[ $? -eq 64 ] && grep -qF 'unknown flag: --nope' "$TMP/u2.err" \
  && ok "7 unknown flag exits 64" || fail_msg "7 unknown flag contract"
printf '%s' '{"not":"an array"}' > "$TMP/obj.json"
bash "$VSC" --claims "$TMP/obj.json" --bundles "$BUNDLES_A" --head "$HEAD_SHA" \
  >"$TMP/u3.err" 2>&1
[ $? -eq 64 ] && grep -qF 'not a JSON array' "$TMP/u3.err" \
  && ok "7 non-array claims file exits 64 (unusable input)" \
  || fail_msg "7 non-array claims contract"
printf '%s' '[{"claim_id": ' > "$TMP/trunc.json"
bash "$VSC" --claims "$TMP/trunc.json" --bundles "$BUNDLES_A" --head "$HEAD_SHA" \
  >"$TMP/u4.err" 2>&1
[ $? -eq 64 ] && grep -qF 'not valid JSON' "$TMP/u4.err" \
  && ok "7 unparseable claims file exits 64" || fail_msg "7 unparseable claims contract"
bash "$VSC" --claims "$CLAIMS_A" --bundles "$BUNDLES_A" --head "deadbe" \
  >"$TMP/u5.err" 2>&1
[ $? -eq 64 ] && grep -qF '7-40 hex' "$TMP/u5.err" \
  && ok "7 a 6-hex --head exits 64 (below the 7-hex minimum)" \
  || fail_msg "7 short --head contract"
jq -n '[{claim_id: "c0", ac_id: "A", source_locator: "no-line-number.md", verify: "x"}]' \
  > "$TMP/badloc.json"
bash "$VSC" --claims "$TMP/badloc.json" --bundles "$BUNDLES_A" --head "$HEAD_SHA" \
  >"$TMP/u6.err" 2>&1
[ $? -eq 64 ] && grep -qF 'source_locator' "$TMP/u6.err" \
  && ok "7 a source_locator without <path>:<N> exits 64" \
  || fail_msg "7 bad locator contract"
jq -n '[{claim_id: "c0", ac_id: "A", source_locator: "absent.md:3", verify: "x"}]' \
  > "$TMP/absent.json"
( cd "$REPO" && bash "$VSC" --claims "$TMP/absent.json" --bundles "$BUNDLES_A" --head "$HEAD_SHA" \
  >"$TMP/u7.err" 2>&1 )
[ $? -eq 64 ] && grep -qF 'absent in the worktree' "$TMP/u7.err" \
  && ok "7 a locator whose file is absent exits 64" || fail_msg "7 absent file contract"

# Engine subcommand propagation: same three codes, byte-identical payloads.
eng() {  # eng <want> <label> <claims> <bundles>
  local want="$1" label="$2" claims="$3" bundles="$4" rc=0
  ( cd "$REPO" && bash "$ENGINE" span-audit --claims "$claims" --bundles "$bundles" \
      --head "$HEAD_SHA" ) >"$TMP/eng.out" 2>"$TMP/eng.err" || rc=$?
  if [ "$rc" != "$want" ]; then
    fail_msg "$label (want rc=$want, got $rc)"
    sed 's/^/    err: /' "$TMP/eng.err"
    return 0
  fi
  if [ "$want" = 0 ] && ! grep -qF 'span-audit: covered' "$TMP/eng.out"; then
    fail_msg "$label: no summary line"; return 0
  fi
  if [ "$want" = 8 ] && ! head -1 "$TMP/eng.err" | grep -qF 'span-audit: case '; then
    fail_msg "$label: no case line"; return 0
  fi
  ok "$label (rc=$rc)"
}
eng 0 "7 engine.sh span-audit propagates 0" "$CLAIMS_A" "$BUNDLES_A"
eng 8 "7 engine.sh span-audit propagates 8" "$CLAIMS_A" "$B_SPAN"
bash "$ENGINE" span-audit --claims "$CLAIMS_A" >"$TMP/u8.err" 2>&1
[ $? -eq 64 ] && grep -qF 'usage: span-audit' "$TMP/u8.err" \
  && ok "7 engine.sh span-audit propagates 64" || fail_msg "7 engine 64 contract"
if bash "$ENGINE" help 2>&1 | grep -qF 'span-audit'; then
  ok "7 engine.sh usage names the span-audit subcommand"
else
  fail_msg "7 engine.sh usage text has no span-audit entry"
fi

# =============================================================================
# 8. AC7 — bash/awk/jq/sed only: no interpreter in the deliverable
# =============================================================================
if sed 's/#.*//' "$VSC" | grep -qE '(^|[;&|(])(node|python3?|ruby|perl)([ (]|$)'; then
  fail_msg "8 the verifier invokes an interpreter"
  sed 's/#.*//' "$VSC" | grep -nE '(node|python3?|ruby|perl)' | sed 's/^/    /'
else
  ok "8 verifier is bash/awk/jq/sed only (no interpreter invocation)"
fi
if grep -qF 'jq -c' "$VSC"; then
  fail_msg "8 the verifier extracts a raw_blob with jq -c (the C5 defect class)"
else
  ok "8 verifier never extracts a raw_blob with jq -c"
fi
if grep -qF 'jq -r' "$VSC"; then
  ok "8 verifier extracts raw_blob with jq -r"
else
  fail_msg "8 verifier has no jq -r extraction"
fi

# =============================================================================
# 9. AC6/AC8 — the wiring and the operational copy exist and stay in order
# =============================================================================
WF="$ROOT/skills/council/workflow.js"
P45="$ROOT/skills/council/phases-4-5.md"
P67="$ROOT/skills/council/phases-6-7.md"
SPEC13="$ROOT/specs/core/SPEC-013-adversarial-council-tribunal.md"
wf_call=$(grep -n "runEngine('span-audit'" "$WF" | head -1 | cut -d: -f1)
judge_at=$(grep -n "^  // --- Judge ---" "$WF" | head -1 | cut -d: -f1)
if [ -n "$wf_call" ] && [ -n "$judge_at" ] && [ "$wf_call" -lt "$judge_at" ]; then
  ok "6 workflow.js calls span-audit before the judge parts spawn"
else
  fail_msg "6 workflow.js span-audit call missing or after the judge spawn (call=$wf_call judge=$judge_at)"
fi
if grep -qF "exit_code: spanAudit.status" "$WF"; then
  ok "6 workflow.js fails closed with the engine exit (no judge spawn)"
else
  fail_msg "6 workflow.js does not propagate the span-audit exit"
fi
if grep -qF 'engine.sh span-audit' "$P45" \
  && grep -qF 'span-audit: case N:' "$P45" \
  && grep -qF 'rc` 8' "$P45"; then
  ok "6 phases-4-5.md § Phase 5 holds the hand-run fence (rc 8 → re-collection)"
else
  fail_msg "6 phases-4-5.md has no Phase-5 span-audit fence"
fi
if grep -qF 'engine.sh span-audit' "$P67"; then
  ok "8 phases-6-7.md cross-references the span audit"
else
  fail_msg "8 phases-6-7.md M14 section has no span-audit cross-reference"
fi
if grep -qF 'MUST (CDT-605) audit WP 1-16 token coverage' "$SPEC13" \
  && grep -qF 'CDT-605: **Pre-judge-wave span audit.**' "$SPEC13"; then
  ok "8 SPEC-013 carries the MUST bullet and the dated Version History row"
else
  fail_msg "8 SPEC-013 is missing the CDT-605 MUST bullet or the changelog row"
fi
if grep -qF 'span-audit)      cmd_span_audit' "$ROOT/skills/council/engine.sh" \
  && grep -qF 'bash "$SPAN_VERIFY"' "$ROOT/skills/council/engine-report-path.sh"; then
  ok "4 engine.sh dispatches span-audit to the argv wrapper (no re-derived checks)"
else
  fail_msg "4 engine dispatch or the cmd_span_audit wrapper is missing"
fi

# Guard: nothing wrote into the live worktree.
if git -C "$ROOT" status --porcelain | grep -qF 'skills/council/fixtures/verify-span-coverage'; then
  ok "8 guard: fixture dir is the suite's own input (untracked work in progress)"
fi

# ---- Summary ----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
  echo "PASS: test-verify-span-coverage.sh"
  exit 0
else
  echo "FAIL: test-verify-span-coverage.sh"
  exit 1
fi
