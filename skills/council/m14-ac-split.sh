#!/usr/bin/env bash
#
# council/m14-ac-split.sh — M14 per-AC source parser (SPEC-033 M14(g)/(h),
# SPEC-013 Phase 1 "M14 per-AC split", WP 1-14 interface contract C1).
#
# Reads the AC source at HEAD (git show HEAD:<path>) and writes nothing.
# On success (exit 0) prints one JSON document on stdout:
#   {"ac_source":"<path>","ticket_id":"<id>",
#    "acs":[{"id":"A","line":12,"process":false,"verify":"bash x/test-y.sh"|null},...]}
# in document order. A technical AC MAY hold one "Verify:" continuation
# (SPEC-033 M14(g) WP 1-15); a [process] AC never carries one. On a SPEC-033
# M14(g) fail-closed case (1-8, 10-11; case 9, the claim budget, is checked
# by the caller, skills/council/engine.sh) it prints no stdout, prints
# exactly one stderr line "m14-ac-split: <cause>" (naming every failing AC
# id for cases 6, 8, 10 and 11) and exits 8. Argv misuse exits 64.
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

# ---- Parse: section -> subsection -> bullets -> Verify line ---------------
# awk emits, on success, one line per AC as
# "OK\t<id>\t<line>\t<process 0|1>\t<verify or empty>", and on failure a
# single line "ERR\t<case>\t<cause>". Text is used inside awk only, for the
# guard-1 word check, and is never printed.
parsed="$(printf '%s\n' "$content" | awk -v ticket="$ticket_id" '
  function is_blank(s) {
    return (s ~ /^[ \t]*$/)
  }
  function is_continuation(s) {
    # 2+ leading spaces (tabs do not count as a "space" for this rule).
    return (substr(s, 1, 2) == "  ")
  }
  function lstrip_ws(s,   i) {
    i = 1
    while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
    return substr(s, i)
  }
  function is_verify_attempt(s) {
    # Any line (blank, bullet, continuation or malformed) whose text after
    # ALL leading whitespace (spaces or tabs) starts "Verify:" is a Verify
    # line attempt, and is checked against the strict grammar below rather
    # than falling through to case 5. A "Verify:" that is not at the start
    # after stripping (e.g. inside bullet prose) is not an attempt.
    return (substr(lstrip_ws(s), 1, 7) == "Verify:")
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
    # Exactly 2 leading spaces, then "Verify: bash ", then one or more
    # path/arg tokens from the M14(g) Verify-line charset, single-space
    # separated (SPEC-033 M14(g) WP 1-15).
    verify_re = "^  Verify: bash [A-Za-z0-9._/=:@%+,-]+( [A-Za-z0-9._/=:@%+,-]+)*$"
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
      if (is_verify_attempt(line)) {
        if (line !~ verify_re) {
          errcode = 10
          vid = (cur > 0) ? ids[cur] : "none"
          errmsg = "case 10: AC " vid ": a Verify line breaks the M14(g) grammar rule"
          exit
        }
        if (cur == 0) {
          errcode = 10
          errmsg = "case 10: AC none: a Verify line appears before any AC bullet in the subsection"
          exit
        }
        if (proc[cur] == 1) {
          errcode = 10
          errmsg = "case 10: AC " ids[cur] ": a [process] AC MUST NOT hold a Verify line"
          exit
        }
        if (ver[cur] != "") {
          errcode = 10
          errmsg = "case 10: AC " ids[cur] ": a second Verify line on this AC"
          exit
        }
        # "  Verify: bash ..." -- strip the 2-space indent and "Verify: ".
        ver[cur] = substr(line, 11)
        next
      }
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
        ver[n] = ""
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
      print "OK\t" ids[i] "\t" lines[i] "\t" proc[i] "\t" ver[i]
    }
  }
')"

# ---- Report the first ERR line, or emit JSON from the OK lines ------------
err_line="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="ERR"{print; exit}')"
if [ -n "$err_line" ]; then
  cause="$(printf '%s\n' "$err_line" | cut -f3-)"
  fail "$cause"
fi

# ---- Case 10 (path checks) on every Verify command -------------------------
# The grammar (checked above, in awk) constrains the charset; these checks
# are the M14(g) structural rules on "the first word after bash": no leading
# "/", no ".." segment, a suite basename, never tools/run-all-tests.sh, and
# present at HEAD. Unlike the awk cases above (which fail fast on the first
# bad line), this loop collects every failing AC id before reporting, since
# case 10 "names every failing id" (SPEC-033 M14(g), WP 1-15 IC C1). The
# same pass also collects every AC id with a Verify line, for case 11 below.
bad_ids=""
verify_ids=""
while IFS="$(printf '\t')" read -r tag id line_no proc_flag verify || [ -n "$tag" ]; do
  [ "$tag" = "OK" ] || continue
  [ -n "$verify" ] || continue
  if [ -z "$verify_ids" ]; then verify_ids="$id"; else verify_ids="$verify_ids,$id"; fi
  vpath="$(printf '%s\n' "$verify" | awk '{print $2}')"
  ok=1
  case "$vpath" in
    /*) ok=0 ;;
  esac
  case "/$vpath/" in
    */../*) ok=0 ;;
  esac
  base="$(basename -- "$vpath")"
  case "$base" in
    test.sh|test-*.sh|*-test.sh) ;;
    *) ok=0 ;;
  esac
  [ "$vpath" = "tools/run-all-tests.sh" ] && ok=0
  if [ "$ok" -eq 1 ]; then
    git -C "$toplevel" cat-file -e "HEAD:$vpath" 2>/dev/null || ok=0
  fi
  if [ "$ok" -eq 0 ]; then
    if [ -z "$bad_ids" ]; then bad_ids="$id"; else bad_ids="$bad_ids,$id"; fi
  fi
done <<PARSED_EOF
$parsed
PARSED_EOF
if [ -n "$bad_ids" ]; then
  fail "case 10: AC $bad_ids: the Verify path fails a M14(g) path check (absolute, '..', non-suite basename, tools/run-all-tests.sh, or absent at HEAD)"
fi

# ---- Case 11: at least one Verify line, and the worktree has uncommitted
# changes to tracked files. The split reads HEAD; a verify run reads the
# worktree, so a dirty tracked file would let a verify run see content the
# split never checked. ------------------------------------------------------
if [ -n "$verify_ids" ]; then
  git -C "$toplevel" diff --quiet HEAD -- \
    || fail "case 11: worktree has uncommitted changes to tracked files; verify runs read the worktree (ACs $verify_ids)"
fi

acs_json="$(printf '%s\n' "$parsed" | awk -F'\t' '
  $1=="OK" {
    proc_bool = ($4 == "1") ? "true" : "false"
    if ($5 == "") {
      printf "{\"id\":\"%s\",\"line\":%s,\"process\":%s,\"verify\":null}\n", $2, $3, proc_bool
    } else {
      printf "{\"id\":\"%s\",\"line\":%s,\"process\":%s,\"verify\":\"%s\"}\n", $2, $3, proc_bool, $5
    }
  }
' | jq -s '.')"

jq -n \
  --arg ac_source "$ac_path" \
  --arg ticket_id "$ticket_id" \
  --argjson acs "$acs_json" \
  '{ac_source: $ac_source, ticket_id: $ticket_id, acs: $acs}'
