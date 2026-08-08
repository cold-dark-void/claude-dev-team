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
#   - Rows whose item file Status is terminal per shared classifier terminal-status.sh
#     (COMPLETED/DONE/FIXED*/CLOSED/CANCELLED/…; case-insensitive token-match) → PRUNED
#     (item file deleted, index row dropped). Linear (when linked) or git/commit history is the
#     durable record for done work — the local write-through is a disposable cache, not an archive.
#   - Index rows with no corresponding item file → REMOVED (dead references).
#   - Duplicate rows for one slug → collapse to a single row (keep the first/most-informative).
#   - Item files with NO index row at all (orphans — never dual-written, or predate this convention)
#     → pruned when their own Status is already terminal; otherwise left untouched and reported,
#     since deleting unindexed OPEN work would be a silent loss.
# LINEAR pass (when --linear-verdicts FILE given):
#   - FILE is a TSV/JSON of slug→terminal-state, resolved by the CALLING Claude session (which has MCP).
#     Slugs listed as terminal (Done/Cancelled/Completed) take PRECEDENCE over local status: the row
#     is pruned the same as a locally-terminal item. This script does NOT call MCP.
#
# ROOT = --root if set, else git rev-parse --show-toplevel, else pwd.
# Does NOT commit — local write-through only; never stage process trackers.
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

# Shared terminal classifier (CDT-160) — contract lives in terminal-status.sh (SPEC-009).
# Blank-state-in-verdicts short-circuit stays at load_verdicts call sites (not here).
_TS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/terminal-status.sh"
is_closed_status() {
  bash "$_TS" is-closed "$1"
}

# Read **Status**: value from an item file (first hit), trimmed.
item_status_value() {
  local file="$1"
  grep -m1 -E '^\*\*Status\*\*:' "$file" 2>/dev/null \
    | sed 's/^\*\*Status\*\*:[[:space:]]*//' || true
}

# Read linear_id from YAML frontmatter, when present (report-only here; no MCP calls).
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
#   COMPLETE → row + item file PRUNED (deleted)
#   PENDING  → row stays in ## Pending
# Duplicate rows for one slug always collapse to the first-seen row.
#
# We rebuild the index deterministically:
#   header (everything before the first ## Pending/## Completed section is preserved verbatim),
#   then ## Pending with surviving pending rows in first-seen order,
#   then an (empty, after pruning) ## Completed section for schema stability.

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
  lid=$(item_linear_id "$item")
  lid_suffix="${lid:+ [linear_id: $lid]}"
  if [ -n "${VERDICT_SLUGS[$slug]:-}" ]; then
    DISPOSITION["$slug"]="completed"
    ACTIONS+=("prune '$slug' (Linear verdict: terminal)${lid_suffix}")
    continue
  fi
  st=$(item_status_value "$item")
  if is_closed_status "$st"; then
    DISPOSITION["$slug"]="completed"
    ACTIONS+=("prune '$slug' (item Status=${st:-COMPLETED})${lid_suffix}")
  else
    DISPOSITION["$slug"]="pending"
  fi
done

# Orphan scan: item files on disk with NO index row at all — invisible to the index-driven
# pass above (a distinct failure mode from a dead-ref index row). A closed-status orphan is
# safe to prune (nothing points to it; Linear or git/commit history already has the record).
# An open/unrecognized-status orphan is reported only, never deleted — silently discarding
# un-shipped work with no other record of it would violate "no silent loss".
declare -a ORPHAN_PRUNE=()
declare -a ORPHAN_KEEP=()
for item in "$BACKLOG_DIR"/*.md; do
  [ -f "$item" ] || continue
  oslug=$(basename "$item" .md)
  [ -n "${SEEN[$oslug]:-}" ] && continue
  ost=$(item_status_value "$item")
  if is_closed_status "$ost"; then
    ORPHAN_PRUNE+=("$oslug")
    ACTIONS+=("prune orphan '$oslug' (no index row; item Status=${ost:-COMPLETED})")
  else
    ORPHAN_KEEP+=("$oslug")
    olid=$(item_linear_id "$item")
    printf -v omsg "ORPHAN not pruned (no index row, status=%s): %s%s — needs manual triage (/backlog add or delete)" \
      "${ost:-unrecognized}" "$oslug" "${olid:+ [linear_id: $olid]}"
    ACTIONS+=("$omsg")
  fi
done

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
  # Completed items are pruned, not listed — Linear/commit history is the durable record.
  # Header kept (empty) for schema stability / manual future use.
  printf '\n## Completed\n\n'
} > "$NEW_INDEX"
rm -f "$HEADER_TMP"

# Change detection: compare rebuilt index to current, used to report "no changes" and to keep
# dry-run honest.
INDEX_CHANGED=0
if ! diff -q "$INDEX" "$NEW_INDEX" >/dev/null 2>&1; then
  INDEX_CHANGED=1
fi

# All prunes (index-driven "completed" slugs + orphan-driven prunes) — these delete the item file.
declare -a PRUNE_SLUGS=()
for slug in "${SLUG_ORDER[@]}"; do
  [ "${DISPOSITION[$slug]}" = "completed" ] || continue
  PRUNE_SLUGS+=("$slug")
done
PRUNE_SLUGS+=("${ORPHAN_PRUNE[@]}")

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$INDEX_CHANGED" -eq 0 ] && [ ${#PRUNE_SLUGS[@]} -eq 0 ] && [ ${#ORPHAN_KEEP[@]} -eq 0 ]; then
    printf 'reconcile (dry-run): no changes — index already consistent.\n'
  else
    printf 'reconcile (dry-run): planned actions:\n'
    for a in "${ACTIONS[@]}"; do printf '  - %s\n' "$a"; done
    [ "$INDEX_CHANGED" -eq 1 ] && printf '  - rewrite index: .claude/backlog.md\n'
  fi
  rm -f "$NEW_INDEX"
  exit 0
fi

# Apply: prune item files (index-driven + orphan), then swap the index in.
for slug in "${PRUNE_SLUGS[@]}"; do
  rm -f "$BACKLOG_DIR/${slug}.md"
done

if [ "$INDEX_CHANGED" -eq 1 ]; then
  mv "$NEW_INDEX" "$INDEX"
else
  rm -f "$NEW_INDEX"
fi

if [ "$INDEX_CHANGED" -eq 0 ] && [ ${#PRUNE_SLUGS[@]} -eq 0 ] && [ ${#ORPHAN_KEEP[@]} -eq 0 ]; then
  printf 'reconcile: no changes — index already consistent.\n'
else
  printf 'reconcile: applied %d action(s).\n' "${#ACTIONS[@]}"
  for a in "${ACTIONS[@]}"; do printf '  - %s\n' "$a"; done
fi
exit 0
