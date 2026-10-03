#!/usr/bin/env bash
# skills/memory-store/test-setup-team-fences.sh — SPEC-005 wp-1-13-setup-team-lembed
# ACs (CDT-261 [10 F1], rv-p0-09 `/setup team` bash). Extracts the bash fences of
# the `/setup team` sub of commands/setup.md (tests/lib/fence.sh) and runs each
# one in a fresh `bash`, the way the host runs a fence: one shell per fence,
# nothing carried over from another fence.
#
#   Steps 2, 2.5, 3, 4  the memory-store scripts (schema.sql, migrate.sh,
#                       download-extensions.sh, migrate-md.sh) are found under
#                       skills/memory-store/, not at the plugin root
#   Step 5              the .gitignore fallback needs no flag from Step 3
#   Step 5.5            no cross-fence variable is exported
#   Step 5b             one fence: SETTINGS and HOSTS_TO_ADD are set in the
#                       fence that uses them, .claude/ is created, no C1 waiver
#   Approval text       the team path asks for the settings merge only (it
#                       never writes bash-compress.sh; /setup orchestration does)
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). The plugin is a fake
# root (CLAUDE_PLUGIN_ROOT) holding the real plugin-dir.sh, schema.sql and
# seed-common.sh and logging stubs for the three scripts that would migrate or
# download. SETUP_MD may name another revision of setup.md (bite-on-old-code
# run); default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP_MD="${SETUP_MD:-$ROOT/commands/setup.md}"

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

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE CLAUDE_PLUGIN_ROOT EMBEDDING_URL

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
FAKE="$WORK/plugin"
STUB_LOG="$WORK/stub.log"
mkdir -p "$FAKE/skills/memory-store" "$FAKE/agents"
cp "$ROOT/skills/plugin-dir.sh" "$FAKE/skills/plugin-dir.sh"
cp "$ROOT/skills/memory-store/schema.sql" "$ROOT/skills/memory-store/seed-common.sh" "$FAKE/skills/memory-store/"
for stub in migrate.sh download-extensions.sh migrate-md.sh; do
  cat > "$FAKE/skills/memory-store/$stub" <<'STUB'
#!/usr/bin/env bash
# logging stub: one line per call, "<script> <argv...>"
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
exit 0
STUB
done

# make_proj <dir> — an empty git repo (no .claude/ yet)
make_proj() {
  mkdir -p "$1" && ( cd "$1" && git init -q . && git commit -q --allow-empty -m init )
}

# run_fence <fence-text> <prefix> [VAR=value ...] — fresh bash, cwd = $PROJ.
# PDH="$FAKE" simulates the host's session carry (WP 7-02): carried fences take
# the root from env; the Step 0 stanza fence re-resolves and ignores it.
run_fence() {
  local text="$1" prefix="$2"
  shift 2
  fence_exec "$prefix" "$PROJ" "$text" CLAUDE_PLUGIN_ROOT="$FAKE" PDH="$FAKE" STUB_LOG="$STUB_LOG" "$@"
}

# run_section <heading> <prefix> [VAR=value ...] — every bash fence of the
# section, in source order, each in its own fresh shell. Sets SECTION_FENCES
# (count) and SECTION_RC (last non-zero fence status, else 0); <prefix>.err and
# <prefix>.out hold all fences' stderr and stdout.
run_section() {
  local heading="$1" prefix="$2" n=1 text
  shift 2
  SECTION_FENCES=0
  SECTION_RC=0
  : > "$prefix.err"
  : > "$prefix.out"
  while text="$(fence_nth "$SETUP_MD" "$heading" "$n")"; do
    run_fence "$text" "$prefix.f$n" "$@"
    [ "$RUN_RC" -eq 0 ] || SECTION_RC="$RUN_RC"
    cat "$prefix.f$n.err" >> "$prefix.err"
    cat "$prefix.f$n.out" >> "$prefix.out"
    n=$((n + 1))
  done
  SECTION_FENCES=$((n - 1))
}

stub_called() { grep -qxF -- "$1" "$STUB_LOG" 2>/dev/null; }
jq_has() { jq -e "$1" "$2" > /dev/null 2>&1; } # jq_has <filter> <file>: filter is truthy
no_missing_file_error() { ! grep -qiE 'no such file|not found|cannot open' "$1.err"; }

PROJ="$WORK/proj"
make_proj "$PROJ" || { echo "FATAL: fixture repo"; exit 1; }
PROJ_REAL="$(cd "$PROJ" && pwd)"

# ---- structural: the team sub exists and its steps have fences --------------
TEAM_FENCES="$(fence_blocks "$SETUP_MD" 'Sub: `team`')"
check "structural: the team sub holds bash fences" [ -n "$TEAM_FENCES" ]
for h in "### Step 1:" "### Step 2: Initialize" "### Step 2.5:" "### Step 3:" "### Step 4:" "### Step 5: Update" "### Step 5.5:" "### Step 5b:"; do
  if [ -n "$(fence_nth "$SETUP_MD" "$h" 1)" ]; then pass_line "structural: '$h' has a bash fence"
  else fail_line "structural: '$h' has a bash fence (zero extracted)"; fi
done

# ---- CDT-261: every script is found under skills/memory-store/ --------------
# Step 1 (already correct before this work package): the regression guard
: > "$STUB_LOG"
run_section "### Step 1:" "$WORK/s1"
check "Step 1: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 1: Plugin dir is <plugin>/skills/memory-store" grep -qxF "Plugin dir: $FAKE/skills/memory-store" "$WORK/s1.out"

# Step 2: real schema.sql from the fake plugin creates the DB
run_section "### Step 2: Initialize" "$WORK/s2"
check "Step 2: exits 0 (rc=$SECTION_RC; err: $(head -c 200 "$WORK/s2.err"))" [ "$SECTION_RC" -eq 0 ]
check "Step 2: no missing-file error on stderr ($(head -c 200 "$WORK/s2.err"))" no_missing_file_error "$WORK/s2"
check "Step 2: memory.db is created at <MROOT>/.claude/memory/memory.db" [ -s "$PROJ/.claude/memory/memory.db" ]
SCHEMA_VER="$(sqlite3 "$PROJ/.claude/memory/memory.db" "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || true)"
check "Step 2: schema.sql was applied (schema_version=$SCHEMA_VER)" [ -n "$SCHEMA_VER" ]
check "Step 2: reports the DB as initialized" grep -qF "SQLite memory DB initialized at" "$WORK/s2.out"

# Step 2.5: migrate.sh gets the project root
: > "$STUB_LOG"
run_section "### Step 2.5:" "$WORK/s25"
check "Step 2.5: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 2.5: migrate.sh (skills/memory-store) runs with MROOT as its argument" stub_called "migrate.sh $PROJ_REAL"
check "Step 2.5: no missing-file error on stderr ($(head -c 200 "$WORK/s25.err"))" no_missing_file_error "$WORK/s25"

# Step 3: download-extensions.sh gets the project root
: > "$STUB_LOG"
run_section "### Step 3:" "$WORK/s3"
check "Step 3: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 3: download-extensions.sh (skills/memory-store) runs with MROOT as its argument" stub_called "download-extensions.sh $PROJ_REAL"
check "Step 3: no missing-file error on stderr ($(head -c 200 "$WORK/s3.err"))" no_missing_file_error "$WORK/s3"

# Step 4: migrate-md.sh gets the project root
: > "$STUB_LOG"
run_section "### Step 4:" "$WORK/s4"
check "Step 4: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 4: migrate-md.sh (skills/memory-store) runs with MROOT as its argument" stub_called "migrate-md.sh $PROJ_REAL"
check "Step 4: no missing-file error on stderr ($(head -c 200 "$WORK/s4.err"))" no_missing_file_error "$WORK/s4"

# A plugin without the script: a warning, no crash, no stub call, exit 0
: > "$STUB_LOG"
mv "$FAKE/skills/memory-store/migrate.sh" "$FAKE/skills/memory-store/migrate.sh.off"
run_section "### Step 2.5:" "$WORK/s25missing"
mv "$FAKE/skills/memory-store/migrate.sh.off" "$FAKE/skills/memory-store/migrate.sh"
check "Step 2.5 with migrate.sh absent: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 2.5 with migrate.sh absent: migrate.sh is not run" [ ! -s "$STUB_LOG" ]

# Linear static check: every $PLUGIN_DIR/<file> literal resolves under skills/memory-store/
plugin_dir_literals() { grep -o '\$PLUGIN_DIR/[A-Za-z0-9._-]*' | sed 's|^\$PLUGIN_DIR/||' | sort -u; }
missing_literals() { # stdin: fence text; prints each literal with no file in the repo
  local f
  plugin_dir_literals | while IFS= read -r f; do
    [ -f "$ROOT/skills/memory-store/$f" ] || printf '%s\n' "$f"
  done
}
LITERALS="$(printf '%s\n' "$TEAM_FENCES" | plugin_dir_literals | tr '\n' ' ')"
check "static: the team fences use \$PLUGIN_DIR/<file> literals (got: $LITERALS)" [ -n "$LITERALS" ]
check "static: every \$PLUGIN_DIR/<file> literal resolves under skills/memory-store/ in the repo" \
  bash -c '[ -z "$1" ]' _ "$(printf '%s\n' "$TEAM_FENCES" | missing_literals)"
check "control: the literal check reports a file that does not exist" \
  bash -c '[ "$1" = "no-such-file.sh" ]' _ "$(printf '%s\n' 'bash "$PLUGIN_DIR/no-such-file.sh" "$MROOT"' | missing_literals)"
# PLUGIN_DIR must not be assigned the plugin root (the CDT-261 defect)
count_root_assign() { grep -c 'PLUGIN_DIR="\$PDH"' || true; }
PLUGIN_DIR_ROOT_LINES="$(printf '%s\n' "$TEAM_FENCES" | count_root_assign)"
check "static: no fence sets PLUGIN_DIR to the plugin root (found $PLUGIN_DIR_ROOT_LINES)" [ "$PLUGIN_DIR_ROOT_LINES" = 0 ]
check "control: the plugin-root check counts a planted old assignment" \
  bash -c '[ "$1" = 1 ]' _ "$(printf '%s\n' 'PLUGIN_DIR="$PDH"' | count_root_assign)"

# ---- rv-p0-09: cross-fence state --------------------------------------------
# Step 5: no flag from Step 3 is needed (each fence is its own shell)
run_section "### Step 5: Update" "$WORK/s5"
check "Step 5: exits 0 with no flag from Step 3 (rc=$SECTION_RC; err: $(head -c 200 "$WORK/s5.err"))" [ "$SECTION_RC" -eq 0 ]
for entry in ".claude/memory/extensions/" ".claude/memory/models/" ".claude/memory/memory.db" ".claude/memory/memory.db-wal" ".claude/memory/memory.db-shm"; do
  check "Step 5: .gitignore holds $entry" grep -qxF "$entry" "$PROJ/.gitignore"
done
count_flag_refs() { grep -c "export $1\|\${$1:-}" || true; } # count_flag_refs <VAR>; stdin: text
# The embed error log (WP 1-13) can quote memory content: it must stay out of git.
# Steps 3 and 5 ensure the child glob .claude/memory/* (SPEC-024 M9), which covers it.
: > "$PROJ/.claude/memory/.errors.log"
check "Step 5: .claude/memory/.errors.log is git-ignored through the .claude/memory/* child glob" \
  bash -c 'cd "$1" && git check-ignore -q .claude/memory/.errors.log' _ "$PROJ"
check "control: a file outside .claude/memory is not git-ignored by the same check" \
  bash -c 'cd "$1" && : > plain-file.txt && ! git check-ignore -q plain-file.txt' _ "$PROJ"
for var in EXT_GITIGNORE_DONE SEED_IMPORT_SUMMARY; do
  hits="$(printf '%s\n' "$TEAM_FENCES" | count_flag_refs "$var")"
  check "static: no team fence exports or reads $var across fences (found $hits)" [ "$hits" = 0 ]
done
check "control: the flag check counts the old Step 3 line and the old Step 5 test" \
  bash -c '[ "$1" = 2 ]' _ "$(printf '%s\n' 'x && export EXT_GITIGNORE_DONE=1' 'if [ -z "${EXT_GITIGNORE_DONE:-}" ]; then' | count_flag_refs EXT_GITIGNORE_DONE)"
check "static: the Step 7 prose does not read \$SEED_IMPORT_SUMMARY" \
  bash -c '! printf "%s\n" "$1" | grep -qF "\$SEED_IMPORT_SUMMARY"' _ "$(md_section "$SETUP_MD" '### Step 7:')"

# Step 5b: one fence; .claude/ is created; settings.json gets the hosts
S5B_TEXT="$(md_section "$SETUP_MD" '### Step 5b:')"
check "Step 5b: no 'lint-ok: C1' waiver in the section" bash -c '! printf "%s\n" "$1" | grep -q "lint-ok: C1"' _ "$S5B_TEXT"
check "control: the waiver check matches a planted waiver" bash -c 'printf "%s\n" "x # lint-ok: C1" | grep -q "lint-ok: C1"'
check "no 'lint-ok: C1' waiver anywhere in the team sub" \
  bash -c '! printf "%s\n" "$1" | grep -q "lint-ok: C1"' _ "$TEAM_FENCES"

P2="$WORK/proj2"
make_proj "$P2" || { echo "FATAL: fixture repo 2"; exit 1; }
PROJ="$P2"
[ ! -e "$P2/.claude" ] || { echo "FATAL: fixture has .claude"; exit 1; }
run_section "### Step 5b:" "$WORK/s5b1"
check "Step 5b: exactly one bash fence, so no variable crosses a fence (found $SECTION_FENCES)" [ "$SECTION_FENCES" -eq 1 ]
check "Step 5b: exits 0 (rc=$SECTION_RC; err: $(head -c 200 "$WORK/s5b1.err"))" [ "$SECTION_RC" -eq 0 ]
check "Step 5b: no redirect error on stderr ($(head -c 200 "$WORK/s5b1.err"))" bash -c '! grep -qiE "no such file|ambiguous redirect" "$1"' _ "$WORK/s5b1.err"
check "Step 5b: .claude/settings.json is written in a project with no .claude/" [ -s "$P2/.claude/settings.json" ]
check "Step 5b: settings.json is valid JSON" jq_has . "$P2/.claude/settings.json"
check "Step 5b: github.com:22 is in sandbox.network.allowedDomains" \
  jq_has '.sandbox.network.allowedDomains | index("github.com:22")' "$P2/.claude/settings.json"
check "Step 5b: reports the host as added" grep -qF "Added github.com:22 to sandbox.network.allowedDomains" "$WORK/s5b1.out"

# a second run adds nothing
run_section "### Step 5b:" "$WORK/s5b2"
check "Step 5b re-run: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 5b re-run: the host is already in the allowlist" grep -qF "github.com:22 already in allowlist" "$WORK/s5b2.out"
check "Step 5b re-run: github.com:22 appears once" \
  bash -c '[ "$(jq "[.sandbox.network.allowedDomains[] | select(. == \"github.com:22\")] | length" "$1")" = 1 ]' _ "$P2/.claude/settings.json"

# an embedding host is added too, and existing settings are kept
P3="$WORK/proj3"
make_proj "$P3" || { echo "FATAL: fixture repo 3"; exit 1; }
mkdir -p "$P3/.claude"
printf '%s\n' '{"permissions":{"defaultMode":"auto"}}' > "$P3/.claude/settings.json"
PROJ="$P3"
run_section "### Step 5b:" "$WORK/s5b3" EMBEDDING_URL=https://embed.example.test/v1/embeddings
check "Step 5b with EMBEDDING_URL: exits 0 (rc=$SECTION_RC)" [ "$SECTION_RC" -eq 0 ]
check "Step 5b with EMBEDDING_URL: the embedding host is in the allowlist" \
  jq_has '.sandbox.network.allowedDomains | index("embed.example.test")' "$P3/.claude/settings.json"
check "Step 5b with EMBEDDING_URL: github.com:22 is in the allowlist" \
  jq_has '.sandbox.network.allowedDomains | index("github.com:22")' "$P3/.claude/settings.json"
check "Step 5b with EMBEDDING_URL: the existing permissions.defaultMode is kept" \
  bash -c '[ "$(jq -r .permissions.defaultMode "$1")" = auto ]' _ "$P3/.claude/settings.json"

# ---- approval text: the team path asks for the settings merge only -----------
# An approval ask names a hook to WRITE; the team path writes none. Prose that
# says where bash-compress.sh lives is fine, so the check is on the ask itself.
TEAM_TEXT="$(md_section "$SETUP_MD" '### Step 5b:')"
check "approval text: the team Step 5b does not ask to approve writing a hook (bash-compress.sh)" \
  bash -c '! printf "%s\n" "$1" | grep -q "Write .claude/hooks/\|permissionDecision"' _ "$TEAM_TEXT"
check "approval text: the team Step 5b still asks for the settings.json merge" \
  bash -c 'printf "%s\n" "$1" | grep -q "Merge into .claude/settings.json"' _ "$TEAM_TEXT"
check "control: the old approval ask (bash-compress.sh) is caught by the same grep" \
  bash -c 'printf "%s\n" "$1" | grep -q "Write .claude/hooks/\|permissionDecision"' _ '  2. Write .claude/hooks/bash-compress.sh (PreToolUse; permissionDecision:allow'
check "control: the orchestration sub does name bash-compress.sh" \
  bash -c 'printf "%s\n" "$1" | grep -q "bash-compress"' _ "$(md_section "$SETUP_MD" 'Sub: `orchestration`')"

echo "---"
echo "setup team fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
