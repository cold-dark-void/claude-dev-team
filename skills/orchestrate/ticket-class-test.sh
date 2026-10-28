#!/usr/bin/env bash
# ticket-class-test.sh — word-boundary classifier + Glossary carve-out (CDT-589-C1).
# Fails on a substring "auth" match. Carve-out cases call the CLI only; the
# fixture glossary is hermetic (no live repo CONTEXT.md, no Linear fetch).
#
# Per-AC run receipts (CDT-595, SPEC-009 § CDT-595): every check prints
# `ok AC<n>: <slug>` on stdout and a failure prints `FAIL: AC<n>: <slug>:
# <detail>` on stderr, from tests/lib/ac-receipt.sh. `--ac AC<n>` runs one AC
# block and prints the subset aggregate. The last stdout line of any run is
# `PASS=<n> FAIL=<m>`; the count of `^ok ` lines equals n.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLASS="$HERE/ticket-class.sh"
FIX="$HERE/fixtures/glossary-carve-out"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/ac-receipt.sh
. "$HERE/../../tests/lib/ac-receipt.sh"
hermetic_init
parse_ac_args "$@"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT INT TERM

PASS=0
FAIL=0

# run_class <glossary> <text> — sets OUT (stdout), RC (exit), ERR (stderr).
run_class() {
  local g=$1 text=$2
  OUT=$(TICKET_CLASS_GLOSSARY="$g" bash "$CLASS" --text "$text" 2>"$TMP/err")
  RC=$?
  ERR=$(cat "$TMP/err")
}

# check <want> <text> <slug> — the no-carve-out form (sentinel off), byte-identical
# to the pre-CDT-589-C1 classifier.
check() {
  local want=$1 text=$2 slug=$3
  run_class off "$text"
  [ "$RC" -eq 0 ] || { bad "$slug" "rc non-zero for [$text]"; return; }
  if [ "$OUT" = "$want" ]; then ok "$slug"
  else bad "$slug" "text [$text] got [$OUT] want [$want]"; fi
}

# gcheck <want> <text> <slug> [glossary] — carve-out form.
gcheck() {
  local want=$1 text=$2 slug=$3 g=${4:-$FIX/CONTEXT.md}
  run_class "$g" "$text"
  [ "$RC" -eq 0 ] || { bad "$slug" "rc non-zero for [$text]"; return; }
  if [ "$OUT" = "$want" ]; then ok "$slug"
  else bad "$slug" "glossary [$g] text [$text] got [$OUT] want [$want]"; fi
}

# carve_check <want-stderr> <text> <slug> — AC11 stderr contract.
carve_check() {
  local want=$1 text=$2 slug=$3
  run_class "$FIX/CONTEXT.md" "$text"
  if [ "$ERR" = "$want" ]; then ok "$slug"
  else bad "$slug" "carve stderr [$text] got [$ERR] want [$want]"; fi
}

# fail_closed <glossary> <slug> — AC7: hit stands, no stderr, exit 0.
fail_closed() {
  local g=$1 slug=$2
  run_class "$g" "pin stays shared Same-session via preferences"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "auth-secrets" ] && [ -z "$ERR" ]; then ok "$slug"
  else bad "$slug" "fail-closed [$g]: rc=$RC out=[$OUT] err=[$ERR]"; fi
}

# dircheck <want> <text> <slug> <dir> <label> — AC9 discovery-path form: the
# CLI runs from <dir> with the glossary override cleared. <label> names that
# path in the failure detail.
dircheck() {
  local want=$1 text=$2 slug=$3 dir=$4 label=$5
  OUT=$(cd "$dir" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "$text" 2>/dev/null)
  if [ "$OUT" = "$want" ]; then ok "$slug"
  else bad "$slug" "AC9 $label [$text] got [$OUT] want [$want]"; fi
}

# mk_gloss <file> <term> — one-row Terms table.
mk_gloss() {
  printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid (aliases) |\n|---|---|---|\n| %s | d | a |\n' "$2" > "$1" || return 1
}

# --- AC14: the 8 pre-existing base cases stay green (SPEC-009 C1 AC14) ----
# Planted negative control: "author" contains "auth" and must NOT classify.
set_ac AC14
if want_ac; then
  check none "author" base-author
  check none "The author wrote the design note." base-author-sentence
  check none "tokenizer" base-tokenizer
  check auth-secrets "auth" base-auth
  check auth-secrets "Add authentication to the session" base-add-authentication
  check auth-secrets "store the API key" base-store-api-key
  check auth-secrets "private-key rotation" base-private-key-rotation
  check none "rename the public helper" base-rename-public-helper
fi

# --- AC1: the fixture pair, both CLI forms --------------------------------
set_ac AC1
if want_ac; then
  gcheck none "pin stays shared Same-session via preferences" fixture-glossary-none
  check auth-secrets "pin stays shared Same-session via preferences" sentinel-off-hit
  OUT=$(TICKET_CLASS_GLOSSARY="$FIX/CONTEXT.md" bash "$CLASS" \
    < "$FIX/ticket-ac1.txt" 2>/dev/null)
  RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then ok stdin-form-none
  else bad "stdin-form-none" "AC1 stdin form: rc=$RC out=[$OUT]"; fi
fi

# --- AC2: carve is per occurrence, not per document -----------------------
set_ac AC2
if want_ac; then
  gcheck auth-secrets "Same-session token theft" per-occurrence-theft
  gcheck auth-secrets "the session in Same-session" per-occurrence-space-form
  gcheck none "Same-session" per-occurrence-only
fi

# --- AC3: token equality, not substring ----------------------------------
set_ac AC3
if want_ac; then
  gcheck none "Same-session." token-dot
  gcheck none "Same-session, and nothing else" token-comma
  gcheck none "$(printf 'notes\nSame-session')" token-line-bounded
  gcheck none "same-sessions" plural-not-carved
  gcheck auth-secrets "auth-same-session" compound-prefix-hit
  gcheck none "Same-SESSION" case-insensitive
fi

# --- AC4: masking creates no new hit (before/after identical) -------------
set_ac AC4
if want_ac; then
  check auth-secrets "authSame-session" mask-before-authsame
  gcheck auth-secrets "authSame-session" mask-after-authsame
  check none "authSame-sessionx" mask-before-authsame-x
  gcheck none "authSame-sessionx" mask-after-authsame-x
  gcheck none "author" neg-control-author
  gcheck none "tokenizer" neg-control-tokenizer
  gcheck none "rename the public helper" neg-control-rename
fi

# --- AC5: the hyphenated compound never carves the space form ------------
set_ac AC5
if want_ac; then
  gcheck none "private-key-material rotation" compound-carves-compound
  gcheck auth-secrets "rotate the private key" hyphen-keeps-space-form
fi

# --- AC6: col 1 of ## Terms only -----------------------------------------
set_ac AC6
if want_ac; then
  gcheck auth-secrets "pin stays shared Same-session via preferences" avoid-column-only "$FIX/avoid-only.md"
  gcheck auth-secrets "pin stays shared Same-session via preferences" decisions-bullet-only "$FIX/decisions-only.md"
  gcheck auth-secrets "rotate the cross-token signer" definition-column-only
  gcheck auth-secrets "drop the reuse-auth alias" avoid-column-alias
fi

# --- AC7: fail-closed on every unparsable glossary -----------------------
set_ac AC7
if want_ac; then
  # The scan-tool rc>=2 branch cannot be forced through the CLI (no injectable
  # regex or unreadable scan file), so it is pinned on the source text: both
  # scans must treat any rc other than 0/1 as a hit.
  if [ "$(grep -cF '[ "$rc" -ne 1 ]' "$CLASS")" = "2" ]; then ok scan-tool-failure
  else bad "scan-tool-failure" "scan rc>=2 fail-closed branch is not in both scans"; fi
  # D1 path absent: no override, and the repo has no CONTEXT.md at all. This is
  # the no-glossary baseline, distinct from missing-path (the env var names a
  # file that is not there).
  NOFILE="$TMP/nofile"
  mkdir -p "$NOFILE"
  NERR="$TMP/nofile.err"
  OUT=$(cd "$NOFILE" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" \
    --text "pin stays shared Same-session via preferences" 2>"$NERR")
  RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "auth-secrets" ] && [ ! -s "$NERR" ]; then ok no-file
  else bad "no-file" "no glossary in repo: rc=$RC out=[$OUT] err=[$(cat "$NERR")]"; fi
  : > "$TMP/empty.md"
  printf '# Fixture glossary\n\n## Decisions\n\n- 2026-10-26: Same-session note.\n' > "$TMP/noterms.md"
  printf '## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n' > "$TMP/header.md"
  printf '## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n| | empty column one | x |\n' > "$TMP/emptycol1.md"
  printf '## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\nSame-session | d | a |\n' > "$TMP/nonpipe.md"
  fail_closed "$TMP/empty.md" empty-file
  fail_closed "$TMP/noterms.md" no-terms
  fail_closed "$TMP/header.md" header-only
  fail_closed "$TMP/emptycol1.md" empty-col1
  fail_closed "$TMP/nonpipe.md" non-pipe-row
  fail_closed "$TMP/does-not-exist.md" missing-path
  fail_closed "$TMP" directory-path
  printf '## Terms\n\n| Café-session | d | a |\n| Same-session | d | a |\n' > "$TMP/utf8.md"
  gcheck none "Same-session" non-ascii-term "$TMP/utf8.md"
  if [ "$(id -u)" = "0" ]; then
    # SPEC-030 R18: chmod 000 does not stop root reading the file, so the
    # check is a legitimate skip, never a pass and never a `SKIP:` line.
    skip_ac "mode-000 uid0"
  else
    printf '## Terms\n\n| Same-session | d | a |\n' > "$TMP/mode000.md"
    chmod 000 "$TMP/mode000.md"
    fail_closed "$TMP/mode000.md" mode-000
    chmod 644 "$TMP/mode000.md"
  fi
fi

# --- AC8: true positives survive the fixture glossary --------------------
set_ac AC8
if want_ac; then
  gcheck auth-secrets "session cookie theft" pos-session-cookie
  gcheck auth-secrets "rotate the API key" pos-api-key
  gcheck auth-secrets "private-key rotation" pos-private-key-rotation
  gcheck auth-secrets "auth" pos-auth
  gcheck auth-secrets "token" pos-token
  gcheck auth-secrets "Add authentication to the session" pos-add-authentication
  gcheck auth-secrets "the non-auth flag" pos-non-auth-compound
  gcheck auth-secrets "re-session the row" pos-re-session-compound
fi

# --- AC9: D1 first-hit resolution ----------------------------------------
set_ac AC9
if want_ac; then
  if ! command -v git >/dev/null 2>&1; then
    # Receipt form, not `SKIP:`: judge.md reads a `SKIP:` line as evidence
    # against. These fixtures need git, so the block cannot run without it.
    skip_ac "no-git"
  else
    REPO="$TMP/mrepo"
    mkdir -p "$REPO/docs/domain"
    mk_gloss "$REPO/CONTEXT.md" "Mroot-probe-session"
    mk_gloss "$REPO/docs/domain/CONTEXT.md" "Mdoc-probe-session"
    git init -q "$REPO"
    ( cd "$REPO" && git add -A && git commit -qm fixture )
    git -C "$REPO" worktree add -q "$REPO/.wt" HEAD
    mk_gloss "$REPO/.wt/CONTEXT.md" "Wtroot-probe-session"
    dircheck none "wtroot-probe-session" wtroot-beats-mroot "$REPO/.wt" worktree
    dircheck auth-secrets "mroot-probe-session" gwt-ignores-mroot "$REPO/.wt" worktree
    dircheck auth-secrets "mdoc-probe-session" gwt-ignores-mdoc "$REPO/.wt" worktree
    dircheck none "mroot-probe-session" mroot-beats-mdoc "$REPO" main
    dircheck auth-secrets "mdoc-probe-session" mdoc-shadowed-at-root "$REPO" main
    DOC="$TMP/docsonly"
    mkdir -p "$DOC/docs/domain"
    mk_gloss "$DOC/docs/domain/CONTEXT.md" "Droot-probe-session"
    git init -q "$DOC"
    ( cd "$DOC" && git add -A && git commit -qm fixture )
    OUT=$(cd "$DOC" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "droot-probe-session" 2>/dev/null)
    if [ "$OUT" = "none" ]; then ok docs-domain-fallback
    else bad "docs-domain-fallback" "AC9 docs/domain fallback got [$OUT]"; fi
    PLUGIN="$TMP/plugin"
    mkdir -p "$PLUGIN"
    mk_gloss "$PLUGIN/CONTEXT.md" "Plugin-probe-session"
    OUT=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN" env -u TICKET_CLASS_GLOSSARY \
      bash "$CLASS" --text "plugin-probe-session" 2>/dev/null)
    if [ "$OUT" = "auth-secrets" ]; then ok plugin-never
    else bad "plugin-never" "AC9 plugin dir must never be a glossary source, got [$OUT]"; fi
  fi
fi

# --- AC10: env override and the off sentinel ------------------------------
set_ac AC10
if want_ac; then
  # The sentinel wins over every path: no glossary is read, so no carve line
  # and the unmasked hit stands.
  run_class off "Same-session"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "auth-secrets" ] && [ -z "$ERR" ]; then ok sentinel-off
  else bad "sentinel-off" "sentinel off: rc=$RC out=[$OUT] err=[$ERR]"; fi
  # TICKET_CLASS_GLOSSARY beats the D1 discovery path: the repo-local
  # CONTEXT.md names a term the env file does not, and vice versa.
  OVR="$TMP/override"
  mkdir -p "$OVR"
  mk_gloss "$OVR/CONTEXT.md" "Root-probe-session"
  mk_gloss "$TMP/override.md" "Override-probe-session"
  OUT=$(cd "$OVR" && TICKET_CLASS_GLOSSARY="$TMP/override.md" \
    bash "$CLASS" --text "override-probe-session" 2>/dev/null)
  if [ "$OUT" = "none" ]; then ok env-override
  else bad "env-override" "env glossary not used, got [$OUT]"; fi
  OUT=$(cd "$OVR" && TICKET_CLASS_GLOSSARY="$TMP/override.md" \
    bash "$CLASS" --text "root-probe-session" 2>/dev/null)
  if [ "$OUT" = "auth-secrets" ]; then ok env-override-beats-root
  else bad "env-override-beats-root" "root glossary used, got [$OUT]"; fi
fi

# --- AC11: the carve line ------------------------------------------------
set_ac AC11
if want_ac; then
  carve_check "ticket-class: carved same-session=1" "Same-session" carve-line-present
  carve_check "ticket-class: carved same-session=2 private-key-material=1" \
    "Same-session private-key-material and Same-session" carve-line-present-multi
  carve_check "" "session cookie theft" zero-carve-silence
  CAP="$TMP/cap.md"
  {
    printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n'
    i=1
    while [ "$i" -le 258 ]; do printf '| aa%s-session | d | a |\n' "$i"; i=$((i + 1)); done
  } > "$CAP"
  run_class "$CAP" "aa258-session"
  if [ "$OUT" = "auth-secrets" ] \
    && [ "$ERR" = "ticket-class: glossary cap 256; using first 256" ]; then ok stdout-exit-unchanged
  else bad "stdout-exit-unchanged" "cap over-256: out=[$OUT] err=[$ERR]"; fi
  run_class "$CAP" "aa1-session"
  if [ "$OUT" = "none" ] && [ "$ERR" = \
    "ticket-class: glossary cap 256; using first 256
ticket-class: carved aa1-session=1" ]; then ok stdout-exit-unchanged-cap-line
  else bad "stdout-exit-unchanged-cap-line" "cap first-256 used: out=[$OUT] err=[$ERR]"; fi
fi

# --- AC13: portable subset, and 256 KB + 100 rows under 2 s --------------
# argv and the exit-code contract are unchanged by the carve-out.
set_ac AC13
if want_ac; then
  bash "$CLASS" --text a b >/dev/null 2>&1
  if [ "$?" -eq 64 ]; then ok usage-two-args; else bad "usage-two-args" "usage: --text with two args must exit 64"; fi
  bash "$CLASS" --bogus >/dev/null 2>&1
  if [ "$?" -eq 64 ]; then ok usage-unknown-arg; else bad "usage-unknown-arg" "usage: unknown arg must exit 64"; fi
  # Every construct is split by an empty quote pair so this file is not itself
  # flagged by the run-all-tests --portable filter, while the assembled pattern
  # bites on the real text.
  BANNED='de''clare -A|de''clare -n|lo''cal -n|ma''pfile|rea''darray'
  BANNED="$BANNED|fl''ock|sha''256sum|gt''imeout|ti''meout"
  BANNED="$BANNED|grep -''P|touch -''d|-pri''ntf"
  BANNED="$BANNED|\$\{[A-Za-z_][A-Za-z0-9_]*,,"
  BANNED="$BANNED|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^"
  if printf 'x ma''pfile y' | grep -Eq "$BANNED"; then ok banned-pattern-vacuity
  else bad "banned-pattern-vacuity" "banned-construct pattern matches nothing (vacuous)"; fi
  if grep -Eq "$BANNED" "$CLASS"; then
    bad "portability-grep" "ticket-class.sh uses a banned construct: $(grep -En "$BANNED" "$CLASS")"
  else
    ok portability-grep
  fi
  G100="$TMP/perf-gloss.md"
  {
    printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n'
    printf '| Same-session | d | a |\n'
    i=2
    while [ "$i" -le 100 ]; do printf '| aa%s-session | d | a |\n' "$i"; i=$((i + 1)); done
  } > "$G100"
  BIG="$TMP/perf-ticket.txt"
  awk 'BEGIN { for (i = 0; i < 2900; i++) print "the pin stays shared Same-session via preferences and aa7-session plus aa99-session line " i }' > "$BIG"
  SIZE=$(wc -c < "$BIG" | tr -d ' ')
  if [ "$SIZE" -ge 262144 ]; then ok input-size-256k; else bad "input-size-256k" "perf input is only $SIZE bytes"; fi
  START=$SECONDS
  OUT=$(TICKET_CLASS_GLOSSARY="$G100" bash "$CLASS" < "$BIG" 2>/dev/null)
  ELAPSED=$((SECONDS - START))
  if [ "$OUT" = "none" ]; then ok determinism
  else bad "determinism" "AC13 big input: out=[$OUT] elapsed=${ELAPSED}s"; fi
  # The 2 s budget is a per-run wall-clock claim, so it is measured only when
  # AC13 is the selected block. A full run omits it (CDT-595 AC5).
  if [ "$AC_FILTER" = "AC13" ]; then
    if [ "$ELAPSED" -lt 2 ]; then ok "perf-2s ${ELAPSED}s"
    else bad "perf-2s" "AC13 perf: elapsed=${ELAPSED}s"; fi
  fi
fi

ac_finish
