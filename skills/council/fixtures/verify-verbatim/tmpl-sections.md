---
name: tmpl-sections
description: |
  CDT-602 AC2 golden template. Exercises the loadPrompt section semantics:
  a kept `{{#B}}` block (marker lines removed, body kept), a dropped block
  (empty var), one-pass substitution (a value carrying `{{A}}` must not
  re-expand), and a missing var that stays literal.
---

# tmpl-sections

Authoring header outside the fence (frontmatter strip must remove the
frontmatter; fence extraction must remove this prose).

## Prompt body

```
HEAD {{A}}
{{#B}}
B-line [{{C}}]
{{/B}}
TAIL {{MISSING}} {{D}}
```

trailing prose outside the fence
