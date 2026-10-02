#!/usr/bin/env bash
# Compare {{VARS}} in templates/report.md with the SKILL.md placeholder table.
# HTML comments must not contain live {{VARS}}. Exit 1 on drift, 2 on structure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE="${FIX_TICKET_TEMPLATE:-$ROOT/skills/fix-ticket/templates/report.md}"
SKILL="${FIX_TICKET_SKILL:-$ROOT/skills/fix-ticket/SKILL.md}"
VAR_RE='\{\{[A-Z0-9_]+\}\}'

if [ ! -f "$TEMPLATE" ] || [ ! -f "$SKILL" ]; then
  echo "FAIL: template or skill missing" >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/fix-ticket-vars.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Body: drop HTML comments so a note cannot count as a substitution site.
awk '
  {
    line = $0
    while (1) {
      start = index(line, "<!--")
      if (c == 0 && start == 0) { print line; break }
      if (c == 0 && start > 0) {
        printf "%s", substr(line, 1, start - 1)
        line = substr(line, start + 4)
        c = 1
        continue
      }
      end = index(line, "-->")
      if (c == 1 && end == 0) { break }
      if (c == 1 && end > 0) {
        line = substr(line, end + 3)
        c = 0
        continue
      }
    }
  }
' "$TEMPLATE" | grep -oE "$VAR_RE" | sort -u > "$work/body" || true

# Comment text only.
awk '
  {
    line = $0
    while (1) {
      if (c == 0) {
        start = index(line, "<!--")
        if (start == 0) break
        line = substr(line, start + 4)
        c = 1
        continue
      }
      end = index(line, "-->")
      if (end == 0) { print line; break }
      printf "%s\n", substr(line, 1, end - 1)
      line = substr(line, end + 3)
      c = 0
    }
  }
' "$TEMPLATE" | grep -oE "$VAR_RE" | sort -u > "$work/comments" || true

if [ -s "$work/comments" ]; then
  echo "FAIL: live placeholder inside an HTML comment" >&2
  cat "$work/comments" >&2
  exit 1
fi

awk '
  $0 ~ /^\| Placeholder \|/ { grab = 1; next }
  grab && $0 ~ /^\|/ {
    print
    next
  }
  grab { grab = 0 }
' "$SKILL" | grep -oE "$VAR_RE" | sort -u > "$work/skill" || true

if [ ! -s "$work/body" ] || [ ! -s "$work/skill" ]; then
  echo "FAIL: could not read template vars or the skill table" >&2
  exit 2
fi

miss_skill="$(comm -23 "$work/body" "$work/skill")"
miss_body="$(comm -13 "$work/body" "$work/skill")"
if [ -n "$miss_skill" ] || [ -n "$miss_body" ]; then
  if [ -n "$miss_skill" ]; then
    echo "FAIL: in the template, not in the skill table:" >&2
    printf '%s\n' "$miss_skill" >&2
  fi
  if [ -n "$miss_body" ]; then
    echo "FAIL: in the skill table, not in the template:" >&2
    printf '%s\n' "$miss_body" >&2
  fi
  exit 1
fi

echo "OK: fix-ticket report template vars match the skill table"
exit 0
