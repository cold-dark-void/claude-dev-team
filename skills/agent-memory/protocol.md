<!--
  Canonical agent memory protocol — SINGLE SOURCE OF TRUTH.

  This is the ONE authoritative copy of the per-agent memory block. It is expanded
  inline into every behavioral agent's `## Persistent Memory` section (with `<AGENT>`
  substituted for the agent name) between `<!-- include: skills/agent-memory/protocol.md
  agent=X -->` / `<!-- /include -->` markers. `/release` drift-checks that every agent's
  marked region equals this file expanded — so the 7 copies can never drift again.

  Agents inline this (rather than referencing it at runtime) because a spawned agent's
  cwd is the consumer's project, where this skill is not reachable, and agents have no
  Skill tool. Self-containment is required for portability (D2 / SPEC-003).

  The ONLY per-agent substitution is `<AGENT>`. Set shell variables CONTENT, TYPE,
  and CONTEXT before the write fence. `<TYPE>` in a path is the file stem the agent fills.
  Contracts: write protocol per SPEC-004 + skills/memory-store; session-read SoT is
  this file (SPEC-006); cross-agent search per skills/memory-recall Steps 3–5;
  line limits per SPEC-004.

  Each bash fence re-resolves path vars — fences are separate shells (SPEC-021 C1).
-->
### Path resolution
```bash
MROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd || pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
AGENT_MEM="$MROOT/.claude/memory/<AGENT>"

# Detect storage mode
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

### Session start — load directives (before memory)
```bash
MROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd || pwd)
DIRECTIVES="$MROOT/.claude/memory/<AGENT>/directives.md"
if [ -s "$DIRECTIVES" ]; then
  echo "## Standing orders for this project"; cat "$DIRECTIVES"
fi
```

### Session start — read memory (tiered)
```bash
MROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd || pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
AGENT_MEM="$MROOT/.claude/memory/<AGENT>"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
if [ "$USE_DB" = "true" ]; then
  # Load tier 2, tier 1, and every non-archived tier-0 row. Distill archives
  # consumed tier-0, so a lesson written after a digest stays visible (CDT-336).
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  MEMDB_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/memdb.sh 2>/dev/null || true)
  if [ -n "$MEMDB_SH" ] && [ -f "$MEMDB_SH" ]; then
    bash "$MEMDB_SH" load-session "$MEMDB" "<AGENT>"
  else
    sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT type, content FROM memories
      WHERE agent='<AGENT>' AND archived=FALSE
      ORDER BY tier DESC, type, updated_at DESC;"
  fi
else
  for TYPE in cortex memory lessons; do
    cat "$AGENT_MEM/$TYPE.md" 2>/dev/null
  done
fi
# Context is always .md (per-worktree)
cat "$WTROOT/.claude/memory/<AGENT>/context.md" 2>/dev/null
```

### Writing memory (append-only; embeds best-effort)
```bash
MROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd || pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
AGENT_MEM="$MROOT/.claude/memory/<AGENT>"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
if [ "$USE_DB" = "true" ]; then
  # Append ONE focused fact. memdb.sh write binds the values, reads the row
  # back, and retries only when the first attempt did not commit (CDT-276 T-3).
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  MEMDB_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/memdb.sh 2>/dev/null || true)
  # Embed resolver tiers: 0) substituted CLAUDE_PLUGIN_ROOT token (SPEC-002 tier 1b);
  # 1) PDH; 2) cwd + version-ranked cache (SPEC-002 CDT-234). Same fail-mode as before.
  EMB=""
  _emb_pr='${CLAUDE_PLUGIN_ROOT}'
  if [ "${_emb_pr#\$}" = "$_emb_pr" ] && [ -f "$_emb_pr/skills/memory-store/embed-one.sh" ]; then
    EMB="$_emb_pr/skills/memory-store/embed-one.sh"
  fi
  [ -n "$EMB" ] || EMB=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/embed-one.sh 2>/dev/null || true)
  if [ -z "$EMB" ]; then
  EMB=$( [ -f skills/memory-store/embed-one.sh ] && echo skills/memory-store/embed-one.sh \
    || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/memory-store/embed-one.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 )
  fi
  MEMORY_ID=""
  if [ -n "$MEMDB_SH" ] && [ -f "$MEMDB_SH" ]; then
    MEMORY_ID=$(bash "$MEMDB_SH" write "$MEMDB" "<AGENT>" "<TYPE>" "$CONTENT" || true)
  fi
  [ -n "$EMB" ] && [ -n "$MEMORY_ID" ] && bash "$EMB" "$MEMDB" "$MEMORY_ID" "$CONTENT" 2>/dev/null || true
else
  # Fallback: append at most 8000 bytes. printf writes the variable, so a
  # content line that looks like a heredoc terminator cannot close the write.
  mkdir -p "$AGENT_MEM"
  _cap=$(printf '%s' "$CONTENT" | head -c 8000)
  printf '%s\n' "$_cap" >> "$AGENT_MEM/<TYPE>.md"
fi
# Context always writes to .md (per-worktree); current-state snapshot, so overwrite.
mkdir -p "$WTROOT/.claude/memory/<AGENT>"
_ctx=$(printf '%s' "$CONTEXT" | head -c 8000)
printf '%s\n' "$_ctx" > "$WTROOT/.claude/memory/<AGENT>/context.md"
```
### Memory search (cross-agent)
```bash
# Semantic + keyword search across ALL agents lives in skills/memory-recall (Steps 3-5).
# Run /memory search <query>, or follow that skill, to search other agents' memory.
```

### Limits
- **SQLite mode:** No line limits. The DB handles storage efficiently.
- **Fallback (.md) mode (per SPEC-004):** cortex 100 lines, memory 50 lines, lessons 80 lines, context 60 lines.
