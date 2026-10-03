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
| Manual | No orchestrate worktree: do not edit. Route the user to `/refactor`. |

A manual invocation that has no `/orchestrate` worktree routes to `/refactor`.
Do not simplify in place. Runs under `/orchestrate` already have a worktree and
do not use the refactor escalation gate.

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
4. **Tests stay green** — if the project has a quick test command, prefer running it
   after edits. If tests fail, revert with `git reset --hard "$PRE_SIMPLIFY_SHA"`
   (the checkpoint committed before the spawn). Do not `git checkout -- <file>`:
   that also deletes uncommitted IC work that was never checkpointed.
5. **No new dependencies**

## Scope discovery

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
CHANGED=$(bash "$PDH/skills/plugin-dir.sh" file skills/lib/changed-set.sh)
bash "$CHANGED" paths
```

Commit that set before the spawn, and record the checkpoint:

```bash
git add --pathspec-from-file=- <<'EOF'
<paste the changed-set paths>
EOF
git commit -m "chore: pre-simplify checkpoint"
PRE_SIMPLIFY_SHA=$(git rev-parse HEAD)
printf '%s\n' "$PRE_SIMPLIFY_SHA"
```

Filter to source files (language-appropriate). Cap at ~25 files; if larger, only
the files touched by the latest implement commits for the ticket.

## Spawn prompt (orchestrator template)

Before spawning @ic4:
```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" ic4)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort ic4)
printf '%s\n' "$EFFORT"
```
Surface resolver stderr to the user. Do not swallow.
Bash stdout = model string; empty → omit model. MUST NOT pass "".
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent
`effort` param; empty → omit (MUST NOT pass `""`).
If spawn fails attributed to the model param (invalid/unknown/unsupported
model): retry once with model omitted; warn
`model-map: host rejected model '<string>' for ic4; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported
effort): retry once omitting effort; warn
`model-map: host rejected effort '<token>' for ic4; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not
combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

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
