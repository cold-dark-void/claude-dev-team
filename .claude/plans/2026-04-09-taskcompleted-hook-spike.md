# COUNCIL-001 T1 — TaskCompleted Hook Contract Spike

**Date:** 2026-04-09
**Investigator:** ic5
**Time spent:** ~15 minutes
**Status:** resolved

## Summary

Claude Code delivers the TaskCompleted event as a **JSON object on stdin** containing `task_id`, `task_subject`, `task_description`, `hook_event_name`, `session_id`, `transcript_path`, and `cwd`. `CLAUDE_TASK_ID` is **NOT** injected by Claude Code itself — only `CLAUDE_PROJECT_DIR` and `CLAUDE_CODE_ENTRYPOINT` are. Stdin is therefore the canonical task-id transport for Claude-Code-native TaskCompleted; orchestrator-exported `CLAUDE_TASK_ID` is an orthogonal channel used by SPEC-009 flows.

## Raw observations

- **cwd:** `/home/user/vibes/claude-dev-team` (worktree root, not `.claude/`)
- **argv:** empty (count=0). Hook command `bash .claude/hooks/task-completed.sh` receives no positional args.
- **Claude-injected env vars present when hook fires:**
  - `CLAUDE_CODE_ENTRYPOINT=cli`
  - `CLAUDE_PROJECT_DIR=/home/user/vibes/claude-dev-team`
  - `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (from `settings.json` `env:` block, not Claude itself)
- **`CLAUDE_TASK_ID` present by default:** **NO.** Not set unless orchestrator exports it.
- **No `TASK_*`, `HOOK_*`, `TOOL_*` env vars** set by Claude Code.
- **stdin payload present:** **YES** — single-line JSON, no trailing newline issues, delivered synchronously (captured by `timeout 1 cat`).
- **stdin payload shape (verbatim from probe):**
  ```json
  {
    "session_id": "00000000-0000-4000-8000-000000000001",
    "transcript_path": "/home/user/.claude/projects/-home-user-vibes-claude-dev-team/00000000-0000-4000-8000-000000000001.jsonl",
    "cwd": "/home/user/vibes/claude-dev-team",
    "hook_event_name": "TaskCompleted",
    "task_id": "17",
    "task_subject": "COUNCIL-001 T1 spike probe",
    "task_description": "Throwaway task used to trigger TaskCompleted hook for contract spike. Safe to delete."
  }
  ```
- **Notable absences from stdin payload:** no `metadata`, no `requires_council`, no `status`, no `blocks`/`blockedBy`, no `owner`. Claude Code exposes only the three task-core fields (`task_id`, `task_subject`, `task_description`) plus session context. Any council metadata MUST live in `.claude/tasks/<task_id>.json` — the payload alone is insufficient to decide gate applicability.
- `task_id` is a **string** (`"17"`, not `17`). Hook must not assume integer.

## Answers to the open questions

1. **Is stdin JSON the canonical task-metadata transport?**
   Yes for the task id. Stdin carries the authoritative `task_id` that Claude Code itself assigns. It does NOT carry council-gate metadata — `requires_council` still lives in `.claude/tasks/<task_id>.json` as SPEC-002 line 22 specifies.

2. **Is `CLAUDE_TASK_ID` injected by Claude Code or orchestrator-only?**
   **Orchestrator-only.** Claude Code does not set `CLAUDE_TASK_ID`. The env-var channel is entirely a SPEC-013 Phase 6 / SPEC-009 convention for orchestrated subagent flows. The hook MUST read the task id from stdin JSON first, and MAY prefer `CLAUDE_TASK_ID` as an override for orchestrated-subagent contexts where stdin isn't wired the same way.

3. **Which SPEC-002 MUSTs need adjustment?**
   - **Line 22** — reframe: task id SHOULD be resolved from stdin `task_id` first, with `CLAUDE_TASK_ID` as an orchestrator override. Current wording ("env var is authoritative") is wrong for Claude-Code-native flows.
   - **Line 27** — soften: "The hook MUST learn the completing task id from the `CLAUDE_TASK_ID` environment variable" is inverted. Rewrite to: "The hook MUST learn the task id from stdin JSON `task_id` when present, and MUST fall back to `CLAUDE_TASK_ID` when stdin is empty/unavailable; when both are set, `CLAUDE_TASK_ID` wins (orchestrator override)."
   - **Line 28** — promote MAY → MUST: stdin JSON is the primary transport, not a secondary source.
   - **Line 33** — "cannot gate without task id" fail case: trigger ONLY when BOTH stdin `task_id` is absent/empty AND `CLAUDE_TASK_ID` is unset. Currently only checks env var.
   - **Line 76 (Open Question)** — resolved. Stdin JSON IS delivered; spec should record the exact shape above.

## Implementation guidance for Task 10

Concrete bullets for the IC4 building the real `task-completed.sh`:

- **Task id resolution order:** (1) `CLAUDE_TASK_ID` env var if set and non-empty (orchestrator override); (2) parse stdin as JSON and read `.task_id`. Cache stdin in a variable — you only get one read.
- **Stdin read pattern:** `STDIN_JSON=$(timeout 1 cat 2>/dev/null || true)` — non-blocking, tolerates missing stdin (e.g. direct `bash` invocation during tests).
- **JSON parsing:** use `python3 -c` (already used in current hook for plugin JSON) — no `jq` dependency. Example:
  ```bash
  TASK_ID=$(printf '%s' "$STDIN_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin) if sys.stdin.read else {}; print(d.get("task_id",""))' 2>/dev/null)
  ```
  Actually simpler: read stdin once into `$STDIN_JSON`, then pipe that variable to python3.
- **Treat `task_id` as a string** — don't numeric-compare. Path lookups use it verbatim: `$MROOT/.claude/tasks/${TASK_ID}.json`.
- **`$MROOT` resolution** unchanged — `git rev-parse --git-common-dir` then `cd $(dirname ...)`. Note: `CLAUDE_PROJECT_DIR` IS set and matches the worktree root in our probe, but worktree-aware MROOT still needs the git-common-dir dance because `CLAUDE_PROJECT_DIR` points at the worktree, not the shared common dir.
- **cwd when hook fires:** worktree root, not `.claude/`. Relative paths like `.claude/tasks/...` work, but always compose against `$MROOT` for worktree safety.
- **Missing stdin path:** if stdin is empty AND `CLAUDE_TASK_ID` unset, AND no `requires_council` context can be determined, treat as "legacy / non-council-gated task" and silent no-op pass (consistent with SPEC-002 line 24).
- **Fail-loud path:** only when `.claude/tasks/<task_id>.json` exists with `requires_council: true` AND we cannot resolve a qualifying verdict.
- **Keep existing plugin JSON validation** — the real hook still needs those 15 lines of plugin/marketplace.json checks. Compose: validate plugin JSONs first, then council gate.
- **Don't trust stdin to be valid JSON** — wrap the python parse in try/except; on parse failure with `CLAUDE_TASK_ID` unset, silent-pass (don't crash the hook on malformed input).
- **Tests (Task 15 smoke):** three scenarios worth covering: (a) stdin-only (Claude-Code-native), (b) env-var-only (orchestrated subagent with no stdin), (c) both set (verify env wins).

## Blockers / unknowns

- **None for the core contract.** Open questions that didn't need resolution for Task 10:
  - Does Claude Code retry on non-zero exit? (Not blocking — the exit-2 semantics work regardless.)
  - Does stdin close after the single JSON object, or can multiple events stream? (Probe saw single object; assume single-shot per hook invocation.)
  - Behavior in worktree other than main? (Not tested; `CLAUDE_PROJECT_DIR` should point at the active worktree, and the git-common-dir resolution handles the shared root.)
- Hook logs to `/tmp/council-t1-hook-probe.log` were cleaned up post-run.
