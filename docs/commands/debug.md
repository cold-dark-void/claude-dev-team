# /debug

Phase-gated bug handler (SPEC-014) plus a ticket pipeline (SPEC-028). Full
investigation → root-cause → fix → verify enforces root-cause-before-edit: no
file is touched until the root cause is written to the session. Hard gates also
require a failing test before any fix, a holistic callsite scan after it, and a
self-calibration checklist before any "done" claim. `ticket` mode runs
premise→implement→adversarial refuters for a **known** bug ticket (never commits
or calls `/release`). Prefer `/debug ticket` over the legacy `/fix-ticket`
command (deprecated — removed at v1.0.0).

## Usage

```
/debug <description>
/debug patch <description>
/debug arch <description>
/debug ticket <ticket-id> "<bug/premise>" [--fix "…"] [--agent ic4|ic5] [--lenses a,b] [--worktree <path>]
```

If `<description>` is empty (non-ticket modes), the skill asks `What is the bug or issue to debug?` and waits.
Missing ticket-id or premise → usage error, no agent spawn.

## Subcommands

| Form | Mode | Pipeline |
|------|------|----------|
| `/debug <description>` | `full` (default) | Complete pipeline: reproduce → root cause → spec alignment → scope decision → failing test → fix → callsite grep → self-calibration → done. |
| `/debug patch <description>` | `patch` (fast path) | Root cause → failing test → fix → validate. Skips spec alignment, callsite grep, escalation, and refactor handling. Aborts to full mode if the bug needs a refactor or cross-subsystem change. |
| `/debug arch <description>` | `arch` (design-first) | Reproduce → root cause, then mandatory `/kickoff` handoff. Never writes a test or fix inline — the root cause investigation is the deliverable. |
| `/debug ticket …` | `ticket` | Premise → implement → N qa refuters → report. Worktree-isolated; no commit/version/release. |

**Parser rule:** if the first token is exactly `patch`, `arch`, or `ticket` (case-sensitive), it selects the mode and the remainder becomes the args/description. Otherwise the mode is `full` and the whole argument is the description. A description that genuinely starts with those words is misread as a mode selector — rephrase to avoid the ambiguity.

## Gates

Every mode shares the same non-negotiable gates:

- **Root-cause-before-edit** — no file may be edited, created, or deleted until a written root cause statement appears in the session. The statement must identify (a) what specifically fails, (b) why it fails, and (c) the originating layer — not the symptom layer.
- **Scope decision (full mode)** — `targeted-patch`, `refactor-first`, or `escalate-to-kickoff` must be stated in writing before any fix code. Applying the same fix in more than one place always triggers the refactor path.
- **Failing-test-first** — a regression test capturing the bug must exist and be confirmed failing for the right reason before the fix is written. If no test suite exists, the skill warns and substitutes a reproduction scenario document.
- **Holistic callsite scan (full mode)** — after the fix, grep the codebase for the same root cause pattern; every hit is addressed or documented. More than 10 hits escalates to `/kickoff`.
- **Self-calibration checklist** — emitted verbatim before any completion language. If any item is unchecked, no "done / fixed / resolved / complete" language is allowed.

## Examples

**Full investigation:**
```
/debug websocket connection drops the thinking preference on reconnect
```
Loads project context, reproduces the bug, then gates on a root cause statement:
```
Root cause: HandleConnect reads the saved `thinking` preference before
SetThinkingEnabled runs, so the request uses the stale default (true). The
defect originates in handler init order in ws.go:HandleConnect, not in the
preference storage layer.

Scope: targeted-patch
```

**Fast path for an isolated bug:**
```
/debug patch off-by-one in pagination offset calc
```
Skips spec alignment, escalation, and the callsite scan — runs root cause → failing test → fix → validate only.

**Design-first, hands off to planning:**
```
/debug arch retry storm when the upstream queue saturates
```
Stops after the root cause and emits the `/kickoff` handoff:
```
ROOT CAUSE: <written statement>
AFFECTED FILES:
  - internal/queue/dispatcher.go
PROPOSED APPROACH: <2-3 sentences>
WHY INLINE REJECTED: arch mode — design decision required
```

**Known bug ticket (premise → implement → refuters):**
```
/debug ticket CDV-42 "off-by-one in pagination offset" --fix "clamp offset to >= 0"
```
Verifies the bug still exists, applies the smallest fix in a SPEC-016 worktree,
spawns parallel qa refuters, writes a report. Caller owns commit/release.

**Self-calibration before completion (full mode):**
```
Self-calibration checklist:
  [✓] Root cause statement written before any file was edited
  [✓] Failing test existed and was confirmed failing before fix
  [✓] Full test suite passes
  [✓] Callsite grep completed — all hits addressed or documented
  [✓] Refactor committed separately before fix (✓ n/a — targeted-patch)
  [✓] Manual verification completed (✓ n/a — reproducible)
```
Only when every item is `✓` does the skill emit a completion summary and suggest `/wrap-ticket <TICKET-ID>`.

## See Also

- [`/refactor`](./refactor.md) — design-first restructuring; `/debug` hands off to `/refactor inline` when scope is `refactor-first`
- [`/kickoff`](./kickoff.md) — planning handoff target for `arch` mode and `escalate-to-kickoff` scope
- [`/wrap-ticket`](./wrap-ticket.md) — close out after the fix PR is merged
- [`/fix-ticket`](./fix-ticket.md) — deprecated stub; use `/debug ticket`
- Protocol: `skills/debug/SKILL.md`; ticket contract: SPEC-028
