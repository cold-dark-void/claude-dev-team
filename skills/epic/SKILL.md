---
name: epic
description: |
    Umbrella decomposition and sequenced orchestration (SPEC-025). PM+TL
    jointly decompose an epic into child tickets + cross-ticket DAG; persist
    via Linear preferred + local write-through; walk ready children by handing each to
    /kickoff or /orchestrate. Composition layer only — never reimplements the
    ticket lifecycle. Usage: /epic <EPIC-ID> ["text"] | status | complete |
    block | unblock | sync | --redecompose | [--autopilot[=<token>]] |
    [--no-context-discipline] | [--worktree] [--release <bump>]
user-invocable: false
---

# Epic — Umbrella Decomposition & Sequenced Orchestration

Governing spec: `specs/core/SPEC-025-epic-umbrella-decomposition.md`.

**Composition rule (M11):** `/epic` ends at the handoff string. It does **not**
inline kickoff/orchestrate steps, spawn IC agents, write application code,
create **per-child** worktrees, or write epic children into `.claude/tasks/`.
**M14 carve-out:** MAY ensure/route one integration worktree (`epic-<ID>`) and
compose end-of-epic seal; MUST NOT re-implement full orchestrate lifecycle or
`/release` version/tag/push.

Mechanical CLI (subprocess only, never source):

```bash
bash skills/epic/epic-lib.sh <cmd> …
```

State lives at `$MROOT/.claude/epics/<EPIC-ID>/state.json` (shared across
worktrees). Override root for tests: `EPIC_ROOT`.
Writers serialize via exclusive flock on `$MROOT/.claude/epics/.lock`
(SPEC-025 M6); readers unlocked.

---

## Arguments

| Invocation | Behavior |
|------------|----------|
| `/epic <ID> "<text>"` | Decompose if no state; else resume execute |
| `/epic <ID>` | Resume / status if state exists; else prompt for text |
| `/epic status [<ID>]` | Rollup one epic or all active |
| `/epic --redecompose <ID> "<text>"` | Confirm → re-decompose non-completed only |
| `/epic complete <ID> <CHILD>` | Manual complete (kickoff-mode children) |
| `/epic block <ID> <CHILD> [reason]` | Mark child blocked |
| `/epic unblock <ID> <CHILD>` | Mark child pending again |
| `/epic sync <ID> [--dry-run]` | Refresh local `state.json` from Linear (M15) when state may be stale |
| `/epic … --worktree` | (decompose/execute/resume/`--redecompose` only) Enable epic integration-worktree mode (SPEC-025 M14 / CDT-141). Bare flag only — value forms hard-fail (exit 64). Persists `worktree_enabled=true` on init when set. After init (and on resume when state enabled): ensure **one** integration worktree `epic-<EPIC-ID>` (C2). On resume: omit to honor store; present must match state or exit 64 (C6). Illegal on `status` \| `complete` \| `block` \| `unblock` \| `sync`. |
| `/epic … --release <bump>` | (with `--worktree` only) End-of-epic release bump intent; `<bump>` ∈ {patch,minor,major}. Space form canonical; `--release=<bump>` accepted alias. Alone / bare / `each`\|`end` / without `--worktree` → exit 64, zero side effects. Persists `release_bump` on init. Resume: omit honors store (no silent clear); mismatch → 64 (C6). After last child: Mode B.7 seal once (squash → one `/release <bump>` → `sealed=true`; C5). Without this flag: no epic seal, unless a new decompose carries a release-bump `--autopilot` token, which sets the same intent (Step 0.5). |
| `/epic … --no-context-discipline` | Debug opt-out of M13 between-child boundary (default **on**) |

Execution mode (`kickoff` | `orchestrate`) is chosen **once** at first execute
and stored in `state.json` (L7).

**Context discipline (M13 / CDT-127):** default **on** for multi-child Mode B.
Debug opt-out: `--no-context-discipline` **or** `EPIC_NO_CONTEXT_DISCIPLINE=1`.
Single-child epics: no mandatory boundary. See **B.6**.

---

---

## Load protocol

Mode bodies live in this directory — this file is the router. Read **only the
current stage**; do not read every stage file up front.

1. Once per run: read `run-start.md` and run its Step 0 fence (canonical PDH
   stanza — prints `PDH=<root>` to stderr), then Step 0.4 (worktree/release
   flags) and Step 0.5 (autopilot enablement). Every later fence carries the
   root as `skills/lib/pdh-later-fence.sh` session state; re-run the Step 0 fence first
   when the carried root is not held.
2. Resolve and read the mode file for the dispatch arm you are executing:
   `STEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/<stage>)`.

| Dispatch arm | File | What |
|--------------|------|------|
| Decompose (new epic) | `mode-a-decompose.md` | A.1–A.6: prechecks, PM+TL spawn, merge, cycle gate, approval, persist + M4.1/M12 dual-write |
| Execute / Resume | `mode-b-execute.md` | B.1–B.7: rollup, ready set, handoff, completion, M13 boundary, end-of-epic seal |
| `status` | `mode-c-status.md` | `show` / `rollup` |
| `complete` / `block` / `unblock` | `mode-d-complete.md` | Thin `set-status` wrappers (Mode D) |
| `sync` | `mode-f-sync.md` | Linear → local refresh (M15) |
| `--redecompose` | `mode-e-redecompose.md` | Confirm → re-decompose non-completed only |
| Shared preamble | `run-start.md` | Step 0 roots, Step 0.4 flags, Step 0.5 autopilot |

3. After a mode finishes, return to this router for the next dispatch arm.

Router anchor — the same canonical stanza as `run-start.md` Step 0; fences in
this file (e.g. Passive notifications) carry from it:

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

---

## Integration notes

### Standup (M10)

`/status standup` runs `epic-lib.sh rollup` and prints `## Epics` when non-empty.
Sourced from `state.json`, not prose.

### wrap-ticket (SHOULD)

`/wrap-ticket` calls `epic-lib.sh mark-done "$TICKET_ID"` best-effort (matches
child `id` or `linear_id`). Unknown ticket → exit 0, no fail.

### What /epic MUST NOT do (M11)

- Write application code or spawn IC agents directly
- Run review loops
- Create/remove **per-child** worktrees (or any worktree outside the M14 integration carve-out)
- Store children in `.claude/tasks/`
- Expose any option that skips PM on child handoff
- Treat seed packets as status authority (status SoT = `epic-lib` / `state.json` only)
- Inline next-child handoff while prior child transcripts remain live context when M13 discipline is on

**M11 carve-out (CDT-141-C2/C3/C5 / M14):** when `worktree_enabled`, `/epic` **MAY**
ensure **exactly one** integration worktree (`epic-<EPIC-ID>` via
`ensure-integration-worktree` → worktree-lib) and **route** child handoffs into
it (`resolve-child-worktree` / `ensure-ticket-worktree` + B.4 template). At
end-of-epic with `release_bump` set, **MAY** run **B.7** seal composition
(`seal-ready` / `seal` → squash-stage + one `/release` + `sealed=true`). Still
MUST NOT create per-child worktrees, remove worktrees (including the integration
tree on child wrap), re-implement kickoff/orchestrate WT lifecycle, or fork
`/release`'s version/tag/push contract.

---

## Error handling

| Case | Action |
|------|--------|
| No EPIC-ID | Ask; do not guess |
| Decompose without text | Prompt for epic text |
| Cycle in DAG | Halt; zero writes; name back-edge |
| Decline approval | Exit; zero writes **including** zero Linear project create/link (AC12) |
| Linear fail / absent (issue, project, or attach) | Exactly: `Linear unavailable — continuing with local write-through only`; continue local (M5/M12) |
| Linear inventory fail (M4.1) | M5 notice; **skip Linear child creates**; local write-through only (no silent duplicates) |
| Linear parent has ≥1 non-canceled child (M4.1) | Adopt unique map (zero creates) **or** HALT with exact line `HALT: Linear already has N child issue(s) under <EPIC-ID> — adopt or confirm force-create; refusing duplicate create`; autopilot never force-creates |
| `/epic sync` no state | Report nothing to sync; stop |
| `/epic sync` MCP down | M5 notice; zero state mutation |
| `/epic sync` stale local | `sync-apply` fills null `linear_id` / project id; pulls status forward; never downgrades `completed`; orphans report-only |
| Project multi-hit exact name | Link first exact survivor; print exactly `Multiple Linear projects named '<title>' — linking first hit`; do not create (OQ3) |
| Child attach fail | Keep `linear_project_id`; continue other children (OQ5) |
| Bare resume + null project id | Do not create/link project (OQ4) |
| Resume M14 flags omitted | Honor stored `worktree_enabled` / `release_bump` (C6); ensure same integration tree |
| Resume M14 flags conflict with state | Exit **64**, zero side effects; no silent mode change/downgrade (C6) |
| All children completed + `release_bump` set | **B.7** seal once: squash-stage → one `/release <bump>` → `sealed=true` (C5) |
| Seal failure (B.7 post-stage) | Bare `seal --abort` (stash then reset if it refuses via `--force`); `sealed` stays false; no partial tag/push (C5/CDT-170) |
| Seal abort (clean main or seal-owned stage) | Bare `seal --abort`; resets seal-owned staging; exit 0. Other dirt → exit **1**, WIP preserved — `--force` = stash then reset for an intentional wipe (CDT-170) |
| No `release_bump` at end | No epic seal path (C5) |
| No ready children | Report rollup; stop cleanly |
| Confirm handoff = n | Exit; child stays pending (or revert in_progress if already set — prefer confirm **before** set-status) |
| M13 seed build/validate fail | Exactly: `context-discipline: seed failed — <reason>`; next child stays `pending`; no `in_progress` without valid seed when boundary required |

Confirm **before** `set-status in_progress` so `n` leaves state unchanged (AC10).

---

## Passive notifications (CDT-123 / CDV-210 Tier B)

Same fail-open webhook sink as `/orchestrate` (`skills/notify/webhook.sh`). Never
block `/epic` on notify failure. Unset `AGENT_WEBHOOK_URL` → silent.

At each site that says **Passive notifications → Tier B**, run (fresh shell):

```bash
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
NOTIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh)
NOTIFY_SOURCE=epic NOTIFY_TICKET="<EPIC-ID or CHILD-ID>" \
  bash "$NOTIFY" <event> "<detail ≤500 chars>"
```

| Event | Epic call site |
|-------|----------------|
| `task_blocked` | Autopilot halt at A.5 (atomic scope+plan) or B.3 (per-child handoff) |
| `task_complete` | Successful A.6 persist after approve; optional: epic all-children completed |

---

## Tests

```bash
bash skills/epic/test.sh
```
