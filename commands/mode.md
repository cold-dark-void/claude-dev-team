---
name: mode
description: >
  Session modes — focus (action-first + evidence) and blunt (tone + confidence).
  Orthogonal stack; session-only. Usage: /mode <focus|blunt|status|off> [on|off|status]
argument-hint: "<focus|blunt|status|off> [on|off|status]"
---

# /mode

Unified entry for session tone/shape modes. Two independent switches (orthogonal
stack — both may be ON at once):

| Mode | Axis | Backend |
|------|------|---------|
| **focus** | Shape + evidence discipline | `skills/focus/SKILL.md` |
| **blunt** | Tone + confidence calibration | `skills/blunt/SKILL.md` |

Session-only — no files, no hooks, no disk state under `.claude/`. Active until
explicit `off` or session end. Not agent↔agent `Output mode: terse|ultra`.

## Dispatch

Parse the first positional argument as `<sub>`. Remaining args pass through to
the routed sub. If absent or unknown, print usage and **stop with no mode change**.

```
Usage: /mode <focus|blunt|status|off> [on|off|status]

Subs:
  focus [on|off|status]   Shape + evidence (bare focus ≡ on)
  blunt [on|off|status]   Tone + confidence (bare blunt ≡ on)
  status                  Report both modes (Focus + Blunt ON|OFF)
  off                     Disable both modes
```

## Routing table

| `<sub>` | Strategy | Target |
|---------|----------|--------|
| `focus` | **skill-delegate** | `skills/focus/SKILL.md` (arg = rest; bare ≡ `on`) |
| `blunt` | **skill-delegate** | `skills/blunt/SKILL.md` (arg = rest; bare ≡ `on`) |
| `status` | **inline** | print both ON/OFF lines (no skill load required for report) |
| `off` | **inline** | disable both; print both OFF lines |

Unknown/missing sub → usage block above → stop. Do not guess a default sub.
Do not toggle either mode on unknown input.

---

## Sub: `focus` [on|off|status]

### Step 1: Load the skill

Read and follow:

```
skills/focus/SKILL.md
```

### Step 2: Apply argument

Second token (default when omitted: `on`):

| Arg | Effect |
|-----|--------|
| (none) or `on` | Enable focus mode for rest of session; print skill ON line |
| `off` | Disable focus only; print skill OFF line |
| `status` | Print `Focus mode: ON` or `Focus mode: OFF` only |

Unknown second token → print focus usage (`/mode focus [on|off|status]`) and stop;
do not change focus state.

### Step 3: Scope

Only the **focus** switch changes. Blunt state is untouched (orthogonal).

When the user is mid-bug / false smoking gun: apply skill Pillar B immediately
(B3 kill, B4 dead ends, B5 systematic loop). Do **not** auto-invoke `/debug`
unless investigation re-confirms a real defect that needs the formal pipeline.

---

## Sub: `blunt` [on|off|status]

### Step 1: Load the skill

Read and follow:

```
skills/blunt/SKILL.md
```

### Step 2: Apply argument

Second token (default when omitted: `on`):

| Arg | Effect |
|-----|--------|
| (none) or `on` | Enable blunt mode for rest of session; print skill ON line |
| `off` | Disable blunt only; print skill OFF line |
| `status` | Print `Blunt mode: ON` or `Blunt mode: OFF` only |

Unknown second token → print blunt usage (`/mode blunt [on|off|status]`) and stop;
do not change blunt state.

### Step 3: Scope

Only the **blunt** switch changes. Focus state is untouched (orthogonal).

While ON, every human-facing reply follows the skill (verdict first; no sugarcoat;
certainty matches evidence). If focus is also ON, apply both — see skill
§ Interaction with `/mode focus`.

---

## Sub: `status`

Report **both** modes. No skill body load required for the report itself.
Track session state mentally (conversation only).

Print exactly two lines (order fixed):

```
Focus mode: ON
Blunt mode: OFF
```

or the matching ON/OFF values for the current session. No extra prose.

---

## Sub: `off`

Disable **both** modes for the rest of this session (or until re-enabled).

Print:

```
Focus mode OFF
Blunt mode OFF
```

(Match skill disable wording: `Focus mode OFF` / `Blunt mode OFF`.)

If a mode was already off, still print its OFF line (idempotent).

---

## Orthogonal stack

| If both ON | Apply |
|------------|--------|
| Shape | focus Pillar A (action-first, numbered steps) |
| Investigation | focus Pillar B (CONFIRMED/LIKELY/UNKNOWN, dead ends) |
| Tone | blunt (verdict-first, no softener, confidence match) |

| Mode alone | Effect |
|------------|--------|
| focus only | shape + evidence; normal tone OK |
| blunt only | tone rules; normal structure OK |
| neither | default session behavior |

Also orthogonal to `Output mode: terse|ultra`, `/brainstorm`, `/debug`,
`/council`, and `/review-and-commit`.

## Structured workflow exception

Do not flatten load-bearing schemas (`/council`, `/review-and-commit`, handoff
JSON, spec tables). Apply mode rules *around* those blocks.

## Non-goals

- No PreToolUse hooks, no disk state
- No replacement for `/debug` phases or `/council` tribunal
- Not a substitute for `/review-and-commit`
- Legacy `/focus` and `/blunt` are deprecation stubs → `/mode focus` / `/mode blunt`
  (same skill backends)
