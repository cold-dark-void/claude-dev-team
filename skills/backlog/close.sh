#!/usr/bin/env bash
# close.sh — deterministic backlog item close + verify (subprocess-only, never source).
#
# Usage:
#   close.sh <slug-or-title> [--ticket ID] [--sha SHA] [--note TEXT] [--root PATH]
#            [--status COMPLETED|FIXED/CLOSED]
#   close.sh verify <slug-or-title> [--root PATH]
#
# Edits local write-through under ROOT/.claude/backlog/ and ROOT/.claude/backlog.md
# (never committed as product — process trackers stay on disk only).
# ROOT = --root if set, else $MROOT — the parent of `git rev-parse
# --git-common-dir` — else pwd outside git (SPEC-009 § Backlog root rule).
# Every linked worktree therefore reads and writes the one shared store; the
# former show-toplevel default is withdrawn.
# Does NOT commit — local write-through only; never stage process trackers.
#
# close mode holds the shared backlog lock (skills/backlog/lock.sh,
# <root>/.claude/backlog.lock/) for the whole read-decide-write, taken once
# per process after the write-free early exits and before the first read a
# write decision uses. `close.sh verify` takes no lock.
#
# Exit: 0 ok (incl. Linear-only skip when no local write-through), 1 not found /
# verify fail / lock busy, 64 usage. Missing index/dir post-hygiene is calm
# exit 0 (CDT-63), not error-shaped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

_TS="$SCRIPT_DIR/terminal-status.sh"
is_closed_status() {
  bash "$_TS" is-closed "$1"
}

[ -f "$SCRIPT_DIR/../lib/portable.sh" ] || die 1 "missing helper: $SCRIPT_DIR/../lib/portable.sh"
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"
[ -f "$SCRIPT_DIR/lock.sh" ] || die 1 "missing helper: $SCRIPT_DIR/lock.sh"
# shellcheck source=lock.sh
. "$SCRIPT_DIR/lock.sh"

USAGE='Usage: close.sh <slug-or-title> [options]
       close.sh verify <slug-or-title> [--root PATH]
Options: --ticket ID  --sha SHA  --note TEXT  --root PATH
         --status COMPLETED|FIXED/CLOSED (default COMPLETED)'

# Charset for path-safe slugs — same as worktree-lib validate_slug / reconcile (CDT-175).
# Guard every path built from a slug; free-text QUERY (title search) is not a slug.
valid_slug() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

require_valid_slug() {
  local slug="$1"
  if ! valid_slug "$slug"; then
    die 1 "invalid slug (only [A-Za-z0-9_-] allowed): $slug"
  fi
}

MODE="close"
if [ "${1:-}" = "verify" ]; then
  MODE="verify"
  shift
fi

QUERY=""
TICKET=""
SHA=""
NOTE=""
ROOT=""
STATUS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) TICKET="${2:-}"; shift 2 || die 64 "--ticket needs value" ;;
    --sha) SHA="${2:-}"; shift 2 || die 64 "--sha needs value" ;;
    --note) NOTE="${2:-}"; shift 2 || die 64 "--note needs value" ;;
    --root) ROOT="${2:-}"; shift 2 || die 64 "--root needs value" ;;
    --status) STATUS="${2:-}"; shift 2 || die 64 "--status needs value" ;;
    -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
    -*) die 64 "unknown option: $1" ;;
    *)
      if [ -z "$QUERY" ]; then
        QUERY="$1"
        shift
      else
        die 64 "unexpected argument: $1"
      fi
      ;;
  esac
done

[ -n "$QUERY" ] || die 64 "missing <slug-or-title>"$'\n'"$USAGE"

if [ -z "$STATUS" ]; then
  STATUS="COMPLETED"
fi
case "$STATUS" in
  COMPLETED|FIXED/CLOSED) ;;
  *) die 64 "invalid --status '$STATUS' (expected COMPLETED|FIXED/CLOSED)" ;;
esac

# resolve_root (SPEC-009 C3): --root if set, else $MROOT (the parent of
# `git rev-parse --git-common-dir`), else pwd outside git.
resolve_root() {
  if [ -n "$ROOT" ]; then
    [ -d "$ROOT" ] || die 1 "root not a directory: $ROOT"
    ROOT=$(cd "$ROOT" && pwd)
    return 0
  fi
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    ROOT=$(cd "$(dirname "$_gc")" && pwd)
    return 0
  fi
  ROOT=$(pwd)
}

# Prints matching slugs (one per line). Exit 1 if none.
find_slugs() {
  local q="$1"
  local backlog_dir="$ROOT/.claude/backlog"
  local index="$ROOT/.claude/backlog.md"
  local q_base slug f title slug_lc title_lc q_lc
  local -a matches=()

  q_base=$(basename "$q" .md)
  q_base=${q_base#backlog/}
  q_lc=$(printf '%s' "$q_base" | tr '[:upper:]' '[:lower:]')

  # Direct path match only when q_base is a path-safe slug (never construct from ../ etc.).
  if valid_slug "$q_base" && [ -f "$backlog_dir/${q_base}.md" ]; then
    printf '%s\n' "$q_base"
    return 0
  fi

  if [ -d "$backlog_dir" ]; then
    for f in "$backlog_dir"/*.md; do
      [ -f "$f" ] || continue
      slug=$(basename "$f" .md)
      valid_slug "$slug" || continue
      title=$(item_title "$f")
      [ -n "$title" ] || title="$slug"
      slug_lc=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
      title_lc=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
      if [ "$slug_lc" = "$q_lc" ] \
        || [[ "$slug_lc" == *"$q_lc"* ]] \
        || [[ "$title_lc" == *"$q_lc"* ]]; then
        matches+=("$slug")
      fi
    done
  fi

  if [ ${#matches[@]} -eq 0 ] && [ -f "$index" ]; then
    local line
    # || [ -n "$line" ]: also scan a final row with no trailing newline (WP 1-04 rework T4-1 sibling defect).
    while IFS= read -r line || [ -n "$line" ]; do
      slug=$(printf '%s' "$line" | sed -n 's/.*](backlog\/\([^)]*\)\.md).*/\1/p')
      [ -n "$slug" ] || continue
      # Index-row slug is untrusted — reject before any path construction (CDT-192).
      valid_slug "$slug" || continue
      [ -f "$backlog_dir/${slug}.md" ] || continue
      title=$(item_title "$backlog_dir/${slug}.md")
      [ -n "$title" ] || title="$slug"
      slug_lc=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
      title_lc=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
      line_lc=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
      if [ "$slug_lc" = "$q_lc" ] \
        || [[ "$slug_lc" == *"$q_lc"* ]] \
        || [[ "$title_lc" == *"$q_lc"* ]] \
        || [[ "$line_lc" == *"$q_lc"* ]]; then
        matches+=("$slug")
      fi
    done < "$index"
  fi

  if [ ${#matches[@]} -eq 0 ]; then
    return 1
  fi
  printf '%s\n' ${matches[@]+"${matches[@]}"} | awk 'NF && !seen[$0]++'
}

item_status_value() {
  local file="$1"
  grep -m1 -E '^\*\*Status\*\*:' "$file" 2>/dev/null \
    | sed 's/^\*\*Status\*\*:[[:space:]]*//' || true
}

# Extract linear_id from YAML frontmatter (session bridge for Linear Done; no MCP here).
item_linear_id() {
  local file="$1"
  awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^linear_id:[[:space:]]*/ {
      sub(/^linear_id:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file" 2>/dev/null || true
}

# item_title <file> (SPEC-009 § Backlog write integrity, C6): prints the first
# "^# " line after the YAML frontmatter block (if any), with the leading "# "
# stripped. Prints nothing when no such line exists — callers fall back to the
# slug. Used at every former `head -n 1` title site.
item_title() {
  local file="$1"
  awk '
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; next }
    in_fm { next }
    /^# / { sub(/^# */, ""); print; exit }
  ' "$file" 2>/dev/null || true
}

pick_one_slug() {
  local slugs n slug
  if ! slugs=$(find_slugs "$QUERY"); then
    die 1 "no backlog item matching: $QUERY"
  fi
  n=$(printf '%s\n' "$slugs" | grep -c . || true)
  if [ "${n:-0}" -gt 1 ]; then
    printf 'error: ambiguous match for %s:\n%s\n' "$QUERY" "$slugs" >&2
    printf 'Pick one slug and re-run.\n' >&2
    exit 64
  fi
  printf '%s\n' "$slugs" | head -n1
}

cmd_verify() {
  resolve_root
  local backlog_dir="$ROOT/.claude/backlog"
  [ -d "$backlog_dir" ] || die 1 "no backlog dir: $backlog_dir"

  local slug file st
  slug=$(pick_one_slug)
  require_valid_slug "$slug"
  file="$backlog_dir/${slug}.md"
  [ -f "$file" ] || die 1 "missing item file: $file"
  st=$(item_status_value "$file")
  if is_closed_status "$st"; then
    printf 'Verified closed: .claude/backlog/%s.md\n' "$slug"
    exit 0
  fi
  printf 'Still open: .claude/backlog/%s.md status=%s\n' "$slug" "${st:-unknown}" >&2
  exit 1
}

build_status_line() {
  if [ "$STATUS" = "FIXED/CLOSED" ]; then
    if [ -n "$TICKET" ]; then
      printf '**Status**: FIXED/CLOSED (%s)' "$TICKET"
      [ -n "$SHA" ] && printf ' — %s' "$SHA"
      [ -n "$NOTE" ] && printf ' — %s' "$NOTE"
      printf '\n'
    else
      printf '**Status**: FIXED/CLOSED\n'
    fi
  else
    if [ -n "$TICKET" ]; then
      printf '**Status**: COMPLETED (%s)\n' "$TICKET"
    else
      printf '**Status**: COMPLETED\n'
    fi
  fi
}

build_closed_footer() {
  local today extra=""
  today=$(date +%Y-%m-%d)
  [ -n "$TICKET" ] && extra="$extra $TICKET"
  [ -n "$SHA" ] && extra="$extra $SHA"
  [ -n "$NOTE" ] && extra="$extra — $NOTE"
  printf '*Closed: %s%s*\n' "$today" "$extra"
}

index_tag() {
  if [ "$STATUS" = "FIXED/CLOSED" ] && [ -n "$TICKET" ]; then
    printf '[FIXED/CLOSED — %s]' "$TICKET"
  elif [ "$STATUS" = "FIXED/CLOSED" ]; then
    printf '[FIXED/CLOSED]'
  elif [ -n "$TICKET" ]; then
    printf '[COMPLETED — %s]' "$TICKET"
  else
    printf '[COMPLETED]'
  fi
}

# Returns 0 updated, 2 already closed, 1 write failure. Rewrite goes through
# atomic_write (SPEC-009 § Backlog write integrity); values reach awk via
# ENVIRON, never -v, so \t \n \\ & / stay byte-for-byte (AC G). A producer/
# write failure must map to 1, never 2 — cmd_close reads rc==2 as "already
# closed" and must not misread a failed rewrite that way (WP 1-04 rework T3).
update_item_file() {
  local file="$1"
  local st new_status closed_line
  st=$(item_status_value "$file")
  if is_closed_status "$st"; then
    return 2
  fi
  new_status=$(build_status_line)
  closed_line=$(build_closed_footer)
  atomic_write "$file" env BL_NS="$new_status" BL_CL="$closed_line" awk '
    BEGIN { ns = ENVIRON["BL_NS"]; cl = ENVIRON["BL_CL"]; status_done = 0; has_closed = 0 }
    /^\*\*Status\*\*:/ {
      print ns
      status_done = 1
      next
    }
    /^\*Closed:/ { has_closed = 1 }
    { print }
    END {
      if (!status_done) print ns
      if (!has_closed) {
        print ""
        print cl
      }
    }
  ' "$file" || return 1
}

# Preserve hierarchical Pending content; only move this slug's bullet to Completed.
# No-op (return 0) when index is absent — Linear-only / post-hygiene (CDT-63).
# Index update goes through atomic_write with a getline-free, ENVIRON-driven awk
# program (SPEC-009 C5): exactly one `## Completed` header and one row per slug,
# even when the header is the last line or an old row sits directly under it.
update_index() {
  local slug="$1"
  local index="$ROOT/.claude/backlog.md"
  local tag found_line line_new title

  require_valid_slug "$slug"
  [ -f "$index" ] || return 0
  tag=$(index_tag)

  found_line=$(grep -E "\]\(backlog/${slug}\.md\)" "$index" | head -n1 || true)
  if [ -z "$found_line" ]; then
    title=$(item_title "$ROOT/.claude/backlog/${slug}.md")
    [ -n "$title" ] || title="$slug"
    found_line="- [${title}](backlog/${slug}.md) - ${title} ${tag}"
  else
    # Strip prior status tags. Inside a sed character class, ] must be first
    # after ^ (i.e. [^]]) — [^\]] is parsed as "not backslash" + literal ], so
    # FIXED/CLOSED — ID and COMPLETED — ID tags never stripped (CDT-57 dogfood).
    line_new=$(printf '%s' "$found_line" \
      | sed -E 's/[[:space:]]*\[(PENDING|COMPLETED[^]]*|FIXED\/CLOSED[^]]*)\]//g' \
      | sed -E 's/[[:space:]]+$//')
    found_line="${line_new} ${tag}"
  fi

  atomic_write "$index" env BL_SLUG="$slug" BL_ROW="$found_line" awk '
    BEGIN {
      slug = ENVIRON["BL_SLUG"]; row = ENVIRON["BL_ROW"]
      key = "](backlog/" slug ".md)"; ins = 0; pend = 0; seen_hdr = 0
    }
    index($0, key) { next }
    pend {
      pend = 0
      if ($0 ~ /^[[:space:]]*$/) { print; print row }
      else if ($0 ~ /^## Completed[[:space:]]*$/) { print row; print "" }
      else { print row; print ""; print }
      ins = 1
      next
    }
    /^## Completed[[:space:]]*$/ {
      if (seen_hdr) next
      seen_hdr = 1
      print
      pend = 1
      next
    }
    { print }
    END {
      if (pend) { print ""; print row; ins = 1 }
      if (!ins) { print ""; print "## Completed"; print ""; print row; print "" }
    }
  ' "$index" || return 1
}

# Print linear_id bridge line when present (session marks Linear Done; bash-only here).
print_linear_bridge() {
  local file="$1"
  local lid
  lid=$(item_linear_id "$file")
  if [ -n "$lid" ]; then
    printf 'linear_id: %s\n' "$lid"
  fi
}

# Linear-only / post-hygiene (C8 removed committed backlog index): no local
# write-through is the EXPECTED case. Calm skip, exit 0 — never error-shaped.
skip_linear_only() {
  if [ -n "${BACKLOG_DEBUG:-}" ]; then
    printf 'debug: no local backlog write-through under %s (Linear-only)\n' "$ROOT" >&2
  else
    printf 'No local backlog write-through — skip (Linear-only).\n'
  fi
  exit 0
}

cmd_close() {
  resolve_root
  local backlog_dir="$ROOT/.claude/backlog"
  local index="$ROOT/.claude/backlog.md"

  # Neither dir nor index: pure Linear-only / never dual-written.
  if [ ! -d "$backlog_dir" ] && [ ! -f "$index" ]; then
    skip_linear_only
  fi

  # Dir missing but index present is inconsistent; still can't close items.
  if [ ! -d "$backlog_dir" ]; then
    die 1 "no backlog dir: $backlog_dir"
  fi

  # Shared backlog lock (SPEC-009 § Backlog write integrity): taken once, after
  # the write-free early exits above, before the first read (find_slugs) that a
  # write decision uses. Released automatically via lock.sh's EXIT/INT/TERM trap.
  backlog_lock_acquire "$ROOT" || exit $?

  local slug file rc
  if ! slug=$(find_slugs "$QUERY"); then
    # No matching local item. Index missing → Linear-only expected (CDT-63).
    # Index present → real miss (item should exist for close).
    if [ ! -f "$index" ]; then
      skip_linear_only
    fi
    die 1 "no backlog item matching: $QUERY"
  fi
  # Ambiguity / pick-one (same rules as pick_one_slug)
  local n
  n=$(printf '%s\n' "$slug" | grep -c . || true)
  if [ "${n:-0}" -gt 1 ]; then
    printf 'error: ambiguous match for %s:\n%s\n' "$QUERY" "$slug" >&2
    printf 'Pick one slug and re-run.\n' >&2
    exit 64
  fi
  slug=$(printf '%s\n' "$slug" | head -n1)
  require_valid_slug "$slug"
  file="$backlog_dir/${slug}.md"

  set +e
  update_item_file "$file"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    update_index "$slug" || die 1 "failed to update index: $index"
    printf 'Already closed: .claude/backlog/%s.md\n' "$slug"
    print_linear_bridge "$file"
    exit 0
  elif [ "$rc" -ne 0 ]; then
    die 1 "failed to update item: $file"
  fi

  update_index "$slug"
  printf 'Closed: .claude/backlog/%s.md\n' "$slug"
  print_linear_bridge "$file"
  exit 0
}

if [ "$MODE" = "verify" ]; then
  cmd_verify
else
  cmd_close
fi
