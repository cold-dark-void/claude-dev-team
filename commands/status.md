---
name: status
description: >
  Read-only project snapshot hub — standup, metrics rollup, and worktree list.
  Usage /status [standup [TICKET-ID]|metrics [--json] [--section …]|worktree]
argument-hint: "[standup [TICKET-ID]|metrics [--json] [--section all|council|outcomes|worktree]|worktree]"
agent: build
---

# /status — Read-only Snapshot Hub

Single entry for status monitoring (SPEC-009, SPEC-016). **Display-only** —
MUST NOT mutate worktrees, locks, branches, ledgers, DBs, task stores, or
outcomes. MUST NOT call `worktree-lib.sh release` or any other mutator.

Engines stay live (do not re-implement aggregation here):

| Engine | Path |
|--------|------|
| Standup logic | `skills/standup/SKILL.md` (protocol retained; discovery DEPRECATED) |
| Metrics rollup | `skills/metrics/rollup.sh` |
| Worktree list | `skills/worktree-lib.sh status` |

## Dispatch

Parse the first positional argument as `<sub>`. Remaining args (including flags)
pass through unchanged to the routed sub-behavior.

| Args | Action |
|------|--------|
| _(none)_ / bare `/status` | **Sequence** (in order): standup view → metrics (all sections) → worktree status |
| `standup [TICKET-ID]` | Standup snapshot only (skill logic) |
| `metrics [--json] [--section all\|council\|outcomes\|worktree]` | Metrics rollup only (flag parity with former metrics Surface) |
| `worktree` | Worktree list/status only (`worktree-lib.sh status`) |
| unknown | Print usage and stop |

```
Usage: /status
       /status standup [TICKET-ID]
       /status metrics [--json] [--section all|council|outcomes|worktree]
       /status worktree
```

Unknown sub → print usage and stop. Do **not** guess a default sub other than
the bare full-snapshot sequence.

---

## Bare `/status` — full snapshot sequence

Run the three views **in this order**, each under a clear section header.
Continue to the next view even if one degrades (missing tasks, missing jq,
empty worktrees). Do not stop early on partial data.

```
═══ Standup ═══════════════════════════════════════════════════════════
<run Sub: standup with no TICKET-ID filter>

═══ Metrics ═══════════════════════════════════════════════════════════
<run Sub: metrics with no flags — all sections, human tables>

═══ Worktrees ═════════════════════════════════════════════════════════
<run Sub: worktree>
```

Each sub section follows the same steps as the dedicated sub below. Read-only
constraints apply to every step.

---

## Sub: `standup` — skill-delegate → `skills/standup`

**Do not re-implement standup behavior here.** Read and follow
`skills/standup/SKILL.md` with remaining args passed through.

| Invocation | Behavior |
|------------|----------|
| `/status standup` | All active tasks across tickets |
| `/status standup <TICKET-ID>` | Filter tasks whose subject contains that ID |

Pass-through: optional `TICKET-ID` only. No flags on the current surface.

Standup discovery is DEPRECATED (CDT-46-C4 T8) but the protocol body is retained
as the skill-delegate backend — do not pure-stub it. Behavior parity with
`skills/standup/SKILL.md` MUST hold (TaskList + file-store reconcile, context.md
mtime staleness, READY via `dag-lib.sh ready-set`, epic rollup, escalation
surface only — never auto-send).

Standup is **read-only**: MUST NOT call `TaskUpdate`, `TaskCreate`, SendMessage,
or any task-store mutator. Surface suggested actions; do not execute them.

---

## Sub: `metrics` — engine → `skills/metrics/rollup.sh`

Display-only observability rollup (CDV-187 / SPEC-026 display path). Aggregation
is owned exclusively by `rollup.sh` — agents MUST NOT hand-aggregate JSONL or
index files.

### Flag parity

- `/status metrics` — all sections, human tables
- `/status metrics --json` — single JSON object on stdout
- `/status metrics --section <all|council|outcomes|worktree>` — one section
- Flags may combine: `/status metrics --json --section outcomes`

### Step 1: Resolve rollup.sh

Install-aware resolution via `plugin-dir.sh` (pre-release-safe tilde-map
`sort -V` PDH stanza):

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
ROLLUP_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/rollup.sh)

if [ -z "$ROLLUP_SH" ] || [ ! -f "$ROLLUP_SH" ]; then
  echo "error: skills/metrics/rollup.sh not found in the installed plugin cache" >&2
  exit 1
fi
```

### Step 2: Invoke rollup (pass-through flags)

Forward user-supplied `--json` / `--section` args unchanged. Do not re-parse
or re-aggregate. For bare `/status`, invoke with no flags (all sections).

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
ROLLUP_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/rollup.sh)
bash "$ROLLUP_SH" "$@"
```

| Exit | Meaning |
|------|---------|
| 0 | Success or partial (missing sources / no jq → section degrade, still 0) |
| 64 | Usage error (unknown flag / bad section) |

### Step 3: Present output

Print the script's stdout as-is. Do not reformat. Do not open council report
bodies under `.claude/council/*.md`.

**MUST NOT** call `emit-outcome.sh`, council index writers, or any task-store
mutator.

---

## Sub: `worktree` — engine → `skills/worktree-lib.sh status`

Read-only enumeration of `$MROOT/.worktrees/*` (lock FRESH|STALE|NONE, age,
HEAD). Same lib semantics as former `/worktree status|list` (SPEC-016).

### Step 1: Resolve worktree-lib.sh

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)

if [ ! -f "$WT_LIB" ]; then
  echo "error: worktree-lib.sh not found" >&2
  exit 1
fi
```

### Step 2: List only (status)

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
bash "$WT_LIB" status
```

Print stdout to the user. Exit non-zero from the lib is unexpected for status —
surface stderr if it occurs.

### Constraints (worktree sub)

- MUST resolve via `plugin-dir.sh` — never `$MROOT/skills/worktree-lib.sh` alone.
- MUST call only `status` (or equivalent list) — **MUST NOT** call `release`,
  `ensure`, `register`, or `sweep`.
- MUST NOT call `git worktree remove` / `git worktree add`.
- Mutating release remains on `/worktree release <slug>` (not this command).

---

## Global constraints

- **Read-only hub** — no writes under `.claude/`, no task mutations, no DB
  writes, no lock changes, no branch deletes.
- **No `release`** — this command must not invoke worktree release or any
  force-remove path. Release lives on `/worktree` only.
- Engines stay live: `rollup.sh`, `worktree-lib.sh`, and standup protocol body
  under `skills/standup/SKILL.md` (discovery DEPRECATED; skill-delegate retained).
