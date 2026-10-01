# stats

Display anonymized memory usage metrics. Shows counts and sizes only — no memory content is ever displayed. Safe to share publicly.

## Arguments

- `/memory stats` — show all stats
- `/memory stats --agent <name>` — stats for a single agent

## Step 1: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
```

## Step 2: Check DB exists

If no DB or no sqlite3:
```
Memory stats unavailable — no SQLite DB found.
Run /setup team to initialize.
```

## Step 3: Gather and display stats

Run these queries and format the output:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# This fence is a new shell. Read --agent from the user's words.
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
[ "${1:-}" = "stats" ] && shift
STATS_AGENT=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --agent)
      shift || true
      STATS_AGENT="${1:-}"
      shift || true
      ;;
    *) shift ;;
  esac
done
case "${STATS_AGENT}" in
  "") ;;
  pm|tech-lead|ic5|ic4|devops|qa|ds) ;;
  *) echo "Error: --agent must match the roster" >&2; exit 64 ;;
esac
AGENT_SQL=""
if [ -n "$STATS_AGENT" ]; then
  AGENT_SQL="AND agent='$STATS_AGENT'"
fi
# Per-agent stats (active rows only — archived excluded)
sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" "
SELECT
  agent,
  COUNT(*) AS total_memories,
  SUM(CASE WHEN type='cortex' THEN 1 ELSE 0 END) AS cortex,
  SUM(CASE WHEN type='memory' THEN 1 ELSE 0 END) AS memory,
  SUM(CASE WHEN type='lessons' THEN 1 ELSE 0 END) AS lessons,
  CAST(AVG(LENGTH(content)) AS INTEGER) AS avg_chars,
  MAX(LENGTH(content)) AS max_chars,
  SUM(LENGTH(content)) AS total_chars
FROM memories
WHERE archived = FALSE $AGENT_SQL
GROUP BY agent
ORDER BY total_chars DESC;
"

# Overall summary (active rows only — archived excluded)
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT agent) AS agents,
  SUM(LENGTH(content)) AS total_chars,
  CAST(AVG(LENGTH(content)) AS INTEGER) AS avg_chars,
  MAX(LENGTH(content)) AS max_chars,
  MIN(created_at) AS oldest_memory,
  MAX(created_at) AS newest_memory
FROM memories
WHERE archived = FALSE $AGENT_SQL;
"

# Embedding status. Skip the meta read when the table was never created.
HAS_META=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='embedding_meta';")
if [ "${HAS_META:-0}" = "1" ]; then
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
SELECT
  (SELECT value FROM config WHERE key='embedding_mode') AS mode,
  (SELECT value FROM config WHERE key='embedding_model') AS model,
  (SELECT COUNT(*) FROM embedding_meta) AS embedded_count,
  (SELECT COUNT(*) FROM memories WHERE archived = FALSE $AGENT_SQL) AS total_count;
"
else
  echo "Embeddings: embedding_meta table is absent"
fi

# Embed errors: embed-one.sh and migrate-md.sh append "<UTC ts> embed <site> <detail>"
# to .errors.log for every failed embed. embed_error_count (embed-common.sh, resolved
# through plugin-dir.sh) counts the lines. Never print them: the detail is sqlite
# error text and can quote memory content.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EMBED_COMMON=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/embed-common.sh 2>/dev/null || true)
if [ -n "$EMBED_COMMON" ] && [ -f "$EMBED_COMMON" ]; then
  # shellcheck disable=SC1090
  . "$EMBED_COMMON"
  EMBED_ERRORS=$(embed_error_count "$MROOT/.claude/memory")
else
  EMBED_ERRORS="unavailable (embed-common.sh not found)"
fi
echo "Embed errors: $EMBED_ERRORS"

# Boot load estimate (what agents actually load at session start).
# Mirrors memdb.sh load-session: every non-archived row, all tiers.
# tier0_rows is the unarchived tier-0 tail loaded beside any digest (CDT-336).
sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" "
SELECT
  agent,
  SUM(LENGTH(content)) AS boot_load_chars,
  SUM(CASE WHEN tier = 0 THEN 1 ELSE 0 END) AS tier0_rows,
  CASE
    WHEN SUM(LENGTH(content)) > 10000 THEN '⚠ HIGH'
    WHEN SUM(LENGTH(content)) > 5000 THEN 'moderate'
    ELSE 'ok'
  END AS status
FROM memories
WHERE archived = FALSE $AGENT_SQL
GROUP BY agent
ORDER BY boot_load_chars DESC;
"
```

## Step 4: Format output

```
MEMORY STATS
════════════════════════════════════════════════════════════

Per-agent breakdown:
<per-agent table from query 1>

Summary:
  Total memories:  <N>
  Total agents:    <N>
  Total chars:     <N> (<N/1000>K)
  Avg memory size: <N> chars
  Max memory size: <N> chars
  Oldest memory:   <date>
  Newest memory:   <date>

Embeddings:
  Mode:     <mode> (<model>)
  Embedded: <N>/<total> memories
  Embed errors: <N> (from the "Embed errors:" line; N > 0 → see .claude/memory/.errors.log and run /doctor; "unavailable" → embed-common.sh was not found, reinstall the plugin)

Boot load per agent (chars loaded at session start):
<boot load table>

════════════════════════════════════════════════════════════
Safe to share — no memory content included.
```

---

