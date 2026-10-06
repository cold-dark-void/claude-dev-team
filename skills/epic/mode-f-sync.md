<!-- /epic stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

## Mode F — `/epic sync <EPIC-ID> [--dry-run]` (M15)

**When:** local `$MROOT/.claude/epics/<EPIC-ID>/state.json` exists but may be
**stale** vs Linear (status closed in Linear, null `linear_id`, wrong project id,
orphans under parent). **Not** re-decomposition (use `--redecompose`).

**Requires:** `exists` → else print `No state for epic <ID> — nothing to sync`
and stop (exit non-zero / return). Illegal with `--worktree` / `--release`
(parse-flags exit 64).

### F.1 Inventory (session-owned MCP)

When Linear MCP is **down**: print M5 one-liner
`Linear unavailable — continuing with local write-through only`, then stop with
**zero** `state.json` mutation (sync has nothing to pull).

When MCP is **up**:

1. `list_issues parentId=<EPIC-ID>` — page until exhausted; same survivor filter
   as M4.1 (not `canceled`). Fields: `id`, `title`, `description`, `status`,
   `statusType`, `projectId` / identifier as available.
2. Optional: if `linear_project_id` is null, resolve project by exact epic
   `title` (M12.2 link-only rules) — do **not** create a project on sync.
3. **Map** each local child to ≤1 Linear survivor:
   - Prefer exact `linear_id` match (identifier or UUID as stored)
   - Else M4.1 title / `child_id`-in-description match
4. **statusType → local status** (session maps before apply):
   - `completed` / done → `completed` (Linear Done only — not In Review)
   - `canceled` → `blocked`
   - `started` → `in_progress` (covers **In Progress** and **In Review** —
     review is still open work for epic walkers; do not treat as completed)
   - else (`unstarted`, backlog, triage, …) → `pending`
5. Build verdicts JSON (TMPDIR):

```json
{
  "linear_project_id": "<optional when local null and known>",
  "children": [
    { "id": "<EPIC-ID>-C1", "linear_id": "CDT-…", "status": "completed",
      "outcome_summary": "optional ≤1 line from Linear title/state" }
  ],
  "orphans": [{ "linear_id": "…", "title": "…" }],
  "unmatched_local": ["<EPIC-ID>-C3"]
}
```

- **orphans:** Linear survivors with no local child map (report only — never
  auto-add children; that needs approve/`--redecompose`)
- **unmatched_local:** local children with null `linear_id` and no unique match

### F.2 Apply (mechanical)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
VERDICTS=$(mktemp "${TMPDIR:-/tmp}/epic-sync-verdicts.XXXXXX.json")
# write F.1 verdicts into $VERDICTS
# DRY_RUN=1 when user passed --dry-run
if [ "${DRY_RUN:-0}" = "1" ]; then
  bash "$EPIC_LIB" sync-apply "$EPIC_ID" --verdicts "$VERDICTS" --dry-run
else
  bash "$EPIC_LIB" sync-apply "$EPIC_ID" --verdicts "$VERDICTS"
fi
rm -f "$VERDICTS"
```

**`sync-apply` invariants (epic-lib, no MCP):**

| Rule | Behavior |
|------|----------|
| Fill `linear_id` | Only when local null/empty |
| `linear_id` mismatch | Conflict; leave local |
| Status same | Skip |
| Status forward | Apply (e.g. pending→completed) |
| `completed` → non-completed | **Skip** (`no_downgrade_completed`) — never re-open wrapped work |
| `linear_project_id` | Fill only when local null; never clear; mismatch → conflict |
| Unknown child / invalid status | Conflict skip |
| Orphans | Report only |
| `--dry-run` | Report planned actions; **zero** disk write |

Print the JSON report (applied / skipped / conflicts / orphans). On conflicts or
orphans, tell the user: orphans need manual map or `--redecompose`; mismatches
need human fix.

**Autopilot:** `/epic sync` is not a SPEC-033 gate; if invoked under autopilot,
apply the same safe rules (no force reopen, no create, no auto-add orphans).

**Does NOT:** create Linear issues, re-decompose, delete children, attach-storm
all children to a project, or run Mode B handoff.

