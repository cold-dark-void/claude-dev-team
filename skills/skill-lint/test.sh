#!/usr/bin/env bash
# SPEC-021 bite-test harness. Run: bash skills/skill-lint/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT="$HERE/check-skill-bash.sh"
FIX="$HERE/fixtures"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init   # private TMPDIR/HOME: every mktemp below lives under one root
PASS=0; FAIL=0
OUT=""; RC=0

run_lint() { # run_lint <expected_exit> <args...>
  local want="$1"; shift
  OUT=$(bash "$LINT" "$@" 2>&1); RC=$?
  if [ "$RC" -eq "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: exit $RC != $want for: $*"; echo "$OUT" | head -5
  fi
}

expect_finding() { # expect_finding <check-id> <path-substring> — greps last OUT
  if echo "$OUT" | grep -q "\[$1\]" && echo "$OUT" | grep -q "$2"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: no [$1] finding for $2 in:"; echo "$OUT" | head -5
  fi
}

expect_no_finding() { # expect_no_finding <check-id>
  if echo "$OUT" | grep -q "\[$1\]"; then
    FAIL=$((FAIL+1)); echo "FAIL: unexpected [$1] finding:"; echo "$OUT" | grep "\[$1\]" | head -3
  else PASS=$((PASS+1)); fi
}

VACUITY="canonical stanza not resolvable"

expect_vacuity() { # expect_vacuity <fail-msg> — C5 must refuse a missing canonical
  if echo "$OUT" | grep -q "$VACUITY"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "$OUT" | tail -3
  fi
}

expect_no_vacuity() { # expect_no_vacuity <fail-msg> — canonical resolved cleanly
  if echo "$OUT" | grep -q "$VACUITY"; then
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "$OUT" | tail -3
  else PASS=$((PASS+1)); fi
}

# T1: clean fixture exits 0; bad flag exits 64
run_lint 0 "$FIX/clean.md"
run_lint 64 --no-such-flag

# T2: C4 — captured inline-PRAGMA flagged; heredoc + -cmd forms not flagged
run_lint 1 "$FIX/c4-pragma.md"
expect_finding C4 "c4-pragma.md:5"
run_lint 1 "$FIX/c4-pragma.md"   # same file: exactly ONE C4 finding
[ "$(echo "$OUT" | grep -c '\[C4\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 C4"; }

# T3: C2 — heredoc/quoted-string bang + HTML-comment opener flagged; legit forms not
run_lint 1 "$FIX/c2-bang.md"
expect_finding C2 "c2-bang.md"
[ "$(echo "$OUT" | grep -c '\[C2\]')" -eq 3 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 3 C2, got:"; echo "$OUT" | grep '\[C2\]'; }

# T4: C3 — unguarded globs flagged; find/case/[[ patterns not
run_lint 1 "$FIX/c3-glob.md"
expect_finding C3 "c3-glob.md"
[ "$(echo "$OUT" | grep -c '\[C3\]')" -eq 3 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 3 C3, got:"; echo "$OUT" | grep '\[C3\]'; }

# T5: C1 — cross-block use flagged; allowlist + nowhere-defined + loop vars not
# declare/local/readonly count as defs (Q4) — FIXED/Y/Z also cross-block
# indented same-block def not C1; indented sibling-only def IS C1
run_lint 1 "$FIX/c1-cross-block.md"
expect_finding C1 "c1-cross-block.md:13"
C1N=$(echo "$OUT" | grep -c '\[C1\]')
# PDH + FIXED + Y + Z + INDENTED_ONLY = 5 cross-block uses
[ "$C1N" -ge 1 ] && echo "$OUT" | grep -q '\[C1\].*\$PDH' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected C1 on \$PDH, got:"; echo "$OUT" | grep '\[C1\]'
}
# declare/local/readonly defs visible as sibling defs
echo "$OUT" | grep -q '\$FIXED\|\$Y\|\$Z' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: declare/local/readonly not treated as C1 defs"
}
# indented assignment in same block is a def — no C1 on $X
echo "$OUT" | grep '\[C1\].*\$X\b' && {
  FAIL=$((FAIL+1)); echo "FAIL: indented same-block \$X should not be C1"
} || PASS=$((PASS+1))
# indented assignment only in sibling → C1 on $INDENTED_ONLY
echo "$OUT" | grep -q '\[C1\].*\$INDENTED_ONLY' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected C1 on indented sibling-only \$INDENTED_ONLY"
}

# T6: waivers — same-line + prev-line suppress; wrong-id does not; summary counts
run_lint 1 "$FIX/waived.md"
[ "$(echo "$OUT" | grep -c '\[C3\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 unwaived C3"; }
echo "$OUT" | grep -q "3 findings, 2 waived" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: summary line wrong: $(echo "$OUT" | tail -1)"; }

# T7: discovery / coverage / CLI edges
# 1. No-arg --root temp tree: plant C4 in commands/, skills/nested/, agents/, AGENTS.md
T7ROOT=$(mktemp -d)
mkdir -p "$T7ROOT/commands" "$T7ROOT/skills/deep/nested" "$T7ROOT/agents"
PLANT='```bash'$'\n''V=$(sqlite3 db "PRAGMA busy_timeout=5000; SELECT 1;")'$'\n''```'
printf '%s\n' "$PLANT" > "$T7ROOT/commands/a.md"
printf '%s\n' "$PLANT" > "$T7ROOT/skills/deep/nested/b.md"
printf '%s\n' "$PLANT" > "$T7ROOT/agents/c.md"
printf '%s\n' "$PLANT" > "$T7ROOT/AGENTS.md"
# also plant a fixture-like path that MUST be excluded from no-arg
mkdir -p "$T7ROOT/skills/skill-lint/fixtures"
printf '%s\n' "$PLANT" > "$T7ROOT/skills/skill-lint/fixtures/planted.md"
run_lint 1 --root "$T7ROOT"
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md; do
  echo "$OUT" | grep -q "$loc" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: no-arg scan missed $loc"; }
done
echo "$OUT" | grep -q "skill-lint/fixtures/planted.md" && {
  FAIL=$((FAIL+1)); echo "FAIL: fixtures dir not excluded from no-arg discovery"
} || PASS=$((PASS+1))

# 2. File-list form: scan only named file (other planted not reported)
run_lint 1 "$T7ROOT/commands/a.md"
echo "$OUT" | grep -q "commands/a.md" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: file-list missed named file"; }
echo "$OUT" | grep -q "agents/c.md" && { FAIL=$((FAIL+1)); echo "FAIL: file-list scanned non-named file"; } || PASS=$((PASS+1))
rm -rf "$T7ROOT"

# 3. Fixtures excluded: no-arg on real repo root must NOT report fixtures/c4-pragma.md
REPO_ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(bash "$LINT" --root "$REPO_ROOT" 2>&1); RC=$?
echo "$OUT" | grep -q "fixtures/c4-pragma.md" && {
  FAIL=$((FAIL+1)); echo "FAIL: real-tree no-arg reported fixtures/c4-pragma.md"
} || PASS=$((PASS+1))

# 4. All-missing paths → 64
run_lint 64 /no/such/a.md /no/such/b.md

# 5. Unreadable skip+warn (mix with readable → not 64)
UNREAD=$(mktemp)
chmod 000 "$UNREAD" 2>/dev/null || true
if [ ! -r "$UNREAD" ]; then
  run_lint 0 "$FIX/clean.md" "$UNREAD"
  echo "$OUT" | grep -qi "warn:" && PASS=$((PASS+1)) || {
    # warn may be on stderr mixed into OUT via 2>&1
    echo "$OUT" | grep -qi "cannot read\|warn" && PASS=$((PASS+1)) || {
      FAIL=$((FAIL+1)); echo "FAIL: expected warn for unreadable path"
    }
  }
else
  PASS=$((PASS+1))  # skip if chmod ineffective (e.g. root)
fi
rm -f "$UNREAD"

# T8: C5 — PDH bootstrap-stanza drift against SPEC-002's canonical fenced block
SPEC002="$REPO_ROOT/specs/core/SPEC-002-plugin-infrastructure.md"
CANON=$(grep -m1 '^PDH=\$( {' "$SPEC002")
[ -n "$CANON" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: no canonical stanza in $SPEC002"; }
DECOY='PDH=$( { decoy-block-that-is-not-the-canonical-stanza; } )'
C3W='# lint-ok: C3 — marketplace */ for-loop + -f guarded'

# 1. Mutated-byte fixture bites; C3 waiver does not suppress C5; C5 waiver does
run_lint 1 "$FIX/c5-pdh-drift.md"
expect_finding C5 "c5-pdh-drift.md:9"
[ "$(echo "$OUT" | grep -c '\[C5\]')" -eq 1 ] && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 unwaived C5, got:"; echo "$OUT" | grep '\[C5\]'
}

# 2. Indentation tolerance: canonical at 0/2/4-space indent → no C5
T8A=$(mktemp -d)
{ printf '```bash\n%s\n%s\n```\n' "$C3W" "$CANON"
  printf '```bash\n  %s\n  %s\n```\n' "$C3W" "$CANON"
  printf '```bash\n    %s\n    %s\n```\n' "$C3W" "$CANON"; } > "$T8A/indent.md"
run_lint 0 "$T8A/indent.md"
expect_no_finding C5

# 3. Anchor bite-test: SPEC-002 holds MORE THAN ONE fenced bash block. Anchoring on
#    "first block in the file" would extract the decoy and compare every emission
#    against garbage while still exiting 0. Decoys sit both before and after the
#    canonical section here; a correct heading anchor ignores both.
T8B=$(mktemp -d)
mkdir -p "$T8B/specs/core" "$T8B/commands"
{ printf '# SPEC-002\n\n## Overview\n\n```bash\n%s\n```\n\n' "$DECOY"
  printf '### Locating `plugin-dir.sh` itself\n\n```bash\n# canonical\n%s\n```\n\n' "$CANON"
  printf '### Caller integration\n\n```bash\n%s\n```\n' "$DECOY"; } \
  > "$T8B/specs/core/SPEC-002-plugin-infrastructure.md"
printf '```bash\n%s\n%s\n```\n' "$C3W" "$CANON" > "$T8B/commands/site.md"
run_lint 0 --root "$T8B"
expect_no_finding C5
expect_no_vacuity "heading anchor did not resolve past the decoy blocks"

# 4. Vacuous-gate guard: canonical unresolvable + a live PDH stanza → loud non-zero,
#    never a silent pass. Three ways to break it, each must be distinct and fatal.
for BREAK in missing-spec broken-heading no-fence; do
  T8C=$(mktemp -d)
  mkdir -p "$T8C/specs/core" "$T8C/commands"
  printf '```bash\n%s\n%s\n```\n' "$C3W" "$CANON" > "$T8C/commands/site.md"
  case "$BREAK" in
    broken-heading)
      printf '### Finding plugin-dir.sh\n\n```bash\n%s\n```\n' "$CANON" \
        > "$T8C/specs/core/SPEC-002-plugin-infrastructure.md" ;;
    no-fence)
      printf '### Locating `plugin-dir.sh` itself\n\nProse only, no fenced block.\n' \
        > "$T8C/specs/core/SPEC-002-plugin-infrastructure.md" ;;
  esac
  run_lint 1 --root "$T8C"
  expect_vacuity "$BREAK did not report an unresolvable canonical"
  rm -rf "$T8C"
done

# 5. A `# lint-ok: C5` waiver must NOT rescue an unresolvable canonical (that would
#    re-hide the vacuity the guard exists to expose)
T8D=$(mktemp -d)
mkdir -p "$T8D/commands"
printf '```bash\n# lint-ok: C3,C5\n%s\n```\n' "$CANON" > "$T8D/commands/site.md"
run_lint 1 --root "$T8D"
expect_vacuity "C5 waiver silenced the vacuous-gate guard"
rm -rf "$T8D"

# 6. Exclusions: the locator and its test harness are exempt (they cannot bootstrap
#    themselves / hold a deliberately re-quoted copy). Control proves the test bites.
#    Fenced-md bodies in .sh paths: the file-list form scans any path handed to it.
T8E=$(mktemp -d)
mkdir -p "$T8E/skills"
printf '```bash\n%s\n%s\n```\n' "$C3W" "${CANON/k1,1V -k2,2n/k1,1n -k2,2n}" > "$T8E/skills/plugin-dir.sh"
cp "$T8E/skills/plugin-dir.sh" "$T8E/skills/plugin-dir-test.sh"
cp "$T8E/skills/plugin-dir.sh" "$T8E/skills/other.sh"
run_lint 0 --root "$REPO_ROOT" "$T8E/skills/plugin-dir.sh" "$T8E/skills/plugin-dir-test.sh"
expect_no_finding C5
run_lint 1 --root "$REPO_ROOT" "$T8E/skills/other.sh"
expect_finding C5 "other.sh"
rm -rf "$T8E" "$T8A" "$T8B"

# 7. Live-tree baseline: zero UNWAIVED C5 on the real tree (gate lands green)
OUT=$(bash "$LINT" --root "$REPO_ROOT" 2>&1); RC=$?
expect_no_finding C5
expect_no_vacuity "live tree cannot resolve the SPEC-002 canonical stanza"

# ---------------------------------------------------------------------------
# WP 1-12 (wp-1-12-fence-state): C6 assign-before-use and C10 comment/waiver
# placement. Both rules live in fence-state.awk (bash + awk, no interpreter);
# check-skill-bash.sh runs them after lint.py and merges the output.
# ---------------------------------------------------------------------------
expect_at() { # expect_at <check-id> <file-basename> <line> — one finding line at file:line
  if echo "$OUT" | grep -q "$2:$3: \[$1\]"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: no [$1] finding at $2:$3 in:"; echo "$OUT" | head -8
  fi
}

expect_count() { # expect_count <check-id> <n> — number of printed [ID] findings in last OUT
  local got
  got=$(echo "$OUT" | grep -c "\[$1\]" || true)
  if [ "$got" -eq "$2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: expected $2 [$1] finding(s), got $got:"; echo "$OUT" | grep "\[$1\]"
  fi
}

# T9: C6 — a root variable read before its first assignment in the same fence.
# Positives: fixture lines 7 (MROOT in the MEMDB= line), 21 (MEMDB tested before
# MEMDB=), 30 (PLUGIN_DIR), 38 (unquoted heredoc body), 47 (waived). Negatives:
# correct order, same-line assign, export, :=, single quotes, comments, quoted
# heredoc, longer names, and a fence that never assigns the name (C1's job).
run_lint 1 "$FIX/c6-assign-before-use.md"
expect_at C6 c6-assign-before-use.md 7
expect_at C6 c6-assign-before-use.md 21
expect_at C6 c6-assign-before-use.md 30
expect_at C6 c6-assign-before-use.md 38
expect_count C6 4
echo "$OUT" | grep -q "c6-assign-before-use.md:47:" && { FAIL=$((FAIL+1)); echo "FAIL: waived C6 at :47 was printed"; } || PASS=$((PASS+1))
echo "$OUT" | grep -q '\[C6\] \$MEMDB is used before' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: C6 message does not name \$MEMDB"; }
# the C6 waiver is counted, never silent (--json keeps waived findings)
if command -v jq >/dev/null 2>&1; then
  JW=$(bash "$LINT" --json "$FIX/c6-assign-before-use.md" 2>/dev/null | jq -r '[.[] | select(.check == "C6" and .waived)] | map(.line) | join(",")' || true)
  [ "$JW" = "47" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: waived C6 lines '$JW' != '47'"; }
else
  PASS=$((PASS+1))  # jq absent: the waived-count check needs --json
fi

# T10: C10 — comment and waiver placement. Positives: 6 (waiver after a
# continuation backslash), 13 (backslash then trailing space), 21 (comment line
# inside a continuation), 29 (waiver inside an open double quote), 39 (# inside
# a quoted sqlite3 SQL argument), 47 (# inside a single-quoted sqlite3 SQL
# argument). The NEGATIVE fence from line 54 holds the correct forms.
run_lint 1 "$FIX/c10-waiver-placement.md"
for L in 6 13 21 29 39 47; do expect_at C10 c10-waiver-placement.md "$L"; done
expect_count C10 6
echo "$OUT" | grep -q "6 findings, 0 waived" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: C10 fixture summary wrong: $(echo "$OUT" | tail -1)"; }

# 1. C10 cannot be waived: a waiver above a planted defect does not hide it
T10A=$(mktemp -d)
printf '```bash\n# lint-ok: C10\n"$E" run \\  # lint-ok: C10\n  --x\n```\n' > "$T10A/w.md"
run_lint 1 "$T10A/w.md"
expect_at C10 w.md 3
rm -rf "$T10A"

# 2. A C6 waiver must not hide C10 and the reverse (IDs are matched exactly)
T10B=$(mktemp -d)
printf '```bash\n# lint-ok: C6\nMEMDB="$MROOT/m.db"\nMROOT=$(pwd)\n# lint-ok: C10\nE=1 \\  # lint-ok: C1\n  cmd\n```\n' > "$T10B/w.md"
run_lint 1 "$T10B/w.md"
expect_no_finding C6
expect_at C10 w.md 6
rm -rf "$T10B"

# T11: wrapper contract — lint.py and fence-state.awk findings merge into one
# report; exit codes and the summary line stay one contract.
T11=$(mktemp -d)
printf '```bash\nV=$(sqlite3 db "PRAGMA busy_timeout=5000; SELECT 1;")\nMEMDB="$MROOT/m.db"\nMROOT=$(pwd)\n```\n' > "$T11/both.md"
run_lint 1 "$T11/both.md"
expect_at C4 both.md 2
expect_at C6 both.md 3
echo "$OUT" | tail -1 | grep -qx "2 findings, 0 waived" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: merged summary wrong: $(echo "$OUT" | tail -1)"; }

# C6-only file: exit 1 comes from the awk engine alone
printf '```bash\nMEMDB="$MROOT/m.db"\nMROOT=$(pwd)\n```\n' > "$T11/c6only.md"
run_lint 1 "$T11/c6only.md"
expect_at C6 c6only.md 2
# clean file still exits 0 with the original summary
run_lint 0 "$FIX/clean.md"
echo "$OUT" | tail -1 | grep -qx "0 findings, 0 waived" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: clean summary wrong: $(echo "$OUT" | tail -1)"; }

# --json: one JSON array holding both engines' findings
if command -v jq >/dev/null 2>&1; then
  JOUT=$(bash "$LINT" --json "$T11/both.md" 2>&1); JRC=$?
  [ "$JRC" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: --json exit $JRC != 1"; }
  JCHK=$(printf '%s' "$JOUT" | jq -r '[.[].check] | sort | join(",")' 2>&1 || true)
  [ "$JCHK" = "C4,C6" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: --json checks '$JCHK' != 'C4,C6'"; }
else
  PASS=$((PASS+2))  # jq absent: the --json merge needs it; nothing to assert here
fi

# usage errors keep exit 64; --help passes through to argparse (exit 0)
run_lint 64 --root
run_lint 64 --no-such-flag "$FIX/clean.md"
run_lint 0 --help
echo "$OUT" | grep -q "usage:" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: --help printed no usage"; }

# fail closed: a broken awk must never turn into a silent pass
mkdir -p "$T11/shim"
printf '#!/bin/sh\nexit 2\n' > "$T11/shim/awk"; chmod +x "$T11/shim/awk"
OUT=$(PATH="$T11/shim:$PATH" bash "$LINT" "$FIX/clean.md" 2>&1); RC=$?
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "fence-state" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: broken awk must exit 1 naming fence-state (rc=$RC): $(echo "$OUT" | tail -2)"; }

# no-arg discovery proves C6 and C10 over every globbed location (coverage
# bite-test), and skips the fixtures directory
T11R=$(mktemp -d)
mkdir -p "$T11R/commands" "$T11R/skills/deep/nested" "$T11R/agents" "$T11R/skills/skill-lint/fixtures"
PLANT6='```bash'$'\n''MEMDB="$MROOT/m.db"'$'\n''MROOT=$(pwd)'$'\n''```'
PLANT10='```bash'$'\n''E=1 \  # c'$'\n''  cmd'$'\n''```'
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md; do
  printf '%s\n%s\n' "$PLANT6" "$PLANT10" > "$T11R/$loc"
done
printf '%s\n%s\n' "$PLANT6" "$PLANT10" > "$T11R/skills/skill-lint/fixtures/planted.md"
run_lint 1 --root "$T11R"
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md; do
  echo "$OUT" | grep -q "$loc:2: \[C6\]" && echo "$OUT" | grep -q "$loc:6: \[C10\]" && PASS=$((PASS+1)) || {
    FAIL=$((FAIL+1)); echo "FAIL: no-arg scan missed C6/C10 in $loc"; }
done
echo "$OUT" | grep -q "fixtures/planted.md" && { FAIL=$((FAIL+1)); echo "FAIL: fixtures dir scanned by the awk engine"; } || PASS=$((PASS+1))
rm -rf "$T11" "$T11R"

# T12: live tree — zero C6 and zero C10 findings. C10 cannot be waived. A real
# C6 hit is fixed by reordering the block, never waived, so the live tree must
# hold no C6 waiver either. The JSON keeps waived findings, so a waiver cannot
# hide a hit from this count.
if command -v jq >/dev/null 2>&1; then
  LIVE=$({ bash "$LINT" --json --root "$REPO_ROOT" 2>/dev/null || true; } | jq -r '[.[] | select(.check == "C6" or .check == "C10")] | map("\(.path):\(.line):\(.check):\(.waived)") | join(" ")' 2>&1)
  [ -z "$LIVE" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: live tree has C6/C10 findings: $LIVE"; }
else
  OUT=$(bash "$LINT" --root "$REPO_ROOT" 2>&1); RC=$?
  expect_no_finding C6
  expect_no_finding C10
fi

# T13 (WP 2-01): C6 also guards PDH and EXT_DIR. Positives: fixture lines 6
# (PDH read before its bootstrap) and 15 (EXT_DIR read before it is assigned);
# line 23 holds a waived PDH read. Negatives: correct order, export, :=, quotes,
# comments, a longer name, and a fence that never assigns the name (C1's job).
run_lint 1 "$FIX/c6-resolver-names.md"
expect_at C6 c6-resolver-names.md 6
expect_at C6 c6-resolver-names.md 15
expect_count C6 2
echo "$OUT" | grep -q '\[C6\] \$PDH is used before' && echo "$OUT" | grep -q '\[C6\] \$EXT_DIR is used before' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: C6 messages must name \$PDH and \$EXT_DIR"; }
echo "$OUT" | grep -q "c6-resolver-names.md:23:.*\[C6\]" && { FAIL=$((FAIL+1)); echo "FAIL: waived C6 at :23 was printed"; } || PASS=$((PASS+1))
# the waiver is counted (--json keeps waived findings), never silent
if command -v jq >/dev/null 2>&1; then
  JW=$(bash "$LINT" --json "$FIX/c6-resolver-names.md" 2>/dev/null | jq -r '[.[] | select(.check == "C6" and .waived)] | map(.line) | join(",")' || true)
  [ "$JW" = "23" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: waived C6 lines '$JW' != '23'"; }
else
  PASS=$((PASS+1))  # jq absent: the waived-count check needs --json
fi

# T14 (WP 2-01): one fence parser and one scan set for every engine that reads
# fences in awk and bash. fence-scan.awk owns the fence-opener match and
# scan-set.sh owns discovery; fence-state.awk and check-skill-bash.sh carry no
# copy. The same grep must find the opener match in fence-scan.awk (planted
# negative control), so a moved comment cannot make the check pass by accident.
FENCE_OPEN_RE='\[ \\t\]\*```'
grep -q "$FENCE_OPEN_RE" "$HERE/fence-scan.awk" 2>/dev/null && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: control: fence-scan.awk must hold the fence-opener match"; }
grep -q "$FENCE_OPEN_RE" "$HERE/fence-state.awk" && { FAIL=$((FAIL+1)); echo "FAIL: fence-state.awk still holds its own fence-opener match"; } || PASS=$((PASS+1))
grep -q 'discover()' "$HERE/check-skill-bash.sh" && { FAIL=$((FAIL+1)); echo "FAIL: check-skill-bash.sh still holds its own discover()"; } || PASS=$((PASS+1))
[ -f "$HERE/scan-set.sh" ] && grep -q 'skill_lint_scan_set()' "$HERE/scan-set.sh" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: scan-set.sh must define skill_lint_scan_set"; }

echo "---"
echo "skill-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
