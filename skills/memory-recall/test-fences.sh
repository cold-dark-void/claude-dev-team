#!/usr/bin/env bash
# skills/memory-recall/test-fences.sh — SPEC-006 / SPEC-021 wp-1-12-fence-state
# ACs (CDT-357 [07 F-7], CDT-263 [07 F-18], CDT-264 memory-recall:106, W2-22).
# Extracts the bash fences of skills/memory-recall/SKILL.md (tests/lib/fence.sh)
# and runs each in a fresh `bash`, the way the host runs a fence: one shell per
# fence, nothing carried over from another fence.
#
#   Step 3  keyword search: % _ ' in the query match literally (LIKE escaped)
#   Step 4  semantic search in each embedding mode (none / remote-stub /
#           lembed): EXT_DIR and MODEL_DIR are set in the fence, .load paths are
#           quoted, the query is captured without shell expansion
#   Step 5  .md fallback: uses the DB when present, grep -F, a query such as
#           $(touch X) executes nothing, a worktree's context.md is searched
#   Step 8  unembedded-memories fence: LIKE escaped
#
# HOST LIMIT: the sqlite-vec (vec0) and sqlite-lembed extensions are not
# installed here. A sqlite3 shim on PATH therefore stands in ONLY for heredoc
# SQL that holds a `.load` line: it records that SQL to $SHIM_LOG (no
# extension is loaded) and exits 0. Every other sqlite3 call runs on the real
# binary against a real fixture DB. The Step 4 assertions for lembed and
# remote mode read the recorded `.load` paths and arguments; a curl stub
# returns a fixed embedding for remote mode.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). SKILL_MD may name
# another revision of SKILL.md (bite-on-old-code run); default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="${SKILL_MD:-$ROOT/skills/memory-recall/SKILL.md}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init
require_cmd sqlite3 git jq
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: "&" in ${v//a/b} is special

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK/bin"
REAL_SQLITE="$(command -v sqlite3)"
export REAL_SQLITE
SHIM_LOG="$WORK/shim.log"
export SHIM_LOG

# The fence resolves MROOT itself (git + cd/pwd); on macOS its spelling of the
# fixture paths differs from this suite's raw mktemp strings (/private/var vs
# /var, TMPDIR trailing slash) — extract each path and compare canonically.
# shellcheck source=../../tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
shim_load_arg() { # quoted argument of the first .load line ending in /<basename>
  sed -n 's/^\.load "\(.*\)"$/\1/p' "$SHIM_LOG" | grep "/$1\$" | head -1
}
reg_model_path() { # model path inside the registration statement's lembed_model_from_file()
  grep "^INSERT INTO temp\.lembed_models(name, model) SELECT 'mini', lembed_model_from_file(" "$SHIM_LOG" \
    | head -1 | sed "s/.*lembed_model_from_file('\([^']*\)').*/\1/"
}

# ---- stubs ------------------------------------------------------------------
cat > "$WORK/bin/sqlite3" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for heredoc SQL that holds a `.load` line; everything else is real.
in=$(cat)
if printf '%s\n' "$in" | grep -q '^\.load'; then
  { printf '%s\n' "$in"; printf -- '-----\n'; } >> "$SHIM_LOG"
  exit 0
fi
if [ -n "$in" ]; then printf '%s\n' "$in" | "$REAL_SQLITE" "$@"; else "$REAL_SQLITE" "$@" < /dev/null; fi
SHIM
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '{"data":[{"embedding":[0.25,0.5,0.75]}]}\n'
CURL
chmod +x "$WORK/bin/sqlite3" "$WORK/bin/curl"

# ---- extract ----------------------------------------------------------------
STEP3="$(fence_nth "$SKILL_MD" "## Step 3: Keyword search" 1)"
STEP4="$(fence_nth "$SKILL_MD" "## Step 4: Semantic search" 1)"
STEP5="$(fence_nth "$SKILL_MD" "## Step 5: Fallback" 1)"
STEP8="$(fence_nth "$SKILL_MD" "## Step 8: Handling" 1)"
for pair in "Step 3:$STEP3" "Step 4:$STEP4" "Step 5:$STEP5" "Step 8:$STEP8"; do
  if [ -n "${pair#*:}" ]; then pass_line "structural: ${pair%%:*} has a bash fence"
  else fail_line "structural: ${pair%%:*} has a bash fence (zero extracted)"; fi
done

# ---- fixture ----------------------------------------------------------------
# A git repo with a real memory.db (schema.sql) and per-agent .md files.
make_repo() { # make_repo <dir> <with-db 1|0>
  local dir="$1" with_db="$2"
  mkdir -p "$dir/.claude/memory/pm" "$dir/.claude/memory/tech-lead"
  ( cd "$dir" && git init -q . && git commit -q --allow-empty -m init ) || return 1
  printf 'plain needle.token line\nother needleXtoken line\n' > "$dir/.claude/memory/pm/memory.md"
  printf 'lessons about $(touch pwned)\n' > "$dir/.claude/memory/tech-lead/lessons.md"
  if [ "$with_db" = 1 ]; then
    "$REAL_SQLITE" "$dir/.claude/memory/memory.db" < "$ROOT/skills/memory-store/schema.sql" > /dev/null || return 1
    "$REAL_SQLITE" "$dir/.claude/memory/memory.db" "
      INSERT INTO memories(agent, type, content, tier) VALUES
        ('pm', 'memory', 'coverage reached 100% this sprint', 0),
        ('pm', 'memory', 'there are 1000 widgets queued', 0),
        ('pm', 'lessons', 'use a_b naming for the flag', 0),
        ('pm', 'lessons', 'axb is a different token', 0),
        ('pm', 'cortex', 'it''s a quote in the note', 0);" || return 1
  fi
}
REPO="$WORK/repo"
NODB="$WORK/repo-nodb"
make_repo "$REPO" 1 || { echo "FATAL: fixture repo"; exit 1; }
make_repo "$NODB" 0 || { echo "FATAL: fixture repo (no db)"; exit 1; }
DB="$REPO/.claude/memory/memory.db"
set_cfg() { "$REAL_SQLITE" "$DB" "UPDATE config SET value='$2' WHERE key='$1';"; }

# run_fence <fence-text> <cwd> <prefix> — substitutes placeholders like the model
# does, runs in a fresh bash under the stub PATH. Sets RUN_RC; output in $prefix.out/.err
run_fence() {
  local text="$1" cwd="$2" prefix="$3" query="${QUERY_TEXT-needle}"
  text="${text//<QUERY>/$query}"
  text="${text//<CURRENT_MODEL>/test-model}"
  : > "$SHIM_LOG"
  fence_exec "$prefix" "$cwd" "$text" PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="${FENCE_PLUGIN_ROOT-$ROOT}"
}
out_has() { grep -qF -- "$1" "$2.out"; }
out_lacks() { ! grep -qF -- "$1" "$2.out"; }

# covers: SPEC-006/T1
# ---- Step 3: keyword search, LIKE escaped ------------------------------------
QUERY_TEXT='100%' run_fence "$STEP3" "$REPO" "$WORK/s3a"
check "Step 3: query '100%' exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "Step 3: '100%' matches the row that holds 100% literally" out_has "coverage reached 100%" "$WORK/s3a"
check "Step 3: '100%' does not match '1000 widgets' (% is not a wildcard)" out_lacks "1000 widgets" "$WORK/s3a"

QUERY_TEXT='a_b' run_fence "$STEP3" "$REPO" "$WORK/s3b"
check "Step 3: 'a_b' matches the row that holds a_b" out_has "use a_b naming" "$WORK/s3b"
check "Step 3: 'a_b' does not match 'axb' (_ is not a wildcard)" out_lacks "axb is a different" "$WORK/s3b"

QUERY_TEXT="it's" run_fence "$STEP3" "$REPO" "$WORK/s3c"
check "Step 3: a query with a single quote still finds the row (rc=$RUN_RC)" out_has "it's a quote" "$WORK/s3c"

rm -f "$WORK/pwned3"
QUERY_TEXT="\$(touch $WORK/pwned3)" run_fence "$STEP3" "$REPO" "$WORK/s3d"
check "Step 3: a query '\$(touch X)' executes nothing" [ ! -e "$WORK/pwned3" ]

# ---- Step 4: semantic search in each embedding mode --------------------------
EXT="$REPO/.claude/memory/extensions"
MODELS="$REPO/.claude/memory/models"

# mode none: a leftover numeric dimension must not pull it into the lembed branch
set_cfg embedding_mode fallback; set_cfg embedding_dimensions 384
QUERY_TEXT='100%' run_fence "$STEP4" "$REPO" "$WORK/s4none"
check "Step 4 none: exits 0 (rc=$RUN_RC; err: $(head -c 160 "$WORK/s4none.err"))" [ "$RUN_RC" -eq 0 ]
check "Step 4 none: reports the keyword fallback" out_has "Using keyword search" "$WORK/s4none"
check "Step 4 none: no .load reaches sqlite3" [ ! -s "$SHIM_LOG" ]
check "Step 4 none: the keyword fallback matches '100%' literally" out_has "coverage reached 100%" "$WORK/s4none"
check "Step 4 none: the keyword fallback does not match '1000 widgets'" out_lacks "1000 widgets" "$WORK/s4none"

# mode lembed: both extension files and the model must resolve from MROOT
mkdir -p "$EXT" "$MODELS"
: > "$EXT/vec0.so"; : > "$EXT/lembed0.so"; : > "$EXT/vec0.dylib"; : > "$EXT/lembed0.dylib"
set_cfg embedding_mode lembed; set_cfg embedding_dimensions 384
QUERY_TEXT="it's fine" run_fence "$STEP4" "$REPO" "$WORK/s4lembed"
check "Step 4 lembed: exits 0 (rc=$RUN_RC; err: $(head -c 160 "$WORK/s4lembed.err"))" [ "$RUN_RC" -eq 0 ]
check "Step 4 lembed: .load vec0 from <MROOT>/.claude/memory/extensions, quoted" \
  [ "$(path_canon "$(shim_load_arg vec0)")" = "$(path_canon "$EXT/vec0")" ]
check "Step 4 lembed: .load lembed0 from <MROOT>/.claude/memory/extensions, quoted" \
  [ "$(path_canon "$(shim_load_arg lembed0)")" = "$(path_canon "$EXT/lembed0")" ]
check "Step 4 lembed: the model is registered (name 'mini') from <MROOT>/.claude/memory/models/all-MiniLM-L6-v2.gguf" \
  [ "$(path_canon "$(reg_model_path)")" = "$(path_canon "$MODELS/all-MiniLM-L6-v2.gguf")" ]
check "Step 4 lembed: lembed() gets the registered NAME, with the query SQL-escaped" grep -qF "lembed('mini', 'it''s fine')" "$SHIM_LOG"
REG_LINE="$(grep -n "^INSERT INTO temp\.lembed_models(name, model) SELECT 'mini', lembed_model_from_file(" "$SHIM_LOG" | head -1 | cut -d: -f1)"
USE_LINE="$(grep -n -F -- "lembed('mini', " "$SHIM_LOG" | head -1 | cut -d: -f1)"
check "Step 4 lembed: the registration comes before the lembed() call, after both .load lines (lines ${REG_LINE:-none} < ${USE_LINE:-none})" \
  bash -c 'l=$(grep -n "^\.load .*lembed0" "$1" | head -1 | cut -d: -f1); [ -n "$l" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$l" -lt "$2" ] && [ "$2" -lt "$3" ]' _ "$SHIM_LOG" "$REG_LINE" "$USE_LINE"
lembed_first_args() { grep -oE "lembed\('[^']*'" "$SHIM_LOG" | sort -u; } # one line per distinct first argument of a lembed( call
check "Step 4 lembed: the first argument of every lembed() call is the model name, never a file path (got: $(lembed_first_args))" \
  [ "$(lembed_first_args)" = "lembed('mini'" ]
check "Step 4 lembed: no .load of a path with an empty root" bash -c '! grep -qE "^\.load \"?/(vec0|lembed0)" "$1"' _ "$SHIM_LOG"
check "Step 4 lembed: no sqlite3 error text on stderr" bash -c '! grep -qiE "cannot open shared object|no such module|parse error" "$1"' _ "$WORK/s4lembed.err"

# The registration statement and the model name come from embed-common.sh, resolved
# through plugin-dir.sh (TL fix: no second hand-typed copy in the fence).
typed_copy_count() { grep -cE "temp\.lembed_models|lembed\('mini'|SELECT 'mini'" || true; } # stdin: fence text
check "Step 4: the fence sources embed-common.sh through plugin-dir.sh" \
  bash -c 'printf "%s\n" "$1" | grep -q "plugin-dir.sh\" file skills/memory-store/embed-common.sh"' _ "$STEP4"
check "Step 4: the fence uses embed_lembed_register_sql and \$EMBED_LEMBED_NAME" \
  bash -c 'printf "%s\n" "$1" | grep -q "embed_lembed_register_sql" && printf "%s\n" "$1" | grep -qF "\$EMBED_LEMBED_NAME"' _ "$STEP4"
check "Step 4: the fence holds no hand-typed registration statement or 'mini' literal (found $(printf '%s\n' "$STEP4" | typed_copy_count))" \
  [ "$(printf '%s\n' "$STEP4" | typed_copy_count)" = 0 ]
check "control: the copy check counts a planted hand-typed registration" \
  bash -c '[ "$1" = 2 ]' _ "$(printf '%s\n' "INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('x');" "WHERE e.embedding MATCH lembed('mini', 'q')" | typed_copy_count)"

# lembed mode, but embed-common.sh does not resolve: keyword search, no .load, exit 0
mkdir -p "$WORK/noplugin/skills"
cp "$ROOT/skills/plugin-dir.sh" "$WORK/noplugin/skills/plugin-dir.sh"
QUERY_TEXT='100%' FENCE_PLUGIN_ROOT="$WORK/noplugin" run_fence "$STEP4" "$REPO" "$WORK/s4nocommon"
check "Step 4 lembed, embed-common.sh unresolved: exits 0 (rc=$RUN_RC; err: $(head -c 160 "$WORK/s4nocommon.err"))" [ "$RUN_RC" -eq 0 ]
check "Step 4 lembed, embed-common.sh unresolved: falls back to keyword search" out_has "Using keyword search" "$WORK/s4nocommon"
check "Step 4 lembed, embed-common.sh unresolved: no .load reaches sqlite3" [ ! -s "$SHIM_LOG" ]
check "Step 4 lembed, embed-common.sh unresolved: the keyword fallback still matches '100%'" out_has "coverage reached 100%" "$WORK/s4nocommon"

# mode remote (curl stub returns a fixed embedding)
set_cfg embedding_mode remote; set_cfg embedding_dimensions 3
set_cfg embedding_url "http://127.0.0.1:1/embeddings"; set_cfg embedding_model "stub-model"
QUERY_TEXT='remote query' run_fence "$STEP4" "$REPO" "$WORK/s4remote"
check "Step 4 remote: exits 0 (rc=$RUN_RC; err: $(head -c 160 "$WORK/s4remote.err"))" [ "$RUN_RC" -eq 0 ]
check "Step 4 remote: .load vec0 from <MROOT>/.claude/memory/extensions, quoted" \
  [ "$(path_canon "$(shim_load_arg vec0)")" = "$(path_canon "$EXT/vec0")" ]
check "Step 4 remote: the vector from the endpoint reaches MATCH" grep -qF "MATCH '[0.25,0.5,0.75]'" "$SHIM_LOG"
check "Step 4 remote: queries the vec_memories_3 table" grep -qF "FROM vec_memories_3 e" "$SHIM_LOG"

# ---- Step 5: .md fallback ------------------------------------------------------
# DB present: the fence must see the DB (USE_DB=true) and not run the grep branch
QUERY_TEXT='needle.token' run_fence "$STEP5" "$REPO" "$WORK/s5db"
check "Step 5 with a DB: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "Step 5 with a DB: uses the DB, so the .md grep fallback prints nothing" [ ! -s "$WORK/s5db.out" ]

# no DB: fixed-string match, with 2 lines of context; '.' is not a wildcard
QUERY_TEXT='needle.token' run_fence "$STEP5" "$NODB" "$WORK/s5nodb"
check "Step 5 no DB: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "Step 5 no DB: prints the agent header for the file that matches" out_has "=== @pm / memory ===" "$WORK/s5nodb"
check "Step 5 no DB: the literal line is shown" out_has "plain needle.token line" "$WORK/s5nodb"
check "Step 5 no DB: 'needle.token' treated as a fixed string still shows context" out_has "other needleXtoken line" "$WORK/s5nodb"

QUERY_TEXT='needle.tokenZ' run_fence "$STEP5" "$NODB" "$WORK/s5none"
check "Step 5 no DB: a regex-only match ('.' as any char) prints nothing" [ ! -s "$WORK/s5none.out" ]

# a query that is shell syntax executes nothing (quoted heredoc capture)
rm -f "$WORK/pwned5"
QUERY_TEXT="\$(touch $WORK/pwned5)" run_fence "$STEP5" "$NODB" "$WORK/s5inj"
check "Step 5: a query '\$(touch X)' executes nothing" [ ! -e "$WORK/pwned5" ]
QUERY_TEXT='`touch '"$WORK"'/pwned5b`' run_fence "$STEP5" "$NODB" "$WORK/s5inj2"
check "Step 5: a backtick query executes nothing" [ ! -e "$WORK/pwned5b" ]
QUERY_TEXT='"; touch '"$WORK"'/pwned5c; echo "' run_fence "$STEP5" "$NODB" "$WORK/s5inj3"
check "Step 5: a quote-breaking query executes nothing" [ ! -e "$WORK/pwned5c" ]
QUERY_TEXT='lessons about $(touch pwned)' run_fence "$STEP5" "$NODB" "$WORK/s5lit"
check "Step 5: shell syntax in a query is matched as literal text" out_has "=== @tech-lead / lessons ===" "$WORK/s5lit"

# a worktree's own context.md is searched (per-worktree file, never in the DB)
WT="$WORK/wt"
( cd "$NODB" && git worktree add -q "$WT" -b wt-branch ) 2>/dev/null
mkdir -p "$WT/.claude/memory/pm"
printf 'worktree-only context line\n' > "$WT/.claude/memory/pm/context.md"
QUERY_TEXT='worktree-only' run_fence "$STEP5" "$WT" "$WORK/s5wt"
check "Step 5 from a worktree: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "Step 5 from a worktree: the worktree's context.md is searched" out_has "=== @pm / context ===" "$WORK/s5wt"

# ---- Step 8: not-yet-embedded memories, LIKE escaped --------------------------
QUERY_TEXT='100%' run_fence "$STEP8" "$REPO" "$WORK/s8"
check "Step 8: exits 0 (rc=$RUN_RC; err: $(head -c 160 "$WORK/s8.err"))" [ "$RUN_RC" -eq 0 ]
check "Step 8: '100%' matches the literal row" out_has "coverage reached 100%" "$WORK/s8"
check "Step 8: '100%' does not match '1000 widgets'" out_lacks "1000 widgets" "$WORK/s8"

echo "---"
echo "memory-recall fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
