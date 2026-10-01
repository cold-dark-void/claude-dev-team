#!/usr/bin/env bash
# tools/fence-exec/test.sh — SPEC-030 R23+ bite-tests of the fence-exec harness.
# Run: bash tools/fence-exec/test.sh
#
# Every check F1-F5 has a fixture in fixtures/ with planted positives and
# negative controls. A mutant copy of the harness with one rule switched off
# must lose exactly that rule's findings, so each test is shown to depend on the
# code it guards. The live tree must exit 0, and a canary appended to every
# live fence must be read (the lexer stays in sync to the last line).
#
# Hermetic: hermetic_init puts TMPDIR and HOME under one private root. The
# suite writes nothing under the checkout.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
# shellcheck source=../../tests/lib/hermetic.sh
. "$REPO/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/check.sh
. "$REPO/tests/lib/check.sh"
hermetic_init
cd "$REPO" || exit 1

pass=0
fail=0
RUN="$HERE/run.sh"
FIX="$HERE/fixtures"
OUT=""
RC=0

run_with() { # run_with RUN.SH ARGS... — OUT holds stdout+stderr, RC the exit code (240 s cap when timeout exists)
  local runsh="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    OUT=$(timeout 240 bash "$runsh" "$@" 2>&1 < /dev/null); RC=$?
  else
    OUT=$(bash "$runsh" "$@" 2>&1 < /dev/null); RC=$?
  fi
}
run_h() { run_with "$RUN" "$@"; }

has_at() { printf '%s\n' "$OUT" | grep -q -- "$1:$2: \[$3\]"; }
n_of() { printf '%s\n' "$OUT" | grep -c -- "\[$1\]" || true; }
is_rc() { [ "$RC" -eq "$1" ]; }
count_is() { [ "$(n_of "$1")" -eq "$2" ]; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
out_lacks() { ! printf '%s\n' "$OUT" | grep -qF -- "$1"; }
summary_zero() { printf "%s\n" "$OUT" | grep -q "^0 findings, "; }

# ---------------------------------------------------------------------------
# F1 — bash -n per fence (CDT-272 goal 2). Positives: line 9 and line 40 (a bash title template fence: template is the third word, so it is no template). Negatives: a clean
# fence, a `bash template` fence and a non-bash fence.
# ---------------------------------------------------------------------------
run_h check --manifest none "$FIX/f1-syntax.md"
check "F1: a fence that fails bash -n exits 1" is_rc 1
check "F1: finding at the failing line (fence line 2 of the fence at 8)" has_at "tools/fence-exec/fixtures/f1-syntax.md" 9 F1
check "F1: the fence whose info string is bash title template is checked (template is not the second word)" has_at "tools/fence-exec/fixtures/f1-syntax.md" 40 F1
check "F1: exactly two findings (clean, template and sql fences are silent)" count_is F1 2
check "F1: the finding names its section" out_has "(section: Positive)"

# One definition of a template fence for F1 and F2-F4: the second word of the info
# string is exactly template (as smoke.py is_template_fence). The engine emits the
# flag; run.sh reads it. A `bash template` fence gets no check; `bash x template` gets both.
TPL="$HERMETIC_ROOT/tpl.md"
printf '# T\n\n```bash template\nreturn 1\necho )\n```\n\n```bash x template\nreturn 2\necho )\n```\n' > "$TPL"
run_h check --manifest none "$TPL"
check "template: F4 fires only in the bash x template fence (line 9), not in the bash template fence" has_at "$TPL" 9 F4
check "template: one F4 finding" count_is F4 1
check "template: F1 fires only in the bash x template fence (line 10)" has_at "$TPL" 10 F1
check "template: one F1 finding" count_is F1 1

# ---------------------------------------------------------------------------
# F2 — a function that only another fence defines (goal 3).
# ---------------------------------------------------------------------------
run_h check --manifest none "$FIX/f2-function-scope.md"
check "F2: exits 1" is_rc 1
for l in 19 25 26 71 72 73 74 75 76 77 78 79; do check "F2: call at line $l" has_at "tools/fence-exec/fixtures/f2-function-scope.md" "$l" F2; done
check "F2: exactly fifteen findings (three calls on lines 71 and 72 count each; own copy, text, function keyword, template, unknown name are silent)" count_is F2 15
check "F2: the message names the function and its defining line" out_has '`fe_helper` is called here but only another fence of this file defines it (line 8)'

# ---------------------------------------------------------------------------
# F3 — trap EXIT outside a script-body fence (goal 3, the /retro trap).
# ---------------------------------------------------------------------------
run_h check --manifest none "$FIX/f3-trap-exit.md"
check "F3: exits 1" is_rc 1
for l in 10 16 23; do check "F3: trap at line $l" has_at "tools/fence-exec/fixtures/f3-trap-exit.md" "$l" F3; done
check "F3: exactly three findings (own-fence rm, shebang body, other signals, template are silent)" count_is F3 3
check "F3: the rm trap names the variable that another fence reads" out_has 'it deletes $WORKDIR when this fence ends, and the fence at line'

# ---------------------------------------------------------------------------
# F4 — return outside a function (goal 3).
# ---------------------------------------------------------------------------
run_h check --manifest none "$FIX/f4-return.md"
check "F4: exits 1" is_rc 1
for l in 9 15 17; do check "F4: return at line $l" has_at "tools/fence-exec/fixtures/f4-return.md" "$l" F4; done
check "F4: exactly three findings (function bodies, text, heredoc, comment are silent)" count_is F4 3

# ---------------------------------------------------------------------------
# F5 — path literals against the repo (goal 4). The fixture root holds
# skills/plugin-dir.sh, skills/real/lib.sh and skills/real/schema.sql.
# ---------------------------------------------------------------------------
run_h check --manifest none --root "$FIX/f5-root" "$FIX/f5-root/commands/paths.md"
check "F5: exits 1" is_rc 1
for l in 8 9 10 11 18; do check "F5: missing path at line $l" has_at "commands/paths.md" "$l" F5; done
check "F5: exactly five findings (existing paths, placeholders, globs, comments, heredoc are silent)" count_is F5 5
check "F5: a \$PLUGIN_DIR leaf resolves next to the plugin-dir.sh dir literal" out_has 'path literal skills/real/absent.sql does not exist'

# ---------------------------------------------------------------------------
# Clean fixture: realistic shell shapes read without a finding.
# ---------------------------------------------------------------------------
run_h check --manifest none "$FIX/clean.md"
check "clean fixture: exit 0" is_rc 0
check "clean fixture: summary" out_has "0 findings, 0 excluded (4 fences in 1 files)"

# Canary: a top-level return appended to every fence of clean.md must be found
# in each of the four fences. A lexer that lost its place in a quote, a
# heredoc or a substitution would hide the canary.
canary_copy() { # canary_copy SRC DEST LISTROWS — DEST is SRC with `return 9` after each non-template fence body
  local src="$1" dest="$2" rows="$3" ends
  ends=$(printf '%s\n' "$rows" | FENCE_SRC="$src" awk -F'\t' '$1 == ENVIRON["FENCE_SRC"] && $5 !~ /template/ && $3 >= $2 { printf "%s%s", (n++ ? "," : ""), $3 }')
  ENDS="$ends" awk 'BEGIN { n = split(ENVIRON["ENDS"], a, ","); for (i = 1; i <= n; i++) e[a[i]] = 1 } { print } (FNR in e) { print "return 9" }' "$src" > "$dest"
}
CAN="$HERMETIC_ROOT/canary"
mkdir -p "$CAN"
run_h list --manifest none "$FIX/clean.md"
ROWS="$OUT"
canary_copy "tools/fence-exec/fixtures/clean.md" "$CAN/clean.md" "$ROWS"
run_h check --manifest none "$CAN/clean.md"
check "canary: one return found per fence of the clean fixture" count_is F4 4

# ---------------------------------------------------------------------------
# list — every bash fence with file, first line, last line, heading, info.
# ---------------------------------------------------------------------------
run_h list --manifest none "$FIX/f4-return.md"
check "list: exit 0" is_rc 0
check "list: a row names file, start, end, heading and info" out_has "$(printf 'tools/fence-exec/fixtures/f4-return.md\t8\t9\tPositives\tbash')"
check "list: four fences" test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 4

# ---------------------------------------------------------------------------
# No-argument discovery covers commands/, skills/**, agents/ and AGENTS.md, and
# skips skill-lint fixtures (coverage bite-test).
# ---------------------------------------------------------------------------
TREE="$HERMETIC_ROOT/tree"
mkdir -p "$TREE/commands" "$TREE/skills/deep/nested" "$TREE/agents" "$TREE/skills/skill-lint/fixtures"
PLANT=$(printf '# Plant\n\n```bash\nreturn 1\n```\n')
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md skills/skill-lint/fixtures/planted.md; do
  printf '%s\n' "$PLANT" > "$TREE/$loc"
done
run_h check --manifest none --root "$TREE"
check "discovery: exit 1" is_rc 1
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md; do
  check "discovery: $loc is scanned" has_at "$loc" 4 F4
done
check "discovery: fixtures directory is skipped" out_lacks "fixtures/planted.md"
check "discovery: four findings" count_is F4 4

# ---------------------------------------------------------------------------
# Fail closed: a broken awk is never a clean run. Usage errors exit 64.
# ---------------------------------------------------------------------------
SHIM="$HERMETIC_ROOT/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 2\n' > "$SHIM/awk"
chmod +x "$SHIM/awk"
PATH="$SHIM:$PATH" run_with "$RUN" check --manifest none "$FIX/clean.md"
check "fail closed: a failing awk exits 1" is_rc 1
check "fail closed: says the fences were not checked" out_has "refusing to report a clean run"

run_h --help
check "usage: --help exits 0" is_rc 0
check "usage: --help prints the usage" out_has "Usage: bash tools/fence-exec/run.sh"
run_h --no-such-flag
check "usage: unknown option exits 64" is_rc 64
run_h check run
check "usage: two subcommands exit 64" is_rc 64
run_h check --manifest none "$HERMETIC_ROOT/absent.md"
check "usage: no readable FILE exits 64" is_rc 64
run_h check --root "$HERMETIC_ROOT/absent" --manifest none "$FIX/clean.md"
check "usage: a --root that is not a directory exits 64" is_rc 64
run_h check --manifest "$HERMETIC_ROOT/absent.tsv" "$FIX/clean.md"
check "usage: a --manifest that is not a file exits 64" is_rc 64

# ---------------------------------------------------------------------------
# Manifest (goal 5): exclusions are counted and reasoned; suite rows are linked
# to their fence; `run` executes each suite once.
# ---------------------------------------------------------------------------
M="$HERMETIC_ROOT/mroot"
mkdir -p "$M/commands" "$M/tests"
printf '# Doc\n\n## Step 1: Do it\n\n```bash\nreturn 1\n```\n\n## Step 2: Other\n\n```bash\nreturn 2\n```\n' > "$M/commands/doc.md"
printf '#!/usr/bin/env bash\necho "suite-a ran for: Step 1: Do it"\nprintf x >> "%s/count-a"\nexit 0\n' "$HERMETIC_ROOT" > "$M/tests/test-a.sh"
printf '#!/usr/bin/env bash\necho "suite-b ran for: Step 2: Other"\nexit 3\n' > "$M/tests/test-b.sh"
TAB=$(printf '\t')
mrow() { local IFS="$TAB"; printf '%s\n' "$*"; }

mrow exclude F4 commands/doc.md "section: Step 1: Do it" 1 doc-step-one "Step 1 is pseudocode, tracked in the backlog item" > "$M/ok.tsv"
run_h check --root "$M" --manifest "$M/ok.tsv"
check "manifest: a matching exclusion keeps the finding out of the count (Step 2 still reported)" has_at "commands/doc.md" 12 F4
check "manifest: one finding and one excluded" out_has "1 findings, 1 excluded"
check "manifest: an exclusion is printed, never silent" out_has "excluded: [F4] commands/doc.md, 1 finding(s), backlog doc-step-one — Step 1 is pseudocode, tracked in the backlog item"

mrow exclude F4 commands/doc.md "outside a function" 2 doc-all "both steps" > "$M/all.tsv"
run_h check --root "$M" --manifest "$M/all.tsv"
check "manifest: exclusions that cover every finding exit 0" is_rc 0
check "manifest: 0 findings, 2 excluded" out_has "0 findings, 2 excluded"

mrow exclude F4 commands/doc.md "outside a function" 3 doc-all "count too high" > "$M/count.tsv"
run_h check --root "$M" --manifest "$M/count.tsv"
check "manifest: a wrong count is an M1 finding and exits 1" is_rc 1
check "manifest: the M1 line names the two counts" out_has 'matched 2 finding(s), the manifest says 3'

mrow exclude F4 commands/doc.md "no such text" 1 doc-stale "stale row" > "$M/stale.tsv"
run_h check --root "$M" --manifest "$M/stale.tsv"
check "manifest: a stale exclusion (matches nothing) is an M1 finding" out_has 'matched 0 finding(s), the manifest says 1'
check "manifest: the two real findings are still reported" count_is F4 2

mrow exclude F2 commands/doc.md "outside a function" 2 doc-all "wrong check id" > "$M/wrongcheck.tsv"
run_h check --root "$M" --manifest "$M/wrongcheck.tsv"
check "manifest: an exclusion for another check hides nothing" count_is F4 2

printf 'exclude\tF9\tcommands/doc.md\tx\t1\tslug\treason\n' > "$M/bad1.tsv"
run_h check --root "$M" --manifest "$M/bad1.tsv"
check "manifest: an unknown check id exits 64" is_rc 64
printf 'exclude\tF4\tcommands/doc.md\tx\t1\tslug\t\n' > "$M/bad2.tsv"
run_h check --root "$M" --manifest "$M/bad2.tsv"
check "manifest: an empty reason exits 64" is_rc 64
printf 'exclude\tF4\tcommands/doc.md\tx\t0\tslug\treason\n' > "$M/bad3.tsv"
run_h check --root "$M" --manifest "$M/bad3.tsv"
check "manifest: a zero count exits 64" is_rc 64
printf 'exclude\tF4\tcommands/doc.md\tx\t1\tBad Slug\treason\n' > "$M/bad4.tsv"
run_h check --root "$M" --manifest "$M/bad4.tsv"
check "manifest: a backlog slug with spaces exits 64" is_rc 64
printf 'frobnicate\ta\tb\n' > "$M/bad5.tsv"
run_h check --root "$M" --manifest "$M/bad5.tsv"
check "manifest: an unknown row kind exits 64" is_rc 64
printf 'suite\tcommands/doc.md\tStep 1\n' > "$M/bad6.tsv"
run_h check --root "$M" --manifest "$M/bad6.tsv"
check "manifest: a suite row with too few fields exits 64" is_rc 64

# suite rows (static link): the fence exists and the suite names its heading
{
  mrow exclude F4 commands/doc.md "outside a function" 2 doc-all "both steps"
  mrow suite commands/doc.md "Step 1: Do it" tests/test-a.sh "runs step 1"
  mrow suite commands/doc.md "Step 2: Other" tests/test-b.sh "runs step 2"
} > "$M/suites.tsv"
run_h check --root "$M" --manifest "$M/suites.tsv"
check "suite rows: linked suites and fences pass the static check" is_rc 0

mrow exclude F4 commands/doc.md "outside a function" 2 doc-all "both" > "$M/link.tsv"
mrow suite commands/doc.md "Step 9: Missing" tests/test-a.sh "heading absent" >> "$M/link.tsv"
run_h check --root "$M" --manifest "$M/link.tsv"
check "suite rows: a heading that is not in the file is an M1 finding" out_has "has no bash fence under a heading that holds 'Step 9: Missing'"
check "suite rows: a suite that never names the heading is an M1 finding" out_has "never names the heading 'Step 9: Missing'"

mrow exclude F4 commands/doc.md "outside a function" 2 doc-all "both" > "$M/link2.tsv"
mrow suite commands/nope.md "Step 1" tests/test-a.sh "file absent" >> "$M/link2.tsv"
mrow suite commands/doc.md "Step 1: Do it" tests/absent-test.sh "suite absent" >> "$M/link2.tsv"
mrow suite commands/doc.md "Step 1: Do it" tests/helper.sh "not a suite name" >> "$M/link2.tsv"
printf '# helper\n' > "$M/tests/helper.sh"
run_h check --root "$M" --manifest "$M/link2.tsv"
check "suite rows: an absent doc file is an M1 finding" out_has "names commands/nope.md, which does not exist"
check "suite rows: an absent suite is an M1 finding" out_has "names tests/absent-test.sh, which does not exist"
check "suite rows: a name the all-suites runner would not discover is an M1 finding" out_has "is not a suite name the all-suites runner discovers"

# run: each suite once, a failing suite fails the run and shows its output
{
  mrow exclude F4 commands/doc.md "outside a function" 2 doc-all "both steps"
  mrow suite commands/doc.md "Step 1: Do it" tests/test-a.sh "runs step 1"
  mrow suite commands/doc.md "Step 1: Do it" tests/test-a.sh "second row, same suite"
  mrow suite commands/doc.md "Step 2: Other" tests/test-b.sh "runs step 2"
} > "$M/run.tsv"
rm -f "$HERMETIC_ROOT/count-a"
run_h run --root "$M" --manifest "$M/run.tsv"
check "run: a failing suite exits 1" is_rc 1
check "run: the passing suite is reported" out_has "PASS suite tests/test-a.sh"
check "run: the failing suite is reported with its rc" out_has "FAIL suite tests/test-b.sh (rc=3)"
check "run: the failing suite's output is shown" out_has "| suite-b ran for: Step 2: Other"
check "run: two suites, one failed" out_has "2 suites, 1 failed"
check "run: a suite listed twice runs once" test "$(wc -c < "$HERMETIC_ROOT/count-a" | tr -d ' ')" -eq 1

{
  mrow exclude F4 commands/doc.md "outside a function" 2 doc-all "both steps"
  mrow suite commands/doc.md "Step 1: Do it" tests/test-a.sh "runs step 1"
} > "$M/run-ok.tsv"
run_h run --root "$M" --manifest "$M/run-ok.tsv"
check "run: all suites passing exits 0" is_rc 0
run_h run --root "$M" --manifest "$M/stale.tsv"
check "run: a static finding fails the run (no suite output needed)" is_rc 1

# ---------------------------------------------------------------------------
# Mutants: switch one rule off in a private copy of the harness. The planted
# positives must disappear, which shows each test above depends on its rule.
# ---------------------------------------------------------------------------
mutant() { # mutant NAME SED-ON-ENGINE SED-ON-RUN — builds $HERMETIC_ROOT/mut-NAME
  local d="$HERMETIC_ROOT/mut-$1"
  mkdir -p "$d/tools/fence-exec" "$d/skills/skill-lint" "$d/tests/lib"
  cp "$HERE/run.sh" "$HERE/fence-check.awk" "$d/tools/fence-exec/"
  cp "$REPO/skills/skill-lint/fence-scan.awk" "$REPO/skills/skill-lint/scan-set.sh" "$d/skills/skill-lint/"
  cp "$REPO/tests/lib/fence.sh" "$d/tests/lib/"
  sed -i.bak -e "$2" "$d/tools/fence-exec/fence-check.awk"
  sed -i.bak -e "$3" "$d/tools/fence-exec/run.sh"
  printf 'function nofinding(a, b, c, d) { }\n' >> "$d/tools/fence-exec/fence-check.awk"
}
mut_run() { # mut_run NAME ARGS...
  local n="$1"
  shift
  run_with "$HERMETIC_ROOT/mut-$n/tools/fence-exec/run.sh" "$@"
}
mutant f1 's/^$//' 's/bash -n "\$WORK/true "$WORK/'
mut_run f1 check --manifest none "$FIX/f1-syntax.md"
check "mutant F1 (bash -n off): the planted syntax error goes unreported" count_is F1 0
mutant f2 's/finding("F2"/nofinding("F2"/' 's/^$//'
mut_run f2 check --manifest none "$FIX/f2-function-scope.md"
check "mutant F2 (rule off): the planted calls go unreported" count_is F2 0
mutant f3 's/finding("F3"/nofinding("F3"/' 's/^$//'
mut_run f3 check --manifest none "$FIX/f3-trap-exit.md"
check "mutant F3 (rule off): the planted traps go unreported" count_is F3 0
mutant f4 's/finding("F4"/nofinding("F4"/' 's/^$//'
mut_run f4 check --manifest none "$FIX/f4-return.md"
check "mutant F4 (rule off): the planted returns go unreported" count_is F4 0
mutant f5 's/^$//' 's/add_finding "F5"/true "F5"/'
mut_run f5 check --manifest none --root "$FIX/f5-root" "$FIX/f5-root/commands/paths.md"
check "mutant F5 (rule off): the planted paths go unreported" count_is F5 0
# control: the unmodified copy of the harness still reports them
mutant ctl 's/^$//' 's/^$//'
mut_run ctl check --manifest none "$FIX/f4-return.md"
check "mutant control: an unmodified copy reports the F4 positives" count_is F4 3

# ---------------------------------------------------------------------------
# Live tree: exit 0 with the committed manifest, and the scan is not vacuous.
# ---------------------------------------------------------------------------
run_h check
check "live tree: check exits 0" is_rc 0
check "live tree: no unexcluded finding" summary_zero
check "live tree: the retro F2 exclusion is gone" out_lacks "excluded: [F2] commands/retro.md, 4 finding(s), backlog wp-2-10-retro-scheduled"
check "live tree: the retro F3 exclusion is gone" out_lacks "excluded: [F3] commands/retro.md, 1 finding(s), backlog wp-2-10-retro-scheduled"
check "live tree: the manifest holds no exclude row" test "$(grep -c '^exclude' "$HERE/manifest.tsv")" -eq 0
re='\(([0-9]+) fences in ([0-9]+) files\)'
if [[ "$OUT" =~ $re ]] && [ "${BASH_REMATCH[1]}" -ge 400 ] && [ "${BASH_REMATCH[2]}" -ge 150 ]; then
  pass_line "live tree: the scan covers at least 400 fences in 150 files (${BASH_REMATCH[1]} fences, ${BASH_REMATCH[2]} files)"
else
  fail_line "live tree: the scan is vacuous or the summary changed: $(printf '%s\n' "$OUT" | tail -1)"
fi

# The starting set of CDT-272 goal 5 is in the committed manifest: each fence is
# tied to the suite that runs it. The same predicate fails on a manifest with
# one row removed (planted negative control).
not() { ! "$@"; }
has_suite_row() { # has_suite_row MANIFEST FILE NEEDLE — a suite row for FILE whose heading needle holds NEEDLE
  MF="$2" MN="$3" awk -F'\t' '$1 == "suite" && $2 == ENVIRON["MF"] && index($3, ENVIRON["MN"]) > 0 { found = 1 } END { exit !found }' "$1"
}
REQ='commands/setup.md|Sub: `team`
commands/memory.md|Step 5: Check distill_enabled
commands/memory.md|Step 10.1
commands/memory.md|Step 10.5
skills/memory-recall/SKILL.md|Step 4: Semantic search
commands/retro.md|Step 1b: Scheduled path lock
skills/review-and-commit/SKILL.md|Step 5: Finalize
skills/refactor/SKILL.md|Step 1b'
while IFS='|' read -r rf rn || [ -n "$rf" ]; do
  [ -n "$rf" ] || continue
  check "manifest: a suite row runs $rf under '$rn'" has_suite_row "$HERE/manifest.tsv" "$rf" "$rn"
done <<EOF2
$REQ
EOF2
grep -v 'skills/refactor/SKILL.md' "$HERE/manifest.tsv" > "$HERMETIC_ROOT/manifest-less.tsv"
check "manifest: the predicate fails when the refactor row is removed (negative control)" not has_suite_row "$HERMETIC_ROOT/manifest-less.tsv" "skills/refactor/SKILL.md" "Step 1b"

# Canary over every live fence: the lexer must reach the last line of each
# non-template fence. Copies go under the private root; nothing is written in
# the checkout. The live tree holds no top-level return, so the canary count
# per file must equal the fence count per file.
run_h list
LIVE_ROWS="$OUT"
LC="$HERMETIC_ROOT/livecanary"
mkdir -p "$LC"
files=$(printf '%s\n' "$LIVE_ROWS" | cut -f1 | sort -u)
while IFS= read -r f || [ -n "$f" ]; do
  [ -n "$f" ] || continue
  mkdir -p "$LC/$(dirname "$f")"
  canary_copy "$f" "$LC/$f" "$LIVE_ROWS"
done <<EOF
$files
EOF
want=$(printf '%s\n' "$LIVE_ROWS" | awk -F'\t' '$5 !~ /template/ && $3 >= $2 { n[$1]++ } END { for (k in n) print k, n[k] }' | sort)
LCFILES=()
while IFS= read -r f || [ -n "$f" ]; do LCFILES+=("$LC/$f"); done < <(cd "$LC" && find . -name '*.md' | sed 's|^\./||' | sort)
run_h check --manifest none --root "$LC" "${LCFILES[@]}"
got=$(printf '%s\n' "$OUT" | awk '/\[F4\]/ { split($1, a, ":"); n[a[1]]++ } END { for (k in n) print k, n[k] }' | sort)
if [ "$want" = "$got" ] && [ -n "$want" ]; then
  pass_line "live canary: a return appended to every non-template fence is found in each one"
else
  fail_line "live canary: the lexer lost its place in some fences: $(printf '%s\n%s\n' "$want" "$got" | sort | uniq -u | head -5 | tr '\n' ';')"
fi

echo "---"
echo "fence-exec tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
