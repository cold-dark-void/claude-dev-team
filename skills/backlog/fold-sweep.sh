#!/usr/bin/env bash
# fold-sweep.sh — post-ship fold close-out sweep (subprocess-only, bash-only, no MCP).
#
# A release fold bundles several tickets, but nothing at ship closed their local
# backlog files or non-primary child Linear issues — status drift every ship.
# This sweep collects the ticket IDs/slugs named by a shipped fold commit (the
# subject's trailing (slug, ...) list and the matching CHANGELOG entry) and, for
# each one, closes the local write-through item via the ONE tested close verb
# (skills/backlog/close.sh — the same engine /backlog close, /orchestrate ship
# and /wrap-ticket use; this script never writes tracker files itself and never
# forks the write path). Non-fatal by contract: callers run it post-push with
# `|| true` — a sweep failure must never fail a release or a wrap.
#
# Usage:
#   fold-sweep.sh --commit SHA [--root PATH] [--changelog PATH] [--linear-close-cmd CMD]
#   fold-sweep.sh --find-fold TOKEN [--root PATH] [--changelog PATH] [--linear-close-cmd CMD]
#
# Exactly one of --commit / --find-fold is required.
#   --commit SHA       the fold commit to sweep (e.g. the pushed /release HEAD).
#   --find-fold TOKEN  locate the newest fold commit (subject `fix:|feat: vX.Y.Z —
#                      … (slug, …)`) whose trailing slug list names TOKEN — the
#                      /wrap-ticket path (runs on master history post-merge).
#                      No match is a calm one-line skip, exit 0.
#
# ROOT (SPEC-009 § Backlog root rule): --root PATH if set, else $MROOT (the parent
# of `git rev-parse --git-common-dir`), else pwd. The CHANGELOG body is read from
# the fold commit blob first (the fold carries its own entry), falling back to
# --changelog PATH, then ROOT/CHANGELOG.md.
#
# Linear (SPEC-009 posture — bash engines never call MCP): for each item this
# sweep FLIPS (already-closed files are skipped without writes) that carries a
# `linear_id` frontmatter id, the engine either
#   - invokes `--linear-close-cmd CMD` with the id as argv 1 (test/CI seam; the
#     stub records the call, production callers never set it), or
#   - prints `linear-close: <ID>` for the owning session to mark Done via MCP,
#     best-effort: unreachable → one line, local write stands, continue.
# An item without linear_id is a silent skip.
#
# Exit: 0 ok (swept, or calm skip), 64 usage, 1 engine failure (never from a
# per-slug close failure — those are logged and counted, then exit 0).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

USAGE='Usage: fold-sweep.sh (--commit SHA | --find-fold TOKEN)
                 [--root PATH] [--changelog PATH] [--linear-close-cmd CMD]'

ROOT=""
COMMIT=""
FIND_TOKEN=""
CHANGELOG=""
LINEAR_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 || die 64 "--commit needs value" ;;
    --find-fold) FIND_TOKEN="${2:-}"; shift 2 || die 64 "--find-fold needs value" ;;
    --root) ROOT="${2:-}"; shift 2 || die 64 "--root needs value" ;;
    --changelog) CHANGELOG="${2:-}"; shift 2 || die 64 "--changelog needs value" ;;
    --linear-close-cmd) LINEAR_CMD="${2:-}"; shift 2 || die 64 "--linear-close-cmd needs value" ;;
    -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
    -*) die 64 "unknown option: $1" ;;
    *) die 64 "unexpected argument: $1" ;;
  esac
done

if [ -z "$COMMIT" ] && [ -z "$FIND_TOKEN" ]; then
  die 64 "exactly one of --commit / --find-fold is required"$'\n'"$USAGE"
fi
if [ -n "$COMMIT" ] && [ -n "$FIND_TOKEN" ]; then
  die 64 "--commit and --find-fold are mutually exclusive"$'\n'"$USAGE"
fi

# Charset for path-safe slugs/tokens — same as close.sh / reconcile (CDT-175).
valid_slug() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# resolve_root (SPEC-009 C3): --root if set, else $MROOT (the parent of
# `git rev-parse --git-common-dir`), else pwd outside git. Identical body to
# close.sh / reconcile.sh.
resolve_root() {
  if [ -n "$ROOT" ]; then [ -d "$ROOT" ] || die 1 "root not a directory: $ROOT"; ROOT=$(cd "$ROOT" && pwd); return 0; fi
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then ROOT=$(cd "$(dirname "$_gc")" && pwd); return 0; fi
  ROOT=$(pwd)
}

# Read linear_id from YAML frontmatter (same shape as close.sh / reconcile.sh).
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

# tok_matches TOKEN ITEM — fold-token match (advisor B1 B2): case-insensitive;
# TOKEN equals ITEM or ITEM starts with "${TOKEN}-" (CDT-900 matches cdt-900
# and cdt-900-some-title, never cdt-9000-some-title).
tok_matches() {
  local t item
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  item=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  if [ "$item" = "$t" ]; then
    return 0
  fi
  case "$item" in
    "$t"-*) return 0 ;;
  esac
  return 1
}

# tok_in_list TOKEN LIST — LIST is comma/semicolon separated (a fold subject's
# trailing `(slug, …)` payload; v1.22.19 used `; `). tok_matches per item.
tok_in_list() {
  local t="$1" rest item
  rest=$(printf '%s' "$2" | tr ';' ',')
  rest="$rest,"
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    item=$(printf '%s' "$item" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    if tok_matches "$t" "$item"; then
      return 0
    fi
    rest="${rest#*,}"
  done
  return 1
}

# slug_list_from_text TEXT — print the whitespace/comma/semicolon-separated
# tokens found inside TEXT's parenthetical groups, one per line. Callers only
# act on tokens that name an existing item file, but TEXT must already be
# scoped to a real slug list (a subject's trailing parens, or a changelog
# LEAD's trailing parens) — whole-body scans harvest junk parens.
slug_list_from_text() {
  printf '%s\n' "$1" | grep -oE '\([^)]*\)' 2>/dev/null \
    | tr ',();' '    ' | tr -s '[:space:]' '\n' || true
}

# changelog_lead_list SECTION — tokens of the section's lead bullet's trailing
# `(slug, …)` list: the same string lead-summary.sh puts on the fold subject.
# Detail bullets are never scanned (advisor B1: role lists like
# `(reviewer, scout, …)` in a detail must stay inert).
#
# The bold span is a BRE capture group: `\([^*]*\)`. Plain `([^*]*)` is a literal
# paren pair, so `\1` had no group to name, GNU sed died on "invalid reference
# \1", and the CHANGELOG lead never contributed a slug (CDT-574-C7).
changelog_lead_list() {
  local bullet lead list
  bullet=$(printf '%s\n' "$1" | grep -m1 -E '^[[:space:]]*-[[:space:]]*\*\*' || true)
  [ -n "$bullet" ] || return 0
  lead=$(printf '%s' "$bullet" | sed -n 's/^[[:space:]]*-[[:space:]]*\*\*\([^*]*\)\*\*.*/\1/p')
  [ -n "$lead" ] || return 0
  list=$(printf '%s' "$lead" | sed -n 's/.*(\([^)]*\))[[:space:]]*$/\1/p')
  [ -n "$list" ] || return 0
  slug_list_from_text "($list)"
}

# changelog_section CHANGELOG_TEXT VERSION — body of `### v<VERSION>` / `### <VERSION>`
# up to the next `### ` heading.
#
# awk reads the whole input and stops with a flag; it MUST NOT `exit` early. An
# early exit closes the read end of the pipe, `printf` (the writer) dies on
# SIGPIPE, and `set -o pipefail` turns the pipeline into status 141, which
# `set -e` propagates. Any fold section followed by a later `### ` heading with
# more than the pipe buffer (64 KB) after it is a real CHANGELOG section, so the
# sweep died before it closed anything (CDT-574-C7).
changelog_section() {
  printf '%s\n' "$1" | awk -v ver="^### v?${2}[[:space:]]*$" '
    stop { next }
    $0 ~ ver { grab=1; next }
    /^### / { if (grab) { stop=1; grab=0; next } }
    grab { print }
  '
}

# Engine needs git for the fold subject / changelog blob. Not a repo → calm skip
# (post-push sweep is never error-shaped against its caller).
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'fold-sweep: not a git repo — nothing to sweep.\n'
  exit 0
fi

resolve_root
BACKLOG_DIR="$ROOT/.claude/backlog"
CLOSE="$SCRIPT_DIR/close.sh"
[ -f "$CLOSE" ] || die 1 "missing helper: $CLOSE"

# ---- resolve the fold commit ---------------------------------------------

if [ -n "$FIND_TOKEN" ]; then
  valid_slug "$FIND_TOKEN" || die 64 "invalid --find-fold token: $FIND_TOKEN"
  COMMIT=""
  while IFS=$'\t' read -r sha subj; do
    [ -n "$sha" ] || continue
    # Fold convention: `type: vX.Y.Z — <lead> (slug, ...)` — lead-summary.sh
    # derives the subject from the CHANGELOG lead, so the slug list rides along.
    printf '%s' "$subj" | grep -qE '^(fix|feat): v[0-9]+\.[0-9]+\.[0-9]+ ' || continue
    list=$(printf '%s' "$subj" | sed -n 's/.*(\([^)]*\))[[:space:]]*$/\1/p')
    [ -n "$list" ] || continue
    if tok_in_list "$FIND_TOKEN" "$list"; then
      COMMIT="$sha"
      break
    fi
  done < <(git log --extended-regexp --grep='^(fix|feat): v' --format='%H%x09%s')
  if [ -z "$COMMIT" ]; then
    printf 'fold-sweep: no fold commit naming %s — nothing to sweep.\n' "$FIND_TOKEN"
    exit 0
  fi
fi

git cat-file -e "${COMMIT}^{commit}" 2>/dev/null || die 1 "not a commit: $COMMIT"
# Pin the full sha: short refs / HEAD would land verbatim in the close footer.
COMMIT=$(git rev-parse --verify "${COMMIT}^{commit}")

subj=$(git show -s --format=%s "$COMMIT")
ver=$(printf '%s' "$subj" | sed -nE 's/^(fix|feat): v([0-9]+\.[0-9]+\.[0-9]+) .*/\2/p')
list=$(printf '%s' "$subj" | sed -n 's/.*(\([^)]*\))[[:space:]]*$/\1/p')

# ---- collect candidate slugs (fold subject + its CHANGELOG entry) ---------

cl=$(git show "$COMMIT":CHANGELOG.md 2>/dev/null) || cl=""
if [ -z "$cl" ] && [ -n "$CHANGELOG" ] && [ -f "$CHANGELOG" ]; then
  cl=$(cat "$CHANGELOG")
fi
if [ -z "$cl" ] && [ -f "$ROOT/CHANGELOG.md" ]; then
  cl=$(cat "$ROOT/CHANGELOG.md")
fi

ALL_TOKS=""
[ -n "$list" ] && ALL_TOKS="$ALL_TOKS
$(slug_list_from_text "($list)")"
if [ -n "$cl" ] && [ -n "$ver" ]; then
  section=$(changelog_section "$cl" "$ver")
  [ -n "$section" ] && ALL_TOKS="$ALL_TOKS
$(changelog_lead_list "$section")"
elif [ -n "$cl" ]; then
  # No version in the subject — nothing to scope the changelog section with;
  # the subject's own slug list still stands.
  :
fi

# Unique, charset-valid candidate order (exact-line membership, never a
# substring case — cdt-900 must not dedupe against cdt-9000).
CANDIDATES=""
for tok in $(printf '%s\n' "$ALL_TOKS" | sed '/^$/d'); do
  valid_slug "$tok" || continue
  if printf '%s\n' "$CANDIDATES" | grep -qFx "$tok"; then
    continue
  fi
  CANDIDATES="$CANDIDATES
$tok"
done
CANDIDATES=${CANDIDATES#"
"}

if [ -z "$CANDIDATES" ]; then
  printf 'fold-sweep: fold %s carries no slug list — nothing to sweep.\n' "$COMMIT"
  exit 0
fi

# ---- sweep ----------------------------------------------------------------

FLIPPED=0
ALREADY=0
LINEAR=0
SKIPPED=0

for slug in $CANDIDATES; do
  file="$BACKLOG_DIR/${slug}.md"
  if [ ! -f "$file" ]; then
    # No local write-through under this slug — calm skip (Linear-only / already
    # pruned). Never fuzzy-match a different item by title.
    SKIPPED=$((SKIPPED + 1))
    printf 'fold-sweep: no local item for %s — skip.\n' "$slug" >&2
    continue
  fi
  set +e
  if [ -n "$ver" ]; then
    close_out=$(bash "$CLOSE" "$slug" --root "$ROOT" --ticket "v$ver" --sha "$COMMIT" 2>&1)
  else
    close_out=$(bash "$CLOSE" "$slug" --root "$ROOT" --sha "$COMMIT" 2>&1)
  fi
  close_rc=$?
  set -e
  if printf '%s\n' "$close_out" | grep -q '^Closed: '; then
    FLIPPED=$((FLIPPED + 1))
    flipped=1
  elif printf '%s\n' "$close_out" | grep -q '^Already closed: '; then
    ALREADY=$((ALREADY + 1))
    flipped=0
  else
    SKIPPED=$((SKIPPED + 1))
    printf 'fold-sweep: close failed for %s (rc %s): %s\n' "$slug" "$close_rc" "$close_out" >&2
    continue
  fi
  # Linear is best-effort and only for items this sweep actually flipped —
  # an already-closed file must not re-issue a Linear write (idempotency).
  if [ "$flipped" -eq 1 ]; then
    lid=$(item_linear_id "$file")
    if [ -n "$lid" ]; then
      if [ -n "$LINEAR_CMD" ]; then
        set +e
        bash "$LINEAR_CMD" "$lid"
        lin_rc=$?
        set -e
        if [ "$lin_rc" -eq 0 ]; then
          LINEAR=$((LINEAR + 1))
        else
          printf 'fold-sweep: linear-close failed for %s — local write stands.\n' "$lid" >&2
        fi
      else
        printf 'linear-close: %s\n' "$lid"
        LINEAR=$((LINEAR + 1))
      fi
    fi
  fi
done

printf 'fold-sweep: flipped=%d already-closed=%d linear=%d skipped=%d\n' \
  "$FLIPPED" "$ALREADY" "$LINEAR" "$SKIPPED"
exit 0
