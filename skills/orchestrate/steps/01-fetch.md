<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 1: Fetch issue context

Resolve **ticket source** and a `closes:` list (persisted on the plan in Step 6).

### Tracker-plane gate (CDT-646)

Read the project's tracker plane once per run before resolving the source
(SPEC-009 § Linear sync is opt-in). One reader: `skills/backlog/linear-gate.sh`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
GATE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/linear-gate.sh)
LINEAR_SYNC=$(bash "$GATE" status --root "$MROOT")   # off (default) | on
printf 'linear_sync=%s\n' "$LINEAR_SYNC"
```

- `off` (default): the local backlog store at `$MROOT/.claude/backlog/` is the
  ticket source of truth. MUST NOT issue any Linear MCP call in this step — the
  order below starts at **Backlog**. A bare `<ISSUE-ID>` with no local item is
  freeform intake, not a Linear lookup.
- `on`: Linear is a mirror you may read first (order **Linear → Backlog →
  Freeform** below), and every write stays local-first, Linear-sync-second
  through `bash "$GATE" sync --root "$MROOT" -- <bridge>`.
- Print the `linear_sync=<off|on>` line beside the Step 2 source line.

Order:

1. **Linear** — only when `LINEAR_SYNC=on` **and** Linear MCP is available (e.g.
   `get_issue`) and the ID resolves: extract title, description, ACs, priority,
   assignee, status, labels.
   Set `source=linear`. Seed `closes:` with `linear:<ISSUE-ID>`.
2. **Backlog** — else if `.claude/backlog/<ISSUE-ID>.md` exists, or
   `.claude/backlog.md` / item titles match the ID or slug: load Problem/Goal/Notes
   as issue context. Set `source=backlog`. Seed `closes:` with
   `backlog/<slug>.md` (and any additional slugs the user names).
3. **Freeform** — else ask the user to paste title, description, ACs. Set
   `source=freeform`, `closes: []`, and warn: no tracker will be closed at ship.

If `LINEAR_SYNC=on` and Linear **and** a matching backlog item both exist,
dual-write both into `closes:` (close local index at ship; Linear ticket status
per **Linear lifecycle** (`11-ship.md`) — Done only when work is on master /
wrap). With the gate `off`, `closes:` carries backlog entries only.

Print source + closes in the Step 2 summary. Store issue context for all
subsequent agent prompts.

---
