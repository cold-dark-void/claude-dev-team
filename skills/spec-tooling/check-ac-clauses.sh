#!/usr/bin/env bash
# check-ac-clauses.sh — flag technical AC clauses no command can check
# (spec-ac-uncheckable-clause-lint, WARN-grade).
#
# The M14 per-AC gate (SPEC-033 M14(g)) scores every technical AC on the
# evidence its Verify suite produces. A clause that asserts style only —
# WP 1-06 AC H ended "The text follows ASD-STE100." — has no
# command-checkable form: no Verify suite can produce evidence for it, the
# M14 judge scores the AC low (BC7), and the gate halts. A Verify line does
# not clear such a clause — the writer must move the sentence to a
# [process] AC or delete it; the finding names both options.
#
# The heuristic is intentionally CONSERVATIVE: only a documented pattern set
# of style-standard references that no command can check is flagged:
#   - ASD-STE100 (any case; covers "follows ASD-STE100")
#   - Simplified Technical English (any case)
# Style clauses beyond this set are guidance, not findings — the writer rule
# text lives where ACs are written (/orchestrate Step 6:
# skills/orchestrate/steps/06-design.md, and /kickoff:
# skills/kickoff/SKILL.md). Extend the set only with patterns proven to have
# no command-checkable form, to keep false positives near zero.
#
# Scope: the ## Acceptance criteria section, technical AC bullets only — a
# [process] AC is exactly where a style clause belongs. 2-space continuation
# lines join the AC's text before matching. Findings print one stderr line
# each ("AC <id> (line <n>): ..."); clean runs print nothing to stdout.
# Exit codes: 0 = clean, 1 = findings, 64 = usage error.

set -u

usage() {
  echo "usage: check-ac-clauses.sh <specfile>" >&2
  exit 64
}

[ $# -eq 1 ] || usage
specfile="$1"
if [ ! -f "$specfile" ]; then
  echo "check-ac-clauses.sh: no such file: $specfile" >&2
  exit 64
fi

awk -v file="$specfile" '
  function lstrip(s,   i) {
    i = 1
    while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
    return substr(s, i)
  }
  function flush(   low, hit) {
    if (valid && id != "" && !proc && text != "") {
      low = tolower(text)
      hit = ""
      if (index(low, "asd-ste100") > 0) hit = "ASD-STE100"
      else if (index(low, "simplified technical english") > 0) hit = "Simplified Technical English"
      if (hit != "") {
        printf "%s: AC %s (line %d): style-only clause \"%s\" has no command-checkable form — a Verify line does not clear it: move the sentence to a [process] AC or delete it\n", file, id, ac_line, hit > "/dev/stderr"
        n++
      }
    }
  }
  BEGIN {
    in_sec = 0
    valid = 0
    id = ""
    proc = 0
    text = ""
    n = 0
  }
  /^## Acceptance criteria[[:space:]]*$/ { in_sec = 1; next }
  in_sec && /^## / { in_sec = 0 }
  in_sec {
    if ($0 ~ /^- \*\*/) {
      flush()
      valid = 0
      rest = substr($0, 5)
      dot = index(rest, ".**")
      if (dot > 0) {
        cand = substr(rest, 1, dot - 1)
        rem = substr(rest, dot + 3)
        if (cand ~ /^[A-Z][A-Z0-9]?[A-Z0-9]?[A-Z0-9]?$/ && rem ~ /^ /) {
          afterspace = substr(rem, 2)
          proc = 0
          text = afterspace
          if (substr(afterspace, 1, 10) == "[process] ") {
            proc = 1
            text = substr(afterspace, 11)
          }
          if (text != "") {
            valid = 1
            id = cand
            ac_line = NR
          }
        }
      }
    } else if (valid && substr($0, 1, 2) == "  ") {
      # A Verify continuation is a command, not AC prose — it can never
      # clear a style-only clause and must not join the match text.
      if (substr(lstrip($0), 1, 7) != "Verify:") {
        text = text " " $0
      }
    }
  }
  END {
    flush()
    exit n ? 1 : 0
  }
' "$specfile"
