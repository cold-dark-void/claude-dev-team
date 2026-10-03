#!/usr/bin/env bash
# reconcile.sh — deterministic, idempotent backlog index↔item-file repair (subprocess-only, never source).
#
# Brings ROOT/.claude/backlog.md into agreement with ROOT/.claude/backlog/<slug>.md item files
# (and, when supplied, with Linear-resolved terminal-state verdicts). Hygiene only — never invents
# new backlog items. See specs/core/SPEC-009-ticket-workflow.md §"Backlog reconcile" and
# §"Backlog write integrity (WP 1-04)".
#
# Usage:
#   reconcile.sh [--root PATH] [--dry-run] [--linear-verdicts FILE]
#
# ROOT (SPEC-009 § Backlog root rule): --root PATH if set, else $MROOT (the parent of
# `git rev-parse --git-common-dir` — the same shared root `/backlog add` writes), else `pwd`
# outside a git repository. Every linked worktree therefore reconciles the one shared store.
#
# Lock (SPEC-009 § Backlog write integrity): apply mode (i.e. not --dry-run) holds the shared
# backlog lock (`<root>/.claude/backlog.lock`, skills/backlog/lock.sh) for the whole
# read-decide-write. A busy lock exits 1 with the lock path on stderr, no file changed.
# --dry-run writes nothing and never takes the lock.
#
# Line-preserving apply (SPEC-009 § Line-preserving reconcile): this script drops only the index
# rows it decides to remove — terminal (pruned), dead-reference and duplicate. Every other line
# (headings, prose, blank lines, nested content, kept rows) stays byte-identical and in its
# original position. No add, move, re-order or re-tag. A run that drops no row does not rewrite
# the index at all (mtime/inode untouched).
#
# Verdicts (SPEC-009 § Blank verdict is non-terminal, CDT-267): a blank state — a TSV line with an
# empty state, a bare slug line with no state, or a JSON state of "" or null — is non-terminal: it
# has no effect and the slug falls through to its local item-file status. JSON verdicts are parsed
# with jq only, never a regex; jq absent with JSON input is a hard failure (exit 1, no writes). A
# TSV verdicts file needs no jq.
#
# LOCAL pass (always):
#   - Rows whose item file Status is terminal per shared classifier terminal-status.sh
#     (COMPLETED/DONE/FIXED*/CLOSED/CANCELLED/…; case-insensitive token-match) → PRUNED
#     (item file deleted, index row dropped). Linear (when linked) or git/commit history is the
#     durable record for done work — the local write-through is a disposable cache, not an archive.
#   - Index rows with no corresponding item file → REMOVED (dead references).
#   - Duplicate rows for one slug → collapse to a single row (keep the first-seen row verbatim).
#   - Item files with NO index row at all (orphans — never dual-written, or predate this convention)
#     → pruned when their own Status is already terminal; otherwise left untouched and reported,
#     since deleting unindexed OPEN work would be a silent loss.
# LINEAR pass (when --linear-verdicts FILE given):
#   - FILE is a TSV/JSON of slug→terminal-state, resolved by the CALLING Claude session (which has MCP).
#     Slugs listed as terminal (Done/Cancelled/Completed) take PRECEDENCE over local status: the row
#     is pruned the same as a locally-terminal item. This script does NOT call MCP.
#
# Does NOT commit — local write-through only; never stage process trackers.
#
# Exit: 0 ok (reconciled or already clean), 1 error (no index/dir, malformed verdicts, lock busy),
# 64 usage.

set -euo pipefail

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

# Self-relative helpers (install-correct in a dev checkout, a marketplace clone and the cache
# alike; SPEC-009 § Backlog write integrity). Sourced, never subprocess: the lock's traps and
# state must live in this shell.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "$SCRIPT_DIR/lock.sh" ] || die 1 "missing helper: $SCRIPT_DIR/lock.sh"
. "$SCRIPT_DIR/lock.sh"
[ -f "$SCRIPT_DIR/../lib/portable.sh" ] || die 1 "missing helper: $SCRIPT_DIR/../lib/portable.sh"
. "$SCRIPT_DIR/../lib/portable.sh"

USAGE='Usage: reconcile.sh [--root PATH] [--dry-run] [--linear-verdicts FILE]
  --root PATH             backlog root (else $MROOT — the parent of `git rev-parse
                          --git-common-dir` — else pwd)
  --dry-run               print planned actions; write nothing; never takes the lock
  --linear-verdicts FILE  TSV/JSON of slug→terminal-state (Linear SoT; precedence over
                          local status; a blank state is non-terminal)'

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

# C3 — root resolution (SPEC-009 § Backlog root rule; identical body in close.sh).
resolve_root() {
  if [ -n "$ROOT" ]; then [ -d "$ROOT" ] || die 1 "root not a directory: $ROOT"; ROOT=$(cd "$ROOT" && pwd); return 0; fi
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then ROOT=$(cd "$(dirname "$_gc")" && pwd); return 0; fi
  ROOT=$(pwd)
}

# Shared terminal classifier (CDT-160) — contract lives in terminal-status.sh (SPEC-009).
# Blank-state-in-verdicts short-circuit stays at load_verdicts call sites (not here).
_TS="$SCRIPT_DIR/terminal-status.sh"
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

# C4 — verdict JSON filter (jq only, fail closed; SPEC-009 § Verdict JSON). Accepts a flat object
# or an array of objects; slug wins over id, state wins over status; a null value counts as
# absent. Checked with jq 1.8.1 fed 9 samples directly to this filter (bypassing load_verdicts'
# own detection below): flat, array, slug>id, state>status, [1], "str", {"a":1}, missing slug,
# parse error. Detection of JSON vs TSV never reaches jq on "str": a verdicts file is JSON iff
# its first non-blank character is "{" or "[" (SPEC-009 § Verdict JSON); a bare "str" fails that
# check and load_verdicts reads it as TSV instead.
VERDICT_JQ='
def s: if . == null then "" elif type == "string" then . else error("state not a string") end;
if type == "object" then to_entries[] | [.key, (.value | s)]
elif type == "array" then .[] | if type != "object" then error("element not an object")
  else [ (if .slug != null then .slug else .id end), ((if .state != null then .state else .status end) | s) ] end
else error("top-level not an object or array") end
| if (.[0] | type) != "string" or .[0] == "" then error("missing slug") else . end
| @tsv
'

# Load Linear verdicts file into VERDICT_SLUGS (assoc: slug -> 1 if terminal). Pure read; runs
# BEFORE the lock — a malformed file exits 1 with no lock ever taken and no writes.
# Supports two shapes:
#   TSV : lines "<slug>\t<state>"  (state matched by is_closed_status; blank state = non-terminal)
#   JSON: a flat object {"<slug>":"<state>",...} OR an array of objects each carrying a
#         "slug"/"id" and a "state"/"status" key, parsed by jq only (VERDICT_JQ above).
# Non-terminal states are ignored (they never override local; local may still close them).
# bash 3.2 has no associative arrays (CDT-285): each slug map below is a
# key/value pair of parallel arrays with a linear lookup. Slugs are short
# backlog ids and the keys are data (never evaled).
BL_VERDICT_KEYS=(); BL_VERDICT_VALS=()
BL_SEEN_KEYS=();     BL_SEEN_VALS=()
BL_ROWTEXT_KEYS=();  BL_ROWTEXT_VALS=()
BL_DISP_KEYS=();     BL_DISP_VALS=()

_bl_verdict_set() { # mark <slug> terminal
  local i=0
  while [ "$i" -lt "${#BL_VERDICT_KEYS[@]}" ]; do
    [ "${BL_VERDICT_KEYS[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  BL_VERDICT_KEYS+=("$1")
  BL_VERDICT_VALS+=(1)
  return 0
}
_bl_verdict_has() { # rc 0 iff <slug> has a terminal verdict
  local i=0
  while [ "$i" -lt "${#BL_VERDICT_KEYS[@]}" ]; do
    [ "${BL_VERDICT_KEYS[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  return 1
}
_bl_seen_has() { # rc 0 iff <slug> already recorded from the index
  local i=0
  while [ "$i" -lt "${#BL_SEEN_KEYS[@]}" ]; do
    [ "${BL_SEEN_KEYS[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  return 1
}
_bl_seen_set() {
  BL_SEEN_KEYS+=("$1")
  BL_SEEN_VALS+=(1)
  return 0
}
_bl_rowtext_set() {
  BL_ROWTEXT_KEYS+=("$1")
  BL_ROWTEXT_VALS+=("$2")
  return 0
}
_bl_disp_set() { # _bl_disp_set <slug> <pending|completed|missing|invalid>
  local i=0
  while [ "$i" -lt "${#BL_DISP_KEYS[@]}" ]; do
    [ "${BL_DISP_KEYS[$i]}" = "$1" ] && { BL_DISP_VALS[$i]="$2"; return 0; }
    i=$((i + 1))
  done
  BL_DISP_KEYS+=("$1")
  BL_DISP_VALS+=("$2")
  return 0
}
_bl_disp_get() { # prints the disposition of <slug>, or "" when absent
  local i=0
  while [ "$i" -lt "${#BL_DISP_KEYS[@]}" ]; do
    [ "${BL_DISP_KEYS[$i]}" = "$1" ] && { printf '%s' "${BL_DISP_VALS[$i]}"; return 0; }
    i=$((i + 1))
  done
  return 0
}
load_verdicts() {
  [ -n "$VERDICTS_FILE" ] || return 0
  [ -f "$VERDICTS_FILE" ] || die 1 "linear-verdicts file not found: $VERDICTS_FILE"
  local first
  # Format detection (SPEC-009 § Verdict JSON): JSON iff the file's first non-blank
  # character is { or [; skip leading blank/whitespace-only lines first, then test.
  first=$(grep -m1 -v -E '^[[:space:]]*$' "$VERDICTS_FILE" 2>/dev/null || true)
  if printf '%s' "$first" | grep -qE '^[[:space:]]*[[{]'; then
    command -v jq >/dev/null 2>&1 || die 1 "jq required to read JSON verdicts: $VERDICTS_FILE"
    local pairs slug state
    pairs=$(jq -r "$VERDICT_JQ" "$VERDICTS_FILE" 2>/dev/null) || die 1 "malformed verdicts JSON: $VERDICTS_FILE"
    while IFS=$'\t' read -r slug state; do
      [ -n "$slug" ] || continue
      # Blank state is non-terminal (CDT-267): no effect, never sets VERDICT_SLUGS.
      if [ -n "$state" ] && is_closed_status "$state"; then
        _bl_verdict_set "$slug"
      fi
    done <<< "$pairs"
  else
    # TSV: <slug>\t<state>
    local slug state
    # || [ -n "$slug" ]: read a final unterminated line too (WP 1-04 rework T4-1).
    while IFS=$'\t' read -r slug state _ || [ -n "$slug" ]; do
      slug=$(printf '%s' "$slug" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -n "$slug" ] || continue
      case "$slug" in \#*) continue ;; esac
      # Blank state is non-terminal (CDT-267): no effect, never sets VERDICT_SLUGS.
      if [ -n "$state" ] && is_closed_status "$state"; then
        _bl_verdict_set "$slug"
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

# Shared lock: the whole read-decide-write below. --dry-run writes nothing and never locks.
if [ "$DRY_RUN" -eq 0 ]; then
  backlog_lock_acquire "$ROOT" || exit $?
fi

# Planned-action log (dry-run and summary). Populated during the scan.
declare -a ACTIONS=()
# Count of index rows this run drops: duplicate-row occurrences plus the first row of every
# missing/completed slug. DROPPED > 0 is the sole trigger to rewrite the index at all.
DROPPED=0

# For each unique slug in the index, decide its terminal disposition:
#   missing   → row removed (dead ref)
#   completed → row + item file PRUNED (deleted)
#   pending   → row stays, verbatim
#   invalid   → row stays, verbatim (charset guard; never touches the filesystem)
# Duplicate rows for one slug always collapse to the first-seen row (kept only if that first
# row's own disposition is pending/invalid).

# Collect ordered unique slugs + first-seen row text, and count duplicate occurrences.
# bash 3.2 has no associative arrays (CDT-285): each slug map below is a
declare -a SLUG_ORDER=()    # slugs in first-seen order
declare -a INVALID_SLUGS=() # slugs that failed the charset guard

# || [ -n "$line" ]: also classify a final row with no trailing newline (else
# pass 1 silently drops it, and it re-appears as a false ORPHAN below — WP 1-04
# rework T4-1).
while IFS= read -r line || [ -n "$line" ]; do
  slug=$(row_slug "$line")
  [ -n "$slug" ] || continue
  if _bl_seen_has "$slug"; then
    ACTIONS+=("collapse duplicate row for '$slug'")
    DROPPED=$((DROPPED + 1))
    continue
  fi
  _bl_seen_set "$slug"
  SLUG_ORDER+=("$slug")
  _bl_rowtext_set "$slug" "$line"
done < "$INDEX"

# Classify each unique slug.
for slug in ${SLUG_ORDER[@]+"${SLUG_ORDER[@]}"}; do
  if [[ ! "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
    _bl_disp_set "$slug" "invalid"
    INVALID_SLUGS+=("$slug")
    ACTIONS+=("INVALID slug not reconciled (only [A-Za-z0-9_-] allowed): $slug — row kept, no file touched; needs manual triage")
    continue
  fi
  item="$BACKLOG_DIR/${slug}.md"
  if [ ! -f "$item" ]; then
    _bl_disp_set "$slug" "missing"
    ACTIONS+=("remove dead-ref row for '$slug' (no item file)")
    DROPPED=$((DROPPED + 1))
    continue
  fi
  lid=$(item_linear_id "$item")
  lid_suffix="${lid:+ [linear_id: $lid]}"
  if _bl_verdict_has "$slug"; then
    _bl_disp_set "$slug" "completed"
    ACTIONS+=("prune '$slug' (Linear verdict: terminal)${lid_suffix}")
    DROPPED=$((DROPPED + 1))
    continue
  fi
  st=$(item_status_value "$item")
  if is_closed_status "$st"; then
    _bl_disp_set "$slug" "completed"
    ACTIONS+=("prune '$slug' (item Status=${st:-COMPLETED})${lid_suffix}")
    DROPPED=$((DROPPED + 1))
  else
    _bl_disp_set "$slug" "pending"
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
  _bl_seen_has "$oslug" && continue
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

# Line-preserving: the index is rewritten iff at least one row drops.
INDEX_CHANGED=0
[ "$DROPPED" -gt 0 ] && INDEX_CHANGED=1

# All prunes (index-driven "completed" slugs + orphan-driven prunes) — these delete the item file.
declare -a PRUNE_SLUGS=()
for slug in ${SLUG_ORDER[@]+"${SLUG_ORDER[@]}"}; do
  [ "$(_bl_disp_get "$slug")" = "completed" ] || continue
  PRUNE_SLUGS+=("$slug")
done
PRUNE_SLUGS+=(${ORPHAN_PRUNE[@]+"${ORPHAN_PRUNE[@]}"})

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$INDEX_CHANGED" -eq 0 ] && [ ${#PRUNE_SLUGS[@]} -eq 0 ] && [ ${#ORPHAN_KEEP[@]} -eq 0 ] && [ ${#INVALID_SLUGS[@]} -eq 0 ]; then
    printf 'reconcile (dry-run): no changes — index already consistent.\n'
  else
    printf 'reconcile (dry-run): planned actions:\n'
    for a in ${ACTIONS[@]+"${ACTIONS[@]}"}; do printf '  - %s\n' "$a"; done
    [ "$INDEX_CHANGED" -eq 1 ] && printf '  - rewrite index: .claude/backlog.md\n'
  fi
  exit 0
fi

# emit_index — line-preserving stream producer for atomic_write (SPEC-009 § Line-preserving
# reconcile). Streams $INDEX; prints every non-row line verbatim; for a row line, prints only the
# first occurrence of a pending/invalid slug verbatim; drops every duplicate occurrence and every
# first-occurrence row of a missing/completed slug. No add, move, re-order or re-tag.
# Every write returns its own failure (|| return 1): atomic_write runs this
# producer inside an `if`, so errexit is off in here — an unguarded printf that
# fails mid-stream (ENOSPC/EIO) would otherwise be masked by a later successful
# command, and a truncated temp file would get renamed over the index (WP 1-04
# rework T4-2).
emit_index() {
  local _line _slug _read_rc _ek _bl_hit
  [ -r "$INDEX" ] || return 1
  # bash 3.2: no associative arrays (CDT-285) — emitted slugs are a plain array.
  local _emitted_keys=()
  while true; do
    IFS= read -r _line
    _read_rc=$?
    if [ "$_read_rc" -gt 1 ]; then
      return 1
    fi
    if [ "$_read_rc" -ne 0 ] && [ -z "$_line" ]; then
      break
    fi
    _slug=$(row_slug "$_line")
    if [ -z "$_slug" ]; then
      printf '%s\n' "$_line" || return 1
      continue
    fi
    _bl_hit=0
    for _ek in ${_emitted_keys[@]+"${_emitted_keys[@]}"}; do
      [ "$_ek" = "$_slug" ] && { _bl_hit=1; break; }
    done
    if [ "$_bl_hit" -eq 1 ]; then
      continue
    fi
    _emitted_keys+=("$_slug")
    case "$(_bl_disp_get "$_slug")" in
      pending|invalid) printf '%s\n' "$_line" || return 1 ;;
      *) ;;
    esac
  done < "$INDEX"
}

# Apply order: index first (atomic_write), then prune item files. A crash between the two leaves
# a terminal orphan on disk — the next run prunes it — never a dangling index row.
if [ "$INDEX_CHANGED" -eq 1 ]; then
  atomic_write "$INDEX" emit_index || die 1 "failed to write index: $INDEX"
fi

for slug in ${PRUNE_SLUGS[@]+"${PRUNE_SLUGS[@]}"}; do
  rm -f "${BACKLOG_DIR:?}/${slug:?}.md"
done

if [ "$INDEX_CHANGED" -eq 0 ] && [ ${#PRUNE_SLUGS[@]} -eq 0 ] && [ ${#ORPHAN_KEEP[@]} -eq 0 ] && [ ${#INVALID_SLUGS[@]} -eq 0 ]; then
  printf 'reconcile: no changes — index already consistent.\n'
else
  printf 'reconcile: applied %d action(s).\n' "${#ACTIONS[@]}"
  for a in ${ACTIONS[@]+"${ACTIONS[@]}"}; do printf '  - %s\n' "$a"; done
fi
exit 0
