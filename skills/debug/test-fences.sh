#!/usr/bin/env bash
# test-fences.sh — /debug Step 0c path sanitizer and Step 1 reopen lookup.
# Headings: ## Step 0c: Load bug-specific context
#           ### S.1 Theme key + reopen status
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MD="$ROOT/skills/debug/SKILL.md"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

unset GIT_DIR GIT_WORK_TREE
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

nth_matching() { # nth_matching <heading> <grep-needle>
  local n=1 f
  while true; do
    if ! f=$(fence_nth "$MD" "$1" "$n"); then
      return 1
    fi
    if printf '%s\n' "$f" | grep -q "$2"; then
      printf '%s\n' "$f"
      return 0
    fi
    n=$((n + 1))
  done
}

LOGF=$(nth_matching '## Step 0c: Load bug-specific context' 'git log') || LOGF=""
[ -n "$LOGF" ] && ok "Step 0c git-log fence extracts" || bad "Step 0c git-log fence extracts"

REPO="$TMP/repo"
mkdir -p "$REPO/src"
printf '%s\n' 'auth' > "$REPO/src/auth"
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" init -q .
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" add src/auth
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m AUTHLINE

run_log() { # run_log <path> <prefix>
  local text
  text=$(printf '%s\n' "$LOGF" | sed "s|<affected-path>|$1|g")
  fence_exec "$TMP/$2" "$REPO" "$text"
}

run_log src/auth rel
printf '%s\n' "$(cat "$TMP/rel.out")" | grep -q AUTHLINE \
  && ok "relative src/auth survives and git log sees it" || bad "relative path log: $(cat "$TMP/rel.out") $(cat "$TMP/rel.err")"
[ "$RUN_RC" -eq 0 ] && ok "relative path fence exits 0" || bad "relative path fence rc=$RUN_RC"
printf '%s\n' "$(cat "$TMP/rel.err")" | grep -q 'fatal:' \
  && bad "relative path produced a fatal" || ok "relative path has no fatal"

run_log ../outside trav
printf '%s\n' "$(cat "$TMP/trav.out")" | grep -q 'Path traversal' \
  && ok "../outside is rejected" || bad "traversal not rejected"
[ "$RUN_RC" -eq 0 ] && ok "traversal fence exits 0" || bad "traversal fence rc=$RUN_RC"
printf '%s\n' "$(cat "$TMP/trav.err")" | grep -q 'fatal:' \
  && bad "traversal produced a fatal" || ok "traversal has no fatal"

run_log "" empty
printf '%s\n' "$(cat "$TMP/empty.err")" | grep -q 'fatal:' \
  && bad "empty path produced a fatal" || ok "empty path has no fatal"
printf '%s\n' "$(cat "$TMP/empty.out")" | grep -q 'skip git log' \
  && ok "empty path skips git log" || bad "empty path did not skip"
[ "$RUN_RC" -eq 0 ] && ok "empty path fence exits 0" || bad "empty path fence rc=$RUN_RC"

run_log /etc/passwd outside
printf '%s\n' "$(cat "$TMP/outside.out")" | grep -q 'git log skipped' \
  && ok "outside path skips git log" || bad "outside path did not skip"
printf '%s\n' "$(cat "$TMP/outside.out")" | grep -q AUTHLINE \
  && bad "outside path ran git log" || ok "outside path did not log the repo file"
[ "$RUN_RC" -eq 0 ] && ok "outside path fence exits 0" || bad "outside path fence rc=$RUN_RC"

FINDF=$(nth_matching '## Step 0c: Load bug-specific context' 'skip test scan') || FINDF=""
[ -n "$FINDF" ] && ok "Step 0c test-scan fence extracts" || bad "Step 0c test-scan fence extracts"
if [ -n "$FINDF" ]; then
  text=$(printf '%s\n' "$FINDF" | sed 's|<affected-path>|src/auth|g')
  fence_exec "$TMP/findrel" "$REPO" "$text"
  printf '%s\n' "$(cat "$TMP/findrel.err")" | grep -q 'fatal:' \
    && bad "test-scan relative path fatal" || ok "test-scan relative path has no fatal"
  text=$(printf '%s\n' "$FINDF" | sed 's|<affected-path>|../outside|g')
  fence_exec "$TMP/findtrav" "$REPO" "$text"
  printf '%s\n' "$(cat "$TMP/findtrav.out")" | grep -q 'Path traversal' \
    && ok "test-scan rejects ../outside" || bad "test-scan did not reject traversal"
fi

# ---- S.1 reopen lookup (## Step 1: SPEC-029 gates) --------------------------
S1=$(nth_matching '### S.1 Theme key + reopen status' 'theme-status.sh') || S1=""
[ -n "$S1" ] && ok "S.1 fence extracts" || bad "S.1 fence extracts"

plug() {
  local dest="$1"
  mkdir -p "$dest/skills/debug" "$dest/agents"
  cp "$ROOT/skills/plugin-dir.sh" "$dest/skills/plugin-dir.sh"
  cp "$ROOT/skills/debug/theme-status.sh" "$dest/skills/debug/theme-status.sh"
  chmod +x "$dest/skills/plugin-dir.sh" "$dest/skills/debug/theme-status.sh"
  printf '%s\n' '# pm' > "$dest/agents/pm.md"
}

CONS="$TMP/consumer"
mkdir -p "$CONS"
env -u GIT_DIR -u GIT_WORK_TREE git -C "$CONS" init -q .
MKT="$TMP/home-ok/.claude/plugins/marketplaces/dev-team"
plug "$MKT"
fence_exec "$TMP/resolved" "$CONS" "$S1" HOME="$TMP/home-ok"
if printf '%s\n' "$(cat "$TMP/resolved.out")" | grep -q 'THEME_KEY=' \
  && ! printf '%s\n' "$(cat "$TMP/resolved.err" "$TMP/resolved.out")" | grep -q 'theme-status.sh unresolved'; then
  ok "consumer cwd with no CLAUDE_PLUGIN_ROOT resolves theme-status.sh"
else
  bad "resolved lookup out=$(cat "$TMP/resolved.out") err=$(cat "$TMP/resolved.err")"
fi

fence_exec "$TMP/missing" "$CONS" "$S1" HOME="$TMP/home-empty"
blob=$(cat "$TMP/missing.out" "$TMP/missing.err")
printf '%s\n' "$blob" | grep -q 'WARN: theme-status.sh unresolved — SPEC-029 reopen count unavailable' \
  && ok "unresolved helper warns" || bad "missing warn: $blob"
printf '%s\n' "$blob" | grep -q 'REOPEN_COUNT=0' \
  && bad "unresolved helper printed REOPEN_COUNT=0" || ok "unresolved helper does not assert reopen 0"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
