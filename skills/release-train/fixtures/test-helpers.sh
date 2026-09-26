#!/usr/bin/env bash
# test-helpers.sh -- shared helpers for skills/release-train/test.sh and
# test-integration.sh (SPEC-003 copy-extract). Source only, never invoke
# directly: `. "$HERE/fixtures/test-helpers.sh"`.

# clean_except_queue <dir> -- CDT-332: the release-train queue dir is
# expected untracked state, not repo content; use the same top-anchored
# exclusion train-lib.sh cmd_preflight uses, so tests assert the same
# whole-repo semantics preflight relies on regardless of cwd.
clean_except_queue() {
  local dir="$1"
  [ -z "$dir" ] && { echo "clean_except_queue: <dir> argument required" >&2; return 2; }
  [ -z "$(git -C "$dir" status --porcelain -- ':/' ':(top,exclude).claude/release-train')" ]
}
