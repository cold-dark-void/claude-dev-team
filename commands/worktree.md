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
| `release <slug>` | Confirm in chat, then remove lock + worktree if clean |
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
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
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
3. **Chat confirmation (required).** Ask the user something like:
   ```
   Release worktree .worktrees/<slug>? This removes the worktree and
   feat/<slug> branch if clean. (yes/no)
   ```
   - On **no** / decline / anything other than explicit yes: do **not** call
     release; print `release cancelled` and stop.
   - On **yes**: proceed.
4. Call the lib (dirty-tree refusal is owned by the lib — do not force-remove):

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
bash "$WT_LIB" release "$slug"
```

5. Surface result:
   - Exit 0: report success (path removed).
   - Exit 1 with dirty-tree message: show the lib stderr as-is; do **not**
     retry with force or `git worktree remove --force`.
   - Other non-zero: show stderr; stop.

## Constraints

- MUST resolve via `plugin-dir.sh` — never `bash skills/worktree-lib.sh` alone
  as the only path, and never `$MROOT/skills/worktree-lib.sh`.
- MUST NOT call `git worktree remove` / `git worktree add` from this command.
- MUST NOT force-remove dirty worktrees.
- MUST NOT invoke `worktree-lib.sh status` (or `list`) from this command —
  listing is `/status worktree` only.
- `ensure` / `register` / `sweep` / `status` / `list` are lib (or `/status`)
  surfaces — not exposed as actions here.
