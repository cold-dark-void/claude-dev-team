#!/usr/bin/env bash
# skills/backlog/slug.sh — path-safe backlog slug validator (CDT-175 / SPEC-040 M14).
# SOURCE-ONLY — never run this file as a subprocess; require_valid_slug calls the
# caller's own die().
#
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/slug.sh"
#   valid_slug "$slug" || ...
#   require_valid_slug "$slug"      # calls die 1 (defined by the caller)
#
# Charset for path-safe slugs — same as worktree-lib validate_slug / reconcile.
# Guard every path built from a slug; free-text QUERY (title search) is not a
# slug. Functions only: sourcing changes no shell options beyond `set -u`.

set -u

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'error: slug.sh is source-only — do ". slug.sh" from a caller script\n' >&2
  exit 64
fi

valid_slug() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

require_valid_slug() {
  local slug="$1"
  if ! valid_slug "$slug"; then
    die 1 "invalid slug (only [A-Za-z0-9_-] allowed): $slug"
  fi
}
