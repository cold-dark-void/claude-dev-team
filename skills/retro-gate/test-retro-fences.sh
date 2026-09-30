#!/usr/bin/env bash
# skills/retro-gate/test-retro-fences.sh — SPEC-012 S1-S9 / SPEC-030 R23+
# (CDT-272 goal 5, "commands/retro.md scheduled"). Runs the Step 1b scheduled
# path-lock fence of commands/retro.md, extracted with tests/lib/fence.sh, in a
# fresh shell inside a fixture git repo against a stub plugin root. The stub
# scheduled-lock.sh and write-scheduled-report.sh log every call, so the suite
# sees which script each branch of the fence runs.
#
#   scheduled (MODE=all AUTO=1)   acquire the lock; rc 2 (held) skips with exit 0
#                                 and writes no report; rc 1 (error) continues
#   not scheduled                 the lock script is never called
#   lock script absent            the fence continues without a lock
#
# KNOWN DEFECT (backlog wp-2-10-retro-scheduled, CDT-324 in WP 2-10): the fence
# arms `trap ... release EXIT`, and a fence's shell exits when the fence ends, so
# the lock is released before Step 2 starts. The suite states today's behavior
# in a case labelled KNOWN DEFECT. The static checks F2 and F3 of
# tools/fence-exec/run.sh name the same defect; the manifest excludes both.
# Flip the KNOWN DEFECT case when that item is fixed.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). RETRO_MD may name
# another revision of retro.md; default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RETRO_MD="${RETRO_MD:-$ROOT/commands/retro.md}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
REPO="$WORK/repo"
PLUG="$WORK/plug"
STUB_LOG="$WORK/stub.log"
mkdir -p "$REPO" "$PLUG/skills/retro-gate"

# ---- fixture repo (MROOT and WTROOT come from here) -------------------------
git -C "$REPO" init -q . || { echo "FAIL: git init"; exit 1; }

# ---- extract ----------------------------------------------------------------
FENCE="$(fence_nth "$RETRO_MD" '### Step 1b: Scheduled path lock' 1)" || FENCE=""
if [ -n "$FENCE" ]; then pass_line "structural: Step 1b has a bash fence"
else fail_line "structural: Step 1b has a bash fence (zero extracted)"; fi

# ---- stub plugin root -------------------------------------------------------
# CLAUDE_PLUGIN_ROOT (plugin-dir.sh tier 0) makes the fence's own PDH stanza
# resolve to $PLUG. The stub lock script exits with STUB_LOCK_RC on acquire.
cp "$ROOT/skills/plugin-dir.sh" "$PLUG/skills/plugin-dir.sh"
chmod +x "$PLUG/skills/plugin-dir.sh"
make_stubs() {
  cat > "$PLUG/skills/retro-gate/scheduled-lock.sh" <<'STUB'
#!/usr/bin/env bash
printf 'lock %s %s\n' "$1" "$2" >> "$STUB_LOG"
[ "$1" = "acquire" ] && exit "${STUB_LOCK_RC:-0}"
exit 0
STUB
  cat > "$PLUG/skills/retro-gate/write-scheduled-report.sh" <<'STUB'
#!/usr/bin/env bash
printf 'writer %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
  chmod +x "$PLUG/skills/retro-gate/scheduled-lock.sh" "$PLUG/skills/retro-gate/write-scheduled-report.sh"
}
make_stubs

# run_fence <out-prefix> [NAME=value ...] — run the fence in a fresh bash, cwd = the fixture repo
run_fence() {
  local prefix="$1"
  shift
  : > "$STUB_LOG"
  fence_exec "$prefix" "$REPO" "$FENCE" CLAUDE_PLUGIN_ROOT="$PLUG" STUB_LOG="$STUB_LOG" "$@"
}

log_has() { grep -q -- "$1" "$STUB_LOG"; }
log_lacks() { ! grep -q -- "$1" "$STUB_LOG"; }
log_count() { grep -c -- "$1" "$STUB_LOG" || true; }

# ---- scheduled, lock free ---------------------------------------------------
run_fence "$WORK/free" MODE=all AUTO=1 STUB_LOCK_RC=0
check "scheduled, lock free: the fence exits 0" test "$RUN_RC" -eq 0
check "scheduled, lock free: acquire is called once with the repo as MROOT" test "$(log_count "^lock acquire $REPO\$")" -eq 1
check "scheduled, lock free: no report is written by this fence" log_lacks '^writer'
# KNOWN DEFECT (backlog wp-2-10-retro-scheduled, CDT-324): the EXIT trap fires when the fence's shell ends.
check "KNOWN DEFECT: the lock is released when the Step 1b fence ends, before Step 2" test "$(log_count "^lock release $REPO\$")" -eq 1

# ---- scheduled, lock held (rc 2) --------------------------------------------
run_fence "$WORK/held" MODE=all AUTO=1 STUB_LOCK_RC=2
check "lock held: the fence exits 0" test "$RUN_RC" -eq 0
check "lock held: prints the skip line" grep -q 'scheduled retro: lock held, skipping' "$WORK/held.out"
check "lock held: a held lock is not released by the skipped run" log_lacks '^lock release'
check "lock held: a lock-held skip writes no report" log_lacks '^writer'

# ---- scheduled, acquire fails (rc 1) ----------------------------------------
run_fence "$WORK/err" MODE=all AUTO=1 STUB_LOCK_RC=1
check "acquire error: the fence exits 0 and continues without a lock" test "$RUN_RC" -eq 0
check "acquire error: warns on stderr" grep -q 'scheduled lock acquire failed (rc=1) — continuing without lock' "$WORK/err.err"
check "acquire error: no trap is armed, so nothing is released" log_lacks '^lock release'

# ---- not scheduled: negative controls ---------------------------------------
run_fence "$WORK/single" MODE=single AUTO=0 STUB_LOCK_RC=0
check "MODE=single: the fence exits 0" test "$RUN_RC" -eq 0
check "MODE=single: the lock script is never called" log_lacks '^lock'
run_fence "$WORK/autoonly" MODE=one AUTO=1 STUB_LOCK_RC=0
check "AUTO=1 with MODE=one: the lock script is never called" log_lacks '^lock'
run_fence "$WORK/modeonly" MODE=all AUTO=0 STUB_LOCK_RC=0
check "MODE=all with AUTO=0: the lock script is never called" log_lacks '^lock'

# ---- lock script absent ------------------------------------------------------
rm -f "$PLUG/skills/retro-gate/scheduled-lock.sh"
run_fence "$WORK/nolock" MODE=all AUTO=1
check "lock script absent: the fence exits 0" test "$RUN_RC" -eq 0
check "lock script absent: nothing is acquired" log_lacks '^lock'
make_stubs

# ---- bite: a mutated fence makes the cases above fail ------------------------
# Drop the AUTO guard: an unscheduled run then takes the lock, so the
# "not scheduled" negative controls would fail.
MUT_FENCE="$(printf '%s\n' "$FENCE" | sed 's/\[ "\$AUTO" = "1" \]/true/')"
: > "$STUB_LOG"
fence_exec "$WORK/mut1" "$REPO" "$MUT_FENCE" CLAUDE_PLUGIN_ROOT="$PLUG" STUB_LOG="$STUB_LOG" MODE=all AUTO=0 STUB_LOCK_RC=0
check "bite: without the AUTO guard an unscheduled run takes the lock" log_has '^lock acquire'
# Change the held-lock code: a held lock then no longer skips the run.
MUT_FENCE="$(printf '%s\n' "$FENCE" | sed 's/"\$LOCK_RC" -eq 2/"$LOCK_RC" -eq 9/')"
: > "$STUB_LOG"
fence_exec "$WORK/mut2" "$REPO" "$MUT_FENCE" CLAUDE_PLUGIN_ROOT="$PLUG" STUB_LOG="$STUB_LOG" MODE=all AUTO=1 STUB_LOCK_RC=2
check "bite: with the held-lock branch changed the skip line is gone" bash -c '! grep -q "lock held, skipping" "$1.out"' _ "$WORK/mut2"

echo "---"
echo "retro fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
