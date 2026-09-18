---
name: council
description: |
  Adversarial council tribunal — reality-checks claims with material evidence.
  Spawns blind investigators, prosecutor, devil's advocate, and a tool-less
  judge. Issues per-claim verdicts with confidence scores. Use mid-session
  to audit a shaky claim, after a debug session to verify "all green", or
  on a plan file to find unverified assumptions. Shares an engine with
  /review-and-commit (diff-mode preset).
argument-hint: '"<claim>" | --session [--last N] | --diff | --plan <path> | --from-retro <id> | --blind [--teams N] [--lenses L1,L2] [--target <path>] [--task-id <id>] [--workflow] [--external[=codex|gemini]] [--council-tier=<light|full>] [--why]'
agent: build
---

# /council

Thin host over `skills/council/SKILL.md` (SPEC-013). This file parses the
slash surface, resolves the skill, and Reads it. Protocol is not restated
here.

```
Usage: /council "<claim>" | --session [--last N] | --diff | --plan <path> | --from-retro <id> | --blind [--teams N] [--lenses L1,L2,...] [--target <path>]
       [--task-id <id>] [--workflow] [--external[=codex|gemini]] [--council-tier=<light|full>] [--why]

Scope flags are mutually exclusive. --teams/--lenses/--target require --blind.
--council-tier accepts only light or full (never skip — short-circuit before invoking /council).
Available lenses: security, contributor, spec, architecture, logic
```

Exactly one of `"<claim>"`, `--session`, `--diff`, `--plan`, `--from-retro`,
or `--blind` must be supplied. Zero or more than one → print usage, exit
non-zero. `--teams` / `--lenses` / `--target` require `--blind`.
`--workflow`, `--external`, `--why`, `--council-tier`, `--task-id` are
orthogonal; `--workflow` MUST NOT apply to `--blind`. There is **no**
`--no-council` flag.

| Arg / flag | Default | Notes |
|------------|---------|-------|
| `"<claim>"` | — | scope=`claim`; preset `generic` |
| `--session [--last N]` | — | scope=`session`; preset `generic` |
| `--diff` | — | scope=`diff`; preset `diff-mode` |
| `--plan <path>` | — | scope=`plan`; preset `generic`; missing path → exit 2 |
| `--from-retro <id>` | — | scope=`from-retro`; preset `generic`; missing anchor → exit 2 |
| `--blind` | — | distinct path (no tribunal Phases 1–5, no `engine.sh` preflight) |
| `--teams N` / `--lenses` / `--target` | 3 / `security,contributor,spec` / full project | blind parity only |
| `--task-id <id>` | `CLAUDE_TASK_ID` then unbound | not applied to `--blind` index rows |
| `--workflow` | off (`COUNCIL_WORKFLOW=1` equiv) | tribunal only; probe-fail → Task path |
| `--external[=codex\|gemini]` | off | additive slot; helper `external-reviewer.sh`; never hard-fail on miss |
| `--council-tier=<light\|full>` | omit → `full` | DRI passthrough to `--tier`. `skip` is **not** legal here |
| `--why` | off | print `why_detail` after summary (flavors, Phase 3, claim budget, preset source) |
| `--preset <name>` | inferred | explicit preset selector |

**Hard fails:** unknown lens; missing `--target` path; `--teams` not a
positive integer; `--council-tier` not in `{light, full}` (includes `skip`).

**Preset inference:** `--diff` → `diff-mode`; everything else → `generic`.
Explicit `--preset` wins.

**Phase 2 flavor append:** a caller MAY append flavor names to `plan.flavors`
after preflight; investigator.md output schema always wins over a flavor's
`output_shape_constraint`.

**Sequence (skill-owned):**

```
parse → [--blind → Blind-review | preflight → Workflow-or-Task Phases 1–5 → finalize]
```

**Hard walls (one-liner):** this host does not auto-grade (skill § 1.5.1);
Workflow is `full`-only — `council: council_tier=light unsupported on the Workflow path; falling back to engine.sh`;
Phase 3 is live (`topic-classifier`, `max_specialists_per_run: 1`,
`confidence_threshold: 0.75`); cache protocol `plan.cache_dir` /
`{{CACHE_DIR}}` / `council-cache`; finalize `--tokens-file`; model map
`resolve-model.sh` then `resolve-model.sh --effort` — empty → omit, host-reject
→ retry once (`host rejected` / `host rejected effort`).

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/council/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded council protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it end-to-end with the user arguments unchanged.

- Parse exclusivity already applied above; pass the surviving scope through.
- Tribunal scopes: translate to `engine.sh preflight --scope <name>` per the
  skill Invocation Contract. `--blind` jumps to skill § Blind-review path.
- Do not restate engine protocol here.

## Notes

- Protocol body: `skills/council/SKILL.md` (`user-invocable: false`)
- Spec: `specs/core/SPEC-013-adversarial-council-tribunal.md`
- Engine: `skills/council/engine.sh` · Workflow: `skills/council/workflow.js`
