#!/usr/bin/env bash
# reconcile.sh — deterministic, idempotent backlog index↔item-file repair (subprocess-only, never source).
#
# Brings ROOT/.claude/backlog.md into agreement with ROOT/.claude/backlog/<slug>.md item files
# (and, when supplied, with Linear-resolved terminal-state verdicts). Hygiene only — never invents
# new backlog items. See specs/core/SPEC-009-ticket-workflow.md §"Backlog reconcile".
#
# Usage:
#   reconcile.sh [--root PATH] [--dry-run] [--linear-verdicts FILE]
#
# LOCAL pass (always):
#   - Rows whose item file Status is COMPLETED/DONE/FIXED-CLOSED (case-insensitive) → move to ## Completed.
#   - Index rows with no corresponding item file → REMOVED (dead references).
#   - Duplicate rows for one slug → collapse to a single row (keep the first/most-informative).
# LINEAR pass (when --linear-verdicts FILE given):
#   - FILE is a TSV/JSON of slug→terminal-state, resolved by the CALLING Claude session (which has MCP).
#     Slugs listed as terminal (Done/Cancelled/Completed) take PRECEDENCE over local status: the item
#     file Status is set to COMPLETED and the row moved to ## Completed. This script does NOT call MCP.
#
# ROOT = --root if set, else git rev-parse --show-toplevel, else pwd.
# Does NOT commit — caller stages.
#
# Exit: 0 ok (reconciled or already clean), 1 error (no index/dir), 64 usage.

set -euo pipefail

USAGE='Usage: reconcile.sh [--root PATH] [--dry-run] [--linear-verdicts FILE]
  --root PATH             backlog root (else git show-toplevel, else pwd)
  --dry-run               print planned actions; write nothing
  --linear-verdicts FILE  TSV/JSON of slug→terminal-state (Linear SoT; precedence over local status)'

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

ROOT=""
DRY_RUN=0
VERDICTS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || die 64 "--root needs value" ;;
    --dry-run) DRY_RUN=1; shift ;;
    --linear-verdicts) VERDICTS_FILE="${2:-}"; shift 2 || die 64 "--linear-verdicts needs value" ;;
    -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
    -*) die 64 "unknown option: $1" ;;
    *) die 64 "unexpected argument: $1" ;;
  esac
done

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

# Uppercase + normalize a status string, then classify as terminal (closed) or not.
# Local item-file terminals: COMPLETED, DONE, FIXED-CLOSED, FIXED/CLOSED (any case, trailing noise ok).
# Linear terminal states (used when classifying --linear-verdicts entries): also CANCELLED/CANCELED.
is_closed_status() {
  local s
  s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$s" in
    *COMPLETED*|*DONE*|*FIXED-CLOSED*|*FIXED/CLOSED*|*FIXED*CLOSED*|*CLOSED*|*CANCELLED*|*CANCELED*) return 0 ;;
    *) return 1 ;;
  esac
}

# Read **Status**: value from an item file (first hit), trimmed.
item_status_value() {
  local file="$1"
  grep -m1 -E '^\*\*Status\*\*:' "$file" 2>/dev/null \
    | sed 's/^\*\*Status\*\*:[[:space:]]*//' || true
}

# Extract the slug from an index row of the form: - [Title](backlog/<slug>.md) - ... [TAG]
row_slug() {
  printf '%s' "$1" | sed -n 's/.*](backlog\/\([^)]*\)\.md).*/\1/p'
}

# Load Linear verdicts file into VERDICT_SLUGS (assoc: slug -> 1 if terminal).
# Supports two shapes:
#   TSV : lines "<slug>\t<state>"  (state matched by is_closed_status; blank state = terminal)
#   JSON: a flat object {"<slug>":"<state>",...} OR an array/list of objects each carrying a
#         "slug"/"id" and a "state"/"status" key, e.g. [{"slug":"x","state":"Done"},...].
# Non-terminal states are ignored (they never override local; local may still close them).
declare -A VERDICT_SLUGS=()
load_verdicts() {
  [ -n "$VERDICTS_FILE" ] || return 0
  [ -f "$VERDICTS_FILE" ] || die 1 "linear-verdicts file not found: $VERDICTS_FILE"
  local first
  first=$(grep -m1 -E '[^[:space:]]' "$VERDICTS_FILE" 2>/dev/null || true)
  if printf '%s' "$first" | grep -qE '^[[:space:]]*[[{]'; then
    # JSON-ish: emit real tab-separated slug<TAB>state pairs, tolerant of both shapes.
    local slug state
    while IFS=$'\t' read -r slug state; do
      [ -n "$slug" ] || continue
      if [ -z "$state" ] || is_closed_status "$state"; then
        VERDICT_SLUGS["$slug"]=1
      fi
    done < <(
      grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"' "$VERDICTS_FILE" \
        | awk '
            function emit(s, v) { if (s != "") printf "%s\t%s\n", s, v }
            {
              match($0, /^"[^"]+"/); k=substr($0,2,RLENGTH-2)
              match($0, /"[^"]*"[[:space:]]*$/); v=substr($0,RSTART+1,RLENGTH-2)
              if (k=="slug" || k=="id") { pend_slug=v; next }
              if (k=="state" || k=="status") { emit(pend_slug, v); pend_slug=""; next }
              # flat object: key IS the slug, value IS the state
              emit(k, v)
            }'
    )
  else
    # TSV: <slug>\t<state>
    local slug state
    while IFS=$'\t' read -r slug state _; do
      slug=$(printf '%s' "$slug" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -n "$slug" ] || continue
      case "$slug" in \#*) continue ;; esac
      if [ -z "$state" ] || is_closed_status "$state"; then
        VERDICT_SLUGS["$slug"]=1
      fi
    done < "$VERDICTS_FILE"
  fi
}

# Set an item file's Status to COMPLETED and append a Closed footer (idempotent — skips if already closed).
close_item_file() {
  local file="$1" reason="$2"
  [ -f "$file" ] || return 0
  local st today tmp
  st=$(item_status_value "$file")
  if is_closed_status "$st"; then
    return 0
  fi
  today=$(date +%Y-%m-%d)
  tmp=$(mktemp "${TMPDIR:-/tmp}/backlog-reconcile-item.XXXXXX")
  awk -v today="$today" -v reason="$reason" '
    BEGIN { status_done=0; has_closed=0 }
    /^\*\*Status\*\*:/ {
      print "**Status**: COMPLETED"
      status_done=1
      next
    }
    /^\*Closed:/ { has_closed=1 }
    { print }
    END {
      if (!status_done) print "**Status**: COMPLETED"
      if (!has_closed) {
        print ""
        printf "*Closed: %s (reconcile: %s)*\n", today, reason
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---- main -----------------------------------------------------------------

resolve_root
BACKLOG_DIR="$ROOT/.claude/backlog"
INDEX="$ROOT/.claude/backlog.md"
[ -d "$BACKLOG_DIR" ] || die 1 "no backlog dir: $BACKLOG_DIR"
[ -f "$INDEX" ] || die 1 "no backlog index: $INDEX"

load_verdicts

# Planned-action log (dry-run and summary). Populated during the scan.
declare -a ACTIONS=()

# For each unique slug in the index, decide its terminal disposition:
#   MISSING  → row(s) removed (dead ref)
#   COMPLETE → row moved to ## Completed, item file closed (local or Linear verdict)
#   PENDING  → row stays in ## Pending
# Duplicate rows for one slug always collapse to the first-seen row.
#
# We rebuild the index deterministically:
#   header (everything before the first ## Pending/## Completed section is preserved verbatim),
#   then ## Pending with surviving pending rows in first-seen order,
#   then ## Completed with surviving completed rows in first-seen order.

# Collect ordered unique slugs + first-seen row text, and detect duplicates/dead refs.
declare -A SEEN=()          # slug -> 1 once its first row is recorded
declare -A ROW_TEXT=()      # slug -> first-seen row text
declare -a SLUG_ORDER=()    # slugs in first-seen order
declare -A DISPOSITION=()   # slug -> pending|completed|missing

while IFS= read -r line; do
  slug=$(row_slug "$line")
  [ -n "$slug" ] || continue
  if [ -n "${SEEN[$slug]:-}" ]; then
    ACTIONS+=("collapse duplicate row for '$slug'")
    continue
  fi
  SEEN["$slug"]=1
  SLUG_ORDER+=("$slug")
  ROW_TEXT["$slug"]="$line"
done < "$INDEX"

# Classify each unique slug.
for slug in "${SLUG_ORDER[@]}"; do
  item="$BACKLOG_DIR/${slug}.md"
  if [ ! -f "$item" ]; then
    DISPOSITION["$slug"]="missing"
    ACTIONS+=("remove dead-ref row for '$slug' (no item file)")
    continue
  fi
  if [ -n "${VERDICT_SLUGS[$slug]:-}" ]; then
    DISPOSITION["$slug"]="completed"
    if ! is_closed_status "$(item_status_value "$item")"; then
      ACTIONS+=("close '$slug' + move to Completed (Linear verdict: terminal)")
    fi
    continue
  fi
  st=$(item_status_value "$item")
  if is_closed_status "$st"; then
    DISPOSITION["$slug"]="completed"
    # Only a move if it wasn't already recorded under Completed — detected below via section.
    ACTIONS+=("ensure '$slug' under Completed (item Status=${st:-COMPLETED})")
  else
    DISPOSITION["$slug"]="pending"
  fi
done

# Determine which slugs currently sit under ## Completed so we can suppress no-op "move" noise
# and, more importantly, so idempotency holds: a row already Completed with a closed item stays put.
declare -A ALREADY_COMPLETED=()
awk '
  /^## Completed[[:space:]]*$/ { sec="c"; next }
  /^## [A-Za-z]/ { sec=""; next }
  sec=="c" && /\]\(backlog\// {
    if (match($0, /\]\(backlog\/[^)]*\.md\)/)) {
      s=substr($0, RSTART, RLENGTH)
      sub(/^\]\(backlog\//, "", s); sub(/\.md\)$/, "", s)
      print s
    }
  }
' "$INDEX" > "${TMPDIR:-/tmp}/backlog-reconcile-completed.$$" 2>/dev/null || true
while IFS= read -r s; do
  [ -n "$s" ] && ALREADY_COMPLETED["$s"]=1
done < "${TMPDIR:-/tmp}/backlog-reconcile-completed.$$"
rm -f "${TMPDIR:-/tmp}/backlog-reconcile-completed.$$"

# Refine ACTIONS: a "completed" slug already under ## Completed with a closed item is a no-op.
# Rebuild a clean planned-action list for reporting/change-detection.
PLANNED=()
for a in "${ACTIONS[@]}"; do PLANNED+=("$a"); done

# Rewrite the index. Header = lines before the first "## Pending" or "## Completed".
HEADER_TMP=$(mktemp "${TMPDIR:-/tmp}/backlog-reconcile-hdr.XXXXXX")
awk '
  /^## Pending[[:space:]]*$/ { exit }
  /^## Completed[[:space:]]*$/ { exit }
  { print }
' "$INDEX" > "$HEADER_TMP"

# Strip a trailing PENDING/COMPLETED/FIXED tag and trailing whitespace, then re-tag.
retag_row() {
  local row="$1" tag="$2" base
  base=$(printf '%s' "$row" \
    | sed -E 's/[[:space:]]*\[(PENDING|COMPLETED[^]]*|FIXED[/-]CLOSED[^]]*|DONE[^]]*)\]//g' \
    | sed -E 's/[[:space:]]+$//')
  printf '%s %s' "$base" "$tag"
}

NEW_INDEX=$(mktemp "${TMPDIR:-/tmp}/backlog-reconcile-idx.XXXXXX")
{
  # Header verbatim (trim trailing blank lines for deterministic spacing).
  sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}' "$HEADER_TMP"
  printf '\n## Pending\n\n'
  for slug in "${SLUG_ORDER[@]}"; do
    [ "${DISPOSITION[$slug]}" = "pending" ] || continue
    retag_row "${ROW_TEXT[$slug]}" "[PENDING]"; printf '\n'
  done
  printf '\n## Completed\n\n'
  for slug in "${SLUG_ORDER[@]}"; do
    [ "${DISPOSITION[$slug]}" = "completed" ] || continue
    retag_row "${ROW_TEXT[$slug]}" "[COMPLETED]"; printf '\n'
  done
} > "$NEW_INDEX"
rm -f "$HEADER_TMP"

# Change detection: compare rebuilt index to current, and check whether any item file
# would flip to closed. Used to report "no changes" and to keep dry-run honest.
INDEX_CHANGED=0
if ! diff -q "$INDEX" "$NEW_INDEX" >/dev/null 2>&1; then
  INDEX_CHANGED=1
fi

# Item-file writes that would happen (completed slugs whose item isn't yet closed).
declare -a ITEM_WRITES=()
for slug in "${SLUG_ORDER[@]}"; do
  [ "${DISPOSITION[$slug]}" = "completed" ] || continue
  item="$BACKLOG_DIR/${slug}.md"
  if ! is_closed_status "$(item_status_value "$item")"; then
    ITEM_WRITES+=("$slug")
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$INDEX_CHANGED" -eq 0 ] && [ ${#ITEM_WRITES[@]} -eq 0 ]; then
    printf 'reconcile (dry-run): no changes — index already consistent.\n'
  else
    printf 'reconcile (dry-run): planned actions:\n'
    if [ ${#PLANNED[@]} -gt 0 ]; then
      for a in "${PLANNED[@]}"; do printf '  - %s\n' "$a"; done
    fi
    for slug in "${ITEM_WRITES[@]}"; do
      printf '  - set item Status=COMPLETED: .claude/backlog/%s.md\n' "$slug"
    done
    [ "$INDEX_CHANGED" -eq 1 ] && printf '  - rewrite index: .claude/backlog.md\n'
  fi
  rm -f "$NEW_INDEX"
  exit 0
fi

# Apply: close item files, then swap the index in.
for slug in "${ITEM_WRITES[@]}"; do
  reason="local"
  [ -n "${VERDICT_SLUGS[$slug]:-}" ] && reason="linear"
  close_item_file "$BACKLOG_DIR/${slug}.md" "$reason"
done

if [ "$INDEX_CHANGED" -eq 1 ]; then
  mv "$NEW_INDEX" "$INDEX"
else
  rm -f "$NEW_INDEX"
fi

if [ "$INDEX_CHANGED" -eq 0 ] && [ ${#ITEM_WRITES[@]} -eq 0 ]; then
  printf 'reconcile: no changes — index already consistent.\n'
else
  printf 'reconcile: applied %d action(s).\n' "$(( ${#PLANNED[@]} + ${#ITEM_WRITES[@]} ))"
  for a in "${PLANNED[@]}"; do printf '  - %s\n' "$a"; done
  for slug in "${ITEM_WRITES[@]}"; do printf '  - closed item: .claude/backlog/%s.md\n' "$slug"; done
fi
exit 0
