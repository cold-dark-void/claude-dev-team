#!/usr/bin/env bash
# skills/backlog/linear-gate-test.sh — tests for the one reader of the
# per-project `linear_sync` key (SPEC-009 § Linear sync is opt-in, CDT-646).
# Offline: no network, no LLM, no MCP. Every case drives linear-gate.sh as a
# subprocess against a fresh ${TMPDIR:-/tmp} fixture.
# smoke parses it with `bash -n`; the all-suites runner runs it (SPEC-030).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE="$HERE/linear-gate.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_CEILING_DIRECTORIES="$HERMETIC_ROOT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

# new_root — fixture project with .claude/ and .claude/dev-team/ present.
new_root() {
  local name="$1" root
  root=$(mktemp -d "$TMPDIR/gate-$name.XXXXXX")
  mkdir -p "$root/.claude/dev-team"
  printf '%s\n' "$root"
}

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name" "want '$want' got '$got'"
  fi
}

assert_rc() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name" "want exit $want got $got"
  fi
}

# rc_of <cmd…> — exit code of a gate run.
rc_of() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

CFG_REL=".claude/dev-team/config.json"

# ---------------------------------------------------------------- default off

R=$(new_root default)
assert_eq "status prints off with no config file" "off" "$(bash "$GATE" status --root "$R")"
assert_rc "enabled exits 1 when off" "1" "$(rc_of bash "$GATE" enabled --root "$R")"
assert_eq "no config file was created by a read" "no" "$([ -e "$R/$CFG_REL" ] && echo yes || echo no)"
rm -rf "$R"

# set creates the config dir when the project has only .claude/
R=$(mktemp -d "$TMPDIR/gate-mkdir.XXXXXX")
mkdir -p "$R/.claude"
bash "$GATE" set --root "$R" on >/dev/null
assert_eq "set creates .claude/dev-team when absent" "true" "$(jq -r .linear_sync "$R/$CFG_REL")"
rm -rf "$R"

# ---------------------------------------------------------------- set on/off

R=$(new_root set)
out=$(bash "$GATE" set --root "$R" on)
case "$out" in
  "linear_sync=on: $R/$CFG_REL") pass "set on prints the config path" ;;
  *) fail "set on prints the config path" "got: $out" ;;
esac
assert_eq "set on writes linear_sync true" "true" "$(jq -r .linear_sync "$R/$CFG_REL")"
assert_eq "status reads on" "on" "$(bash "$GATE" status --root "$R")"
assert_rc "enabled exits 0 when on" "0" "$(rc_of bash "$GATE" enabled --root "$R")"
bash "$GATE" set --root "$R" off >/dev/null
assert_eq "set off writes linear_sync false" "false" "$(jq -r .linear_sync "$R/$CFG_REL")"
assert_eq "status reads off after set off" "off" "$(bash "$GATE" status --root "$R")"
# other keys survive the rewrite
jq '.keep_me = "x"' "$R/$CFG_REL" > "$R/tmp.json" && mv "$R/tmp.json" "$R/$CFG_REL"
bash "$GATE" set --root "$R" on >/dev/null
assert_eq "set preserves sibling config keys" "x" "$(jq -r .keep_me "$R/$CFG_REL")"
assert_eq "config dir holds only config.json" "1" "$(ls -1 "$R/.claude/dev-team" | wc -l | tr -d ' ')"
rm -rf "$R"

# ---------------------------------------------------------------- precedence

R=$(new_root precedence)
bash "$GATE" set --root "$R" off >/dev/null
assert_eq "LINEAR_SYNC=on overrides a config off" "on" "$(LINEAR_SYNC=on bash "$GATE" status --root "$R")"
bash "$GATE" set --root "$R" on >/dev/null
assert_eq "LINEAR_SYNC=off overrides a config on" "off" "$(LINEAR_SYNC=off bash "$GATE" status --root "$R")"
rm -rf "$R"

# --------------------------------------------------------- fail-closed values

for junk in "junk" "yes" "0n" "" "  " "enabled" "false2"; do
  R=$(new_root "junk-$(printf '%s' "$junk" | tr -c 'A-Za-z0-9' '_')")
  printf '{"schema":1,"linear_sync":"%s"}\n' "$junk" > "$R/$CFG_REL"
  assert_eq "config value '$junk' reads as off" "off" "$(bash "$GATE" status --root "$R" 2>/dev/null)"
  rm -rf "$R"
done

R=$(new_root broken-json)
printf '{"linear_sync": true\n' > "$R/$CFG_REL"
assert_eq "invalid JSON reads as off" "off" "$(bash "$GATE" status --root "$R" 2>/dev/null)"
assert_rc "set refuses to rewrite invalid JSON" "1" "$(rc_of bash "$GATE" set --root "$R" off)"
assert_eq "refused set left the file untouched" '{"linear_sync": true' "$(cat "$R/$CFG_REL")"
rm -rf "$R"

R=$(new_root missing-key)
printf '{"schema":1}\n' > "$R/$CFG_REL"
assert_eq "absent key reads as off" "off" "$(bash "$GATE" status --root "$R")"
rm -rf "$R"

# No jq on PATH: the read is loud and fail-closed. Shim = symlinks to the
# external tools the gate and portable.sh call, minus jq (same shape as
# skills/backlog/reconcile-test.sh (t)).
SHIM="$TMPDIR/gate-shim-nojq"
mkdir -p "$SHIM"
for tool in bash awk basename dirname grep sed tr rm mv mkdir stat chmod mktemp date sleep; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$real" "$SHIM/$tool"
done
R=$(new_root no-jq)
printf '{"linear_sync": true}\n' > "$R/$CFG_REL"
assert_eq "status reads off with no jq on PATH" "off" "$(PATH="$SHIM" bash "$GATE" status --root "$R" 2>/dev/null)"
assert_eq "status with no jq names the key on stderr" \
  "linear-gate: no jq — linear_sync reads as off" \
  "$(PATH="$SHIM" bash "$GATE" status --root "$R" 2>&1 >/dev/null)"
assert_rc "enabled exits 1 with no jq on PATH" "1" "$(rc_of env PATH="$SHIM" bash "$GATE" enabled --root "$R")"
rm -rf "$R" "$SHIM"

R=$(new_root bool-tokens)
# accepted on-tokens: the JSON booleans/numbers and their string spellings
printf '{"linear_sync": true}\n'  > "$R/$CFG_REL"; assert_eq "config token true reads as on"  "on" "$(bash "$GATE" status --root "$R")"
printf '{"linear_sync": 1}\n'     > "$R/$CFG_REL"; assert_eq "config token 1 reads as on"     "on" "$(bash "$GATE" status --root "$R")"
printf '{"linear_sync": "on"}\n'  > "$R/$CFG_REL"; assert_eq "config token \"on\" reads as on" "on" "$(bash "$GATE" status --root "$R")"
printf '{"linear_sync": "ON"}\n'  > "$R/$CFG_REL"; assert_eq "config token \"ON\" reads as on" "on" "$(bash "$GATE" status --root "$R")"
printf '{"linear_sync": false}\n' > "$R/$CFG_REL"; assert_eq "config token false reads as off" "off" "$(bash "$GATE" status --root "$R")"
printf '{"linear_sync": 0}\n'     > "$R/$CFG_REL"; assert_eq "config token 0 reads as off"     "off" "$(bash "$GATE" status --root "$R")"
printf '{"linear_sync": "off"}\n' > "$R/$CFG_REL"; assert_eq "config token \"off\" reads as off" "off" "$(bash "$GATE" status --root "$R")"
rm -rf "$R"

# ------------------------------------------------------- root resolution rule

R=$(mktemp -d "$TMPDIR/gate-repo.XXXXXX")
git init -q "$R"
mkdir -p "$R/.claude"
git -C "$R" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m seed
git -C "$R" worktree add -q "$R/.worktrees/CDT-1" -b feat/CDT-1 2>/dev/null
bash "$GATE" set --root "$R" on >/dev/null
assert_eq "read from a linked worktree with no --root sees the shared config" "on" \
  "$(cd "$R/.worktrees/CDT-1" && bash "$GATE" status)"
assert_eq "read from the main checkout with no --root" "on" "$(cd "$R" && bash "$GATE" status)"
rm -rf "$R"

# --------------------------------------------------------------- sync: off

R=$(new_root sync-off)
PROOF="$R/proof"
cat > "$R/bridge.sh" <<'EOF'
#!/usr/bin/env bash
touch "$PROOF_MARK"
EOF
chmod +x "$R/bridge.sh"
out=$(PROOF_MARK="$PROOF" bash "$GATE" sync --root "$R" -- "$R/bridge.sh")
assert_eq "sync off prints one skip line" "linear-skip: linear_sync=off — local path only, no Linear call" "$out"
assert_eq "sync off never runs the command" "no" "$([ -e "$PROOF" ] && echo yes || echo no)"
assert_rc "sync off exits 0" "0" "$(rc_of env PROOF_MARK="$PROOF" bash "$GATE" sync --root "$R" -- "$R/bridge.sh")"
rm -rf "$R"

R=$(new_root sync-off-env)
bash "$GATE" set --root "$R" on >/dev/null
PROOF="$R/proof"
out=$(LINEAR_SYNC=off PROOF_MARK="$PROOF" bash "$GATE" sync --root "$R" -- "$R/bridge.sh" 2>&1 || true)
assert_eq "env off skips a config-on project" "no" "$([ -e "$PROOF" ] && echo yes || echo no)"
rm -rf "$R"

# ---------------------------------------------------------------- sync: on

R=$(new_root sync-on)
bash "$GATE" set --root "$R" on >/dev/null
PROOF="$R/proof"
printf '#!/usr/bin/env bash\ntouch "$PROOF_MARK"\n' > "$R/bridge.sh"
chmod +x "$R/bridge.sh"
out=$(PROOF_MARK="$PROOF" bash "$GATE" sync --root "$R" -- "$R/bridge.sh" CDT-9)
assert_eq "sync on prints the command it runs" "linear-sync: $R/bridge.sh CDT-9" "$out"
assert_eq "sync on runs the command" "yes" "$([ -e "$PROOF" ] && echo yes || echo no)"
assert_rc "sync on passes rc 0 through" "0" "$(rc_of env PROOF_MARK="$PROOF" bash "$GATE" sync --root "$R" -- "$R/bridge.sh")"
printf '#!/usr/bin/env bash\nexit 3\n' > "$R/fail.sh"
chmod +x "$R/fail.sh"
assert_rc "sync on passes a failing rc through" "3" "$(rc_of bash "$GATE" sync --root "$R" -- "$R/fail.sh")"
out=$(bash "$GATE" sync --root "$R")
case "$out" in
  "linear-sync: linear_sync=on — session owns the Linear MCP call (local write already committed)")
    pass "sync on with no command says the session owns the MCP call" ;;
  *) fail "sync on with no command says the session owns the MCP call" "got: $out" ;;
esac
rm -rf "$R"

# ------------------------------------------------------------------- usage

R=$(new_root usage)
assert_rc "no arguments exits 64" "64" "$(rc_of bash "$GATE")"
assert_rc "unknown subcommand exits 64" "64" "$(rc_of bash "$GATE" bogus --root "$R")"
assert_rc "set without --root exits 64" "64" "$(rc_of bash "$GATE" set on)"
assert_rc "set with no value exits 64" "64" "$(rc_of bash "$GATE" set --root "$R")"
assert_rc "set with two values exits 64" "64" "$(rc_of bash "$GATE" set --root "$R" on off)"
assert_rc "set with a junk value exits 64" "64" "$(rc_of bash "$GATE" set --root "$R" maybe)"
assert_rc "status with a stray token exits 64" "64" "$(rc_of bash "$GATE" status --root "$R" extra)"
assert_rc "sync with a non-executable command exits 64" "64" "$(rc_of bash "$GATE" sync --root "$R" -- "$R/nope")"
assert_rc "set into a root with no .claude exits 1" "1" "$(rc_of bash "$GATE" set --root "$R/.." on)"
rm -rf "$R"

# ------------------------------------------------------------- no-network

# Executable lines only: the prose of this helper says "sync", which contains
# the letters nc, so comments are stripped before the scan.
NET=$(grep -v '^[[:space:]]*#' "$GATE" \
  | grep -nE 'curl|wget|mcp__|https?://|(^|[;&|[:space:]])(nc|ncat|ssh|telnet)[[:space:]]' || true)
if [ -z "$NET" ]; then pass "gate helper spawns no network tool"
else fail "gate helper spawns no network tool" "$NET"; fi
SRC=$(grep -c 'linear-gate.sh' "$HERE/ticket.sh" || true)
if [ "$SRC" -ge 1 ]; then pass "ticket.sh routes Linear handoff through the gate"
else fail "ticket.sh routes Linear handoff through the gate" "no gate reference in ticket.sh"; fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
