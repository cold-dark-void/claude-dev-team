---
name: tmpl-adjacent
description: |
  CDT-602 AC2 golden (section-block edges): adjacent markers `{{#E}}` and
  `{{/E}}` carry no body, so the section regex needs a newline before the
  close and does not match — both lines stay literal. The `{{#Z}}` block is
  dropped (empty var) at the end of the file, where the newline that
  preceded the open marker is the render's last byte.
---

## Prompt body

```
OPEN
{{#E}}
{{/E}}
AFTER {{A}}
{{#Z}}
Z-body
{{/Z}}
```
