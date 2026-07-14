---
name: memory-export
description: Export sanitized tier-2 core memories to a committable seed pack under
  .claude/memory/seed/ for warm-start on fresh clones (SPEC-024).
argument-hint: "[--agent <name>] [--limit N] [--dry-run]"
agent: build
---

# /memory-export

Write a sanitized, provenance-tagged seed pack from distilled **tier-2/core** memories
(or fallback cortex/lessons highlights) to `.claude/memory/seed/`. The pack is for
human PR review and commit — this command **never** git-adds, commits, or pushes.

## Arguments

- `/memory-export` — export all 7 behavioral agents (default cap 40 entries/agent)
- `/memory-export --agent <name>` — one agent only (`pm|tech-lead|ic5|ic4|devops|qa|ds`)
- `/memory-export --limit N` — override per-agent entry cap
- `/memory-export --dry-run` — print what would be written (including exclusions) without writing

## Step 1: Export seed pack

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
EXPORT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/export-seed-pack.sh)
if [ -z "$EXPORT_SH" ] || [ ! -f "$EXPORT_SH" ]; then
  echo "ERROR: could not resolve export-seed-pack.sh"
  exit 1
fi
# Pass through user flags from $ARGUMENTS (agent may substitute parsed flags)
bash "$EXPORT_SH" $ARGUMENTS "$MROOT"
```

## After export

1. Skim `.claude/memory/seed/*.md` for residual secrets/paths (sanitization is a floor).
2. Commit via a **reviewed PR** — do not push unreviewed packs.
3. On a fresh clone, `/init-team` imports the pack before project-init (warm start).

See SPEC-024 for layout, sanitization rules, and import semantics.
