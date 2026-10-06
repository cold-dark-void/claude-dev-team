---
name: memory-recall
description: Search and retrieve agent memories from SQLite DB with semantic or keyword search
user-invocable: false
---

# memory-recall

Search and retrieve memories stored by agents. Supports semantic (vector) search when
embeddings are available, keyword search as a fallback, and `.md` file grep when the DB
is absent entirely.

---

## Step 1: Resolve paths and detect storage mode

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"

USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

---

## Step 2: Load all memories for an agent (session start)

**Single source of truth:** agent session-start (directives → tiered read → context.md)
lives in `skills/agent-memory/protocol.md` and is managed-inline into the 7 behavioral
agents (drift-checked by `skills/agent-memory/sync-includes.py` at `/release`).

Do **not** duplicate that bash here. Contract summary (SPEC-006):

- Load directives first, then tiered memory, then per-worktree `context.md`
- Load tier-2, then tier-1, and every non-archived tier-0 row (`type, content`)
- Always exclude `archived = TRUE`
- Fallback when `USE_DB=false`: cat `cortex` / `memory` / `lessons` `.md` files

This skill owns **cross-agent search** (Steps 3–5+). Session boot uses the protocol partial.

---

## Step 3: Keyword search (cross-agent)

Simple LIKE-based search — no extensions required. Keyword mode returns up to 20 rows
per SPEC-006 (`LIMIT 20`).

Every fence in this skill is a separate shell. Each fence sets its own `MROOT`, `MEMDB`
and `QUERY`; none of them sees a variable from another fence. Replace `<QUERY>` with the
search text. The heredoc delimiter is quoted, so the text is never expanded or executed.

The query is interpolated into SQL, so it MUST be single-quote escaped first (`'`→`''`)
to prevent SQL injection. In a LIKE pattern it MUST also have `\`, `%` and `_` escaped,
so they match literally (`ESCAPED_QUERY` for a string literal, `LIKE_QUERY` for a LIKE
pattern; LIKE uses `ESCAPE '\'`). Every fence that puts the query in SQL defines both:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
QUERY=$(cat <<'QUERY_EOF'
<QUERY>
QUERY_EOF
)
ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
  "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
   FROM memories
   WHERE content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
     AND archived = FALSE
   ORDER BY tier DESC, updated_at DESC
   LIMIT 20;"
```

**Optional agent filter** — append to the WHERE clause:

```bash
# Optional. Check the name, then bind it. Do not paste the name into SQL.
# bash skills/lib/require-agent.sh "$AGENT_FILTER"
# AND agent=?
```

**Optional type filter** — append to the WHERE clause:

```bash
# Add: AND type='<TYPE_FILTER>'
```

---

## Step 4: Semantic search (requires extensions)

Cosine similarity search using stored embeddings. Gracefully degrades to keyword search
when extensions or models are absent.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Same derivation as skills/memory-store/download-extensions.sh (each fence is a new shell).
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"
QUERY=$(cat <<'QUERY_EOF'
<QUERY>
QUERY_EOF
)
EMBED_MODE=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")

EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

# A sidecar hash refuses a tampered extension. No sidecar still allows the load.
ext_ok() {
  local file="$1" side want actual
  [ -f "$file" ] || return 0
  side="$file.sha256"
  [ -f "$side" ] || return 0
  want=$(tr -d '[:space:]' < "$side" | tr 'A-F' 'a-f') || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum -- "$file" | awk '{print $1}' | tr 'A-F' 'a-f')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 -- "$file" | awk '{print $1}' | tr 'A-F' 'a-f')
  else
    return 0
  fi
  [ "$want" = "$actual" ]
}

# lembed needs the model-registration helper in embed-common.sh (SPEC-004). Resolve it
# through plugin-dir.sh; when it does not resolve, this fence uses keyword search.
EMBED_COMMON=""
if [ "$EMBED_MODE" = "lembed" ]; then
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  EMBED_COMMON=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/embed-common.sh 2>/dev/null || true)
  if [ -n "$EMBED_COMMON" ] && [ -f "$EMBED_COMMON" ]; then
    # shellcheck disable=SC1090
    . "$EMBED_COMMON"
  else
    EMBED_COMMON=""
  fi
fi
DIMS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
if [ "$EMBED_MODE" = "lembed" ] && [ -n "$EMBED_COMMON" ] && [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ] && \
   [[ "$DIMS" =~ ^[0-9]+$ ]] && [ "$DIMS" -gt 0 ]; then
  MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"
  VEC_TABLE="vec_memories_${DIMS}"
  if ! ext_ok "$EXT_DIR/vec0.$EXT_SUFFIX" || ! ext_ok "$EXT_DIR/lembed0.$EXT_SUFFIX" || ! ext_ok "$MODEL_PATH"; then
    echo "[memory-recall] extension hash mismatch. Using keyword search."
    ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
    LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
    sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
      "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
       FROM memories WHERE content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
         AND archived = FALSE
       ORDER BY tier DESC, updated_at DESC LIMIT 20;"
    exit 0
  fi
  # Escape the query for SQL interpolation (see Step 3): '→''
  ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
  # lembed() takes a registered model NAME, not a file path. The registration is
  # per connection, so it goes in this same sqlite3 call, before lembed(). The
  # statement and the name come from embed-common.sh (no copy here).
  REGISTER_SQL=$(embed_lembed_register_sql "$MODEL_PATH")
  sqlite3 -cmd ".timeout 5000" "$MEMDB" <<EOSQL
.load "$EXT_DIR/vec0"
.load "$EXT_DIR/lembed0"
$REGISTER_SQL
SELECT m.agent, m.type, m.tier,
       substr(m.content, 1, 200) AS snippet,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id AND m.archived = FALSE
WHERE e.embedding MATCH lembed('$EMBED_LEMBED_NAME', '$ESCAPED_QUERY')
  AND k = 10
ORDER BY m.tier DESC, e.distance ASC;
EOSQL

elif [ "$EMBED_MODE" = "remote" ] && \
     DIMS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';") && \
     [[ "$DIMS" =~ ^[0-9]+$ ]] && [ "$DIMS" -gt 0 ]; then
  EMBED_URL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';")
  EMBED_KEY="${EMBEDDING_API_KEY:-}"
  # Env overrides DB; DB is the durable source when env is unset.
  EMBED_MODEL="${EMBEDDING_MODEL:-$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';")}"
  VEC_TABLE="vec_memories_${DIMS}"
  case "${EMBED_MODEL:-}" in
    ""|none|remote)
      echo "[memory-recall] embedding model is a placeholder. Using keyword search."
      ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
      LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
      sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
        "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
         FROM memories WHERE content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
           AND archived = FALSE
         ORDER BY tier DESC, updated_at DESC LIMIT 20;"
      exit 0
      ;;
  esac

  # Auth header via config file so the key is not on the curl argv.
  CURL_ARGS=(-sS --fail --connect-timeout 5 --max-time 30 --proto '=https,http' "$EMBED_URL" -H "Content-Type: application/json")
  CURL_CONFIG=""
  if [ -n "$EMBED_KEY" ]; then
    CURL_CONFIG=$(mktemp "${TMPDIR:-/tmp}/curl-cfg.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$EMBED_KEY" > "$CURL_CONFIG"
    chmod 600 "$CURL_CONFIG"
    CURL_ARGS+=(-K "$CURL_CONFIG")
    trap 'rm -f -- "$CURL_CONFIG"' EXIT
  fi

  BODY="{\"input\":[$(printf '%s' "$QUERY" | jq -Rs .)]}"
  BODY=$(printf '%s' "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
  CURL_ARGS+=(-d "$BODY")

  RESPONSE=$(curl "${CURL_ARGS[@]}") || RESPONSE=""
  [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"
  QUERY_EMBEDDING=$(echo "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding')

  # $QUERY_EMBEDDING crosses a network trust boundary (remote endpoint) and is
  # interpolated raw into the MATCH clause. Require a bracketed numeric vector —
  # reject anything outside digits . , e E + - space [ ] and fall back to keyword
  # search (']' first and '-' last keep the bracket class literal).
  if [ -z "$QUERY_EMBEDDING" ] || [ "$QUERY_EMBEDDING" = "null" ] || \
     printf '%s' "$QUERY_EMBEDDING" | grep -q '[^][0-9.,eE+ -]'; then
    echo "[memory-recall] Invalid/empty embedding from endpoint. Using keyword search."
    ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
    LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
    sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
      "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
       FROM memories WHERE content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
         AND archived = FALSE
       ORDER BY tier DESC, updated_at DESC LIMIT 20;"
    exit 0
  fi

  if ! ext_ok "$EXT_DIR/vec0.$EXT_SUFFIX"; then
    echo "[memory-recall] extension hash mismatch. Using keyword search."
    ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
    LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
    sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
      "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
       FROM memories WHERE content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
         AND archived = FALSE
       ORDER BY tier DESC, updated_at DESC LIMIT 20;"
    exit 0
  fi

  sqlite3 -cmd ".timeout 5000" "$MEMDB" <<EOSQL
.load "$EXT_DIR/vec0"
SELECT m.agent, m.type, m.tier,
       substr(m.content, 1, 200) AS snippet,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id AND m.archived = FALSE
WHERE e.embedding MATCH '$QUERY_EMBEDDING'
  AND k = 10
ORDER BY m.tier DESC, e.distance ASC;
EOSQL

else
  # Fallback: keyword search
  echo "[memory-recall] No embeddings available. Using keyword search."
  ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
  LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
  sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
    "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
     FROM memories WHERE content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
       AND archived = FALSE
     ORDER BY tier DESC, updated_at DESC LIMIT 20;"
fi
```

---

## Step 5: Fallback (.md grep)

Used when `USE_DB=false`. Searches all agent `.md` files with `grep -F` (the query is
literal text, not a regex). The fence sets `MROOT` before `MEMDB`, so a DB that exists
sets `USE_DB=true` and this step prints nothing. `context.md` is per-worktree and never in
the DB, so a linked worktree's own `.claude/memory/*/context.md` files are searched too.
Replace `<QUERY>` with the search text; the quoted heredoc keeps it from being executed.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
QUERY=$(cat <<'QUERY_EOF'
<QUERY>
QUERY_EOF
)
if [ "$USE_DB" = "false" ]; then
  {
    find "$MROOT/.claude/memory" -mindepth 2 -maxdepth 2 -name '*.md' -type f 2>/dev/null
    if [ "$WTROOT" != "$MROOT" ]; then
      find "$WTROOT/.claude/memory" -mindepth 2 -maxdepth 2 -name 'context.md' -type f 2>/dev/null
    fi
  } | while IFS= read -r FILE || [ -n "$FILE" ]; do
    grep -Fiq -- "$QUERY" "$FILE" || continue
    AGENT=$(basename "$(dirname "$FILE")")
    TYPE=$(basename "$FILE" .md)
    echo "=== @$AGENT / $TYPE ==="
    grep -Fi -C 2 -- "$QUERY" "$FILE"
    echo ""
  done
fi
```

---

## Step 6: Interface summary

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| query | yes | — | Search query string |
| agent | no | all agents | Filter to single agent |
| type | no | all types | Filter to cortex/memory/lessons/digest/core |
| limit | no | semantic 10 / keyword 20 | Max results (SPEC-006: top-10 semantic, up-to-20 keyword) |

**Filtering:** Archived rows (`archived = TRUE`) are **never** returned in any mode
(session load, keyword search, semantic search, or unembedded fallback). This is enforced
at the query level in every step above.

---

## Step 7: Return format

Each result includes:

- `agent` — which agent stored this memory
- `type` — cortex, memory, lessons, digest, or core
- `tier` — 0 (raw), 1 (digest), or 2 (core)
- `snippet` — first 200 chars of content
- `score` — similarity percentage `(1 - distance) * 100` (semantic) or empty (keyword)
- `created_at` — when the memory was stored

---

## Step 8: Handling not-yet-embedded memories

After semantic results, also surface memories that lack embeddings for the current model
(e.g., memories stored before embedding was configured, or stored while extensions were
absent). Replace `<QUERY>`. Read the model name from config `embedding_model`
and single-quote escape it. The query is single-quote escaped
(`ESCAPED_QUERY`) and LIKE-escaped (`LIKE_QUERY`), see Step 3, before interpolation.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
QUERY=$(cat <<'QUERY_EOF'
<QUERY>
QUERY_EOF
)
# Append unembedded memories (keyword match) after semantic results.
# Bind the model name from config. Do not paste a placeholder into SQL.
CURRENT_MODEL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';")
ESCAPED_MODEL=$(printf '%s' "$CURRENT_MODEL" | sed "s/'/''/g")
ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
LIKE_QUERY=$(printf '%s' "$ESCAPED_QUERY" | sed 's/[\\%_]/\\&/g')
sqlite3 -cmd ".timeout 5000" "$MEMDB" <<EOSQL
SELECT m.agent, m.type, m.tier, substr(m.content, 1, 200) AS snippet,
       '[not yet embedded]' AS score, m.created_at
FROM memories m
LEFT JOIN embedding_meta em ON em.memory_id = m.id AND em.model = '$ESCAPED_MODEL'
WHERE em.memory_id IS NULL
  AND m.archived = FALSE
  AND m.content LIKE '%${LIKE_QUERY}%' ESCAPE '\\' COLLATE NOCASE
LIMIT 10;
EOSQL
```

---

## Design notes

- The `MATCH` operator + `k = N` is sqlite-vec's KNN syntax — it is not standard SQL.
- Distance is cosine distance: lower = more similar, 0 = identical. `vec_memories_*` tables are created with `distance_metric=cosine` (`skills/memory-store/vec-cosine.sh`). The L2 default makes `(1 - distance) * 100` negative.
- To convert to similarity percentage: `(1 - distance) * 100`.
- `lembed()` takes a **registered model name**, not a file path. Register the GGUF on the same `sqlite3` connection first: `INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('<gguf path>');`. Then call `lembed('mini', <text>)`. `temp.lembed_models` is per connection.
- For remote embedding providers, the URL is read from the DB config (`embedding_url`).
  Model: `EMBEDDING_MODEL` env if set, else config `embedding_model`. Optional
  `EMBEDDING_API_KEY` for authenticated providers.
- `jq` is required for remote embedding extraction and request building.
- Vec0 virtual tables (`vec_memories_384`, `vec_memories_768`) are only accessible when
  the sqlite-vec extension is loaded. Always guard vec0 operations with an extension
  availability check.
- The `USE_DB` guard (Step 1) must wrap all DB operations — fall through to `.md` grep
  (Step 5) whenever `USE_DB=false`.
