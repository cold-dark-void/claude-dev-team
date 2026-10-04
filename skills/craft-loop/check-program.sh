#!/usr/bin/env bash
# check-program.sh — mechanical validator for /craft-loop programs (rv-w3-28).
#
# Checks what SPEC-020 makes machine-checkable about a program file:
#   frontmatter (name/target/cadence/status/created), the 6 required section
#   headings, the default # Never guardrails (or an explicit `- loosened:`
#   record), journal-read as the first and journal-append as the last
#   procedure step, and the `## Iteration` entry schema.
# Checklist item 6 (unit grain) stays human judgment and is NOT checked here.
#
# Usage:
#   check-program.sh <program.md>
#   echo "$draft" > "$tmp" && check-program.sh "$tmp"   # craft-mode drafts
#
# stdout: silence on success (or with --quiet), one OK line otherwise.
# stderr: one violation per line.
# Exit:   0 valid · 1 violations · 64 usage

set -uo pipefail

usage() {
  echo "usage: check-program.sh [--quiet] <program.md>" >&2
  exit 64
}

QUIET=0
if [ "${1:-}" = "--quiet" ]; then
  QUIET=1
  shift
fi
[ $# -eq 1 ] || usage
PROG=$1
[ -f "$PROG" ] || { echo "check-program: no such file: $PROG" >&2; exit 64; }

VIOLATIONS=0
viol() {
  VIOLATIONS=$((VIOLATIONS + 1))
  echo "check-program: $1" >&2
}

# ---- A. Frontmatter ----------------------------------------------------------
FM=$(awk 'BEGIN{s=0} /^---$/{s++; next} s==1{print} s>=2{exit}' "$PROG")
if [ -z "$FM" ]; then
  viol "no YAML frontmatter block (--- ... ---)"
else
  fm_has() { printf '%s\n' "$FM" | grep -qE "^$1:"; }
  fm_val() { printf '%s\n' "$FM" | sed -n "s/^$1:[[:space:]]*//p" | head -1; }

  fm_has name || viol "frontmatter missing name:"
  NAME=$(fm_val name)
  case "$NAME" in
    ''|*[!a-z0-9-]*|*--) viol "frontmatter name is not kebab-case: '$NAME'" ;;
  esac

  TARGET=$(fm_val target)
  case "$TARGET" in
    loop|goal) ;;
    *) viol "frontmatter target must be loop or goal, got '$TARGET'" ;;
  esac

  CADENCE=$(fm_val cadence)
  [ -n "$CADENCE" ] || viol "frontmatter missing cadence:"

  STATUS=$(fm_val status)
  case "$STATUS" in
    ready|retired) ;;
    *) viol "frontmatter status must be ready or retired, got '$STATUS'" ;;
  esac

  CREATED=$(fm_val created)
  case "$CREATED" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) viol "frontmatter created must be YYYY-MM-DD, got '$CREATED'" ;;
  esac
fi

# ---- B. Six required section headings ----------------------------------------
section_body() { # section_body <heading-text> -> body lines
  awk -v h="$1" '
    $0 == "# " h { on=1; next }
    on && /^# / { exit }
    on { print }
  ' "$PROG"
}
for h in "Objective" "Every iteration" "Stop when" "Never" "When blocked" "Journal entry schema"; do
  if ! grep -qxF "# $h" "$PROG"; then
    viol "missing required section: # $h"
  fi
done

# ---- C. Never list: defaults present, or an explicit loosening record --------
NEVER=$(section_body "Never")
if [ -n "$(printf '%s' "$NEVER" | tr -d '[:space:]')" ]; then
  LOOSENED=$(printf '%s' "$NEVER" | grep -cE '^[[:space:]]*-[[:space:]]*loosened:')
  case "$LOOSENED" in ''|*[!0-9]*) LOOSENED=0 ;; esac
  # Default guardrails (SPEC-020): publish/push, branch/tag deletion + history
  # rewrite, deletion outside declared scope. A missing default is acceptable
  # only with a matching explicit `- loosened:` record.
  if ! printf '%s' "$NEVER" | grep -qi 'git push\|publish'; then
    [ "$LOOSENED" -ge 1 ] || viol "# Never lacks the git push/publish guardrail (and no '- loosened:' record)"
  fi
  if ! printf '%s' "$NEVER" | grep -qi 'rewrite git history\|delete branches\|branches or tags'; then
    [ "$LOOSENED" -ge 1 ] || viol "# Never lacks the branch/tag deletion and history-rewrite guardrail (and no '- loosened:' record)"
  fi
  if ! printf '%s' "$NEVER" | grep -qi 'outside the scope\|outside.*declared scope'; then
    [ "$LOOSENED" -ge 1 ] || viol "# Never lacks the deletion-outside-scope guardrail (and no '- loosened:' record)"
  fi
else
  viol "# Never section is empty"
fi

# ---- D. Journal read first, journal append last ------------------------------
ITER=$(section_body "Every iteration")
if [ -n "$(printf '%s' "$ITER" | tr -d '[:space:]')" ]; then
  FIRST_ITEM=$(printf '%s\n' "$ITER" | grep -E '^[0-9]+\.' | head -1)
  LAST_ITEM=$(printf '%s\n' "$ITER" | grep -E '^[0-9]+\.' | tail -1)
  case "$FIRST_ITEM" in
    *[Jj]ournal*) ;;
    *) viol "first # Every iteration step must read the journal, got: ${FIRST_ITEM:-<none>}" ;;
  esac
  case "$LAST_ITEM" in
    *[Jj]ournal*) ;;
    *) viol "last # Every iteration step must append the journal entry, got: ${LAST_ITEM:-<none>}" ;;
  esac
else
  viol "# Every iteration has no numbered steps"
fi

# ---- E. Journal entry schema -------------------------------------------------
SCHEMA=$(section_body "Journal entry schema")
if ! printf '%s' "$SCHEMA" | grep -q '## Iteration'; then
  viol "# Journal entry schema must carry the ## Iteration <N> entry template"
fi

if [ "$VIOLATIONS" -eq 0 ]; then
  [ "$QUIET" -eq 1 ] || echo "OK: $PROG passes check-program"
  exit 0
fi
exit 1
