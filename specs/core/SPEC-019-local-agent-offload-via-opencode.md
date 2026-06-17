# SPEC-019: Local-Agent Offload via OpenCode

**Status**: DRAFT
**Category**: core
**Created**: 2026-06-16

**Covers** (planned): `skills/local-agent/` (wrapper script), `skills/orchestrate/SKILL.md` (routing hook), config surface (opt-in flag), `AGENTS.md` (tool-offload note)

**Delivery split:** **PR1 (this reconcile)** delivers the *scriptable subset* — the
`skills/local-agent/run.sh` subprocess CLI, its `SKILL.md` contract, the metrics file, and
the `AGENTS.md` tool-offload note. **PR2 (separate later ticket)** delivers the
orchestrator wiring (`skills/orchestrate/`): per-task routing, the Claude diff-review loop,
2-attempt escalation, and OS-level leash enforcement. MUST/MUST-NOT clauses below that
describe routing, review, escalation, or council/TDD gating define the *target system* and
are realized in PR2; PR1 provides the leaf primitive they call.

## Overview

Defines an **opt-in** path for offloading mechanical, machine-verifiable work from
Claude onto a user-provided local model invoked through **OpenCode**, while Claude
remains the planner, router, and reviewer. The goal is to cut Claude token spend
(real dollars, subscription-cap pressure, and Opus-on-trivia waste) with **zero
quality regression**: every offloaded change passes the same machine-check, diff
review, TDD gate, and TaskCompleted gate as Claude-authored work.

OpenCode is a separate CLI, not an Anthropic model, so it is always invoked as a
**Bash subprocess** (`opencode run "<brief>"`) — never as a Claude `Task` subagent.
The feature is **invisible when off**: with no opt-in flag, no OpenCode on PATH, or a
failed preflight, the workflow falls back transparently to the Claude executor. This
mirrors the model-agnostic, graceful-degradation posture of the embeddings design
(`EMBEDDING_URL`, SPEC-004/006).

**Coupling with SPEC-003 (documented, per conflict-scan decision P):** SPEC-003 assigns
`ic4` the Sonnet model tier in its YAML definition. This spec does **not** modify any
agent definition — `ic4`'s `model: sonnet` remains the **fallback executor**. When
offload is enabled, the orchestrator routes an *eligible task* to the local model
*instead of spawning the Claude IC subagent*; the agent role and its declared tier are
unchanged and resume control on fallback or escalation. SPEC-003 should carry a
one-line forward-reference to this spec when next revised.

## MUST

### Opt-in & graceful fallback

- MUST be **disabled by default**. Offload activates only when an explicit opt-in flag
  (`LOCAL_AGENT=opencode`) is set in the project config surface.
- MUST run a **preflight check** before routing any task to the local agent: `command -v
  opencode` succeeds AND a fast liveness probe returns success. On any preflight
  failure, MUST fall back to the Claude executor and log the fallback once per run. The
  liveness probe is `opencode --version` (fast, side-effect-free; verified to return
  `1.17.4` on the reference install).
- MUST fall back to the Claude executor (the agent's declared `model` tier per SPEC-003)
  whenever the flag is unset, preflight fails, the task is ineligible, or the retry cap
  is exhausted. With offload off, output MUST be indistinguishable from a Claude-only run.

### Routing scope

- MUST route to the local agent **only** these eligible task types: ic4-class
  implementation (extending existing patterns), codebase discovery/search, and
  docs/boilerplate generation.
- MUST gate every offload on a **per-task confidence check**: route local only when (a)
  the task is mechanical AND (b) a deterministic machine-check exists for it (tests,
  lint, `bash -n`, JSON-validate, or build). If no machine-check exists, MUST route to
  Claude.
- MUST use a **static per-agent eligibility set** for this version (the three types
  above). Capability-tier routing and runtime-orchestrator routing are out of scope (see
  Open Questions).

### Invocation contract

- MUST invoke the local agent as a Bash subprocess
  (`opencode run --dir <worktree> "<brief>"` — the brief is a single positional argument),
  never as a Claude `Task` subagent. (`--dir`, positional `message`, `--format json`,
  `--model`, `--agent`, `--pure` verified present on OpenCode 1.17.4.)
- MUST assume OpenCode is already installed and configured with a default model/provider.
  This spec MUST NOT manage model or provider selection.
- MUST pass a **self-contained task brief** composed by the Claude orchestrator. The local
  agent MUST NOT be granted access to agent memory, cortex, or the SQLite memory DB — the
  brief is its sole context.
- MUST set the subprocess working directory to the ticket worktree.

### Execution isolation (leash — best-effort)

- MUST apply a **best-effort leash**: run with the working directory set to the ticket
  worktree (`opencode run --dir <worktree>`) and rely on OpenCode's own
  permission/provider configuration to bound tool actions and network egress to the
  configured model endpoint. This is **convention-level confinement, not OS-enforced
  isolation**.
- **Documented residual risk:** the wrapper does NOT spawn OpenCode inside an OS sandbox
  (bubblewrap/seccomp/namespaces). A misconfigured or adversarial local model *could* in
  principle write outside the worktree or reach other hosts. PR1 accepts this residual
  risk for an opt-in, user-controlled feature and surfaces it in `SKILL.md`. Hard
  OS-level enforcement (writes fs-scoped to the worktree, egress allowlist) is a **future
  ticket (PR2/SPEC-019-follow-up)** and is explicitly out of PR1 scope.
- The CALLER obtains the worktree via `skills/worktree-lib.sh` per SPEC-016 and passes the
  resolved path as `--worktree <path>` to the wrapper; the wrapper itself does NOT call
  `worktree-lib.sh` (subprocess-CLI separation per SPEC-016).
- MUST NOT grant the local agent authority to commit, push, or tag (the wrapper issues no
  git write commands); out-of-worktree writes are discouraged by `--dir` but not
  hard-prevented in PR1 (see residual risk above).

### Verification & review loop

- MUST run the task's deterministic machine-check after each local-agent attempt. The
  check is a caller-supplied shell string executed via `bash -c "$CHECK"` (never `eval`),
  run **after** the `opencode run` invocation. Exit 0 ⇒ pass, non-zero ⇒ fail.
  Local iterations against the machine-check do NOT consume Claude review tokens.
- MUST require Claude to review the resulting diff before the change is accepted — the
  same bar applied to Claude-authored work (reuse SPEC-010 / council `diff-mode` where
  applicable).
- MUST cap Claude-reviewed retries at **2**, inheriting SPEC-009's "agent stuck after 2
  attempts → escalate" rule. On the second rejected review, MUST escalate the task to the
  Claude executor, which completes it.
- On escalation, MUST hand the local agent's partial diff to Claude as context; Claude
  owns the final output.

### Inherited disciplines

- Offloaded implementation MUST satisfy the same TDD gate (RED → GREEN → REFACTOR for
  runtime-behavior changes) that SPEC-003 requires of ic4/ic5.
- Offloaded work MUST stay within SPEC-009's LOC caps (~1k soft / 2k hard; no single file
  >1k lines changed) and MUST NOT silently absorb discovered scope (new ticket per
  SPEC-009).
- Offloaded tasks MUST pass the same `TaskCompleted` quality gate (SPEC-013 council gate)
  as Claude-authored tasks before completion.

### Wrapper exit-code contract (PR1)

- The `run.sh` wrapper MUST use exactly these exit codes, documented in `SKILL.md`:
  - `0` — success: `opencode run` completed AND the caller's machine-check passed.
  - `1` — machine-check failure: OpenCode ran but the post-check (`bash -c "$CHECK"`)
    returned non-zero. The diff (if any) is left in place for the caller to review/discard.
  - `2` — fallback: the flag is not exactly `opencode`, OpenCode is absent, or the
    liveness probe failed. The caller MUST treat `2` as "run this task on Claude instead"
    and a one-line notice MUST be emitted to stderr.
- Stdout discipline (matching `worktree-lib.sh`/`ci-watch`): stdout carries only the
  result payload; all diagnostics go to stderr.

### Instrumentation

- MUST record, per offloaded task, one JSON record appended to
  `.claude/local-agent/metrics.jsonl` (JSONL: one record per line, mirroring the
  `.claude/ci-watch/` sidecar precedent). One record per **terminal path**
  (`success` / `fallback` / `fail`).
- **PR1 record schema** (emitted by `run.sh`):
  `{ ts, outcome, exit_code, saved_est_tokens, spent_tokens }`.
  - `ts` — epoch seconds.
  - `outcome` — `success` | `fail` | `fallback` (one per terminal path).
  - `exit_code` — `0` | `1` | `2` (the wrapper's exit code; see exit-code contract).
  - `saved_est_tokens` — estimate of **Claude** tokens *saved* (the authoring cost
    avoided). This is `null` in PR1: `run.sh` cannot know it without the orchestrator's
    accounting, so the full Claude-savings estimate is deferred to PR2. The field is
    present now to keep the schema stable. Never the string `"unknown"`.
  - `spent_tokens` — the **measured** local OpenCode cost when cheaply available (e.g.
    `opencode run --format json` event stream / `opencode stats`), else the JSON literal
    `null`. This is the local-model cost, NOT a Claude cost — distinct from
    `saved_est_tokens`.
- **PR2 additions to the schema** (not PR1 keys): `ticket` (the orchestrator owns the
  ticket id; `run.sh` is invoked without one) and `spent_review_escalation` (Claude tokens
  spent on diff review + escalation, which occur in `skills/orchestrate/`, not in the
  wrapper). PR2 appends these without breaking the PR1 keys above.
- Metric writes MUST be guarded by `command -v jq`; with `jq` absent the wrapper skips the
  metrics append (best-effort, non-fatal) rather than failing the run.
- MUST keep the metrics readable for **manual tuning** of the eligibility set. An
  automatic kill-switch is out of scope (see Open Questions).

## SHOULD

- SHOULD compose the briefest sufficient task brief — the local model has no project
  memory, but an over-long brief wastes its context window.
- SHOULD prefer discovery and docs offload over implementation offload in repositories
  whose machine-check is weak (e.g. dev-team itself: no build step, thin tests), reserving
  code-impl offload for repos with real test suites.
- SHOULD reuse the existing review path (council `diff-mode`) rather than a bespoke
  reviewer.
- SHOULD surface in `standup`/`orchestrate` output which tasks ran local vs Claude.

## MUST NOT

- MUST NOT enable offload by default.
- MUST NOT route to the local agent any of: tech-lead (architecture/design), ic5
  (ambiguous/novel/security-sensitive), the QA final release gate, the council judge or
  any council/blind-review investigator, PM kickoff, or release/version-bump/commit work.
- MUST NOT give the local agent memory/cortex/DB access, commit/push authority, or
  out-of-worktree write access.
- MUST NOT let offloaded work bypass the TDD gate, LOC caps, diff review, or
  `TaskCompleted` council gate.
- MUST NOT block or degrade the workflow when OpenCode is absent — always fall back.

## Routing & escalation flow

```
for each unblocked task:
  if flag off OR task ineligible OR no machine-check OR preflight fails:
      → Claude executor (normal path)
  else:
      attempt = 0
      compose self-contained brief
      loop:
          opencode run "<brief>"           # cwd = worktree, sandboxed, allowlisted
          run machine-check                # local iterates here for FREE
          if machine-check fails: continue local iteration (no Claude cost)
          Claude reviews diff              # the gated, token-costing step
          if review passes: accept → TaskCompleted gate → done
          attempt += 1
          if attempt >= 2:                 # inherits SPEC-009 2-attempt rule
              → escalate: Claude executor finishes (gets partial diff as context)
          else:
              fold review feedback into brief; loop
  record { saved_est, spent_review_escalation } to .claude/ metrics
```

## Configuration

- Opt-in flag `LOCAL_AGENT` is an **environment variable** (mirroring the `EMBEDDING_URL`
  pattern, SPEC-004/006), not a `settings.json` key. It MUST equal exactly the string
  `opencode`; any other value (including unset or empty) ⇒ feature off ⇒ wrapper exits `2`
  (fallback).
- Metrics file: `.claude/local-agent/metrics.jsonl` (JSONL, one record per line). PR1
  record keys: `{ ts, outcome, exit_code, saved_est_tokens, spent_tokens }` (see
  Instrumentation; `ticket` + `spent_review_escalation` are PR2 additions).
- No model or provider keys are managed by this spec — OpenCode owns its own configuration.

## Test

- [ ] With the flag unset, an orchestration run spawns only Claude executors and produces
      output identical to pre-feature behavior (offload invisible when off).
- [ ] With the flag set but `opencode` absent from PATH, preflight fails and every task
      falls back to the Claude executor, with a single logged fallback notice.
- [ ] An eligible mechanical task **with** a machine-check routes to `opencode run` in the
      ticket worktree; an otherwise-identical task **without** a machine-check routes to
      Claude.
- [ ] A forbidden agent/task (tech-lead, ic5, qa-gate, council judge/investigator, PM
      kickoff, release) is never routed to the local agent even with the flag set.
- [ ] A diff that fails Claude review twice escalates to the Claude executor on the second
      rejection (≤2 Claude-reviewed attempts), and the Claude output is what completes.
- [ ] The local agent cannot write outside the worktree, nor commit/push/tag, nor reach
      any network host beyond the model endpoint.
- [ ] An offloaded implementation that skips the TDD gate, exceeds LOC caps, or fails the
      `TaskCompleted` council gate is rejected exactly as Claude-authored work would be.
- [ ] Each offloaded task appends a `{saved_est, spent}` record to the metrics file.

## Validation

- [ ] Spec reviewed and promoted to ACTIVE
- [ ] SPEC-003 carries a forward-reference to this spec (via `/update-spec`) on its next revision
- [ ] Instrumentation confirms net-positive token savings on at least one real
      orchestration run before the eligibility set is widened

## Open Questions

- Retry cap **N is fixed at 2** for this version (aligned with SPEC-009's 2-attempt rule).
  Revisit only if instrumentation shows a different value pays off.
- **Backlog:** capability-tier routing (route by the user's declared local-model size).
- **Backlog:** orchestrator-decides-at-runtime routing (Claude classifies each task
  instead of static per-agent eligibility).
- **Backlog:** offloading the council/blind-review investigator fan-out (largest token
  burst, but judgment-heavy — revisit only after this version proves net-positive).
- **Backlog:** automatic kill-switch on a per-route reject-rate threshold.
- Whether to promote the wrapper into a standalone composable skill (`/local-do`) reusable
  by `/debug` and `/refactor`, vs keeping it wired only into `/orchestrate`.
- ~~Exact metrics file format and location under `.claude/`.~~ **Resolved:**
  `.claude/local-agent/metrics.jsonl`, JSONL, `jq`-guarded (see Instrumentation).
- ~~Liveness probe command.~~ **Resolved:** `opencode --version`.
- ~~Worktree source for the wrapper.~~ **Resolved:** caller passes `--worktree <path>`;
  wrapper does not call `worktree-lib.sh` (SPEC-016 subprocess-CLI separation).
- **Backlog (PR2):** OS-level leash enforcement (bubblewrap/seccomp fs-scope + egress
  allowlist) to replace PR1's best-effort `--dir` confinement.

## Version History

| Date | Change |
|------|--------|
| 2026-06-16 | Initial version (DRAFT) — opt-in OpenCode offload of mechanical/verifiable work; static per-agent routing; per-task machine-check gate; direct-write + Claude diff review; 2-attempt cap inheriting SPEC-009; sandboxed/allowlisted leash; token-savings instrumentation. Conflict-scanned against SPEC-002/003/009/010/013/016 (no blockers; SPEC-003 model-tier coupling documented; inherited disciplines encoded as MUSTs). |
| 2026-06-16 | Reconcile for CDV-19 PR1 (DRAFT). **Softened** the isolation MUST from OS-enforced sandbox/allowlist to a **best-effort `--dir` leash** + documented residual-risk note + forward-pointer to a PR2 OS-enforcement ticket. Pinned: env-var flag `LOCAL_AGENT=opencode` (exact match) with exit-2 fallback; invocation `opencode run --dir <worktree> "<brief>"` (flags verified on 1.17.4); caller-supplied machine-check via `bash -c "$CHECK"` (no `eval`); wrapper exit-code contract 0/1/2; metrics `.claude/local-agent/metrics.jsonl` (JSONL, `jq`-guarded) with stable schema (`saved_est_tokens` = measured-or-`null`, never `"unknown"`); liveness probe `opencode --version`; worktree passed as `--worktree <path>` (caller owns `worktree-lib.sh`, SPEC-016 separation). Added PR1/PR2 delivery split. Status stays DRAFT. |
| 2026-06-16 | Metrics-schema adjudication (CDV-19-1 review, DRAFT). **Fixed conceptual error**: prior text conflated `saved_est_tokens` (estimate of *Claude* tokens saved) with the measured local cost. Canonical PR1 record is now `{ ts, outcome, exit_code, saved_est_tokens, spent_tokens }`: `saved_est_tokens` = Claude-tokens-saved estimate = `null` in PR1 (orchestrator-owned, deferred to PR2); `spent_tokens` = measured local OpenCode cost (or `null`), explicitly NOT a Claude cost. Marked `ticket` and `spent_review_escalation` as PR2-only additions (the wrapper has no ticket id and review/escalation runs in `skills/orchestrate/`). Updated Configuration metrics line. Status stays DRAFT. |

## Cross-references

- **SPEC-002** — Plugin Infrastructure: sandbox/permissions baseline, config surface.
- **SPEC-003** — Agent Role System: ic4 Sonnet tier is the fallback executor (coupling documented above); TDD-gate and escalation disciplines inherited.
- **SPEC-009** — Ticket Workflow: task tagging, LOC caps, 2-attempt escalation rule, scope discipline.
- **SPEC-010** — Code Review & Release: diff review path (`diff-mode`); release work is non-offloadable.
- **SPEC-013** — Adversarial Council Tribunal: `TaskCompleted` quality gate; investigator fan-out offload deferred to backlog.
- **SPEC-016** — Worktree Isolation: local agent executes inside a `worktree-lib.sh`-managed worktree.
