# Runbook: Migrating an existing project to v1.0.0

One-sitting checklist for **0.x → 1.0.0** consumers. Authoritative command renames:
[CHANGELOG v1.0.0 Migration](../../CHANGELOG.md#v100). New project? Use
[Onboarding](onboarding.md) instead.

---

## 1. Update the plugin

| Install path | What to do |
|--------------|------------|
| **Claude Code marketplace** | Auto-latest usually lands `1.0.0`. If still on `0.80.x` / `1.0.0-pre.N`, update/reinstall via marketplace (`/plugin` refresh for `dev-team`). Pre-release → stable comparator edge cases: see CDT-55. |
| **Git clone** | `git pull` (or checkout the `v1.0.0` tag). **Upstream no longer ships `.claude/`** (hooks, backlog, plans) — local `.claude/` stays yours; regenerate hooks in step 4. |
| **opencode** | Pull, then re-run `bash install.sh` so agent copies pick up new text. |

Confirm the plugin reports **1.0.0** (or newer patch) before continuing.

---

## 2. Run `/doctor` first

Plugin surface: **`dev-team:doctor`** (not the Claude Code harness built-in `/doctor`).

```
/doctor
```

It flags schema drift, stale/missing hooks, posture coherence, and resolve issues.
`/setup team` and `/setup orchestration` **hard-gate** on it: exit ≤1 proceeds; exit 2
blocks. Override only when needed:

```
/setup team --skip-doctor
/setup orchestration --skip-doctor
```

`--skip-doctor` **must** print a WARNING, then continues. Prefer fixing FAIL rows first.

**Self-remediating hooks under the setup gate (v1.0.1+):** `/setup team` and
`/setup orchestration` run doctor with `--gate=team|orchestration`. FAIL rows whose
**exact** fix-it is that same command (typical: missing/stale `hooks.events` /
`hooks.hygiene` with fix-it `/setup orchestration`) stay visible as FAIL but **do not
block** the gate. Bare `/doctor` (no `--gate`) still exits 2 on those rows — honesty
for CI/support. Genuine FAILs (schema, version, unparseable settings, …) still block.

**Override:** `--skip-doctor` still prints a WARNING and continues (use only if needed).
Doctor `--fix` is a **narrow** allowlist (locks / handoff cache only) — it does
**not** create or rewrite hooks or migrate schema.

---

## 3. Memory DB migrate (if `schema_version` < 4)

v1.0 expects **schema_version = 4**. Skip this step if `/doctor` already PASSes
`memory.schema`, or you have no `memory.db` yet (`.md` fallback is fine).

```bash
# Project root that owns .claude/memory/memory.db
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

# Backup first
cp -a "$MROOT/.claude/memory/memory.db" \
  "$MROOT/.claude/memory/memory.db.bak-$(date +%Y%m%d)"

# Resolve plugin root, then chain v2→v3→v4 (content survives; idempotent)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
bash "$PDH/skills/memory-store/migrate.sh" "$MROOT"
```

Alternatively: `/setup team --migrate-only` (runs the same driver, then exits).

---

## 4. Re-run `/setup orchestration` (orchestration projects)

```
/setup orchestration
```

**Why this is the critical step:**

1. **Stale hook engines** — pre-v1 live hooks often resolve the plugin with bare
   `sort -V | tail`. With `1.0.0-pre.N` dirs still in the cache, that can pick a
   **stale** pre-release engine. Regeneration installs the pre-release-safe
   tilde-map stanza (`sed 's/-pre\./~pre./' | sort -V | …`).
2. **Permission posture flip** — orchestration default moves to **Cell D**:
   `auto` + sandbox enabled + `autoAllowBashIfSandboxed` + matrix allow set
   (CDT-75; epic C5 wording was “sandbox + auto”). v1.0.0–1.0.1 shipped Cell C
   (`dontAsk`); re-run `/setup orchestration` to flip and get Linear MCP working
   without MCP allow-list surgery. Re-runs print key / old / new / restore
   disclosure. Matrix evidence:
   [permission-posture-matrix](permission-posture-matrix.md).

If only self-remediating hooks FAILs blocked you historically: re-run setup on
v1.0.1+ (gate-aware). If genuine FAILs remain: fix them or `/setup orchestration
--skip-doctor`, then `/doctor` again. Non-orchestration projects can skip this step.

**Setup batch approvals (CDT-68):** settings.json merge and writing
`bash-compress.sh` may require **one** explicit user approval up front (not mid-run
denials). Do not remove those prompts — they are self-escalation guards; batch them.

---

## 5. Command invocations — deadline **v1.1**

Deprecation **stubs still redirect** in v1.0.x, then are **deleted at v1.1**.
Update CI, project docs, and custom skills **now**.

Full table: [CHANGELOG v1.0.0 Migration](../../CHANGELOG.md#v100). Headlines:

| Old | New |
|-----|-----|
| `/memory-*`, `/validate-memory` | `/memory <sub>` |
| `/check-specs`, `/create-spec`, `/find-spec`, `/list-specs`, `/update-spec`, `/generate-specs`, `/generate-tests`, `/reflect-specs` | `/spec <sub>` |
| `/blind-review` | `/council --blind` |
| `/focus`, `/blunt` | `/mode focus` · `/mode blunt` |
| `/standup`, `/metrics`, `/worktree list\|status` | `/status standup` · `/status metrics` · `/status worktree` |
| `/scaffold-project`, `/init-orchestration`, `/init-team` | `/setup project` · `orchestration` · `team` |
| `/fix-ticket` | `/debug ticket` |
| `/local-do`, `/incident`, `/demo` | **removed** (no stub behavior beyond tombstone) |

Live mutate worktree path remains `/worktree release <slug>` only.

---

## 6. Backlog + Linear MCP (if you use `/backlog`)

v1.0 is **Linear-first** with mandatory local write-through. Run once:

```
/backlog reconcile
```

Repairs index ↔ item files; with Linear MCP up, dual-write stays consistent.
Ship/wrap still **never** stage `.claude/backlog*` into product commits.

---

## 7. No action needed

These survive the upgrade without migration steps:

- Agent **memories / cortexes** (after schema is current)
- Existing **worktrees** (release via `/worktree release` when done)
- Local **plans** / process trackers under `.claude/`
- Committed **`CONTEXT.md`** (domain glossary)
- Per-agent **`directives.md`**

---

## Done when

- [ ] Plugin is **1.0.0+**
- [ ] `/doctor` exit ≤1 (hooks + `memory.schema` clean if you use them)
- [ ] Orchestration projects re-ran `/setup orchestration` (posture + hooks)
- [ ] Scripted callers use hub names (step 5)
- [ ] `/backlog reconcile` done if applicable

**See also:** [Setup → Upgrading](../setup.md#upgrading-the-plugin-existing-projects) (0.71–0.77 minor arc) · [CHANGELOG](../../CHANGELOG.md) · [docs hub](../README.md)
