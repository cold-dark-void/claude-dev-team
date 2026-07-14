---
name: incident
description: >
  DevOps-led war-room for production incidents — severity triage, parallel RO
  investigation, append-only timeline, propose-only mitigation, comms drafts,
  cold postmortem → backlog (SPEC-027).
argument-hint: "[<description> | resume <id> | postmortem <id> | list]"
---

# /incident

Opens a devops-led **war-room** for production incidents (SPEC-027).

`/debug` is a single-bug root-cause loop. `/incident` is multi-thread response:
severity → parallel investigation → durable timeline → rollback-first
**propose-only** mitigation → stakeholder **drafts** (never sent) → postmortem.

**Boundaries:** no external paging/alerting; no unconfirmed state changes; no
timeline rewrites; incident state only under `.claude/incidents/` (not
`memory.db` / `.claude/handoff/`).

## Arguments

| Args | Action |
|------|--------|
| `<description>` | Open: severity proposal → confirm → war-room |
| _(empty)_ | Prompt for description |
| `resume <id>` | Reconstruct state solely from incident directory |
| `postmortem <id>` | Cold postmortem from artifacts + backlog offer |
| `list` | List incident ids |

Parser: first token ∈ {`resume`, `postmortem`, `list`} → subcommand; else entire
args = open description.

## Step 1: Load and follow the skill

Load **`skills/incident/SKILL.md`** and execute its protocol for the parsed
subcommand. Do not reimplement steps here.

Resolve scripts when the skill needs them:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
if [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ]; then
  WS=$(bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh)
  TL=$(bash "$PDH/skills/plugin-dir.sh" file skills/incident/timeline.sh)
else
  WS="$MROOT/skills/incident/workspace.sh"
  TL="$MROOT/skills/incident/timeline.sh"
fi
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
[ -f "${TL:-}" ] || TL="$(pwd)/skills/incident/timeline.sh"
```

## Flow (summary)

1. **Severity gate (M1)** — propose SEV1|SEV2|SEV3 + rationale; **no threads**
   until user confirms/overrides.
2. **Workspace (M2)** — `$MROOT/.claude/incidents/<YYYY-MM-DD>-<slug>/`
   (`timeline.jsonl` canonical, `timeline.md` render, `comms/`, `meta.json`).
3. **Parallel RO threads (M5)** — change-correlation / symptom-evidence /
   blast-radius in one tool-use block; findings → observation entries.
4. **Mitigation (M7)** — rollback-first proposals; execute only after explicit
   per-action confirm; declines logged as decisions.
5. **`/debug` (M6)** — code RC → **delegate**, never reimplement SPEC-014.
6. **QA gate (M4)** — `mitigated` only after QA-validation timeline entry.
7. **Comms (M8)** — local drafts only; cadence SEV1≈30m / SEV2≈2h / SEV3≈daily.
8. **Postmortem (M9/M10)** — cold from dir; action items via `/backlog add`.

## Artifacts

```
.claude/incidents/<id>/
  meta.json
  timeline.jsonl    # canonical
  timeline.md       # render
  comms/NNN-*.md
  postmortem.md
```

## Notes

- Commander posture: existing **devops** agent (SPEC-003) — no new agent.
- Full protocol, gates, and CLI contracts: `skills/incident/SKILL.md`.
- Spec: `specs/core/SPEC-027-incident-war-room.md`.
