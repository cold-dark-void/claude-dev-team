<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 7: Create task graph

When `[ "$ORCH_TIER" = "light" ]`: skip DAG and task-store. One task. MUST NOT set `requires_council` (council default is skip; override is Step 9). Do not run `dag-lib.sh` / `task-store.sh` / the TaskCreate loop below. Continue to Step 8.

Otherwise (omit / `standard` / `full`):

Before creating any tasks, extract the dependency graph from the approved Tech Lead plan and reject cycles up front:
1. For each task in the plan, note its ID (Task 1, Task 2, …) and its "Depends on:" list.
2. Map each plan "Task N" reference to its compound key `<ISSUE-ID>-N` (the same key Step 7 uses for `task-store.sh create`), then build a JSON array: `[{"task_id": "<ISSUE-ID>-N", "depends_on": ["<ISSUE-ID>-M", ...]}, ...]`. A task with no deps gets `"depends_on": []`.
3. Write the dependency JSON to `$DAG_FILE` and run the cycle pre-gate BEFORE any TaskCreate:
   ```bash
   DAG_FILE="${TMPDIR:-/tmp}/orchestrate-dag-$$.json"
   CYCLE_ERR="${TMPDIR:-/tmp}/orchestrate-cycle-err-$$.txt"
   # (caller already wrote the dependency JSON into $DAG_FILE)
   # Re-resolve PDH (each bash fence is a fresh shell)
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
   DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
   bash "$DAG_LIB" check-cycle "$DAG_FILE" 2>"$CYCLE_ERR"
   rc=$?
   if [ "$rc" -eq 1 ]; then
     CYCLE_MSG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Orchestrate error: circular dependency detected: $CYCLE_MSG. Revise the task graph."
     # halt — do NOT call TaskCreate for any task
   elif [ "$rc" -ne 0 ]; then
     DIAG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Orchestrate error: cycle gate could not run (rc=$rc): $DIAG"
     # halt — do NOT call TaskCreate for any task
   fi
   rm -f "$DAG_FILE" "$CYCLE_ERR"
   ```
   Do NOT call TaskCreate (or `task-store.sh create`) for any task if a cycle is detected or the cycle gate could not run.

For each task in the approved plan, finalize tagging then call TaskCreate.

**`Task-class:` line (SPEC-026 M3).** Record class as a prose line (mirroring
`Recommended agent:`) — NOT a `task-store.sh` schema field.
Fixed taxonomy: `impl-extend | impl-novel | refactor | test | docs | infra | discovery`.
Missing line ⇒ `task_class: null` at emit; null-class records are still written but
excluded from advisory aggregation (M7).

#### Step 7 advisory (SPEC-026 M5/M6/M7) — before Recommended agent is finalized

After choosing the **static** Recommended agent (SPEC-009 rules) and Task-class,
consult the outcome ledger. Fail-open: any failure ⇒ silence, keep static (M9).
MUST NOT auto-flip routing (M6).

```bash
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RATES=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/outcome-rates.sh)
STATIC_AGENT="<ic4|ic5|… from static rule>"
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
    Recommended agent: <ic4|ic5|qa>
    Depends on: [Task IDs] or "none"
    requires_council: <true|false>   # omit = false
```

After each TaskCreate succeeds and the task id is known, the orchestrator MUST call:

```bash
# Build colon-separated depends_on from this task's plan "Depends on:" list.
# Map each "Task N" reference to the SAME compound key used below: "<ISSUE-ID>-N".
# e.g. if Task 3 depends on Task 1 and Task 2 and <ISSUE-ID> is CDV-QF-FILTER:
#   DEPS="CDV-QF-FILTER-1:CDV-QF-FILTER-2"
# If no deps:
#   DEPS=""
DEPS=$(echo "<compound dep keys for this task, space/comma-separated>" | tr ', ' ':' | tr -s ':' | sed 's/^://;s/:$//')
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" create <ISSUE-ID>-<task_id> "<subject>" <requires_council> "$DEPS"
```

where `<ISSUE-ID>` is the current issue ID (e.g. `CDV-QF-FILTER`) and `<task_id>` is the integer returned by TaskCreate (e.g. `1`). The compound key (e.g. `CDV-QF-FILTER-1`) prevents task-store collisions when a new Claude process reuses the same integer IDs across runs. The 4th `[depends_on]` argument MUST use the SAME compound `<ISSUE-ID>-N` form so `dag-lib.sh ready-set`'s set-subtraction matches completed task IDs — a bare `Task N` or `N` would never appear in the done-set and would silently re-mark every dependent as ready, defeating the DAG. A task with no deps passes `""` (empty depends_on). This writes `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json` — the source of truth the SPEC-002 TaskCompleted hook reads to determine whether the council quality gate applies (SPEC-009, "council gate applies when `requires_council: true`" MUST + the task-store source-of-truth MUSTs). If `task-store.sh` exits non-zero, surface the error to the user immediately — do NOT silently continue.

Update the plan file with task IDs.

If Linear is available, add a comment with the task breakdown.

