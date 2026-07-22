---
name: doctor
description: >
  Install & config diagnostics for the dev-team plugin (SPEC-022). Read-only by
  default; --fix applies a narrow allowlist. User-facing entry: /doctor
  (namespaced dev-team:doctor).
---

# doctor

Deterministic, offline install/config health battery. Diagnoses version triplet,
memory stack, hooks, settings, optional deps, worktree locks, and plugin
resolution. Never bootstraps (that is `/init-team` / `/init-orchestration`).

Governing spec: `specs/core/SPEC-022-doctor-install-diagnostics.md`.

## Components

```
skills/doctor/
├── SKILL.md      (this file)
├── doctor.sh     CLI — flags, check registry, render, --fix
├── test.sh       bite-tests
└── fixtures/     synthetic trees (optional; tests mostly build under $TMPDIR)
```

## Interface — doctor.sh

```
doctor.sh [--json] [--fix] [--only <check-id|group>] [-h|--help]
```

| Flag | Effect |
|------|--------|
| (default) | Human table on stdout; read-only |
| `--json` | Single JSON document on stdout; diagnostics on stderr |
| `--fix` | Apply allowlisted repairs only (see below) |
| `--only <id\|group>` | Run a subset of checks |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All executed checks PASS |
| 1 | ≥1 WARN, 0 FAIL |
| 2 | ≥1 FAIL |
| 64 | Usage error (unknown flag / bad `--only`) |

SKIP does not affect the exit code.

### JSON schema (`doctor_schema: "1"`)

```
{
  "doctor_schema": "1",
  "plugin_version": "<semver>",
  "resolved_tier": "dev|cache|fallback",
  "checks": [
    {"id":"…","group":"…","status":"PASS|WARN|FAIL|SKIP","detail":"…","fixit":null|"…"}
  ],
  "summary": {"pass":N,"warn":N,"fail":N,"skip":N}
}
```

`fixit` is null on PASS/SKIP. Schema evolves additively only.

## Check ids

| id | group |
|----|-------|
| `version.triplet` | version |
| `memory.sqlite3` | memory |
| `memory.db` | memory |
| `memory.schema` | memory |
| `memory.ext.vec` | memory |
| `memory.ext.lembed` | memory |
| `memory.embedding_config` | memory |
| `hooks.events` | hooks |
| `hooks.hygiene` | hooks |
| `hooks.templates` | hooks (dev-checkout only; SKIP in consumer) |
| `settings.json` | settings |
| `settings.agent_teams` | settings |
| `settings.sandbox_coherence` | settings |
| `deps.jq` | deps |
| `deps.python3` | deps |
| `deps.gh` | deps |
| `worktree.locks` | worktree |
| `worktree.distill_lock` | worktree |
| `plugin.resolve` | plugin |

## Severity

| Severity | When |
|----------|------|
| **FAIL** | Triplet drift; unparseable plugin/settings JSON; `schema_version` mismatch; wired hook → missing script; missing canonical hook **event** when `settings.hooks` exists |
| **WARN** | Optional dep absent; uninitialized memory; extension unloadable; embedding config incoherent; un-anchored hook path; stale wt-lock; held distilling_lock; sandbox/bypass coherence |
| **SKIP** | Probe tool for that check absent; dev-only check in consumer |
| **PASS** | Invariant holds |

Uninitialized memory is **WARN not FAIL** — fix-it is `/init-team`.

## `--fix` allowlist

Only these repairs (idempotent; announced; TTY confirms; non-TTY applies):

1. Clear held `distilling_lock` → `''` (mirrors `/memory distill --force`)
2. Remove **STALE** (per SPEC-016 TTL) `.wt-lock` files — never worktree dirs, never FRESH locks
3. Sweep `$MROOT/.claude/handoff/cache/*.tmp`

MUST NOT touch `settings.json`, schema, manifests, CHANGELOG, or create memory/hooks.

## Single-source expectations

| Expectation | Source |
|-------------|--------|
| Version triplet | SPEC-002 / files themselves |
| Hook set + hygiene | `skills/init-orchestration` templates |
| WT lock TTL | `WT_LOCK_TTL_SECONDS` + `worktree-lib.sh` |
| Plugin resolve | `skills/plugin-dir.sh` subprocess |
| schema_version expected | `skills/memory-store/schema.sql` seed |

## Naming

Plugin command surface: **`dev-team:doctor`**. Claude Code also ships a harness
built-in `/doctor` (harness install health). This battery covers plugin/project
health only and does not shadow the harness command.

## Related

- SPEC-022, SPEC-002, SPEC-005, SPEC-016
- `/init-team`, `/init-orchestration`, `/release`, `/memory distill --force`
