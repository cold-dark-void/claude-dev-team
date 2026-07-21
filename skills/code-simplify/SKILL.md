---
name: code-simplify
description: |
    Behavior-preserving polish on recently modified code — clarity only, no
    logic or API changes. Used by /orchestrate after Tech Lead approve, before
    QA. Zero external deps (in-plugin; not Anthropic's marketplace plugin).
---

# Code Simplify

Optional post-implement pass that cleans **recently modified** files without
changing observable behavior. Inspired by Anthropic's code-simplifier agent;
this is a **MIT-owned protocol** inside dev-team — no marketplace install required.

## When to run

| Caller | When |
|--------|------|
| `/orchestrate` | After **all** IC tasks have Tech Lead **APPROVE** (Step 9), **before** Step 10 QA |
| Manual | User asks to simplify recent work; or after a large IC implement outside orchestrate |

Skip when:
- Diff is docs/config-only with no runtime code
- User set `CODE_SIMPLIFY=0` in the environment for this session
- Worktree has no uncommitted/committed changes since branch base (empty diff)

Fail-open: if the simplify agent errors or times out, print one line and continue
to QA — never block ship on polish.

## Hard constraints (agent MUST)

1. **No behavior change** — same inputs → same outputs; no new features; no
   deleted edge-case handling; no API/schema renames
2. **Recently modified only** — files in `git diff <base>...HEAD` (and unstaged
   worktree changes if any). Do not "improve" unrelated modules
3. **Match project style** — AGENTS.md, existing patterns, domain glossary terms
4. **Tests stay green** — if project has a quick test command, prefer running it
   after edits; if tests fail, **revert** the simplify edits and report failure
5. **No new dependencies**

## Scope discovery

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Prefer merge-base with main/master; fall back to upstream or empty-tree
BASE=$(git -C "$WTROOT" merge-base HEAD origin/main 2>/dev/null \
  || git -C "$WTROOT" merge-base HEAD origin/master 2>/dev/null \
  || git -C "$WTROOT" merge-base HEAD main 2>/dev/null \
  || git -C "$WTROOT" merge-base HEAD master 2>/dev/null \
  || echo "")
if [ -n "$BASE" ]; then
  git -C "$WTROOT" diff --name-only "$BASE"...HEAD
  git -C "$WTROOT" diff --name-only
else
  git -C "$WTROOT" diff --name-only HEAD
  git -C "$WTROOT" status --short
fi
```

Filter to source files (language-appropriate). Cap at ~25 files; if larger, only
the files touched by the latest implement commits for the ticket.

## Spawn prompt (orchestrator template)

```
You are running a behavior-preserving code-simplify pass (dev-team skill
code-simplify). Output mode: terse.

Worktree: <WT_PATH>
Ticket: <ISSUE-ID>
Files in scope (only these):
<file list>

Rules:
1. Clarity/maintainability only — flatten nesting, remove duplication you
   introduced, clarify names, drop dead code that is clearly unreachable from
   THIS change. No behavior, API, or schema changes.
2. Do not expand scope beyond the file list.
3. Prefer surgical edits. If unsure whether a change preserves behavior, skip it.
4. Match AGENTS.md and existing style. Prefer domain-glossary terms if CONTEXT.md exists.
5. When done, report: files touched | skipped (with reason) | tests run (or N/A).

Return your report as this agent's final message — do NOT SendMessage the orchestrator.
```

Spawn as a short-lived agent (ic4 is fine; not tech-lead/qa). One pass only —
no multi-round debate.

## Output contract

Print to the orchestrator log:

```
Code-simplify: <done | skipped | failed-open>
  files: <N touched>
  notes: <one line>
```

On `failed-open` or `skipped`, proceed to QA unchanged.
