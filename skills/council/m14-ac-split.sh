#!/usr/bin/env bash
#
# council/m14-ac-split.sh — M14 per-AC source parser (SPEC-033 M14(g)/(h),
# SPEC-013 Phase 1 "M14 per-AC split", WP 1-14 interface contract C1).
#
# Reads the AC source at HEAD (git show HEAD:<path>) and writes nothing.
# On success (exit 0) prints one JSON document on stdout:
#   {"ac_source":"<path>","ticket_id":"<id>","acs":[{"id":"A","line":12,"process":false},...]}
# in document order. On a SPEC-033 M14(g) fail-closed case (1-8; case 9,
# the claim budget, is checked by the caller, skills/council/engine.sh) it
# prints no stdout, prints exactly one stderr line "m14-ac-split: <cause>"
# and exits 8. Argv misuse exits 64.
#
# Usage: m14-ac-split.sh <ticket_id> <path>
#   <ticket_id>  the "### <ticket_id>" subsection to read.
#   <path>       relative to the worktree top level, no ".." segment.

set -uo pipefail

SELF="m14-ac-split"

usage() {
  echo "usage: $SELF.sh <ticket_id> <path>" >&2
  exit 64
}

fail() {  # fail <cause>
  echo "$SELF: $1" >&2
  exit 8
}

[ "$#" -eq 2 ] || usage
ticket_id="$1"
ac_path="$2"
[ -n "$ticket_id" ] || usage
[ -n "$ac_path" ] || usage

# ---- Case 1: path format (relative, no ".." segment) -----------------------
case "$ac_path" in
  /*)
    fail "case 1: <path> must be relative, got an absolute path: $ac_path"
    ;;
esac
case "/$ac_path/" in
  */../*)
    fail "case 1: <path> must not hold a '..' segment: $ac_path"
    ;;
esac

toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || fail "case 1: not inside a git worktree"

# ---- Case 1: path absent at HEAD -------------------------------------------
content="$(git -C "$toplevel" show "HEAD:$ac_path" 2>/dev/null)" \
  || fail "case 1: <path> absent at HEAD: $ac_path"

# ---- Parse: section -> subsection -> bullets --------------------------------
# awk emits, on success, one line per AC as "OK\t<id>\t<line>\t<process 0|1>",
# and on failure a single line "ERR\t<case>\t<cause>". Text is used inside
# awk only, for the guard-1 word check, and is never printed.
parsed="$(printf '%s\n' "$content" | awk -v ticket="$ticket_id" '
  function is_blank(s) {
    return (s ~ /^[ \t]*$/)
  }
  function is_continuation(s) {
    # 2+ leading spaces (tabs do not count as a "space" for this rule).
    return (substr(s, 1, 2) == "  ")
  }
  # Parses a bullet line into out["id"], out["process"], out["text"].
  # Returns 1 on a match, 0 otherwise. Mirrors
  # ^- \*\*([A-Z][A-Z0-9]{0,3})\.\*\* (\[process\] )?\S without regex groups
  # (portable across awk implementations).
  function parse_bullet(s, out,   rest, dotpos, id, remainder, afterspace, text, is_process) {
    if (substr(s, 1, 4) != "- **") return 0
    rest = substr(s, 5)
    dotpos = index(rest, ".**")
    if (dotpos <= 0) return 0
    id = substr(rest, 1, dotpos - 1)
    if (id !~ /^[A-Z][A-Z0-9]?[A-Z0-9]?[A-Z0-9]?$/) return 0
    remainder = substr(rest, dotpos + 3)
    if (substr(remainder, 1, 1) != " ") return 0
    afterspace = substr(remainder, 2)
    is_process = 0
    text = afterspace
    if (substr(afterspace, 1, 10) == "[process] ") {
      is_process = 1
      text = substr(afterspace, 11)
    }
    if (length(text) == 0 || substr(text, 1, 1) == " ") return 0
    out["id"] = id
    out["process"] = is_process
    out["text"] = text
    return 1
  }
  BEGIN {
    section_found = 0
    in_section = 0
    subsection_found = 0
    in_subsection = 0
    n = 0
    cur = 0
    errcode = 0
  }
  {
    line = $0
    if (!section_found) {
      if (line == "## Acceptance criteria") {
        section_found = 1
        in_section = 1
      }
      next
    }
    if (in_section && !subsection_found) {
      if (substr(line, 1, 3) == "## ") {
        in_section = 0
        next
      }
      if (line == "### " ticket) {
        subsection_found = 1
        in_subsection = 1
        cur = 0
      }
      next
    }
    if (in_subsection) {
      if (substr(line, 1, 4) == "### " || substr(line, 1, 3) == "## " || line == "---") {
        in_subsection = 0
        next
      }
      if (is_blank(line)) { next }
      delete b
      if (parse_bullet(line, b)) {
        if (b["id"] in seen) {
          errcode = 6
          errmsg = "case 6: duplicate AC id " b["id"]
          exit
        }
        seen[b["id"]] = 1
        n++
        ids[n] = b["id"]
        lines[n] = NR
        proc[n] = b["process"]
        texts[n] = b["text"]
        cur = n
        next
      }
      if (is_continuation(line)) {
        if (cur > 0) { texts[cur] = texts[cur] " " line }
        next
      }
      errcode = 5
      errmsg = "case 5: line " NR " in the \"### " ticket "\" subsection is not blank, not an AC bullet, and not a continuation"
      exit
    }
  }
  END {
    if (errcode != 0) {
      print "ERR\t" errcode "\t" errmsg
      exit 0
    }
    if (!section_found) {
      print "ERR\t2\tcase 2: the \"## Acceptance criteria\" heading is missing"
      exit 0
    }
    if (!subsection_found) {
      print "ERR\t3\tcase 3: the \"### " ticket "\" subsection is missing"
      exit 0
    }
    if (n == 0) {
      print "ERR\t4\tcase 4: the \"### " ticket "\" subsection holds zero AC bullets"
      exit 0
    }
    technical = 0
    guard1_bad = ""
    for (i = 1; i <= n; i++) {
      if (proc[i] == 0) {
        technical++
      } else {
        t = texts[i]
        # Guard 1: case-insensitive whole word, non-alnum boundaries.
        if (t !~ /(^|[^A-Za-z0-9])([Tt][Ee][Ss][Tt][Ss]?|[Ss][Uu][Ii][Tt][Ee][Ss]?|[Rr][Uu][Nn][Nn][Ee][Rr]|[Gg][Aa][Tt][Ee][Ss]?|[Cc][Ii]|[Rr][Ee][Ll][Ee][Aa][Ss][Ee])([^A-Za-z0-9]|$)/) {
          if (guard1_bad == "") { guard1_bad = ids[i] } else { guard1_bad = guard1_bad "," ids[i] }
        }
      }
    }
    if (technical == 0) {
      print "ERR\t7\tcase 7: zero technical ACs remain in the \"### " ticket "\" subsection after [process] ACs are removed"
      exit 0
    }
    if (guard1_bad != "") {
      print "ERR\t8\tcase 8: [process] AC " guard1_bad " fails guard 1 (no test/suite/runner/gate/CI/release word)"
      exit 0
    }
    for (i = 1; i <= n; i++) {
      print "OK\t" ids[i] "\t" lines[i] "\t" proc[i]
    }
  }
')"

# ---- Report the first ERR line, or emit JSON from the OK lines ------------
err_line="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="ERR"{print; exit}')"
if [ -n "$err_line" ]; then
  cause="$(printf '%s\n' "$err_line" | cut -f3-)"
  fail "$cause"
fi

acs_json="$(printf '%s\n' "$parsed" | awk -F'\t' '
  $1=="OK" {
    proc_bool = ($4 == "1") ? "true" : "false"
    printf "{\"id\":\"%s\",\"line\":%s,\"process\":%s}\n", $2, $3, proc_bool
  }
' | jq -s '.')"

jq -n \
  --arg ac_source "$ac_path" \
  --arg ticket_id "$ticket_id" \
  --argjson acs "$acs_json" \
  '{ac_source: $ac_source, ticket_id: $ticket_id, acs: $acs}'
