# /mode

Unified entry for session tone/shape modes. Two independent switches (orthogonal
stack — both may be ON at once):

| Mode | Axis | Backend |
|------|------|---------|
| **focus** | Shape + evidence discipline | `skills/focus/SKILL.md` |
| **blunt** | Tone + confidence calibration | `skills/blunt/SKILL.md` |

Session-only — no files, no hooks, no disk state. Active until explicit `off` or
session end. Not agent↔agent `Output mode: terse|ultra`.

Prefer this surface over the legacy `/focus` and `/blunt` commands (deprecated —
removed at v1.0.0).

## Usage

```
/mode <focus|blunt|status|off> [on|off|status]
```

| Sub | Summary |
|-----|---------|
| `focus [on\|off\|status]` | Shape + evidence (bare `focus` ≡ `on`) |
| `blunt [on\|off\|status]` | Tone + confidence (bare `blunt` ≡ `on`) |
| `status` | Report both modes (Focus + Blunt ON\|OFF) |
| `off` | Disable both modes |

Unknown or missing sub prints usage and stops — no mode change.

## Sub: `focus`

Action-first replies **+** evidence discipline (no guessing; kill false smoking
guns; keep dead ends). Passes through to `skills/focus/SKILL.md`.

```
/mode focus
/mode focus on
/mode focus off
/mode focus status
```

Only the focus switch changes; blunt is untouched.

## Sub: `blunt`

No sugarcoating, verdict-first, certainty matches evidence. Passes through to
`skills/blunt/SKILL.md`.

```
/mode blunt
/mode blunt on
/mode blunt off
/mode blunt status
```

Only the blunt switch changes; focus is untouched. Stacks with focus when both ON.

## Sub: `status` / `off`

```
/mode status   # Focus mode: ON|OFF  +  Blunt mode: ON|OFF
/mode off      # disable both
```

## See also

- Protocol backends: `skills/focus/SKILL.md`, `skills/blunt/SKILL.md`
- [`/debug`](./debug.md) — formal bug pipeline (not a session mode)
- [`/council`](./council.md) — adversarial claim tribunal
- Legacy stubs: [`/focus`](./focus.md), [`/blunt`](./blunt.md)
