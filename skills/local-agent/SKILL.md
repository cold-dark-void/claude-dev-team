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
diff-review, 2-attempt escalation, and OS-level leash enforcement are PR2.

## Purpose

Cut Claude token spend (real dollars, subscription-cap pressure, Opus-on-trivia
waste) with zero quality regression. Every offloaded change passes the same
machine-check as Claude-authored work. The feature is invisible when off.

## Components

```
skills/local-agent/
├── SKILL.md   (this file)
└── run.sh     subprocess CLI — the PR1 leaf primitive
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

## Leash (best-effort, NOT OS-enforced)

The local agent runs with its working directory set to the ticket worktree
(`opencode run --dir <worktree>`) and relies on OpenCode's own
permission/provider configuration to bound tool actions and network egress to
the configured model endpoint. This is **convention-level confinement, not
OS-enforced isolation**.

**Residual risk:** a misconfigured or adversarial local model could in principle
write outside the worktree or reach other hosts. PR1 accepts this risk for an
opt-in, user-controlled feature. Hard OS-level enforcement (filesystem scope via
bubblewrap/seccomp, egress allowlist) is a future ticket (PR2/SPEC-019-follow-up).

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

## PR2 deferral

This skill ships the standalone wrapper only. The following are PR2:

- Orchestrator routing (per-task eligibility check, brief composition)
- Claude diff-review loop
- 2-attempt escalation to the Claude executor
- OS-level leash enforcement (bubblewrap/seccomp + egress allowlist)

## Cross-references

- **SPEC-019** — Local-Agent Offload via OpenCode (this skill's governing spec)
- **SPEC-016** — Worktree Isolation: caller resolves worktree via `worktree-lib.sh`; `run.sh` receives it as `--worktree`
- **SPEC-003** — Agent Role System: ic4 Sonnet tier is the fallback executor; coupling documented in SPEC-019
- **SPEC-009** — Ticket Workflow: 2-attempt escalation rule (PR2)
- **SPEC-010** — Code Review & Release: diff-review path used in PR2 orchestration
