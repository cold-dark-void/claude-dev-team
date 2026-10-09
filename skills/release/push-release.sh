#!/usr/bin/env bash
# SPEC-010 Step 6: push the release branch and its tag atomically, so a
# rejected push cannot leave the tag on the remote without the commits
# that justify it (or vice versa).
#
# Usage:
#   push-release.sh --tag vX.Y.Z [--remote NAME] [--print] [-h|--help]
#
# Exit: 0 ok; 1 push failed (remote unchanged; command printed to run by
# hand); 64 usage / not a repo / detached HEAD / tag missing / tag not at
# HEAD.
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: push-release.sh --tag vX.Y.Z [--remote NAME] [--print] [-h|--help]

Pushes the current branch and the given tag to REMOTE (default origin) in
one atomic push (git push --atomic), so a rejected push changes nothing on
the remote.

--tag TAG      required; must match ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$
--remote NAME  default: origin
--print        print the push command (shell-quoted) instead of running it;
               pushes nothing.

After the tag-at-HEAD check and before git push, D2-compares the tag
commit subject to the CHANGELOG lead at that commit (lead-summary.sh
--check --from-commit). --print skips D2 and still pushes nothing.

Exit 0 ok; 1 push failed or D2 mismatch (remote unchanged); 64 usage /
not a repo / detached HEAD / tag missing / tag not at HEAD.
EOF
}

TAG=""
REMOTE="origin"
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "push-release.sh: --tag requires a value" >&2; usage >&2; exit 64; }
      TAG="$2"
      shift 2
      ;;
    --remote)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "push-release.sh: --remote requires a value" >&2; usage >&2; exit 64; }
      REMOTE="$2"
      shift 2
      ;;
    --print) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*)
      echo "push-release.sh: unknown flag: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      echo "push-release.sh: unexpected argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [ -z "$TAG" ]; then
  echo "push-release.sh: --tag is required" >&2
  usage >&2
  exit 64
fi

if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "push-release.sh: --tag: '$TAG' does not match vX.Y.Z" >&2
  exit 64
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "push-release.sh: not a git repository" >&2
  exit 64
fi

if ! BR=$(git symbolic-ref --short -q HEAD); then
  echo "push-release: detached HEAD — check out the release branch, then re-run push-release.sh (nothing pushed)" >&2
  exit 64
fi

TAG_SHA=$(git rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null) || {
  echo "push-release.sh: refs/tags/$TAG not found" >&2
  exit 64
}

HEAD_SHA=$(git rev-parse --verify HEAD)

if [ "$TAG_SHA" != "$HEAD_SHA" ]; then
  echo "push-release: $TAG points at ${TAG_SHA:0:7}, HEAD is ${HEAD_SHA:0:7}" >&2
  exit 64
fi

CMD=(git push --atomic --no-follow-tags "$REMOTE" "refs/heads/$BR" "refs/tags/$TAG")

if [ "$PRINT" = 1 ]; then
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LEAD_SUMMARY_SH="$HERE/lead-summary.sh"
VER="${TAG#v}"
VER="${VER%%[-+]*}"
SUBJECT=$(git log -1 --format=%s "$TAG_SHA")
if ! bash "$LEAD_SUMMARY_SH" --check --from-commit "$TAG_SHA" "$VER" "$SUBJECT"; then
  exit 1
fi

RC=0
"${CMD[@]}" || RC=$?

if [ "$RC" -eq 0 ]; then
  echo "push-release: pushed refs/heads/$BR + refs/tags/$TAG to $REMOTE (atomic)"
  exit 0
fi

{
  echo "push-release: push failed (git rc $RC); --atomic: $REMOTE is unchanged. Run by hand:"
  printf '%q ' "${CMD[@]}"
  printf '\n'
} >&2
exit 1
