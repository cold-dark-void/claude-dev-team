---
name: fix-ticket
description: >
  Internal protocol for /debug ticket — premise→implement→refuters pipeline
  (SPEC-028). Not a user entry; invoke via /debug ticket.
---

# fix-ticket (backend for `/debug ticket`)

> **Entry:** `/debug ticket <ticket-id> "<bug/premise>" […]`.
> This file is the skill-delegate backend for ticket mode — not a primary
> slash command. The old `/fix-ticket` command was removed at v1.1; protocol
> body + `prompts/` + `templates/` are permanent (v1.1 contract: protocol-retained
> backends; host is `skills/debug/SKILL.md` ticket mode).

Protocol for `/debug ticket` (SPEC-028). Orchestrator-driven Task-spawn pipeline:

**premise verify (ic5) → implement in worktree (ic4/ic5) → N adversarial refuters (qa) → orchestrator review + report**

Markdown Task path is authoritative. `workflow.js` is an optional non-invoked
reference asset (args-as-JSON-string guard for Workflow authoring conventions).

Governing spec: `specs/core/SPEC-028-fix-ticket-workflow.md`.

---

## Arguments

| Arg / flag | Required | Default | Description |
|------------|----------|---------|-------------|
| `<ticket-id>` | Yes | — | Ticket id (e.g. `CDV-42`, `AUDIT-P0.8`) |
| `"<bug/premise>"` | Yes | — | Documented bug description |
| `--fix "<instructions>"` | No | same as premise / empty | Fix instructions for implementer |
| `--agent ic4\|ic5` | No | `ic4` | Implementer agent |
| `--lenses a,b` | No | `correctness,completeness` | Comma-separated refute lenses |
| `--worktree <path>` | No | `worktree-lib.sh ensure <ticket-id>` | Existing worktree path |

Missing ticket-id or premise → usage error, no spawn.

```
Usage: /debug ticket <ticket-id> "<bug/premise>" [--fix "<instructions>"] [--agent ic4|ic5] [--lenses a,b] [--worktree <path>]
```

---

## Invariants (non-negotiable)

- **No version files** — never edit `.claude-plugin/plugin.json`, `marketplace.json`, or README version/changelog.
- **No commit** — never `git commit` / `git add` / `git checkout` / `git reset` in the pipeline.
- **No git checkout in refuters** — bite-test restore only via `cp` backup or sed-reverse.
- **CDV-199 marker** — on unusable refuter spawn, exact string `self-verified — refuters unavailable`; actor is always orchestrator. Protocol home: `skills/council/SKILL.md` § Spawn-failure degradation.
- **Caller owns release** — draft changelog bullet only; no `/release`.
- **Output mode: terse** on every Task spawn.
- **Worktree under `$MROOT/.worktrees/<slug>`** when created by this skill (SPEC-016).

---

## Step 0: Resolve roots + PDH

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/fix-ticket/SKILL.md)
```

Load templates from `$SKILL_DIR/prompts/{premise,implement,refute}.md` and
`$SKILL_DIR/templates/report.md`.

---

## Step 1: Parse args

Parse `$ARGUMENTS` (or equivalent user text):

1. First positional token → `TICKET`
2. Next quoted string (or remaining non-flag tokens until a `--` flag) → `BUG`
3. Flags: `--fix`, `--agent`, `--lenses`, `--worktree`

Validate:

```bash
# After parse into shell vars (orchestrator may hold vars in session; re-check):
if [ -z "${TICKET:-}" ] || [ -z "${BUG:-}" ]; then
  echo "Usage: /debug ticket <ticket-id> \"<bug/premise>\" [--fix \"...\"] [--agent ic4|ic5] [--lenses a,b] [--worktree <path>]" >&2
  exit 64
fi
AGENT="${AGENT:-ic4}"
case "$AGENT" in ic4|ic5) ;; *) echo "error: --agent must be ic4 or ic5" >&2; exit 64 ;; esac
FIX="${FIX:-}"
LENSES="${LENSES:-correctness,completeness}"
```

If the orchestrator parses in prose (not bash), apply the same rules and stop
with the usage line on missing required fields.

---

## Step 2: Ensure worktree

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
# WORKTREE from --worktree if set; else ensure:
if [ -z "${WORKTREE:-}" ]; then
  WORKTREE=$(bash "$WT_LIB" ensure "$TICKET") || {
    echo "error: worktree-lib.sh ensure failed for $TICKET" >&2
    exit 1
  }
fi
# Reject paths outside $MROOT/.worktrees/ when skill-created; if user passed
# --worktree, require it exists and is a git worktree.
[ -d "$WORKTREE" ] || { echo "error: worktree not found: $WORKTREE" >&2; exit 1; }
```

---

## Step 3: Verify-premise (ic5, read-only)

1. Read `prompts/premise.md`; substitute `{{TICKET}}`, `{{WORKTREE}}`, `{{BUG}}`.
2. Spawn Task: agent `dev-team:ic5` (or Explore-capable), **read-only**.
   Include `Output mode: terse`. Resolve the agent actually spawned
   (`ic5`; named fallback `ic5`→`ic4` resolves `ic4`). Unnamed /
   `general-purpose` / Explore: omit the fence.

Before spawning @ic5:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" ic5)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort ic5)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for ic5; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for ic5; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

3. Expect structured return per premise schema (`holds`, `evidence`, …).

**Gate:** if `holds=false` → go to Step 7 with `premise_holds=false`, empty
impl/verdicts, `all_hold=false`, `verification_mode=full`. Do **not** implement
or refute. Print clear stop: `Premise does not hold — stopping (no implement).`

---

## Step 4: Implement (ic4/ic5)

1. Read `prompts/implement.md`; substitute placeholders including
   `{{PREMISE_JSON}}` (full premise object) and `{{AGENT}}`, `{{FIX}}`.
2. Spawn Task: agent `dev-team:{{AGENT}}`. Resolve the agent actually
   spawned (`ic4` or `ic5` from `--agent`). Unnamed / `general-purpose` /
   Explore: omit the fence.

Before spawning @<agent> (`ic4` or `ic5` from `--agent`):
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
# Re-resolve in this fence (SPEC-021 C1) — Step 1's AGENT does not carry across blocks.
AGENT="${AGENT:-ic4}"
MODEL=$(bash "$RESOLVE" "$AGENT")
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort "$AGENT")
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for $AGENT; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for $AGENT; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

3. Expect `files_changed`, `diff_summary`, `changelog_md` (required).
4. Orchestrator checklist after return:
   - Diff is under worktree only
   - No version-triplet files in `files_changed`
   - Changes uncommitted (`git status` in worktree)

Do **not** apply `changelog_md` to CHANGELOG.md.

---

## Step 5: Adversarial-verify (parallel qa refuters)

1. Split `LENSES` on commas → list (default `correctness`, `completeness`).
2. For each lens, substitute `prompts/refute.md` (`{{LENS}}`, `{{PREMISE_EVIDENCE}}`, …).
3. Spawn **one Task per lens in a single message** (parallel), agent `dev-team:qa`.
   Same fence for later `qa` spawns of this agent. Unnamed /
   `general-purpose` / Explore: omit the fence.

Before spawning @qa:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" qa)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort qa)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for qa; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for qa; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

4. Collect verdicts `{lens, holds, issues?, detail?}`.

### Spawn-failure degradation

If any refuter spawn fails or returns unusable output (rate-limit, empty,
refusal):

1. Keep good returns; self-verify **only** missing lenses with real tools.
2. Actor is always the **orchestrator** — never the implementer.
3. Set `verification_mode=self-verified` and include marker
   `self-verified — refuters unavailable`.
4. Protocol home (cite only, do not restate): `skills/council/SKILL.md`
   § Spawn-failure degradation.

Partial fleet still marks degraded.

---

## Step 6: Orchestrator review

Synthesize:

- `all_hold` = (verdicts length ≥ 1) AND (every verdict `holds=true`)
- `verification_mode` = `self-verified` if any lens was self-verified, else `full`
- If any lens `holds=false`, list issues for the caller; do not auto-fix.

---

## Step 7: Write report

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
REPORT_DIR="$MROOT/.claude/fix-ticket"
mkdir -p "$REPORT_DIR"
DATE=$(date -u +%Y-%m-%d)
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPORT="$REPORT_DIR/${DATE}-${TICKET}.md"
```

Fill `templates/report.md`:

| Placeholder | Value |
|-------------|--------|
| `{{TICKET}}` | ticket id |
| `{{WORKTREE}}` | worktree path |
| `{{PREMISE_HOLDS}}` | true/false |
| `{{ALL_HOLD}}` | true/false |
| `{{VERIFICATION_MODE}}` | full \| self-verified |
| `{{CREATED_AT}}` | ISO-8601 UTC |
| `{{DEGRADED_BANNER}}` | `> **self-verified — refuters unavailable**` when degraded; else empty |
| premise/impl/verdict sections | from phase returns |

Write the filled report with the Write tool (avoid bash heredocs with `!`).

No `index.json` — this is not a council gate.

---

## Step 8: Print next steps

Print (adapt to outcome):

```
Report: .claude/fix-ticket/<date>-<ticket>.md
premise_holds=<bool> all_hold=<bool> verification_mode=<full|self-verified>
Worktree: <path> (changes UNCOMMITTED)

Next:
  1. cd <worktree> && git diff
  2. Fix any failed lenses if all_hold=false
  3. /review-and-commit  (optional)
  4. /release when ready  (caller owns; this skill never releases)
Draft changelog bullet:
  <impl.changelog_md>
```

If premise failed, omit impl/changelog and state stop.

---

## Return schemas (operational copy)

**Premise:** `holds` (bool, req), `evidence` (string, req), `current_locations[]`,
`scope_notes`, `sibling_occurrences[]`, `reference_impl`.

**Impl:** `files_changed[]` (req), `diff_summary` (req), `changelog_md` (req),
`side_effects_checked`, `validation`.

**Verdict:** `lens` (req), `holds` (bool, req), `issues[]`, `detail`.

---

## Notes

### Workflow authoring convention (shared with CDV-196)

If driving a Claude Workflow `.js` asset, **always** guard args:

```js
let t = args
if (typeof args === 'string') {
  try { t = JSON.parse(args) } catch (e) { t = {} }
}
if (!t || typeof t !== 'object' || !t.ticket || !t.worktree) {
  return { error: 'args not interpolated', args_type: typeof args }
}
```

Fail loud when required fields are missing. Do not assume `args` is already
an object. Reference implementation: `skills/fix-ticket/workflow.js`
(non-invoked; markdown path remains authoritative).

### Distinct from

| Command | Difference |
|---------|------------|
| `/debug` | Open-ended investigation; root-cause-before-edit. fix-ticket assumes known premise + fix. |
| `/orchestrate` | Full lifecycle + PR; task store. fix-ticket is a single-ticket fix loop, no PR. |
| `/council` | Pure auditor; no implement. |
| `/review-and-commit` | Diff review + optional commit. fix-ticket never commits. |

### Adjacent tickets

- **CDV-196** — council Workflow re-platform; do not absorb.
- **CDV-199** — spawn-failure marker/protocol home in council; reuse only.
