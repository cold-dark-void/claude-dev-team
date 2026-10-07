#!/usr/bin/env bash
# tools/fence-exec/test-later-fences.sh — SPEC-030 R27 suite for the CDT-502-C5
# later fences (SPEC-030 ### CDT-502-C5 AC11). The `skills/backlog/SKILL.md`
# `Subcommand: `reconcile`` fence is the minimum later fence under contract: it
# must self-resolve PDH in a FRESH shell with PDH unset (the retired
# `PDH="${PDH:-<PDH>}"` carry line puts the literal `<PDH>` into a path — the
# C1 dogfood row 4b failure this suite owns the bite for).
#
#   - extraction via tests/lib/fence.sh, the heading needle the manifest row
#     names (run.sh M1 greps this suite for it)
#   - SKILL_MD overrides the source file: a bite-on-old-code run points it at
#     a revision still carrying the retired carry line (the AC11 red artifact
#     uses the pre-C5 copy: git show 32fa33c:skills/backlog/SKILL.md)
#   - the hermetic HOME plants a tier-3 dev-team-edge cache version root (the
#     CDT-508 regression layout), so the resolved root proves the edge channel
#   - documented optional placeholders (`[--root <path>] …`) are substituted
#     by omission, the way the host runs the fence; rc is asserted only on
#     this verbatim-runnable fence — placeholder templates that legitimately
#     exit non-zero are out of scope (AC11 scoping)
#   - a second case runs the managed partial's own line (the byte SoT the
#     fence expands): with PDH pre-set non-empty it is used unchanged, with
#     no existence re-check — a stale carry is honored verbatim
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); the suite writes
# nothing under the checkout. bash 3.2 portable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="${SKILL_MD:-$ROOT/skills/backlog/SKILL.md}"
PARTIAL="${PARTIAL:-$ROOT/skills/lib/pdh-later-fence.sh}"

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
STORE="$HERMETIC_ROOT/store"
mkdir -p "$WORK" "$STORE"

# The manifest row's heading needle (run.sh M1 greps this suite for it).
NEEDLE='Subcommand: `reconcile`'

err_lacks() { ! grep -qF -- "$1" "$2"; }

# ---- fixture plugin root ----------------------------------------------------
# Tier-3 dev-team-edge cache version root (the CDT-508 layout) under the
# hermetic HOME: the REAL plugin-dir.sh (the fence executes it) and a stub
# reconcile payload (the payload's internals are not what this suite tests;
# the retro-gate suites stub their payloads the same way). The store cwd is
# not a git repo, so tier 1 cannot resolve and the cache arm must win.
EDGE_ROOT="$HOME/.claude/plugins/cache/cold-dark-void/dev-team-edge/9.9.9"
mkdir -p "$EDGE_ROOT/skills/backlog"
cp "$ROOT/skills/plugin-dir.sh" "$EDGE_ROOT/skills/plugin-dir.sh"
export RECON_LOG="$WORK/recon-stub.log"
{
  printf '#!/usr/bin/env bash\n'
  printf '# fixture stub: stands in for skills/backlog/reconcile.sh; records the run\n'
  printf 'printf "ran\\n" >> "$RECON_LOG"\n'
} > "$EDGE_ROOT/skills/backlog/reconcile.sh"

# ---- extract ----------------------------------------------------------------
RECON_FENCE="$(fence_nth "$SKILL_MD" "$NEEDLE" 1)"
check "structural: the reconcile heading holds a bash fence" [ -n "$RECON_FENCE" ]
check "structural: the fence carries exactly one PDH= assignment" \
  [ "$(printf '%s\n' "$RECON_FENCE" | grep -c '^PDH=')" = 1 ]

# Documented optional placeholders are substituted by omission: the host runs
# `bash "$RECON"` with none of the optional flags. (sed with escaped brackets:
# the same text in a ${var//…/} pattern would read as a glob character class.)
RUNTEXT=$(printf '%s\n' "$RECON_FENCE" | sed -e 's/ \[--root <path>\]//g' \
  -e 's/ \[--dry-run\]//g' -e 's/ \[--linear-verdicts <file>\]//g')

# The CDT-508 probe: the fence body plus two lines — the body's own exit
# status (the fence's rc is its last command's; the probe must not mask it)
# and the resolved PDH (plugin-dir-test.sh appends the same PDH probe to both
# canonical texts).
PROBE='printf "BODY_RC=%s\n" "$?"
printf "PDH=%s\n" "$PDH"'

# ---- case 1: fresh shell, PDH unset — self-resolution -----------------------
fence_exec "$WORK/lf1" "$STORE" "$RUNTEXT
$PROBE" -u PDH -u CLAUDE_PLUGIN_ROOT
rc1=$(sed -n 's/^BODY_RC=//p' "$WORK/lf1.out")
pdh1=$(sed -n 's/^PDH=//p' "$WORK/lf1.out")
check "reconcile fence: PDH resolves non-empty" [ -n "$pdh1" ]
check "reconcile fence: PDH points at an existing plugin root" [ -d "$pdh1" ]
check "reconcile fence: resolves the planted tier-3 dev-team-edge cache (CDT-508)" \
  [ "$pdh1" = "$EDGE_ROOT" ]
check "reconcile fence: no literal <PDH> reaches a path (captured stderr)" \
  err_lacks '<PDH>' "$WORK/lf1.err"
check "reconcile fence: exits 0 with the placeholders substituted (rc=$rc1)" [ "$rc1" -eq 0 ]
check "reconcile fence: the payload line ran" [ -s "$RECON_LOG" ]

# ---- case 2: PDH pre-set non-empty — used unchanged -------------------------
# A stale carry is honored verbatim (no existence re-check): the body's later
# path uses then fail downstream; only the carry semantics are asserted here.
STALE=/pdh-carried-stale
fence_exec "$WORK/lf2" "$STORE" "$RUNTEXT
$PROBE" -u CLAUDE_PLUGIN_ROOT "PDH=$STALE"
pdh2=$(sed -n 's/^PDH=//p' "$WORK/lf2.out")
check "reconcile fence: a non-empty carried PDH is used unchanged (no existence re-check)" \
  [ "$pdh2" = "$STALE" ]
check "reconcile fence: the carried run emits no literal <PDH> either" \
  err_lacks '<PDH>' "$WORK/lf2.err"

# ---- case 3: the managed partial's own line (the byte SoT) ------------------
PARTIAL_LINE=$(grep -m1 '^PDH="' "$PARTIAL" | sed 's/^[[:space:]]*//')
check "structural: the partial holds the later-fence PDH= line" [ -n "$PARTIAL_LINE" ]
fence_exec "$WORK/p1" "$STORE" "$PARTIAL_LINE
$PROBE" -u PDH -u CLAUDE_PLUGIN_ROOT
pdhp=$(sed -n 's/^PDH=//p' "$WORK/p1.out")
check "partial line: resolves the planted tier-3 edge cache with PDH unset" \
  [ "$pdhp" = "$EDGE_ROOT" ]
fence_exec "$WORK/p2" "$STORE" "$PARTIAL_LINE
$PROBE" -u CLAUDE_PLUGIN_ROOT "PDH=$STALE"
pdhp2=$(sed -n 's/^PDH=//p' "$WORK/p2.out")
check "partial line: a non-empty carried PDH is used unchanged" [ "$pdhp2" = "$STALE" ]

echo "---"
echo "later-fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
