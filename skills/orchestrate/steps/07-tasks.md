<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 7: Create task graph

When `[ "$ORCH_TIER" = "light" ]`: skip DAG and task-store. One task. MUST NOT set `requires_council` (council default is skip; override is Step 9). Do not run `dag-lib.sh` / `task-store.sh` / the TaskCreate loop below. Continue to Step 8.

Otherwise (omit / `standard` / `full`):

Resolve and Read `skills/orchestrate/task-graph.md`
(`bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-graph.md`).
`<Caller>` = `Orchestrate`. Follow its Inputs, Cycle pre-gate (write fence then
check fence) and Phase 1 sections before any TaskCreate below.

For each task in the approved plan, finalize tagging then call TaskCreate.

**`Task-class:` line (SPEC-026 M3).** Record class as a prose line (mirroring
`Recommended agent:`) — NOT a `task-store.sh` schema field.
Fixed taxonomy: `impl-extend | impl-novel | refactor | test | docs | infra | discovery`.
Missing line ⇒ `task_class: null` at emit; null-class records are still written but
excluded from advisory aggregation (M7).

#### Step 7 advisory (SPEC-026 M5/M6/M7) — before Recommended agent is finalized

After choosing the **static** Recommended agent (SPEC-009 rules; cite
agents/tech-lead.md Task-routing table) and Task-class,
consult the outcome ledger. Fail-open: any failure ⇒ silence, keep static (M9).
MUST NOT auto-flip routing (M6).

```bash
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RATES=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/outcome-rates.sh)
STATIC_AGENT="<ic4|ic5|qa|devops|ds>"
TASK_CLASS="<from Task-class line; empty if missing>"
ADVISORY=""
if [ -n "$TASK_CLASS" ]; then
  ADVISORY=$(bash "$RATES" "$STATIC_AGENT" "$TASK_CLASS" 2>/dev/null || true)
fi
[ -n "$ADVISORY" ] && printf '%s\n' "$ADVISORY"
```

- Empty `$ADVISORY` (cold start / thin data / boundary / no jq) → no advisory text;
  set `Recommended agent: $STATIC_AGENT`.
- Non-empty → print to user. **Interactive only:** wait for explicit accept/decline.
  On **explicit accept**, set `Recommended agent:` to the suggested alt (the
  `consider <alt>` agent — already M8-legal). Decline / timeout / unattended /
  no response → keep `$STATIC_AGENT`. Unattended runs never wait.

Then call TaskCreate with the finalized lines:

```
TaskCreate:
  subject: "<ISSUE-ID> Task N — <title>"
  description: |
    <description>
    Task-class: <impl-extend|impl-novel|refactor|test|docs|infra|discovery>
    Recommended agent: <ic4|ic5|qa|devops|ds>
    Depends on: [Task IDs] or "none"
    requires_council: <true|false>   # omit = false
```

After all TaskCreate calls in this step, follow `skills/orchestrate/task-graph.md`
Phase 2 to call `task-store.sh create` once per task, and its Status key section
for every later `task-store.sh update-status` call.

Update the plan file with the Task Map line form from `task-graph.md` (`- Task N (id:<ID>): <title> [depends on: Task M, …]`).

If Linear is available, add a comment with the task breakdown.

