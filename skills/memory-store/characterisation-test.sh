#!/usr/bin/env bash
# skills/memory-store/characterisation-test.sh — CDT-253
# Lock /memory stats gather and /memory search (--status + keyword fallback)
# stdout against a fixture DB. Extracts fenced bash from the command before
# the extract, and from the owning skill after.
# Run: bash skills/memory-store/characterisation-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/memory.md"
STATS_SKILL="$HERE/stats.md"
RECALL="$ROOT/skills/memory-recall/SKILL.md"
SCHEMA="$HERE/schema.sql"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

extract_fence_matching() {
  local src="$1" dest="$2" pattern="$3"
  awk -v pat="$pattern" '
    /^```bash[[:space:]]*$/ { inb=1; buf=""; next }
    /^```[[:space:]]*$/ {
      if (inb) {
        inb=0
        if (buf ~ pat) { printf "%s", buf; exit }
      }
      next
    }
    inb { buf = buf $0 "\n" }
  ' "$src" > "$dest"
}

cmp_file() {
  local got="$1" want="$2" label="$3"
  if cmp -s "$got" "$want"; then
    ok "$label"
  else
    bad "$label"
    echo "  --- want ---"; cat -A "$want" | sed 's/^/  /'
    echo "  --- got ---"; cat -A "$got" | sed 's/^/  /'
  fi
}

if [ ! -f "$SCHEMA" ]; then
  echo "error: schema.sql not found at $SCHEMA" >&2
  exit 1
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/mem-char.XXXXXX")
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FIX="$WORKDIR/proj"
mkdir -p "$FIX/.claude/memory"
git -C "$FIX" init -q
git -C "$FIX" config user.email "char@test"
git -C "$FIX" config user.name "char"
sqlite3 "$FIX/.claude/memory/memory.db" <"$SCHEMA" >/dev/null
sqlite3 "$FIX/.claude/memory/memory.db" <<'SQL'
INSERT INTO memories(agent, type, content, tier, archived, created_at, updated_at) VALUES
 ('pm', 'cortex', 'AAA-cortex-content-32-chars!!', 0, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
 ('pm', 'memory', 'BBB-memory-row', 0, 0, '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z'),
 ('ic5', 'lessons', 'CCC-lesson', 0, 0, '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z'),
 ('ic5', 'digest', 'DDD-digest-text-here', 1, 0, '2026-03-01T00:00:00Z', '2026-03-01T00:00:00Z'),
 ('ic5', 'core', 'EEE-core-knowledge', 2, 0, '2026-04-01T00:00:00Z', '2026-04-01T00:00:00Z'),
 ('ic4', 'memory', 'FFF-archived-should-not-appear-in-stats', 0, 1, '2026-05-01T00:00:00Z', '2026-05-01T00:00:00Z');
INSERT INTO embedding_meta(memory_id, model, dimensions, vec_table) VALUES (1, 'none', 0, 'none');
SQL

STATS_SRC="$CMD"
if [ -f "$STATS_SKILL" ] && grep -qF 'Per-agent stats' "$STATS_SKILL"; then
  STATS_SRC="$STATS_SKILL"
fi
STATUS_SRC="$CMD"
if [ -f "$RECALL" ] && grep -qF 'echo "Memory DB:' "$RECALL"; then
  STATUS_SRC="$RECALL"
fi
if [ ! -f "$RECALL" ]; then
  echo "error: skills/memory-recall/SKILL.md missing" >&2
  exit 1
fi

STATS_SH="$WORKDIR/stats.sh"
STATUS_SH="$WORKDIR/status.sh"
STEP4_SH="$WORKDIR/step4.sh"
extract_fence_matching "$STATS_SRC" "$STATS_SH" "Per-agent stats"
extract_fence_matching "$STATUS_SRC" "$STATUS_SH" 'echo "Memory DB:'
extract_fence_matching "$RECALL" "$STEP4_SH" "No embeddings available"

if [ ! -s "$STATS_SH" ]; then
  echo "error: no stats gather fence in $STATS_SRC" >&2
  exit 1
fi
if [ ! -s "$STATUS_SH" ]; then
  echo "error: no search --status fence in $STATUS_SRC" >&2
  exit 1
fi
if [ ! -s "$STEP4_SH" ]; then
  echo "error: no semantic-fallback fence in $RECALL" >&2
  exit 1
fi

run_in_fix() {
  local script="$1" out="$2" err="$3"
  (
    cd "$FIX" || exit 1
    bash "$script"
  ) >"$out" 2>"$err"
  echo $?
}

got_out="$WORKDIR/got-out"
got_err="$WORKDIR/got-err"
want="$WORKDIR/want"

# ---- T1 /memory stats gather (SQL output, archived excluded, boot-load distilled) ----
rc=$(run_in_fix "$STATS_SH" "$got_out" "$got_err")
cat >"$want" <<'EOF'
agent  total_memories  cortex  memory  lessons  avg_chars  max_chars  total_chars
-----  --------------  ------  ------  -------  ---------  ---------  -----------
ic5    3               0       0       1        16         20         48         
pm     2               1       1       0        21         29         43         
5|2|91|18|29|2026-01-01T00:00:00Z|2026-04-01T00:00:00Z
fallback|none|1|6
agent  boot_load_chars  status
-----  ---------------  ------
pm     43               ok    
ic5    38               ok    
EOF
cmp_file "$got_out" "$want" "T1 stats gather stdout"
if [ ! -s "$got_err" ]; then ok "T1 stats stderr empty"; else bad "T1 stats stderr nonempty"; cat -A "$got_err"; fi
if [ "$rc" = "0" ]; then ok "T1 stats exit 0"; else bad "T1 stats exit $rc want 0"; fi

# ---- T2 /memory search --status (path normalised) ----
rc=$(run_in_fix "$STATUS_SH" "$got_out" "$got_err")
sed "s|$FIX/.claude/memory/memory.db|<MEMDB>|g" "$got_out" >"$WORKDIR/got-status"
cat >"$want" <<'EOF'
Memory DB:      <MEMDB>
Embedding mode: fallback (none, 0-dim)
Total memories: 6

agent  raw  digests  core  archived
-----  ---  -------  ----  --------
ic4    0    0        0     1       
ic5    1    1        1     0       
pm     2    0        0     0       
EOF
cmp_file "$WORKDIR/got-status" "$want" "T2 search --status stdout"
if [ ! -s "$got_err" ]; then ok "T2 search --status stderr empty"; else bad "T2 search --status stderr nonempty"; fi
if [ "$rc" = "0" ]; then ok "T2 search --status exit 0"; else bad "T2 search --status exit $rc want 0"; fi

# ---- T3 /memory search --status, no DB ----
NODB="$WORKDIR/nodb"
mkdir -p "$NODB"
git -C "$NODB" init -q
(
  cd "$NODB" || exit 1
  bash "$STATUS_SH"
) >"$got_out" 2>"$got_err"
echo $? >"$WORKDIR/rc-nodb"
cat >"$want" <<'EOF'
Memory DB: not initialized (run /setup team first)
EOF
cmp_file "$got_out" "$want" "T3 search --status no-db stdout"
if [ "$(cat "$WORKDIR/rc-nodb")" = "0" ]; then ok "T3 no-db exit 0"; else bad "T3 no-db exit $(cat "$WORKDIR/rc-nodb") want 0"; fi

# ---- T4 /memory search <query> keyword fallback (no embeddings) ----
(
  cd "$FIX" || exit 1
  QUERY=cortex bash "$STEP4_SH"
) >"$got_out" 2>"$got_err"
echo $? >"$WORKDIR/rc-kw"
cat >"$want" <<'EOF'
[memory-recall] No embeddings available. Using keyword search.
agent  type    tier  snippet                        updated_at          
-----  ------  ----  -----------------------------  --------------------
pm     cortex  0     AAA-cortex-content-32-chars!!  2026-01-01T00:00:00Z
EOF
cmp_file "$got_out" "$want" "T4 search keyword-fallback stdout"
if [ "$(cat "$WORKDIR/rc-kw")" = "0" ]; then ok "T4 search keyword-fallback exit 0"; else bad "T4 search keyword-fallback exit $(cat "$WORKDIR/rc-kw") want 0"; fi

echo ""
echo "characterisation: stats_src=$STATS_SRC status_src=$STATUS_SRC"
echo "characterisation tests: $PASS pass / $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
