# Tracker plane — the `linear_sync` gate and the offline ticket verbs

The one operational copy of the CDT-646 tracker-plane protocol (SPEC-002 D1).
`skills/backlog/SKILL.md` § Tracker plane, `commands/status.md` § Tracker plane,
and the epic / kickoff / orchestrate gate notes cite this file and never restate
it. Spec: `specs/core/SPEC-009-ticket-workflow.md` § Linear sync is opt-in.

`skills/backlog/linear-gate.sh` is the only code that reads `linear_sync`.
`skills/backlog/ticket.sh` is the ticket verb CLI over the local store.

## Bind the gate once per run

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
GATE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/linear-gate.sh)
LINEAR_SYNC=$(bash "$GATE" status --root "$MROOT")
printf 'linear_sync=%s\n' "$LINEAR_SYNC"
```

- `off` (the default) — every path is the **local path**. Skip every Linear step,
  query, and MCP call; print no Linear notice; the local store is the whole
  answer. A Surface MUST complete its job and MUST NOT report Linear as
  unavailable for a call it never made.
- `on` — local write first, Linear second. The CDT-54 fail-open lines
  (`Linear unreachable — …`) live on this leg only.
- Resolution: `$LINEAR_SYNC` (one run) → `<root>/.claude/dev-team/config.json`
  (project) → `off`. Absent key, absent file, invalid JSON, an unknown token, or
  no `jq` all resolve `off`: the offline path is the fail-closed path.
- Flip it: `bash "$GATE" set --root "$MROOT" on` (writes the config, prints the
  path; `off` restores the default). `enabled` is the test/branch form (exit 0 on
  / 1 off).
- Ordered handoff: `bash "$GATE" sync -- CMD ARGS…` runs `CMD` only when the key
  is `on`, after the local write, and passes its exit code through. With the key
  `off` it prints `linear-skip: linear_sync=off — local path only, no Linear
  call` and runs nothing. `LINEAR_SYNC_CMD` is the test seam for the sync leg.

## Offline ticket verbs

`skills/backlog/ticket.sh` creates, claims, and closes a ticket, an epic, or an
epic child over the local store: **zero network, zero Linear MCP calls** in the
verbs themselves. `create` → `add.sh`, `claim` → `close.sh claim`, `close` →
`close.sh` — the CLI delegates, so no second write path appears (SPEC-002 D1).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
TICKET=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/ticket.sh)
bash "$TICKET" create --root "$MROOT" --title "<TITLE>" --problem "<TEXT>" \
  --goal "<TEXT>" [--kind ticket|epic|child] [--epic-parent <EPIC-ID>] \
  [--child-id <ID>] [--depends-on "[CDT-646]"] [--estimate S|M|L] [--agent ic5]
bash "$TICKET" claim --root "$MROOT" <slug-or-title> [--owner <name>]
bash "$TICKET" close --root "$MROOT" <slug-or-title> [--ticket <ID>] [--sha <sha>]
```

Every verb prints `store: <root>/.claude/backlog` and exits `0` ok / `1` verb
failure (no match, closed item, lock timeout) / `64` usage and ambiguity (a bad
flag, or a query that matches more than one item — `close.sh`
`require_one_slug` reports the matches and never picks one).
The root follows SPEC-009 § Backlog root rule (`--root` wins).
`--linear-id` is the `on`-path linkage; with the key `off` nothing reads it.
After the local write each verb runs the gate's `sync` seam.

## Claim mechanics

`close.sh claim <slug-or-title> [--owner NAME]` stamps an item as taken so a
second agent does not start it. Zero Linear MCP calls on either gate path.

- Item: `**Status**: IN_PROGRESS (<owner>)` plus a
  `*Claimed: <date> by <owner>*` footer; frontmatter is preserved.
- Index: the row re-tags to `[IN_PROGRESS]` **in place** under `## Pending` —
  the row stays open, so `list`, `sweep`, and `reconcile` keep seeing the work.
- `IN_PROGRESS` is open to `skills/backlog/terminal-status.sh` (`is-claimed`
  answers the claim question with the same token-match rule).
- One shared `mkdir` lease (`<root>/.claude/backlog.lock/`), idempotent for the
  same owner (`Already claimed:`), refuses a terminal item (exit 1), and refuses
  an unknown slug (exit 1). `--owner` defaults to `unassigned`.
- Manual fallback: change the status line and append the footer by hand, then
  re-tag the index row. Preserve frontmatter (`linear_id`, epic fields).

## Mirror paths (`linear_sync=on` only)

These are the Linear legs the Surfaces skip entirely with the key `off`. Local
state is already committed before each one runs; a mirror failure prints one line
and the local write stands.

- **Create** — create the Linear issue (title + the self-contained
  problem/goal text), capture the team issue key, then write the item once with
  `add.sh --linear-id <ID>`: frontmatter `linear_id:` plus the `linear:<ID>`
  token on the index row. MCP-down / create failure →
  `Linear unreachable — local backlog only.`, write with no `linear_id`.
- **Close** — `close.sh` first (item + index), then read `linear_id` from the
  frontmatter, the `linear:<ID>` index token, or the plan `closes:` entry, and
  mark the Linear issue terminal. Failure → `Linear unreachable — local close
  only.` `close.sh verify` is the ship gate, and it reads the local store only.
- **List** — query Linear for open issues (exclude terminal states), present
  them cross-referenced with the local store, and report local rows with no
  `linear_id` as work the mirror does not carry. Failure →
  `Linear unreachable — local backlog only.` then the local index.
- **Reconcile** — resolve each linked entry's Linear state, write the
  `slug<TAB>state` verdicts file, pass `--linear-verdicts`; a terminal verdict
  prunes the item (file deleted, row dropped) even when the local status is
  open. With the key `off` the flag is never passed and the LOCAL pass is the
  whole reconcile.
- **Ship close-out** — `skills/backlog/fold-sweep.sh` prints one
  `linear-close: <ID>` line per flipped item for the session's best-effort Linear
  Done. With the key `off` the session runs none of those calls.

Every mirror leg is one best-effort call per record: no retry loop, no block, no
rollback of the local write.
