#!/usr/bin/env bash
# SPEC-010 Step 0.5: record the ship-start commit and take a tag snapshot
# so a later step (check-ship-history.sh --tag-snapshot) can detect a tag
# that was retargeted mid-release (D4).
#
# Usage:
#   ship-start.sh                # default: write a fresh snapshot
#   ship-start.sh --path SHA     # print the snapshot path for SHA; writes nothing
#   ship-start.sh --list         # print the current tag table to stdout; writes nothing
#   ship-start.sh --clear        # delete every snapshot of this worktree's git dir
#   ship-start.sh -h|--help      # usage on stdout, exit 0
#
# Env (default mode only): SHIP_START_SHA overrides HEAD as the ship-start
# commit (used to re-take a snapshot after a confirmed history rewrite).
#
# Snapshot path: $(git rev-parse --absolute-git-dir)/dev-team-release/tags-<40hex>.tsv
#
# --list is the sole source of the <refname><TAB><peeled-commit-sha> tag
# table (SPEC-010 R2): one for-each-ref call, peeled in-place. Default mode
# writes this same table to TAG_SNAPSHOT; check-ship-history.sh reads it via
# `ship-start.sh --list` too, so the peeling rule lives in exactly one place.
#
# Exit: 0 ok; 64 usage / not a repo / unborn HEAD / bad ambient SHA.
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ship-start.sh [--path SHA | --list | --clear] [-h|--help]

Default mode: records the ship-start commit (HEAD, or SHIP_START_SHA if set)
and writes a tag snapshot for later D4 (retargeted tag) detection. Prints:
  SHIP_START=<40hex>
  TAG_SNAPSHOT=<abs path>
  LAST_TAG=<tag or empty>

--path SHA   print the snapshot path that SHA would use; writes nothing.
--list       print the current refs/tags/* table (<refname><TAB><commit>,
             one line per tag that peels to a commit, sorted) to stdout;
             writes nothing. This is the same table default mode writes to
             TAG_SNAPSHOT.
--clear      delete every snapshot under this worktree's git dir.

Exit 0 ok; 64 usage / not a repo / unborn HEAD / bad ambient SHA.
EOF
}

MODE=default
PATH_SHA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --path)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "ship-start.sh: --path requires a SHA" >&2; usage >&2; exit 64; }
      MODE=path
      PATH_SHA="$2"
      shift 2
      ;;
    --list) MODE=list; shift ;;
    --clear) MODE=clear; shift ;;
    -h|--help) usage; exit 0 ;;
    --*)
      echo "ship-start.sh: unknown flag: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      echo "ship-start.sh: unexpected argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

# Prints "<refname>\t<peeled-commit-sha>" for every refs/tags/* ref that
# points at a commit, directly (lightweight) or via one annotated tag
# object (peeled), sorted by refname. Never inspects a tag's ref-log.
list_tags() {
  git for-each-ref \
    --format='%(refname)%09%(objecttype)%09%(objectname)%09%(*objecttype)%09%(*objectname)' \
    refs/tags |
    while IFS=$'\t' read -r refname otype oname ptype pname; do
      if [ "$otype" = commit ]; then
        printf '%s\t%s\n' "$refname" "$oname"
      elif [ "$ptype" = commit ]; then
        printf '%s\t%s\n' "$refname" "$pname"
      fi
    done | LC_ALL=C sort
}

if ! GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null); then
  echo "ship-start.sh: not a git repository" >&2
  exit 64
fi
DIR="$GITDIR/dev-team-release"

if [ "$MODE" = clear ]; then
  rm -f "$DIR"/tags-*.tsv
  rmdir "$DIR" 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = path ]; then
  SHA40=$(git rev-parse --verify "${PATH_SHA}^{commit}" 2>/dev/null) || {
    echo "ship-start.sh: --path: unresolvable SHA=$PATH_SHA" >&2
    exit 64
  }
  echo "$DIR/tags-$SHA40.tsv"
  exit 0
fi

if [ "$MODE" = list ]; then
  list_tags
  exit 0
fi

# default mode
if [ -n "${SHIP_START_SHA:-}" ]; then
  SHIP_START=$(git rev-parse --verify "${SHIP_START_SHA}^{commit}" 2>/dev/null) || {
    echo "release: unresolvable ambient SHIP_START_SHA=$SHIP_START_SHA" >&2
    exit 64
  }
else
  SHIP_START=$(git rev-parse --verify HEAD 2>/dev/null) || {
    echo "ship-start.sh: unborn HEAD — no commits yet" >&2
    exit 64
  }
fi

mkdir -p "$DIR"
FILE="$DIR/tags-$SHIP_START.tsv"
TMP=$(mktemp "$DIR/tags-XXXXXX")
trap 'rm -f "$TMP"' EXIT

list_tags >"$TMP"

mv -f "$TMP" "$FILE"

find "$DIR" -maxdepth 1 -type f -name 'tags-*.tsv' ! -name "$(basename "$FILE")" -delete

LAST_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null) || LAST_TAG=""

echo "SHIP_START=$SHIP_START"
echo "TAG_SNAPSHOT=$FILE"
echo "LAST_TAG=$LAST_TAG"
exit 0
