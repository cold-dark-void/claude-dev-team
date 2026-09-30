---
name: worktree
description: Release (remove) a plugin-managed worktree under .worktrees/<slug>. Usage /worktree release <slug>. For listing, use /status worktree.
argument-hint: "release <slug>"
agent: build
---

# /worktree

User-facing **mutate-only** surface for SPEC-016 worktrees (CDT-46-C4). Thin
dispatch over `skills/worktree-lib.sh` for **release** only — never source the
lib; never call `git worktree` directly from this command.

Read-only listing moved to `/status worktree`. This command is **not** a
Deprecation stub — it remains the live path for removing worktrees.

## Usage

```
/worktree release <slug>
```

For status/list of plugin-managed worktrees, use:

```
/status worktree
```

| Args | Action |
|------|--------|
| `release <slug>` | Show a preview (counts, merge state), confirm in chat, then remove lock + worktree if clean and delete `feat/<slug>` only when it is merged — never force-removes |
| `status` / `list` / _(none)_ / unknown | Print usage (point to `/status worktree`) and stop — **do not** call the lib |

Slug rules (same as the lib): `[A-Za-z0-9_-]+` only. Reject empty or invalid
slugs before calling release.

## Step 1: Parse args (no lib yet)

Default / missing / unknown subcommand — including bare `/worktree`,
`status`, and `list` — → usage and **stop without invoking the lib**:

```
usage: /worktree release <slug>
For worktree listing, use: /status worktree
```

Only the `release` subcommand proceeds past this step.

## Step 2: Resolve worktree-lib.sh

Install-aware resolution via `plugin-dir.sh` (script ships in the plugin, not
the user's repo). Run **only** when releasing:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)

if [ ! -f "$WT_LIB" ]; then
  echo "error: worktree-lib.sh not found" >&2
  exit 1
fi
```

## Step 3: `release <slug>`

1. Require `<slug>`. If missing: print usage and stop.
2. Validate slug: must match `^[A-Za-z0-9_-]+$`. If not:
   ```
   release: invalid slug (only [A-Za-z0-9_-] allowed): <slug>
   ```
   Stop without calling the lib.
3. **Preview first (read-only).** Before asking anything, run:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
bash "$WT_LIB" release --preview "$slug"
```

   Show the result to the user, including `ahead_of_base`,
   `ahead_of_upstream` (or "no upstream" when the preview printed
   `upstream: none`), `merged` and `pushed`. If a count line printed `?`,
   show it as-is (a git error on that count, not a failure).

4. **Chat confirmation (required).** State plainly what the lib does: it
   removes the worktree only when the tree is clean, it never
   force-removes, and it deletes `feat/<slug>` only when the branch is
   merged — an unmerged branch is kept.

   - When the preview printed `confirm: slug`, the branch is **not**
     merged. Ask the user to type the exact slug back:
     ```
     Release worktree .worktrees/<slug>?
     feat/<slug> is not merged into <base> (<ahead_of_base> commit(s) ahead).
     This removes the worktree only; feat/<slug> would be kept, not deleted.
     Type `<slug>` to confirm.
     ```
     Accept **only** the exact typed slug as confirmation. A plain `yes`
     is **not** confirmation when the preview printed `confirm: slug`.
   - When the preview printed `confirm: yesno`:
     - If the preview also printed `branch: none`, there is no
       `feat/<slug>` branch — release only removes the worktree:
       ```
       Release worktree .worktrees/<slug>? No feat/<slug> branch exists;
       only the worktree is removed. (yes/no)
       ```
     - Otherwise `feat/<slug>` is merged, and release removes the branch
       too:
       ```
       Release worktree .worktrees/<slug>? This removes the worktree and,
       because feat/<slug> is merged, the branch too. (yes/no)
       ```
     Either way, a plain yes/no answer is enough.
   - On decline, or on anything other than the required confirmation
     (typed slug, or yes): do **not** call release; print
     `release cancelled` and stop.
   - On the correct confirmation: proceed.
5. Call the lib (dirty-tree refusal is owned by the lib — do not force-remove):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
bash "$WT_LIB" release "$slug"
```

6. Surface result:
   - Exit 0: report success (path removed). If stderr had a
     `release: kept feat/<slug>` line, show that warning too — the
     branch stays because it is not merged (or has no resolvable base).
   - Exit 1: show the lib stderr as-is (dirty tree, or a failed worktree
     removal). Do **not** retry with a force flag.
   - Other non-zero: show stderr; stop.

## Constraints

- MUST resolve via `plugin-dir.sh` — never `bash skills/worktree-lib.sh` alone
  as the only path, and never `$MROOT/skills/worktree-lib.sh`.
- MUST NOT call `git worktree remove` / `git worktree add` from this command.
- MUST NOT force-remove dirty worktrees; MUST NOT retry a failed removal with
  a force flag.
- MUST run `release --preview` before asking for confirmation, and MUST
  require the typed slug (not a plain `yes`) when the preview prints
  `confirm: slug`.
- MUST NOT invoke `worktree-lib.sh status` (or `list`) from this command —
  listing is `/status worktree` only.
- `ensure` / `register` / `sweep` / `status` / `list` are lib (or `/status`)
  surfaces — not exposed as actions here.
