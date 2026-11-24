---
name: fixture-delta
role: investigator
description: |
  CDT-602 AC2 flavor golden: flavorDelta strips the frontmatter, cuts
  everything through the `## Delta body` marker line, drops the `[//]: #`
  authoring lines, and trims what is left.
---

Authoring note above the marker — flavorDelta cuts it.

[//]: # (authoring line the strip must remove)

## Delta body

[//]: # (authoring line right after the marker)

FLAVOR: you are the fixture investigator.
Trailing blank lines below are trimmed away.

