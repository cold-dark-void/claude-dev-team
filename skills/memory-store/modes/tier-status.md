# Tier status

Canonical per-agent tier counts. `/memory distill --status` and
`/memory search --status` both run this fence. Do not copy the SELECT.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
  "SELECT agent,
    SUM(CASE WHEN tier=0 AND archived=FALSE THEN 1 ELSE 0 END) AS raw,
    SUM(CASE WHEN tier=0 AND archived=TRUE THEN 1 ELSE 0 END) AS archived,
    SUM(CASE WHEN tier=1 AND archived=FALSE THEN 1 ELSE 0 END) AS digests,
    SUM(CASE WHEN tier=2 AND archived=FALSE THEN 1 ELSE 0 END) AS core
  FROM memories GROUP BY agent ORDER BY agent;"
```
