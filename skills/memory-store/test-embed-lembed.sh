#!/usr/bin/env bash
# skills/memory-store/test-embed-lembed.sh — SPEC-004 wp-1-13-setup-team-lembed
# ACs (CDT-262 [07 F-1]: lembed called with a file path instead of a registered
# model name, and the failure hidden). Runs embed-one.sh and migrate-md.sh in
# lembed mode against a fixture project and a sqlite3 shim.
#
#   registration   the model is registered on the connection that calls
#                  lembed(): INSERT INTO temp.lembed_models(name, model)
#                  SELECT 'mini', lembed_model_from_file('<gguf>') comes after
#                  the .load lines and BEFORE every lembed() call; lembed()
#                  gets the model NAME, never a path
#   stored         the vector write goes through (the shim accepts it only
#                  when the name was registered, like the real extension)
#   errors         a failed embed adds one line to <MROOT>/.claude/memory/
#                  .errors.log, the caller still gets exit 0 / its own result
#
# HOST LIMIT: the sqlite-vec (vec0) and sqlite-lembed extensions are not
# installed here, and this suite downloads nothing (a CI round-trip with a
# real model needs its own approval). A sqlite3 shim on PATH therefore stands
# in ONLY for sqlite3 calls that hold a `.load` line or a lembed() call: it
# records the SQL to $SHIM_LOG, refuses a lembed('<name>') whose name was not
# registered earlier in the same call ("Unknown model name", as the extension
# does), and exits 0 otherwise. Every other sqlite3 call runs on the real
# binary against a real fixture DB.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). EMBED_ONE and
# MIGRATE_MD may name another revision of the scripts (bite-on-old-code run);
# default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMBED_ONE="${EMBED_ONE:-$ROOT/skills/memory-store/embed-one.sh}"
MIGRATE_MD="${MIGRATE_MD:-$ROOT/skills/memory-store/migrate-md.sh}"
RECALL_MD="${RECALL_MD:-$ROOT/skills/memory-recall/SKILL.md}"
COMMON="$ROOT/skills/memory-store/embed-common.sh"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init
require_cmd sqlite3 jq

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK/bin"
REAL_SQLITE="$(command -v sqlite3)"
export REAL_SQLITE
SHIM_LOG="$WORK/shim.log"
export SHIM_LOG

# ---- stubs ------------------------------------------------------------------
cat > "$WORK/bin/sqlite3" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for sqlite3 calls that load an extension or call lembed(); all other
# calls run on the real binary. Like the real CLI it reads SQL from stdin only
# when no SQL argument is given (a read loop around it keeps its own stdin).
set -u
n=0; skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -cmd|-init|-separator|-newline|-nullvalue|-mode|-vfs) skip=1 ;;
    -*) ;;
    *) n=$((n + 1)) ;;
  esac
done
in=""
[ "$n" -le 1 ] && in=$(cat)
all=$(printf '%s\n' "$@"; printf '%s\n' "$in")
case "$all" in
  *.load*|*lembed*) ;;
  *)
    if [ "$n" -le 1 ]; then printf '%s\n' "$in" | "$REAL_SQLITE" "$@"; else "$REAL_SQLITE" "$@" < /dev/null; fi
    exit $?
    ;;
esac
{ printf '%s\n' "$all"; printf -- '-----\n'; } >> "$SHIM_LOG"
if [ -n "${SHIM_FAIL_MSG:-}" ]; then
  echo "Error: $SHIM_FAIL_MSG" >&2
  exit 1
fi
# The extension's rule: lembed('<name>', ...) needs <name> registered earlier on this connection.
registered=" "
reg_prefix="INSERT INTO temp.lembed_models(name, model) SELECT '"
while IFS= read -r line; do
  case "$line" in
    "$reg_prefix"*)
      rest=${line#"$reg_prefix"}
      name=${rest%%\'*}
      gguf=${rest#*"lembed_model_from_file('"}
      gguf=${gguf%"');"}  # the path ends at the closing quote, bracket and semicolon
      gguf=${gguf//"''"/"'"}  # a doubled quote in the SQL is one quote in the path
      if [ ! -f "$gguf" ]; then echo "Error: unable to open model file '$gguf'" >&2; exit 1; fi
      registered="$registered$name "
      ;;
  esac
  rest=$line
  while :; do
    case "$rest" in
      *"lembed('"*)
        after=${rest#*"lembed('"}
        nm=${after%%\'*}
        case "$registered" in
          *" $nm "*) ;;
          *) echo "Error: Unknown model name '$nm'. Was it registered with lembed_models?" >&2; exit 1 ;;
        esac
        rest=$after
        ;;
      *) break ;;
    esac
  done
done <<EOF_ALL
$all
EOF_ALL
case "$all" in
  *"vec_to_json(lembed("*)
    [ -n "${SHIM_STDERR_OK:-}" ] && echo "warning: noise on stderr from the extension" >&2
    echo "${SHIM_VEC_OUT:-[0.1,0.2,0.3]}"
    ;;
esac
id=$(printf '%s\n' "$all" | tr '\n' ' ' | sed -n 's/.*INSERT INTO vec_memories_[0-9]*(memory_id, embedding) *VALUES (\([0-9][0-9]*\).*/\1/p')
[ -n "$id" ] && echo "STORED $id" >> "$SHIM_LOG.stored"
exit 0
SHIM
chmod +x "$WORK/bin/sqlite3"
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "${CURL_BODY:-}"
CURL
chmod +x "$WORK/bin/curl"

# ---- fixture ----------------------------------------------------------------
# make_proj <dir> <mode> — MROOT with a real memory.db (schema.sql), one memory
# row (id 1), empty extension files and an empty model file.
make_proj() {
  local d="$1" mode="$2" mem="$1/.claude/memory"
  mkdir -p "$mem/extensions" "$mem/models" "$mem/pm"
  "$REAL_SQLITE" "$mem/memory.db" < "$ROOT/skills/memory-store/schema.sql" > /dev/null || return 1
  "$REAL_SQLITE" "$mem/memory.db" "
    UPDATE config SET value='$mode' WHERE key='embedding_mode';
    INSERT INTO memories(id, agent, type, content) VALUES (1, 'pm', 'memory', 'first memory text to embed');" || return 1
  : > "$mem/extensions/vec0.so"; : > "$mem/extensions/lembed0.so"
  : > "$mem/extensions/vec0.dylib"; : > "$mem/extensions/lembed0.dylib"
  : > "$mem/models/all-MiniLM-L6-v2.gguf"
}
reset_logs() { : > "$SHIM_LOG"; rm -f "$SHIM_LOG.stored"; }
line_of() { grep -n -F -- "$1" "$SHIM_LOG" | head -1 | cut -d: -f1; } # line_of <text>: first line number or empty
lembed_first_args() { grep -oE "lembed\('[^']*'" "$1" | sort -u; } # one line per distinct first argument of a lembed( call
errors_lines() { if [ -f "$1/.claude/memory/.errors.log" ]; then grep -c '' "$1/.claude/memory/.errors.log"; else echo 0; fi; }
run_embed() { # run_embed <proj> <text> — embed-one.sh for memory id 1 under the shim PATH
  ( cd "$1" && env PATH="$WORK/bin:$PATH" bash "$EMBED_ONE" "$1/.claude/memory/memory.db" 1 "$2" ) < /dev/null > "$WORK/embed.out" 2> "$WORK/embed.err"
  RUN_RC=$?
}
model_path() { printf '%s/.claude/memory/models/all-MiniLM-L6-v2.gguf' "$1"; }

# ---- embed-one.sh, lembed mode: register, then lembed('<name>') --------------
P1="$WORK/p1"
make_proj "$P1" lembed || { echo "FATAL: fixture"; exit 1; }
MODEL1="$(model_path "$P1")"
REG1="INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('$MODEL1');"

reset_logs
run_embed "$P1" "it's a memory"
check "embed-one lembed: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "embed-one lembed: the shim saw the call" [ -s "$SHIM_LOG" ]
check "embed-one lembed: the model is registered with its GGUF path" grep -qxF "$REG1" "$SHIM_LOG"
REG_LINE="$(line_of "$REG1")"
CALL_LINE="$(line_of "lembed('mini', ")"
check "embed-one lembed: lembed() is called with the model name, text SQL-escaped" grep -qF "lembed('mini', 'it''s a memory')" "$SHIM_LOG"
check "embed-one lembed: the registration comes before the first lembed() call (lines ${REG_LINE:-none} < ${CALL_LINE:-none})" \
  bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$REG_LINE" "$CALL_LINE"
check "embed-one lembed: registration comes after both .load lines" \
  bash -c 'l=$(grep -n "^\.load .*lembed0" "$1" | head -1 | cut -d: -f1); [ -n "$l" ] && [ "$l" -lt "$2" ]' _ "$SHIM_LOG" "${REG_LINE:-0}"
check "embed-one lembed: the first argument of every lembed() call is the model name (got: $(lembed_first_args "$SHIM_LOG"))" [ "$(lembed_first_args "$SHIM_LOG")" = "lembed('mini'" ]
check "embed-one lembed: the vector write is accepted (registered name), memory 1 stored" grep -qx 'STORED 1' "$SHIM_LOG.stored"
check "embed-one lembed: no .errors.log line after a good embed" [ "$(errors_lines "$P1")" = 0 ]

# a failing embed: one error line, exit 0, nothing thrown at the caller
reset_logs
SHIM_FAIL_MSG='no such table: vec_memories_384' run_embed "$P1" "another memory"
check "embed-one lembed failure: still exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "embed-one lembed failure: one line is added to .errors.log" [ "$(errors_lines "$P1")" = 1 ]
ERRLINE="$(tail -1 "$P1/.claude/memory/.errors.log" 2>/dev/null || true)"
check "embed-one lembed failure: the line is '<UTC ts> embed embed-one memory 1: ...' (got: $ERRLINE)" \
  bash -c 'printf "%s\n" "$1" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z embed embed-one memory 1: "' _ "$ERRLINE"
check "embed-one lembed failure: the line carries the sqlite error text" bash -c 'printf "%s\n" "$1" | grep -qF "no such table: vec_memories_384"' _ "$ERRLINE"

# model file missing: no sqlite call, one error line naming the file
P2="$WORK/p2"
make_proj "$P2" lembed || { echo "FATAL: fixture 2"; exit 1; }
rm -f "$P2/.claude/memory/models/all-MiniLM-L6-v2.gguf"
reset_logs
run_embed "$P2" "no model here"
check "embed-one lembed, model missing: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "embed-one lembed, model missing: sqlite3 is not called" [ ! -s "$SHIM_LOG" ]
check "embed-one lembed, model missing: one error line names the model file" \
  bash -c '[ "$(grep -c "" "$1")" = 1 ] && grep -qF "all-MiniLM-L6-v2.gguf" "$1"' _ "$P2/.claude/memory/.errors.log"

# extension missing: one error line names it
P3="$WORK/p3"
make_proj "$P3" lembed || { echo "FATAL: fixture 3"; exit 1; }
rm -f "$P3/.claude/memory/extensions/lembed0.so" "$P3/.claude/memory/extensions/lembed0.dylib"
reset_logs
run_embed "$P3" "no extension here"
check "embed-one lembed, extension missing: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "embed-one lembed, extension missing: one error line names lembed0" \
  bash -c '[ "$(grep -c "" "$1")" = 1 ] && grep -qF "lembed0" "$1"' _ "$P3/.claude/memory/.errors.log"

# fallback mode: nothing to embed, nothing to log
P4="$WORK/p4"
make_proj "$P4" fallback || { echo "FATAL: fixture 4"; exit 1; }
reset_logs
run_embed "$P4" "keyword only"
check "embed-one fallback mode: exits 0, sqlite3 shim not called, no .errors.log" \
  bash -c '[ "$1" = 0 ] && [ ! -s "$2" ] && [ ! -e "$3" ]' _ "$RUN_RC" "$SHIM_LOG" "$P4/.claude/memory/.errors.log"

# remote mode: an endpoint that returns no vector is logged too (it was silent)
P5="$WORK/p5"
make_proj "$P5" remote || { echo "FATAL: fixture 5"; exit 1; }
"$REAL_SQLITE" "$P5/.claude/memory/memory.db" "INSERT OR REPLACE INTO config(key, value) VALUES ('embedding_url', 'http://127.0.0.1:1/embeddings');"
reset_logs
CURL_BODY='{"oops":1}' run_embed "$P5" "remote text"
check "embed-one remote, no vector in the response: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "embed-one remote, no vector in the response: one error line" \
  bash -c '[ "$(grep -c "" "$1")" = 1 ] && grep -qE " embed embed-one memory 1: " "$1"' _ "$P5/.claude/memory/.errors.log"

# ---- migrate-md.sh, lembed mode: json(lembed('<path>')) -> registered name ----
# Unembedded rows exist (no embedding_meta) and there is no .md file, so the
# script goes straight to its bulk-embedding loop.
run_migrate() { # run_migrate <proj>
  ( cd "$1" && env PATH="$WORK/bin:$PATH" bash "$MIGRATE_MD" "$1" ) < /dev/null > "$WORK/migrate.out" 2> "$WORK/migrate.err"
  RUN_RC=$?
}
P6="$WORK/p6"
make_proj "$P6" lembed || { echo "FATAL: fixture 6"; exit 1; }
MODEL6="$(model_path "$P6")"
REG6="INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('$MODEL6');"
reset_logs
run_migrate "$P6"
check "migrate-md lembed: the model is registered with its GGUF path" grep -qxF "$REG6" "$SHIM_LOG"
M_REG="$(line_of "$REG6")"
M_CALL="$(line_of "lembed('mini', ")"
check "migrate-md lembed: lembed() is called with the model name" grep -qF "lembed('mini', 'first memory text to embed')" "$SHIM_LOG"
check "migrate-md lembed: the registration comes before the lembed() call (lines ${M_REG:-none} < ${M_CALL:-none})" \
  bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$M_REG" "$M_CALL"
check "migrate-md lembed: the vector is read as JSON with vec_to_json() (json() cannot hold a BLOB)" grep -qF "vec_to_json(lembed('mini'" "$SHIM_LOG"
check "migrate-md lembed: the first argument of every lembed() call is the model name (got: $(lembed_first_args "$SHIM_LOG"))" [ "$(lembed_first_args "$SHIM_LOG")" = "lembed('mini'" ]
check "migrate-md lembed: the vector row is written for memory 1" grep -qE "INSERT INTO vec_memories_3\(memory_id, embedding\) VALUES \(1, '\[0\.1,0\.2,0\.3\]'\)" "$SHIM_LOG"
check "migrate-md lembed: no WARN and no .errors.log line after a good embed" \
  bash -c '! grep -q "WARN" "$1" && [ ! -e "$2" ]' _ "$WORK/migrate.out" "$P6/.claude/memory/.errors.log"

P7="$WORK/p7"
make_proj "$P7" lembed || { echo "FATAL: fixture 7"; exit 1; }
reset_logs
SHIM_FAIL_MSG='lembed boom' run_migrate "$P7"
check "migrate-md lembed failure: the run still finishes (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "migrate-md lembed failure: the WARN line is printed for the chunk" grep -qF "WARN: lembed failed for chunk 1" "$WORK/migrate.out"
check "migrate-md lembed failure: one line is added to .errors.log" [ "$(errors_lines "$P7")" = 1 ]
check "migrate-md lembed failure: the line is '<ts> embed migrate-md chunk 1: ...' with the sqlite error" \
  bash -c 'grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z embed migrate-md chunk 1: .*lembed boom" "$1"' _ "$P7/.claude/memory/.errors.log"

# stderr noise from a call that SUCCEEDS must not reach the vector (TL fix: 2>&1 put it in
# $EMBEDDING): the chunk is still embedded and nothing is logged
P8="$WORK/p8"
make_proj "$P8" lembed || { echo "FATAL: fixture 8"; exit 1; }
reset_logs
SHIM_STDERR_OK=1 run_migrate "$P8"
check "migrate-md, stderr noise on success: the run finishes (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "migrate-md, stderr noise on success: the vector row is still written for memory 1" \
  grep -qE "INSERT INTO vec_memories_3\(memory_id, embedding\) VALUES \(1, '\[0\.1,0\.2,0\.3\]'\)" "$SHIM_LOG"
check "migrate-md, stderr noise on success: no WARN and no .errors.log line" \
  bash -c '! grep -q "WARN" "$1" && [ ! -e "$2" ]' _ "$WORK/migrate.out" "$P8/.claude/memory/.errors.log"

# an embedding whose dimension count is empty, 0 or not a number: one log line per chunk, no
# bare `continue`, and (not-JSON) no abort of the whole run under set -e
for bad in '[]' 'not json'; do
  PB="$WORK/pbad$(printf '%s' "$bad" | tr -dc 'a-z' | cut -c1-4)"
  make_proj "$PB" lembed || { echo "FATAL: fixture bad dims"; exit 1; }
  reset_logs
  SHIM_VEC_OUT="$bad" run_migrate "$PB"
  check "migrate-md, embedding '$bad': the run still finishes (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
  check "migrate-md, embedding '$bad': WARN names the chunk and the dimensions" grep -qF "WARN: invalid embedding dimensions" "$WORK/migrate.out"
  check "migrate-md, embedding '$bad': one line '<ts> embed migrate-md chunk 1: invalid embedding dimensions' in .errors.log" \
    bash -c '[ "$(grep -c "" "$1")" = 1 ] && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z embed migrate-md chunk 1: invalid embedding dimensions" "$1"' _ "$PB/.claude/memory/.errors.log"
  check "migrate-md, embedding '$bad': no vector row is written" bash -c '! grep -q "INSERT INTO vec_memories_" "$1"' _ "$SHIM_LOG"
done

# embed-common.sh missing next to migrate-md.sh: a warning, embedding skipped, the .md import still runs
LONE="$WORK/lone"
mkdir -p "$LONE"
cp "$MIGRATE_MD" "$LONE/migrate-md.sh"
P9="$WORK/p9"
make_proj "$P9" lembed || { echo "FATAL: fixture 9"; exit 1; }
mkdir -p "$P9/.claude/memory/qa"
printf '## Notes\nthis is a section of the qa lessons file that is long enough to import\n' > "$P9/.claude/memory/qa/lessons.md"
reset_logs
( cd "$P9" && env PATH="$WORK/bin:$PATH" bash "$LONE/migrate-md.sh" "$P9" ) < /dev/null > "$WORK/migrate.out" 2> "$WORK/migrate.err"
RUN_RC=$?
QA_ROWS="$("$REAL_SQLITE" "$P9/.claude/memory/memory.db" "SELECT COUNT(*) FROM memories WHERE agent='qa' AND type='lessons';")"
check "migrate-md without embed-common.sh: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "migrate-md without embed-common.sh: the .md file is still imported (qa/lessons rows: $QA_ROWS)" [ "$QA_ROWS" = 1 ]
check "migrate-md without embed-common.sh: a warning names the missing file on stderr" grep -qF "embed-common.sh" "$WORK/migrate.err"
check "migrate-md without embed-common.sh: embedding is skipped (sqlite3 shim not called)" [ ! -s "$SHIM_LOG" ]

# ---- embed-common.sh helpers: registration SQL, error counter -----------------
# Run each helper in a subshell that sources the real library.
helper() { ( . "$COMMON" && "$@" ); } # helper <function> [args...]
QUOTED_GGUF="/a/b'c/model.gguf"
check "embed_lembed_register_sql doubles a single quote in the model path" \
  bash -c '[ "$1" = "$2" ]' _ "$(helper embed_lembed_register_sql "$QUOTED_GGUF")" \
  "INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('/a/b''c/model.gguf');"

C1="$WORK/counter"
mkdir -p "$C1"
check "embed_error_count: no .errors.log → 0" bash -c '[ "$1" = 0 ]' _ "$(helper embed_error_count "$C1")"
check "embed_error_count: an empty memdir argument → 0" bash -c '[ "$1" = 0 ]' _ "$(helper embed_error_count "")"
( . "$COMMON"
  embed_log_error "$C1" embed-one "memory 1: first"
  embed_log_error "$C1" migrate-md "chunk 2: second" )
printf '%s\n' '2026-01-01T00:00:00Z other site not an embed line' >> "$C1/.errors.log"
check "embed_error_count: 2 embed lines + 1 foreign line → 2" bash -c '[ "$1" = 2 ]' _ "$(helper embed_error_count "$C1")"
check "embed_error_last: the timestamp of the last embed line" \
  bash -c 'printf "%s\n" "$1" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$" && [ "$1" = "$(awk "\$2 == \"embed\" { t = \$1 } END { print t }" "$2")" ]' _ "$(helper embed_error_last "$C1")" "$C1/.errors.log"

# a project directory whose name holds a single quote: the registration SQL-escapes the model path
PQ="$WORK/p'q"
make_proj "$PQ" lembed || { echo "FATAL: fixture quote"; exit 1; }
MODELQ="$(model_path "$PQ")"
reset_logs
run_embed "$PQ" "quote path"
check "embed-one, model path with a single quote: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "embed-one, model path with a single quote: the path is registered with the quote doubled" \
  grep -qxF "INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('${MODELQ//\'/\'\'}');" "$SHIM_LOG"
check "embed-one, model path with a single quote: the vector write is accepted and nothing is logged" \
  bash -c 'grep -qx "STORED 1" "$1" && [ ! -e "$2" ]' _ "$SHIM_LOG.stored" "$PQ/.claude/memory/.errors.log"

# ---- the three sites agree on the model name ---------------------------------
COMMON_NAME="$(grep -E '^EMBED_LEMBED_NAME=' "$COMMON" | head -1 | sed -E 's/^EMBED_LEMBED_NAME="?([^"]*)"?$/\1/')"
check "embed-common.sh names the model 'mini' (got: $COMMON_NAME)" [ "$COMMON_NAME" = mini ]
check "embed-one.sh and migrate-md.sh build the registration with embed_lembed_register_sql, not a typed copy" \
  bash -c '! grep -q "INSERT INTO temp.lembed_models" "$1" "$2" && grep -q "embed_lembed_register_sql" "$1" && grep -q "embed_lembed_register_sql" "$2"' _ "$ROOT/skills/memory-store/embed-one.sh" "$ROOT/skills/memory-store/migrate-md.sh"
check "control: the typed-copy grep finds the statement in embed-common.sh" \
  grep -q "INSERT INTO temp.lembed_models" "$COMMON"
# memory-recall Step 4 sources embed-common.sh too: skills/memory-recall/test-fences.sh

echo "---"
echo "embed lembed tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
