#!/usr/bin/env bash
# Drift gate (AUDIT-P0.2): the hook templates emitted by init-orchestration must
# stay byte-identical to this repo's canonical live `.claude/hooks/<name>.sh`.
#
# For each hook, extract the fenced ```bash block that follows the
#   "create `.claude/hooks/<name>.sh` with this content:" marker in
# skills/init-orchestration/SKILL.md, and diff it against the live hook.
# Exit non-zero (naming the drifted hook) on any mismatch. Exit 0 if all match.
#
# Wired into /release as a pre-commit gate alongside sync-includes +
# check-template-vars. Run from the repo root.

set -uo pipefail

# Resolve repo root from this script's location (works from any cwd).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SKILL="$ROOT/skills/init-orchestration/SKILL.md"
HOOKS_DIR="$ROOT/.claude/hooks"

HOOKS="task-completed stop-review memory-capture bash-compress precompact-rescue rescue-pointer"

if [ ! -f "$SKILL" ]; then
  echo "check-hook-templates: SKILL.md not found at $SKILL" >&2
  exit 1
fi

DRIFTED=()

for name in $HOOKS; do
  live="$HOOKS_DIR/$name.sh"
  if [ ! -f "$live" ]; then
    echo "check-hook-templates: live hook missing: $live" >&2
    DRIFTED+=("$name (live hook missing)")
    continue
  fi

  # Extract the fenced ```bash block following the marker for THIS hook.
  extracted=$(SKILL="$SKILL" NAME="$name" python3 -c '
import os, sys, re
skill = open(os.environ["SKILL"], encoding="utf-8").read()
name = os.environ["NAME"]
marker = "create `.claude/hooks/%s.sh` with this content:" % name
idx = skill.find(marker)
if idx == -1:
    sys.stderr.write("no marker for %s\n" % name)
    sys.exit(3)
rest = skill[idx:]
m = re.search(r"\n```bash\n(.*?)\n```", rest, re.DOTALL)
if not m:
    sys.stderr.write("no fenced bash block after marker for %s\n" % name)
    sys.exit(3)
# Emit block content WITHOUT a trailing newline. Command substitution
# strips trailing newlines anyway; the diff below re-adds exactly one via
# printf %s\n to match the live hook (which ends in exactly one newline).
sys.stdout.write(m.group(1))
' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "check-hook-templates: could not extract template for '$name' from SKILL.md" >&2
    DRIFTED+=("$name (template not extractable)")
    continue
  fi

  if ! diff -u "$live" <(printf '%s\n' "$extracted") >/dev/null 2>&1; then
    echo "check-hook-templates: DRIFT — SKILL.md template for '$name' differs from live $live" >&2
    diff -u "$live" <(printf '%s\n' "$extracted") >&2 || true
    DRIFTED+=("$name")
  fi
done

if [ "${#DRIFTED[@]}" -gt 0 ]; then
  echo "check-hook-templates: FAIL — drifted hook template(s): ${DRIFTED[*]}" >&2
  exit 1
fi

echo "check-hook-templates: OK — all hook templates match live .claude/hooks/*.sh"
exit 0
