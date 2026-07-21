# /focus

Session mode with **two pillars**:

1. **Shape** — ADHD-friendly action-first replies (numbered steps, restate state, no preamble)
2. **Evidence** — stop guessing; confirm with tools; kill false smoking guns; keep dead ends (in-session anti-gaslighting)

Opt-in for the rest of the session. No disk state, no hooks.

## Usage

```
/focus
/focus on
/focus off
/focus status
```

## When to use

| Situation | Why `/focus` |
|-----------|----------------|
| Replies are long, buried, hard to act on | Pillar A |
| Prior “root cause” / smoking gun keeps failing | Pillar B — attack and kill it with evidence |
| Agent keeps guessing or re-proposing dead ends | Pillar B |
| You want systematic checks without re-entering full `/debug` | Pillar B |

## When *not* to use

| Situation | Use instead |
|-----------|-------------|
| Fresh bug, need test-first fix lifecycle | `/debug` |
| Audit a claim adversarially with multiple investigators | `/council` |
| Requirements / design before planning | `/brainstorm` |
| Persist dead ends for a *new* session | `/handoff` |

## Evidence rules (summary)

- Label claims **CONFIRMED** / **LIKELY** / **UNKNOWN**
- Causal claims need path:line, command output, or equivalent — not story
- False smoking gun: restate → disconfirming check → **KILLED** with evidence → next hypothesis
- Do not re-offer killed hypotheses this session
- Do not declare fixed without confirmed mechanism or green repro

## Shape rules (summary)

Lead with next action; number multi-step work; one concrete next step; cap lists at 5; no “Great question” / “Hope this helps.”

## See also

- Protocol: `skills/focus/SKILL.md`
- `/debug` — formal bug pipeline
- `/handoff` — anti-gaslighting brief for a *later* session
- `/council` — adversarial claim tribunal
