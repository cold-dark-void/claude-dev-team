# search

Search all agent memories. Auto-detects the best available mode:
semantic (vector embeddings) → keyword (SQLite LIKE) → grep (.md files).

## Arguments

- `/memory search <query>` — search for memories related to the query
- `/memory search --status` — show memory DB status (mode, row counts)
- `/memory search` (no args) — print usage

## Step 1: Parse arguments

If no arguments provided, print:
```
Usage: /memory search <query>
       /memory search --status

Searches all agent memories using the best available method:
  - Semantic search (vector embeddings) when DB + embeddings configured
  - Keyword search (SQLite LIKE) when DB exists but no embeddings
  - Grep search (.md files) when no DB available
```
And stop.

## Step 2: Handle --status flag

If remaining arguments contain `--status`:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
if [ ! -f "$MEMDB" ]; then
  echo "Memory DB: not initialized (run /setup team first)"
  exit 0
fi

EMBED_MODE=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")
MODEL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';")
DIMS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
TOTAL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories;")

EMBED_URL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)

echo "Memory DB:      $MEMDB"
echo "Embedding mode: $EMBED_MODE ($MODEL, ${DIMS}-dim)"
[ -n "$EMBED_URL" ] && echo "Embedding URL:  $EMBED_URL"
echo "Total memories: $TOTAL"
echo ""
# Tier columns live in skills/memory-store/modes/tier-status.md. Run that fence.
# Do not copy the SELECT into this file.
```
And stop.

## Step 3: Search (skill-delegate)

Read and follow `skills/memory-recall/SKILL.md` with the remaining args as the query
(and any optional agent/type/limit filters the skill documents). That skill owns
path resolution, mode detection (semantic/lembed → semantic/remote → keyword →
grep), result formatting, and unembedded fallbacks.

Pass-through: `/memory search <query>` → skill query=`<query>`.

---

