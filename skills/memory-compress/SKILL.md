---
name: memory-compress
description: |
    Fact-dense rewrite of agent memory prose (tier-0 notes, digests) without
    losing technical substance. Companion to /memory distill. Zero external deps.
user-invocable: false
---

# Memory Compress

Optional brevity pass for **memory content** — not a full distillation (no
tier promotion). Goal: same facts, fewer tokens, so session loads stay lean.

## When

| Caller | When |
|--------|------|
| `/memory distill` | Optional pre-step on raw tier-0 rows before digest LLM (if user asks, or `MEMORY_COMPRESS=1`) |
| Manual | User asks to compress cortex/lessons/memory prose |

Skip when `MEMORY_COMPRESS=0` or content is already bullet-dense.

## Rules (MUST)

1. **Preserve every technical fact** — names, paths, IDs, versions, constraints,
   decisions, “do not” rules
2. **Prefer bullets** over paragraphs; one fact per line when possible
3. **Drop** greetings, hedges, restatements, “as discussed”, process narration
4. **Keep** code snippets, commands, and error strings **byte-exact**
5. **Do not** invent facts or change meaning
6. **Do not** delete archived markers or tier semantics — this is prose only

## Output shape

```markdown
- Fact one (path/to/file: detail)
- Fact two — constraint
- DO NOT: <rule>
```

Target: roughly **40–60% fewer tokens** on verbose narrative; already-tight
bullets may stay near 100%.

## Protocol snippet

```bash
# Append-only supersede: insert a new tier-0 row. Do not UPDATE the old row.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
MEMDB_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/memdb.sh 2>/dev/null || true)
[ -n "$MEMDB_SH" ] && bash "$MEMDB_SH" write "$MEMDB" "$AGENT" "$TYPE" "$CONTENT"
```

When rewriting `.md` fallback files (`cortex.md` / `memory.md` / `lessons.md`),
preserve headers; compress body sections only.
