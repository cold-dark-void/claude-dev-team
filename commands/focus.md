---
name: focus
description: >
  Session mode: action-first replies + evidence discipline (no guessing, confirm
  with tools, kill false smoking guns, keep dead-ends). Usage: /focus [on|off|status]
argument-hint: "[on|off|status]"
---

# /focus

Enable **focus mode** for the rest of this session. Two pillars (both on together):

1. **Shape** — action-first, numbered steps, no preamble (ADHD-friendly output)
2. **Evidence** — no narrative root-causes without confirmation; attack false smoking guns; track dead ends (anti-gaslighting in-session)

Session-only — no files, no hooks. Not a full `/debug` re-run.

## Arguments

| Arg | Effect |
|-----|--------|
| (none) or `on` | Enable focus mode |
| `off` | Disable |
| `status` | Report ON/OFF |

## Step 1: Load the skill

Read and follow:

```
skills/focus/SKILL.md
```

## Step 2: Apply argument

- **`on` / empty** — both pillars active until `off` or session end; print ON line from skill
- **`off`** — inactive; print OFF line
- **`status`** — `Focus mode: ON` or `OFF` only

## Step 3: When the user is mid-bug

If they came from a broken `/debug` “smoking gun” or repeated false fixes:

1. Apply **Pillar B** immediately (especially B3 kill false smoking gun, B4 dead ends, B5 systematic loop)
2. Do **not** auto-invoke `/debug` again unless investigation re-confirms a real defect that needs the formal pipeline
3. Prefer CONFIRMED / KILLED / UNKNOWN labels in replies

## Notes

- Shape credit: [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) (MIT)
- Evidence spirit: handoff Dead-ends (SPEC-018), IC verify-before-build, council “no claim without evidence” — lightweight, same session
- Orthogonal to `Output mode: terse|ultra` and to `/brainstorm`
