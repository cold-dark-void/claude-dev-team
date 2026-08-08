---
name: bug-hunt
description: >
  Unknown-defect discovery: scoped multi-perspective discover → continuous
  refute/confirm → findings plan + proceed-gated backlog materialize →
  severity-band phase handoff emit-only (stages 1–4). Usage:
  /bug-hunt [path] [--severity-floor …] [--proceed]
  | /bug-hunt materialize <path> [--severity-floor …] [--proceed]
  | /bug-hunt handoff <plan-path> [--start-phase <n>]
argument-hint: '[path | materialize <path> | handoff <plan-path>] [--severity-floor critical|warning|nitpick] [--proceed] [--start-phase N]'
---

# /bug-hunt

Thin host over `skills/bug-hunt/SKILL.md` (SPEC-034; stages **1–4**). Protocol
owns parse → S1→S2→REPORT→S3→S4; this file only resolves the skill and passes
args through.

```
# Continuous (discover → refute → report → plan → optional materialize → phase handoff):
/bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed] [--start-phase <n>]

# Resume materialize (fresh session or re-run):
/bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]

# Resume phase handoff (post-S3 plan; emit-only):
/bug-hunt handoff <plan-path> [--start-phase <n>]
```

| Arg / form | Default | Notes |
|------------|---------|-------|
| `path` (continuous) | project root | Scope of discover; non-existent / unreadable / out-of-root → loud fail (exit 64) |
| `materialize <path>` | — | Resume entry: `.json` preferred, `.md` report, or existing `-plan.md` |
| `handoff <plan-path>` | — | Resume S4: path ending in `-plan.md` (or sibling plan); missing/unreadable → exit 64 |
| `--severity-floor` | `nitpick` (continuous); artifact then `nitpick` (resume) | Re-applied at S3 filter; invalid → exit 64; ignored for S4 banding |
| `--proceed` | off | Satisfies M8 materialize lock (no interactive token) |
| `--start-phase <n>` | off | Satisfies M9 for phase `n` (flag or typed `start-phase-<n>`); arms print-only |

**Sequence (continuous, skill-owned):**

```
S0 parse → S1 discover → S2 refute → REPORT → S3 plan [→ proceed → backlog]
  → S4 phase-plan + handoff stubs [→ start-phase → print route hint]
```

Narrow-path smoke shape: `/bug-hunt <existing-subdir> [--severity-floor …]` yields
report + `-plan.md` + ≥0 backlog (only with proceed) + phase handoff stubs —
**no** product fixes, **no** engine invoke.

**Shipped (CDT-136/C2 + CDT-138/C3 + CDT-139/C4):** S1 discover + S2 refute/confirm → report → S3 findings plan + proceed-gated bh-quality backlog materialize → S4 severity-band phase-plan + handoff templates (emit-only).

**Hard walls (one-liner):** no backlog materialize without explicit proceed (`--proceed` or typed `proceed`); S4 is **emit-only** — MUST NOT invoke `/orchestrate`/`/epic`, spawn fix ICs, or edit product code to fix; no phase arm without M9 (`--start-phase <n>` or typed `start-phase-<n>`); no re-S1/S2 on materialize resume; no re-S1–S3 invent on handoff resume; no commit/version-bump/release; on refuter spawn failure use CDV-199 marker `self-verified — refuters unavailable` (orchestrator only).

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/bug-hunt/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded bug-hunt protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it end-to-end with the user arguments unchanged.

- Continuous parse, `materialize <path>` resume, `handoff <plan-path>` resume, S0–S4
  pipeline, M8 proceed lock, M9 start-phase lock, and phase-done live in the skill —
  do not restate protocol here.
- Stage 4 is emit-only (templates + `invocation_hint` print); do not invoke
  `/orchestrate` or `/epic` from this command.
- Plan write before proceed is allowed; backlog create only after proceed (skill S3d→S3e).
- Phase templates write before arm is allowed; print invocation only after M9 lock (skill S4e→S4f).

## Notes

- Protocol body: `skills/bug-hunt/SKILL.md`
- Spec: `specs/core/SPEC-034-bug-hunt-workflow.md`
- Compose (cite-not-fork): S1/S2 → `skills/council/SKILL.md` § Blind-review + investigator;
  S3 → `skills/backlog/SKILL.md` § Programmatic write-back;
  S4 → templates `phase-plan.md` + `handoff-phase.md` (print-only route hints)
