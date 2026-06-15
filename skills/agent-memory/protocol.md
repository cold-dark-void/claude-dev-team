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

  The ONLY per-agent substitution is `<AGENT>`. `<TYPE>`/`<CONTENT>`/`<content>`/
  `<context>` are write-time placeholders the agent fills (identical across all agents).
  Contracts: write protocol per SPEC-004 + skills/memory-store; read per SPEC-006 +
  skills/memory-recall Step 2; line limits per SPEC-004.
-->
### Path resolution
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
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
DIRECTIVES="$MROOT/.claude/memory/<AGENT>/directives.md"
if [ -s "$DIRECTIVES" ]; then
  echo "## Standing orders for this project"; cat "$DIRECTIVES"
fi
```

### Session start — read memory (tiered)
```bash
if [ "$USE_DB" = "true" ]; then
  HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories
    WHERE agent='<AGENT>' AND tier > 0 AND archived=FALSE;")
  if [ "$HAS_DISTILLED" -gt 0 ]; then
    sqlite3 "$MEMDB" "SELECT type, content FROM memories
      WHERE agent='<AGENT>' AND tier=2 AND archived=FALSE
      ORDER BY type, updated_at DESC;"
    sqlite3 "$MEMDB" "SELECT type, content FROM memories
      WHERE agent='<AGENT>' AND tier=1 AND archived=FALSE
      ORDER BY type, updated_at DESC;"
  else
    sqlite3 "$MEMDB" "SELECT type, content FROM memories
      WHERE agent='<AGENT>' AND tier=0 AND archived=FALSE
      ORDER BY type, created_at DESC;"
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
if [ "$USE_DB" = "true" ]; then
  # Append ONE focused fact/decision/lesson per INSERT. <TYPE> = cortex|memory|lessons.
  ESCAPED=$(printf '%s' "$CONTENT" | sed "s/'/''/g")
  MEMORY_ID=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('<AGENT>', '<TYPE>', '$ESCAPED');
    SELECT last_insert_rowid();") \
    || { sleep 1; MEMORY_ID=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('<AGENT>', '<TYPE>', '$ESCAPED');
      SELECT last_insert_rowid();"); }
  # Best-effort embedding — silently skips when extensions absent. embed-one.sh is a
  # sibling of skills/memory-store/; resolve it (dev checkout first, else installed cache).
  EMB=$( [ -f skills/memory-store/embed-one.sh ] && echo skills/memory-store/embed-one.sh \
    || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/memory-store/embed-one.sh' 2>/dev/null | sort -V | tail -1 )
  [ -n "$EMB" ] && [ -n "$MEMORY_ID" ] && bash "$EMB" "$MEMDB" "$MEMORY_ID" "$CONTENT" 2>/dev/null || true
else
  # Fallback: append to .md (NEVER truncate — append-only contract, SPEC-004)
  mkdir -p "$AGENT_MEM"
  cat >> "$AGENT_MEM/<TYPE>.md" << 'EOF'
<content>
EOF
fi
# Context always writes to .md (per-worktree); current-state snapshot, so overwrite
cat > "$WTROOT/.claude/memory/<AGENT>/context.md" << 'EOF'
<context>
EOF
```

### Memory search (cross-agent)
```bash
# Semantic + keyword search across ALL agents lives in skills/memory-recall (Steps 3-5).
# Run /memory-search <query>, or follow that skill, to search other agents' memory.
```

### Limits
- **SQLite mode:** No line limits. The DB handles storage efficiently.
- **Fallback (.md) mode (per SPEC-004):** cortex 100 lines, memory 50 lines, lessons 80 lines, context 60 lines.
