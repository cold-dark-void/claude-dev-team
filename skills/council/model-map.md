<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

## Model map (SPEC-037)

Named-roster Task/Agent spawns honor `$MROOT/.claude/dev-team/models.local.json`
via `resolve-model.sh`. Empty stdout = **Tier default** (omit `model`; MUST
NOT pass `""`). Then `resolve-model.sh --effort`: non-empty → Agent/Workflow
`effort` param; empty → omit (**inherited effort**; MUST NOT pass `""`).
Surface resolver stderr. Do not swallow. Mapping `council-judge` MUST NOT add
tools (`tools: ""` stays empty).

**Wired roles** (one fence per role; same fence for later spawns of this
agent). Resolve the agent actually spawned. Named fallback `finder`→`ic5`
resolves `ic5` (CDT-230). Unnamed / `general-purpose` / Explore: omit the fence.

**Omit (OQ1):** Phase 1 extractor, Phase 2.5 cross-reviewer, Phase 3
specialist, Phase 4 prosecutor/advocate, `--blind` waves. Those roles spawn
`dev-team:council-scribe` (`tools: ""`). Do not map `council-scribe`.

### Investigator (`finder`) — Phase 2

Before spawning @finder:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" finder)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort finder)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent/Workflow `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for finder; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for finder; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

### Cross-reviewer (`council-scribe`) — Phase 2.5

Tool-less. Spawn `subagent_type: "dev-team:council-scribe"`. No model-map
fence (OQ1). MUST NOT run tools. Do not spawn `finder`.

### Judge (`council-judge`) — Phase 5

Before spawning @council-judge:
```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" council-judge)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort council-judge)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent/Workflow `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for council-judge; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for council-judge; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

Dispatch surface: `commands/council.md` points here. Wired fences are
Phase 2 `finder` and Phase 5 `council-judge`. Phase 2.5 is `council-scribe`
with no fence.

---
