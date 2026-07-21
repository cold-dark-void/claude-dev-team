# /brainstorm

Structured Socratic design refinement. Forces requirement clarification through four rounds of targeted questions before any planning or implementation begins. Use before `/kickoff` for complex features, or standalone for early-stage ideation.

## Usage

```
/brainstorm <feature or problem description>
/brainstorm
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `<description>` | Feature or problem to brainstorm. Omit to be prompted. |

## Examples

**Start a brainstorm with a description:**
```
/brainstorm real-time collaboration on shared documents
```

**Start without a description:**
```
/brainstorm
```
Prompts: `What feature or problem would you like to brainstorm?`

**Expected synthesis output (after all rounds):**
```
## Problem Statement
Teams editing the same document lose each other's changes when saves collide.

## Success Criteria
- Two users editing simultaneously see each other's cursors within 500ms
- No data loss on concurrent edits

## Scope
IN:  text edits, cursor positions, presence indicators
OUT: file attachments, comments, version history

## Constraints
- Must not break existing single-user save flow
- No new backend infrastructure in v1

## Key Risks
- Conflict resolution on concurrent edits — mitigation: operational transforms or CRDT
- WebSocket connection state on mobile — mitigation: graceful reconnect with queued ops

## Open Questions
- Should presence be opt-in or always-on?
```

## How It Works

`/brainstorm` runs a four-round Socratic interview before proposing anything. It loads Tech Lead and PM memory, the domain glossary (`CONTEXT.md` or `docs/domain/CONTEXT.md` if present), plus any relevant specs from `specs/` before starting, so questions are grounded in the actual codebase and existing constraints.

**Round 1 — Core Intent:** What problem is being solved, who has it, what does success look like, and why now? The command asks 3-5 targeted questions and waits for your answers before moving on.

**Round 2 — Scope and Constraints:** What is explicitly out of scope? What are the hard constraints (timeline, tech stack, backward compatibility, performance)? What existing behavior must not change? Any regulatory or security requirements?

**Round 3 — Edge Cases and Integration:** Failure modes, concurrency, unexpected inputs. What other systems does this touch? What is the migration path for existing data or users? Are there known anti-patterns or past attempts that failed?

**Round 4 — Alternatives (if still ambiguous):** Simpler alternatives, minimum viable version, what would be cut if time were halved.

After all rounds, the command synthesizes your answers into a structured summary (Problem Statement, Success Criteria, Scope, Constraints, Key Risks, Open Questions, and candidate domain terms) and asks you to confirm or correct it.

Only after you confirm does it present 2-3 design options with pros, cons, effort, and risk — each with a clear recommendation and reasoning, not a neutral menu.

The full brainstorm is saved to `.claude/plans/<date>-brainstorm-<slug>.md` for use in `/kickoff`. User-confirmed domain terms are merged into the project **domain glossary** (`CONTEXT.md` preferred, or `docs/domain/CONTEXT.md` if that path already exists) — a committed ubiquitous-language file, not agent memory. See `skills/domain-glossary/SKILL.md`.

### Rules

- No solutions are proposed during questioning — questions only until synthesis.
- All four rounds run even if you say "just build it" — skipping rounds produces plans with hidden assumptions.
- Questions are batched (3-5 at a time), not dumped all at once.
- If your answers reveal the problem is simpler than it appeared, the command will say so and suggest a lighter approach.
- If your answers reveal unexpected complexity, it flags that and suggests phasing the work.

## See Also

- [`/kickoff`](./kickoff.md) — formal planning phase to run after brainstorm
- [`/orchestrate`](./orchestrate.md) — full end-to-end lifecycle
