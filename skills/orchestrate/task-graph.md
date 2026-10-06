<!-- Shared Step 7 task-graph protocol. Cited by skills/orchestrate/steps/07-tasks.md and skills/kickoff/SKILL.md — do not restate. -->

# Step 7 task-graph protocol

## Inputs

- `<Caller>`: `Kickoff` or `Orchestrate`.
- `<ISSUE-ID>`: the current ticket id.
- The plan's tasks, each with its `Depends on:` list.

## Cycle pre-gate — write fence

Before any TaskCreate, write the plan graph to a deterministic file. Node ids
are plan ordinals as strings (`"1"`, `"2"`, …), not TaskCreate ids.

```bash template
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ISSUE_ID="<ISSUE-ID>"
DAG_FILE="$MROOT/.claude/tasks/dag/$ISSUE_ID.json"
mkdir -p "$(dirname "$DAG_FILE")"
cat > "$DAG_FILE" <<'DAG_JSON'
<JSON array: [{"task_id":"1","depends_on":[]},{"task_id":"3","depends_on":["1","2"]}] — plan ordinals as strings>
DAG_JSON
```

## Cycle pre-gate — check fence

Run this in a fresh shell, after the write fence above. Branch on
`check-cycle`'s exit code: 1 means a cycle; any other non-zero means the
check could not run. Both stop Step 7.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ISSUE_ID="<ISSUE-ID>"
DAG_FILE="$MROOT/.claude/tasks/dag/$ISSUE_ID.json"
CALLER="<Kickoff|Orchestrate>"
CYCLE_ERR=$(mktemp "${TMPDIR:-/tmp}/task-graph-cycle.XXXXXX")
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
bash "$DAG_LIB" check-cycle "$DAG_FILE" 2>"$CYCLE_ERR"
rc=$?
MSG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
rm -f "$DAG_FILE" "$CYCLE_ERR"
if [ "$rc" -eq 1 ]; then
  echo "$CALLER error: circular dependency detected: $MSG. Revise the task graph."
  exit 1
elif [ "$rc" -ne 0 ]; then
  echo "$CALLER error: cycle gate could not run (rc=$rc): $MSG"
  exit "$rc"
fi
```

On either error, stop Step 7. Do NOT call TaskCreate or `task-store.sh create`
for any task. `exit` stops only this fence's shell; you enforce the halt.

## Phase 1 — TaskCreate

For each plan task, in plan order, run the caller's own TaskCreate block (its
own description lines — Task-class, advisory and Recommended agent for
Orchestrate; quality-check mode and `Exposes:` for Kickoff). Record
`Task N → <id>` from each TaskCreate result. Phase 2 needs this table, because
a task can depend on a later plan task.

## Phase 2 — task store

After all of Phase 1 completes, call `task-store.sh create` once per task:

```bash template
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" create "<ISSUE-ID>-<id>" "<subject>" <requires_council> "<DEPS>" --plan-ordinal <N> --taskcreate-id <id>
```

`<DEPS>` is the `:`-joined `<ISSUE-ID>-<id(M)>` for each "Task M" in this
task's plan `Depends on:` list, translated through the Phase 1 table.
Example: Tasks 1, 2 and 3 got TaskCreate ids 41, 42 and 43; Task 3 depends on
Tasks 1 and 2 → `<DEPS>` = `CDV-1-41:CDV-1-42`. A dep key that names no task
keeps the dependent out of `ready-set` for ever — the run stalls. If
`task-store.sh` exits non-zero, surface the error to the user; do not
continue.

## Task Map

The caller records, in its plan, one line per task:

```
- Task N (id:<ID>): <title> [depends on: Task M, …]
```

Kickoff writes this in its Step 7 Task Map fence. Orchestrate writes this in
`07-tasks.md` "Update the plan file".

## Status key

Every later `task-store.sh update-status` call MUST pass the same
`<ISSUE-ID>-<id>` key that `create` used (the Task-store status mirror,
`cross-cutting.md`).
