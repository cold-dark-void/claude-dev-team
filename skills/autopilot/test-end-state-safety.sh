#!/usr/bin/env bash
# skills/autopilot/test-end-state-safety.sh — SPEC-025 wp-1-05-git-safety-lib
# AC H, AC I, and SPEC-033 wp-1-08-autopilot-state AC F. Extracts the fenced
# bash blocks under end-state.md's headings (tests/lib/fence.sh: fence_blocks/
# fence_nth for bash-fence bodies, md_section for section prose text) and runs
# them against fixture repos, without refactoring end-state.md into a script.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); every fixture repo
# lives under $TMPDIR. GIT_SAFETY/EPIC_LIB/CHECK_SHIP/SHIP_START resolution
# for the extracted blocks goes through CLAUDE_PLUGIN_ROOT=$ROOT
# (plugin-dir.sh Tier 0 force), which works from any cwd, including a
# fixture repo that is not the plugin checkout.
#
# END_STATE may be overridden by the caller to point at a different
# end-state.md (e.g. an older revision, for a bite-on-old-code run);
# defaults to the tip file in this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
END_STATE="${END_STATE:-$ROOT/skills/autopilot/end-state.md}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

pass=0
fail=0
pass_line() { echo "PASS: $1"; pass=$((pass + 1)); }
fail_line() { echo "FAIL: $1"; fail=$((fail + 1)); }

# md_section (tests/lib/fence.sh) extracts the raw section text (prose
# checks only — NOT bash-fence bodies; see fence_blocks below for those).
sec4_text="$(md_section "$END_STATE" "## 4. ")"
sec65_text="$(md_section "$END_STATE" "## 6.5 ")"
sec55_text="$(md_section "$END_STATE" "## 5.5 ")"
blocks4="$(fence_blocks "$END_STATE" "## 4. ")"
blocks65="$(fence_blocks "$END_STATE" "## 6.5 ")"

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

# subst_block <main-repo-path> <branch> <card-path> <ship-start-sha> [<autopilot-bump>]
# Reads a block on stdin, prints it substituted. <SHIP_START_SHA> is
# replaced ONLY on the line matching literal ^SHIP_START_SHA="<SHIP_START_SHA>"
# (the guard's comparison literal stays otherwise, or the guard trips).
# <autopilot-bump> is optional (blocks with no <AUTOPILOT_BUMP> placeholder
# ignore it); defaults to empty.
subst_block() {
  local mainpath="$1" branch="$2" cardpath="$3" sha="$4" bump="${5:-}"
  sed \
    -e "s|<main-repo-path>|$mainpath|g" \
    -e "s|<branch>|$branch|g" \
    -e "s|<card-path>|$cardpath|g" \
    -e "s|<AUTOPILOT_BUMP>|$bump|g" \
    -e "/^SHIP_START_SHA=\"<SHIP_START_SHA>\"/ s|<SHIP_START_SHA>|$sha|"
}

# run_block <fixture-dir> <substituted-block-text>
# Writes the block to a file under $TMPDIR and runs it with `bash <file>`
# directly at the top level — NOT wrapped in a function. AC F / C7 convert
# every halt path in these fences from `return` to `exit`; running a fence
# wrapped in a `run_block() { … }` function (as this suite did before WP
# 1-08) would let an old-code `return` behave like a real halt and mask
# exactly the CDT-311 defect C7 fixes (a top-level `return` in a script run
# via `bash file` prints a bash error and FALLS THROUGH to the next line
# instead of stopping). Running unwrapped is what makes the new F cases —
# and, retroactively, the H/I cases below — a real bite against pre-C7
# end-state.md. Aborts the whole suite (harness error, not a product FAIL)
# if any bracket placeholder survives substitution, except the §5.5/§6.5
# guard's own comparison literal (`!= "<SHIP_START_SHA>"`), which
# subst_block intentionally never rewrites (it only rewrites the
# `SHIP_START_SHA=` assignment line) — masked out before the check runs.
run_block() {
  local fx="$1" block="$2" outfile out rc check
  check="$(printf '%s\n' "$block" | sed 's/!= "<SHIP_START_SHA>"/!= "GUARD_LITERAL"/')"
  if printf '%s\n' "$check" | grep -qE '<(main-repo-path|branch|card-path|SHIP_START_SHA|AUTOPILOT_BUMP)>'; then
    echo "HARNESS ERROR: unsubstituted placeholder survived — aborting suite" >&2
    printf '%s\n' "$block" >&2
    exit 2
  fi
  outfile="$(mktemp "$TMPDIR/run-block.XXXXXX")"
  printf '%s\n' "$block" >"$outfile"
  local run_cmd=(bash "$outfile")
  if command -v timeout >/dev/null 2>&1; then
    run_cmd=(timeout 20 "${run_cmd[@]}")
  fi
  out=$(cd "$fx" && CLAUDE_PLUGIN_ROOT="$ROOT" PDH="$ROOT" "${run_cmd[@]}" 2>&1)
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

# build_bc3_fixture (AC F): a bare "origin" + a real clone checked out ON
# the default branch itself — the shape end-state.md actually runs in
# (squash-stage happens directly on the main-repo path, so LAND_TARGET ==
# DEFAULT_BRANCH, not a feature branch). Prints "<origin-dir> <main-dir>".
build_bc3_fixture() {
  local origin main
  origin="$(mktemp -d "$TMPDIR/bc3-origin.XXXXXX")" || return 1
  git init -q --bare "$origin" || return 1
  main="$(mktemp -d "$TMPDIR/bc3-main.XXXXXX")" || return 1
  (
    cd "$main" || exit 1
    git init -q .
    git symbolic-ref HEAD refs/heads/master
    printf 'base\n' >base.txt
    git add base.txt
    git commit -q -m base
    git remote add origin "$origin"
    git push -q origin master
    git fetch -q origin
    git remote set-head origin master
  ) || return 1
  printf '%s %s\n' "$origin" "$main"
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
# HEAD = SHIP_START_SHA.
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
sc1_bite() {
  local fx head_before block out rc
  fx="$(build_untracked_collision_fixture)" || { fail_line "SC1 setup"; return; }
  head_before="$(git -C "$fx" rev-parse HEAD)"

  if (cd "$fx" && git merge --squash feat/x >/dev/null 2>&1); then
    fail_line "SC1: PREMISE FALSIFIED — git merge --squash did NOT refuse to overwrite the untracked file at a squash-added path (Design item 4 assumption is wrong)"
    (cd "$fx" && git reset --hard -q "$head_before" 2>/dev/null || true)
  else
    pass_line "SC1: git merge --squash refuses to overwrite an untracked file at a squash-added path"
  fi

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

# ---- SPEC-033 wp-1-08-autopilot-state AC F cases -----------------------------

# F structural: no top-level return anywhere in end-state.md's bash fences
# (whole-file scan), and §3 fetches before it checks ancestry.
f_structural() {
  local ret ln_fetch ln_ancestor blocks3
  ret="$(fence_top_level_returns "$END_STATE")"
  if [ -z "$ret" ]; then
    pass_line "structural: no bash fence in end-state.md has a top-level return (AC F)"
  else
    fail_line "structural: no bash fence in end-state.md has a top-level return (AC F): $ret"
  fi

  blocks3="$(fence_blocks "$END_STATE" "## 3. ")"
  ln_fetch="$(printf '%s\n' "$blocks3" | grep -n -F 'fetch --no-tags origin' | head -1 | cut -d: -f1)"
  ln_ancestor="$(printf '%s\n' "$blocks3" | grep -n -F 'merge-base --is-ancestor' | head -1 | cut -d: -f1)"
  if [ -n "$ln_fetch" ] && [ -n "$ln_ancestor" ] && [ "$ln_fetch" -lt "$ln_ancestor" ]; then
    pass_line "structural: §3 fetches origin before the merge-base --is-ancestor check"
  else
    fail_line "structural: §3 fetches origin before the merge-base --is-ancestor check (fetch_line=$ln_fetch ancestor_line=$ln_ancestor)"
  fi
}

# F1: fetch fails (origin URL retargeted to a missing path) -> §3 exits
# non-zero, even though main is genuinely ahead (so without the fetch
# clause this fixture would otherwise pass BC3) — proves the fetch-failure
# clause itself, not just the ancestor check.
f1_fetch_fails() {
  local fx origin main block rc out
  fx="$(build_bc3_fixture)" || { fail_line "F1 setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  ( cd "$main" && printf 'ahead\n' >ahead.txt && git add ahead.txt && git commit -q -m ahead ) \
    || { fail_line "F1 setup: local commit"; return; }
  git -C "$main" remote set-url origin "$TMPDIR/no-such-origin-$$" \
    || { fail_line "F1 setup: remote set-url"; return; }
  block="$(fence_blocks "$END_STATE" "## 3. " | subst_block "$main" "" "/tmp/card.json" "")"
  run_block "$main" "$block"
  rc=$?; out="$RUN_OUT"
  if [ "$rc" -ne 0 ]; then
    pass_line "F1: §3 exits !=0 when the fetch fails"
  else
    fail_line "F1: §3 exits !=0 when the fetch fails (got rc=$rc: $out)"
  fi
}

# F2: origin ahead (a second clone pushes past main's cached view) -> §3
# exits non-zero AFTER the fetch updates the stale local ref (proves the
# fetch actually ran, not that a pre-existing stale cache happened to fail).
f2_origin_ahead() {
  local fx origin main second block rc out
  fx="$(build_bc3_fixture)" || { fail_line "F2 setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  second="$(mktemp -d "$TMPDIR/bc3-second.XXXXXX")" || { fail_line "F2 setup: mktemp"; return; }
  git clone -q "$origin" "$second" || { fail_line "F2 setup: clone"; return; }
  (
    cd "$second" || exit 1
    printf 'from-elsewhere\n' >elsewhere.txt
    git add elsewhere.txt
    git commit -q -m elsewhere
    git push -q origin master
  ) || { fail_line "F2 setup: push from second clone"; return; }
  block="$(fence_blocks "$END_STATE" "## 3. " | subst_block "$main" "" "/tmp/card.json" "")"
  run_block "$main" "$block"
  rc=$?; out="$RUN_OUT"
  if [ "$rc" -ne 0 ]; then
    pass_line "F2: §3 exits !=0 when origin is ahead after the fetch"
  else
    fail_line "F2: §3 exits !=0 when origin is ahead after the fetch (got rc=$rc: $out)"
  fi
}

# F3: local contains origin (the normal pre-land state) -> §3 exits 0.
f3_bc3_clear() {
  local fx origin main block rc out
  fx="$(build_bc3_fixture)" || { fail_line "F3 setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  ( cd "$main" && printf 'ahead\n' >ahead.txt && git add ahead.txt && git commit -q -m ahead ) \
    || { fail_line "F3 setup: local commit"; return; }
  block="$(fence_blocks "$END_STATE" "## 3. " | subst_block "$main" "" "/tmp/card.json" "")"
  run_block "$main" "$block"
  rc=$?; out="$RUN_OUT"
  if [ "$rc" -eq 0 ]; then
    pass_line "F3: §3 exits 0 when the land target contains origin"
  else
    fail_line "F3: §3 exits 0 when the land target contains origin (got rc=$rc: $out)"
  fi
}

# F4: §3.5 calls ship-start.sh (writing a tag snapshot) on the master bump,
# and does NOT on a release bump (that snapshot is /release Step 0.5's job).
f4_ship_start_on_master() {
  local fx origin main block rc out gitdir nsnap
  fx="$(build_bc3_fixture)" || { fail_line "F4 setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  block="$(fence_blocks "$END_STATE" "## 3.5 " | subst_block "$main" "" "/tmp/card.json" "" "master")"
  run_block "$main" "$block"
  rc=$?; out="$RUN_OUT"
  if [ "$rc" -eq 0 ]; then pass_line "F4: §3.5 exits 0 on the master bump"; else fail_line "F4: §3.5 exits 0 on the master bump (rc=$rc: $out)"; fi
  gitdir="$(git -C "$main" rev-parse --absolute-git-dir 2>/dev/null)"
  nsnap="$(find "$gitdir/dev-team-release" -maxdepth 1 -name 'tags-*.tsv' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${nsnap:-0}" -ge 1 ]; then
    pass_line "F4: §3.5 wrote a tag snapshot on the master bump"
  else
    fail_line "F4: §3.5 wrote a tag snapshot on the master bump (none found under $gitdir/dev-team-release)"
  fi
}

f4b_no_ship_start_on_release() {
  local fx origin main block rc out gitdir nsnap
  fx="$(build_bc3_fixture)" || { fail_line "F4b setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  block="$(fence_blocks "$END_STATE" "## 3.5 " | subst_block "$main" "" "/tmp/card.json" "" "patch")"
  run_block "$main" "$block"
  rc=$?; out="$RUN_OUT"
  if [ "$rc" -eq 0 ]; then pass_line "F4b: §3.5 exits 0 on a release bump"; else fail_line "F4b: §3.5 exits 0 on a release bump (rc=$rc: $out)"; fi
  gitdir="$(git -C "$main" rev-parse --absolute-git-dir 2>/dev/null)"
  nsnap="$(find "$gitdir/dev-team-release" -maxdepth 1 -name 'tags-*.tsv' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${nsnap:-0}" -eq 0 ]; then
    pass_line "F4b: §3.5 does not snapshot on a release bump (that is /release Step 0.5's job)"
  else
    fail_line "F4b: §3.5 does not snapshot on a release bump (found $nsnap)"
  fi
}

# F5: §5.5 land-no-release exits non-zero when the §3.5 snapshot is missing.
f5_missing_snapshot() {
  local fx origin main sha block rc out
  fx="$(build_bc3_fixture)" || { fail_line "F5 setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  sha="$(git -C "$main" rev-parse HEAD)"
  block="$(fence_blocks "$END_STATE" "## 5.5 " | subst_block "$main" "" "/tmp/card.json" "$sha" "master")"
  run_block "$main" "$block"
  rc=$?; out="$RUN_OUT"
  if [ "$rc" -ne 0 ]; then
    pass_line "F5: §5.5 land-no-release exits !=0 when the snapshot is missing"
  else
    fail_line "F5: §5.5 land-no-release exits !=0 when the snapshot is missing (rc=$rc: $out)"
  fi
  if printf '%s\n' "$out" | grep -qF 'snapshot missing'; then
    pass_line "F5: §5.5 names the missing snapshot"
  else
    fail_line "F5: §5.5 names the missing snapshot: $out"
  fi
}

# F6: §5.5 land-no-release passes --tag-snapshot, exits 0 when clean, and
# clears the snapshot afterward. F6b: the release path needs no snapshot
# at all (not its job) and still exits 0.
f6_structural() {
  local blocks55
  blocks55="$(fence_blocks "$END_STATE" "## 5.5 ")"
  if printf '%s\n' "$blocks55" | grep -qF -- '--tag-snapshot'; then
    pass_line "structural: §5.5 passes --tag-snapshot to check-ship-history.sh"
  else
    fail_line "structural: §5.5 passes --tag-snapshot to check-ship-history.sh"
  fi
}

f6_clean_clears() {
  local fx origin main sha block35 block55 rc gitdir before after
  fx="$(build_bc3_fixture)" || { fail_line "F6 setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  sha="$(git -C "$main" rev-parse HEAD)"
  block35="$(fence_blocks "$END_STATE" "## 3.5 " | subst_block "$main" "" "/tmp/card.json" "" "master")"
  run_block "$main" "$block35"
  rc=$?
  if [ "$rc" -ne 0 ]; then fail_line "F6 setup: §3.5 snapshot write failed (rc=$rc): $RUN_OUT"; return; fi
  gitdir="$(git -C "$main" rev-parse --absolute-git-dir 2>/dev/null)"
  before="$(find "$gitdir/dev-team-release" -maxdepth 1 -name 'tags-*.tsv' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${before:-0}" -lt 1 ]; then fail_line "F6 setup: no snapshot after §3.5"; return; fi

  block55="$(fence_blocks "$END_STATE" "## 5.5 " | subst_block "$main" "" "/tmp/card.json" "$sha" "master")"
  run_block "$main" "$block55"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass_line "F6: §5.5 land-no-release exits 0 on a clean, present snapshot"
  else
    fail_line "F6: §5.5 land-no-release exits 0 on a clean, present snapshot (rc=$rc: $RUN_OUT)"
  fi
  after="$(find "$gitdir/dev-team-release" -maxdepth 1 -name 'tags-*.tsv' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${after:-1}" -eq 0 ]; then
    pass_line "F6: §5.5 clears the snapshot after a clean check"
  else
    fail_line "F6: §5.5 clears the snapshot after a clean check (still $after present)"
  fi
}

f6b_release_needs_no_snapshot() {
  local fx origin main sha block rc
  fx="$(build_bc3_fixture)" || { fail_line "F6b setup"; return; }
  origin="${fx%% *}"; main="${fx##* }"
  sha="$(git -C "$main" rev-parse HEAD)"
  block="$(fence_blocks "$END_STATE" "## 5.5 " | subst_block "$main" "" "/tmp/card.json" "$sha" "patch")"
  run_block "$main" "$block"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass_line "F6b: §5.5 release path exits 0 with no snapshot on disk (not its job)"
  else
    fail_line "F6b: §5.5 release path exits 0 with no snapshot on disk (rc=$rc: $RUN_OUT)"
  fi
}

# F7: §5.5 text names /release Step 6 as the ship-history authority on the
# release path.
f7_release_authority_text() {
  if printf '%s\n' "$sec55_text" | grep -qF '/release` Step 5.5 and Step 6'; then
    pass_line "structural: §5.5 text names /release Step 6 as the ship-history authority on the release path"
  else
    fail_line "structural: §5.5 text names /release Step 6 as the ship-history authority on the release path"
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
f_structural
f1_fetch_fails
f2_origin_ahead
f3_bc3_clear
f4_ship_start_on_master
f4b_no_ship_start_on_release
f5_missing_snapshot
f6_structural
f6_clean_clears
f6b_release_needs_no_snapshot
f7_release_authority_text

echo "----"
echo "pass=$pass fail=$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
