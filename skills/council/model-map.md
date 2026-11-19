<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

## Model pins (SPEC-037 + SPEC-042)

Named-roster Task/Agent spawns honor `$MROOT/.claude/dev-team/models.local.json`
via `resolve-model.sh`. Every covered council spawn carries an **explicit
`model`** (SPEC-042 M1): at these sites an empty map is **not** an omit. This
overrides the SPEC-037 M13/M16 omit path at council sites only; M13 ∪ M16 sites
elsewhere keep their omit path.

Two pin classes cover every covered spawn (SPEC-042 M2):

**P1 — map-resolved role.** A mappable role (`finder`, `council-judge`, the
Phase 2 named fallback `ic5`, the Phase 3 specialist's named roster
`dev-team:<agent>`) resolves through `resolve-model.sh` at spawn time
(subprocess, never sourced; SPEC-037 M5, SPEC-002 PDH stanza). Non-empty stdout
→ the `model` param. **Empty stdout → pass the role's SPEC-003 § Tier-default
alias** below. MUST NOT pass `""`; MUST NOT omit. That alias is also the role's
**sibling alias** for the host-reject retry.

| P1 role | Tier-default alias (sibling alias) |
|---|---|
| `finder` | `sonnet` |
| `ic5` | `sonnet` |
| `devops` | `sonnet` |
| `qa` | `sonnet` |
| `council-judge` | `opus` |
| `ds` | `opus` |
| `pm` | `opus` |

The suite asserts this column equals SPEC-003 § Tier table (SPEC-042 M7).

**P2 — scribe-class role.** A tool-less, non-mappable `council-scribe`-class
role (Phase 1 extractor, Phase 2.5 cross-reviewer, Phase 3 classifier, Phase 4
prosecutor/advocate, and the `--blind` reviewers plus quorum analyst) pins the
literal `model: sonnet`. That literal is the **P2 pin constant** — this
sentence is its one home (maintainer ruling 2026-11-18; CDT-654 swaps it for a
map resolve). No `resolve-model.sh` call, no map key, no `models.local.json`
write: `council-scribe` stays out of `mappable-names.sh` (SPEC-042 M8) and is
exempt from the alias table above. The unnamed Phase 2 fallbacks
`general-purpose` / `"Explore"` have no Tier row and take the same P2 value.

Effort stays on the map path: `resolve-model.sh --effort` — non-empty →
Agent/Workflow `effort` param; empty → omit (**inherited effort**; MUST NOT
pass `""`). Surface resolver stderr. Do not swallow. Mapping `council-judge`
MUST NOT add tools (`tools: ""` stays empty).

**Host-reject retry (SPEC-042 M4).** On a spawn failure attributed to the
`model` param (invalid/unknown/unsupported model), retry **once** with the
**sibling alias** — the Tier-default alias chosen at pin time (P1) or `sonnet`
(P2). NEVER retry by omitting `model`, NEVER derive the alias from the rejected
string, NEVER combinatorial-retry. Warn exactly:
`model-map: host rejected model '<string>' for <agent>; retrying with sibling alias '<alias>'`.

**Pin==sibling carve-out (SPEC-042 M4).** A P2 pin already equals its sibling
alias (`sonnet` = `sonnet`), so the retry value equals the rejected value and a
retry can add nothing. A P2 site therefore performs **no retry and emits no
warn** on a model-attributed reject; it degrades per that site's existing
failure path (Task path: the site's own spawn-failure handling; Workflow path:
`skills/council/workflow.js` degradation). The retry above is the P1 path: it
bites only where the resolved map value differs from the Tier-default alias.

**Wired fences** (one fence per P1 role; same fence for later spawns of that
role). Resolve the agent actually spawned.

### Extractor (`council-scribe`) — Phase 1

P2 pin. Tool-less. Spawn `subagent_type: "dev-team:council-scribe"` with
`model: sonnet` on both extractor shapes (session/diff and plan). No
`resolve-model.sh` call. MUST NOT run tools.

### Investigator (`finder`) — Phase 2

Before spawning @finder:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" finder)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort finder)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: pass `sonnet` — `finder`'s SPEC-003 § Tier-default alias (P1 floor). NEVER omit `model` at a council site; MUST NOT pass `""`.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent/Workflow `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with the sibling alias `sonnet` (the alias chosen at pin time — never derived from the rejected string, never an omitted `model`); warn `model-map: host rejected model '<string>' for finder; retrying with sibling alias 'sonnet'`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for finder; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

**Phase 2 fallback chain pins (SPEC-042 M2).** Named fallback `finder`→`ic5`
(CDT-230): re-run the fence above resolving `ic5`; non-empty stdout → that
value, empty → `sonnet` (ic5's Tier alias). The unnamed `general-purpose` and
`"Explore"` fallbacks: pin `model: sonnet` (P2 value; no resolver call, no
fence). Every fallback spawn carries an explicit pin — the chain never falls
back to an unpinned spawn.

### Cross-reviewer (`council-scribe`) — Phase 2.5

P2 pin. Tool-less. Spawn `subagent_type: "dev-team:council-scribe"` with
`model: sonnet`. No `resolve-model.sh` call. MUST NOT run tools. Do not spawn
`finder`.

### Classifier and specialist — Phase 3

- **Classifier** (`dev-team:council-scribe`): P2 pin — `model: sonnet`, no
  resolver call. Tool-less.
- **Specialist** (`dev-team:<agent>` — `devops` / `ds` / `qa` / `pm`): P1. Run
  the canonical fence `skills/model-map/spawn-fence.md` with the spawned agent
  as `<AGENT>` (one fence for this role; resolve the agent actually spawned, do
  not paste full PDH at every later spawn). Non-empty stdout → the `model`
  param; empty → that agent's Tier-default alias from the table above
  (`devops`/`qa` → `sonnet`, `ds`/`pm` → `opus`). NEVER `""`, never omitted.
  Effort: same `--effort` rule as @finder.

### Prosecutor and Devil's Advocate (`council-scribe`) — Phase 4

P2 pin. Tool-less. Spawn `subagent_type: "dev-team:council-scribe"` with
`model: sonnet` for both briefs. No `resolve-model.sh` call. Do not spawn
`ic5`.

### Judge (`council-judge`) — Phase 5

Before spawning @council-judge:
```bash
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" council-judge)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort council-judge)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: pass `opus` — `council-judge`'s SPEC-003 § Tier-default alias (P1 floor). NEVER omit `model` at a council site; MUST NOT pass `""`.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent/Workflow `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with the sibling alias `opus` (the alias chosen at pin time — never derived from the rejected string, never an omitted `model`); warn `model-map: host rejected model '<string>' for council-judge; retrying with sibling alias 'opus'`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for council-judge; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

The pin is per role, not per spawn: every judge part of a bundle-cap split
carries the same resolved value (SPEC-042 M1).

### Blind reviewers and quorum analyst (`council-scribe`) — `--blind`

P2 pin. Tool-less. Spawn `subagent_type: "dev-team:council-scribe"` with
`model: sonnet` for each unconstrained team, each lens reviewer, and the single
quorum analyst. No `resolve-model.sh` call.

Dispatch surface: `commands/council.md` mirrors every pin above at its phase
block. The P1 fences there expand `skills/model-map/spawn-fence.md`
byte-identically (Phase 2 `finder`, Phase 5 `council-judge`; the Phase 3
specialist reuses that canonical fence with its own `<AGENT>`).

---
