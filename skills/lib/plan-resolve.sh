#!/usr/bin/env bash
#
# skills/lib/plan-resolve.sh — SPEC-033 M9a plan lookup by Tracking ticket_id.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   plan-resolve.sh find <ticket_id>
#   plan-resolve.sh field <plan-path> <key>
#
# ---- find ---------------------------------------------------------------------
# Searches, in order, the worktree top-level plans dir
# (`git rev-parse --show-toplevel`/.claude/plans) and $MROOT/.claude/plans
# (git-common-dir formula; deduped when the two paths are equal — a bare
# checkout with no separate worktree). A missing dir is skipped, not an
# error.
#
# A candidate plan is any `*.md` file whose `## Tracking` section (the lines
# strictly between the `## Tracking` heading and the next line starting
# `## `, or EOF) holds a line matching
# `^- ticket_id:[[:space:]]*<ticket_id>[[:space:]]*$` — a LITERAL compare of
# <ticket_id> (never a regex), so a dot or other regex metacharacter in the
# id cannot widen the match.
#
# Zero candidates       -> no stdout, exit 1 (legacy plan with no
#                          `ticket_id:` line, or no plan at all, is "not
#                          found" — SPEC-033 D11).
# One candidate          -> its absolute path on stdout, exit 0.
# Several candidates     -> the newest by mtime across both dirs (`ls -t`)
#                          wins; there is no prefix/glob fallback.
#
# ---- field --------------------------------------------------------------------
# Prints the value of the first `- <key>:` line inside <plan-path>'s
# `## Tracking` section, whitespace-trimmed. A `- <key>:` line OUTSIDE
# `## Tracking` is ignored. Key absent -> empty stdout, exit 0 (absent is a
# valid, normal result, not an error). Missing <plan-path> -> exit 1.
#
# Both subcommands are read-only and never write anything.
#
# Exit codes:
#   0   success (including "found" for `field`)
#   1   `find`: no candidate plan; `field`: <plan-path> does not exist
#  64   usage error: missing/unknown subcommand, wrong argc, a <ticket_id>
#       not matching ^[A-Za-z0-9_.-]+$, or a <key> not matching ^[a-z_]+$
#
# bash 3.2 portable: no mapfile, no declare -A, no ${var,,}.

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: plan-resolve.sh find <ticket_id> | plan-resolve.sh field <plan-path> <key>'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

[ $# -ge 1 ] || die "plan-resolve.sh requires a subcommand"

SUB="$1"
shift

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

case "$SUB" in
  find)
    [ $# -eq 1 ] || die "find requires exactly 1 argument (<ticket_id>)"
    TICKET_ID="$1"
    case "$TICKET_ID" in
      '') die "ticket_id must not be empty" ;;
      *[!A-Za-z0-9_.-]*) die "ticket_id must match ^[A-Za-z0-9_.-]+\$" ;;
    esac

    resolve_mroot
    TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || TOPLEVEL=""

    DIRS=()
    if [ -n "$TOPLEVEL" ] && [ -d "$TOPLEVEL/.claude/plans" ]; then
      DIRS+=("$TOPLEVEL/.claude/plans")
    fi
    if [ -d "$MROOT/.claude/plans" ]; then
      DUP=false
      for d in ${DIRS[@]+"${DIRS[@]}"}; do
        [ "$d" = "$MROOT/.claude/plans" ] && DUP=true
      done
      [ "$DUP" = true ] || DIRS+=("$MROOT/.claude/plans")
    fi

    MATCHES=()
    for d in ${DIRS[@]+"${DIRS[@]}"}; do
      for f in "$d"/*.md; do
        [ -e "$f" ] || continue
        if PR_TICKET_ID="$TICKET_ID" awk '
          BEGIN { intrack = 0; found = 0 }
          /^## Tracking[[:space:]]*$/ { intrack = 1; next }
          intrack && /^## / { intrack = 0 }
          intrack {
            line = $0
            n = sub(/^- ticket_id:[ \t]*/, "", line)
            if (n > 0) {
              sub(/[ \t]+$/, "", line)
              if (line == ENVIRON["PR_TICKET_ID"]) { found = 1 }
            }
          }
          END { exit (found ? 0 : 1) }
        ' "$f"; then
          MATCHES+=("$f")
        fi
      done
    done

    [ ${#MATCHES[@]} -eq 0 ] && exit 1

    if [ ${#MATCHES[@]} -eq 1 ]; then
      printf '%s\n' "${MATCHES[0]}"
      exit 0
    fi

    NEWEST=$(ls -t "${MATCHES[@]}" | head -n 1) || die "ls -t failed resolving newest match"
    printf '%s\n' "$NEWEST"
    exit 0
    ;;

  field)
    [ $# -eq 2 ] || die "field requires exactly 2 arguments (<plan-path> <key>)"
    PLAN_PATH="$1"
    KEY="$2"
    case "$KEY" in
      '') die "key must match ^[a-z_]+\$" ;;
      *[!a-z_]*) die "key must match ^[a-z_]+\$" ;;
    esac

    [ -f "$PLAN_PATH" ] || exit 1

    PR_KEY="$KEY" awk '
      BEGIN { intrack = 0; found = 0 }
      /^## Tracking[[:space:]]*$/ { intrack = 1; next }
      intrack && /^## / { intrack = 0 }
      intrack && !found {
        pfx = "- " ENVIRON["PR_KEY"] ":"
        if (index($0, pfx) == 1) {
          val = substr($0, length(pfx) + 1)
          gsub(/^[ \t]+/, "", val)
          gsub(/[ \t]+$/, "", val)
          print val
          found = 1
        }
      }
    ' "$PLAN_PATH"
    exit 0
    ;;

  *)
    die "unknown subcommand '$SUB' (expected find or field)"
    ;;
esac
