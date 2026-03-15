# /memory-search
Search across all agent memories using the best available method.

## Usage
/memory-search <query>
/memory-search --status

## Flags
| Flag | Description |
|------|-------------|
| `<query>` | Text to search for across all agent memories |
| `--status` | Show memory DB status: mode, embedding config, and per-agent row counts |

## Examples

Search for memories about authentication:
```
/memory-search authentication token
```
Output (semantic mode):
```
MEMORY SEARCH: "authentication token"  [semantic/lembed]
════════════════════════════════════════════

@tech-lead / cortex  (94%)  2026-01-14 11:32:00
  JWT tokens expire after 15 minutes. Refresh tokens stored in httpOnly cookies...

@ic4 / memory  (87%)  2026-01-13 09:10:00
  Auth middleware expects Authorization header with Bearer prefix...

════════════════════════════════════════════
Results: 2 matches
```

Check the current memory backend and embedding configuration:
```
/memory-search --status
```
Output:
```
Memory DB:      /home/user/project/.claude/memory/memory.db
Embedding mode: lembed (all-MiniLM-L6-v2, 384-dim)
Total memories: 143

agent       raw  digests  core  archived
----------  ---  -------  ----  --------
ic4          12        2     1         0
pm           10        3     1         8
tech-lead     9        2     0         6
```

Search when no DB is available (grep fallback):
```
/memory-search database migration
```
Output:
```
MEMORY SEARCH: "database migration"  [grep / .md files]
════════════════════════════════════════════

@tech-lead / cortex.md:
  schema migrations run via golang-migrate
  -- database migration --
  always run migrate up before deploying

════════════════════════════════════════════
```

## How It Works
`/memory-search` auto-detects the best search method available in the current environment. If the SQLite memory database exists and vector extensions are loaded, it uses **semantic search** — embedding the query and finding the closest matching memories by cosine similarity, returning a relevance score per result. If the DB exists but embeddings are not configured, it falls back to **keyword search** using SQL `LIKE` matching. If no DB is present at all, it falls back to **grep** across the `.md` memory files in each agent's directory.

Results from DB-backed modes are sorted by tier (core first, then digests, then raw) and then by relevance score, so the highest-value memories surface first. Archived memories are excluded from all searches.

## See Also
- [/memory-distill](memory-distill.md) — compress raw memories to keep search results clean
- [/memory-config](memory-config.md) — configure distillation and embedding settings
