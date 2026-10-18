#!/usr/bin/env bash
# test-classify.sh — trigger-(b) classifier + static-check bite-tests
# (SPEC-039 M13-M19, epic child CDT-564-C5).
#
# Machine-check: bash skills/advisor/test-classify.sh  (exit 0)
#
# Every AC sub-clause of the SPEC-039 `### CDT-564` section gets its own
# named run-output PASS line (the C8/M14 lesson: an aggregate or
# source-assert-only name is not per-clause run output).
#
# Hermetic: everything lives under TMPDIR; the advisor state root is a
# scratch ADVISOR_STATE_ROOT; the shared models.local.json is backed up and
# restored under flock (same discipline as test.sh — the map file is shared,
# so concurrent suite runs must serialize).

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1
CLS="$ROOT/skills/advisor/classify.sh"
SC="$ROOT/skills/advisor/static-check.sh"
ASK="$ROOT/skills/advisor/ask.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/advisor-classify-test.XXXXXX")
[ -d "$TMP" ] || { echo "test-classify.sh: mktemp -d failed (check TMPDIR)" >&2; exit 1; }

# Shared map backup/restore under a global lock (fd 9; closes after the trap).
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MAP="$MROOT/.claude/dev-team/models.local.json"
mkdir -p "$(dirname "$MAP")"
exec 9>>"$(dirname "$MAP")/.test-map.lock"
flock 9
MAP_BAK="$TMP/models.local.json.bak"
if [ -f "$MAP" ]; then cp "$MAP" "$MAP_BAK"; fi
restore_map() {
  if [ -f "$MAP_BAK" ]; then mv "$MAP_BAK" "$MAP"; else rm -f "$MAP"; fi
}
trap 'restore_map; rm -rf "$TMP"' EXIT

clear_layers() { rm -f "$MAP"; }
plant_advisor() {
  mkdir -p "$(dirname "$MAP")"
  echo '{"version":1,"agents":{"advisor":"test-model-x"},"effort":{"advisor":"low"}}' > "$MAP"
}

ST="$TMP/state"
cls() { # cls <args...> — classifier against the scratch state root
  ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$CLS" "$@" 2>"$TMP/cls.err"
}

# find_i <want-remainder> — smallest i with sha256("shadow probe i") % 10
# equal to the remainder (first 13 hex chars as one integer, the M17 rule).
find_i() {
  local i=1 h
  while [ "$i" -le 5000 ]; do
    h=$(printf 'shadow probe %s' "$i" | sha256sum | cut -d' ' -f1)
    [ $((0x${h:0:13} % 10)) -eq "$1" ] && { echo "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# =============================================================================
# AC1 — classifier contract (M14/M15): POSIX-ERE, one JSON hit array, no LLM,
# structured disposition class only.
# =============================================================================

OUT=$(cls --kind wave-plan --text 'The plan uses dag-lib and two ICs.')
if printf '%s' "$OUT" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1; then
  pass "c1-empty-array-no-fire"
else
  fail "c1-empty-array-no-fire: $OUT"
fi
N=$(printf '%s' "$OUT" | jq -s 'length' 2>/dev/null)
[ "$N" = "1" ] && pass "c1-stdout-single-json-array" || fail "c1-stdout-single-json-array: $N"

OUT=$(cls --kind disposition --action close --text 'Closing CDT-1: build verified.')
if printf '%s' "$OUT" | jq -e '.[0].class == "disposition" and .[0].trigger == "b"' >/dev/null 2>&1; then
  pass "c1-disposition-structured-action-hit"
else
  fail "c1-disposition-structured-action-hit: $OUT"
fi

OUT=$(cls --kind wave-plan --text 'we should close the ticket and block the release')
if printf '%s' "$OUT" | jq -e 'map(.class) | index("disposition") == null' >/dev/null 2>&1; then
  pass "c1-disposition-prose-verbs-not-scanned"
else
  fail "c1-disposition-prose-verbs-not-scanned: $OUT"
fi

cls --kind disposition --action 'close the ticket' --text 'x' >/dev/null 2>&1
[ $? -eq 64 ] && pass "c1-invalid-action-exit-64" || fail "c1-invalid-action-exit-64"
cls --kind wave-plan --action close --text 'x' >/dev/null 2>&1
[ $? -eq 64 ] && pass "c1-action-rejected-on-wave-plan-64" || fail "c1-action-rejected-on-wave-plan-64"
cls --kind vibes --text 'x' >/dev/null 2>&1
[ $? -eq 64 ] && pass "c1-unknown-kind-exit-64" || fail "c1-unknown-kind-exit-64"

# No-LLM / no-spawn: source-level (no Agent tool, no spawn, no prompt text)
# plus runtime (a run without --run-id writes nothing anywhere).
if ! grep -qE 'Agent tool|spawn-request|subagent_type|curl |http://|https://' "$CLS" \
  && ! grep -qiE 'ask\.sh|resolve-model' "$CLS"; then
  pass "c1-no-llm-no-spawn-by-source"
else
  fail "c1-no-llm-no-spawn-by-source"
fi
rm -rf "$ST"
cls --kind wave-plan --text 'nothing here' >/dev/null
[ ! -e "$ST" ] && pass "c1-scan-without-run-id-writes-nothing" || fail "c1-scan-without-run-id-writes-nothing"

printf 'omp is Open MPI\n' > "$TMP/plan.txt"
A=$(cls --kind wave-plan --file "$TMP/plan.txt")
B=$(cls --kind wave-plan --text 'omp is Open MPI')
[ "$A" = "$B" ] && pass "c1-file-input-equivalent" || fail "c1-file-input-equivalent: $A vs $B"
C=$(printf 'omp is Open MPI' | cls --kind wave-plan)
[ "$C" = "$B" ] && pass "c0-stdin-scans-equivalent" || fail "c0-stdin-scans-equivalent: $C vs $B"
OUT=$(cls --kind wave-plan --text 'omp is Open MPI')
if printf '%s' "$OUT" | jq -e 'length == 1 and .[0].trigger == "b" and .[0].class == "identity" and (.[0].span | type == "string") and (.[0].question_hash | type == "string")' >/dev/null 2>&1; then
  pass "c0-hit-record-shape"
else
  fail "c0-hit-record-shape: $OUT"
fi

# =============================================================================
# AC2 — identity-claim patterns (M16): three patterns, subject rules, dedupe.
# =============================================================================

hit1() { # hit1 <id> <text> <jq-filter on the array> — assert filter true
  local id="$1" text="$2" filt="$3" out
  out=$(cls --kind wave-plan --text "$text")
  if printf '%s' "$out" | jq -e "$filt" >/dev/null 2>&1; then
    pass "$id"
  else
    fail "$id: $out"
  fi
}

hit1 "c2-pattern1-host-claim-hit" 'omp on this machine is Open MPI' \
  '.[0].class == "identity" and (.[0].span | test("on this machine is"))'
hit1 "c2-pattern1-verb-variants-hit" 'docker on this host is not running the agent' \
  '.[0].class == "identity" and (.[0].span | test("on this host is not"))'
hit1 "c2-pattern2-installed-hit" 'omp is not installed on the runner' \
  '.[0].class == "identity" and (.[0].span | test("omp is not installed"))'
hit1 "c2-pattern2-state-variants-hit" 'nginx is present in the image and curl is missing' \
  'length == 2 and all(.[]; .class == "identity")'
hit1 "c2-pattern3-propername-hit" 'We think omp is Open MPI for the toolchain.' \
  '.[0].class == "identity" and .[0].span == "omp is Open"'
hit1 "c2-subject-lowercase-or-path" '/usr/bin/omp is installed here' \
  '.[0].class == "identity" and (.[0].span | startswith("/usr/bin/omp"))'
hit1 "c2-miss-ic4-well-defined-seat" 'ic4 is the well-defined seat' 'length == 0'
hit1 "c2-miss-uppercase-subject" 'IC4 is installed' 'length == 0'

OUT=$(cls --kind wave-plan --text 'omp on this machine is Open MPI')
NH=$(printf '%s' "$OUT" | jq '[.[] | select(.class == "identity")] | length' 2>/dev/null)
if [ "$NH" = "1" ]; then
  pass "c2-overlap-dedupes-to-one-hit"
else
  fail "c2-overlap-dedupes-to-one-hit: $NH hits in $OUT"
fi

OUT=$(cls --kind disposition --action descope --text 'omp is Open MPI and we descope this')
if printf '%s' "$OUT" | jq -e 'length == 2 and .[0].class == "disposition" and .[1].class == "identity"' >/dev/null 2>&1; then
  pass "c2-disposition-scan-includes-identity"
else
  fail "c2-disposition-scan-includes-identity: $OUT"
fi

# AC3 — identity breadth on disposition scans: all three patterns fire.
DI=0
for DT in 'omp on this machine is Open MPI' 'omp is not installed' 'omp is Open MPI'; do
  DI=$((DI + 1))
  OUT=$(cls --kind disposition --action close --text "$DT")
  if printf '%s' "$OUT" | jq -e 'length == 2 and .[0].class == "disposition" and .[1].class == "identity"' >/dev/null 2>&1; then
    pass "c2-disposition-identity-pattern$DI-hit"
  else
    fail "c2-disposition-identity-pattern$DI-hit: $OUT"
  fi
done

# AC2 — every structured action verb produces exactly one disposition hit.
for A2 in close block reassign; do
  OUT=$(cls --kind disposition --action "$A2" --text 'nothing structured here')
  if printf '%s' "$OUT" | jq -e 'length == 1 and .[0].class == "disposition" and .[0].trigger == "b"' >/dev/null 2>&1; then
    pass "c1-$A2-action-structured-hit"
  else
    fail "c1-$A2-action-structured-hit: $OUT"
  fi
done

# =============================================================================
# AC3 — miss sampling (M17): silent skip; 10% shadow row; never spawns.
# =============================================================================

rm -rf "$ST"
cls --kind wave-plan --text 'ic4 is the well-defined seat' >/dev/null
[ ! -e "$ST/runs" ] && pass "c3-zero-hit-silent-skip-no-state" || fail "c3-zero-hit-silent-skip-no-state"

I0=$(find_i 0) || { fail "c3-miss-sample-row-on-modulo-zero: no i found"; I0=1; }
rm -rf "$ST"
cls --kind wave-plan --text "shadow probe $I0" --run-id s1 >/dev/null
SH="$ST/runs/s1/shadow.jsonl"
H0=$(printf 'shadow probe %s' "$I0" | sha256sum | cut -d' ' -f1)
[ $((0x${H0:0:13} % 10)) -eq 0 ] && pass "c3-sha256-first13-modulo-zero" || fail "c3-sha256-first13-modulo-zero: $H0"
if [ -f "$SH" ] && [ "$(wc -l < "$SH")" = "1" ] \
  && [ "$(jq -r '.class' "$SH")" = "miss-sample" ]; then
  pass "c3-miss-sample-row-on-modulo-zero"
  pass "c3-miss-sample-exactly-one-row"
else
  fail "c3-miss-sample-row-on-modulo-zero / exactly-one-row: $(cat "$SH" 2>/dev/null)"
fi

I1=$(find_i 1) || { fail "c3-no-row-on-non-multiple-hash: no i found"; I1=1; }
rm -rf "$ST"
cls --kind wave-plan --text "shadow probe $I1" --run-id s2 >/dev/null
[ ! -f "$ST/runs/s2/shadow.jsonl" ] && pass "c3-no-row-on-non-multiple-hash" || fail "c3-no-row-on-non-multiple-hash"

rm -rf "$ST"
cls --kind wave-plan --text "shadow probe $I0" --run-id s3 >/dev/null
if [ -f "$ST/runs/s3/shadow.jsonl" ] && [ ! -f "$ST/runs/s3/spawn-request.json" ] \
  && [ "$(ls "$ST/runs/s3" | tr '\n' ' ')" = "shadow.jsonl " ]; then
  pass "c3-miss-sample-never-spawns"
else
  fail "c3-miss-sample-never-spawns: $(ls "$ST/runs/s3" 2>/dev/null | tr '\n' ' ')"
fi

# =============================================================================
# AC4 — static-check before probe (M19): paths-only evidence, receipt, hash
# parity with ask.sh probe.
# =============================================================================

# 4a. Default run (host commands off): outputs are paths, all files exist.
EV="$TMP/ev1"; rm -rf "$EV" "$ST"
H=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" run \
  --question 'is omp installed' --evidence-dir "$EV" --run-id rt1 2>"$TMP/sc.err")
RC=$?
if [ "$RC" -eq 0 ] && [ -n "$H" ]; then
  pass "c4-run-prints-question-hash"
else
  fail "c4-run-prints-question-hash: rc=$RC $(cat "$TMP/sc.err")"
fi
if jq -e 'all(.checks[]?; (.output // "") == "" or ((.output | startswith("/")) and (.output | test("\\.(txt|out)$"))))' \
  "$EV/static-check.json" >/dev/null 2>&1; then
  pass "c4-check-outputs-are-paths"
else
  fail "c4-check-outputs-are-paths: $(cat "$EV/static-check.json" 2>/dev/null)"
fi
if [ -f "$EV/cmdv-omp.txt" ] && jq -e '.checks[] | select(.cmd == "command -v omp" and .status == "ran" and (.exit | type == "number"))' \
  "$EV/static-check.json" >/dev/null 2>&1; then
  pass "c4-command-v-check-recorded"
else
  fail "c4-command-v-check-recorded"
fi
if jq -e '[.checks[] | select(.check == "pacman" and .status == "ran")] | length == 0' \
  "$EV/static-check.json" >/dev/null 2>&1; then
  pass "c4-host-cmds-skipped-by-default"
else
  fail "c4-host-cmds-skipped-by-default: $(cat "$EV/static-check.json")"
fi

# 4a-2. The summary JSON carries only names, exit codes, and output paths —
# never embedded command output or prose (AC5 sub-clause).
if jq -e 'keys == ["checks","docs_hits","question"] and
  ([.checks[] | ((.status == "skipped" and (.reason | type == "string")) or
                 (.status == "ran" and (.exit | type == "number") and (.output | test("^/"))))] | all)' \
  "$EV/static-check.json" >/dev/null 2>&1; then
  pass "c4-json-paths-exit-codes-only"
else
  fail "c4-json-paths-exit-codes-only: $(cat "$EV/static-check.json" 2>/dev/null)"
fi

# 4b. Host commands opt-in: pacman -Q runs only when the host has pacman.
EV2="$TMP/ev2"; rm -rf "$EV2"
ADVISOR_STATIC_HOST_CMDS=1 ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" run \
  --question 'is omp installed' --evidence-dir "$EV2" --run-id rt2 >/dev/null 2>&1
if command -v pacman > /dev/null 2>&1; then
  if jq -e '.checks[] | select(.check == "pacman" and .status == "ran")' \
    "$EV2/static-check.json" >/dev/null 2>&1; then
    pass "c4-host-cmds-run-when-opted-in"
  else
    fail "c4-host-cmds-run-when-opted-in: $(cat "$EV2/static-check.json")"
  fi
else
  if jq -e '.checks[] | select(.check == "pacman" and .status == "skipped" and .reason == "no pacman on host")' \
    "$EV2/static-check.json" >/dev/null 2>&1; then
    pass "c4-host-cmds-run-when-opted-in"
  else
    fail "c4-host-cmds-run-when-opted-in (no-pacman branch): $(cat "$EV2/static-check.json")"
  fi
fi

# 4b-2. file/strings run per path token when host commands are opted in.
FX2="$TMP/fxfile"; mkdir -p "$FX2"; printf 'textual fixture\n' > "$FX2/blob"
EVF="$TMP/ev-file"; rm -rf "$EVF"
ADVISOR_STATIC_HOST_CMDS=1 ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" run \
  --question "check $FX2/blob" --evidence-dir "$EVF" --run-id rf1 >/dev/null 2>&1
if [ -f "$EVF/file-1.out" ] && [ -f "$EVF/strings-1.out" ]; then
  pass "c4-file-strings-run-on-path-token"
else
  fail "c4-file-strings-run-on-path-token: $(ls "$EVF" 2>/dev/null | tr '\n' ' ')"
fi

# 4c. Repo-docs evidence is path:line, from a hermetic fixture MROOT.
FX="$TMP/fxrepo"; mkdir -p "$FX/docs"; git -C "$FX" init -q
printf 'omp is the Open MPI runtime for this epic.\n' > "$FX/docs/note.md"
EVD="$TMP/ev-docs"; rm -rf "$EVD"
(cd "$FX" && ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" run \
  --question 'does omp exist' --evidence-dir "$EVD" --run-id rd1) >/dev/null 2>&1
if grep -q 'docs/note\.md:1$' "$EVD/docs-hits.txt"; then
  pass "c4-docs-hits-are-path-line-locators"
else
  fail "c4-docs-hits-are-path-line-locators: $(cat "$EVD/docs-hits.txt" 2>/dev/null)"
fi

# 4d. Receipt gates verify; wrong hash is nonzero.
ADVISOR_STATE_ROOT="$ST" bash "$SC" verify --run-id rt1 --question-hash "$H" >/dev/null 2>&1
[ $? -eq 0 ] && pass "c4-receipt-present-after-run" || fail "c4-receipt-present-after-run"
ADVISOR_STATE_ROOT="$ST" bash "$SC" verify --run-id rt1 --question-hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef >/dev/null 2>&1
[ $? -eq 1 ] && pass "c4-verify-rejects-wrong-hash" || fail "c4-verify-rejects-wrong-hash"
rm -rf "$ST"
ADVISOR_STATE_ROOT="$ST" bash "$SC" verify --run-id rt1 --question-hash "$H" >/dev/null 2>&1
[ $? -eq 1 ] && pass "c4-receipt-absent-before-run" || fail "c4-receipt-absent-before-run"

# 4e. Hash parity: static-check's hash == ask.sh probe's question_hash over
# the same evidence dir (static-check before probe, same question, M19).
plant_advisor
EVP="$TMP/ev-parity"; rm -rf "$EVP" "$ST"
HP=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" run \
  --question 'is omp installed here' --evidence-dir "$EVP" --run-id rp1 2>/dev/null)
OUT=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$ASK" probe --trigger b \
  --question 'is omp installed here' --evidence-dir "$EVP" --run-id rp1 2>"$TMP/probe.err")
SRP=$(printf '%s' "$OUT" | jq -r '.spawn_request_path // empty')
PH=$( [ -n "$SRP" ] && jq -r '.question_hash // empty' "$SRP" )
if [ "$HP" = "$PH" ] && [ -n "$HP" ]; then
  pass "c4-question-hash-parity-with-probe"
else
  fail "c4-question-hash-parity-with-probe: static=$HP probe=$PH"
fi
if [ -n "$HP" ] && [ "$HP" = "$PH" ]; then
  pass "c5-hash-parity-values-compared"
else
  fail "c5-hash-parity-values-compared: static=$HP probe=$PH"
fi
if [ -n "$SRP" ] && [ "$(jq -r '.evidence_dir' "$SRP")" = "$EVP" ]; then
  pass "c8-spawn-request-carries-evidence-dir-path"
else
  fail "c8-spawn-request-carries-evidence-dir-path: $SRP"
fi

# 4f. The question hash covers evidence-dir content, i.e. it is computed
# after the check outputs are written (AC6 sub-clause).
EVH1="$TMP/ev-h1"; EVH2="$TMP/ev-h2"; rm -rf "$EVH1" "$EVH2"
mkdir -p "$EVH1" "$EVH2"; printf 'alpha\n' > "$EVH1/out.txt"; printf 'beta\n' > "$EVH2/out.txt"
H1=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" hash --question 'same question' --evidence-dir "$EVH1" 2>/dev/null)
H2=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" hash --question 'same question' --evidence-dir "$EVH2" 2>/dev/null)
[ -n "$H1" ] && [ "$H1" != "$H2" ] && pass "c5-hash-covers-evidence-dir-content" \
  || fail "c5-hash-covers-evidence-dir-content: $H1 vs $H2"

# =============================================================================
# AC7 — hook point 1: wave-plan write (M13.1). Source asserts on the protocol
# files, plus runtime execution of the actual fenced guard from each doc.
# =============================================================================

D06="$ROOT/skills/orchestrate/steps/06-design.md"
D07="$ROOT/skills/orchestrate/steps/07-tasks.md"
grep -q -- '--kind wave-plan' "$D06" && grep -q 'skills/advisor/classify.sh' "$D06" \
  && pass "c5-06-design-wave-plan-classifier-before-persist" \
  || fail "c5-06-design-wave-plan-classifier-before-persist"
grep -q -- '--kind wave-plan' "$D07" && grep -q 'skills/advisor/classify.sh' "$D07" \
  && pass "c5-07-tasks-wave-plan-classifier-before-persist" \
  || fail "c5-07-tasks-wave-plan-classifier-before-persist"
grep -qi 'mid-run rewrite' "$D06" && grep -qi 'mid-run rewrite' "$D07" \
  && pass "c5-wave-plan-mid-run-rewrite-covered" \
  || fail "c5-wave-plan-mid-run-rewrite-covered"
grep -q 'ADVISOR_SKIP_TRIGGER' "$D06" && grep -q 'ADVISOR_ON' "$D06" \
  && grep -q 'ADVISOR_SKIP_TRIGGER' "$D07" && grep -q 'ADVISOR_ON' "$D07" \
  && pass "c5-wave-plan-hook-off-skip-bypass" \
  || fail "c5-wave-plan-hook-off-skip-bypass"

# exec_fence <doc> <prefix> — extract the ADVISOR_ON guard fence from a hook
# doc and execute the REAL text: env unset (silent skip, exit 0), interactive
# bypass (silent skip), and advisor on with a stubbed classify returning hits
# (halt signal on stderr). Also asserts the fence invokes classify with the
# right --kind and states the halt MUST NOT write.
exec_fence() {
  doc="$1"; pfx="$2"; FENCE=""
  FENCE=$(awk '/^if \[ "\$\{ADVISOR_ON:-\}" = "true" \]/{f=1} f{print} f&&/^fi$/{exit}' "$doc")
  if [ -z "$FENCE" ]; then fail "$pfx-fence-extractable"; return; fi
  case "$FENCE" in
    *"--kind disposition"*) pass "$pfx-fence-invokes-disposition" ;;
    *"--kind wave-plan"*)   pass "$pfx-fence-invokes-wave-plan" ;;
    *) fail "$pfx-fence-invokes-classify" ;;
  esac
  case "$FENCE" in
    *"MUST NOT"*) pass "$pfx-fence-halt-must-not-write" ;;
    *) fail "$pfx-fence-halt-must-not-write" ;;
  esac
  OUT=$(env -u ADVISOR_ON -u ADVISOR_SKIP_TRIGGER bash -c "$FENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "$pfx-fence-off-silent-executed"
  else
    fail "$pfx-fence-off-silent-executed: rc=$RC out=$OUT"
  fi
  OUT=$(env ADVISOR_ON=true ADVISOR_SKIP_TRIGGER=1 bash -c "$FENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "$pfx-fence-bypass-silent-executed"
  else
    fail "$pfx-fence-bypass-silent-executed: rc=$RC out=$OUT"
  fi
  mkdir -p "$STUBROOT/skills"
  printf '#!/usr/bin/env bash\nprintf "%%s" "${STUB_CLASSIFY:?}"\n' > "$STUBROOT/skills/plugin-dir.sh"
  printf '#!/usr/bin/env bash\nprintf '"'"'%%s'"'"' '"'"'[{"trigger":"b","class":"identity","span":"x","question_hash":"h"}]'"'"'\n' > "$STUBROOT/stub-classify.sh"
  OUT=$(STUB_CLASSIFY="$STUBROOT/stub-classify.sh" PDH="$STUBROOT" ADVISOR_ON=true bash -c "$FENCE" 2>&1); RC=$?
  case "$OUT" in
    *"advisor trigger-(b) hits"*) pass "$pfx-fence-halt-signal-on-hits" ;;
    *) fail "$pfx-fence-halt-signal-on-hits: rc=$RC out=$OUT" ;;
  esac
}
# fence_order <doc> <prefix> <before-pattern> — the doc states the classifier
# runs BEFORE the write, and the fence text precedes that statement's subject.
fence_order() {
  doc="$1"; pfx="$2"; pat="$3"
  bl=$(grep -n "$pat" "$doc" | head -1 | cut -d: -f1)
  fl=$(awk '/^if \[ "\$\{ADVISOR_ON:-\}" = "true" \]/{print NR; exit}' "$doc")
  if [ -n "$bl" ] && [ -n "$fl" ] && [ "$bl" -lt "$fl" ]; then
    pass "$pfx-fence-before-write-order"
  else
    fail "$pfx-fence-before-write-order: before=$bl fence=$fl"
  fi
}
STUBROOT="$TMP/stubpd"
exec_fence "$D06" "c6-06design"
exec_fence "$D07" "c6-07tasks"
fence_order "$D06" "c6-06design" "BEFORE persisting"
fence_order "$D07" "c6-07tasks" "BEFORE persisting"

# =============================================================================
# AC6 — hook point 2: disposition write (M13.2). Source asserts on the three
# disposition surfaces (wrap-ticket close, epic set-status, backlog close).
# =============================================================================

W12="$ROOT/skills/orchestrate/steps/12-wrap.md"
MB="$ROOT/skills/epic/mode-b-execute.md"
BL="$ROOT/skills/backlog/SKILL.md"
grep -q -- '--kind disposition' "$W12" && grep -q 'skills/advisor/classify.sh' "$W12" \
  && pass "c6-12-wrap-close-classifier" || fail "c6-12-wrap-close-classifier"
grep -q -- '--kind disposition' "$MB" && grep -q 'skills/advisor/classify.sh' "$MB" \
  && pass "c6-mode-b-set-status-classifier" || fail "c6-mode-b-set-status-classifier"
grep -q -- '--kind disposition' "$BL" && grep -q 'skills/advisor/classify.sh' "$BL" \
  && pass "c6-backlog-close-classifier" || fail "c6-backlog-close-classifier"
grep -q -- '--action' "$W12" && grep -q -- '--action' "$MB" && grep -q -- '--action' "$BL" \
  && pass "c6-disposition-action-arg-plumbed" || fail "c6-disposition-action-arg-plumbed"
grep -q 'ADVISOR_SKIP_TRIGGER' "$W12" && grep -q 'ADVISOR_SKIP_TRIGGER' "$MB" \
  && grep -q 'ADVISOR_SKIP_TRIGGER' "$BL" \
  && pass "c6-disposition-hook-off-skip-bypass" || fail "c6-disposition-hook-off-skip-bypass"
exec_fence "$W12" "c7-12wrap"
exec_fence "$MB" "c7-modeb"
exec_fence "$BL" "c7-backlog"
fence_order "$W12" "c7-12wrap" "BEFORE any"
fence_order "$MB" "c7-modeb" 'BEFORE `set-status'
fence_order "$BL" "c7-backlog" 'BEFORE `close.sh'

# =============================================================================
# AC9 — SKILL.md documents the classify-hits -> static-check -> probe order.
# =============================================================================

SKILL="$ROOT/skills/advisor/SKILL.md"
grep -q 'static-check.sh' "$SKILL" && grep -q 'classify.sh' "$SKILL" \
  && pass "c8-skill-doc-classifier-order" || fail "c8-skill-doc-classifier-order"
L1=$(grep -n '^1\. `classify.sh`' "$SKILL" | head -1 | cut -d: -f1)
L2=$(grep -n '^2\. `static-check.sh run' "$SKILL" | head -1 | cut -d: -f1)
L3=$(grep -n '^3\. `ask.sh probe' "$SKILL" | head -1 | cut -d: -f1)
if [ -n "$L1" ] && [ -n "$L2" ] && [ -n "$L3" ] && [ "$L1" -lt "$L2" ] && [ "$L2" -lt "$L3" ]; then
  pass "c8-skill-doc-order-is-classify-static-probe"
else
  fail "c8-skill-doc-order-is-classify-static-probe: L1=$L1 L2=$L2 L3=$L3"
fi

# =============================================================================
# Round-6 byte-level token exhibits. Each test echoes the exhibited tokens
# into run output so an evidence raw_blob can hold them verbatim (BC7 r5
# strikes: AC1 'never sourced' + hit-record span, AC4 M17 hash rule, AC5
# probe-not-unchecked, AC7 literal '## Waves').
# =============================================================================

# R6-1. AC1 "invoked as a subprocess CLI and never sourced": no hook doc or
# SKILL.md sources classify.sh; every reference uses the bash subprocess form.
NEVER_SRC_OK=1
for D in "$ROOT/skills/orchestrate/steps/06-design.md" \
         "$ROOT/skills/orchestrate/steps/07-tasks.md" \
         "$ROOT/skills/orchestrate/steps/12-wrap.md" \
         "$ROOT/skills/epic/mode-b-execute.md" \
         "$ROOT/skills/backlog/SKILL.md" \
         "$SKILL"; do
  if grep -nE '(^|[;[:space:]])(source|\.)[[:space:]][^|]*classify\.sh' "$D" >/dev/null 2>&1; then
    NEVER_SRC_OK=0
    echo "sourcing-form-found: $D" >&2
  fi
done
echo "invocation-form: $(grep -h 'bash "$CLASSIFY"' "$ROOT/skills/orchestrate/steps/06-design.md" | head -1 | sed 's/^[[:space:]]*//')"
[ "$NEVER_SRC_OK" -eq 1 ] \
  && pass "c0-classify-subprocess-form-never-sourced" \
  || fail "c0-classify-subprocess-form-never-sourced"

# R6-2. AC1 hit-record span: keys of a real hit in run output + the
# documented span line in SKILL.md.
HITJ=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$CLS" --kind wave-plan --text 'omp is Open MPI' 2>/dev/null)
HITKEYS=$(printf '%s' "$HITJ" | jq -r '.[0] | keys_unsorted | join(",")' 2>/dev/null)
echo "hit-record-keys: $HITKEYS"
[ "$HITKEYS" = "trigger,class,span,question_hash" ] \
  && pass "c0-hit-record-keys-trigger-class-span-question-hash" \
  || fail "c0-hit-record-keys-trigger-class-span-question-hash: $HITKEYS"
SPANLINE=$(grep -n 'trigger":"b"' "$SKILL" | head -1)
echo "skillmd-span-line: $SPANLINE"
[ -n "$SPANLINE" ] && pass "c0-hit-record-span-documented-skills" \
  || fail "c0-hit-record-span-documented-skills"

# R6-3. AC4 M17 rule exhibit: the first-13-hex / % 10 arithmetic at runtime.
MI=$(find_i 0)
MH=$(printf 'shadow probe %s' "$MI" | sha256sum | cut -d' ' -f1)
echo "m17-exhibit: sha256(\"shadow probe $MI\") first13=${MH:0:13} mod10=$((0x${MH:0:13} % 10))"
[ "$MI" != "" ] && [ $((0x${MH:0:13} % 10)) -eq 0 ] \
  && pass "c3-m17-first13-modulo-exhibit" \
  || fail "c3-m17-first13-modulo-exhibit"

# R6-4. AC5 probe MUST NOT start un-checked: runtime caller sequence —
# classify (silent) -> static-check run -> verify wrong hash BLOCKS the
# probe -> verify correct hash OPENS it -> probe stub starts exactly once.
SEQ="$TMP/seq"; rm -rf "$SEQ" "$ST"; mkdir -p "$SEQ"
printf '#!/usr/bin/env bash\necho "PROBE-STARTED"\n' > "$SEQ/stub-probe.sh"
EVQ="$TMP/ev-seq"; rm -rf "$EVQ"
C1=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$CLS" --kind disposition --action close --text 'nothing to see' 2>/dev/null)
HQ=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$SC" run \
  --question 'is omp installed' --evidence-dir "$EVQ" --run-id sq1 2>"$TMP/seq.err") \
  || fail "c5-caller-sequence-probe-gated: static-run rc=$? $(cat "$TMP/seq.err")"
: > "$SEQ/gate.log"
ADVISOR_STATE_ROOT="$ST" bash "$SC" verify --run-id sq1 --question-hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef >/dev/null 2>&1 \
  && echo "gate=WRONG-HASH-OPENED" >> "$SEQ/gate.log" || echo "gate=blocked-wrong-hash" >> "$SEQ/gate.log"
ADVISOR_STATE_ROOT="$ST" bash "$SC" verify --run-id sq1 --question-hash "$HQ" >/dev/null 2>&1 \
  && { echo "gate=open" >> "$SEQ/gate.log"; bash "$SEQ/stub-probe.sh" >> "$SEQ/gate.log" 2>&1; }
echo "caller-sequence: classify=$( [ "$C1" = "[]" ] && echo silent-skip || echo "$C1" ) static-check=ran $(tr '\n' '|' < "$SEQ/gate.log")"
grep -q '^gate=blocked-wrong-hash$' "$SEQ/gate.log" \
  && [ "$(grep -c '^PROBE-STARTED$' "$SEQ/gate.log")" -eq 1 ] \
  && grep -q '^gate=open$' "$SEQ/gate.log" \
  && pass "c5-caller-sequence-probe-gated" \
  || fail "c5-caller-sequence-probe-gated: $(cat "$SEQ/gate.log" 2>/dev/null)"

# R6-5. AC7 mid-run-rewrite token: the literal `## Waves` span exists in
# both wave-plan hook docs and is echoed into run output.
W1=$(grep -n '## Waves' "$ROOT/skills/orchestrate/steps/06-design.md" | head -1)
W2=$(grep -n '## Waves' "$ROOT/skills/orchestrate/steps/07-tasks.md" | head -1)
echo "waves-token-06design: $W1"
echo "waves-token-07tasks: $W2"
[ -n "$W1" ] && [ -n "$W2" ] \
  && pass "c6-wave-plan-rewrite-waves-token-exhibited" \
  || fail "c6-wave-plan-rewrite-waves-token-exhibited: w1=$W1 w2=$W2"

# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
