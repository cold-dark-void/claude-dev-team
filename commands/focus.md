---
name: focus
description: >
  ADHD-friendly session output — action-first replies, numbered steps, no
  preamble/pleasantries. Opt-in for the rest of this session. Usage:
  /focus [on|off|status]
argument-hint: "[on|off|status]"
---

# /focus

Enable (or disable) **focus mode** for the rest of this session. While on,
shape every human-facing reply per `skills/focus/SKILL.md`. Session-only —
no files, no hooks.

## Arguments

| Arg | Effect |
|-----|--------|
| (none) or `on` | Enable focus mode |
| `off` | Disable focus mode |
| `status` | Report whether focus mode is on |

## Step 1: Load the skill

Read and follow:

```
skills/focus/SKILL.md
```

(Resolve via plugin install path if needed — same PDH pattern as other skills.)

## Step 2: Apply argument

- **`on` / empty** — mark focus mode active for this session; print the ON line from the skill; obey all rules on subsequent turns until `off`.
- **`off`** — mark inactive; print OFF line; stop applying focus rules.
- **`status`** — print `Focus mode: ON` or `Focus mode: OFF` (based on this session only). Do not change state.

## Step 3: Stay in character

While ON, every reply to the user follows the skill rules (including structured-workflow exceptions). Do not re-invoke the skill file each turn unless you need to re-read the rules.

## Notes

- Inspired by [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) (MIT); adapted here.
- Orthogonal to agent `Output mode: terse|ultra` (agent↔agent).
- Orthogonal to `/brainstorm` (requirements) and any future dry-mode discuss command.
