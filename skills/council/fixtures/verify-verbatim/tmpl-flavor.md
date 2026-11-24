---
name: tmpl-flavor
description: |
  CDT-602 AC2 flavor golden template: {{FLAVOR_DELTA}} is filled from
  --flavor and a dropped {{#VERIFY_COMMAND}} block sits at the end of the
  fenced body.
---

## Prompt body

```
ROLE
----
{{FLAVOR_DELTA}}

BUDGET {{TOOL_BUDGET}}
{{#VERIFY_COMMAND}}
VERIFY: {{VERIFY_COMMAND}}
{{/VERIFY_COMMAND}}
```
