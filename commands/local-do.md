---
name: local-do
description: Offload one mechanical, machine-verifiable task to the local model, review the result, and fall back to Claude if the local agent is unavailable or fails.
agent: build
---

# Local Do

Runs the local-agent offload loop on a single task supplied inline. Drives
`skills/local-agent/run.sh` (the PR1 leaf primitive), reviews the worktree
diff on success, and escalates to the invoking Claude when either attempt cap
is hit. Intended for standalone, ad-hoc mechanical tasks; orchestrated
ticket-based work should go through the PR2 orchestrator instead.

**Relationship to /local-agent:** `/local-agent` is the internal engine
(`skills/local-agent/run.sh`) that this command drives. Do NOT invoke
`run.sh` directly for user-facing work; use `/local-do`.

**Future consumers:** `/debug` and `/refactor` MAY call `/local-do` for
their mechanical execution phases. Not wired in v1.

## Usage

```
/local-do <brief> --check <shell-expr> [--worktree <path>]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `<brief>` | Yes | Self-contained task description; becomes the local agent's sole context. |
| `--check <shell-expr>` | Yes | Deterministic machine-check — a shell expression evaluated via `bash -c` after the local agent finishes. Exit 0 = pass; non-zero = fail. |
| `--worktree <path>` | No | Target git worktree. Defaults to the current working directory. Must be an existing git worktree (not created by this command). |

`<brief>` and `--check` are both required. A missing or empty value for either
is a usage error (exit 64 framing).

## Counters and attempt caps

Two independent counters govern the retry/review loop (inheriting SPEC-009,
matching the 2-attempt escalation contract established in PR2 / CDV-20):

- **LOCAL_ATTEMPTS** — counts calls to `run.sh` triggered by a machine-check
  failure (exit code 1). Cap: **2**.
- **REVIEW_ATTEMPTS** — counts calls to `run.sh` triggered by the invoking
  Claude requesting changes during diff review. Cap: **2**.

Hitting either cap triggers escalation (Step 5). The two caps are
independent: a fallback (exit 2) consumes neither counter.

For the authoritative exit-code contract (`0`/`1`/`2`/`64`) see
`skills/local-agent/SKILL.md`. Engine internals (bwrap, opencode invocation,
liveness probe, metrics) are owned by `run.sh` and are not restated here.

**Metrics:** `run.sh` logs its own PR1 JSONL record per terminal path. This
command does NOT call `emit-orch-metric.sh` — there is no ticket or
`saved_est_tokens` estimate available in standalone mode. On **cap
escalation only** (LOCAL_ATTEMPTS or REVIEW_ATTEMPTS hit), emit one
SPEC-026 outcomes-ledger row via `skills/metrics/emit-outcome.sh`
(agent=`local`, outcome=`escalated`). Do **not** write the SPEC-019
local-agent metrics file from this path.

---

## Workflow

### Step 1: Parse and validate arguments

Parse `<brief>`, `--check`, and optional `--worktree` from the user's
invocation.

- If `<brief>` is absent or empty: print usage and stop (exit 64 framing).
- If `--check` is absent or empty: print usage and stop (exit 64 framing).
- Resolve `--worktree`: if not supplied, default to the current working
  directory. Validate that it is an existing git worktree:

```bash
# Resolve and validate the target worktree
WT="${WORKTREE_ARG:-$(pwd)}"

if [ ! -d "$WT" ]; then
  echo "error: --worktree is not a directory: $WT" >&2
  exit 64
fi

# Confirm it is a git worktree (git rev-parse must succeed inside it)
if ! git -C "$WT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: --worktree is not a git worktree: $WT" >&2
  exit 64
fi
```

Do NOT create the worktree. If the path does not resolve to an existing git
worktree, stop with a clear error.

### Step 2: Resolve run.sh

Locate `skills/local-agent/run.sh` via `plugin-dir.sh` using the standard
PDH resolution pattern:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
RUN_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/local-agent/run.sh)

if [ ! -f "$RUN_SH" ]; then
  echo "error: skills/local-agent/run.sh not found in the installed plugin cache" >&2
  exit 1
fi
```

### Step 3: Invoke run.sh and branch on exit code

Initialize counters:

```bash
LOCAL_ATTEMPTS=0
REVIEW_ATTEMPTS=0
CURRENT_BRIEF="$BRIEF"
```

Call `run.sh` with the resolved worktree, brief, and check expression:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
RUN_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/local-agent/run.sh)
bash "$RUN_SH" --worktree "$WT" --brief "$CURRENT_BRIEF" --check "$CHECK"  # lint-ok: C1
RC=$?
```

Branch on `$RC`:

- **Exit 2 (fallback):** `run.sh` printed a one-line notice to stderr. The
  local agent is unavailable (flag unset, opencode absent, or liveness probe
  failed). Proceed directly to **Step 5 (Escalate)** — the invoking Claude
  does the task itself without consuming either attempt counter. Report that
  the local agent was unavailable.

- **Exit 1 (machine-check failure):** Increment `LOCAL_ATTEMPTS`. If
  `LOCAL_ATTEMPTS >= 2`, proceed to **Step 5 (Escalate)**. Otherwise, fold
  the failure into the brief and retry:

  > "Previous attempt failed the machine-check (`$CHECK`). Review the diff
  > left in the worktree, correct the issue, and re-apply the task:
  > `$CURRENT_BRIEF`"

  Set `CURRENT_BRIEF` to this updated brief, then return to the top of
  Step 3.

- **Exit 0 (success):** The machine-check passed. Proceed to **Step 4
  (Review)**.

- **Exit 64 (usage error):** This indicates a bug in the invoking Claude's
  argument construction. Print the error and stop; do not retry.

### Step 4: Review the diff

The invoking Claude reviews the worktree diff directly — a lightweight
PR-style review (not a council/diff-mode run). Read the diff:

```bash
git -C "$WT" diff HEAD  # lint-ok: C1
```

Also read any staged changes:

```bash
git -C "$WT" diff --cached  # lint-ok: C1
```

Evaluate whether the diff correctly implements the brief and passes a
reasonable quality bar (no obvious regressions, no unrelated changes, no
leftover debug artifacts).

**APPROVE:** The diff looks correct. Report a diff summary and the check
result. Done.

**REQUEST CHANGES:** Fold the review feedback into the brief as a correction
note:

> "Review feedback: <your specific observations>. Revise and re-apply the
> task: `$CURRENT_BRIEF`"

Increment `REVIEW_ATTEMPTS`. If `REVIEW_ATTEMPTS >= 2`, proceed to **Step 5
(Escalate)**. Otherwise set `CURRENT_BRIEF` to the updated brief and return
to **Step 3** (call `run.sh` again).

### Step 5: Escalate

Either the fallback path was taken (exit 2), or an attempt cap was hit
(`LOCAL_ATTEMPTS >= 2` or `REVIEW_ATTEMPTS >= 2`).

#### 5a. Outcomes-ledger emit (cap escalation only)

When **and only when** a cap was hit (`LOCAL_ATTEMPTS >= 2` or
`REVIEW_ATTEMPTS >= 2`) — not on exit-2 unavailable fallback — append one
SPEC-026 outcomes row. Fail-open: any resolve/emit failure is ignored.

Standalone `/local-do` has no ticket/task_id/task_class; use literal `null`.
If this command is driven from an orchestrated local offload where
ticket/task_id (and optionally task_class) are known, pass those instead of
`null` for the first two (and fourth) args.

```bash
# Re-resolve PDH (each bash fence is a fresh shell)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
EMIT=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/emit-outcome.sh 2>/dev/null) || true
# ticket task_id agent task_class size outcome review_cycles qa_bounces council_overturns
if [ -n "${EMIT:-}" ] && [ -f "$EMIT" ]; then
  bash "$EMIT" null null local null null escalated null null null 2>/dev/null || true
fi
```

Do **not** call `emit-orch-metric.sh` and do **not** write
`.claude/local-agent/metrics.jsonl` from this path (SPEC-019 ownership stays
with `run.sh` / orchestrate).

#### 5b. Claude finishes the task

The invoking Claude finishes the task itself:

1. Read the current worktree diff as partial context (whatever `run.sh` left
   in place, if anything):

   ```bash
   git -C "$WT" diff HEAD  # lint-ok: C1
   ```

2. Apply any corrections or complete the remaining work, incorporating:
   - The original brief.
   - The check expression — verify the check passes before reporting done.
   - Any partial diff from the local agent as a starting point.
   - Any review feedback accumulated across prior rounds.

3. Report what was done, note that escalation was triggered and why (cap hit
   or local agent unavailable), and confirm the check result.

---

## Error handling summary

| Condition | Action |
|-----------|--------|
| Missing `<brief>` or `--check` | Usage error, stop (exit 64 framing) |
| `--worktree` path not a git worktree | Usage error, stop (exit 64 framing) |
| `run.sh` not found | Print error, stop (exit 1) |
| `run.sh` exits 2 (fallback) | Escalate immediately (Step 5) |
| `run.sh` exits 1 twice (LOCAL_ATTEMPTS cap) | Escalate (Step 5) |
| Review rejects twice (REVIEW_ATTEMPTS cap) | Escalate (Step 5) |
| `run.sh` exits 64 | Print error, stop — do not retry |
