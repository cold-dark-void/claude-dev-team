#!/usr/bin/env bash
# SPEC-033 CDT-597 master-tag gate: the tip of the default branch must equal
# a release tag at every pushed state. An untagged fold on master is the
# untracked-ship failure this ticket closes — the work landed with no version,
# no tag, and no CHANGELOG entry.
#
# The one exception needs no special case: the /release fold commit is itself
# the tagged tip, so the same check passes it.
#
# Pure subprocess — no LLM, no network, no ref mutation.
#
# Usage:
#   check-master-tagged.sh <new-tip-sha>
#
# Exit: 0 the tip carries an exact-match tag
#       1 the tip is untagged — land it through the release train instead
#       64 usage (bad arg count, non-repo, unresolvable sha)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-master-tagged.sh <new-tip-sha>

Passes (exit 0) when `git describe --tags --exact-match <new-tip-sha>`
resolves — the tip is a release fold. Refuses (exit 1) when it does not: the
default-branch tip must equal a tag at every pushed state (SPEC-033 CDT-597).
Remediation: /release-train register <branch>, then the next /release folds it
and tags the tip.

Exit 0 ok; 1 untagged tip; 64 usage. Does not mutate refs.
EOF
}

[ $# -eq 1 ] || { usage; exit 64; }
[ -n "$1" ] || { usage; exit 64; }
SHA="$1"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check-master-tagged.sh: not a git repository" >&2
  exit 64
fi

if ! git rev-parse --verify -q "${SHA}^{commit}" >/dev/null 2>&1; then
  echo "check-master-tagged.sh: cannot resolve a commit from '$SHA'" >&2
  exit 64
fi

if TAG=$(git describe --tags --exact-match "$SHA" 2>/dev/null); then
  echo "check-master-tagged.sh: ok — $SHA is tagged $TAG"
  exit 0
fi

BRANCH=$(git for-each-ref --points-at "$SHA" --format='%(refname:short)' refs/heads | head -1)
[ -n "$BRANCH" ] || BRANCH="<branch>"
echo "check-master-tagged.sh: refuse $SHA — no release tag on the default-branch tip (SPEC-033 CDT-597). Land it through the release train instead: /release-train register $BRANCH — the next /release folds the branch and its fold commit is the tag." >&2
exit 1
