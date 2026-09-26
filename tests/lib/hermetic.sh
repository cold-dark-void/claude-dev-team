#!/usr/bin/env bash
# tests/lib/hermetic.sh — SPEC-030 R20 hermetic suite helper. Source-only.
#
#   hermetic_init     Creates one mktemp -d root under the caller's TMPDIR
#                     (default /tmp), exports HERMETIC_ROOT (that root),
#                     TMPDIR=$HERMETIC_ROOT/tmp and HOME=$HERMETIC_ROOT/home
#                     (both created), unsets XDG_CONFIG_HOME, exports fixed
#                     GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL/GIT_COMMITTER_NAME/
#                     GIT_COMMITTER_EMAIL values, and installs
#                     `trap hermetic_cleanup EXIT`.
#   hermetic_cleanup  rm -rf "$HERMETIC_ROOT" (no-op if unset).
#
# A suite that installs its own EXIT trap after hermetic_init MUST call
# hermetic_cleanup from that trap.

hermetic_init() {
  HERMETIC_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermetic.XXXXXX")
  export HERMETIC_ROOT
  export TMPDIR="$HERMETIC_ROOT/tmp"
  export HOME="$HERMETIC_ROOT/home"
  mkdir -p "$TMPDIR" "$HOME"
  unset XDG_CONFIG_HOME
  export GIT_AUTHOR_NAME="hermetic"
  export GIT_AUTHOR_EMAIL="hermetic@example.invalid"
  export GIT_COMMITTER_NAME="hermetic"
  export GIT_COMMITTER_EMAIL="hermetic@example.invalid"
  trap hermetic_cleanup EXIT
}

hermetic_cleanup() {
  [ -n "${HERMETIC_ROOT:-}" ] && rm -rf "$HERMETIC_ROOT"
  return 0
}
