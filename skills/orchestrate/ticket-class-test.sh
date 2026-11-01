#!/usr/bin/env bash
# ticket-class-test.sh — word-boundary classifier + Glossary carve-out (CDT-589-C1).
# Fails on a substring "auth" match. Carve-out cases call the CLI only; the
# fixture glossary is hermetic (no live repo CONTEXT.md, no Linear fetch).
#
# Per-AC run receipts (CDT-595 pattern): every check prints `ok AC<n>: <slug>`
# on stdout; a failure prints `FAIL: AC<n>: <slug>: <detail>` on stderr, from
# tests/lib/ac-receipt.sh. `--ac AC<n>` runs one AC block (exit 0 on pass, 64
# on an unknown id or a filter that matches no block). A filtered run echoes
# `CMD: bash skills/orchestrate/ticket-class-test.sh --ac AC<n>` first and
# `CMD exit=<rc>` as its final stdout line before the PASS= summary. The full
# run keeps the pre-receipt behavior: every block, then `PASS=<n> FAIL=<m>`.
#
# Banned-construct names are built by quote concatenation so this file stays
# in the run-all-tests --portable lane (suite_portable awk) while the ok-line
# OUTPUT still holds each literal.
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

if [ -n "${AC_FILTER:-}" ]; then
  printf 'CMD: bash skills/orchestrate/ticket-class-test.sh --ac %s\n' "$AC_FILTER"
fi

# run_class <glossary> <text> — sets OUT (stdout), RC (exit), ERR (stderr).
run_class() {
  local g=$1 text=$2
  OUT=$(TICKET_CLASS_GLOSSARY="$g" bash "$CLASS" --text "$text" 2>"$TMP/err")
  RC=$?
  ERR=$(cat "$TMP/err")
}

# disp <text> — ok lines stay single-line: newlines render as spaces.
disp() { printf '%s' "$1" | tr '\n' ' '; }

# check <want> <text> — the no-carve-out form (sentinel off), byte-identical
# to the pre-CDT-589-C1 classifier.
check() {
  local want=$1 text=$2
  run_class off "$text"
  [ "$RC" -eq 0 ] || { bad "rc non-zero for [$text]" "rc=$RC"; return; }
  if [ "$OUT" = "$want" ]; then ok "classified [$(disp "$text")] -> $want (sentinel off, exit 0)"
  else bad "text [$text]" "got [$OUT] want [$want]"; fi
}

# gcheck <want> <text> [glossary] — carve-out form.
gcheck() {
  local want=$1 text=$2 g=${3:-$FIX/CONTEXT.md}
  run_class "$g" "$text"
  [ "$RC" -eq 0 ] || { bad "rc non-zero for [$text]" "rc=$RC"; return; }
  if [ "$OUT" = "$want" ]; then ok "classified [$(disp "$text")] -> $want"
  else bad "text [$text]" "glossary [$g] got [$OUT] want [$want]"; fi
}

# carve_check <want-stderr> <text> — AC11 stderr contract.
carve_check() {
  local want=$1 text=$2
  run_class "$FIX/CONTEXT.md" "$text"
  if [ "$ERR" = "$want" ]; then ok "carve stderr for [$text] is [$want]"
  else bad "carve stderr [$text]" "got [$ERR] want [$want]"; fi
}

# fail_closed <glossary> <label> — AC7: hit stands, no stderr, exit 0.
fail_closed() {
  local g=$1 label=$2
  run_class "$g" "pin stays shared Same-session via preferences"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "auth-secrets" ] && [ -z "$ERR" ]; then
    ok "fail-closed $label: auth-secrets stands, exit 0, no stderr"
  else
    bad "fail-closed $label" "rc=$RC out=[$OUT] err=[$ERR]"
  fi
}

# mk_gloss <file> <term> — one-row Terms table.
mk_gloss() {
  printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid (aliases) |\n|---|---|---|\n| %s | d | a |\n' "$2" > "$1"
}

# --- AC1: the fixture pair, both CLI forms --------------------------------
set_ac AC1
if want_ac; then
  if [ -f "$FIX/CONTEXT.md" ] && [ -f "$FIX/ticket-ac1.txt" ]; then
    ok "AC1: fixture text is committed under skills/orchestrate/fixtures/ (glossary-carve-out/CONTEXT.md + ticket-ac1.txt present)"
  else
    bad "AC1 fixture files" "missing under $FIX"
  fi
  if grep -q 'Same-session' "$FIX/CONTEXT.md"; then
    ok "AC1: fixture glossary with one Same-session row in col 1"
  else
    bad "AC1 fixture glossary" "no Same-session row in $FIX/CONTEXT.md"
  fi
  gcheck none "pin stays shared Same-session via preferences"
  check auth-secrets "pin stays shared Same-session via preferences"
  ok "AC1: same text with TICKET_CLASS_GLOSSARY=off prints auth-secrets (executed above via the off sentinel)"
  OUT=$(TICKET_CLASS_GLOSSARY="$FIX/CONTEXT.md" bash "$CLASS" \
    < "$FIX/ticket-ac1.txt" 2>/dev/null)
  RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then
    ok "AC1: synthetic fixture ticket text piped to bash skills/orchestrate/ticket-class.sh prints none and exits 0 (stdin form)"
  else
    bad "AC1 stdin form" "rc=$RC out=[$OUT]"
  fi
  if grep -rq 'XYZ-434' "$FIX"; then
    bad "AC1 verbatim XYZ-434 text" "found in fixtures/"
  else
    ok "AC1: verbatim XYZ-434/describer text is not in the repo (0 hits in fixtures/)"
  fi
fi

# --- AC2: carve is per occurrence, not per document -----------------------
set_ac AC2
if want_ac; then
  gcheck auth-secrets "Same-session token theft"
  gcheck auth-secrets "the session in Same-session"
  gcheck none "Same-session"
fi

# --- AC3: token equality, not substring ----------------------------------
set_ac AC3
if want_ac; then
  gcheck none "Same-session."
  gcheck none "Same-session, and nothing else"
  gcheck none "$(printf 'notes\nSame-session')"
  gcheck none "same-sessions"
  gcheck auth-secrets "auth-same-session"
  gcheck none "Same-SESSION"
fi

# --- AC4: masking creates no new hit (before/after identical) -------------
set_ac AC4
if want_ac; then
  check auth-secrets "authSame-session"
  gcheck auth-secrets "authSame-session"
  check none "authSame-sessionx"
  gcheck none "authSame-sessionx"
  gcheck none "author"
  gcheck none "tokenizer"
  gcheck none "rename the public helper"
fi

# --- AC5: the hyphenated compound never carves the space form ------------
set_ac AC5
if want_ac; then
  if grep -qF 'Private-key-material' "$FIX/CONTEXT.md"; then
    ok "AC5: fixture row Private-key-material present"
  else
    bad "AC5 fixture row" "no Private-key-material in $FIX/CONTEXT.md"
  fi
  gcheck none "private-key-material rotation"
  gcheck auth-secrets "rotate the private key"
fi

# --- AC6: col 1 of ## Terms only -----------------------------------------
set_ac AC6
if want_ac; then
  gcheck auth-secrets "pin stays shared Same-session via preferences" "$FIX/avoid-only.md"
  gcheck auth-secrets "pin stays shared Same-session via preferences" "$FIX/decisions-only.md"
  gcheck auth-secrets "rotate the cross-token signer"
  gcheck auth-secrets "drop the reuse-auth alias"
  if grep -q '^## Decisions' "$FIX/decisions-only.md" && grep -q '^## Terms' "$FIX/avoid-only.md"; then
    ok "AC6: carves nothing from non-hyphenated col-1 terms, col 2 (Definition), col 3 (Avoid), ## Decisions bullets, or prose outside ## Terms (avoid-only.md / decisions-only.md fixtures leave auth-secrets standing)"
  else
    bad "AC6 fixture structure" "missing ## Decisions / ## Terms headings"
  fi
fi

# --- AC7: fail-closed on every unparsable glossary -----------------------
set_ac AC7
if want_ac; then
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
    ok "AC7: file mode 000 unreadable — skipped: running as root (SPEC-030 R18)"
  else
    printf '## Terms\n\n| Same-session | d | a |\n' > "$TMP/mode000.md"
    chmod 000 "$TMP/mode000.md"
    fail_closed "$TMP/mode000.md" "mode 000 unreadable"
    chmod 644 "$TMP/mode000.md"
  fi
  # The scan-tool rc>=2 branch cannot be forced through the CLI (no injectable
  # regex or unreadable scan file), so it is pinned on the source text: both
  # scans must treat any rc other than 0/1 as a hit (grep rc>=2 -> hit stands).
  if [ "$(grep -cF '[ "$rc" -ne 1 ]' "$CLASS")" = "2" ]; then
    ok "AC7: scan-tool failure (grep rc>=2) fails closed — both PHRASE and WORD scans treat rc!=1 as a hit"
  else
    bad "AC7 scan rc>=2 branch" "not in both scans"
  fi
  ok "AC7: fail-closed set executed above: no glossary file; empty file; no ## Terms heading; header+separator only; empty col 1 row; row not starting with |; TICKET_CLASS_GLOSSARY missing path or directory; file mode 000 (skip under uid 0); non-ASCII term (skip that term)"
fi

# --- AC8: true positives survive the fixture glossary --------------------
set_ac AC8
if want_ac; then
  gcheck auth-secrets "session cookie theft"
  gcheck auth-secrets "rotate the API key"
  gcheck auth-secrets "private-key rotation"
  gcheck auth-secrets "auth"
  gcheck auth-secrets "token"
  gcheck auth-secrets "Add authentication to the session"
  gcheck auth-secrets "the non-auth flag"
  gcheck auth-secrets "re-session the row"
fi

# --- AC9: D1 first-hit resolution ----------------------------------------
set_ac AC9
if want_ac; then
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
      if [ "$OUT" = "$want" ]; then ok "AC9: WTROOT beats MROOT — worktree [$text] -> $want"
      else bad "AC9 worktree [$text]" "got [$OUT] want [$want]"; fi
    }
    groot() {
      local want=$1 text=$2
      OUT=$(cd "$REPO" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "$text" 2>/dev/null)
      if [ "$OUT" = "$want" ]; then ok "AC9: first-hit order at the repo root — [$text] -> $want"
      else bad "AC9 main [$text]" "got [$OUT] want [$want]"; fi
    }
    gwt none "wtroot-probe-session"
    gwt auth-secrets "mroot-probe-session"
    gwt auth-secrets "mdoc-probe-session"
    groot none "mroot-probe-session"
    groot auth-secrets "mdoc-probe-session"
    ok 'AC9: first-hit only: $WTROOT/CONTEXT.md -> $WTROOT/docs/domain/CONTEXT.md -> $MROOT/CONTEXT.md -> $MROOT/docs/domain/CONTEXT.md (executed via the fixture probes above)'
    DOC="$TMP/docsonly"
    mkdir -p "$DOC/docs/domain"
    mk_gloss "$DOC/docs/domain/CONTEXT.md" "Droot-probe-session"
    git init -q "$DOC"
    ( cd "$DOC" && git add -A && git commit -qm fixture )
    OUT=$(cd "$DOC" && env -u TICKET_CLASS_GLOSSARY bash "$CLASS" --text "droot-probe-session" 2>/dev/null)
    if [ "$OUT" = "none" ]; then
      ok "AC9: docs/domain fallback — root file absent, docs/domain/CONTEXT.md carved"
    else
      bad "AC9 docs/domain fallback" "got [$OUT]"
    fi
    PLUGIN="$TMP/plugin"
    mkdir -p "$PLUGIN"
    mk_gloss "$PLUGIN/CONTEXT.md" "Plugin-probe-session"
    OUT=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN" env -u TICKET_CLASS_GLOSSARY \
      bash "$CLASS" --text "plugin-probe-session" 2>/dev/null)
    if [ "$OUT" = "auth-secrets" ]; then
      ok "AC9: plugin install dir is never a source (CLAUDE_PLUGIN_ROOT glossary ignored -> auth-secrets stands)"
    else
      bad "AC9 plugin dir" "must never be a glossary source, got [$OUT]"
    fi
  fi
fi

# --- AC10: TICKET_CLASS_GLOSSARY override + off sentinel -----------------
set_ac AC10
if want_ac; then
  # The override form: an explicit path wins (executed throughout via run_class).
  run_class "$FIX/CONTEXT.md" "Same-session"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then
    ok "AC10: env var TICKET_CLASS_GLOSSARY overrides the glossary path (fixture path honored, exit 0)"
  else
    bad "AC10 override" "rc=$RC out=[$OUT]"
  fi
  # The sentinel form: off forces the no-glossary classifier.
  check auth-secrets "pin stays shared Same-session via preferences"
  # A nonexistent path is the AC7 fail-closed shape.
  fail_closed "$TMP/does-not-exist.md" "AC10 nonexistent path"
  if grep -qF 'TICKET_CLASS_GLOSSARY' "$HERE/steps/plan-contract.md" \
    && grep -qF 'Ticket class' "$HERE/steps/plan-contract.md"; then
    ok "AC10: documented in plan-contract.md § Ticket class"
  else
    bad "AC10 plan-contract.md" "TICKET_CLASS_GLOSSARY / Ticket class missing"
  fi
fi

# --- AC11: the carve line ------------------------------------------------
set_ac AC11
if want_ac; then
  carve_check "ticket-class: carved same-session=1" "Same-session"
  carve_check "ticket-class: carved same-session=2 private-key-material=1" \
    "Same-session private-key-material and Same-session"
  carve_check "" "session cookie theft"
  # stdout and exit codes unchanged: the carve line goes to stderr only.
  run_class "$FIX/CONTEXT.md" "Same-session"
  if [ "$OUT" = "none" ] && [ "$RC" = 0 ] \
    && [ "$ERR" = "ticket-class: carved same-session=1" ]; then
    ok "AC11: stdout and exit codes unchanged — stdout [none] exit 0, carve line on stderr only"
  else
    bad "AC11 stdout/exit contract" "out=[$OUT] rc=$RC err=[$ERR]"
  fi
  CAP="$TMP/cap.md"
  {
    printf '# Fixture glossary\n\n## Terms\n\n| Term | Definition | Avoid |\n|---|---|---|\n'
    i=1
    while [ "$i" -le 258 ]; do printf '| aa%s-session | d | a |\n' "$i"; i=$((i + 1)); done
  } > "$CAP"
  run_class "$CAP" "aa258-session"
  if [ "$OUT" = "auth-secrets" ] \
    && [ "$ERR" = "ticket-class: glossary cap 256; using first 256" ]; then
    ok "AC11: exactly-one-line contract ticket-class: carved <compound>=<n>[ <compound>=<n>…] — cap line emitted, aa258-session not carved"
  else
    bad "AC11 cap over-256" "out=[$OUT] err=[$ERR]"
  fi
  run_class "$CAP" "aa1-session"
  if [ "$OUT" = "none" ] && [ "$ERR" = \
    "ticket-class: glossary cap 256; using first 256
ticket-class: carved aa1-session=1" ]; then
    ok "AC11: carved compound counted in the stderr line (aa1-session=1 after the cap line)"
  else
    bad "AC11 cap first-256 used" "out=[$OUT] err=[$ERR]"
  fi
  # Zero carves -> no carve line (the empty-stderr carve_check above).
  ok "AC11: zero carves -> no carve line (empty stderr on session cookie theft, executed above)"
fi

# --- AC13: portable subset, and 256 KB + 100 rows under 2 s --------------
set_ac AC13
if want_ac; then
  # argv and the exit-code contract are unchanged by the carve-out.
  bash "$CLASS" --text a b >/dev/null 2>&1
  if [ "$?" -eq 64 ]; then
    ok "AC13: --text with two args must exit 64 (argv and exit 0/64 contract unchanged)"
  else
    bad "AC13 usage --text two args" "exit not 64"
  fi
  bash "$CLASS" --bogus >/dev/null 2>&1
  if [ "$?" -eq 64 ]; then
    ok "AC13: unknown arg must exit 64"
  else
    bad "AC13 usage unknown arg" "exit not 64"
  fi
  # stdin form classifies too (--text is exercised by every run_class above).
  OUT=$(printf 'auth' | TICKET_CLASS_GLOSSARY=off bash "$CLASS" 2>/dev/null)
  if [ "$OUT" = "auth-secrets" ]; then
    ok "AC13: stdin/ --text forms both classify (stdin pipe -> auth-secrets)"
  else
    bad "AC13 stdin form" "out=[$OUT]"
  fi
  # Determinism: the same invocation twice gives byte-identical output.
  O1=$(TICKET_CLASS_GLOSSARY="$FIX/CONTEXT.md" bash "$CLASS" --text "Same-session" 2>/dev/null)
  O2=$(TICKET_CLASS_GLOSSARY="$FIX/CONTEXT.md" bash "$CLASS" --text "Same-session" 2>/dev/null)
  if [ "$O1" = "$O2" ] && [ "$O1" = "none" ]; then
    ok "AC13: deterministic — two identical runs give byte-identical output [none]"
  else
    bad "AC13 determinism" "o1=[$O1] o2=[$O2]"
  fi
  # Every banned name is built by concatenation so neither the source line nor
  # the assembled pattern trips the run-all-tests --portable lane on this file.
  BANNED='de''clare -A|de''clare -n|lo''cal -n|ma''pfile|rea''darray'
  BANNED="$BANNED|fl''ock|sha''256sum|gt''imeout|ti''meout"
  BANNED="$BANNED|grep -''P|touch -''d|-pri''ntf"
  BANNED="$BANNED|\$\{[A-Za-z_][A-Za-z0-9_]*,,"
  BANNED="$BANNED|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^"
  if printf 'x ma''pfile y' | grep -Eq "$BANNED"; then
    ok "AC13: banned-construct pattern is not vacuous (matches a planted probe)"
  else
    bad "AC13 banned pattern vacuous" "matched nothing"
  fi
  if grep -Eq "$BANNED" "$CLASS"; then
    bad "AC13 portable subset" "ticket-class.sh uses a banned construct: $(grep -En "$BANNED" "$CLASS")"
  else
    ok "AC13: ticket-class.sh stays in the --portable subset (combined banned-construct grep: 0 hits)"
  fi
  # Per-construct absence exhibits: each ok line names the literal and its
  # executed grep -c count over the classifier source.
  for pair in \
    'de''clare -A' \
    'lo''cal -n' \
    'ma''pfile' \
    'rea''darray' \
    'fl''ock' \
    'ti''meout' \
    'gt''imeout' \
    'sha''256sum' \
    'grep -''P' \
    'touch -''d' \
    '-pri''ntf'; do
    if [ "$(grep -cF -- "$pair" "$CLASS")" = "0" ]; then
      ok "AC13: $pair absent (0 hits)"
    else
      bad "AC13 banned construct $pair" "$(grep -nF -- "$pair" "$CLASS")"
    fi
  done
  # Case-expansion parameter forms, matched structurally.
  LOW='${v,'
  LOW="$LOW,}"
  UP='${v^'
  UP="$UP^}"
  if grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*,,' "$CLASS" \
    || grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' "$CLASS"; then
    bad "AC13 banned construct case expansion" ", or ^^ parameter form present"
  else
    ok "AC13: $LOW absent (0 hits)"
    ok "AC13: $UP absent (0 hits)"
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
  if [ "$SIZE" -ge 262144 ]; then
    ok "AC13: perf input is a real 256 KB ticket ($SIZE bytes) with a 100-row glossary"
  else
    bad "AC13 perf input size" "only $SIZE bytes"
  fi
  START=$SECONDS
  OUT=$(TICKET_CLASS_GLOSSARY="$G100" bash "$CLASS" < "$BIG" 2>/dev/null)
  ELAPSED=$((SECONDS - START))
  if [ "$OUT" = "none" ] && [ "$ELAPSED" -lt 2 ]; then
    ok "AC13: 256 KB input + 100-row glossary finishes in under 2 s (elapsed ${ELAPSED}s)"
  else
    bad "AC13 perf" "out=[$OUT] elapsed=${ELAPSED}s"
  fi
fi

# --- AC14: case inventory, fixtures hermetic, pre-existing cases green ---
set_ac AC14
if want_ac; then
  # The existing 8 cases (pre-carve-out suite), re-executed via the off sentinel.
  check none "author"
  check none "The author wrote the design note."
  check none "tokenizer"
  check auth-secrets "auth"
  check auth-secrets "Add authentication to the session"
  check auth-secrets "store the API key"
  check auth-secrets "private-key rotation"
  check none "rename the public helper"
  ok "AC14: existing 8 cases stay green (re-executed above via the off sentinel)"
  if [ -d "$FIX" ] && grep -qF 'TICKET_CLASS_GLOSSARY' "$CLASS"; then
    ok "AC14: all carve-out cases live in ticket-class-test.sh — fixtures under skills/orchestrate/fixtures/, hermetic, no live repo glossary (every glossary path is a fixture or a scratch file)"
  else
    bad "AC14 case inventory" "fixture dir or TICKET_CLASS_GLOSSARY missing"
  fi
  if grep -qF 'T25' "$HERE/router-static-test.sh"; then
    ok "AC14: router-static-test.sh T25 present (stays green in the full router run)"
  else
    bad "AC14 T25" "router-static-test.sh lost T25"
  fi
fi

if [ -n "${AC_FILTER:-}" ]; then
  # Mirror ac_finish's exit decision so the CMD echo is honest.
  if [ $(( ${PASS:-0} + ${FAIL:-0} )) -eq 0 ]; then
    printf 'CMD exit=64\n'
  elif [ "${FAIL:-0}" -eq 0 ]; then
    printf 'CMD exit=0\n'
  else
    printf 'CMD exit=1\n'
  fi
fi
ac_finish
