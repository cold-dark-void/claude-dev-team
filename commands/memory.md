---
name: memory
description: Unified memory surface — config, distill, export, search, stats, validate
argument-hint: "<config|distill|export|search|stats|validate> [args...]"
agent: build
---

# /memory

Thin host over four engine skills. This file parses the sub, resolves the
skill, and Reads it. Protocol is not restated here.

```
Usage: /memory <config|distill|export|search|stats|validate> [args...]

Subs:
  config    View/set distillation and validation config
  distill   Compress tier-0 raw memories into digests / promote to core
  export    Export sanitized tier-2 seed pack (SPEC-024)
  search    Search memories (semantic / keyword / grep)
  stats     Anonymized usage metrics (counts and sizes only)
  validate  Cross-reference memories vs codebase; --reconcile for contradictions
```

Parse the first positional argument as `<sub>`. If absent or unknown, print
the usage block and stop. Remaining args pass through unchanged.

| `<sub>` | Protocol file |
|---------|---------------|
| `config` | `skills/memory-store/config.md` |
| `distill` | `skills/memory-store/distill.md` |
| `export` | `skills/memory-store/export.md` |
| `search` | `skills/memory-recall/SKILL.md` |
| `stats` | `skills/memory-store/stats.md` |
| `validate` | `skills/validate-memory/SKILL.md` |

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SUB=""
for arg in $ARGUMENTS; do
  SUB="$arg"
  break
done
case "$SUB" in
  config)   REL="skills/memory-store/config.md" ;;
  distill)  REL="skills/memory-store/distill.md" ;;
  export)   REL="skills/memory-store/export.md" ;;
  search)   REL="skills/memory-recall/SKILL.md" ;;
  stats)    REL="skills/memory-store/stats.md" ;;
  validate) REL="skills/validate-memory/SKILL.md" ;;
  *)
    echo "Usage: /memory <config|distill|export|search|stats|validate> [args...]" >&2
    exit 1
    ;;
esac
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file "$REL")
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: $REL not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded memory protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it with remaining args (everything after `<sub>`)
unchanged.

- `config` / `distill` / `export` / `stats` live in `skills/memory-store/`.
- `search` lives in `skills/memory-recall/SKILL.md` (includes `--status`).
- `validate` lives in `skills/validate-memory/SKILL.md`; that file directs
  you to `skills/validate-memory/pipeline.md` for the host steps. Read both.
- `distill --compress` / `MEMORY_COMPRESS=1` cites
  `skills/memory-compress/SKILL.md` — do not inline it here.

Do not restate engine protocol in this command.

## Notes

- Engines: `memory-store`, `memory-recall`, `memory-compress`, `validate-memory`
  (all `user-invocable: false`)
- Specs: SPEC-006 (search), SPEC-007 (distill/config/stats), SPEC-011
  (validate), SPEC-024 (export)
