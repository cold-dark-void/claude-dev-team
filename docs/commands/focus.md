# /focus

ADHD-friendly **session output shaping**. Lead with the next action, number multi-step work, restate state across turns, suppress tangents and pleasantries. Opt-in for the rest of the session.

Inspired by [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) (MIT); adapted for this plugin.

## Usage

```
/focus
/focus on
/focus off
/focus status
```

## Arguments

| Arg | Description |
|-----|-------------|
| (none) or `on` | Enable focus mode until session end or `/focus off` |
| `off` | Disable focus mode |
| `status` | Print whether focus mode is on (session only) |

## What changes

While ON, human-facing replies:

1. Lead with the next action or the answer (no preamble)
2. Number multi-step tasks
3. End with one concrete next step when work is open
4. Suppress tangents (second issues only as a later yes/no)
5. Restate mid-task state each turn
6. Give specific time estimates
7. Make wins visible in concrete terms
8. Matter-of-fact errors (cause + fix)
9. Cap lists at 5 (split do-now vs later)
10. No "Great question" / "Hope this helps" theater

## What does not change

- No tool bans (you can still edit/commit — this is prose shape only)
- No disk state under `.claude/`
- Agent↔agent `Output mode: terse|ultra` is separate
- Load-bearing report schemas (`/council`, `/review-and-commit`, handoff JSON, etc.) keep their structure; focus applies around them

## Examples

```
/focus
```

```
Focus mode ON — action-first replies for this session. /focus off to disable.
```

Then a normal coding question gets an action-first answer instead of a long warm-up.

## See also

- Protocol: `skills/focus/SKILL.md`
- `/brainstorm` — structured requirements before planning (different job)
