#!/usr/bin/env bash
# Static ACs for council tiering grading (CDT-126, SPEC-013 "Council tiering").
# Exercises the rules layer only — never the middle-band triage call, which is an LLM.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TG="$ROOT/skills/council/tier-grade.sh"
FIX="$ROOT/skills/council/fixtures/tier-grade"
fail=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tier-grade-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; NOTREPO="$TMP/notrepo"; BADREPO="$TMP/badrepo"
mkdir -p "$REPO" "$NOTREPO" "$BADREPO"

# ---- Scratch repo: content the content-dependent signals need -----------------
git init -q "$REPO"
git init -q "$BADREPO"
mkdir -p "$REPO/lib" "$REPO/src" "$REPO/docs" "$REPO/tools"
printf 'package lib\n' > "$REPO/lib/hub.go"
for i in 1 2 3 4 5 6; do printf 'import "lib/hub.go"\n' > "$REPO/src/ref0$i.go"; done
printf -- '---\nname: policy\nstatus: ACTIVE\n---\n\nbody\n' > "$REPO/docs/policy.md"
printf '#!/bin/sh\necho hi\n' > "$REPO/tools/runner"
chmod 644 "$REPO/tools/runner"
# Committed, then deleted from the working tree below, so the blob-SHA branch is the
# only way to reach their post-image.
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/tools/staged-hook"
chmod 644 "$REPO/tools/staged-hook"
printf -- '---\nstatus: DRAFT\n---\n\nbody\n' > "$REPO/docs/staged-policy.md"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init

# ---- Helpers -----------------------------------------------------------------
OUT=""; RC=0
grade() {  # grade <cwd> <numstat-fixture> [raw-fixture]
  local cwd="$1" n="$FIX/$2" r="${3:-}"
  if [ -n "$r" ]; then
    OUT="$(cd "$cwd" && bash "$TG" --numstat "$n" --raw "$FIX/$r" 2>/dev/null)"
  else
    OUT="$(cd "$cwd" && bash "$TG" --numstat "$n" 2>/dev/null)"
  fi
  RC=$?
}

expect() {  # expect <label> <jq-filter>
  if printf '%s' "$OUT" | jq -e "$2" >/dev/null 2>&1; then
    echo "OK: $1"
  else
    echo "FAIL: $1"; echo "     got: $OUT"; fail=1
  fi
}

expect_rc0() {  # every graded run emits JSON and exits 0
  if [ "$RC" -eq 0 ]; then echo "OK: $1 exit 0"; else echo "FAIL: $1 exit $RC (want 0)"; fail=1; fi
}

# ---- Bands -------------------------------------------------------------------
grade "$REPO" clear-low.numstat
expect_rc0 "clear-low"
expect "clear-low -> light" '.tier=="light" and .band=="clear-low" and .files==3 and .loc==42
                             and (.critical_signals|length)==0 and .fanin_probed==true'

grade "$REPO" clear-high-files.numstat
expect "clear-high files>20 -> full" '.tier=="full" and .band=="clear-high" and .files==25
                                      and (.grading_reason|test("files=25>20"))'

grade "$REPO" clear-high-loc.numstat
expect "clear-high loc>600 -> full" '.tier=="full" and .band=="clear-high" and .loc==700
                                     and (.grading_reason|test("loc=700>600"))'

grade "$REPO" middle.numstat
expect "ambiguous middle -> middle" '.tier=="middle" and .band=="middle" and .files==8 and .loc==250
                                     and .fanin_probed==true and (.critical_signals|length)==0
                                     and (.grading_reason|test("triage call required"))'

# ---- Signal 1 — spec / contract file ----------------------------------------
grade "$REPO" sig1-specs-path.numstat
expect "signal 1 (specs/ segment) -> full" '.tier=="full" and .band=="clear-high"
  and (.critical_signals|map(select(.signal==1 and .file=="specs/core/example.md"))|length)==1
  and (.critical_signals[0].why|test("specs/ segment"))'

grade "$REPO" sig1-spec-basename.numstat
expect "signal 1 (SPEC-*.md basename) -> full" '.tier=="full"
  and (.critical_signals|map(select(.signal==1))|length)==1
  and (.critical_signals[0].why|test("basename matches"))'

grade "$REPO" sig1-frontmatter.numstat
expect "signal 1 (status: frontmatter) -> full" '.tier=="full"
  and (.critical_signals|map(select(.signal==1 and .file=="docs/policy.md"))|length)==1
  and (.critical_signals[0].why|test("status:"))'

# ---- Signal 2 — executable ---------------------------------------------------
grade "$REPO" sig2-mode.numstat sig2-mode.raw
expect "signal 2 (raw dst mode 100755) -> full" '.tier=="full"
  and (.critical_signals|map(select(.signal==2 and .file=="tools/deploy"))|length)==1
  and (.critical_signals[0].why|test("100755"))'

grade "$REPO" sig2-shebang.numstat
expect "signal 2 (post-image #!) -> full" '.tier=="full"
  and (.critical_signals|map(select(.signal==2 and .file=="tools/runner"))|length)==1
  and (.critical_signals[0].why|test("begins with"))'

# ---- Post-image resolution via the --raw blob SHA ----------------------------
# The blob-SHA branch is the reason --raw exists: for staged and ref-range diffs the
# working tree is NOT the post-image. Both checked-in .raw fixtures carry all-zero dst
# SHAs (the realistic unstaged shape), so they only ever exercise the working-tree
# fallback. Build a raw carrying real blob SHAs and delete the working-tree copies, so
# these assertions can pass ONLY through `git cat-file`.
hook_sha="$(git -C "$REPO" rev-parse HEAD:tools/staged-hook)"
policy_sha="$(git -C "$REPO" rev-parse HEAD:docs/staged-policy.md)"
printf '5\t2\ttools/staged-hook\n4\t1\tdocs/staged-policy.md\n' > "$TMP/blob.numstat"
printf ':100644 100644 0000000 %s M\ttools/staged-hook\n:100644 100644 0000000 %s M\tdocs/staged-policy.md\n' \
  "$hook_sha" "$policy_sha" > "$TMP/blob.raw"
rm -f "$REPO/tools/staged-hook" "$REPO/docs/staged-policy.md"

OUT="$(cd "$REPO" && bash "$TG" --numstat "$TMP/blob.numstat" --raw "$TMP/blob.raw" 2>/dev/null)"; RC=$?
expect_rc0 "post-image via blob SHA"
expect "post-image resolves from the --raw blob SHA, not the working tree" '.tier=="full"
  and (.critical_signals|map(select(.signal==2 and .file=="tools/staged-hook"))|length)==1
  and (.critical_signals|map(select(.signal==1 and .file=="docs/staged-policy.md"))|length)==1'

# Negative control: same numstat, no --raw. With the working-tree copies gone there is no
# post-image at all, so neither content-half signal can fire — which is what proves the
# assertion above came from the blob branch and not from a leftover file on disk.
OUT="$(cd "$REPO" && bash "$TG" --numstat "$TMP/blob.numstat" 2>/dev/null)"; RC=$?
expect "same numstat without --raw finds no post-image" \
  '.band=="clear-low" and .tier=="light" and (.critical_signals|length)==0'

# ---- Signal 3 — high fan-in (clear-low and middle bands) ---------------------
grade "$REPO" sig3-fanin.numstat
expect "signal 3 (fan-in >=5) in the middle band -> full" '.tier=="full" and .fanin_probed==true
  and (.critical_signals|map(select(.signal==3 and .file=="lib/hub.go"))|length)==1
  and (.critical_signals[0].why|test("referenced by 6 other tracked files"))'

# A small edit to a high-fan-in file must not slip through as light just because it is
# small — the probe runs in clear-low too.
grade "$REPO" sig3-fanin-clear-low.numstat
expect "signal 3 (fan-in >=5) in the clear-low band -> full" '.tier=="full" and .band=="clear-high"
  and .files==2 and .loc==20 and .fanin_probed==true
  and (.critical_signals|map(select(.signal==3 and .file=="lib/hub.go"))|length)==1'

grade "$REPO" clear-high-loc.numstat
expect "signal 3 not probed once clear-high is already resolved" '.fanin_probed==false'

# Cap boundaries: each band's cap equals its own file ceiling (clear-low files<=5,
# middle files<=20), so the probe runs at exactly the cap and must not trip it. Neither
# cap branch can fire today — asserted statically instead.
grade "$REPO" clear-low-5-files.numstat
expect "fan-in cap boundary (clear-low, 5 files) probes without tripping the cap" \
  '.tier=="light" and .files==5 and .loc==100 and .fanin_probed==true and (.critical_signals|length)==0'

grade "$REPO" middle-20-files.numstat
expect "fan-in cap boundary (middle, 20 files) probes without tripping the cap" \
  '.tier=="middle" and .files==20 and .fanin_probed==true and (.critical_signals|length)==0'

if grep -q 'fan-in probe cap exceeded' "$TG" \
  && grep -q '^FANIN_CAP_LOW="\$BAND_LOW_FILES"' "$TG" \
  && grep -q '^FANIN_CAP_MIDDLE="\$BAND_HIGH_FILES"' "$TG"; then
  echo "OK: fan-in cap branch present, both caps derived from the band constants"
else
  echo "FAIL: fan-in cap branch missing or caps not derived from band constants"; fail=1
fi

# Every band threshold is declared once and interpolated — no digit written twice.
if grep -qE '^BAND_LOW_FILES=5[[:space:]]*(#|$)'    "$TG" \
  && grep -qE '^BAND_LOW_LOC=100[[:space:]]*(#|$)'   "$TG" \
  && grep -qE '^BAND_HIGH_FILES=20[[:space:]]*(#|$)' "$TG" \
  && grep -qE '^BAND_HIGH_LOC=600[[:space:]]*(#|$)'  "$TG" \
  && grep -q -- '-gt "\$BAND_HIGH_FILES"' "$TG" && grep -q -- '-gt "\$BAND_HIGH_LOC"' "$TG" \
  && grep -q -- '-le "\$BAND_LOW_FILES"'  "$TG" && grep -q -- '-le "\$BAND_LOW_LOC"'  "$TG" \
  && ! grep -qE 'REASON=.*(>20|>600|<=5,|<=100,)' "$TG"; then
  echo "OK: band thresholds declared once, interpolated into comparisons and reasons"
else
  echo "FAIL: band thresholds hardcoded inline or duplicated in a reason string"; fail=1
fi

# ---- Signal 4 — deletion-heavy executable ------------------------------------
grade "$REPO" sig4-deletion-heavy-exec.numstat sig4-deletion-heavy-exec.raw
expect "signal 4 (deletion-heavy executable) -> full, alongside signal 2" '.tier=="full"
  and (.critical_signals|map(select(.signal==4 and .file=="tools/oldscript"))|length)==1
  and (.critical_signals|map(select(.signal==2))|length)==1'

# ---- Signal 5 — test removal -------------------------------------------------
grade "$REPO" sig5-test-removal.numstat
expect "signal 5 (net-negative test file) -> full" '.tier=="full"
  and (.critical_signals|map(select(.signal==5 and .file=="src/parser_test.go"))|length)==1'

# ---- Rename post-image resolution --------------------------------------------
# Rename handling is covered entirely by the real-git-ops section below. Hand-written
# rename fixtures were removed: a " => " path cannot be resolved without --raw's status
# letter, so a hand-written numstat-only rename now (correctly) fails closed, and any
# fixture pairing one with a hand-written .raw would just be asserting my own guess at
# git's output — which is how the empty-replacement bug survived in the first place.

# ==============================================================================
# Fixtures generated from REAL git operations
# ==============================================================================
# Everything above grades hand-written numstat/raw text, which only ever exercises the
# shapes I thought to type. Two production bugs (the "a/{b => }/tool" empty-replacement
# rename, and "-\t-" line counts on -diff/binary files) were both shapes git emits
# routinely and neither was reachable from a hand-written fixture. Below, git itself
# produces the input: real `git mv` across directory levels, a real .gitattributes
# -diff marker, real binary content, a real mode change, and a real symlink. Assertions
# run against whatever the local git actually prints, so these cannot drift from it.

GOPS="$TMP/gitops"
mkdir -p "$GOPS"
git init -q "$GOPS"
g() { git -C "$GOPS" "$@"; }
gcommit() { g -c user.email=t@t -c user.name=t commit -qm "$1" >/dev/null; }
uniq_lines() {  # <count> <tag> — distinct content so rename detection pairs deterministically
  local i=0
  while [ "$i" -lt "$1" ]; do printf '%s-line-%d\n' "$2" "$i"; i=$((i + 1)); done
}
gitops_grade() {  # capture the staged diff exactly as a caller would, then grade it
  g diff --cached --numstat > "$TMP/g.numstat"
  g diff --cached --raw     > "$TMP/g.raw"
  OUT="$(cd "$GOPS" && bash "$TG" --numstat "$TMP/g.numstat" --raw "$TMP/g.raw" 2>/dev/null)"
  RC=$?
}

mkdir -p "$GOPS/a/b" "$GOPS/c" "$GOPS/e/f" "$GOPS/vendor" "$GOPS/bin" "$GOPS/assets"
uniq_lines 40 tool  > "$GOPS/a/b/tool";   chmod 755 "$GOPS/a/b/tool"
uniq_lines 40 tool2 > "$GOPS/c/tool2";    chmod 755 "$GOPS/c/tool2"
uniq_lines 40 svc   > "$GOPS/e/f/svc.go"; chmod 755 "$GOPS/e/f/svc.go"
uniq_lines 40 flat  > "$GOPS/old-name.md"; chmod 755 "$GOPS/old-name.md"
uniq_lines 10 gen   > "$GOPS/vendor/gen.pb.go"
uniq_lines 10 plain > "$GOPS/bin/deploy"
head -c 512 /dev/urandom > "$GOPS/assets/logo.png"
printf 'vendor/gen.pb.go -diff\n*.png binary\n' > "$GOPS/.gitattributes"
uniq_lines 5 anchor > "$GOPS/anchor.txt"
g add -A >/dev/null
gcommit init

# --- Empty-replacement rename (the F-B repro: "a/{b => }/tool") ---------------
# The file is mode 755 with NO shebang, so signal 2 can only come from the --raw mode
# lookup — which is keyed on the post-image path. A parser that emits "a//tool" misses
# the key and the signal silently vanishes.
g mv a/b/tool a/tool
g add -A >/dev/null
gitops_grade
expect_rc0 "real git mv (segment removed)"
expect "real 'a/{b => }/tool' resolves to a/tool, keeping its --raw mode lookup" \
  '.tier=="full" and (.critical_signals|map(select(.signal==2 and .file=="a/tool"))|length)==1
   and (.critical_signals|map(select(.file|test("//")))|length)==0
   and (.grading_reason|test("fail-closed")|not)'
gcommit rename-out

# --- Segment added, segment renamed, and a bare rename in one real diff --------
g mv c/tool2 c/d/tool2 2>/dev/null || { mkdir -p "$GOPS/c/d"; g mv c/tool2 c/d/tool2; }
g mv e/f/svc.go e/g/svc.go 2>/dev/null || { mkdir -p "$GOPS/e/g"; g mv e/f/svc.go e/g/svc.go; }
g mv old-name.md new-name.md
g add -A >/dev/null
gitops_grade
expect_rc0 "real git mv (segment added / renamed / bare)"
expect "every real rename form resolves to its post-image path" \
  '(.critical_signals|map(select(.signal==2 and .file=="c/d/tool2"))|length)==1
   and (.critical_signals|map(select(.signal==2 and .file=="e/g/svc.go"))|length)==1
   and (.critical_signals|map(select(.signal==2 and .file=="new-name.md"))|length)==1
   and (.critical_signals|map(select(.file|test("//")))|length)==0
   and (.grading_reason|test("fail-closed")|not)'
gcommit renames

# --- Real -diff attribute marker (the F-C repro) ------------------------------
# A 2000-line append to a file marked `-diff` prints as "-\t-". Counting that as 0 LOC
# graded it light; it must reach at least triage.
uniq_lines 2000 bulk >> "$GOPS/vendor/gen.pb.go"
g add -A >/dev/null
gitops_grade
expect_rc0 "real -diff attributed file"
expect "real -diff file with a 2000-line change never grades light" \
  '.tier=="middle" and .files==1 and .loc==0
   and (.grading_reason|test("no line count available"))'
gcommit vendor-bulk

# --- Real binary change -------------------------------------------------------
head -c 4096 /dev/urandom > "$GOPS/assets/logo.png"
g add -A >/dev/null
gitops_grade
expect_rc0 "real binary change"
expect "real binary change never grades light" \
  '.tier=="middle" and (.grading_reason|test("no line count available"))'
gcommit binary

# --- Real mode change 644 -> 755, no shebang ----------------------------------
chmod 755 "$GOPS/anchor.txt"
g add -A >/dev/null
gitops_grade
expect_rc0 "real mode change"
expect "real 644->755 mode change fires signal 2 with no content change" \
  '.tier=="full" and (.critical_signals|map(select(.signal==2 and .file=="anchor.txt"))|length)==1'
gcommit chmod

# --- Real symlink -------------------------------------------------------------
ln -s anchor.txt "$GOPS/link.txt"
g add -A >/dev/null
gitops_grade
expect_rc0 "real symlink addition"
expect "real symlink grades without a spurious signal or fail-closed" \
  '.tier=="light" and (.critical_signals|length)==0 and (.grading_reason|test("fail-closed")|not)'
gcommit symlink

# --- M14 shape: committed range graded while the working tree disagrees --------
# The ship gate grades `merge-base..HEAD`, i.e. committed history. Here the COMMITTED
# blob is plain text but the WORKING TREE copy has a shebang, so reading the working
# tree would invent a signal 2 that is not in the graded range. The correct result is
# no signal at all — which is only reachable through the --raw blob SHA.
uniq_lines 12 plain2 > "$GOPS/bin/deploy"
g add -A >/dev/null
gcommit deploy-committed
printf '#!/bin/sh\necho drift\n' > "$GOPS/bin/deploy"
g diff --numstat HEAD~1..HEAD > "$TMP/m14.numstat"
g diff --raw     HEAD~1..HEAD > "$TMP/m14.raw"
OUT="$(cd "$GOPS" && bash "$TG" --numstat "$TMP/m14.numstat" --raw "$TMP/m14.raw" 2>/dev/null)"; RC=$?
expect_rc0 "M14-shaped committed range"
expect "committed range grades the committed blob, not a drifted working tree" \
  '.files==1 and (.critical_signals|map(select(.signal==2))|length)==0
   and (.grading_reason|test("fail-closed")|not)'
g checkout -- bin/deploy 2>/dev/null || true

# --- --raw / --numstat disagreement fails closed ------------------------------
printf '1\t0\tnot-in-the-raw-input.txt\n' >> "$TMP/m14.numstat"
OUT="$(cd "$GOPS" && bash "$TG" --numstat "$TMP/m14.numstat" --raw "$TMP/m14.raw" 2>/dev/null)"; RC=$?
expect "fail-closed: --raw missing a numstat path -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: --raw does not describe numstat path"))'

# ==============================================================================
# Decoy-file attack on rename-notation collapse
# ==============================================================================
# " => " in a numstat path is ambiguous: rename notation, or a literal filename that
# contains it. numstat carries no marker; only --raw's status letter does. Committing a
# real 100755 executable under a directory literally named "{a => b}" PLUS a decoy at
# the collapsed path aimed the executable's row at the decoy's mode and content, and the
# whole diff graded light. Each case below is built with real git.

decoy_repo() {  # <dir> — fresh repo with one seed commit
  mkdir -p "$1"; git init -q "$1"
  printf 'seed\n' > "$1/seed.txt"
  git -C "$1" add -A >/dev/null
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null
}
decoy_grade() {  # <dir> [--no-raw]
  git -C "$1" diff --cached --numstat > "$TMP/d.numstat"
  git -C "$1" diff --cached --raw     > "$TMP/d.raw"
  if [ "${2:-}" = "--no-raw" ]; then
    OUT="$(cd "$1" && bash "$TG" --numstat "$TMP/d.numstat" 2>/dev/null)"
  else
    OUT="$(cd "$1" && bash "$TG" --numstat "$TMP/d.numstat" --raw "$TMP/d.raw" 2>/dev/null)"
  fi
  RC=$?
}

# --- The attack: executable at a literal "{a => b}" path, decoy at the collapse -------
DA="$TMP/decoy-attack"; decoy_repo "$DA"
mkdir -p "$DA/tools/{a => b}" "$DA/tools/b"
printf 'payload\nno shebang\n' > "$DA/tools/{a => b}/deploy"; chmod 755 "$DA/tools/{a => b}/deploy"
printf 'harmless decoy\n' > "$DA/tools/b/deploy";              chmod 644 "$DA/tools/b/deploy"
git -C "$DA" add -A >/dev/null
decoy_grade "$DA"
expect_rc0 "decoy attack"
expect "decoy cannot redirect a 100755 row to a 100644 file" '.tier=="full"
  and (.critical_signals|map(select(.signal==2 and .file=="tools/{a => b}/deploy"))|length)==1
  and (.critical_signals|map(select(.file=="tools/b/deploy"))|length)==0'

# Without --raw there is no status letter, so the same row cannot be disambiguated.
decoy_grade "$DA" --no-raw
expect "no --raw: an ambiguous ' => ' path fails closed instead of guessing" \
  '.tier=="full" and .band=="fail-closed"
   and (.grading_reason|test("needs --raw to tell rename notation from a literal name"))'

# --- Control: same executable, no decoy ---------------------------------------
DB="$TMP/decoy-control"; decoy_repo "$DB"
mkdir -p "$DB/tools/{a => b}"
printf 'payload\n' > "$DB/tools/{a => b}/deploy"; chmod 755 "$DB/tools/{a => b}/deploy"
git -C "$DB" add -A >/dev/null
decoy_grade "$DB"
expect "control: literal ' => ' path with no decoy grades on its own mode" '.tier=="full"
  and (.critical_signals|map(select(.signal==2 and .file=="tools/{a => b}/deploy"))|length)==1
  and (.grading_reason|test("fail-closed")|not)'

# --- Control: ordinary executable, no rename notation anywhere ----------------
DC="$TMP/decoy-plain"; decoy_repo "$DC"
mkdir -p "$DC/tools"
printf 'payload\n' > "$DC/tools/deploy"; chmod 755 "$DC/tools/deploy"
git -C "$DC" add -A >/dev/null
decoy_grade "$DC"
expect "control: plain 100755 file still grades full via signal 2" '.tier=="full"
  and (.critical_signals|map(select(.signal==2 and .file=="tools/deploy"))|length)==1'

# --- Collision: a literal name AND a genuine rename collapsing to the same string ---
# git really does print two identical numstat rows here, one per file. The row cannot be
# read both ways at once, so it fails closed rather than picking one.
DD="$TMP/decoy-collision"; decoy_repo "$DD"
mkdir -p "$DD/tools/{a => b}" "$DD/tools/a" "$DD/tools/b"
uniq_lines 20 literal > "$DD/tools/{a => b}/deploy"
uniq_lines 20 renamed > "$DD/tools/a/deploy"
git -C "$DD" add -A >/dev/null
git -C "$DD" -c user.email=t@t -c user.name=t commit -qm pair >/dev/null
git -C "$DD" mv tools/a/deploy tools/b/deploy
printf 'more\n' >> "$DD/tools/{a => b}/deploy"
git -C "$DD" add -A >/dev/null
decoy_grade "$DD"
expect_rc0 "rename/literal collision"
expect "a row readable as both a literal name and a rename post-image fails closed" \
  '.tier=="full" and .band=="fail-closed"
   and (.grading_reason|test("ambiguous numstat path"))'

# ---- Fail-closed matrix ------------------------------------------------------
grade "$REPO" empty.numstat
expect_rc0 "fail-closed empty diff"
expect "fail-closed: empty diff -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: empty or unresolvable diff"))'

grade "$REPO" malformed-nonnumeric.numstat
expect "fail-closed: non-numeric numstat -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: malformed numstat line"))'

grade "$REPO" malformed-notabs.numstat
expect "fail-closed: tab-less numstat -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: malformed numstat line"))'

grade "$REPO" quoted-path.numstat
expect "fail-closed: C-quoted path -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: unsupported C-quoted path"))'

OUT="$(cd "$NOTREPO" && bash "$TG" --numstat "$FIX/clear-low.numstat" 2>/dev/null)"; RC=$?
expect_rc0 "fail-closed git failure"
expect "fail-closed: outside a work tree -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: git failure"))'

OUT="$(cd "$REPO" && PATH= "${BASH:-/bin/bash}" "$TG" --numstat "$FIX/clear-low.numstat" 2>/dev/null)"; RC=$?
expect_rc0 "fail-closed missing jq"
expect "fail-closed: jq not in PATH -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: jq not found"))'

OUT="$(cd "$REPO" && bash "$TG" --numstat "$TMP/does-not-exist" 2>/dev/null)"; RC=$?
expect "fail-closed: unreadable numstat -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: numstat input not readable"))'

printf 'CORRUPT' > "$BADREPO/.git/index"
OUT="$(cd "$BADREPO" && bash "$TG" --numstat "$FIX/sig3-fanin.numstat" 2>/dev/null)"; RC=$?
expect_rc0 "fail-closed git grep failure"
expect "fail-closed: git grep failure mid-probe -> full" '.tier=="full" and .band=="fail-closed"
  and (.grading_reason|test("^fail-closed: git failure: git grep exited"))'

# ---- Interface contract ------------------------------------------------------
OUT="$(cd "$REPO" && bash "$TG" --numstat - < "$FIX/clear-low.numstat" 2>/dev/null)"; RC=$?
expect "stdin (--numstat -) matches file input" '.tier=="light" and .files==3 and .loc==42'

usage_out="$(cd "$REPO" && bash "$TG" 2>/dev/null)"; usage_rc=$?
if [ "$usage_rc" -eq 2 ] && [ -z "$usage_out" ]; then
  echo "OK: missing --numstat -> exit 2, no JSON"
else
  echo "FAIL: usage rc=$usage_rc out='$usage_out' (want rc=2, empty)"; fail=1
fi

usage_out="$(cd "$REPO" && bash "$TG" --numstat "$FIX/clear-low.numstat" --bogus x 2>/dev/null)"; usage_rc=$?
if [ "$usage_rc" -eq 2 ]; then
  echo "OK: unknown flag -> exit 2"
else
  echo "FAIL: unknown flag rc=$usage_rc (want 2)"; fail=1
fi

# `skip` is never auto-selectable (SPEC-013: grading MUST NOT be able to return it).
if grep -q '"skip"\|=skip' "$TG"; then
  echo "FAIL: tier-grade.sh can emit skip"; fail=1
else
  echo "OK: skip is not emittable by grading"
fi

# Fail-closed emitter must not depend on jq.
if awk '/^fail_closed\(\)/,/^}/' "$TG" | grep -q 'jq'; then
  echo "FAIL: fail_closed() depends on jq"; fail=1
else
  echo "OK: fail_closed() is jq-free"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
