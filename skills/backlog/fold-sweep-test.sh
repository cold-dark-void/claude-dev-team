#!/usr/bin/env bash
# skills/backlog/fold-sweep-test.sh — deterministic subprocess tests for fold-sweep.sh.
# Offline: no network, no LLM, no MCP. Each case drives fold-sweep.sh against a fresh
# ${TMPDIR:-/tmp} git fixture (the Linear close is a stub script recording its argv).
# smoke parses it with `bash -n`; the all-suites runner runs it (SPEC-030).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SWEEP="$HERE/fold-sweep.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_CEILING_DIRECTORIES="$HERMETIC_ROOT"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then pass "$3"
  else fail "$3" "missing [$1] in: $2"
  fi
}

assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then fail "$3" "unexpectedly contains [$1]"
  else pass "$3"
  fi
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1" "want='$2' got='$3'"
  fi
}

FIX="$TMPDIR/fold-sweep-fixtures"
mkdir -p "$FIX"

# make_repo — hermetic git repo with two backlog items and one pushed fold commit
# naming test-slug-a (open, linear_id), test-slug-b (already closed) and a ghost
# slug with no local item.
make_repo() {
  local d="$FIX/repo-$1"
  mkdir -p "$d/.claude/backlog"
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name "test"

  cat >"$d/.claude/backlog/test-slug-a.md" <<'EOF'
---
linear_id: CDT-900
---

# A

**Status**: PENDING
EOF
  cat >"$d/.claude/backlog/test-slug-b.md" <<'EOF'
# B

**Status**: COMPLETED

---

*Closed: 2026-10-01*
EOF
  cat >"$d/.claude/backlog.md" <<'EOF'
# F - Backlog Index

## Pending

- [A](backlog/test-slug-a.md) - A [PENDING] linear:CDT-900

## Completed

- [B](backlog/test-slug-b.md) - B [COMPLETED]
EOF
  cat >"$d/CHANGELOG.md" <<'EOF'
# Changelog

### v9.9.9
- **Test lead (test-slug-a, test-slug-b, ghost-slug)** — fixture fold entry
EOF
  git -C "$d" add .claude CHANGELOG.md
  git -C "$d" commit -q -m "fix: v9.9.9 — Test lead (test-slug-a, test-slug-b, ghost-slug)"
  printf '%s\n' "$d"
}

# linear_stub PATH — write a stub close command that records each argv to .calls.
linear_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$(dirname "$0")/linear-calls.log"
EOF
}

# ============ the ticket's core fixture: two tickets, one already closed =====

REPO=$(make_repo core)
STUB="$FIX/linear-stub.sh"
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
SHA=$(git -C "$REPO" rev-parse HEAD)

RC=0
OUT=$(cd "$REPO" && bash "$SWEEP" --commit HEAD --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "core sweep exits 0" 0 "$RC"
assert_contains "flipped=1 already-closed=1 linear=1 skipped=1" "$OUT" \
  "flipped=1 already-closed=1 linear=1 skipped=1"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO/.claude/backlog/test-slug-a.md")" "open item flipped with version status line"
assert_contains "*Closed: $(date +%Y-%m-%d) v9.9.9 $SHA*" \
  "$(cat "$REPO/.claude/backlog/test-slug-a.md")" "open item carries version+commit footer"
assert_eq "already-closed item untouched" \
  "$(printf '# B\n\n**Status**: COMPLETED\n\n---\n\n*Closed: 2026-10-01*')" \
  "$(cat "$REPO/.claude/backlog/test-slug-b.md")"
assert_eq "exactly one Linear close issued (stubbed)" "CDT-900" "$(cat "$FIX/linear-calls.log")"
assert_eq "ghost slug with no local item skipped silently" "" \
  "$(ls "$REPO/.claude/backlog/ghost-slug.md" 2>/dev/null || true)"

# ============ idempotent re-run: zero writes, no second Linear call ==========

RC=0
OUT=$(cd "$REPO" && bash "$SWEEP" --commit HEAD --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "re-run exits 0" 0 "$RC"
assert_contains "flipped=0 already-closed=2 linear=0" "$OUT" "re-run flips nothing"
assert_eq "no second Linear close issued" "CDT-900" "$(cat "$FIX/linear-calls.log")"

# ============ no --linear-close-cmd: session bridge line, local write stands =

REPO2=$(make_repo bridge)
RC=0
OUT=$(cd "$REPO2" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "bridge-mode sweep exits 0" 0 "$RC"
assert_contains "linear-close: CDT-900" "$OUT" "bridge mode prints linear-close for the session (MCP)"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO2/.claude/backlog/test-slug-a.md")" "bridge mode still flips the local file"

# Item without linear_id: silent skip of the Linear step.
printf '%s\n' "# C" "" "**Status**: PENDING" >"$REPO2/.claude/backlog/slug-no-lid.md"
cat >>"$REPO2/CHANGELOG.md" <<'EOF'

### v9.9.10
- **Extra lead (test-slug-a, slug-no-lid)** — second fixture fold entry
EOF
git -C "$REPO2" add CHANGELOG.md .claude/backlog/slug-no-lid.md
git -C "$REPO2" commit -q -m "fix: v9.9.10 — Extra lead (test-slug-a, slug-no-lid)"
RC=0
OUT=$(cd "$REPO2" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "no-linear-id sweep exits 0" 0 "$RC"
assert_contains "**Status**: COMPLETED (v9.9.10)" \
  "$(cat "$REPO2/.claude/backlog/slug-no-lid.md")" "no-linear-id item flipped"
assert_not_contains "linear-close" "$OUT" "no linear_id → no bridge line"

# ============ --find-fold: locate the fold from master history ===============

REPO3=$(make_repo findfold)
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
RC=0
OUT=$(cd "$REPO3" && bash "$SWEEP" --find-fold test-slug-a --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "find-fold sweep exits 0" 0 "$RC"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO3/.claude/backlog/test-slug-a.md")" "find-fold flips the named ticket"
assert_eq "find-fold issues the stubbed Linear close" "CDT-900" "$(cat "$FIX/linear-calls.log")"

# Token absent from every fold subject: calm one-line skip, exit 0.
RC=0
OUT=$(cd "$REPO3" && bash "$SWEEP" --find-fold no-such-ticket 2>&1) || RC=$?
assert_eq "find-fold miss exits 0" 0 "$RC"
assert_contains "nothing to sweep" "$OUT" "find-fold miss is a calm skip"

# ============ B1(a): subject-only multi-slug fold — every slug survives =====

# Comma list split with no CHANGELOG parens to lean on: pre-fix, IFS word-split
# kept trailing commas and only the LAST subject slug survived valid_slug.
REPO6="$FIX/repo-subject-only"
mkdir -p "$REPO6/.claude/backlog"
git -C "$REPO6" init -q -b master
git -C "$REPO6" config user.email "test@example.invalid"
git -C "$REPO6" config user.name "test"
cat >"$REPO6/.claude/backlog/test-slug-a.md" <<'EOF'
---
linear_id: CDT-900
---

# A

**Status**: PENDING
EOF
cat >"$REPO6/.claude/backlog/test-slug-b.md" <<'EOF'
---
linear_id: CDT-901
---

# B

**Status**: PENDING
EOF
cat >"$REPO6/CHANGELOG.md" <<'EOF'
# Changelog

### v9.9.9
- **Plain lead** — no slug list in the entry body
EOF
git -C "$REPO6" add .claude CHANGELOG.md
git -C "$REPO6" commit -q -m "fix: v9.9.9 — Plain lead (test-slug-a, test-slug-b)"
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
RC=0
OUT=$(cd "$REPO6" && bash "$SWEEP" --commit HEAD --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "subject-only sweep exits 0" 0 "$RC"
assert_contains "flipped=2 already-closed=0 linear=2 skipped=0" "$OUT" \
  "subject-only fold flips every listed slug"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO6/.claude/backlog/test-slug-a.md")" "subject-only: first slug flipped"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO6/.claude/backlog/test-slug-b.md")" "subject-only: middle slug flipped"
assert_eq "subject-only: both Linear closes issued" "$(printf 'CDT-900\nCDT-901')" \
  "$(cat "$FIX/linear-calls.log")"

# ============ B1(b): junk detail parens stay inert ==========================

# A v1.27.0-shaped section whose DETAIL carries a role list — a whole-body scan
# would harvest `task` and flip a PENDING item named task.md. Lead-only must not.
REPO7="$FIX/repo-junk-parens"
mkdir -p "$REPO7/.claude/backlog"
git -C "$REPO7" init -q -b master
git -C "$REPO7" config user.email "test@example.invalid"
git -C "$REPO7" config user.name "test"
cat >"$REPO7/.claude/backlog/task.md" <<'EOF'
# Task

**Status**: PENDING
EOF
cat >"$REPO7/CHANGELOG.md" <<'EOF'
# Changelog

### v1.27.0
- **omp host support: kickoff handoff is print-only (cdt-547-kickoff-handoff-lines-read-as-orders-by-no, cdt-549-debugger-agent-shadows-omp-built-in-debugg, cdt-551-doctor-detect-omp-and-check-claude-plugins)** — the verified omp v18.7.0 bundled-agent set (`reviewer, scout, security-reviewer, sonic, task`) has zero overlap with the 13-agent roster; doctor gains omp.enabled_providers.
EOF
git -C "$REPO7" add .claude CHANGELOG.md
git -C "$REPO7" commit -q -m "fix: v1.27.0 — omp host support: kickoff handoff is print-only (cdt-547-kickoff-handoff-lines-read-as-orders-by-no, cdt-549-debugger-agent-shadows-omp-built-in-debugg, cdt-551-doctor-detect-omp-and-check-claude-plugins)"
RC=0
OUT=$(cd "$REPO7" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "junk-paren sweep exits 0" 0 "$RC"
assert_eq "junk-paren detail: task.md stays PENDING" "**Status**: PENDING" \
  "$(grep -F '**Status**' "$REPO7/.claude/backlog/task.md")"
assert_contains "flipped=0 already-closed=0 linear=0" "$OUT" \
  "junk-paren detail flips nothing"

# ============ C7: non-top fold section — no SIGPIPE death (exit 141) =========

# /release Step 6.5 runs the sweep for a shipped fold whose `### v<VER>` section
# sits BELOW a later section (the real CHANGELOG is ~390 KB). Pre-fix,
# changelog_section's awk `exit`ed at the section end, the printf writer died on
# SIGPIPE, `set -o pipefail` gave the pipeline status 141, and `set -e` killed the
# sweep: no summary, no backlog closes, no Linear closes. The death needs a later
# heading plus >64 KB of text after it (the pipe buffer), so the filler below the
# fold section is what makes it reproduce in a fixture.
# The subject names only test-slug-a; test-slug-b/ghost-slug come from the section
# lead, so the flips prove the section body was extracted and its slug list swept.
REPO9="$FIX/repo-non-top"
mkdir -p "$REPO9/.claude/backlog"
git -C "$REPO9" init -q -b master
git -C "$REPO9" config user.email "test@example.invalid"
git -C "$REPO9" config user.name "test"
cat >"$REPO9/.claude/backlog/test-slug-a.md" <<'EOF'
---
linear_id: CDT-900
---

# A

**Status**: PENDING
EOF
cat >"$REPO9/.claude/backlog/test-slug-b.md" <<'EOF'
---
linear_id: CDT-901
---

# B

**Status**: PENDING
EOF
cat >"$REPO9/.claude/backlog/newer-slug.md" <<'EOF'
---
linear_id: CDT-903
---

# Newer

**Status**: PENDING
EOF
{
  printf '%s\n' "# Changelog" "" \
    "### v9.9.10" "- **Newer lead (newer-slug)** — a later release, not the fold under test" "" \
    "### v9.9.9" "- **Test lead (test-slug-a, test-slug-b, ghost-slug)** — fixture fold entry" "" \
    "### v9.9.8"
  for i in $(seq 1 8000); do printf -- '- filler %s\n' "$i"; done
} >"$REPO9/CHANGELOG.md"
git -C "$REPO9" add .claude CHANGELOG.md
git -C "$REPO9" commit -q -m "fix: v9.9.9 — Test lead (test-slug-a)"
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
RC=0
OUT=$(cd "$REPO9" && bash "$SWEEP" --commit HEAD --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "non-top fold sweep exits 0 (no SIGPIPE 141)" 0 "$RC"
assert_contains "flipped=2 already-closed=0 linear=2 skipped=1" "$OUT" \
  "non-top fold: the sweep prints its summary"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO9/.claude/backlog/test-slug-a.md")" "non-top fold: subject slug flipped"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO9/.claude/backlog/test-slug-b.md")" \
  "non-top fold: changelog-lead slug flipped (section body extracted)"
assert_eq "non-top fold: newer-section slug stays out of scope" "**Status**: PENDING" \
  "$(grep -F '**Status**' "$REPO9/.claude/backlog/newer-slug.md")"
assert_eq "non-top fold: both Linear closes issued" "$(printf 'CDT-900\nCDT-901')" \
  "$(cat "$FIX/linear-calls.log")"

# Same repo, the fold whose version is the newest section. Pre-fix this died the
# same way (the section is still followed by a later heading); the extraction
# bytes and the stdout contract are unchanged.
git -C "$REPO9" commit -q --allow-empty -m "fix: v9.9.10 — Newer lead (newer-slug)"
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
RC=0
OUT=$(cd "$REPO9" && bash "$SWEEP" --commit HEAD --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "newest-section fold sweep exits 0" 0 "$RC"
assert_contains "flipped=1 already-closed=0 linear=1 skipped=0" "$OUT" \
  "newest-section fold: summary unchanged"
assert_contains "**Status**: COMPLETED (v9.9.10)" \
  "$(cat "$REPO9/.claude/backlog/newer-slug.md")" "newest-section fold: slug flipped"

# Subject with NO slug list, CHANGELOG lead with one: only the section harvest can
# supply the candidate, so this pins changelog_lead_list's capture group (the
# lead pattern once used a literal `(...)` with `\1`, GNU sed died on
# "invalid reference \1", and the entry contributed nothing).
REPO12="$FIX/repo-lead-only"
mkdir -p "$REPO12/.claude/backlog"
git -C "$REPO12" init -q -b master
git -C "$REPO12" config user.email "test@example.invalid"
git -C "$REPO12" config user.name "test"
printf -- '---\nlinear_id: CDT-904\n---\n\n# A\n\n**Status**: PENDING\n' \
  >"$REPO12/.claude/backlog/test-slug-a.md"
{
  printf '%s\n' "# Changelog" "" "### v9.9.9" \
    "- **Test lead (test-slug-a)** — fixture fold entry" "" "### v9.9.8"
  for i in $(seq 1 8000); do printf -- '- filler %s\n' "$i"; done
} >"$REPO12/CHANGELOG.md"
git -C "$REPO12" add .claude CHANGELOG.md
git -C "$REPO12" commit -q -m "fix: v9.9.9 — Plain lead with no parens"
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
RC=0
OUT=$(cd "$REPO12" && bash "$SWEEP" --commit HEAD --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "lead-only fold sweep exits 0" 0 "$RC"
assert_contains "flipped=1 already-closed=0 linear=1 skipped=0" "$OUT" \
  "lead-only fold: the CHANGELOG lead supplies the slug list"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO12/.claude/backlog/test-slug-a.md")" "lead-only fold: slug flipped"
assert_eq "lead-only fold: the Linear close is issued" "CDT-904" \
  "$(cat "$FIX/linear-calls.log")"

# ============ C7: version absent from CHANGELOG / section is empty ==========

# Both keep the calm path: no section body means no lead list, so the subject's
# own slug list stands, and a subject with no slug list is a calm skip, exit 0.
REPO10="$FIX/repo-absent-version"
mkdir -p "$REPO10"
git -C "$REPO10" init -q -b master
git -C "$REPO10" config user.email "test@example.invalid"
git -C "$REPO10" config user.name "test"
{
  printf '%s\n' "# Changelog" "" "### v9.9.10" "- **Newer lead (newer-slug)** — fixture" ""
  for i in $(seq 1 8000); do printf -- '- filler %s\n' "$i"; done
} >"$REPO10/CHANGELOG.md"
git -C "$REPO10" add CHANGELOG.md
git -C "$REPO10" commit -q -m "fix: v9.9.9 — Plain lead"
RC=0
OUT=$(cd "$REPO10" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "absent-version slugless fold exits 0" 0 "$RC"
assert_contains "carries no slug list" "$OUT" "absent-version fold is a calm skip"

REPO11="$FIX/repo-empty-section"
mkdir -p "$REPO11/.claude/backlog"
git -C "$REPO11" init -q -b master
git -C "$REPO11" config user.email "test@example.invalid"
git -C "$REPO11" config user.name "test"
printf -- '---\nlinear_id: CDT-900\n---\n\n# A\n\n**Status**: PENDING\n' \
  >"$REPO11/.claude/backlog/test-slug-a.md"
{
  printf '%s\n' "# Changelog" "" "### v9.9.9" "" "### v9.9.8"
  for i in $(seq 1 8000); do printf -- '- filler %s\n' "$i"; done
} >"$REPO11/CHANGELOG.md"
git -C "$REPO11" add .claude CHANGELOG.md
git -C "$REPO11" commit -q -m "fix: v9.9.9 — Empty lead (test-slug-a)"
RC=0
OUT=$(cd "$REPO11" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "empty-section fold exits 0" 0 "$RC"
assert_contains "flipped=1 already-closed=0 linear=1 skipped=0" "$OUT" \
  "empty section: the subject slug list still sweeps"

# ============ B2: --find-fold prefix match (CDT-900 → cdt-900-some-title) ====

REPO8="$FIX/repo-findfold-prefix"
mkdir -p "$REPO8/.claude/backlog"
git -C "$REPO8" init -q -b master
git -C "$REPO8" config user.email "test@example.invalid"
git -C "$REPO8" config user.name "test"
cat >"$REPO8/.claude/backlog/cdt-900-some-title.md" <<'EOF'
---
linear_id: CDT-902
---

# Child

**Status**: PENDING
EOF
cat >"$REPO8/CHANGELOG.md" <<'EOF'
# Changelog

### v9.9.9
- **Lead (cdt-900-some-title)** — fixture
EOF
git -C "$REPO8" add .claude CHANGELOG.md
git -C "$REPO8" commit -q -m "fix: v9.9.9 — Lead (cdt-900-some-title)"
linear_stub "$STUB"
rm -f "$FIX/linear-calls.log"
# Prefix must not over-match: CDT-9000 never matches cdt-900-some-title.
# (Run BEFORE the positive sweep below — a flip is a one-way write.)
RC=0
OUT=$(cd "$REPO8" && bash "$SWEEP" --find-fold CDT-9000 2>&1) || RC=$?
assert_eq "find-fold CDT-9000 exits 0" 0 "$RC"
assert_contains "nothing to sweep" "$OUT" "find-fold CDT-9000 is a calm skip"
assert_eq "CDT-9000 matched nothing" "**Status**: PENDING" \
  "$(grep -F '**Status**' "$REPO8/.claude/backlog/cdt-900-some-title.md")"

RC=0
OUT=$(cd "$REPO8" && bash "$SWEEP" --find-fold CDT-900 --linear-close-cmd "$STUB" 2>&1) || RC=$?
assert_eq "find-fold prefix match exits 0" 0 "$RC"
assert_contains "**Status**: COMPLETED (v9.9.9)" \
  "$(cat "$REPO8/.claude/backlog/cdt-900-some-title.md")" \
  "find-fold CDT-900 flips cdt-900-some-title (prefix, case-insensitive)"
assert_eq "find-fold prefix match issues the Linear close" "CDT-902" \
  "$(cat "$FIX/linear-calls.log")"

# ============ calm skips: no slug list, not a repo, bad commit ===============

REPO4="$FIX/repo-noslugs"
mkdir -p "$REPO4"
git -C "$REPO4" init -q -b master
git -C "$REPO4" config user.email "test@example.invalid"
git -C "$REPO4" config user.name "test"
printf '%s\n' "# Changelog" "" "### v9.9.9" "- **Plain lead** — no slugs named" >"$REPO4/CHANGELOG.md"
git -C "$REPO4" add CHANGELOG.md
git -C "$REPO4" commit -q -m "fix: v9.9.9 — Plain lead"
RC=0
OUT=$(cd "$REPO4" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "slugless fold exits 0" 0 "$RC"
assert_contains "carries no slug list" "$OUT" "slugless fold is a calm skip"

NOT_GIT="$FIX/notgit"
mkdir -p "$NOT_GIT"
RC=0
OUT=$(cd "$NOT_GIT" && bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "not-a-repo exits 0 (non-fatal posture)" 0 "$RC"
assert_contains "not a git repo" "$OUT" "not-a-repo is a calm skip"

RC=0
OUT=$(cd "$REPO4" && bash "$SWEEP" --commit deadbeef 2>&1) || RC=$?
assert_eq "unknown commit errors" 1 "$RC"

RC=0
OUT=$(bash "$SWEEP" 2>&1) || RC=$?
assert_eq "missing mode is usage" 64 "$RC"

# ============ close failure is logged, never fatal ==========================

REPO5=$(make_repo failpath)
# Item file whose Status cannot be rewritten: hold a FRESH shared backlog lock
# (lock.sh layout: <root>/.claude/backlog.lock/stamp = "<epoch> <ISO> <owner>")
# with a 1s wait budget, so close.sh exits 1 and the sweep must log + exit 0.
mkdir "$REPO5/.claude/backlog.lock"
printf '%s %s %s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "test-holder" \
  >"$REPO5/.claude/backlog.lock/stamp"
RC=0
OUT=$(cd "$REPO5" && BACKLOG_LOCK_WAIT_SECONDS=1 bash "$SWEEP" --commit HEAD 2>&1) || RC=$?
assert_eq "locked store: sweep still exits 0" 0 "$RC"
assert_contains "close failed for test-slug-a" "$OUT" "locked store: close failure logged"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
