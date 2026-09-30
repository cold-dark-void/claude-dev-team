#!/usr/bin/env bash
# tests/lib/fence.sh — WP 1-08 C6: shared fenced-bash-block extraction for
# test suites (replaces per-suite awk copies — copy-extract rule). Source
# only, like hermetic.sh: sourcing this file has no side effect (zero
# top-level commands; only function definitions below).
#
#   fence_blocks <md-file> <heading-substring>
#     Prints the bodies of the bash fences (info-string first token "bash",
#     so "bash template" qualifies; "sh" / "json" / "markdown" / no-lang do
#     not) that live between the first heading line CONTAINING
#     <heading-substring> (a literal substring test via awk index() — never
#     a regex, so a "." in the needle is not a wildcard) and the next
#     heading whose level (count of leading '#') is <= the matched
#     heading's level (EOF is a boundary too). Heading lines themselves,
#     and every line inside a non-bash fence, are never printed. Two or
#     more bash fences in the section print in source order, joined by one
#     line holding only "#--fence--". No heading match, or a matched
#     section with zero bash fences -> empty stdout, exit 0.
#
#     "Containing" is a substring test, so a shorter needle can also match
#     a later, unrelated heading (e.g. "## 3." is a substring of
#     "## 3.5 …") — safe only when the FIRST heading in the file containing
#     the needle is the one the caller means. end-state.md's "## 3." /
#     "## 3.5" pair relies on exactly this: §3 precedes §3.5 in the file.
#     Pick a longer, unambiguous needle when that source-order assumption
#     does not hold.
#
#     ATX heading detection (`^#+[ \t]`) only ever fires OUTSIDE a fence —
#     a shell comment such as "# lint-ok: …" at the top of a fence body
#     would otherwise read as a level-1 heading and end the section early.
#     Fences may be indented (list-nested code blocks): both the opening
#     and closing ``` lines are matched with optional leading blanks, and
#     assumed to use exactly three backticks (the sole convention in this
#     repo today).
#
#   fence_nth <md-file> <heading-substring> <n>
#     Body of the n-th (1-based) bash fence in that section (via
#     fence_blocks, split on its "#--fence--" separator). Fewer than n such
#     fences (including a section with none) -> no stdout, return 1.
#
#   md_section <md-file> <heading-substring>
#     Prints the section BODY (excluding the heading line itself) between
#     the first heading line CONTAINING <heading-substring> (same
#     literal-substring, outside-fence-only heading rule as fence_blocks)
#     and the next heading whose level is <= the matched heading's level
#     (EOF is a boundary too). Unlike fence_blocks, every line is printed
#     as-is, including fence delimiter lines and the body of every fence
#     (any language, or none) -- this is a prose extractor, not a
#     bash-only one. No heading match -> empty stdout, exit 0.
#
#   fence_top_level_returns <md-file>
#     Scans the WHOLE file (every bash fence, in or out of any heading
#     section) and prints "<line-number>:<line-text>" for every line inside
#     such a fence whose first whitespace-delimited word is exactly
#     "return". A `return` that is not the first word on its line (e.g.
#     "… || { …; return 1; }") is NOT reported — that shape needs a human
#     look, not this scan. Always exits 0: the scan itself never fails, and
#     an empty result means no top-level return was found by this rule, not
#     that a fence holds none by any rule.
#
#   fence_exec <prefix> <cwd> <fence-text> [NAME=value ...]
#     Runs one fence the way the host does: writes <fence-text> plus a
#     newline to <prefix>.sh, then runs it in a FRESH `bash` process with
#     its cwd set to <cwd>, extra environment NAME=value ... (each passed to
#     `env`), stdin from /dev/null, stdout to <prefix>.out and stderr to
#     <prefix>.err. Sets the global RUN_RC to the exit status (a missing
#     <cwd> is a non-zero RUN_RC, never a run in the wrong directory).
#     Returns 0 after a run; a usage error returns 1. Caller-side setup
#     (placeholder substitution, truncating a stub log, a PATH stub dir)
#     stays in the caller. This is the one core of the three wp-1-12
#     fence suites' run_fence wrappers (copy-extract rule).
#
# bash 3.2 (no declare -A / mapfile / ${v,,}). awk only, no writes. Every
# value crosses into awk via ENVIRON, never `awk -v` (hazard checklist: -v
# assignment backslash-processes \t \n \\ & / — ENVIRON does not).
#
# Callers run under `set -u`: all three functions check their own argc
# before touching $1/$2/$3, so a missing argument is a clean usage error on
# stderr, not an unbound-variable abort in the caller's shell.

fence_blocks() {
  if [ $# -lt 2 ]; then
    echo "fence_blocks: usage: fence_blocks <md-file> <heading-substring>" >&2
    return 1
  fi
  local md="$1" needle="$2"
  [ -r "$md" ] || return 1
  env FENCE_NEEDLE="$needle" awk '
    BEGIN {
      needle = ENVIRON["FENCE_NEEDLE"]
      insection = 0; level = 0; inblock = 0; bashblock = 0; nblocks = 0
    }
    {
      line = $0
      if (inblock) {
        if (line ~ /^[ \t]*```[ \t]*$/) { inblock = 0; next }
        if (bashblock) print
        next
      }
      if (line ~ /^[ \t]*```/) {
        rest = line
        sub(/^[ \t]*```/, "", rest)
        sub(/^[ \t]+/, "", rest)
        bashblock = (insection && rest ~ /^bash([ \t]|$)/)
        inblock = 1
        if (bashblock) {
          nblocks++
          if (nblocks > 1) print "#--fence--"
        }
        next
      }
      ishead = (line ~ /^#+[ \t]/)
      if (ishead) {
        match(line, /^#+/)
        hlevel = RLENGTH
      }
      if (!insection) {
        if (ishead && index(line, needle) > 0) { insection = 1; level = hlevel }
        next
      }
      if (ishead && hlevel <= level) { exit }
      next
    }
  ' "$md"
}

fence_nth() {
  if [ $# -lt 3 ]; then
    echo "fence_nth: usage: fence_nth <md-file> <heading-substring> <n>" >&2
    return 1
  fi
  local md="$1" needle="$2" n="$3" out rc
  # `if var=$(...)` (not a bare assignment) so a not-found exit status
  # never trips the caller's `set -e` before rc is captured (hazard
  # checklist: a failing command substitution assignment is errexit-live).
  if out="$(fence_blocks "$md" "$needle" | env FENCE_N="$n" awk '
    BEGIN { n = ENVIRON["FENCE_N"] + 0; idx = 1; found = 0 }
    $0 == "#--fence--" { idx++; next }
    idx == n { print; found = 1 }
    END { exit (found ? 0 : 1) }
  ')"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out"
}

md_section() {
  if [ $# -lt 2 ]; then
    echo "md_section: usage: md_section <md-file> <heading-substring>" >&2
    return 1
  fi
  local md="$1" needle="$2"
  [ -r "$md" ] || return 1
  env FENCE_NEEDLE="$needle" awk '
    BEGIN {
      needle = ENVIRON["FENCE_NEEDLE"]
      insection = 0; level = 0; inblock = 0
    }
    {
      line = $0
      if (inblock) {
        if (line ~ /^[ \t]*```[ \t]*$/) { inblock = 0 }
        if (insection) print
        next
      }
      if (line ~ /^[ \t]*```/) {
        inblock = 1
        if (insection) print
        next
      }
      ishead = (line ~ /^#+[ \t]/)
      if (ishead) {
        match(line, /^#+/)
        hlevel = RLENGTH
      }
      if (!insection) {
        if (ishead && index(line, needle) > 0) { insection = 1; level = hlevel }
        next
      }
      if (ishead && hlevel <= level) { exit }
      print
    }
  ' "$md"
}

fence_top_level_returns() {
  if [ $# -lt 1 ]; then
    echo "fence_top_level_returns: usage: fence_top_level_returns <md-file>" >&2
    return 1
  fi
  local md="$1"
  [ -r "$md" ] || return 1
  awk '
    BEGIN { inblock = 0; bashblock = 0 }
    {
      line = $0
      if (inblock) {
        if (line ~ /^[ \t]*```[ \t]*$/) { inblock = 0; next }
        if (bashblock && $1 == "return") printf "%d:%s\n", NR, line
        next
      }
      if (line ~ /^[ \t]*```/) {
        rest = line
        sub(/^[ \t]*```/, "", rest)
        sub(/^[ \t]+/, "", rest)
        bashblock = (rest ~ /^bash([ \t]|$)/)
        inblock = 1
        next
      }
    }
  ' "$md"
  return 0
}

fence_exec() {
  if [ $# -lt 3 ]; then
    echo "fence_exec: usage: fence_exec <prefix> <cwd> <fence-text> [NAME=value ...]" >&2
    return 1
  fi
  local prefix="$1" cwd="$2" text="$3"
  shift 3
  printf '%s\n' "$text" > "$prefix.sh" || return 1
  ( cd "$cwd" && env "$@" bash "$prefix.sh" ) < /dev/null > "$prefix.out" 2> "$prefix.err"
  RUN_RC=$?
  return 0
}
