#!/usr/bin/env bash
# skills/review-and-commit/test-fences.sh — SPEC-021 wp-1-12-fence-state ACs
# (CDT-320 [06 F8b], CDT-264 [06 F8] [06 F10]). Extracts bash fences from
# SKILL.md (tests/lib/fence.sh) and runs them in fresh shells against a stub
# plugin root; no real council engine runs.
#
#   Step 1b  the --impact caller grep finds files (the --include brace pattern
#            matched nothing)
#   Step 3   the preflight fence prints the plan path so a later fence can be
#            given it
#   Step 5   the finalize fence is self-contained: it reads no variable that an
#            earlier fence set, passes every argument to the engine, and fails
#            closed when the plan path is not filled in
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). SKILL_MD may name
# another revision of SKILL.md (bite-on-old-code run); default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="${SKILL_MD:-$ROOT/skills/review-and-commit/SKILL.md}"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init
require_cmd jq

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

# ---- extract ----------------------------------------------------------------
STEP1B="$(fence_nth "$SKILL_MD" "## Step 1b" 1)"
STEP3="$(fence_nth "$SKILL_MD" "## Step 3: Preflight" 1)"
STEP5="$(fence_nth "$SKILL_MD" "## Step 5: Finalize" 1)"
for pair in "Step 1b:$STEP1B" "Step 3:$STEP3" "Step 5:$STEP5"; do
  if [ -n "${pair#*:}" ]; then pass_line "structural: ${pair%%:*} has a bash fence"
  else fail_line "structural: ${pair%%:*} has a bash fence (zero extracted)"; fi
done

# ---- stub plugin root -------------------------------------------------------
# CLAUDE_PLUGIN_ROOT (plugin-dir.sh tier 0) makes the fence's own PDH stanza
# resolve to $PLUG from any cwd. The stub engine logs argv, one arg per line.
PLUG="$WORK/plug"
mkdir -p "$PLUG/skills/council" "$WORK/cwd"
cp "$ROOT/skills/plugin-dir.sh" "$PLUG/skills/plugin-dir.sh"
chmod +x "$PLUG/skills/plugin-dir.sh"
cat > "$PLUG/skills/council/engine.sh" <<'STUB'
#!/usr/bin/env bash
{ printf 'argc=%d\n' "$#"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; } >> "$STUB_LOG"
[ "${1:-}" = "preflight" ] && printf '{}\n'
exit 0
STUB
chmod +x "$PLUG/skills/council/engine.sh"

# run_fence <fence-text> <out-prefix> — run in a fresh bash, cwd = a non-repo dir
run_fence() {
  : > "$STUB_LOG"
  # PDH="$PLUG" simulates the host's session carry (WP 7-02): carried fences
  # take the root from env; stanza fences re-resolve and ignore it.
  fence_exec "$2" "$WORK/cwd" "$1" CLAUDE_PLUGIN_ROOT="$PLUG" PDH="$PLUG" STUB_LOG="$STUB_LOG"
}
STUB_LOG="$WORK/stub.log"

# arg_after <flag> — the value that follows <flag> in the stub log ("" if none)
arg_after() {
  local v
  v=$({ grep -x -A1 -- "arg=$1" "$STUB_LOG" || true; } | sed -n '2p')
  printf '%s' "${v#arg=}"
}

# ---- Step 1b: --impact caller grep (CDT-264 [06 F10]) -----------------------
IMP="$WORK/impact"
mkdir -p "$IMP/src" "$IMP/node_modules/dep" "$IMP/vendor"
for f in src/a.py src/b.ts src/c.sh src/d.go src/e.rs src/f.js src/g.txt node_modules/dep/h.js vendor/i.py; do
  printf 'call needle_fn()\n' > "$IMP/$f"
done
step1b_sub="${STEP1B//<symbol>/needle_fn}"
printf '%s\n' "$step1b_sub" > "$WORK/s1b.sh"
got=$( cd "$IMP" && bash "$WORK/s1b.sh" 2>/dev/null | sort | tr '\n' ' ' )
want="./src/a.py ./src/b.ts ./src/c.sh ./src/d.go ./src/e.rs ./src/f.js "
check "Step 1b: the caller grep lists .py .ts .sh .go .rs .js callers and skips .txt, node_modules, vendor (got: $got)" \
  [ "$got" = "$want" ]

# planted negative control: the old brace form must be caught as matching nothing
brace_form="grep -rl --include='*.{py,js,ts,go,rs,sh}' 'needle_fn' ."
ctl=$( cd "$IMP" && bash -c "$brace_form" 2>/dev/null | wc -l | tr -d ' ' )
check "control: the old --include brace form matches nothing on this fixture (got $ctl)" [ "$ctl" = "0" ]

# ---- Step 3: preflight fence prints the plan path ---------------------------
run_fence "$STEP3" "$WORK/s3"
plan_line=$(grep -m1 '^PLAN_FILE=' "$WORK/s3.out" || true)
check "Step 3: the preflight fence exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "Step 3: the fence prints 'PLAN_FILE=<path>' (got: ${plan_line:-none})" [ -n "$plan_line" ]
check "Step 3: the printed plan file exists and holds the preflight output" \
  bash -c 'p=${1#PLAN_FILE=}; [ -n "$p" ] && [ -f "$p" ] && grep -q "{}" "$p"' _ "${plan_line:-PLAN_FILE=}"

# ---- Step 5: self-contained finalize fence (CDT-320) ------------------------
# Static 1: no variable that only an earlier fence assigns. skill-lint C1 is the
# detector; the JSON keeps waived findings, so a waiver cannot hide one here.
s5_range=$(awk '
  /^## Step 5: Finalize/ { insec = 1; next }
  insec && /^## / { exit }
  insec && /^[ \t]*```bash/ && !inb { inb = 1; start = NR + 1; next }
  insec && inb && /^[ \t]*```[ \t]*$/ { print start " " NR - 1; exit }
' "$SKILL_MD")
s5_lo=${s5_range% *}; s5_hi=${s5_range#* }
c1_in_s5=$({ bash "$LINT" --json "$SKILL_MD" 2>/dev/null || true; } | jq --argjson lo "${s5_lo:-0}" --argjson hi "${s5_hi:-0}" \
  '[.[] | select(.check == "C1" and .line >= $lo and .line <= $hi)] | length' 2>/dev/null || echo "?")
check "Step 5: skill-lint reports no C1 (waived or not) inside the finalize fence (got $c1_in_s5)" [ "$c1_in_s5" = "0" ]

# planted negative control: the same detector does see a waived cross-fence read
ctl_md="$WORK/ctl.md"
printf '```bash\nPLAN_FILE=$(mktemp)\n```\n\n```bash\n# lint-ok: C1\necho "$PLAN_FILE"\n```\n' > "$ctl_md"
ctl_c1=$({ bash "$LINT" --json "$ctl_md" 2>/dev/null || true; } | jq '[.[] | select(.check == "C1")] | length' 2>/dev/null || echo "?")
check "control: the detector counts a waived cross-fence read (got $ctl_c1)" [ "$ctl_c1" = "1" ]

# Static 2: no shell expansion of a variable no shell ever sets
check "Step 5: the fence has no \${degraded…} expansion" bash -c '! printf "%s\n" "$1" | grep -q "\${degraded"' _ "$STEP5"
check "control: the expansion probe fires on the old text" \
  bash -c 'printf "%s\n" "$1" | grep -q "\${degraded"' _ '  ${degraded:+--verification-mode self-verified}'

# Exec 1: the model fills <PLAN_FILE> and <DEGRADED>=false; every argument
# reaches the engine
PLAN="$WORK/plan.json"
printf '{}\n' > "$PLAN"
s5_plan="${STEP5//<PLAN_FILE>/$PLAN}"
s5_filled="${s5_plan//<DEGRADED>/false}"
run_fence "$s5_filled" "$WORK/s5a"
check "Step 5: the filled fence exits 0 (rc=$RUN_RC; err: $(head -c 200 "$WORK/s5a.err"))" [ "$RUN_RC" -eq 0 ]
check "Step 5: engine got 'finalize'" grep -qx 'arg=finalize' "$STUB_LOG"
check "Step 5: engine got --plan-file <the plan path>" [ "$(arg_after --plan-file)" = "$PLAN" ]
ev=$(arg_after --evidence-file)
ju=$(arg_after --judge-output)
check "Step 5: engine got --evidence-file <non-empty path> (got: ${ev:-empty})" [ -n "$ev" ]
check "Step 5: engine got --judge-output <non-empty path> (got: ${ju:-empty})" [ -n "$ju" ]
check "Step 5: a non-degraded run passes no --verification-mode" bash -c '! grep -q -- "--verification-mode" "$1"' _ "$STUB_LOG"
check "Step 5: no empty argument reaches the engine" bash -c '! grep -qx "arg=" "$1"' _ "$STUB_LOG"

# Exec 2: <DEGRADED>=true — the flag reaches the engine
s5_degraded="${s5_plan//<DEGRADED>/true}"
run_fence "$s5_degraded" "$WORK/s5b"
check "Step 5: the degraded run exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "Step 5: the degraded run passes --verification-mode self-verified" \
  [ "$(arg_after --verification-mode)" = "self-verified" ]
check "Step 5: the degraded run still passes --plan-file and --evidence-file" \
  bash -c '[ "$(grep -x -A1 -- "arg=--plan-file" "$1" | sed -n 2p)" = "arg=$2" ] && grep -qx "arg=--evidence-file" "$1"' _ "$STUB_LOG" "$PLAN"

# Exec 3: fail closed — a placeholder left unfilled, or a value that is not
# true or false, exits non-zero and never reaches the engine. A skipped
# <DEGRADED> must not read as "not degraded".
run_fence "${STEP5//<PLAN_FILE>/$PLAN}" "$WORK/s5c"
check "Step 5: an unfilled <DEGRADED> exits non-zero (rc=$RUN_RC)" [ "$RUN_RC" -ne 0 ]
check "Step 5: an unfilled <DEGRADED> never calls the engine" [ ! -s "$STUB_LOG" ]
run_fence "${s5_plan//<DEGRADED>/maybe}" "$WORK/s5d"
check "Step 5: <DEGRADED> set to 'maybe' exits non-zero (rc=$RUN_RC)" [ "$RUN_RC" -ne 0 ]
check "Step 5: <DEGRADED> set to 'maybe' never calls the engine" [ ! -s "$STUB_LOG" ]
run_fence "${STEP5//<DEGRADED>/false}" "$WORK/s5e"
check "Step 5: an unfilled <PLAN_FILE> exits non-zero (rc=$RUN_RC)" [ "$RUN_RC" -ne 0 ]
check "Step 5: an unfilled <PLAN_FILE> never calls the engine" [ ! -s "$STUB_LOG" ]

echo "---"
echo "review-and-commit fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
