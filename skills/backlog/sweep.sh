#!/usr/bin/env bash
# sweep.sh — Backlog sweep helper CLI (SPEC-040). Pure subprocess — no LLM, no
# network, no MCP. The protocol that calls these verbs lives in skills/backlog/sweep.md.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT (SPEC-040 M2).
#
# Usage:
#   sweep.sh compile-ship --ship=<pr|master|patch|minor|major>
#   sweep.sh compile-orchestrate-args --size <S|M|L> [--council-tier <skip|light|full>] [--ship <val>]
#   sweep.sh last-release-tag [--root PATH]
#   sweep.sh tag-date --root PATH --tag TAG
#   sweep.sh evidence-paths-absent --root PATH -- path [path...]
#   sweep.sh evidence-shipped-after --root PATH --added YYYY-MM-DD
#   sweep.sh journal-append --file PATH --json JSON
#   sweep.sh walk-outcome --landed | --halt <condition>
#   sweep.sh journal-skip --file PATH --tag-date <ISO-8601> [--refresh] [--skip-decided]
#   sweep.sh merge-open --linear-json FILE --local-root PATH
#   sweep.sh walk-sort                       # JSONL on stdin, JSONL on stdout
#   sweep.sh is-epic-child --frontmatter FILE
#   sweep.sh is-epic-child --parent-id ID
#   sweep.sh parse-flags [--ship <v>] [--limit <N>] [--project <X>]
#                        [--refresh] [--skip-decided] [--autopilot]
#   sweep.sh summary --counts JSON
#
# Verb contracts (SPEC-040 requirement ids):
#   compile-ship (M17) — stdout is the autopilot argv for /orchestrate: `pr` prints
#     nothing, `master` and `patch|minor|major` print `--autopilot=<val>`. A bad
#     value exits 64. The literal string `--ship` never appears in stdout.
#   compile-orchestrate-args (M15, M17) — Triage size to council tier:
#     S -> `--tier=light`, M -> `--tier` omitted (orchestrate Step 2 is the
#     authority), L -> `--tier=full`. `--council-tier` is appended only when the
#     caller passes it (user-set only). `--ship` is optional: when it is present the
#     compile-ship result is appended last; when it is absent or empty no autopilot
#     argv is emitted, which is the attended default (run /orchestrate with no
#     --autopilot flag). stdout is one space-separated argv line.
#   last-release-tag (M21) — stdout is the newest local tag whose name passes
#     is_release_tag, in committer-date order, or nothing when there is none
#     (empty stdout, exit 0 — the M21 empty baseline). A --root that is not a
#     directory exits 1.
#     The regex is never inlined here: the function text is lifted from
#     ../release/check-ship-history.sh (see load_is_release_tag). `git describe`
#     is never called — it picks non-release tags.
#   tag-date (M22) — stdout is the ISO-8601 date a release tag carries, the tag's
#     own annotated tagger date, else the committer date of the commit the tag
#     points at (the two steps of tag_date()). It is the Step 2 baseline the
#     protocol snapshots once and passes to journal-skip --tag-date. A tag with no
#     resolvable date, a non-repo root, or a missing --root/--tag exits 1 / 64.
#   evidence-paths-absent (M9(a), M25) — the purge CLOSE bar for stale cited paths.
#     Exit 0 when every cited path is absent at HEAD (the HEAD tree and the index are
#     both probes; a present path is a negative verdict, so exit 1 = ASK, not CLOSE).
#     Paths arrive as argv after `--` and go to git as one pathspec each, so a space,
#     a shell metacharacter, or an SQL fragment stays data. A root that is not a repo
#     with a HEAD exits 1 — fail closed, never a false CLOSE. stdout is the Mechanical
#     evidence: one cite per path, the missing-count, and the HEAD committer date.
#   evidence-shipped-after (M9(b)) — the purge CLOSE bar for an already-shipped fix.
#     Exit 0 when a cite is strictly after --added. Cites: each `### vX.Y.Z` heading
#     in ROOT/CHANGELOG.md, dated from its tag (annotated tagger date, else the date
#     of the commit the tag points at) and, where no tag resolves, from a
#     YYYY-MM-DD inside that section; plus each `**Created**: YYYY-MM-DD` line under
#     ROOT/specs. stdout is the Mechanical evidence: the two newest cites with dates
#     and the verdict line. An equal date, an older cite, or no cite exits 1 (ASK).
#   There is NO evidence-symbol-exists verb (SPEC-040 M9 and the MUST NOT list):
#     grep symbol-exists is ASK-only and never a CLOSE. The purge protocol in
#     skills/backlog/sweep.md keeps it there.
#   journal-append (M20) — appends one JSONL object to --file, creating the parent
#     directory. Required keys: ts, disposition, evidence, args, tag_baseline.
#     `outcome` is optional: the intent record omits it, the completed record sets
#     it to one of closed|shipped|pr-stopped|deferred|asked-answered.
#   walk-outcome (M20) — maps one walk run onto that closed outcome enum: --landed
#     prints `shipped`, --halt <condition> prints `pr-stopped`. A child run's own
#     named halt condition (SPEC-033: complexity-overflow, bc5-reroute, ...) is not
#     an outcome value; the protocol records the name in the record's `evidence`
#     string. No flag, both flags, a duplicate --halt, or an empty value exits 64.
#   journal-skip (M22) — exit 0 = skip this item (print why), exit 1 = re-judge.
#     A record whose outcome is terminal and whose ts is at or after --tag-date
#     skips. An empty --tag-date (no release tag) never skips on the date compare.
#     A record with no outcome re-judges. --refresh re-judges everything.
#     --skip-decided skips on any terminal outcome. Both flags exit 64.
#   merge-open (M5) — stdout only (stdin unused): the open set, one JSONL object per
#     item, deduped by linear_id then slug. Linear rows come from --linear-json (an
#     array, or an object carrying an `issues`/`nodes` array; `parentId` is read when
#     present; an empty or absent file is the Linear-down case). Local rows come from
#     <local-root>/.claude/backlog/*.md: frontmatter linear_id + epic_parent,
#     **Status**, *Added:*. Open local statuses only (terminal-status.sh). A
#     local-only PENDING row is open. --root is an alias for the SPEC-009 backlog
#     root when --local-root is absent. --project is NOT handled here: the Linear
#     query is the caller's job (M5).
#     Object schema: {"slug","linear_id","title","priority","added","source",
#     "status","epic_parent","epic_child","size"}. source is linear | local | both
#     (a Linear row with no local write-through keeps slug "" — M11). size is ""
#     here; the protocol triages and fills it before walk-sort.
#   walk-sort (M16) — sorts the open set: size S, M, L; within a bucket Linear
#     priority 1,2,3,4,0; local-only items last, by added ascending. An absent or
#     unknown size sorts as M (orchestrate Step 2 stays the size authority).
#   is-epic-child (M7) — exit 0 = epic child, so SKIP it; exit 1 = not a child.
#     An empty --parent-id is not a child.
#   parse-flags (M18, M22) — accepts --ship <v> (or --ship=<v>), --limit <N>,
#     --project <X>, --refresh, --skip-decided, --autopilot[=<true|false>], and a
#     `--` terminator. A bump belongs on --ship: `--autopilot=patch` is a usage
#     error, not a ship intent. Any other token, a duplicate value flag, a
#     non-integer --limit, a bad --ship, or --refresh with --skip-decided exits 64
#     (before any write: this verb writes nothing). stdout is one JSON object
#     {"ship","limit","project","refresh","skip_decided","autopilot"}.
#     Under --autopilot an unset --ship defaults to master (M17).
#   summary (M24) — --counts is a JSON object
#     {"open":N,"CLOSE":n,"ASK":n,"ORCHESTRATE":n,"DEFER":n,"SKIP":n,"escalations":n};
#     a missing key counts 0. Prints N open, the five disposition buckets, and
#     escalations. Exit 0; a non-zero sweep exit is machinery failure only.
#
# Untrusted ticket text (M25): title, body, Affects and slug reach this script as
# argv or as a JSON file path. Values go to jq with --arg and to git with argv
# only. This script never evals, never bash -c's, and never builds a shell command
# from item content. The one eval is load_is_release_tag, over plugin-shipped
# source it checks first.
#
# Exit codes: 0 ok / skip, 1 negative verdict or machinery failure, 64 usage.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHIP_HIST_SH="$SCRIPT_DIR/../release/check-ship-history.sh"
TS_SH="$SCRIPT_DIR/terminal-status.sh"

USAGE='Usage: sweep.sh <verb> [options]
  compile-ship --ship=<pr|master|patch|minor|major>
  compile-orchestrate-args --size <S|M|L> [--council-tier <skip|light|full>] [--ship <val>]
  last-release-tag [--root PATH]
  tag-date --root PATH --tag TAG
  evidence-paths-absent --root PATH -- path [path...]
  evidence-shipped-after --root PATH --added YYYY-MM-DD
  journal-append --file PATH --json JSON
  walk-outcome --landed | --halt <condition>
  journal-skip --file PATH --tag-date <ISO-8601> [--refresh] [--skip-decided]
  merge-open --linear-json FILE --local-root PATH   # --root PATH is an alias
  walk-sort                      (JSONL on stdin)
  is-epic-child --frontmatter FILE | --parent-id ID
  parse-flags [--ship <v>] [--limit <N>] [--project <X>] [--refresh] [--skip-decided] [--autopilot]
  summary --counts JSON
Exit: 0 ok/skip, 1 negative verdict, 64 usage.'

die() {
  local rc="$1"; shift
  printf 'sweep.sh: %s\n' "$*" >&2
  exit "$rc"
}

usage_err() {
  printf 'sweep.sh: %s\n' "$1" >&2
  printf '%s\n' "$USAGE" >&2
  exit 64
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die 1 "jq is required for the $1 verb"
}

# LF or CR in an argv value would inject rows into the journal and the printed
# summary (same guard as close.sh § reject_ctrl).
reject_ctrl() {
  case "$1" in
    *$'\n'*|*$'\r'*) usage_err "option value must not contain a newline or CR: $2" ;;
  esac
}

# ---- shared helpers (sourced, never copied) --------------------------------
# valid_slug comes from slug.sh — the one copy, shared with close.sh and defer.sh
# (CDT-175). item_status_value and item_title come from readers.sh — the one copy,
# shared with close.sh. Both files are source-only; die() above reports a missing
# helper.
[ -f "$SCRIPT_DIR/slug.sh" ] || die 1 "missing helper: $SCRIPT_DIR/slug.sh"
# shellcheck source=slug.sh
. "$SCRIPT_DIR/slug.sh"
[ -f "$SCRIPT_DIR/readers.sh" ] || die 1 "missing helper: $SCRIPT_DIR/readers.sh"
# shellcheck source=readers.sh
. "$SCRIPT_DIR/readers.sh"

# fm_value <file> <key> — first value of a top-level YAML frontmatter key.
fm_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { in_fm = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && index($0, key ":") == 1 {
      sub("^" key ":[[:space:]]*", "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file" 2>/dev/null || true
}

item_linear_id() {
  fm_value "$1" linear_id
}

item_added() {
  sed -n 's/^\*Added:[[:space:]]*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$1" 2>/dev/null | head -n1 || true
}

# is_closed_status <status> — shared terminal classifier (SPEC-009; DEFERRED is open).
is_closed_status() {
  bash "$TS_SH" is-closed "$1"
}

# ---- release-tag probe (M21) ---------------------------------------------

# Lift is_release_tag out of check-ship-history.sh. That file runs its gate at
# top level (it exits 64 when sourced), so source only its function text. The
# eval target is the plugin-shipped helper file, checked before the eval — never
# item text (M25).
load_is_release_tag() {
  local fn
  [ -f "$SHIP_HIST_SH" ] || die 1 "missing helper: $SHIP_HIST_SH"
  fn=$(awk '/^is_release_tag\(\)/ { f = 1 } f { print } f && /^\}/ { exit }' "$SHIP_HIST_SH") \
    || die 1 "cannot read is_release_tag from $SHIP_HIST_SH"
  printf '%s\n' "$fn" | head -n1 | grep -qE '^is_release_tag\(\) \{$' \
    || die 1 "unexpected is_release_tag definition in $SHIP_HIST_SH"
  eval "$fn"
}

# ---- small validators -----------------------------------------------------

validate_ship() {
  case "$1" in
    pr|master|patch|minor|major) return 0 ;;
  esac
  return 1
}

validate_council_tier() {
  case "$1" in
    skip|light|full) return 0 ;;
  esac
  return 1
}

is_terminal_outcome() {
  [ -n "$1" ] || return 1
  case "$1" in
    closed|shipped|pr-stopped|deferred|asked-answered) return 0 ;;
  esac
  return 1
}

# iso_to_epoch <ISO-8601> — seconds, or rc 1. GNU date takes offsets natively;
# the BSD fallback parses the local-wall clock and drops the offset.
iso_to_epoch() {
  local s="$1" t
  case "$s" in
    '') return 1 ;;
    *[!0-9]*) ;;
    *) printf '%s\n' "$s"; return 0 ;;
  esac
  if date -u -d "$s" +%s 2>/dev/null; then
    return 0
  fi
  t="${s%Z}"
  # Strip a trailing +HH:MM / -HH:MM offset only; the date hyphens must stay.
  case "$t" in
    *[+-][0-9][0-9]:[0-9][0-9]) t="${t%??????}" ;;
  esac
  [ -n "$t" ] || return 1
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$t" +%s 2>/dev/null
}

# resolve_root <value> — SPEC-009 § Backlog root rule: the given path, else
# $MROOT (parent of `git rev-parse --git-common-dir`), else pwd. The rule
# close.sh and defer.sh apply; here the path arrives as an argument. Sets ROOT.
resolve_root() {
  local given="$1" _gc
  if [ -n "$given" ]; then
    [ -d "$given" ] || die 1 "root not a directory: $given"
    ROOT=$(cd "$given" && pwd)
    return 0
  fi
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    ROOT=$(cd "$(dirname "$_gc")" && pwd)
    return 0
  fi
  ROOT=$(pwd)
}

# ---- compile-ship (M17) ---------------------------------------------------

# ship_argv <value> — prints the autopilot argv for /orchestrate (no trailing
# newline; `pr` prints nothing). rc 1 on a bad value.
ship_argv() {
  validate_ship "$1" || return 1
  case "$1" in
    pr) : ;;
    *) printf -- '--autopilot=%s' "$1" ;;
  esac
}

cmd_compile_ship() {
  local ship=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ship) [ $# -ge 2 ] || usage_err "--ship needs value"; ship="$2"; shift 2 ;;
      --ship=*) ship="${1#--ship=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "compile-ship: unexpected argument: $1" ;;
    esac
  done
  [ -n "$ship" ] || usage_err "compile-ship: --ship is required"
  ship_argv "$ship" || usage_err "invalid --ship '$ship' (expected pr|master|patch|minor|major)"
  printf '\n'
}

# ---- compile-orchestrate-args (M15, M17) ---------------------------------

cmd_compile_orchestrate_args() {
  local size="" ship="" ctier="" have_ctier=0 have_ship=0
  local ap=""
  local -a out=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --size) [ $# -ge 2 ] || usage_err "--size needs value"; size="$2"; shift 2 ;;
      --size=*) size="${1#--size=}"; shift ;;
      --ship) [ $# -ge 2 ] || usage_err "--ship needs value"; ship="$2"; have_ship=1; shift 2 ;;
      --ship=*) ship="${1#--ship=}"; have_ship=1; shift ;;
      --council-tier) [ $# -ge 2 ] || usage_err "--council-tier needs value"; ctier="$2"; have_ctier=1; shift 2 ;;
      --council-tier=*) ctier="${1#--council-tier=}"; have_ctier=1; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "compile-orchestrate-args: unexpected argument: $1" ;;
    esac
  done
  [ -n "$size" ] || usage_err "compile-orchestrate-args: --size is required"
  case "$size" in
    S) out+=("--tier=light") ;;
    M) ;;
    L) out+=("--tier=full") ;;
    *) usage_err "invalid --size '$size' (expected S|M|L)" ;;
  esac
  if [ "$have_ctier" -eq 1 ]; then
    reject_ctrl "$ctier" --council-tier
    validate_council_tier "$ctier" \
      || usage_err "invalid --council-tier '$ctier' (expected skip|light|full)"
    out+=("--council-tier=$ctier")
  fi
  # Attended default (M17, sweep.md Step 9b): an absent or empty --ship emits no
  # autopilot argv, so /orchestrate runs with no --autopilot flag. A value that is
  # present must still be a valid one.
  if [ "$have_ship" -eq 1 ] && [ -n "$ship" ]; then
    reject_ctrl "$ship" --ship
    ap=$(ship_argv "$ship") \
      || usage_err "invalid --ship '$ship' (expected pr|master|patch|minor|major)"
    if [ -n "$ap" ]; then
      out+=("$ap")
    fi
  fi
  printf '%s\n' "${out[*]+"${out[*]}"}"
}

# ---- last-release-tag (M21) ----------------------------------------------

cmd_last_release_tag() {
  local root_arg="" t
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage_err "--root needs value"; root_arg="$2"; shift 2 ;;
      --root=*) root_arg="${1#--root=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "last-release-tag: unexpected argument: $1" ;;
    esac
  done
  load_is_release_tag
  ROOT=""
  resolve_root "$root_arg"
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  while IFS= read -r t || [ -n "$t" ]; do
    [ -n "$t" ] || continue
    is_release_tag "$t" || continue
    printf '%s\n' "$t"
    return 0
  done < <(git -C "$ROOT" for-each-ref --sort=-committerdate --format='%(refname:short)' refs/tags/)
  exit 0
}

# ---- tag-date (M22) ------------------------------------------------------

# The Step 2 baseline date. Same two steps as the internal tag_date() used by
# evidence-shipped-after, rendered ISO-8601 so journal-skip can compare it with a
# record ts. The tag name arrives as argv and is probed as a ref, never as a shell
# word (M25).
cmd_tag_date() {
  local root_arg="" tag="" d
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage_err "--root needs value"; root_arg="$2"; shift 2 ;;
      --root=*) root_arg="${1#--root=}"; shift ;;
      --tag) [ $# -ge 2 ] || usage_err "--tag needs value"; tag="$2"; shift 2 ;;
      --tag=*) tag="${1#--tag=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "tag-date: unexpected argument: $1" ;;
    esac
  done
  [ -n "$root_arg" ] || usage_err "tag-date: --root is required"
  [ -n "$tag" ] || usage_err "tag-date: --tag is required"
  reject_ctrl "$tag" --tag
  case "$tag" in
    -*) usage_err "tag-date: --tag must not start with '-': $tag" ;;
  esac
  ROOT=""
  resolve_root "$root_arg"
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die 1 "not a git repository: $ROOT"
  d=$(tag_date "$ROOT" "$tag" iso8601-strict) || die 1 "no date resolves for tag: $tag"
  printf '%s\n' "$d"
}

# ---- evidence-paths-absent (M9(a)) --------------------------------------

# path_in_head <root> <path> — exit 0 when the path is in the HEAD tree. The path
# is one argv pathspec after `--`, so a space, a shell metacharacter, or an SQL
# fragment stays data (M25). `-r` lists a directory's entries, so a directory path
# is present when it holds anything. A glob pathspec can only add matches, so it
# never yields a false absent — the safe polarity for a CLOSE.
path_in_head() {
  local out
  out=$(git -C "$1" ls-tree -r --name-only HEAD -- "$2" 2>/dev/null) || return 1
  [ -n "$out" ]
}

# path_in_index <root> <path> — exit 0 when the path is staged (index, not HEAD).
# A staged file exists in the working tree, so it is present for the evidence bar.
path_in_index() {
  local out
  out=$(git -C "$1" ls-files -- "$2" 2>/dev/null) || return 1
  [ -n "$out" ]
}

cmd_evidence_paths_absent() {
  local root_arg="" sep=0 p n=0 absent=0 sha cdate
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage_err "--root needs value"; root_arg="$2"; shift 2 ;;
      --root=*) root_arg="${1#--root=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      --) shift; sep=1; break ;;
      *) usage_err "evidence-paths-absent: paths must follow -- (got: $1)" ;;
    esac
  done
  [ "$sep" -eq 1 ] || usage_err "evidence-paths-absent: -- is required before the path list"
  [ $# -gt 0 ] || usage_err "evidence-paths-absent: at least one path is required after --"
  [ -n "$root_arg" ] || usage_err "evidence-paths-absent: --root is required"
  for p in "$@"; do
    reject_ctrl "$p" "path"
    case "$p" in
      '') usage_err "evidence-paths-absent: empty path" ;;
      -*) usage_err "evidence-paths-absent: path must not start with '-': $p" ;;
      /*) usage_err "evidence-paths-absent: path must be repo-relative: $p" ;;
    esac
    n=$((n + 1))
  done
  ROOT=""
  resolve_root "$root_arg"
  # Fail closed: an unjudgeable root is never a CLOSE (M9, M10).
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die 1 "not a git repository: $ROOT"
  sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) \
    || die 1 "no HEAD commit to judge against: $ROOT"
  cdate=$(git -C "$ROOT" log -1 --format=%cd --date=short HEAD 2>/dev/null) || cdate=""
  printf 'Mechanical evidence (paths-absent): %s cited path(s), HEAD %s %s\n' \
    "$n" "$sha" "$cdate" || die 1 "cannot write path evidence"
  for p in "$@"; do
    if path_in_head "$ROOT" "$p" || path_in_index "$ROOT" "$p"; then
      printf 'cite %s — present at HEAD: not CLOSE\n' "$p" \
        || die 1 "cannot write path evidence"
    else
      absent=$((absent + 1))
      printf 'cite %s — absent at HEAD\n' "$p" \
        || die 1 "cannot write path evidence"
    fi
  done
  printf 'missing-count: %s of %s\n' "$absent" "$n" \
    || die 1 "cannot write path evidence"
  [ "$absent" -eq "$n" ] || exit 1
  exit 0
}

# ---- evidence-shipped-after (M9(b)) -------------------------------------

# is_iso_date <value> — calendar form YYYY-MM-DD; no calendar range check.
is_iso_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
  esac
  return 1
}

# changelog_sections <file> — one line per release heading:
# <version>\t<heading-line>\t<first date in the section, else ->. The scan stops at
# the next `### ` heading, so the first date is that entry's own.
changelog_sections() {
  awk '
    BEGIN {
      ver = ""; line = 0; d = ""
      DATE_RE = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
    }
    function flush() {
      if (ver != "") printf "%s\t%d\t%s\n", ver, line, (d == "" ? "-" : d)
    }
    /^### / {
      flush()
      ver = ""; d = ""; line = NR
      if (match($0, /^### v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ver = substr($0, 5, RLENGTH - 4)
      }
      if (match($0, DATE_RE)) d = substr($0, RSTART, RLENGTH)
      next
    }
    ver != "" && d == "" && match($0, DATE_RE) { d = substr($0, RSTART, RLENGTH) }
    END { flush() }
  ' "$1" 2>/dev/null || true
}

# tag_date_ok <format> <value> — non-empty for an ISO-8601 render; the short form
# must be a bare calendar date.
tag_date_ok() {
  case "$1" in
    short) is_iso_date "$2" ;;
    *) [ -n "$2" ] ;;
  esac
}

# tag_date <root> <version> [format] — the date a release tag carries: the annotated
# tagger date, else the committer date of the commit the tag points at (a lightweight
# tag has no tagger date). format is a git date format (default short). rc 1 when no
# tag matches. Tag names are tried as written and with a leading `v`.
tag_date() {
  local root="$1" ver="$2" fmt="${3:-short}" ref d
  for ref in "refs/tags/$ver" "refs/tags/v${ver#v}"; do
    d=$(git -C "$root" for-each-ref --format="%(taggerdate:$fmt)" "$ref" 2>/dev/null) || d=""
    if tag_date_ok "$fmt" "$d"; then
      printf '%s\n' "$d"
      return 0
    fi
    d=$(git -C "$root" log -1 --format=%cd --date="$fmt" "$ref" 2>/dev/null) || d=""
    if tag_date_ok "$fmt" "$d"; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# ship_candidates <root> <outfile> — appends "date<TAB>cite" rows for every dated
# CHANGELOG release heading and every spec **Created** line. Read-only over the tree.
ship_candidates() {
  local root="$1" out="$2" ver line secd d f l hit
  local TAB=$'\t'
  if [ -f "$root/CHANGELOG.md" ]; then
    while IFS="$TAB" read -r ver line secd || [ -n "$ver" ]; do
      [ -n "$ver" ] || continue
      d=$(tag_date "$root" "$ver") || d="$secd"
      is_iso_date "$d" || continue
      printf '%s\tCHANGELOG.md:%s %s\n' "$d" "$line" "$ver" >> "$out" \
        || die 1 "cannot stage a shipped-after cite"
    done < <(changelog_sections "$root/CHANGELOG.md")
  fi
  if [ -d "$root/specs" ]; then
    while IFS= read -r hit || [ -n "$hit" ]; do
      [ -n "$hit" ] || continue
      # hit is "<file>:<line>:**Created**: <date>". The file part is split on the
      # first colon, so a spec path that carries a colon is not supported.
      f=${hit%%:*}
      l=${hit#*:}
      l=${l%%:*}
      case "$l" in
        ''|*[!0-9]*) continue ;;
      esac
      d=$(printf '%s' "$hit" | sed -n 's/^.*Created\*\*:[[:space:]]*\([0-9][0-9]*-[0-9][0-9]-[0-9][0-9]\).*$/\1/p')
      is_iso_date "$d" || continue
      printf '%s\t%s:%s Created\n' "$d" "${f#"$root"/}" "$l" >> "$out" \
        || die 1 "cannot stage a shipped-after cite"
    done < <(grep -rn --include='*.md' -e \
      '^\*\*Created\*\*:[[:space:]]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
      "$root/specs" 2>/dev/null)
  fi
}

cmd_evidence_shipped_after() {
  local root_arg="" added="" tmpd="" tmp="" sorted="" top="" d cite i=0 newest=""
  local TAB=$'\t'
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage_err "--root needs value"; root_arg="$2"; shift 2 ;;
      --root=*) root_arg="${1#--root=}"; shift ;;
      --added) [ $# -ge 2 ] || usage_err "--added needs value"; added="$2"; shift 2 ;;
      --added=*) added="${1#--added=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "evidence-shipped-after: unexpected argument: $1" ;;
    esac
  done
  [ -n "$root_arg" ] || usage_err "evidence-shipped-after: --root is required"
  [ -n "$added" ] || usage_err "evidence-shipped-after: --added is required"
  reject_ctrl "$added" --added
  is_iso_date "$added" \
    || usage_err "evidence-shipped-after: invalid --added '$added' (expected YYYY-MM-DD)"
  ROOT=""
  resolve_root "$root_arg"
  # One temp dir so no cite file can leak on a later failure.
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/sweep-ship.XXXXXX") \
    || die 1 "cannot create the shipped-after temp dir"
  trap 'rm -rf -- "$tmpd"' EXIT
  tmp="$tmpd/cand"
  sorted="$tmpd/sorted"
  top="$tmpd/top"
  : > "$tmp" || die 1 "cannot stage shipped-after cites"
  ship_candidates "$ROOT" "$tmp"
  LC_ALL=C sort -t "$TAB" -k1,1r -k2,2 "$tmp" -o "$sorted" \
    || die 1 "cannot sort shipped-after cites"
  head -n 2 "$sorted" > "$top" || die 1 "cannot take the two strongest cites"
  printf 'Mechanical evidence (shipped-after): added=%s root=%s\n' "$added" "$ROOT"
  while IFS="$TAB" read -r d cite || [ -n "$d" ]; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    [ -n "$newest" ] || newest="$d"
    printf 'cite %s: %s date=%s\n' "$i" "$cite" "$d" \
      || die 1 "cannot write shipped-after evidence"
  done < "$top"
  if [ "$i" -eq 0 ]; then
    printf 'verdict: NOT SHIPPED-AFTER (no dated CHANGELOG heading or spec Created cite)\n' \
      || die 1 "cannot write shipped-after evidence"
    exit 1
  fi
  # Strictly after: an equal date is ASK, not CLOSE (M9(b), M10).
  if [[ "$newest" > "$added" ]]; then
    printf 'verdict: SHIPPED-AFTER (newest cite %s is after added %s)\n' "$newest" "$added" \
      || die 1 "cannot write shipped-after evidence"
    exit 0
  fi
  printf 'verdict: NOT SHIPPED-AFTER (newest cite %s is not after added %s)\n' "$newest" "$added" \
    || die 1 "cannot write shipped-after evidence"
  exit 1
}

# ---- walk-outcome (M20) --------------------------------------------------

# Map a walk run onto the closed journal outcome enum. A child run halts with its
# own named condition (SPEC-033 blocking-condition, complexity-overflow, ...); that
# name is not a journal outcome, so the protocol calls this verb and records the
# name in the journal `evidence` string. The enum stays closed (SPEC-040 M20).
cmd_walk_outcome() {
  local landed=0 halt="" n_halt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --landed) landed=1; shift ;;
      --halt) [ $# -ge 2 ] || usage_err "--halt needs value"; halt="$2"; n_halt=$((n_halt + 1)); shift 2 ;;
      --halt=*) halt="${1#--halt=}"; n_halt=$((n_halt + 1)); shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "walk-outcome: unexpected argument: $1" ;;
    esac
  done
  if [ "$landed" -eq 1 ] && [ "$n_halt" -gt 0 ]; then
    usage_err "walk-outcome: use one of --landed or --halt"
  fi
  if [ "$n_halt" -gt 1 ]; then
    usage_err "walk-outcome: duplicate --halt"
  fi
  if [ "$landed" -eq 0 ] && [ "$n_halt" -eq 0 ]; then
    usage_err "walk-outcome: --landed or --halt <condition> is required"
  fi
  if [ "$n_halt" -eq 1 ]; then
    reject_ctrl "$halt" --halt
    [ -n "$halt" ] || usage_err "walk-outcome: --halt needs a non-empty condition"
    printf 'pr-stopped\n' || return 1
    return 0
  fi
  printf 'shipped\n'
}

# ---- journal-append (M20) ------------------------------------------------

JQ_JOURNAL_VALIDATE='
def bad(m): "error: " + m;
. as $o
| if ($o | type) != "object" then bad("json must be an object")
  elif ($o | has("ts") | not) then bad("missing ts")
  elif ($o | has("disposition") | not) then bad("missing disposition")
  elif ($o | has("evidence") | not) then bad("missing evidence")
  elif ($o | has("args") | not) then bad("missing args")
  elif ($o | has("tag_baseline") | not) then bad("missing tag_baseline")
  elif ($o.ts | type) != "string" then bad("ts must be a string")
  elif ($o.disposition | type) != "string" then bad("disposition must be a string")
  elif ($o.evidence | type) != "string" then bad("evidence must be a string")
  elif ($o.args | type) != "string" then bad("args must be a string")
  elif ($o.tag_baseline | type) != "string" then bad("tag_baseline must be a string")
  elif ($o.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}")) | not then
    bad("ts must be ISO-8601 (YYYY-MM-DDThh:mm)")
  elif (["CLOSE","ASK","ORCHESTRATE","DEFER"] | index($o.disposition)) | not then
    bad("disposition must be CLOSE|ASK|ORCHESTRATE|DEFER")
  elif ($o | has("outcome")) and ($o.outcome != null) and (($o.outcome | type) != "string") then
    bad("outcome must be a string")
  elif ($o | has("outcome")) and ($o.outcome != null)
       and ((["closed","shipped","pr-stopped","deferred","asked-answered"] | index($o.outcome)) | not) then
    bad("outcome must be closed|shipped|pr-stopped|deferred|asked-answered")
  else empty end
'

cmd_journal_append() {
  local file="" json="" parent line msg rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) [ $# -ge 2 ] || usage_err "--file needs value"; file="$2"; shift 2 ;;
      --file=*) file="${1#--file=}"; shift ;;
      --json) [ $# -ge 2 ] || usage_err "--json needs value"; json="$2"; shift 2 ;;
      --json=*) json="${1#--json=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "journal-append: unexpected argument: $1" ;;
    esac
  done
  [ -n "$file" ] || usage_err "journal-append: --file is required"
  [ -n "$json" ] || usage_err "journal-append: --json is required"
  reject_ctrl "$file" --file
  require_jq journal-append
  if ! line=$(printf '%s' "$json" | jq -c '.' 2>&1); then
    usage_err "journal-append: invalid JSON: $line"
  fi
  msg=$(printf '%s' "$json" | jq -r "$JQ_JOURNAL_VALIDATE" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    usage_err "journal-append: invalid JSON: $msg"
  fi
  if [ -n "$msg" ]; then
    usage_err "journal-append: ${msg#error: }"
  fi
  parent=$(dirname -- "$file")
  mkdir -p -- "$parent" || die 1 "cannot create journal directory: $parent"
  printf '%s\n' "$line" >> "$file" || die 1 "cannot append journal record: $file"
  printf '%s\n' "$line"
}

# ---- journal-skip (M22) --------------------------------------------------

cmd_journal_skip() {
  local file="" tagdate="" refresh=0 skip_decided=0 have_tagdate=0
  local rec outcome ts te be stem
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) [ $# -ge 2 ] || usage_err "--file needs value"; file="$2"; shift 2 ;;
      --file=*) file="${1#--file=}"; shift ;;
      --tag-date) [ $# -ge 2 ] || usage_err "--tag-date needs value"; tagdate="$2"; have_tagdate=1; shift 2 ;;
      --tag-date=*) tagdate="${1#--tag-date=}"; have_tagdate=1; shift ;;
      --refresh) refresh=1; shift ;;
      --skip-decided) skip_decided=1; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "journal-skip: unexpected argument: $1" ;;
    esac
  done
  [ -n "$file" ] || usage_err "journal-skip: --file is required"
  [ "$have_tagdate" -eq 1 ] || usage_err "journal-skip: --tag-date is required"
  reject_ctrl "$file" --file
  reject_ctrl "$tagdate" --tag-date
  if [ "$refresh" -eq 1 ] && [ "$skip_decided" -eq 1 ]; then
    usage_err "journal-skip: --refresh and --skip-decided are mutually exclusive"
  fi
  if [ "$refresh" -eq 1 ]; then
    exit 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    exit 1
  fi
  stem=${file##*/}
  stem=${stem%.jsonl}
  while IFS= read -r rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    ts=$(printf '%s' "$rec" | jq -r '(.ts // "") | tostring' 2>/dev/null) || continue
    outcome=$(printf '%s' "$rec" | jq -r '(.outcome // "") | tostring' 2>/dev/null) || continue
    is_terminal_outcome "$outcome" || continue
    if [ "$skip_decided" -eq 1 ]; then
      printf 'skip: journal %s outcome=%s ts=%s (skip-decided)\n' "$stem" "$outcome" "$ts"
      exit 0
    fi
    [ -n "$tagdate" ] || continue
    te=$(iso_to_epoch "$ts") || continue
    be=$(iso_to_epoch "$tagdate") || exit 1
    if [ "$te" -ge "$be" ]; then
      printf 'skip: journal %s outcome=%s ts=%s baseline=%s\n' "$stem" "$outcome" "$ts" "$tagdate"
      exit 0
    fi
  done < "$file"
  exit 1
}

# ---- merge-open (M5) ----------------------------------------------------

JQ_MERGE='
def txt(v): if v == null then "" elif (v | type) == "string" then v else (v | tostring) end;
def as_array(x): if (x | type) == "array" then x
  elif (x | type) == "object" then ((x.issues // x.nodes // x.issuesList // []))
  else [] end;
def rows(x): [ x[]
  | if (type == "array") then (.[] | select(type == "object"))
    elif (type == "object") then .
    else empty end ];
def okey: if (.linear_id | length) > 0 then "L:" + .linear_id else "S:" + .slug end;
(as_array($LIN[0] // [])) as $rawlin
| ( [ $rawlin[] | select(type == "object")
    | { linear_id: txt(.identifier // .id),
        slug: "",
        title: txt(.title // .name),
        priority: (if (.priority | type) == "number" then (.priority | floor) else 0 end),
        added: (txt(.createdAt // .created_at) | .[0:10]),
        parent_id: txt(.parentId // .parent_id),
        source: "linear",
        status: "OPEN",
        epic_parent: "" } ] ) as $lin
| ( [ rows($LOC)[]
    | { linear_id: txt(.linear_id),
        slug: txt(.slug),
        title: txt(.title),
        priority: 0,
        added: txt(.added),
        parent_id: "",
        source: "local",
        status: txt(.status),
        epic_parent: txt(.epic_parent) } ] ) as $loc
| ( [ $lin[] | select((.linear_id | length) > 0) | .linear_id ] ) as $lids
| ( [ $lin[]
    | . as $l
    | ( [ $loc[] | select((.linear_id | length) > 0 and .linear_id == $l.linear_id) ][0] ) as $m
    | if $m == null then $l
      else $l + { slug: $m.slug,
                  source: "both",
                  added: (if ($m.added | length) > 0 then $m.added else $l.added end),
                  status: $m.status,
                  epic_parent: $m.epic_parent }
      end ] ) as $merged
| ( [ $loc[]
    | . as $c
    | select(($c.linear_id | length) == 0 or (($lids | index($c.linear_id)) == null)) ] ) as $loconly
| ($merged + $loconly)
| map(. + { size: "",
            epic_child: ((.epic_parent | length) > 0 or (.parent_id | length) > 0) })
| unique_by(okey)
| .[]
'

# scan_local <root> <outfile> — open local items as JSONL (read-only).
scan_local() {
  local root="$1" out="$2"
  local dir="$root/.claude/backlog"
  local f slug status lid title added epc
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    slug=$(basename -- "$f" .md)
    valid_slug "$slug" || continue
    status=$(item_status_value "$f")
    is_closed_status "$status" && continue
    lid=$(item_linear_id "$f")
    title=$(item_title "$f")
    [ -n "$title" ] || title="$slug"
    added=$(item_added "$f")
    epc=$(fm_value "$f" epic_parent)
    jq -cn --arg slug "$slug" --arg linear_id "$lid" --arg title "$title" \
      --arg added "$added" --arg epic_parent "$epc" --arg status "$status" \
      '{slug:$slug,linear_id:$linear_id,title:$title,added:$added,epic_parent:$epic_parent,status:$status}' \
      >> "$out" || die 1 "cannot stage local backlog row: $slug"
  done
}

cmd_merge_open() {
  local linear_json="" local_root="" root_arg="" tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --linear-json) [ $# -ge 2 ] || usage_err "--linear-json needs value"; linear_json="$2"; shift 2 ;;
      --linear-json=*) linear_json="${1#--linear-json=}"; shift ;;
      --local-root) [ $# -ge 2 ] || usage_err "--local-root needs value"; local_root="$2"; shift 2 ;;
      --local-root=*) local_root="${1#--local-root=}"; shift ;;
      --root) [ $# -ge 2 ] || usage_err "--root needs value"; root_arg="$2"; shift 2 ;;
      --root=*) root_arg="${1#--root=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "merge-open: unexpected argument: $1" ;;
    esac
  done
  require_jq merge-open
  if [ -z "$local_root" ]; then
    ROOT=""
    resolve_root "$root_arg"
    local_root="$ROOT"
  fi
  [ -d "$local_root" ] || die 1 "local root not a directory: $local_root"
  if [ -z "$linear_json" ]; then
    linear_json=/dev/null
  elif [ ! -r "$linear_json" ]; then
    die 1 "unreadable --linear-json: $linear_json"
  fi
  if [ "$linear_json" != "/dev/null" ] && [ -s "$linear_json" ]; then
    jq -e 'type == "array" or type == "object"' "$linear_json" >/dev/null 2>&1 \
      || die 1 "malformed --linear-json (expected a JSON array or object): $linear_json"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/sweep-local.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  : > "$tmp" || die 1 "cannot stage local backlog rows"
  scan_local "$local_root" "$tmp"
  jq -cn --slurpfile LIN "$linear_json" --slurpfile LOC "$tmp" "$JQ_MERGE"
  rm -f -- "$tmp"
  trap - EXIT
}

# ---- walk-sort (M16) ----------------------------------------------------

JQ_WALK_SORT='
def size_rank: ({"S":0,"M":1,"L":2}[ (.size // "") ] // 1);
def src_rank: (if .source == "local" then 1 else 0 end);
def prio_rank: ({"1":0,"2":1,"3":2,"4":3,"0":4}[ ((.priority // 0) | floor | tostring) ] // 4);
def added_key: (if (.added // "") == "" then "9999-12-31" else .added end);
sort_by([size_rank, src_rank, prio_rank, added_key, (.linear_id // .slug // "")])[]
'

cmd_walk_sort() {
  require_jq walk-sort
  jq -c -s "$JQ_WALK_SORT"
}

# ---- is-epic-child (M7) -------------------------------------------------

cmd_is_epic_child() {
  local fm="" pid="" have_fm=0 have_pid=0 v
  while [ $# -gt 0 ]; do
    case "$1" in
      --frontmatter) [ $# -ge 2 ] || usage_err "--frontmatter needs value"; fm="$2"; have_fm=1; shift 2 ;;
      --frontmatter=*) fm="${1#--frontmatter=}"; have_fm=1; shift ;;
      --parent-id) [ $# -ge 2 ] || usage_err "--parent-id needs value"; pid="$2"; have_pid=1; shift 2 ;;
      --parent-id=*) pid="${1#--parent-id=}"; have_pid=1; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "is-epic-child: unexpected argument: $1" ;;
    esac
  done
  if [ "$have_fm" -eq 1 ] && [ "$have_pid" -eq 1 ]; then
    usage_err "is-epic-child: use one of --frontmatter or --parent-id"
  fi
  if [ "$have_fm" -eq 0 ] && [ "$have_pid" -eq 0 ]; then
    usage_err "is-epic-child: --frontmatter FILE or --parent-id ID is required"
  fi
  if [ "$have_pid" -eq 1 ]; then
    reject_ctrl "$pid" --parent-id
    if [ -n "$pid" ]; then
      exit 0
    fi
    exit 1
  fi
  reject_ctrl "$fm" --frontmatter
  [ -r "$fm" ] || die 1 "unreadable --frontmatter: $fm"
  v=$(fm_value "$fm" epic_parent)
  if [ -n "$v" ]; then
    exit 0
  fi
  exit 1
}

# ---- parse-flags --------------------------------------------------------

cmd_parse_flags() {
  local ship="" n_ship=0 limit=0 n_limit=0 project="" n_project=0
  local n_refresh=0 n_skip=0 n_ap=0
  local b_refresh b_skip b_ap
  while [ $# -gt 0 ]; do
    case "$1" in
      --ship)
        [ $# -ge 2 ] || usage_err "--ship needs value"
        ship="$2"; n_ship=$((n_ship + 1)); shift 2 ;;
      --ship=*) ship="${1#--ship=}"; n_ship=$((n_ship + 1)); shift ;;
      --limit)
        [ $# -ge 2 ] || usage_err "--limit needs value"
        limit="$2"; n_limit=$((n_limit + 1)); shift 2 ;;
      --limit=*) limit="${1#--limit=}"; n_limit=$((n_limit + 1)); shift ;;
      --project)
        [ $# -ge 2 ] || usage_err "--project needs value"
        project="$2"; n_project=$((n_project + 1)); shift 2 ;;
      --project=*) project="${1#--project=}"; n_project=$((n_project + 1)); shift ;;
      --refresh) n_refresh=$((n_refresh + 1)); shift ;;
      --skip-decided) n_skip=$((n_skip + 1)); shift ;;
      --autopilot) n_ap=$((n_ap + 1)); shift ;;
      --autopilot=false|--autopilot=0) n_ap=$((n_ap - 1)); shift ;;
      --autopilot=true|--autopilot=1) n_ap=$((n_ap + 1)); shift ;;
      --) shift; break ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "unknown flag: $1" ;;
    esac
  done
  [ $# -eq 0 ] || usage_err "unexpected argument: $1"
  [ "$n_ship" -le 1 ] || usage_err "duplicate --ship"
  [ "$n_limit" -le 1 ] || usage_err "duplicate --limit"
  [ "$n_project" -le 1 ] || usage_err "duplicate --project"
  if [ "$n_refresh" -gt 0 ] && [ "$n_skip" -gt 0 ]; then
    usage_err "--refresh and --skip-decided are mutually exclusive"
  fi
  if [ "$n_ship" -eq 1 ]; then
    reject_ctrl "$ship" --ship
    validate_ship "$ship" || usage_err "invalid --ship '$ship' (expected pr|master|patch|minor|major)"
  fi
  reject_ctrl "$limit" --limit
  case "$limit" in
    ''|*[!0-9]*) usage_err "invalid --limit '$limit' (expected an integer >= 0)" ;;
  esac
  # SPEC-040 M17: sweep --autopilot defaults --ship to master.
  if [ "$n_ap" -gt 0 ] && [ "$n_ship" -eq 0 ]; then
    ship="master"
  fi
  reject_ctrl "$project" --project
  require_jq parse-flags
  b_refresh=false
  b_skip=false
  b_ap=false
  [ "$n_refresh" -gt 0 ] && b_refresh=true
  [ "$n_skip" -gt 0 ] && b_skip=true
  [ "$n_ap" -gt 0 ] && b_ap=true
  jq -cn --arg ship "$ship" --arg project "$project" \
    --argjson limit "$limit" \
    --argjson refresh "$b_refresh" \
    --argjson skip_decided "$b_skip" \
    --argjson autopilot "$b_ap" \
    '{ship:$ship, limit:$limit, project:$project, refresh:$refresh, skip_decided:$skip_decided, autopilot:$autopilot}'
}

# ---- summary (M24) ------------------------------------------------------

cmd_summary() {
  local counts="" out
  while [ $# -gt 0 ]; do
    case "$1" in
      --counts) [ $# -ge 2 ] || usage_err "--counts needs value"; counts="$2"; shift 2 ;;
      --counts=*) counts="${1#--counts=}"; shift ;;
      -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
      *) usage_err "summary: unexpected argument: $1" ;;
    esac
  done
  [ -n "$counts" ] || usage_err "summary: --counts is required"
  require_jq summary
  out=$(printf '%s' "$counts" | jq -r '
    def g(k): . as $o | (if ($o[k] | type) == "number" then ($o[k] | floor) else 0 end);
    if type != "object" then "error: counts must be a JSON object"
    else "Sweep summary: \(g("open")) open",
         "CLOSE \(g("CLOSE"))",
         "ASK \(g("ASK"))",
         "ORCHESTRATE \(g("ORCHESTRATE"))",
         "DEFER \(g("DEFER"))",
         "SKIP \(g("SKIP"))",
         "escalations \(g("escalations"))"
    end' 2>&1) || usage_err "summary: invalid counts JSON: $out"
  case "$out" in
    error:*) usage_err "summary: ${out#error: }" ;;
  esac
  printf '%s\n' "$out"
}

# ---- dispatch -----------------------------------------------------------

VERB="${1:-}"
[ -n "$VERB" ] || usage_err "missing <verb>"
shift
case "$VERB" in
  compile-ship) cmd_compile_ship "$@" ;;
  compile-orchestrate-args) cmd_compile_orchestrate_args "$@" ;;
  last-release-tag) cmd_last_release_tag "$@" ;;
  tag-date) cmd_tag_date "$@" ;;
  evidence-paths-absent) cmd_evidence_paths_absent "$@" ;;
  evidence-shipped-after) cmd_evidence_shipped_after "$@" ;;
  journal-append) cmd_journal_append "$@" ;;
  walk-outcome) cmd_walk_outcome "$@" ;;
  journal-skip) cmd_journal_skip "$@" ;;
  merge-open) cmd_merge_open "$@" ;;
  walk-sort) cmd_walk_sort "$@" ;;
  is-epic-child) cmd_is_epic_child "$@" ;;
  parse-flags) cmd_parse_flags "$@" ;;
  summary) cmd_summary "$@" ;;
  -h|--help|help) printf '%s\n' "$USAGE"; exit 0 ;;
  *) usage_err "unknown verb: $VERB" ;;
esac
