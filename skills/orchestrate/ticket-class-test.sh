#!/usr/bin/env bash
# ticket-class-test.sh — word-boundary classifier + Glossary carve-out (CDT-589-C1).
# Fails on a substring "auth" match. Carve-out cases call the CLI only; the
# fixture glossary is hermetic (no live repo CONTEXT.md, no Linear fetch).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLASS="$HERE/ticket-class.sh"
FIX="$HERE/fixtures/glossary-carve-out"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

# run_class <glossary> <text> — sets OUT (stdout), RC (exit), ERR (stderr).
run_class() {
  local g=$1 text=$2
  OUT=$(TICKET_CLASS_GLOSSARY="$g" bash "$CLASS" --text "$text" 2>"$TMP/err")
  RC=$?
  ERR=$(cat "$TMP/err")
}

# check <want> <text> — the no-carve-out form (sentinel off), byte-identical
# to the pre-CDT-589-C1 classifier.
check() {
  local want=$1 text=$2
  run_class off "$text"
  [ "$RC" -eq 0 ] || { bad "rc non-zero for [$text]"; return; }
  if [ "$OUT" = "$want" ]; then ok
  else bad "text [$text] got [$OUT] want [$want]"; fi
}

# gcheck <want> <text> [glossary] — carve-out form.
gcheck() {
  local want=$1 text=$2 g=${3:-$FIX/CONTEXT.md}
  run_class "$g" "$text"
  [ "$RC" -eq 0 ] || { bad "rc non-zero for [$text]"; return; }
  if [ "$OUT" = "$want" ]; then ok
  else bad "glossary [$g] text [$text] got [$OUT] want [$want]"; fi
}

# carve_check <want-stderr> <text> — AC11 stderr contract.
carve_check() {
  local want=$1 text=$2
  run_class "$FIX/CONTEXT.md" "$text"
  if [ "$ERR" = "$want" ]; then ok
  else bad "carve stderr [$text] got [$ERR] want [$want]"; fi
}

# fail_closed <glossary> <label> — AC7: hit stands, no stderr, exit 0.
fail_closed() {
  local g=$1 label=$2
  run_class "$g" "pin stays shared Same-session via preferences"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "auth-secrets" ] && [ -z "$ERR" ]; then ok
  else bad "fail-closed $label: rc=$RC out=[$OUT] err=[$ERR]"; fi
}

# mk_gloss <file> <term> — one-row Terms table.
mk_gloss() {
  printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid (aliases) |\n|---|---|---|\n| %s | d | a |\n' "$2" > "$1"
}

# Planted negative control: "author" contains "auth" and must NOT classify.
check none "author"
check none "The author wrote the design note."
check none "tokenizer"
check auth-secrets "auth"
check auth-secrets "Add authentication to the session"
check auth-secrets "store the API key"
check auth-secrets "private-key rotation"
check none "rename the public helper"

# --- AC1: the fixture pair, both CLI forms --------------------------------
gcheck none "pin stays shared Same-session via preferences"
check auth-secrets "pin stays shared Same-session via preferences"
OUT=$(TICKET_CLASS_GLOSSARY="$FIX/CONTEXT.md" bash "$CLASS" \
  < "$FIX/ticket-ac1.txt" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then ok
else bad "AC1 stdin form: rc=$RC out=[$OUT]"; fi

# --- AC2: carve is per occurrence, not per document -----------------------
gcheck auth-secrets "Same-session token theft"
gcheck auth-secrets "the session in Same-session"
gcheck none "Same-session"

# --- AC3: token equality, not substring ----------------------------------
gcheck none "Same-session."
gcheck none "Same-session, and nothing else"
gcheck none "$(printf 'notes\nSame-session')"
gcheck none "same-sessions"
gcheck auth-secrets "auth-same-session"
gcheck none "Same-SESSION"

# --- AC4: masking creates no new hit (before/after identical) -------------
check auth-secrets "authSame-session"
gcheck auth-secrets "authSame-session"
check none "authSame-sessionx"
gcheck none "authSame-sessionx"
gcheck none "author"
gcheck none "tokenizer"
gcheck none "rename the public helper"

# --- AC5: the hyphenated compound never carves the space form ------------
gcheck none "private-key-material rotation"
gcheck auth-secrets "rotate the private key"

# --- AC6: col 1 of ## Terms only -----------------------------------------
gcheck auth-secrets "pin stays shared Same-session via preferences" "$FIX/avoid-only.md"
gcheck auth-secrets "pin stays shared Same-session via preferences" "$FIX/decisions-only.md"
gcheck auth-secrets "rotate the cross-token signer"
gcheck auth-secrets "drop the reuse-auth alias"

# --- AC7: fail-closed on every unparsable glossary -----------------------
: > "$TMP/empty.md"
printf '# Fixture glossary\n\n## Decisions\n\n- 2026-10-26: Same-session note.\n' > "$TMP/noterms.md"
printf '## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n' > "$TMP/header.md"
printf '## Terms\n\n| | empty column one | x |\nThis row has no pipe\n' > "$TMP/rows.md"
fail_closed "$TMP/empty.md" "empty file"
fail_closed "$TMP/noterms.md" "no Terms heading"
fail_closed "$TMP/header.md" "header and separator only"
fail_closed "$TMP/rows.md" "empty col 1 and non-pipe row"
fail_closed "$TMP/does-not-exist.md" "missing path"
fail_closed "$TMP" "directory path"
printf '## Terms\n\n| Café-session | d | a |\n| Same-session | d | a |\n' > "$TMP/utf8.md"
gcheck none "Same-session" "$TMP/utf8.md"
if [ "$(id -u)" = "0" ]; then
  ok "mode 000 unreadable — skipped: running as root"
else
  printf '## Terms\n\n| Same-session | d | a |\n' > "$TMP/mode000.md"
  chmod 000 "$TMP/mode000.md"
  fail_closed "$TMP/mode000.md" "mode 000 unreadable"
  chmod 644 "$TMP/mode000.md"
fi

# --- AC8: true positives survive the fixture glossary --------------------
gcheck auth-secrets "session cookie theft"
gcheck auth-secrets "rotate the API key"
gcheck auth-secrets "private-key rotation"
gcheck auth-secrets "auth"
gcheck auth-secrets "token"
gcheck auth-secrets "Add authentication to the session"
gcheck auth-secrets "the non-auth flag"
gcheck auth-secrets "re-session the row"

# --- AC9/AC10: D1 first-hit resolution ----------------------------------
if ! command -v git >/dev/null 2>&1; then
  ok "AC9 git fixture cases — skipped: no git"
else
  REPO="$TMP/mrepo"
  mkdir -p "$REPO/docs/domain"
  mk_gloss "$REPO/CONTEXT.md" "Mroot-probe-session"
  mk_gloss "$REPO/docs/domain/CONTEXT.md" "Mdoc-probe-session"
  git init -q "$REPO"
  ( cd "$REPO" && git add -A && git commit -qm fixture )
  git -C "$REPO" worktree add -q "$REPO/.wt" HEAD
  mk_gloss "$REPO/.wt/CONTEXT.md" "Wtroot-probe-session"
  gwt() {
    local want=$1 text=$2
    OUT=$(cd "$REPO/.wt" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "$text" 2>/dev/null)
    if [ "$OUT" = "$want" ]; then ok
    else bad "AC9 worktree [$text] got [$OUT] want [$want]"; fi
  }
  groot() {
    local want=$1 text=$2
    OUT=$(cd "$REPO" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "$text" 2>/dev/null)
    if [ "$OUT" = "$want" ]; then ok
    else bad "AC9 main [$text] got [$OUT] want [$want]"; fi
  }
  gwt none "wtroot-probe-session"
  gwt auth-secrets "mroot-probe-session"
  gwt auth-secrets "mdoc-probe-session"
  groot none "mroot-probe-session"
  groot auth-secrets "mdoc-probe-session"
  DOC="$TMP/docsonly"
  mkdir -p "$DOC/docs/domain"
  mk_gloss "$DOC/docs/domain/CONTEXT.md" "Droot-probe-session"
  git init -q "$DOC"
  ( cd "$DOC" && git add -A && git commit -qm fixture )
  OUT=$(cd "$DOC" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "droot-probe-session" 2>/dev/null)
  if [ "$OUT" = "none" ]; then ok
  else bad "AC9 docs/domain fallback got [$OUT]"; fi
  PLUGIN="$TMP/plugin"
  mkdir -p "$PLUGIN"
  mk_gloss "$PLUGIN/CONTEXT.md" "Plugin-probe-session"
  OUT=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN" env -u TICKET_CLASS_GLOSSARY \
    bash "$CLASS" --text "plugin-probe-session" 2>/dev/null)
  if [ "$OUT" = "auth-secrets" ]; then ok
  else bad "AC9 plugin dir must never be a glossary source, got [$OUT]"; fi
fi

# --- AC11: the carve line ------------------------------------------------
carve_check "ticket-class: carved same-session=1" "Same-session"
carve_check "ticket-class: carved same-session=2 private-key-material=1" \
  "Same-session private-key-material and Same-session"
carve_check "" "session cookie theft"
CAP="$TMP/cap.md"
{
  printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n'
  i=1
  while [ "$i" -le 258 ]; do printf '| aa%s-session | d | a |\n' "$i"; i=$((i + 1)); done
} > "$CAP"
run_class "$CAP" "aa258-session"
if [ "$OUT" = "auth-secrets" ] \
  && [ "$ERR" = "ticket-class: glossary cap 256; using first 256" ]; then ok
else bad "cap over-256: out=[$OUT] err=[$ERR]"; fi
run_class "$CAP" "aa1-session"
if [ "$OUT" = "none" ] && [ "$ERR" = \
  "ticket-class: glossary cap 256; using first 256
ticket-class: carved aa1-session=1" ]; then ok
else bad "cap first-256 used: out=[$OUT] err=[$ERR]"; fi

# --- AC13: portable subset, and 256 KB + 100 rows under 2 s --------------
# argv and the exit-code contract are unchanged by the carve-out.
bash "$CLASS" --text a b >/dev/null 2>&1
if [ "$?" -eq 64 ]; then ok; else bad "usage: --text with two args must exit 64"; fi
bash "$CLASS" --bogus >/dev/null 2>&1
if [ "$?" -eq 64 ]; then ok; else bad "usage: unknown arg must exit 64"; fi
# The scan-tool rc>=2 branch cannot be forced through the CLI (no injectable
# regex or unreadable scan file), so it is pinned on the source text: both
# scans must treat any rc other than 0/1 as a hit.
if [ "$(grep -cF '[ "$rc" -ne 1 ]' "$CLASS")" = "2" ]; then ok
else bad "scan rc>=2 fail-closed branch is not in both scans"; fi
# Every construct is split by an empty quote pair so this file is not itself
# flagged by the run-all-tests --portable filter, while the assembled pattern
# bites on the real text.
BANNED='de''clare -A|de''clare -n|lo''cal -n|ma''pfile|rea''darray'
BANNED="$BANNED|fl''ock|sha''256sum|gt''imeout|ti''meout"
BANNED="$BANNED|grep -''P|touch -''d|-pri''ntf"
BANNED="$BANNED|\$\{[A-Za-z_][A-Za-z0-9_]*,,"
BANNED="$BANNED|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^"
if printf 'x ma''pfile y' | grep -Eq "$BANNED"; then ok
else bad "banned-construct pattern matches nothing (vacuous)"; fi
if grep -Eq "$BANNED" "$CLASS"; then
  bad "ticket-class.sh uses a banned construct: $(grep -En "$BANNED" "$CLASS")"
else
  ok
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
if [ "$SIZE" -ge 262144 ]; then ok; else bad "perf input is only $SIZE bytes"; fi
START=$SECONDS
OUT=$(TICKET_CLASS_GLOSSARY="$G100" bash "$CLASS" < "$BIG" 2>/dev/null)
ELAPSED=$((SECONDS - START))
if [ "$OUT" = "none" ] && [ "$ELAPSED" -lt 2 ]; then ok
else bad "AC13 perf: out=[$OUT] elapsed=${ELAPSED}s"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
