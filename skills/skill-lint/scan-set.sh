#!/usr/bin/env bash
# skills/skill-lint/scan-set.sh — the one no-argument scan set for the fence
# engines (WP 2-01). Source only, like tests/lib/fence.sh: sourcing this file
# has no side effect (one function definition, zero top-level commands).
#
#   skill_lint_scan_set <root>
#     Prints, one path per line, the .md files whose fenced bash blocks the
#     fence engines scan: every *.md file or symlink under <root>/commands,
#     <root>/skills and <root>/agents (skills/skill-lint/fixtures excluded,
#     because planted defects must not fail the live-tree gate), sorted
#     bytewise, then <root>/AGENTS.md when it exists. Paths carry the <root>
#     prefix as given. A missing directory is skipped. Always returns 0.
#
# lint.py discover() is the Python twin of this function (SPEC-021 Scan
# coverage). Users of this file: skills/skill-lint/check-skill-bash.sh and
# tools/fence-exec/run.sh.
#
# bash 3.2 (no mapfile / declare -A).

skill_lint_scan_set() {
  local root="$1" d
  for d in commands skills agents; do
    [ -d "$root/$d" ] || continue
    find "$root/$d" -path '*skill-lint/fixtures*' -prune -o \( -type f -o -type l \) -name '*.md' -print
  done | LC_ALL=C sort
  if [ -f "$root/AGENTS.md" ]; then printf '%s\n' "$root/AGENTS.md"; fi
  return 0
}
