---
name: doctor
description: Diagnose dev-team plugin + project install/config health (PASS/WARN/FAIL table). Read-only by default; --fix for allowlisted repairs only.
argument-hint: "[--json] [--fix] [--only <id|group>] [--gate=<orchestration|team>]"
---

# /doctor

Install & config diagnostics for the **dev-team plugin** and the current project
(SPEC-022). Prints a PASS/WARN/FAIL table with a concrete fix-it line per finding.

**Naming:** Claude Code also has a harness built-in `/doctor` (harness install
health). This plugin command is namespaced as **`dev-team:doctor`** and covers
plugin/project health only — it does not shadow or replace the harness command.

**Read-only by default.** Never creates memory, hooks, or settings. Bootstrap
remains `/setup team` / `/setup orchestration`. Optional deps missing → WARN, never
FAIL.

## Arguments

| Args | Action |
|------|--------|
| _(none)_ | Full battery, human table |
| `--json` | Single JSON document on stdout |
| `--fix` | Apply allowlisted repairs only (see below) |
| `--only <id\|group>` | Run a subset of checks |
| `--gate=<orchestration\|team>` | Gate-mode self-remediation (M6c / CDT-67) |
| `-h` / `--help` | Usage |

Flags may combine: `/doctor --json --only memory`.

### `--fix` allowlist

1. Clear held `distilling_lock` (mirrors `/memory distill --force`)
2. Remove STALE-per-SPEC-016 `.wt-lock` files (not FRESH; not worktree dirs)
3. Sweep `.claude/handoff/cache/*.tmp`

TTY → confirm each repair. Non-TTY → apply. Second `--fix` is a no-op when clean.

## Exit codes

| Code | Meaning (bare) |
|------|---------|
| 0 | All executed checks PASS |
| 1 | ≥1 WARN, no FAIL |
| 2 | ≥1 FAIL |
| 64 | Usage error |

Under `--gate=`: exit 2 only for **blocking** FAILs (fix-it not exactly
`/setup <gate>`); self-remediating FAILs stay status FAIL but yield exit 1
(with WARNs or alone). See SPEC-022 M6c.

**Caller gate (SPEC-022 M6b/M6c):** `/setup team` and `/setup orchestration`
hard-gate on **`dev-team:doctor --gate=<sub>`** (≤1 continue; 2 block) — not the
harness `/doctor`. Doctor remains pure diagnostic — callers own the gate;
override is `--skip-doctor` on those setup subs.

## Step 1: Resolve doctor.sh

Install-aware resolution via `plugin-dir.sh` (script ships in the plugin, not
necessarily the project tree):

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
DOCTOR_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/doctor/doctor.sh)

if [ -z "$DOCTOR_SH" ] || [ ! -f "$DOCTOR_SH" ]; then
  echo "error: skills/doctor/doctor.sh not found in the installed plugin" >&2
  exit 1
fi
```

## Step 2: Invoke doctor (pass-through flags)

Forward any user-supplied flags unchanged. Do not re-parse or re-aggregate:

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
DOCTOR_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/doctor/doctor.sh)
bash "$DOCTOR_SH" "$@"
```

## Step 3: Present output

Print the script's stdout as-is (human table or JSON). Do not reformat.

## Notes

- **Display / diagnose only** in default mode — MUST NOT write under `.claude/`,
  mutate `memory.db` (except `--fix` distilling_lock clear), or call network.
- **Worktree-aware** — resolves `$MROOT` via `git rev-parse --git-common-dir`.
- Check-id table and severity rules: `skills/doctor/SKILL.md`.
- Future `/release` preflight adoption is deferred (SPEC-010 revision).
