#!/usr/bin/env bash
# gen-template-vars.sh — substitution blocks from a prompt's ## Variables table.
#
# One reader of that table. check-template-vars.sh calls this. Do not copy
# the extraction into a third hand-maintained list.
#
#   gen-template-vars.sh vars <prompt.md>     one {{VAR}} per line, sorted
#   gen-template-vars.sh block <prompt.md>    a "with substitutions:" block
#
# The class matches engine.sh finalize: [A-Z0-9_]+ (digits included).
# Exit 0 on success. Exit 2 when the prompt or its table is missing.

set -u

mode="${1:-}"
file="${2:-}"

if [ "$mode" != vars ] && [ "$mode" != block ]; then
  echo "gen-template-vars.sh: usage: vars|block <prompt.md>" >&2
  exit 2
fi
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "gen-template-vars.sh: prompt not found: ${file:-}" >&2
  exit 2
fi

vars="$(sed -n '/^## Variables/,/^## /p' "$file" \
  | grep -E '^\|[[:space:]]*`\{\{[A-Z0-9_]+\}\}`' \
  | grep -oE '\{\{[A-Z0-9_]+\}\}' \
  | sort -u)" || true

if [ -z "$vars" ]; then
  echo "gen-template-vars.sh: no {{VARS}} in ## Variables: $file" >&2
  exit 2
fi

if [ "$mode" = vars ]; then
  printf '%s\n' "$vars"
  exit 0
fi

printf '  with substitutions:\n'
while IFS= read -r v; do
  [ -n "$v" ] && printf '    %s\n' "$v"
done <<EOF
$vars
EOF
exit 0
