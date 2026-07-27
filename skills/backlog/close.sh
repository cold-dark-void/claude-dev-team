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
# ROOT = --root if set, else git rev-parse --show-toplevel, else pwd.
# Does NOT commit — local write-through only; never stage process trackers.
#
# Exit: 0 ok (incl. Linear-only skip when no local write-through), 1 not found /
# verify fail, 64 usage. Missing index/dir post-hygiene is calm exit 0 (CDT-63),
# not error-shaped.

set -euo pipefail

USAGE='Usage: close.sh <slug-or-title> [options]
       close.sh verify <slug-or-title> [--root PATH]
Options: --ticket ID  --sha SHA  --note TEXT  --root PATH
         --status COMPLETED|FIXED/CLOSED (default COMPLETED)'

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
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

resolve_root() {
  if [ -n "$ROOT" ]; then
    [ -d "$ROOT" ] || die 1 "root not a directory: $ROOT"
    ROOT=$(cd "$ROOT" && pwd)
    return 0
  fi
  if ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    return 0
  fi
  ROOT=$(pwd)
}

is_closed_status() {
  local s
  s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$s" in
    *COMPLETED*|*FIXED/CLOSED*|*FIXED*CLOSED*|*CLOSED*) return 0 ;;
    *) return 1 ;;
  esac
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

  if [ -f "$backlog_dir/${q_base}.md" ]; then
    printf '%s\n' "$q_base"
    return 0
  fi

  if [ -d "$backlog_dir" ]; then
    for f in "$backlog_dir"/*.md; do
      [ -f "$f" ] || continue
      slug=$(basename "$f" .md)
      title=$(head -n 1 "$f" 2>/dev/null | sed 's/^# *//')
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
    while IFS= read -r line; do
      slug=$(printf '%s' "$line" | sed -n 's/.*](backlog\/\([^)]*\)\.md).*/\1/p')
      [ -n "$slug" ] || continue
      [ -f "$backlog_dir/${slug}.md" ] || continue
      title=$(head -n 1 "$backlog_dir/${slug}.md" 2>/dev/null | sed 's/^# *//')
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
  printf '%s\n' "${matches[@]}" | awk 'NF && !seen[$0]++'
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

# Returns 0 updated, 2 already closed
update_item_file() {
  local file="$1"
  local st new_status closed_line tmp
  st=$(item_status_value "$file")
  if is_closed_status "$st"; then
    return 2
  fi
  new_status=$(build_status_line)
  closed_line=$(build_closed_footer)
  tmp=$(mktemp "${TMPDIR:-/tmp}/backlog-close.XXXXXX")
  awk -v ns="$new_status" -v cl="$closed_line" '
    BEGIN { status_done=0; has_closed=0 }
    /^\*\*Status\*\*:/ {
      printf "%s", ns
      status_done=1
      next
    }
    /^\*Closed:/ { has_closed=1 }
    { print }
    END {
      if (!status_done) printf "%s", ns
      if (!has_closed) {
        print ""
        printf "%s", cl
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  return 0
}

# Preserve hierarchical Pending content; only move this slug's bullet to Completed.
# No-op (return 0) when index is absent — Linear-only / post-hygiene (CDT-63).
update_index() {
  local slug="$1"
  local index="$ROOT/.claude/backlog.md"
  local tag found_line line_new tmp title
  local has_completed=0

  [ -f "$index" ] || return 0
  tag=$(index_tag)

  found_line=$(grep -E "\]\(backlog/${slug}\.md\)" "$index" | head -n1 || true)
  if [ -z "$found_line" ]; then
    title=$(head -n 1 "$ROOT/.claude/backlog/${slug}.md" | sed 's/^# *//')
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

  tmp=$(mktemp "${TMPDIR:-/tmp}/backlog-index.XXXXXX")
  # Drop existing lines for this slug; append under ## Completed (create if missing)
  if grep -qE '^## Completed[[:space:]]*$' "$index"; then
    has_completed=1
  fi

  awk -v slug="$slug" -v newline="$found_line" -v has_c="$has_completed" '
    BEGIN { inserted=0 }
    $0 ~ "\\]\\(backlog/" slug "\\.md\\)" { next }
    /^## Completed[[:space:]]*$/ {
      print
      # print blank after header if next line is not blank? keep simple: always emit newline after header line content follows
      getline
      if ($0 ~ /^[[:space:]]*$/) {
        print ""
        print newline
        inserted=1
        next
      } else {
        print newline
        print ""
        print
        inserted=1
        next
      }
    }
    { print }
    END {
      if (!inserted) {
        print ""
        print "## Completed"
        print ""
        print newline
        print ""
      }
    }
  ' "$index" > "$tmp"
  mv "$tmp" "$index"
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
  file="$backlog_dir/${slug}.md"

  set +e
  update_item_file "$file"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    update_index "$slug" || true
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
