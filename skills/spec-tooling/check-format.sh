#!/usr/bin/env bash
# check-format.sh — assert a spec file carries the 9 required sections (SPEC-008).
#
# Mechanizes the /spec check Phase-1 "Format Compliance" checklist so dev-side CI can
# prove a spec is structurally complete. /spec check itself stays inline (no consumer
# shell-out); this CLI is OUR bootstrap proof (SPEC-008 Test row, AUDIT-P1-5A MC-6).
#
# Usage:
#   check-format.sh <specfile>
#
# Stdout discipline: on success prints a single OK line to stdout; on failure prints each
# missing requirement (one per line) to stderr. Diagnostics never go to stdout.
# Exit codes: 0 = all 9 present, 1 = one or more missing, 64 = usage error.
#
# The 9 required elements (SPEC-008 / /spec check Phase-1):
#   1. `# <ID>: <Title>` header        (ID prefix ∈ SPEC|PERF|SAFE|COMPAT|ARCH)
#   2. `**Status**:` line
#   3. `**Category**:` line
#   4. `**Created**:` line
#   5. `## Overview` section
#   6. `## MUST` section with ≥1 bullet point (any `- `/`* ` line within the section)
#   7. `## Test` section
#   8. `## Validation` section with ≥1 validation claim (plain `- ` bullet)
#   9. `## Version History` section with a `| Date | Change |` table header
#
# Retired-syntax gate (SPEC-008, 2026-10-12): a `- [ ]` / `- [x]` line under
# ## Validation or ## Test fails the check — the checkbox syntax is retired
# (checkbox state is never evidence, WP 1-15). Checkboxes elsewhere (e.g.
# ## Open Questions) are unaffected.

set -euo pipefail

usage() {
  echo "usage: check-format.sh <specfile>" >&2
  exit 64
}

[ $# -eq 1 ] || usage
specfile="$1"
if [ ! -f "$specfile" ]; then
  echo "check-format.sh: no such file: $specfile" >&2
  exit 64
fi

missing=()

# 1. Header `# <PREFIX>-<NNN>: <Title>`
grep -Eq '^# (SPEC|PERF|SAFE|COMPAT|ARCH)-[0-9]+: .+' "$specfile" \
  || missing+=("header (# <ID>: <Title>)")

# 2-4. Metadata lines
grep -Eq '^\*\*Status\*\*:' "$specfile"   || missing+=("**Status**: line")
grep -Eq '^\*\*Category\*\*:' "$specfile" || missing+=("**Category**: line")
grep -Eq '^\*\*Created\*\*:' "$specfile"  || missing+=("**Created**: line")

# 5. Overview
grep -Eq '^## Overview[[:space:]]*$' "$specfile" || missing+=("## Overview section")

# 6. MUST section + at least one bullet WITHIN that section.
#    SPEC-008 / /spec check Phase-1 require "## MUST with bullet points" — NOT that bullets
#    begin with the word MUST (e.g. SPEC-018 uses '- **M1 — …'). So accept any bullet
#    (line starting with '- ' or '* '), but scope it between '## MUST' and the next '## '
#    heading so an empty MUST section can't pass on a later section's bullets.
if grep -Eq '^## MUST[[:space:]]*$' "$specfile"; then
  awk '
    /^## MUST[[:space:]]*$/ { in_must=1; next }
    in_must && /^## / { in_must=0 }
    in_must && /^[-*] / { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$specfile" || missing+=("## MUST section (no bullet points)")
else
  missing+=("## MUST section")
fi

# 7. Test
grep -Eq '^## Test[[:space:]]*$' "$specfile" || missing+=("## Test section")

# 8. Validation section + at least one validation claim INSIDE that section.
#    SPEC-008 (2026-10-12): the checkbox requirement is retired — a claim is a
#    plain `- ` bullet that carries its evidence. A bullet under Open Questions
#    must not satisfy Validation (CDT-273).
if grep -Eq '^## Validation[[:space:]]*$' "$specfile"; then
  awk '
    /^## Validation[[:space:]]*$/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec && /^[-*] / { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$specfile" || missing+=("## Validation section (no validation claim bullet)")
else
  missing+=("## Validation section")
fi

# Retired-syntax gate: a `- [ ]` / `- [x]` line (any indent, `-` or `*` bullet)
# under ## Validation or ## Test fails the check, so the retired checkbox
# syntax cannot silently return. A `### ` subsection heading does not reset
# the section scope — only the next `## ` heading does.
if awk '
    /^## Test[[:space:]]*$/ { sec=1; next }
    /^## Validation[[:space:]]*$/ { sec=1; next }
    /^## / { sec=0 }
    sec && /^[[:space:]]*[-*][[:space:]]*\[[ xX]\]/ { found=1 }
    END { exit(found ? 1 : 0) }
  ' "$specfile"; then
  :
else
  missing+=("retired checkbox line under ## Validation / ## Test (SPEC-008: syntax retired; use plain claim bullets with evidence)")
fi

# 9. Version History section + table header INSIDE that section.
if grep -Eq '^## Version History[[:space:]]*$' "$specfile"; then
  awk '
    /^## Version History[[:space:]]*$/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec && /^\| *Date *\| *Change *\|/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$specfile" || missing+=("## Version History section (no '| Date | Change |' table)")
else
  missing+=("## Version History section")
fi

if [ ${#missing[@]} -eq 0 ]; then
  echo "OK: all 9 required sections present in $specfile"
  exit 0
fi

echo "FAIL: $specfile is missing ${#missing[@]} required element(s):" >&2
for m in "${missing[@]}"; do
  echo "  - $m" >&2
done
exit 1
