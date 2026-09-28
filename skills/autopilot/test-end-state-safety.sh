#!/usr/bin/env bash
# skills/autopilot/test-end-state-safety.sh — SPEC-025 wp-1-05-git-safety-lib
# AC H, AC I. Extracts the fenced bash blocks under end-state.md's "## 4."
# and "## 6.5" headings (C3 harness contract in the WP plan) and runs them
# against fixture repos, without refactoring end-state.md into a script.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); every fixture repo
# lives under $TMPDIR. GIT_SAFETY resolution for the extracted blocks goes
# through CLAUDE_PLUGIN_ROOT=$ROOT (plugin-dir.sh Tier 0 force), which works
# from any cwd, including a fixture repo that is not the plugin checkout.
#
# Expected RED on df697cb (T4, wave 1): the current end-state.md has no
# is-clean gate in §4, still runs bare `git reset --hard` in §4 and §6.5
# prose, and §6.5 has zero fenced bash blocks at all. T6 (wave 2) makes
# this suite green.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
END_STATE="$ROOT/skills/autopilot/end-state.md"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

pass=0
fail=0
pass_line() { echo "PASS: $1"; pass=$((pass + 1)); }
fail_line() { echo "FAIL: $1"; fail=$((fail + 1)); }

# ---- section / block extraction (C3 harness contract) ----------------------

# Section = lines from the heading line (exclusive) to the next "^## " line.
extract_section_4() {
  awk '
    /^## 4\. / { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec { print }
  ' "$END_STATE"
}

extract_section_65() {
  awk '
    /^## 6\.5 / { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec { print }
  ' "$END_STATE"
}

# Blocks = lines between an opener matching "^```bash" and the next line
# that is exactly three backticks. Concatenates every such block in order.
extract_blocks() {
  awk '
    /^```bash/ { inblk = 1; next }
    inblk && $0 == "```" { inblk = 0; next }
    inblk { print }
  '
}

sec4_text="$(extract_section_4)"
sec65_text="$(extract_section_65)"
blocks4="$(printf '%s\n' "$sec4_text" | extract_blocks)"
blocks65="$(printf '%s\n' "$sec65_text" | extract_blocks)"

# Zero extracted blocks in a section is itself a FAIL (bite: proves the
# harness is reading real fenced content, not silently running nothing).
if [ -n "$blocks4" ]; then
  pass_line "structural: §4 has at least one fenced bash block"
else
  fail_line "structural: §4 has at least one fenced bash block (zero extracted)"
fi
if [ -n "$blocks65" ]; then
  pass_line "structural: §6.5 has at least one fenced bash block"
else
  fail_line "structural: §6.5 has at least one fenced bash block (zero extracted — AC I)"
fi

# ---- substitution -----------------------------------------------------------

# subst_block <main-repo-path> <branch> <card-path> <ship-start-sha>
# Reads a block on stdin, prints it substituted. <SHIP_START_SHA> is
# replaced ONLY on the line matching literal ^SHIP_START_SHA="<SHIP_START_SHA>"
# (the guard's comparison literal stays otherwise, or the guard trips).
subst_block() {
  local mainpath="$1" branch="$2" cardpath="$3" sha="$4"
  sed \
    -e "s|<main-repo-path>|$mainpath|g" \
    -e "s|<branch>|$branch|g" \
    -e "s|<card-path>|$cardpath|g" \
    -e "/^SHIP_START_SHA=\"<SHIP_START_SHA>\"/ s|<SHIP_START_SHA>|$sha|"
}

# run_block <fixture-dir> <substituted-block-text>
# Writes the block into a run_block() function body under $TMPDIR and runs
# it with `bash <file>` (never sourced), cwd pinned to the fixture dir so a
# missed placeholder cannot touch the shared worktree. Aborts the whole
# suite (harness error, not a product FAIL) if any bracket placeholder
# survives substitution — EXCEPT the §6.5 guard's own comparison literal
# (`!= "<SHIP_START_SHA>"`), which the C3 harness contract requires to stay
# unsubstituted (subst_block only rewrites the SHIP_START_SHA= assignment
# line), so it is masked out before this check runs.
run_block() {
  local fx="$1" block="$2" outfile out rc check
  check="$(printf '%s\n' "$block" | sed 's/!= "<SHIP_START_SHA>"/!= "GUARD_LITERAL"/')"
  if printf '%s\n' "$check" | grep -qE '<(main-repo-path|branch|card-path|SHIP_START_SHA)>'; then
    echo "HARNESS ERROR: unsubstituted placeholder survived — aborting suite" >&2
    printf '%s\n' "$block" >&2
    exit 2
  fi
  outfile="$(mktemp "$TMPDIR/run-block.XXXXXX")"
  {
    echo 'run_block() {'
    printf '%s\n' "$block"
    echo '}'
    echo 'run_block'
  } >"$outfile"
  # `timeout` is not stock on macOS bash 3.2 — use it only when present.
  local run_cmd=(bash "$outfile")
  if command -v timeout >/dev/null 2>&1; then
    run_cmd=(timeout 20 "${run_cmd[@]}")
  fi
  out=$(cd "$fx" && CLAUDE_PLUGIN_ROOT="$ROOT" "${run_cmd[@]}" 2>&1)
  rc=$?
  rm -f "$outfile"
  RUN_OUT="$out"
  return $rc
}

# ---- fixtures ----------------------------------------------------------------

# build_fixture: master (base.txt) + branch feat/x (adds feature.txt, no
# overlap with base.txt). Prints the repo dir.
build_fixture() {
  local dir
  dir="$(mktemp -d "$TMPDIR/fixture.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q .
    git symbolic-ref HEAD refs/heads/master
    printf 'base\n' >base.txt
    git add base.txt
    git commit -q -m base
    git checkout -q -b feat/x
    printf 'feature change\n' >feature.txt
    git add feature.txt
    git commit -q -m feature
    git checkout -q master
  ) || return 1
  printf '%s\n' "$dir"
}

# build_conflict_fixture: master and feat/x each edit the same line of
# shared.txt so `git merge --squash` reports a real conflict.
build_conflict_fixture() {
  local dir
  dir="$(mktemp -d "$TMPDIR/fixture-conflict.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q .
    git symbolic-ref HEAD refs/heads/master
    printf 'line-one\n' >shared.txt
    git add shared.txt
    git commit -q -m base
    git checkout -q -b feat/x
    printf 'line-branch\n' >shared.txt
    git add shared.txt
    git commit -q -m branch-edit
    git checkout -q master
    printf 'line-main\n' >shared.txt
    git add shared.txt
    git commit -q -m main-edit
  ) || return 1
  printf '%s\n' "$dir"
}

# build_untracked_collision_fixture: feat/x ADDS a file at a path that main
# also has, untracked, with different bytes — the security-council premise
# probe (Step 6c): does `git merge --squash` really refuse to clobber it?
build_untracked_collision_fixture() {
  local dir
  dir="$(mktemp -d "$TMPDIR/fixture-collide.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q .
    git symbolic-ref HEAD refs/heads/master
    printf 'base\n' >base.txt
    git add base.txt
    git commit -q -m base
    git checkout -q -b feat/x
    printf 'branch-bytes\n' >user-notes.txt
    git add user-notes.txt
    git commit -q -m adds-user-notes
    git checkout -q master
    printf 'original-bytes\n' >user-notes.txt
  ) || return 1
  printf '%s\n' "$dir"
}

# ---- AC H cases --------------------------------------------------------------

# H1: tracked edit on main -> §4 block must halt (rc!=0), print a
# ship-choice halt line, leave the edit and HEAD untouched, and stage no
# squash. Red expected: old §4 has no is-clean gate at all.
h1() {
  local fx head_before edit_before block out rc
  fx="$(build_fixture)" || { fail_line "H1 setup"; return; }
  printf 'dirty-edit\n' >>"$fx/base.txt"
  head_before="$(git -C "$fx" rev-parse HEAD)"
  edit_before="$(cat "$fx/base.txt")"
  block="$(printf '%s\n' "$blocks4" | subst_block "$fx" "feat/x" "/tmp/card.json" "")"
  run_block "$fx" "$block"
  rc=$?
  out="$RUN_OUT"

  if [ "$rc" -ne 0 ]; then pass_line "H1: §4 exits !=0 on a tracked edit"; else fail_line "H1: §4 exits !=0 on a tracked edit (got rc=$rc)"; fi
  if printf '%s' "$out" | grep -qF 'ship-choice halt:'; then pass_line "H1: stdout has ship-choice halt:"; else fail_line "H1: stdout has ship-choice halt: (missing)"; fi
  if [ "$(cat "$fx/base.txt")" = "$edit_before" ]; then pass_line "H1: tracked edit intact"; else fail_line "H1: tracked edit intact (bytes changed)"; fi
  if [ "$(git -C "$fx" rev-parse HEAD)" = "$head_before" ]; then pass_line "H1: HEAD unchanged"; else fail_line "H1: HEAD unchanged (moved)"; fi
  if [ -z "$(git -C "$fx" status --porcelain=v1 -- feature.txt)" ] && [ ! -e "$fx/feature.txt" ]; then
    pass_line "H1: no squash staged"
  else
    fail_line "H1: no squash staged (feature.txt present/staged)"
  fi
}

# H2: untracked-only main -> §4 exits 0 and the squash is staged.
h2() {
  local fx block out rc
  fx="$(build_fixture)" || { fail_line "H2 setup"; return; }
  printf 'notes\n' >"$fx/user-notes.txt"
  block="$(printf '%s\n' "$blocks4" | subst_block "$fx" "feat/x" "/tmp/card.json" "")"
  run_block "$fx" "$block"
  rc=$?
  out="$RUN_OUT"

  if [ "$rc" -eq 0 ]; then pass_line "H2: §4 exits 0 on untracked-only main"; else fail_line "H2: §4 exits 0 on untracked-only main (rc=$rc: $out)"; fi
  if git -C "$fx" diff --cached --name-only | grep -qxF 'feature.txt'; then
    pass_line "H2: squash staged (feature.txt staged)"
  else
    fail_line "H2: squash staged (feature.txt not staged)"
  fi
  if [ -f "$fx/user-notes.txt" ]; then pass_line "H2: untracked file survives"; else fail_line "H2: untracked file survives"; fi
}

# H structural: is-clean --tracked-only appears, and appears before
# merge --squash, in the §4 block.
h_structural() {
  local ln_clean ln_squash
  ln_clean="$(printf '%s\n' "$blocks4" | grep -n -F 'is-clean --tracked-only' | head -1 | cut -d: -f1)"
  ln_squash="$(printf '%s\n' "$blocks4" | grep -n -F 'merge --squash' | head -1 | cut -d: -f1)"
  if [ -n "$ln_clean" ] && [ -n "$ln_squash" ] && [ "$ln_clean" -lt "$ln_squash" ]; then
    pass_line "structural: §4 runs is-clean --tracked-only before merge --squash"
  else
    fail_line "structural: §4 runs is-clean --tracked-only before merge --squash (clean_line=$ln_clean squash_line=$ln_squash)"
  fi
  if printf '%s\n' "$sec4_text" | grep -qF 'append-card.sh'; then
    pass_line "structural: §4 text names append-card.sh"
  else
    fail_line "structural: §4 text names append-card.sh"
  fi
}

# ---- AC I cases --------------------------------------------------------------

# I1: conflicting branch (same-line edit) -> §4 !=0, HEAD unchanged,
# tracked tree clean, untracked file survives.
i1() {
  local fx head_before block out rc
  fx="$(build_conflict_fixture)" || { fail_line "I1 setup"; return; }
  printf 'notes\n' >"$fx/user-notes.txt"
  head_before="$(git -C "$fx" rev-parse HEAD)"
  block="$(printf '%s\n' "$blocks4" | subst_block "$fx" "feat/x" "/tmp/card.json" "")"
  run_block "$fx" "$block"
  rc=$?
  out="$RUN_OUT"

  if [ "$rc" -ne 0 ]; then pass_line "I1: §4 exits !=0 on squash conflict"; else fail_line "I1: §4 exits !=0 on squash conflict (rc=$rc)"; fi
  if [ "$(git -C "$fx" rev-parse HEAD)" = "$head_before" ]; then pass_line "I1: HEAD unchanged"; else fail_line "I1: HEAD unchanged (moved)"; fi
  if [ -z "$(git -C "$fx" status --porcelain=v1 --untracked-files=no)" ]; then pass_line "I1: tracked tree clean"; else fail_line "I1: tracked tree clean"; fi
  if [ -f "$fx/user-notes.txt" ]; then pass_line "I1: untracked file survives"; else fail_line "I1: untracked file survives"; fi
}

# I2: after a good §4 stage + an untracked file + an unstaged version-file
# edit -> §6.5 block exits 0, tracked tree clean, untracked file survives,
# HEAD = SHIP_START_SHA. Depends on §6.5 having a block at all (it does
# not, pre-T6): guarded, reported as its own FAIL rather than run.
i2() {
  if [ -z "$blocks65" ]; then
    fail_line "I2: §6.5 has no fenced block to run (not runnable on current end-state.md)"
    return
  fi
  local fx ship_sha block out rc
  fx="$(build_fixture)" || { fail_line "I2 setup"; return; }
  ship_sha="$(git -C "$fx" rev-parse HEAD)"
  (cd "$fx" && git merge --squash feat/x >/dev/null 2>&1) || { fail_line "I2 setup: squash-stage did not succeed"; return; }
  printf 'notes\n' >"$fx/user-notes.txt"
  printf 'edited\n' >>"$fx/base.txt"
  block="$(printf '%s\n' "$blocks65" | subst_block "$fx" "feat/x" "/tmp/card.json" "$ship_sha")"
  run_block "$fx" "$block"
  rc=$?
  out="$RUN_OUT"

  if [ "$rc" -eq 0 ]; then pass_line "I2: §6.5 exits 0 restoring a good stage"; else fail_line "I2: §6.5 exits 0 restoring a good stage (rc=$rc: $out)"; fi
  if [ -z "$(git -C "$fx" status --porcelain=v1 --untracked-files=no)" ]; then pass_line "I2: tracked tree clean"; else fail_line "I2: tracked tree clean"; fi
  if [ -f "$fx/user-notes.txt" ]; then pass_line "I2: untracked file survives"; else fail_line "I2: untracked file survives"; fi
  if [ "$(git -C "$fx" rev-parse HEAD)" = "$ship_sha" ]; then pass_line "I2: HEAD == SHIP_START_SHA"; else fail_line "I2: HEAD == SHIP_START_SHA"; fi
}

# I3: after a commit on top -> §6.5 !=0, HEAD and the commit intact.
i3() {
  if [ -z "$blocks65" ]; then
    fail_line "I3: §6.5 has no fenced block to run (not runnable on current end-state.md)"
    return
  fi
  local fx ship_sha head_before block out rc
  fx="$(build_fixture)" || { fail_line "I3 setup"; return; }
  ship_sha="$(git -C "$fx" rev-parse HEAD)"
  (
    cd "$fx" || exit 1
    printf 'on-top\n' >ontop.txt
    git add ontop.txt
    git commit -q -m "delivery commit"
  )
  head_before="$(git -C "$fx" rev-parse HEAD)"
  block="$(printf '%s\n' "$blocks65" | subst_block "$fx" "feat/x" "/tmp/card.json" "$ship_sha")"
  run_block "$fx" "$block"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass_line "I3: §6.5 exits !=0 when HEAD moved past SHIP_START_SHA"; else fail_line "I3: §6.5 exits !=0 when HEAD moved past SHIP_START_SHA (rc=$rc)"; fi
  if [ "$(git -C "$fx" rev-parse HEAD)" = "$head_before" ]; then pass_line "I3: HEAD and delivery commit intact"; else fail_line "I3: HEAD and delivery commit intact"; fi
}

# I structural checks over the raw section text (not just the block body).
i_structural() {
  local combined n
  combined="$(printf '%s\n%s\n' "$sec4_text" "$sec65_text")"
  n="$(printf '%s\n' "$combined" | grep -cF 'reset --hard')"
  if [ "$n" -eq 0 ]; then pass_line "structural: zero 'reset --hard' across §4+§6.5 text"; else fail_line "structural: zero 'reset --hard' across §4+§6.5 text (found $n)"; fi

  if printf '%s\n' "$blocks4" | grep -qF 'safe-reset --clean-at'; then
    pass_line "structural: safe-reset --clean-at in §4 block"
  else
    fail_line "structural: safe-reset --clean-at in §4 block"
  fi
  if printf '%s\n' "$blocks65" | grep -qF 'safe-reset --clean-at'; then
    pass_line "structural: safe-reset --clean-at in §6.5 block"
  else
    fail_line "structural: safe-reset --clean-at in §6.5 block"
  fi

  n="$(printf '%s\n' "$sec65_text" | grep -cF 'run the §6.5 block')"
  if [ "$n" -ge 2 ]; then
    pass_line "structural: §6.5 prose names the block on both abort paths"
  else
    fail_line "structural: §6.5 prose names the block on both abort paths (found $n, need >=2)"
  fi
}

# ---- Step 6c security-council bite test --------------------------------------
# Premise under test (Design item 4): "merge --squash refuses to overwrite
# an untracked file". Not yet proven per the security-council finding.
# Fixture: main holds an untracked, non-ignored file at a path the squash
# would add. Assert the squash itself fails, and that after the §4
# recovery block the untracked file keeps its original bytes and HEAD is
# unchanged. This does not depend on the is-clean gate existing yet, so it
# can and should pass on df697cb — if it does not, that's a finding against
# Design 4, reported as such, not softened.
sc1_bite() {
  local fx head_before block out rc
  fx="$(build_untracked_collision_fixture)" || { fail_line "SC1 setup"; return; }
  head_before="$(git -C "$fx" rev-parse HEAD)"

  # Direct proof the premise holds, independent of the §4 wrapper.
  if (cd "$fx" && git merge --squash feat/x >/dev/null 2>&1); then
    fail_line "SC1: PREMISE FALSIFIED — git merge --squash did NOT refuse to overwrite the untracked file at a squash-added path (Design item 4 assumption is wrong)"
    (cd "$fx" && git reset --hard -q "$head_before" 2>/dev/null || true)
  else
    pass_line "SC1: git merge --squash refuses to overwrite an untracked file at a squash-added path"
  fi

  # Re-set the fixture and run it through the actual §4 block's recovery path.
  fx="$(build_untracked_collision_fixture)" || { fail_line "SC1 setup (2)"; return; }
  head_before="$(git -C "$fx" rev-parse HEAD)"
  block="$(printf '%s\n' "$blocks4" | subst_block "$fx" "feat/x" "/tmp/card.json" "")"
  run_block "$fx" "$block"
  rc=$?
  out="$RUN_OUT"
  if [ "$rc" -ne 0 ]; then pass_line "SC1: §4 block exits !=0 on the untracked-collision conflict"; else fail_line "SC1: §4 block exits !=0 on the untracked-collision conflict (rc=$rc: $out)"; fi
  if [ "$(cat "$fx/user-notes.txt" 2>/dev/null)" = "original-bytes" ]; then
    pass_line "SC1: untracked file keeps its original bytes after §4 recovery"
  else
    fail_line "SC1: untracked file keeps its original bytes after §4 recovery (got: $(cat "$fx/user-notes.txt" 2>/dev/null))"
  fi
  if [ "$(git -C "$fx" rev-parse HEAD)" = "$head_before" ]; then
    pass_line "SC1: HEAD unchanged after §4 recovery"
  else
    fail_line "SC1: HEAD unchanged after §4 recovery"
  fi
}

# ---- run ----------------------------------------------------------------

h_structural
[ -n "$blocks4" ] && { h1; h2; }
i_structural
[ -n "$blocks4" ] && i1
i2
i3
[ -n "$blocks4" ] && sc1_bite

echo "----"
echo "pass=$pass fail=$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
