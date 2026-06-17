---
name: local-agent
description: Opt-in offload of mechanical, machine-verifiable tasks to a local model via the OpenCode CLI. Off by default; falls back transparently to Claude when disabled or when preflight fails.
---

# Local Agent

**PR1 leaf primitive — invoked by the PR2 orchestrator (not user-invoked directly).**

Offloads one mechanical, machine-verifiable task to a user-provided local model
via the OpenCode CLI, then gates the result on a caller-supplied deterministic
machine-check. When the flag is off or preflight fails, the wrapper exits `2` and
the caller falls back to the Claude executor — output is indistinguishable from a
Claude-only run.

Implements the SPEC-019 PR1 "scriptable subset". Orchestrator routing, Claude
diff-review, and 2-attempt escalation were delivered in PR2 (CDV-20). The OS-enforced
bubblewrap FS leash was delivered in CDV-21.

## Purpose

Cut Claude token spend (real dollars, subscription-cap pressure, Opus-on-trivia
waste) with zero quality regression. Every offloaded change passes the same
machine-check as Claude-authored work. The feature is invisible when off.

## Components

```
skills/local-agent/
├── SKILL.md              (this file)
├── run.sh                subprocess CLI — the PR1 leaf primitive
└── emit-orch-metric.sh   subprocess CLI — PR2 companion metrics helper
```

## Opt-in flag

`LOCAL_AGENT` environment variable must equal **exactly** the string `opencode`.
Any other value (including unset or empty) disables the feature: the wrapper
emits a one-line notice to stderr and exits `2` (fallback).

This mirrors the `EMBEDDING_URL` pattern (SPEC-004/006): an env-var opt-in, not a
`settings.json` key. No model or provider keys are managed here — OpenCode owns
its own configuration.

## Interface

```
run.sh --worktree <path> --brief <text> --check <shell-expr>
```

**THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.**

| Flag | Required | Description |
|------|----------|-------------|
| `--worktree <path>` | Yes | Ticket worktree directory; must exist. The **caller** resolves this via `worktree-lib.sh` (SPEC-016). `run.sh` does not call `worktree-lib.sh` itself (subprocess-CLI separation). |
| `--brief <text>` | Yes | Self-contained task brief; the local agent's **sole** context. No agent memory, cortex, or SQLite DB is appended to the invocation. |
| `--check <shell-expr>` | Yes | Deterministic machine-check run via `bash -c "$CHECK"` (never `eval`) after `opencode run` returns. Exit 0 = pass; non-zero = fail. |

## Invocation

```
opencode run --dir <worktree> "<brief>"
```

The brief is the single positional argument. `--dir` sets the subprocess working
directory. No other flags or context are passed.

**Liveness probe** (preflight): `opencode --version` must succeed. If `opencode`
is absent from PATH or the liveness probe fails, the wrapper exits `2` (fallback)
with one stderr notice.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | **Success** — `opencode run` completed AND `bash -c "$CHECK"` returned 0. |
| `1` | **Machine-check failure** — OpenCode ran but the post-check returned non-zero (or `opencode run` itself exited non-zero). Any diff is left in place for the caller to review or discard. |
| `2` | **Fallback** — `LOCAL_AGENT` != `"opencode"`, `opencode` absent from PATH, or liveness probe failed. Caller MUST treat `2` as "run this task on Claude instead". A one-line notice is emitted to stderr. |
| `64` | **Usage error** — malformed invocation (missing or unknown flag). |

Stdout carries only the result payload; **all diagnostics go to stderr**. Stdout is
empty on any non-zero exit. (Matches `worktree-lib.sh` / `ci-watch` stdout discipline.)

## Leash (OS-enforced when available)

When `bwrap` is present on PATH and `LOCAL_AGENT_SANDBOX` is not set to `0`, the
`opencode run` call runs inside a **bubblewrap FS sandbox** with the following
bind-set:

| Mount | Mode | Purpose |
|-------|------|---------|
| `--ro-bind / /` | read-only | Full host FS as base layer; blocks all writes by default |
| `--dev /dev` | private | Private device namespace |
| `--proc /proc` | private | Private proc namespace |
| `--tmpfs /tmp` | private tmpfs | Ephemeral scratch; discarded after the call |
| `--bind <worktree> <worktree>` | read-write | Primary write target |
| `--bind-try <gitdir> <gitdir>` | read-write | Resolved `.git` dir (a worktree's `.git` file points outside the worktree; must be writable or git ops fail) |
| `--bind-try <git-common-dir> <git-common-dir>` | read-write | Shared object store, packed-refs, etc. |
| `--bind-try <XDG_CONFIG_HOME/opencode> <path>` | read-write | OpenCode config dir |
| `--bind-try <XDG_DATA_HOME/opencode> <path>` | read-write | OpenCode data dir |
| `--bind-try <XDG_CACHE_HOME/opencode> <path>` | read-write | OpenCode cache dir |
| `--bind-try <XDG_STATE_HOME/opencode> <path>` | read-write | OpenCode state dir |

**Confinement scope:** worktree + git plumbing (gitdir + git-common-dir) + opencode
state dirs. This is NOT worktree-leaf-only: a git worktree's `.git` is a pointer
file outside the worktree itself, so the gitdir and common-dir must be writable or
git operations fail inside the sandbox.

**Scope boundary:** the sandbox wraps ONLY the `opencode run` call. The
caller-supplied `--check` runs **unconfined on the host** — it is trusted
verification code that requires full git plumbing access.

**Network NOT enforced:** no `--unshare-net` is applied. Restricting egress via an
allowlist is a separate future ticket. This sandbox provides FS-scope isolation only.

**Graceful degradation:** when `bwrap` is absent from PATH, `LOCAL_AGENT_SANDBOX=0`
is set, or the `bwrap` pre-flight probe fails, the wrapper emits a one-line downgrade
notice to stderr and falls back to convention-level `--dir` confinement (the `opencode
run --dir <worktree>` working-directory bound from PR1). The exit-code contract
(`0`/`1`/`2`/`64`) is unchanged in all modes.

**Escape hatch:** set `LOCAL_AGENT_SANDBOX=0` to explicitly bypass the bubblewrap
leash and run with `--dir`-only confinement (useful for environments where `bwrap`
is installed but namespaces are restricted, e.g. some container runtimes).

The wrapper issues no git write commands; the local agent cannot commit, push, or
tag via the wrapper.

## Metrics

One JSONL record is appended to `.claude/local-agent/metrics.jsonl` per terminal
path (`success` / `fail` / `fallback`). Writes are guarded by `command -v jq`; if
`jq` is absent, the append is skipped silently (best-effort, non-fatal — never
changes the wrapper's exit code).

**PR1 record schema** (canonical — matches `run.sh` exactly):

```json
{ "ts": 1718500000, "outcome": "success", "exit_code": 0, "saved_est_tokens": null, "spent_tokens": null }
```

| Field | Type | Description |
|-------|------|-------------|
| `ts` | integer | Epoch seconds. |
| `outcome` | string | `"success"` \| `"fail"` \| `"fallback"` — one per terminal path. |
| `exit_code` | integer | `0` \| `1` \| `2` — the wrapper's exit code for this terminal path. |
| `saved_est_tokens` | null | Estimate of **Claude** tokens saved (authoring cost avoided). Always `null` in PR1: `run.sh` cannot compute this without the orchestrator's accounting. Deferred to PR2. Never the string `"unknown"`. |
| `spent_tokens` | number \| null | Measured **local** OpenCode cost (NOT a Claude cost), or `null` when not cheaply available. Distinct from `saved_est_tokens`. |

**PR2-only additions** (not PR1 keys): `ticket` (the orchestrator owns the ticket
id; `run.sh` is invoked without one) and `spent_review_escalation` (Claude tokens
spent on diff review + escalation, which occur in `skills/orchestrate/`, not in
the wrapper).

These PR2 fields are **not** emitted by `run.sh` (which is frozen at its 5-key PR1
record). They are emitted by `emit-orch-metric.sh` — a separate companion CLI the
orchestrator calls after completing diff-review and escalation accounting.

## PR2 companion metrics: emit-orch-metric.sh

```
emit-orch-metric.sh <ticket> <saved_est_tokens|null> <spent_review_escalation|null>
```

**THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.**

Appends one JSONL record to `.claude/local-agent/metrics.jsonl` per orchestrator
run, capturing the PR2-owned fields that `run.sh` cannot know:

**PR2 companion record schema**:

```json
{ "ts": 1718500000, "ticket": "CDV-20", "saved_est_tokens": 8000, "spent_review_escalation": 0 }
```

| Field | Type | Description |
|-------|------|-------------|
| `ts` | integer | Epoch seconds. |
| `ticket` | string | Ticket identifier (orchestrator-owned). |
| `saved_est_tokens` | number \| null | Orchestrator estimate of Claude tokens saved by local-agent offload. `null` when not available. |
| `spent_review_escalation` | number \| null | Claude tokens spent on diff-review + escalation in the orchestrator. `null` when not applicable. |

Arguments `<saved_est_tokens>` and `<spent_review_escalation>` are passed as raw
JSON values — pass a number or the literal word `null`. They are forwarded via
`--argjson` so they serialize as JSON numbers/null, never as strings.

jq-guarded: if `jq` is absent, the script exits `0` silently (no record written).
Best-effort and non-fatal: any internal failure returns `0`. Only usage errors
(wrong argument count) exit `64`.

## Delivery history

- **PR1** — standalone wrapper: `run.sh`, `SKILL.md`, metrics schema
- **PR2 (CDV-20)** — orchestrator routing, Claude diff-review loop, 2-attempt escalation,
  `emit-orch-metric.sh`
- **CDV-21** — bubblewrap FS-scope leash (this section); egress allowlist remains backlog

## Cross-references

- **SPEC-019** — Local-Agent Offload via OpenCode (this skill's governing spec)
- **SPEC-016** — Worktree Isolation: caller resolves worktree via `worktree-lib.sh`; `run.sh` receives it as `--worktree`
- **SPEC-003** — Agent Role System: ic4 Sonnet tier is the fallback executor; coupling documented in SPEC-019
- **SPEC-009** — Ticket Workflow: 2-attempt escalation rule (PR2)
- **SPEC-010** — Code Review & Release: diff-review path used in PR2 orchestration
