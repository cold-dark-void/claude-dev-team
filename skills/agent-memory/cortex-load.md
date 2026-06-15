<!--
  Canonical "load another agent's tiered cortex" fragment — SINGLE SOURCE OF TRUTH.

  This is the ONE authoritative copy of the Step-0 "read agent <AGENT>'s tiered
  cortex" block shared verbatim by the /debug and /refactor skills. It is expanded
  inline into each consumer's Step-0 context-load section between
  `<!-- include: skills/agent-memory/cortex-load.md agent=X -->` / `<!-- /include -->`
  markers (with `<AGENT>` substituted for X). `/release` Step 4.5 drift-checks that
  every marked region equals this file expanded, so the copies can never drift again.

  Markers are placed OUTSIDE the ```bash fence (this partial CARRIES the fence) — the
  P1-5A leak-safe pattern. The block assumes `$USE_DB`, `$MEMDB`, and `$MROOT` are
  already set by the path/USE_DB stanza earlier in Step 0.

  Scope note (AUDIT-P2.7b): the byte-identical pair is /debug and /refactor only, both
  loading agent='tech-lead'. The six other skills that carry a tiered-cortex query
  (kickoff, wrap-ticket, orchestrate, brainstorm, memory-recall, memory-store) load a
  DIFFERENT agent and/or use a different indentation / line-wrapping, so they are NOT
  byte-identical to this region and are deliberately NOT consumers of this partial.
  The ONLY per-consumer substitution is `<AGENT>`.
-->
**b. Tech Lead cortex (tiered memory)**

```bash
if [ "$USE_DB" = "true" ]; then
  HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='<AGENT>' AND tier > 0 AND archived=FALSE;")
  if [ "$HAS_DISTILLED" -gt 0 ]; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<AGENT>' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<AGENT>' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
  else
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<AGENT>' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
  fi
else
  cat "$MROOT/.claude/memory/<AGENT>/cortex.md" 2>/dev/null
fi
```
