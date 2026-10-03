#!/usr/bin/env bash
# skills/wrap-ticket/wrap-ticket-test.sh — bite-tests for WP 1-06 AC A and AC B
# (SPEC-016 "### wp-1-06-branch-deletion-safety", SPEC-009 Wrap-Ticket).
#
# Machine-check: bash skills/wrap-ticket/wrap-ticket-test.sh  (exit 0)
# Extracts real fenced bash blocks out of SKILL.md by heading (extract_fence)
# and runs them as a fresh `bash` process against fixture repos/dirs — it
# does not refactor SKILL.md into a script. Hermetic: private TMPDIR/HOME
# (tests/lib/hermetic.sh); every fixture lives under $TMPDIR.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
RESOLVE_WT="$HERE/resolve-worktree.sh"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name" "want='$want' got='$got'"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"
  else fail "$name" "missing [$needle] in [$hay]"
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$name" "unexpected [$needle] in [$hay]"
  else pass "$name"
  fi
}

assert_file_match() {
  local name="$1" file="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then pass "$name"
  else fail "$name" "pattern /$pat/ not in $file"
  fi
}

assert_file_nomatch() {
  local name="$1" file="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then fail "$name" "pattern /$pat/ unexpectedly in $file"
  else pass "$name"
  fi
}

# ---- fence extraction (C3 harness contract; one heading-parameterized fn) --

# extract_fence "<exact heading text after '## '>" <n> — nth ```bash block
# under that EXACT heading (stops at the next "## " line). Exact match, not
# prefix: "Step 6" must not also grab "Step 6.x" or "Step 6.5" content
# (same anchoring discipline WP 1-06 requires of the product code).
extract_fence() {
  local heading="$1" n="$2"
  EF_HEADING="$heading" EF_N="$n" awk '
    BEGIN {
      heading = ENVIRON["EF_HEADING"]; want = ENVIRON["EF_N"] + 0
      insec = 0; cnt = 0; inblk = 0; infence = 0; isbash = 0
    }
    /^```/ {
      if (!infence) {
        infence = 1
        isbash = ($0 == "```bash") ? 1 : 0
        if (insec && isbash) { inblk = 1; cnt++ }
      } else {
        infence = 0
        inblk = 0
      }
      next
    }
    !infence && /^## / {
      line = substr($0, 4)
      insec = (line == heading) ? 1 : 0
      next
    }
    insec && inblk && cnt == want { print }
  ' "$SKILL"
}

# ---- git fixtures (mirrors skills/lib/git-safety-test.sh conventions) -----

TMP="$TMPDIR"

new_repo() {
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q && git symbolic-ref HEAD refs/heads/master ) >/dev/null 2>&1
}

commit_all() {
  local d="$1" msg="$2"
  ( cd "$d" && git add -A && git commit -q -m "$msg" ) >/dev/null 2>&1
}

# add_ticket_branch <dir> <ticket> <mode: unmerged|ff|squash>
# Leaves master checked out; adds a worktree at "<dir>-wt-<ticket>".
add_ticket_branch() {
  local dir="$1" ticket="$2" mode="$3"
  case "$mode" in
    unmerged)
      ( cd "$dir" && git checkout -q -b "feat/$ticket" ) >/dev/null 2>&1
      printf 'x-%s\n' "$ticket" >> "$dir/base.txt"; commit_all "$dir" "unique-$ticket"
      ( cd "$dir" && git checkout -q master ) >/dev/null 2>&1
      ;;
    ff)
      ( cd "$dir" && git checkout -q -b "feat/$ticket" ) >/dev/null 2>&1
      printf 'x-%s\n' "$ticket" >> "$dir/base.txt"; commit_all "$dir" "feature-$ticket"
      ( cd "$dir" && git checkout -q master && git merge -q --ff-only "feat/$ticket" ) >/dev/null 2>&1
      ;;
    squash)
      ( cd "$dir" && git checkout -q -b "feat/$ticket" ) >/dev/null 2>&1
      printf 'x-%s\n' "$ticket" >> "$dir/base.txt"; commit_all "$dir" "feature-$ticket c1"
      printf 'y-%s\n' "$ticket" >> "$dir/base.txt"; commit_all "$dir" "feature-$ticket c2"
      ( cd "$dir" && git checkout -q master ) >/dev/null 2>&1
      ( cd "$dir" && git merge --squash "feat/$ticket" -q ) >/dev/null 2>&1
      commit_all "$dir" "squash-$ticket"
      ;;
  esac
  git -C "$dir" worktree add -q "${dir}-wt-${ticket}" "feat/$ticket" >/dev/null 2>&1
}

build_repo() {
  local dir
  dir=$(mktemp -d "$TMP/repo.XXXXXX")
  new_repo "$dir"
  printf 'base\n' > "$dir/base.txt"
  commit_all "$dir" base
  printf '%s\n' "$dir"
}

branch_exists() { git -C "$1" show-ref --verify --quiet -- "refs/heads/$2"; }

# ---- fence execution (mirrors skills/autopilot/test-end-state-safety.sh) --

# run_fence <cwd> <block-text> [path-prefix]
# Substitutes nothing (caller does). Runs the block as a fresh `bash`
# process, CLAUDE_PLUGIN_ROOT=$ROOT (plugin-dir.sh Tier 0 force — works from
# any cwd, including a fixture repo that is not the plugin checkout).
run_fence() {
  local cwd="$1" block="$2" pathprefix="${3-}" outfile out rc
  outfile=$(mktemp "$TMP/fence.XXXXXX")
  printf '%s\n' "$block" > "$outfile"
  local run_cmd=(bash "$outfile")
  if command -v timeout >/dev/null 2>&1; then
    run_cmd=(timeout 20 "${run_cmd[@]}")
  fi
  if [ -n "$pathprefix" ]; then
    out=$(cd "$cwd" && CLAUDE_PLUGIN_ROOT="$ROOT" PDH="$ROOT" PATH="$pathprefix:$PATH" "${run_cmd[@]}" 2>&1)
  else
    out=$(cd "$cwd" && CLAUDE_PLUGIN_ROOT="$ROOT" PDH="$ROOT" "${run_cmd[@]}" 2>&1)
  fi
  rc=$?
  rm -f "$outfile"
  RUN_OUT="$out"
  return $rc
}

subst_ticket() { # subst_ticket <block> <ticket-id>
  printf '%s' "${1//<TICKET-ID>/$2}"
}

# git-call-logging PATH shim (C7): wraps the REAL git so a test can assert
# "zero worktree remove / branch calls" instead of inferring it indirectly.
make_git_shim() {
  local bindir="$1" logfile="$2" real_git
  real_git=$(command -v git)
  mkdir -p "$bindir"
  : > "$logfile"
  cat > "$bindir/git" <<SHIMEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$logfile"
exec "$real_git" "\$@"
SHIMEOF
  chmod +x "$bindir/git"
}

echo "== structural: extract_fence finds every fence it should =========="
n_step2=$(extract_fence "Step 2: Collect learnings from agent context files" 1 | grep -c .)
n_step3w=$(extract_fence "Step 3: Append learnings to project memory" 3 | grep -c .)
n_step6exec=$(extract_fence "Step 6: Remove the worktree" 3 | grep -c .)
[ "$n_step2" -gt 0 ] && pass "extract_fence: Step 2 fence #1 non-empty" || fail "extract_fence: Step 2 fence #1 non-empty" "empty"
[ "$n_step3w" -gt 0 ] && pass "extract_fence: Step 3 fence #3 (write) non-empty" || fail "extract_fence: Step 3 fence #3 (write) non-empty" "empty"
[ "$n_step6exec" -gt 0 ] && pass "extract_fence: Step 6 fence #3 (execution) non-empty" || fail "extract_fence: Step 6 fence #3 (execution) non-empty" "empty"

echo "== AC A static: literal TICKET_ID, no C1 waivers, step order ======"

# Each fence that uses $TICKET_ID sets it literally (SPEC-009). Structural:
# the literal assignment appears at least once per fence heading that uses it.
for h in "Step 0: Resolve roots" "Step 2: Collect learnings from agent context files" \
         "Step 4: Update plans index" "Step 5.5: Source tracking close-out (idempotent)" \
         "Step 6: Remove the worktree" "Step 6.x: Prune remote feat branches" \
         "Step 6.5: CI-watch cleanup"; do
  txt=""
  i=1
  while :; do
    blk=$(extract_fence "$h" "$i")
    [ -n "$blk" ] || break
    txt="${txt}${blk}"$'\n'
    i=$((i + 1))
  done
  if printf '%s' "$txt" | grep -qF '$TICKET_ID'; then
    assert_contains "AC A(2): $h sets TICKET_ID literally" "$txt" 'TICKET_ID="<TICKET-ID>"'
  fi
done

# No `# lint-ok: C1` waiver sits on (or directly above) a line that uses
# $TICKET_ID — the one deliberately-kept exception is $SIDECAR_PATH (CRON_ID
# fence, backlog item CDT-278), which does not use $TICKET_ID.
bad=$(awk '
  { lines[NR] = $0 }
  END {
    for (n = 1; n <= NR; n++) {
      hit = 0
      if (lines[n] ~ /\$TICKET_ID/) {
        if (lines[n] ~ /lint-ok:[^\n]*C1/) { hit = 1 }
        else if (n > 1 && lines[n-1] ~ /lint-ok:[^\n]*C1/) { hit = 1 }
      }
      if (hit) { print n": "lines[n] }
    }
  }
' "$SKILL")
assert_eq "AC A(2): no lint-ok: C1 waiver on a \$TICKET_ID line" "" "$bad"

# check-skill-bash.sh (SPEC-021) reports no unwaived finding at all, and no
# C1 finding at all — the Step 6.5 CRON_ID fence re-resolves $SIDECAR_PATH
# in its own block instead of carrying a cross-block C1 waiver (spec gap
# A(2): SPEC-016 AC A(2) says the linter "reports no C1", not "no unwaived
# C1").
LINT_OUT=$(bash "$ROOT/skills/skill-lint/check-skill-bash.sh" --json "$SKILL" 2>&1)
LINT_RC=$?
assert_eq "AC A(2): check-skill-bash.sh exits 0 (no unwaived findings)" "0" "$LINT_RC"
c1_count=$(printf '%s' "$LINT_OUT" | grep -o '"check": "C1"' | grep -c .)
assert_eq "AC A(2): zero C1 findings (waived or not)" "0" "$c1_count"

# Step 5 comes before Step 5.5 (moved section).
step5_line=$(grep -n '^## Step 5: ' "$SKILL" | head -1 | cut -d: -f1)
step55_line=$(grep -n '^## Step 5\.5: ' "$SKILL" | head -1 | cut -d: -f1)
if [ -n "$step5_line" ] && [ -n "$step55_line" ] && [ "$step5_line" -lt "$step55_line" ]; then
  pass "AC A(3): ## Step 5: precedes ## Step 5.5:"
else
  fail "AC A(3): ## Step 5: precedes ## Step 5.5:" "step5=$step5_line step5.5=$step55_line"
fi

echo "== AC A(4): learnings payload never sits in a double-quoted literal ="

# F21 payload: $(touch x), a backtick `touch y`, and a ". A double-quoted
# CONTENT="..." assignment would execute the first two and mis-parse the
# third; the quoted heredoc (LEARNINGS_EOF) must keep all three inert.
PLACEHOLDER='<the new learnings section only (## <TICKET-ID> learnings …) — NOT the full re-read>'
PAYLOAD='## CDT-1 learnings (2026-09-28)

- injected: $(touch x), `touch y`, and a " character.'

write_block=$(extract_fence "Step 3: Append learnings to project memory" 3)
write_block="${write_block//$PLACEHOLDER/$PAYLOAD}"

# sqlite path: memory.db pre-seeded from the real schema (skills/memory-store).
fx_sql=$(mktemp -d "$TMP/f21-sql.XXXXXX")
mkdir -p "$fx_sql/.claude/memory"
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$fx_sql/.claude/memory/memory.db" < "$ROOT/skills/memory-store/schema.sql" >/dev/null
  run_fence "$fx_sql" "$write_block"
  rc_sql=$?
  assert_eq "AC A(4) sqlite: write fence exits 0" "0" "$rc_sql"
  [ -e "$fx_sql/x" ] && fail "AC A(4) sqlite: no x created" "x exists" || pass "AC A(4) sqlite: no x created"
  [ -e "$fx_sql/y" ] && fail "AC A(4) sqlite: no y created" "y exists" || pass "AC A(4) sqlite: no y created"
  got_sql=$(sqlite3 "$fx_sql/.claude/memory/memory.db" "SELECT content FROM memories WHERE agent='claude' AND type='memory' ORDER BY id DESC LIMIT 1;")
  assert_eq "AC A(4) sqlite: stored content is byte-equal to payload" "$PAYLOAD" "$got_sql"
else
  echo "  SKIP AC A(4) sqlite cases — sqlite3 not on PATH"
fi

# .md fallback path: no memory.db present.
fx_md=$(mktemp -d "$TMP/f21-md.XXXXXX")
run_fence "$fx_md" "$write_block"
rc_md=$?
assert_eq "AC A(4) .md: write fence exits 0" "0" "$rc_md"
[ -e "$fx_md/x" ] && fail "AC A(4) .md: no x created" "x exists" || pass "AC A(4) .md: no x created"
[ -e "$fx_md/y" ] && fail "AC A(4) .md: no y created" "y exists" || pass "AC A(4) .md: no y created"
got_md=$(cat "$fx_md/.claude/memory/claude/memory.md" 2>/dev/null)
assert_eq "AC A(4) .md: stored content is byte-equal to payload" "$PAYLOAD" "$got_md"

echo "== AC A(1): Step 2 reads the ticket worktree, not \$MROOT ==========="

step2_block=$(extract_fence "Step 2: Collect learnings from agent context files" 1)

# context.md: MROOT and the ticket worktree hold different text.
fx=$(mktemp -d "$TMP/step2-a.XXXXXX")
mkdir -p "$fx/.worktrees/CDT-1/.claude/memory/ic5" "$fx/.claude/memory/ic5"
printf 'WORKTREE-CONTEXT-TEXT\n' > "$fx/.worktrees/CDT-1/.claude/memory/ic5/context.md"
printf 'MROOT-CONTEXT-TEXT\n' > "$fx/.claude/memory/ic5/context.md"
blk=$(subst_ticket "$step2_block" "CDT-1")
run_fence "$fx" "$blk"
assert_contains "AC A(1): Step 2 prints the worktree context.md" "$RUN_OUT" "WORKTREE-CONTEXT-TEXT"
assert_not_contains "AC A(1): Step 2 does not print the MROOT context.md" "$RUN_OUT" "MROOT-CONTEXT-TEXT"

# Plan lookup: worktree plan name first, then MROOT plan name.
fx=$(mktemp -d "$TMP/step2-b.XXXXXX")
mkdir -p "$fx/.worktrees/CDT-1/.claude/plans" "$fx/.claude/plans"
: > "$fx/.worktrees/CDT-1/.claude/plans/2026-01-01-CDT-1-wtplan.md"
: > "$fx/.claude/plans/2026-01-02-CDT-1-mrootplan.md"
: > "$fx/.claude/plans/2026-01-03-CDT-10-decoy.md"
blk=$(subst_ticket "$step2_block" "CDT-1")
run_fence "$fx" "$blk"
assert_contains "AC A(1): plan lookup finds the worktree plan name" "$RUN_OUT" "2026-01-01-CDT-1-wtplan.md"
assert_contains "AC A(1): plan lookup finds the MROOT plan name" "$RUN_OUT" "2026-01-02-CDT-1-mrootplan.md"
assert_not_contains "AC A(1): plan lookup is anchored — CDT-1 does not match CDT-10" "$RUN_OUT" "2026-01-03-CDT-10-decoy.md"
wt_idx=$(printf '%s\n' "$RUN_OUT" | grep -n "2026-01-01-CDT-1-wtplan.md" | head -1 | cut -d: -f1)
mr_idx=$(printf '%s\n' "$RUN_OUT" | grep -n "2026-01-02-CDT-1-mrootplan.md" | head -1 | cut -d: -f1)
if [ -n "$wt_idx" ] && [ -n "$mr_idx" ] && [ "$wt_idx" -lt "$mr_idx" ]; then
  pass "AC A(1): worktree plan name printed before the MROOT plan name"
else
  fail "AC A(1): worktree plan name printed before the MROOT plan name" "wt=$wt_idx mroot=$mr_idx"
fi

# Worktree gone: no .worktrees/<ID>, no legacy match -> warning + read MROOT.
fx=$(mktemp -d "$TMP/step2-c.XXXXXX")
mkdir -p "$fx/.claude/memory/ic5"
printf 'MROOT-FALLBACK-TEXT\n' > "$fx/.claude/memory/ic5/context.md"
blk=$(subst_ticket "$step2_block" "CDT-9")
run_fence "$fx" "$blk"
assert_contains "AC A(1): worktree-gone warning printed" "$RUN_OUT" "warning: ticket worktree not found"
assert_contains "AC A(1): worktree-gone falls back to MROOT content" "$RUN_OUT" "MROOT-FALLBACK-TEXT"

echo "== AC B static: no :-{}}, cd \"\$MROOT\", no git branch -D ==========="

# Planted negative control (hazard checklist): prove each nomatch regex
# below actually fires on content that has the bad pattern, not just that
# it happens to find nothing. (Also verified empirically: all three FAILed
# when this suite ran against the pre-WP-1-06 SKILL.md — see the RED/GREEN
# bite-test proof in the T3 report.)
neg_fixture=$(mktemp "$TMP/negctl.XXXXXX.md")
cat > "$neg_fixture" <<'NEGEOF'
SKIP_RELEASE=$(jq -r '.skip_release // false' <<<"${CHILD_WT:-{}}")
cd $MROOT
git branch -D "feat/$TICKET_ID" 2>/dev/null || true
NEGEOF
assert_file_match "negative control: :-{}} regex fires on planted bad line" "$neg_fixture" ':-\{\}\}'
assert_file_match "negative control: unquoted cd \$MROOT regex fires on planted bad line" "$neg_fixture" '^cd \$MROOT$'
assert_file_match "negative control: git branch -D regex fires on planted bad line" "$neg_fixture" 'branch -D "feat/\$TICKET_ID"'

assert_file_nomatch "AC B(1): SKILL.md has no :-{}}" "$SKILL" ':-\{\}\}'
assert_file_match "AC B(6): SKILL.md has a quoted cd \"\$MROOT\"" "$SKILL" 'cd "\$MROOT"'
assert_file_nomatch "AC B(6): SKILL.md has no unquoted cd \$MROOT" "$SKILL" '^cd \$MROOT$'
assert_file_nomatch "AC B(5): SKILL.md has no git branch -D \"feat/\$TICKET_ID\"" "$SKILL" 'branch -D "feat/\$TICKET_ID"'

# AC B(1): the DEF='{}' / ${CHILD_WT:-$DEF} pattern is present at every
# CHILD_WT default site (Step 0, Step 6, Step 6.x) — grep count is a
# regression fence: old code had 3 sites using the bare ${CHILD_WT:-{}}}
# form instead (asserted absent above).
def_sites=$(grep -cF '<<<"${CHILD_WT:-$DEF}"' "$SKILL")
if [ "$def_sites" -ge 3 ]; then
  pass "AC B(1): DEF='{}' pattern present at >=3 CHILD_WT default sites (got $def_sites)"
else
  fail "AC B(1): DEF='{}' pattern present at >=3 CHILD_WT default sites" "got $def_sites"
fi

# Behavioral: the exact extracted line form gives exit 0 + empty stderr for
# a populated CHILD_WT and for an empty one (jq never sees a bare "{}" with
# no quoting hazard, and the unset case falls back to DEF cleanly).
jq_line_ok() { # jq_line_ok <label> <CHILD_WT value>
  local label="$1" val="$2" err rc
  err=$(DEF='{}'; CHILD_WT="$val"; jq -r '.skip_release // false' <<<"${CHILD_WT:-$DEF}" 2>&1 1>/dev/null)
  rc=$?
  assert_eq "AC B(1): jq line exit 0 — $label" "0" "$rc"
  assert_eq "AC B(1): jq line empty stderr — $label" "" "$err"
}
jq_line_ok "populated CHILD_WT" '{"skip_release":false,"use_shared":false}'
jq_line_ok "empty CHILD_WT" ""

echo "== L3: yesno prompt covers both branch:none and merged cases ======="

assert_file_match "L3: SKILL.md has a branch:none yesno prompt variant" "$SKILL" 'No feat/<TICKET-ID> branch exists'
assert_file_match "L3: SKILL.md still has the merged yesno prompt variant" "$SKILL" 'is merged into <base> and'

echo "== AC B(2) static: Step 0/2/6 call the helper; old grep is gone ===="

for h in "Step 0: Resolve roots" "Step 2: Collect learnings from agent context files" \
         "Step 6: Remove the worktree"; do
  txt=""
  i=1
  while :; do
    blk=$(extract_fence "$h" "$i")
    [ -n "$blk" ] || break
    txt="${txt}${blk}"$'\n'
    i=$((i + 1))
  done
  assert_contains "AC B(2): $h calls resolve-worktree.sh" "$txt" "skills/wrap-ticket/resolve-worktree.sh"
done
assert_file_nomatch "AC B(2): SKILL.md has no git worktree list (matcher fully extracted)" "$SKILL" 'git worktree list'

echo "== AC B(2): resolve-worktree.sh — exact match, no CDT-1/CDT-1-2 mix ="

fx=$(mktemp -d "$TMP/rw-a.XXXXXX")
new_repo "$fx"
printf 'base\n' > "$fx/base.txt"; commit_all "$fx" base
git -C "$fx" branch feat/CDT-1 >/dev/null 2>&1
git -C "$fx" branch feat/CDT-1-2 >/dev/null 2>&1
git -C "$fx" worktree add -q "$fx-wt-CDT-1" feat/CDT-1 >/dev/null 2>&1
git -C "$fx" worktree add -q "$fx-wt-CDT-1-2" feat/CDT-1-2 >/dev/null 2>&1

got1=$(cd "$fx" && bash "$RESOLVE_WT" CDT-1)
assert_eq "AC B(2): resolve-worktree.sh CDT-1 -> only the CDT-1 path" "${fx}-wt-CDT-1" "$got1"
got2=$(cd "$fx" && bash "$RESOLVE_WT" CDT-1-2)
assert_eq "AC B(2): resolve-worktree.sh CDT-1-2 -> only the CDT-1-2 path" "${fx}-wt-CDT-1-2" "$got2"

# .worktrees/<ID> (order 2) wins over a legacy match (order 3) for the SAME id.
fx=$(mktemp -d "$TMP/rw-b.XXXXXX")
new_repo "$fx"
printf 'base\n' > "$fx/base.txt"; commit_all "$fx" base
mkdir -p "$fx/.worktrees"
git -C "$fx" worktree add -q "$fx/.worktrees/CDT-2" -b feat/CDT-2 >/dev/null 2>&1
git -C "$fx" branch feat/CDT-2-legacy-decoy >/dev/null 2>&1
got3=$(cd "$fx" && bash "$RESOLVE_WT" CDT-2)
assert_eq "AC B(2): .worktrees/<ID> preferred over a legacy match" "$fx/.worktrees/CDT-2" "$got3"

# No match -> empty stdout, exit 0.
fx=$(mktemp -d "$TMP/rw-c.XXXXXX")
new_repo "$fx"
printf 'base\n' > "$fx/base.txt"; commit_all "$fx" base
got4=$(cd "$fx" && bash "$RESOLVE_WT" CDT-404)
rc4=$?
assert_eq "AC B(2): no match -> empty stdout" "" "$got4"
assert_eq "AC B(2): no match -> exit 0" "0" "$rc4"

echo "== L4: resolve-worktree.sh never matches the main worktree itself ==="

# $MROOT's own basename ends with "-CDT-9" — the suffix rule would match it
# unless the first (main) porcelain record is skipped.
fx_parent=$(mktemp -d "$TMP/rw-main.XXXXXX")
fx="$fx_parent/proj-CDT-9"
new_repo "$fx"
printf 'base\n' > "$fx/base.txt"; commit_all "$fx" base
got_main=$(cd "$fx" && bash "$RESOLVE_WT" CDT-9)
assert_eq "L4: main worktree basename ending -<ID> is never matched" "" "$got_main"

# A genuine sibling worktree with the same suffix is still found.
git -C "$fx" branch feat/CDT-9 >/dev/null 2>&1
git -C "$fx" worktree add -q "$fx_parent/other-CDT-9" feat/CDT-9 >/dev/null 2>&1
got_sibling=$(cd "$fx" && bash "$RESOLVE_WT" CDT-9)
assert_eq "L4: a real sibling worktree with the same suffix is still found" "$fx_parent/other-CDT-9" "$got_sibling"

echo "== AC B: resolve-worktree.sh usage/validation ======================"

bash "$RESOLVE_WT" >/dev/null 2>&1
assert_eq "AC B: no args -> exit 64" "64" "$?"
bash "$RESOLVE_WT" "bad id" >/dev/null 2>&1
assert_eq "AC B: invalid id (space) -> exit 64" "64" "$?"
bash "$RESOLVE_WT" "a/b" >/dev/null 2>&1
assert_eq "AC B: invalid id (slash) -> exit 64" "64" "$?"
bash "$RESOLVE_WT" "" >/dev/null 2>&1
assert_eq "AC B: empty id -> exit 64" "64" "$?"

echo "== AC B: resolve-worktree.sh order 1 — epic shared wins ============"

# Stub plugin root: real resolve-worktree.sh copied next to a stub
# epic-lib.sh (fixed use_shared JSON) — proves order 1 beats order 2/3 without
# building real epic state.
stub=$(mktemp -d "$TMP/rw-stub.XXXXXX")
mkdir -p "$stub/skills/wrap-ticket" "$stub/skills/epic"
cp "$RESOLVE_WT" "$stub/skills/wrap-ticket/resolve-worktree.sh"
chmod +x "$stub/skills/wrap-ticket/resolve-worktree.sh"
cat > "$stub/skills/epic/epic-lib.sh" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "resolve-child-worktree" ]; then
  printf '{"use_shared":true,"integration_path":"%s"}\n' "${STUB_INT_PATH:-}"
  exit 0
fi
exit 1
STUBEOF
chmod +x "$stub/skills/epic/epic-lib.sh"

fx=$(mktemp -d "$TMP/rw-shared.XXXXXX")
new_repo "$fx"
printf 'base\n' > "$fx/base.txt"; commit_all "$fx" base
mkdir -p "$fx/.worktrees/CDT-3" "$stub/shared-integration"   # decoy at order 2
got5=$(cd "$fx" && STUB_INT_PATH="$stub/shared-integration" bash "$stub/skills/wrap-ticket/resolve-worktree.sh" CDT-3)
assert_eq "AC B: epic-shared integration path wins over .worktrees/<ID>" "$stub/shared-integration" "$got5"

echo "== AC B(4): Step 6 legacy fence — empty lookup skips, zero git calls ="

step6_block=$(extract_fence "Step 6: Remove the worktree" 3)

fx=$(mktemp -d "$TMP/step6-empty.XXXXXX")
new_repo "$fx"
printf 'base\n' > "$fx/base.txt"; commit_all "$fx" base
bindir=$(mktemp -d "$TMP/gitshim-empty.XXXXXX")
logfile="$TMP/gitshim-empty.log"
make_git_shim "$bindir" "$logfile"
blk=$(subst_ticket "$step6_block" "CDT-404")
run_fence "$fx" "$blk" "$bindir"
rc=$?
assert_eq "AC B(4): empty lookup -> exit 0" "0" "$rc"
assert_contains "AC B(4): empty lookup -> skip message" "$RUN_OUT" "No legacy worktree for CDT-404 — skipping"
bad_calls=$(grep -cE '^worktree remove |^branch ' "$logfile" 2>/dev/null || true)
assert_eq "AC B(4): empty lookup -> zero git worktree remove/branch calls" "0" "${bad_calls:-0}"

echo "== AC B(5): Step 6 legacy fence — merge status decides the branch ==="

# Unmerged: worktree gone, branch kept, message names it.
fx=$(build_repo)
add_ticket_branch "$fx" "CDT-1" unmerged
blk=$(subst_ticket "$step6_block" "CDT-1")
run_fence "$fx" "$blk"
assert_eq "AC B(5) unmerged: fence exits 0" "0" "$?"
[ -d "${fx}-wt-CDT-1" ] && fail "AC B(5) unmerged: worktree removed" "still present" || pass "AC B(5) unmerged: worktree removed"
if branch_exists "$fx" "feat/CDT-1"; then pass "AC B(5) unmerged: branch kept"; else fail "AC B(5) unmerged: branch kept" "branch gone"; fi
assert_contains "AC B(5) unmerged: message names feat/CDT-1" "$RUN_OUT" "Kept feat/CDT-1"
assert_contains "AC B(5) unmerged: message says not merged" "$RUN_OUT" "not merged into"

# Fast-forward merged: worktree and branch both gone.
fx=$(build_repo)
add_ticket_branch "$fx" "CDT-1" ff
blk=$(subst_ticket "$step6_block" "CDT-1")
run_fence "$fx" "$blk"
assert_eq "AC B(5) ff: fence exits 0" "0" "$?"
[ -d "${fx}-wt-CDT-1" ] && fail "AC B(5) ff: worktree removed" "still present" || pass "AC B(5) ff: worktree removed"
if branch_exists "$fx" "feat/CDT-1"; then fail "AC B(5) ff: branch deleted" "branch still present"; else pass "AC B(5) ff: branch deleted"; fi

# Squash merged: worktree and branch both gone.
fx=$(build_repo)
add_ticket_branch "$fx" "CDT-1" squash
blk=$(subst_ticket "$step6_block" "CDT-1")
run_fence "$fx" "$blk"
assert_eq "AC B(5) squash: fence exits 0" "0" "$?"
[ -d "${fx}-wt-CDT-1" ] && fail "AC B(5) squash: worktree removed" "still present" || pass "AC B(5) squash: worktree removed"
if branch_exists "$fx" "feat/CDT-1"; then fail "AC B(5) squash: branch deleted" "branch still present"; else pass "AC B(5) squash: branch deleted"; fi

echo "== M2: Step 6 legacy fence — failed git worktree remove keeps everything ="

# Locked legacy worktree: git worktree remove fails (rc 128, "cannot remove a
# locked working tree"), even though the branch IS merged (so the old bug —
# running safe-delete-branch anyway and printing a false "not merged" line —
# would have fired here). Zero git branch calls proves the fix short-circuits
# before ever reaching the branch step.
fx=$(build_repo)
add_ticket_branch "$fx" "CDT-1" ff
git -C "$fx" worktree lock "${fx}-wt-CDT-1" >/dev/null 2>&1
bindir=$(mktemp -d "$TMP/gitshim-m2.XXXXXX")
logfile="$TMP/gitshim-m2.log"
make_git_shim "$bindir" "$logfile"
blk=$(subst_ticket "$step6_block" "CDT-1")
run_fence "$fx" "$blk" "$bindir"
assert_eq "M2: locked legacy tree — fence exits 0" "0" "$?"
assert_contains "M2: locked legacy tree — 'not forcing' message" "$RUN_OUT" \
  "worktree remove failed for ${fx}-wt-CDT-1 — not forcing; kept feat/CDT-1"
assert_not_contains "M2: locked legacy tree — no misleading 'not merged' message" "$RUN_OUT" "not merged into"
[ -d "${fx}-wt-CDT-1" ] && pass "M2: locked legacy tree — worktree dir survives" || fail "M2: locked legacy tree — worktree dir survives" "removed"
if branch_exists "$fx" "feat/CDT-1"; then pass "M2: locked legacy tree — branch survives"; else fail "M2: locked legacy tree — branch survives" "branch gone"; fi
branch_calls=$(grep -cE '^branch ' "$logfile" 2>/dev/null || true)
assert_eq "M2: locked legacy tree — zero git branch calls" "0" "${branch_calls:-0}"

# Same guard, dirty-tree variant (untracked/modified files, no lock).
fx=$(build_repo)
add_ticket_branch "$fx" "CDT-1" ff
printf 'dirty\n' >> "${fx}-wt-CDT-1/base.txt"
bindir=$(mktemp -d "$TMP/gitshim-m2-dirty.XXXXXX")
logfile="$TMP/gitshim-m2-dirty.log"
make_git_shim "$bindir" "$logfile"
blk=$(subst_ticket "$step6_block" "CDT-1")
run_fence "$fx" "$blk" "$bindir"
assert_eq "M2: dirty legacy tree — fence exits 0" "0" "$?"
assert_contains "M2: dirty legacy tree — 'not forcing' message" "$RUN_OUT" \
  "worktree remove failed for ${fx}-wt-CDT-1 — not forcing; kept feat/CDT-1"
assert_not_contains "M2: dirty legacy tree — no misleading 'not merged' message" "$RUN_OUT" "not merged into"
[ -d "${fx}-wt-CDT-1" ] && pass "M2: dirty legacy tree — worktree dir survives" || fail "M2: dirty legacy tree — worktree dir survives" "removed"
if branch_exists "$fx" "feat/CDT-1"; then pass "M2: dirty legacy tree — branch survives"; else fail "M2: dirty legacy tree — branch survives" "branch gone"; fi
branch_calls=$(grep -cE '^branch ' "$logfile" 2>/dev/null || true)
assert_eq "M2: dirty legacy tree — zero git branch calls" "0" "${branch_calls:-0}"

echo "== AC B(3): Step 6 legacy fence for CDT-1 leaves CDT-1-2 untouched =="

fx=$(build_repo)
add_ticket_branch "$fx" "CDT-1" ff
add_ticket_branch "$fx" "CDT-1-2" ff
blk=$(subst_ticket "$step6_block" "CDT-1")
run_fence "$fx" "$blk"
[ -d "${fx}-wt-CDT-1" ] && fail "AC B(3): CDT-1 worktree removed" "still present" || pass "AC B(3): CDT-1 worktree removed"
[ -d "${fx}-wt-CDT-1-2" ] && pass "AC B(3): CDT-1-2 worktree untouched" || fail "AC B(3): CDT-1-2 worktree untouched" "removed"
if branch_exists "$fx" "feat/CDT-1-2"; then pass "AC B(3): CDT-1-2 branch untouched"; else fail "AC B(3): CDT-1-2 branch untouched" "branch gone"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
