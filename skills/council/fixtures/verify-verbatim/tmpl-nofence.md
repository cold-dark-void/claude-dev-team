---
name: tmpl-nofence
description: |
  CDT-602 AC2 golden (no-fence path): extractPromptBody finds no fence, so
  the body after the frontmatter is the prompt. Its trailing blank line
  stays in the render — the trim is in flavorDelta, never in loadPrompt.
---

# tmpl-nofence

Payload: {{A}} and {{MISSING}}.

