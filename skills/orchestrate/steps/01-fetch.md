<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 1: Fetch issue context

Resolve **ticket source** and a `closes:` list (persisted on the plan in Step 6).
Order:

1. **Linear** — if Linear MCP is available (e.g. `linear_getIssue`) and the ID
   resolves: extract title, description, ACs, priority, assignee, status, labels.
   Set `source=linear`. Seed `closes:` with `linear:<ISSUE-ID>`.
2. **Backlog** — else if `.claude/backlog/<ISSUE-ID>.md` exists, or
   `.claude/backlog.md` / item titles match the ID or slug: load Problem/Goal/Notes
   as issue context. Set `source=backlog`. Seed `closes:` with
   `backlog/<slug>.md` (and any additional slugs the user names).
3. **Freeform** — else ask the user to paste title, description, ACs. Set
   `source=freeform`, `closes: []`, and warn: no tracker will be closed at ship.

If Linear **and** a matching backlog item both exist, dual-write both into
`closes:` (close local index at ship; Linear ticket status per **Linear lifecycle**
below — Done only when work is on master / wrap).

Print source + closes in the Step 2 summary. Store issue context for all
subsequent agent prompts.

---
