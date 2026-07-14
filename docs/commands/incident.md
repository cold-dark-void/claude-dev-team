# /incident

DevOps-led **war-room** for production incidents (SPEC-027). Coordinates severity
triage, parallel read-only investigation, an append-only timeline, rollback-first
**propose-only** mitigation, local stakeholder drafts, and a cold postmortem that
feeds the backlog.

For a single-bug root-cause loop, use [`/debug`](debug.md) instead. `/incident`
may **delegate** to `/debug` when a code-level root cause is suspected; it does
not reimplement SPEC-014 gates.

## Usage

```
/incident <description>
/incident resume <id>
/incident postmortem <id>
/incident list
/incident
```

| Form | Action |
|------|--------|
| `/incident <description>` | Open war-room: severity proposal, then investigation after confirm |
| `/incident` | Prompt for description |
| `/incident resume <id>` | Reconstruct state solely from `.claude/incidents/<id>/` |
| `/incident postmortem <id>` | Generate `postmortem.md` from artifacts; offer `/backlog add` per AI |
| `/incident list` | List incident ids |

**Parser:** first token ∈ {`resume`, `postmortem`, `list`} → subcommand; else the
whole argument string is the open description.

## Flow (summary)

1. **Severity gate** — propose `SEV1` | `SEV2` | `SEV3` + rationale + quick blast
   probe. **No investigation threads** until the user confirms or overrides.
2. **Workspace** — create `$MROOT/.claude/incidents/<YYYY-MM-DD>-<slug>/`.
3. **Parallel RO threads** (one tool-use block): change-correlation, symptom-
   evidence, blast-radius. Findings → timeline `observation` entries.
4. **Mitigation** — rollback-first proposals; execute only after explicit
   per-action confirmation. Declines are logged; nothing runs.
5. **QA gate** — status `mitigated` only after a QA-validation timeline entry.
6. **Comms** — write sequential drafts under `comms/`; **never** send them.
7. **Postmortem** — cold assemble from the incident directory; action items via
   SPEC-009 `/backlog add`.

## Artifacts

```
.claude/incidents/<YYYY-MM-DD>-<slug>/
  meta.json           # id, severity, status, pending_proposal, …
  timeline.jsonl      # canonical append-only store
  timeline.md         # full render of jsonl (do not hand-edit)
  comms/NNN-<slug>.md # stakeholder drafts (local only)
  postmortem.md       # after /incident postmortem
```

Directory is gitignored (machine-local). Resume works from these files alone —
no `memory.db` or transcript parsing.

## Boundaries

- No PagerDuty / Slack / email send
- No unconfirmed deploys, reverts, restarts, or edits outside the incident dir
- No edits to prior timeline lines (corrections = new entries)
- Commander = **devops** posture (no new agent); QA validates mitigation
- Optional `gh` for CI in change-correlation — skip with a note if absent

## Related

- Spec: [`SPEC-027`](../../specs/core/SPEC-027-incident-war-room.md)
- Skill: `skills/incident/SKILL.md`
- CLIs: `skills/incident/workspace.sh`, `skills/incident/timeline.sh`
- [`/debug`](debug.md) · [`/backlog`](../README.md) · [`/council`](council.md)
