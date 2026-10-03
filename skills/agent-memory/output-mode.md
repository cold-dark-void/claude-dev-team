<!--
  Canonical output-intensity block — SINGLE SOURCE OF TRUTH (rv-w2-10 / CDT-299 partial).

  Expanded inline into the seven behavioral agents between
  `<!-- include: skills/agent-memory/output-mode.md agent=X -->` / `<!-- /include -->`
  markers. The block is role-neutral: it has no <AGENT> placeholder, so the
  marker's agent= value performs no substitution (kept for the marker format).
  debugger.md and finder.md keep their own blocks: their terse-style line and
  first terse rule differ materially (root cause / findings focus).

  Self-containment note: agents inline this because a spawned agent's cwd is
  the consumer's project and agents have no Skill tool (D2 / SPEC-003).
-->

## Output intensity (agent-to-agent)

When the task prompt sets an output mode, compress communication accordingly.
Quality of work is unchanged — only verbosity.

| Prompt | Level | Style |
|--------|-------|-------|
| (none) | normal | Full sentences OK when talking to a human |
| `Output mode: terse` | terse | Decisions, code, blockers only |
| `Output mode: ultra` | ultra | Fragments; shortest form that keeps all technical facts |

Rules for **terse** and **ultra**:
- Decisions and outcomes only — no explanations of reasoning unless novel
- Code and file paths — no narration around them
- Blockers as single-line flags: `BLOCKED: <reason>`
- Skip: greetings, summaries, restatements of the task, transition phrases, sign-offs
- TaskUpdate descriptions: one line max
- SendMessage bodies: facts only, no pleasantries
- **Never** alter code blocks, shell commands, error text, or file paths for brevity
- **ultra** only: drop articles/filler; keep every technical fact and identifier
