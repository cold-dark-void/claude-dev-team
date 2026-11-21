#!/usr/bin/env bash
# SPEC-010 CDT-655 pre-release keyword guard: refuse a bump keyword while the
# current version carries a pre-release suffix.
# Pure subprocess — no LLM, no network, no index mutation.
#
# A bump keyword on `2.0.0-pre.N` computes the final `X.Y.Z` (SPEC-010 §
# Pre-release arc scheme P1) and cuts the arc mid-flight — the CDT-628
# failure. While the version carries a pre-release suffix, only an explicit
# version argument may drive a release.
#
# Usage:
#   refuse-pre-keyword.sh <patch|minor|major>
#
# Exit: 0 ok (final version — the keyword may compute)
#       1 refusal (pre-release version — pass an explicit version)
#       64 usage
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: refuse-pre-keyword.sh <patch|minor|major>

Refuses (exit 1) when the current plugin.json version carries a pre-release
suffix — a bump keyword there would compute the final X.Y.Z and cut the arc
mid-flight (SPEC-010 CDT-655). Pass an explicit version to /release instead.

Exit 0 ok; 1 refusal; 64 usage. Does not mutate the index.
EOF
}

[ $# -eq 1 ] || { usage; exit 64; }
case "$1" in
  patch|minor|major) KEYWORD="$1" ;;
  *) usage; exit 64 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "refuse-pre-keyword.sh: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)
VERSION=""
if [ -r "$ROOT/.claude-plugin/plugin.json" ]; then
  VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -1)
fi
if [ -z "$VERSION" ]; then
  echo "refuse-pre-keyword.sh: cannot read a version from $ROOT/.claude-plugin/plugin.json" >&2
  exit 64
fi

VERSION=${VERSION#v}
case "$VERSION" in
  *-*)
    echo "refuse-pre-keyword.sh: refuse $KEYWORD on pre-release version $VERSION — a bump keyword would compute the final version and cut the arc mid-flight (SPEC-010 CDT-655); pass an explicit version instead" >&2
    exit 1
    ;;
esac

echo "refuse-pre-keyword.sh: ok — version $VERSION is final; $KEYWORD may compute"
