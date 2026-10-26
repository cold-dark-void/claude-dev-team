#!/usr/bin/env bash
# ticket-class.sh — word-boundary auth-secrets classifier (CDT-278 T-06design).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   ticket-class.sh              # read the ticket text on stdin
#   ticket-class.sh --text TEXT  # TEXT is one argument
#
# stdout: auth-secrets | none
# A substring hit is not enough. "author" does not match "auth".
# "tokenizer" does not match "token".
#
# Glossary carve-out (CDT-589-C1, SPEC-009): before the PHRASE-then-WORD scan,
# every maximal [A-Za-z0-9-] token that lowercases to a hyphenated "## Terms"
# column-1 compound in the project domain glossary is masked with x
# (length-preserving), so a keyword inside a listed term is not a hit.
# TICKET_CLASS_GLOSSARY names the glossary file; the sentinel "off" disables
# the carve-out. Any missing, unreadable, directory or unparsable glossary is
# fail-closed: no carve-out, byte-identical output, exit 0.
#
# stderr: one line "ticket-class: carved <compound>=<n>[ <compound>=<n>…]"
# (Terms order, counts > 0) when at least one occurrence was masked, plus one
# line "ticket-class: glossary cap 256; using first 256" when the glossary
# lists more than 256 compounds. stdout and the exit codes are unchanged.
#
# Exit: 0 classified, 64 usage.

set -euo pipefail

if [ "${1:-}" = "--text" ]; then
  [ $# -eq 2 ] || { echo "usage: ticket-class.sh [--text TEXT]" >&2; exit 64; }
  TEXT=$2
elif [ $# -eq 0 ]; then
  TEXT=$(cat)
else
  echo "usage: ticket-class.sh [--text TEXT]" >&2
  exit 64
fi

LOW=$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')

# --- Glossary carve-out (CDT-589-C1, SPEC-009) ------------------------------

WORK=""
if WORK=$(mktemp -d "${TMPDIR:-/tmp}/ticket-class.XXXXXX" 2>/dev/null); then
  trap 'rm -rf "$WORK"' EXIT
fi

# glossary_path — print the glossary file to carve from, nothing when there is
# no glossary. D1 first hit: $WTROOT/CONTEXT.md, $WTROOT/docs/domain/CONTEXT.md,
# $MROOT/CONTEXT.md, $MROOT/docs/domain/CONTEXT.md. Never a plugin install dir
# (PDH, CLAUDE_PLUGIN_ROOT, marketplace clone, cache).
glossary_path() {
  local v p wtroot mroot gc
  v=${TICKET_CLASS_GLOSSARY:-}
  [ "$v" = "off" ] && return 1
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  wtroot=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  gc=$(git rev-parse --git-common-dir 2>/dev/null) || gc=""
  if [ -n "$gc" ]; then mroot=$(cd "$(dirname "$gc")" && pwd); else mroot=$(pwd); fi
  for p in "$wtroot/CONTEXT.md" "$wtroot/docs/domain/CONTEXT.md" \
           "$mroot/CONTEXT.md" "$mroot/docs/domain/CONTEXT.md"; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# d4_keep <compound> — D4 anti-gaming floor. Return 0 (keep) unless EVERY
# hyphen segment is a classifier keyword (the WORD list plus the PHRASE
# segments api, key, private). Disabling D4 = make this function return 0.
d4_keep() {
  local compound=$1 seg all_keyword=0
  local IFS=-
  for seg in $compound; do
    case $seg in
      authentication|authorization|apikey|oauth|oidc|jwt|session|credential|\
secret|token|password|auth|pii|ssn|csrf|api|key|private) ;;
      *) all_keyword=1; break ;;
    esac
  done
  [ "$all_keyword" -eq 1 ]
}

# glossary_terms <file> — print candidate col-1 compounds, Terms-table order,
# duplicates removed. Column 1 only; tokens split on whitespace; markdown
# wrappers stripped; hyphenated ASCII tokens only.
glossary_terms() {
  awk '
    /^##[ \t]+Terms[ \t]*$/ { interm = 1; next }
    interm && /^##[ \t]/    { interm = 0 }
    !interm                 { next }
    /^\|/ {
      rest = substr($0, 2)
      p = index(rest, "|")
      cell = (p > 0) ? substr(rest, 1, p - 1) : rest
      m = split(cell, parts, "[ \t]+")
      for (i = 1; i <= m; i++) {
        t = parts[i]
        gsub(/[`*_]/, "", t)
        t = tolower(t)
        if (index(t, "-") == 0) continue
        if (t !~ /^[a-z0-9-]+$/) continue   # non-ASCII, stray punctuation
        if (t !~ /[a-z0-9]/) continue       # |---| separator row
        if (t in seen) continue
        seen[t] = 1
        print t
      }
    }
  ' "$1"
}

GLOSS=$(glossary_path) || GLOSS=""
[ -n "$WORK" ] || GLOSS=""   # no temp dir → fail-closed: no carve-out
if [ -n "$GLOSS" ] && [ ! -f "$GLOSS" ]; then
  GLOSS=""                   # missing path or directory → no carve-out
fi
if [ -n "$GLOSS" ]; then
  # The grep is the fail-closed gate: rc 1 = no Terms heading, rc >= 2 = the
  # scan tool failed (unreadable, mode 000). Both mean no carve-out, and the
  # classifier output stays byte-identical to the no-glossary path.
  hrc=0
  grep -Eq '^##[[:space:]]+Terms([[:space:]]|$)' "$GLOSS" 2>/dev/null || hrc=$?
  if [ "$hrc" -ne 0 ]; then
    GLOSS=""
  fi
fi

COMPS=""
SCANFILE=""
if [ -n "$GLOSS" ]; then
  n=0
  capped=0
  while IFS= read -r c || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    d4_keep "$c" || continue
    if [ "$n" -ge 256 ]; then capped=1; continue; fi
    n=$((n + 1))
    COMPS="$COMPS$c
"
  done < <(glossary_terms "$GLOSS")
  if [ "$capped" -eq 1 ]; then
    echo "ticket-class: glossary cap 256; using first 256" >&2 || true
  fi
fi

if [ -n "$COMPS" ] && printf '%s' "$COMPS" > "$WORK/comps" \
  && printf '%s\n' "$LOW" > "$WORK/low"; then
  # mask.awk — replace every maximal [A-Za-z0-9-] token equal to a compound
  # with x per char (length-preserving, so no new boundary is created). The
  # writes sit in the condition so a full disk skips the carve-out instead of
  # aborting the classifier with no stdout.
  arc=0
  awk -v CF="$WORK/carve" '
    BEGIN { pad = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; plen = length(pad) }
    function fill(m,   s, k) {
      s = ""
      while (m > 0) { k = (m > plen ? plen : m); s = s substr(pad, 1, k); m -= k }
      return s
    }
    NR == FNR {
      if ($0 != "" && !($0 in have)) { n++; ord[n] = $0; have[$0] = 1; cnt[$0] = 0 }
      next
    }
    {
      line = $0
      len = length(line)
      out = ""
      tok = ""
      for (i = 1; i <= len + 1; i++) {
        ch = (i <= len) ? substr(line, i, 1) : " "
        if (ch ~ /[A-Za-z0-9-]/) { tok = tok ch; continue }
        if (tok != "") {
          if (tok in have) { cnt[tok]++; out = out fill(length(tok)) }
          else out = out tok
          tok = ""
        }
        out = out ch
      }
      print out
    }
    END {
      for (i = 1; i <= n; i++)
        if (cnt[ord[i]] > 0) printf "%s\t%d\n", ord[i], cnt[ord[i]] > CF
    }
  ' "$WORK/comps" "$WORK/low" > "$WORK/masked" || arc=$?

  # A mask failure is fail-closed: scan the unmasked text, no carve line.
  if [ "$arc" -eq 0 ] && [ -s "$WORK/masked" ]; then
    carve=""
    if [ -s "$WORK/carve" ]; then
      while IFS="	" read -r comp count || [ -n "${comp:-}" ]; do
        [ -n "${comp:-}" ] || continue
        carve="$carve${carve:+ }$comp=$count"
      done < "$WORK/carve"
      if [ -n "$carve" ]; then
        printf 'ticket-class: carved %s\n' "$carve" >&2 || true
      fi
    fi
    SCANFILE="$WORK/masked"
  fi
fi

if [ -z "$SCANFILE" ] && [ -n "$WORK" ] && printf '%s\n' "$LOW" > "$WORK/scan"; then
  SCANFILE="$WORK/scan"
fi

# scan REGEX — 0 hit, 1 miss, >=2 scan-tool failure. The caller turns a
# failure into auth-secrets (fail-closed toward a hit).
scan() {
  local rc=0
  if [ -n "$SCANFILE" ]; then
    grep -Eq "$1" "$SCANFILE" || rc=$?
  else
    printf '%s' "$LOW" | grep -Eq "$1" || rc=$?
  fi
  return $rc
}

# Multi-word phrases, then single tokens. Longer tokens are listed before
# "auth" so the alternation is obvious; the boundary still rejects "author".
PHRASE='(^|[^[:alnum:]_])(api[- ]key|private[- ]key)([^[:alnum:]_]|$)'
WORD='(^|[^[:alnum:]_])(authentication|authorization|apikey|oauth|oidc|jwt|session|credential|secret|token|password|auth|pii|ssn|csrf)([^[:alnum:]_]|$)'

rc=0
scan "$PHRASE" || rc=$?
if [ "$rc" -ne 1 ]; then
  # 0 = hit; >= 2 = the scan tool failed → fail-closed toward a hit.
  printf '%s\n' auth-secrets
  exit 0
fi
rc=0
scan "$WORD" || rc=$?
if [ "$rc" -ne 1 ]; then
  printf '%s\n' auth-secrets
  exit 0
fi
printf '%s\n' none
exit 0
