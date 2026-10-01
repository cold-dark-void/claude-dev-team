#!/usr/bin/env bash
# Render a finding[] JSON array (stdin) into the Step 6 review sections.
# Vocabulary is `design` (the quality flavor emits design). `quality` is
# accepted only as a legacy alias and lands in Design Problems.
# logic+critical and logic+warning both land in Critical Issues (correctness).
# Anything else that is not a known bucket lands in Other.
set -u
exec jq -r '
def section:
  if .severity == "critical" then "Critical Issues"
  elif .category == "logic" and .severity == "warning" then "Critical Issues"
  elif .category == "compliance" then "Compliance Violations"
  elif (.category == "design" or .category == "quality") and .severity == "warning" then "Design Problems"
  elif .category == "security" and .severity == "warning" then "Security & PII"
  elif .category == "simplification" then "Simplification Opportunities"
  elif .severity == "nitpick" then "Nitpicks"
  else "Other"
  end;
def heading:
  if . == "Critical Issues" then "## Critical Issues (Must Fix) [confidence 95-100]"
  elif . == "Compliance Violations" then "## Compliance Violations"
  elif . == "Design Problems" then "## Design Problems [confidence 80-94]"
  elif . == "Security & PII" then "## Security & PII [confidence 80-94]"
  elif . == "Simplification Opportunities" then "## Simplification Opportunities"
  elif . == "Nitpicks" then "## Nitpicks (Yes, They Matter) [confidence 80-94]"
  else "## Other"
  end;
def line:
  "- \(.file):\(.line) — \(.description) [\(.category), \(.severity)]";
(if type == "array" then . else (.findings // []) end)
| map(. + {section: section})
| group_by(.section)
| .[]
| (.[0].section | heading),
  (.[] | line),
  ""
'
