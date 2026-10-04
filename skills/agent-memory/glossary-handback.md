<!--
Managed partial: glossary load + hand-back block for the 7 behavioral agents
(CDT-299). Included via `<!-- include: skills/agent-memory/glossary-handback.md
agent=<name> -->` regions; sync-includes.py keeps the copies byte-identical.
The load order here is the same one `skills/domain-glossary/SKILL.md` defines
(worktree CONTEXT.md first, main checkout fallback — CDT-374). Do not edit the
expanded regions in agents/*.md; edit this partial and run
`python3 skills/agent-memory/sync-includes.py apply`.
-->

## Domain glossary and hand-back

### Session start — load the domain glossary (before naming anything)

```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd || pwd)
if [ -f "$WTROOT/CONTEXT.md" ]; then
  cat "$WTROOT/CONTEXT.md"
elif [ -f "$WTROOT/docs/domain/CONTEXT.md" ]; then
  cat "$WTROOT/docs/domain/CONTEXT.md"
elif [ -f "$MROOT/CONTEXT.md" ]; then
  cat "$MROOT/CONTEXT.md"
elif [ -f "$MROOT/docs/domain/CONTEXT.md" ]; then
  cat "$MROOT/docs/domain/CONTEXT.md"
else
  echo "No domain glossary (CONTEXT.md) yet."
fi
```

- Prefer glossary **Term** names in specs, plans, tickets, and code; do not
  reintroduce listed **Avoid** aliases. Map an alias the user/ticket used once,
  and note the mapping.
- If the user insists on a name that contradicts the glossary, flag the
  conflict instead of silently overriding either side.
- An absent glossary is fine — do not invent terms; only user-confirmed
  decisions produce them (write-back belongs to `/brainstorm`/`/kickoff`).

### Hand-back — return work as your final message

When the task is done (or blocked), deliver your results **as your final
message**: the orchestrator reads them from your spawn-return value. Spawned
sub-agents have no addressable parent — there is no agent named `main` or
`orchestrator`, so `SendMessage` to one cannot work. Reserve `SendMessage` for
peer-to-peer DMs to *running* teammates, and broadcast sparingly.
