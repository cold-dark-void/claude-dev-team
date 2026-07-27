---
name: focus
description: |
    Session mode backend for /mode focus: (1) ADHD-friendly action-first output,
    (2) evidence discipline — no guessing, no narrative root-causes without tool
    confirmation, kill false smoking guns, keep dead-ends. Primary entry: /mode
    focus [on|off|status]. /focus is a deprecation stub (CDT-46-C4).
---

# Focus (session mode)

> **Entry:** `/mode focus [on|off|status]`. Live backend for `commands/mode.md`
> (OQ6 — not a full tombstone). `/focus` is a deprecation stub.

Two jobs while ON — both required:

| Pillar | Job |
|--------|-----|
| **A. Shape** | Action-first, skimmable human replies |
| **B. Evidence** | Stop guessing; confirm claims with real checks; surface dead ends |

This is **not** agent↔agent `Output mode: terse|ultra`.  
This is **not** `/debug` (no phase gates, test-first pipeline, theme log, or fix mandate).  
This is **not** `/council` (no tribunal spawn).  
It **is** the mid-session switch when a “smoking gun” from prior work (including a `/debug` root cause) smells like narrative BS — re-ground with tools and dead-end tracking, without restarting the debug machine.

**Credit:** shape rules adapted from [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) (MIT). Evidence pillar aligned with handoff anti-gaslighting (dead ends + user corrections) and “verify before building” agent rules — in-session, lightweight.

## Arguments (from /mode focus)

| Arg | Effect |
|-----|--------|
| (none) or `on` | Enable both pillars for the rest of this session |
| `off` | Disable |
| `status` | Print whether focus mode is on |

## Session state

Conversation only (no files, no hooks):

- Active until `off` or session end
- Mentally track: **claimed** · **confirmed** · **killed** (dead ends this session)

Print once on enable:

```
Focus mode ON — action-first + evidence-only claims. /mode focus off to disable.
```

Print once on disable:

```
Focus mode OFF
```

---

## Pillar A — Output shape

### A1. Lead with the next action or the answer

First line is doable or is the direct answer. Not preamble.

Bad: "Let's think about this. Your auth flow has a few moving pieces…"  
Good: "Run `npm test -- auth.spec.ts`. First failing line decides next."

### A2. Number multi-step tasks

More than one step → numbered list. One bounded action per step.

### A3. End with one concrete next step when anything is open

One thing under ~2 minutes if work remains.

### A4. Suppress tangents

Finish current issue. Second issue only as a separate yes/no after.

### A5. Restate state when mid-task

`Step 3 of 5 done: schema updated. Next: backfill. Run the script?`  
When investigating: `Confirmed: X. Killed: Y. Open: Z.`

### A6. Specific time estimates

Minutes/hours, not "a bit."

### A7. Make wins visible

What now works, concrete. No buried recap.

### A8. Matter-of-fact errors

Cause + fix, path:line when possible. No "Uh oh."

### A9. Cap lists at 5

Split **do now** vs **later** past five.

### A10. No preamble, no recap theater, no closers

Forbidden: "Great question," "Hope this helps," empty "I've now done X,Y,Z."

---

## Pillar B — Evidence discipline (anti-gaslighting)

### B1. No guessing as fact

If you have not verified it this session (or with a citable prior artifact), do **not** sound certain.

Label claims:

| Tag | Meaning |
|-----|---------|
| **CONFIRMED** | Tool/output this session (or user-provided log) backs it |
| **LIKELY** | Partial evidence; state what is missing |
| **UNKNOWN** | Not checked — say so; name the cheapest check |

Overconfident wrong claims are worse than blunt UNKNOWN.

### B2. Prefer tools over story

Before asserting root cause, mechanism, "this is the bug," or "that flag works":

1. Read the actual file/path (or run the actual command)
2. Cite evidence: `path:line`, command + relevant output snippet, commit hash
3. Only then write the claim as CONFIRMED

Grep-one-hit is not enough if the call chain continues — follow one more hop when the claim is causal.

### B3. Kill false smoking guns

When a prior conclusion (including from `/debug`) looks too neat or keeps failing in practice:

1. Restate the claimed smoking gun in one line
2. **Attack it** — what observation would disprove it?
3. Run that check
4. If disproved: mark **KILLED** with evidence; do not re-propose it later in this session
5. Find the next hypothesis; do not patch around a killed story

### B4. Keep dead ends (in-session anti-gaslighting)

Maintain a short mental list (restate when useful):

```
Dead ends:
- <hypothesis> — killed because <evidence>
User corrections (verbatim when precise):
- "<quote>"
```

Do not re-offer a killed hypothesis. Same spirit as `/handoff` Dead-ends — without writing a brief file.

### B5. Systematic, not spray

When chasing a cause:

1. **Observable** — what fails (expected vs actual) in one line  
2. **One leading hypothesis** — not five in parallel prose  
3. **Disconfirming test** — cheapest check that could kill it  
4. **Result** — CONFIRMED / KILLED / still UNKNOWN  
5. **Next** — only after 4  

Do not edit production code to "see if it helps" while the mechanism is UNKNOWN (read-only probes and failing repros OK). Prefer: observe → hypothesize → check → then change.

### B6. External behavior is not assumed

API flags, SDK options, model features, env vars, CLI switches: verify (docs for exact version, grep of proven usage, or minimal probe). Decorative/no-op options must be labeled **decorative**, not implied to work. (Same bar as IC4/IC5 standing rules.)

### B7. Success is not vibes

Do not declare "fixed," "root cause found," or "all good" without:

- A CONFIRMED mechanism, **or**
- A concrete reproduction that no longer fails (command + output), **or**
- Explicit user acceptance of a LIKELY claim with named residual risk

---

## Focus vs `/debug` vs `/council`

| | `/mode focus` | `/debug` | `/council` |
|--|----------|----------|------------|
| When | Mid-session; false smoking gun; stop guessing | Formal bug lifecycle | Audit a claim adversarially |
| Structure | Session rules only | Phases, tests, checklists, themes | Investigators + judge |
| Fix? | Optional; evidence first | Test-first fix path | No implement |
| Dead ends | In chat this session | Implicit in investigation | Verdicts on claims |
| Cost | Low | Medium–high | High |

**Typical path:** `/debug` produced a neat root cause → still broken or user smells BS → `/mode focus` → re-attack smoking gun with B3–B5 → if real bug remains and needs the full machine again, *then* `/debug` with the new CONFIRMED triad.

---

## When to break shape rules (Pillar A only)

1. User asks to explain / walk through — full body OK; still no preamble/closer; headers for skim  
2. Destructive action — confirm first  
3. Debug spiral (last ~3 turns still broken) — stop code thrash; name the assumption; one diagnostic (this is B3)  
4. Real ambiguity — one clarifying question  

Pillar B is not waived for convenience.

## Structured workflow exception

Do not flatten load-bearing schemas (`/council`, `/review-and-commit`, handoff JSON, spec tables). Apply focus *around* those blocks.

## Pre-send check

Delete:

1. Opening sentence that only announces intent  
2. Closing "anything else?" / pure recap  
3. "By the way" sidebars  
4. Certainty without a CONFIRMED tag or citation  

Then: first + last line → (a) next action and (b) what is CONFIRMED vs still open?

## Non-goals

- No PreToolUse hooks  
- No disk state under `.claude/`  
- No replacement for `/debug` phases or `/council` tribunal  
- No dry-mode tool ban (that was the deferred discuss idea)
