<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 4: Parallel PM + Tech Lead kickoff

When `[ "$ORCH_TIER" = "light" ]`: spawn exactly one scoper-planner (not parallel PM+TL). Use `@tech-lead` (or a general agent). That agent (1) locks ACs and (2) writes a short (~5-line) plan. Then Step 5. Do not spawn the PM agent or Tech Lead orientation below.

When spawning `@tech-lead`, resolve its model first. If using unnamed/general-purpose instead, omit this block (SPEC-037 AC20).

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" tech-lead)
printf '%s\n' "$MODEL"
```
Bash stdout = model string; empty → omit model.
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for tech-lead; retrying with Tier default`.
Other spawn failures MUST NOT be retried as a model fallback.

```
You are the scoper-planner for issue <ISSUE-ID> (light tier).

Output mode: terse

<ISSUE CONTEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — unambiguous and testable.
   Flag any scope questions that must be resolved before implementation.
   Add any missing ACs the issue implies but doesn't state.
2. Write a short (~5-line) implementation plan to
   `.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md` with a Tracking section:

## Tracking
- source: linear | backlog | freeform
- ticket_id: <ISSUE-ID>
- closes:
  - backlog/<slug>.md
  - linear:<ID>
- autopilot_on: <true|false>
- autopilot_bump: <patch|minor|major|master|null>

`autopilot_on`/`autopilot_bump` MUST always be written (Step-0
`AUTOPILOT_ON`/`AUTOPILOT_BUMP`). Empty closes only for freeform.

Do NOT produce a full task graph. Do NOT spawn further agents.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

Collect one output. Continue to Step 5.

Otherwise (omit / `standard` / `full`):

Use `/kickoff` logic but adapted — spawn both agents in the worktree:

### PM agent (spawn now):

Before spawning @pm:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" pm)
printf '%s\n' "$MODEL"
```
Bash stdout = model string; empty → omit model.
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for pm; retrying with Tier default`.
Other spawn failures MUST NOT be retried as a model fallback.

```
You are @pm. Review issue <ISSUE-ID>:

Output mode: terse

<ISSUE CONTEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — make them unambiguous and testable
2. Flag any scope questions that must be resolved before implementation
3. Add any missing ACs the issue implies but doesn't state
4. Output: revised AC list + open questions (if any)

Do NOT plan implementation. Scope only.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Tech Lead agent (spawn now, in parallel):

Before spawning @tech-lead:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" tech-lead)
printf '%s\n' "$MODEL"
```
Bash stdout = model string; empty → omit model.
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for tech-lead; retrying with Tier default`.
Other spawn failures MUST NOT be retried as a model fallback.

```
You are @tech-lead. Orient on issue <ISSUE-ID> while @pm reviews scope.

Output mode: terse

Issue summary: <title + first 2 sentences>

Your job:
1. Read your cortex.md for architecture context
2. Identify which files/packages this will likely touch
3. Identify existing specs that constrain the design
4. Note technical risks or unknowns

Do NOT produce a plan yet — wait for confirmed ACs.
Output: affected files, relevant specs, risks.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

Collect both outputs.

