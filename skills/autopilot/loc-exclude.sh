#!/usr/bin/env bash
#
# autopilot/loc-exclude.sh — SPEC-033 M15 arms 1–2 (CDT-223).
# Counted-LOC exclusion helper.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   loc-exclude.sh is-excluded <path>
#
# Exit:
#   0   excluded (do not count)
#   1   count
#  64   usage
#
# MUST NOT exit 2 (would kill an orchestrate run). Fail-open on git check-attr
# errors (treat as unspecified). Missing/malformed .gitattributes → arm 1 empty;
# arm 2 still runs.
#
# Arm 1: git check-attr linguist-generated -- <path> reports set or true
#        (false / unspecified do not exclude via this arm).
# Arm 2: built-in lockfile basenames, basename *.snap, vendored prefixes
#        vendor/ third_party/ node_modules/ after stripping leading ./
#        (path equals the prefix or starts with prefix/). Mid-path
#        src/vendor/x does NOT match. *.pb.go / *_gen.* are NOT built-in.
#
# Arm 3 (SPEC-009 specs/tests) stays with the CALLER — this helper does NOT
# classify test files.

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: loc-exclude.sh is-excluded <path>'

die() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

# ---- Usage ------------------------------------------------------------------
[ $# -eq 2 ] || die "loc-exclude.sh requires: is-excluded <path> (got $# args)"
[ "$1" = "is-excluded" ] || die "unknown command '$1' (want is-excluded)"
[ -n "$2" ] || die "path must be non-empty"

path="$2"

# Strip leading ./ for arm-2 prefix + basename (M15). Do not classify tests.
rel="$path"
while [ "${rel#./}" != "$rel" ]; do
  rel="${rel#./}"
done
base="${rel##*/}"

# ---- Arm 2: built-in lockfile / snap / vendored prefix ----------------------
case "$base" in
  package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb|Cargo.lock|composer.lock|Gemfile.lock|poetry.lock|Pipfile.lock|uv.lock|flake.lock|go.sum|*.snap)
    exit 0
    ;;
esac

case "$rel" in
  vendor|vendor/*|third_party|third_party/*|node_modules|node_modules/*)
    exit 0
    ;;
esac

# ---- Arm 1: linguist-generated (fail-open → unspecified) --------------------
if command -v git >/dev/null 2>&1; then
  if attr_line=$(git check-attr linguist-generated -- "$path" 2>/dev/null); then
    case "${attr_line##*: }" in
      set|true) exit 0 ;;
    esac
  fi
fi

exit 1
