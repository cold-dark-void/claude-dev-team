---
name: worktree
description: Inspect or release plugin-managed worktrees under .worktrees/<slug>. Usage /worktree status|list|release <slug>
argument-hint: "status|list|release <slug>"
agent: build
---

# /worktree

User-facing management surface for SPEC-016 worktrees. Thin dispatch over
`skills/worktree-lib.sh` — never source the lib; never call `git worktree`
directly from this command.

## Usage

```
/worktree status
/worktree list
/worktree release <slug>
```

| Args | Action |
|------|--------|
| `status` / `list` | Enumerate `$MROOT/.worktrees/*` (lock FRESH\|STALE\|NONE, age, HEAD) |
| `release <slug>` | Confirm in chat, then remove lock + worktree if clean |
| _(none)_ / unknown | Print usage and stop |

Slug rules (same as the lib): `[A-Za-z0-9_-]+` only. Reject empty or invalid
slugs before calling release.

## Step 1: Resolve worktree-lib.sh

Install-aware resolution via `plugin-dir.sh` (script ships in the plugin, not
the user's repo):

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)

if [ ! -f "$WT_LIB" ]; then
  echo "error: worktree-lib.sh not found" >&2
  exit 1
fi
```

## Step 2: Parse and dispatch

Default / missing / unknown subcommand → usage:

```
usage: /worktree status|list|release <slug>
```

### `status` or `list`

Both map to the same lib listing:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
bash "$WT_LIB" status
```

Print stdout to the user. Exit non-zero from the lib is unexpected for
status/list — surface stderr if it occurs.

### `release <slug>`

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
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
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
- `ensure` / `register` / `sweep` are lib-only surfaces — not exposed here.
