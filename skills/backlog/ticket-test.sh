#!/usr/bin/env bash
# skills/backlog/ticket-test.sh — tests for the offline ticket verbs
# (skills/backlog/ticket.sh: create / claim / close over the local store only,
# SPEC-009 § Offline ticket verbs, CDT-646).
# Offline: no network, no LLM, no MCP. Every case drives the verbs as
# subprocesses against a fresh ${TMPDIR:-/tmp} fixture.
# smoke parses it with `bash -n`; the all-suites runner runs it (SPEC-030).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TK="$HERE/ticket.sh"
ADD="$HERE/add.sh"
CLOSE="$HERE/close.sh"
GATE="$HERE/linear-gate.sh"
RECONCILE="$HERE/reconcile.sh"
SWEEP="$HERE/sweep.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_CEILING_DIRECTORIES="$HERMETIC_ROOT"

FAILED_LABELS=""
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; FAILED_LABELS="$FAILED_LABELS$1\n"; FAIL_DETAILS="$FAIL_DETAILS$2\n"; }

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
assert_file_match() {
  local name="$1" file="$2" pat="$3"
  if grep -qE "$pat" "$file" 2>/dev/null; then pass "$name"
  else fail "$name" "pattern /$pat/ not in $file"
  fi
}
rc_of() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# new_project — fixture project root (git repo, .claude/ present, no config).
new_project() {
  local name="$1" root
  root=$(mktemp -d "$TMPDIR/ticket-$name.XXXXXX")
  git init -q "$root"
  mkdir -p "$root/.claude"
  git -C "$root" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m seed
  printf '%s\n' "$root"
}

# bridge <root> — Linear-bridge stub that records the call and proves the local
# write it follows already exists. Writes nothing outside the fixture.
bridge() {
  local root="$1"
  cat > "$root/bridge.sh" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$BRIDGE_COUNT" 2>/dev/null || echo 0)
echo $((n + 1)) > "$BRIDGE_COUNT"
{
  echo "call $n args=$*"
  if [ -d "$BRIDGE_STORE/.claude/backlog" ]; then
    if grep -l '^\*\*Status\*\*: ' "$BRIDGE_STORE"/.claude/backlog/*.md >/dev/null 2>&1; then
      echo "order ok: local item already written"
    else
      echo "order FAIL: no local item at call time"
    fi
  else
    echo "order FAIL: no local store at call time"
  fi
} >> "$BRIDGE_LOG"
EOF
  chmod +x "$root/bridge.sh"
}

# ============================================================ AC1 create (offline)

R=$(new_project create)
out=$(bash "$TK" create --root "$R" --title "Tracker inversion" --problem "Linear is a hard dependency" --goal "Local is the source of truth")
assert_eq "AC1 create prints the item path" "Added: $R/.claude/backlog/tracker-inversion.md" "$(printf '%s\n' "$out" | head -n1)"
assert_eq "AC1 create prints the store path" "store: $R/.claude/backlog" "$(printf '%s\n' "$out" | grep '^store: ')"
assert_file_match "AC1 item carries PENDING" "$R/.claude/backlog/tracker-inversion.md" '^\*\*Status\*\*: PENDING'
assert_file_match "AC1 index row appended" "$R/.claude/backlog.md" '\[Tracker inversion\]\(backlog/tracker-inversion\.md\).*\[PENDING\]'
assert_eq "AC1 plain ticket has no frontmatter" "# Tracker inversion" "$(head -n1 "$R/.claude/backlog/tracker-inversion.md")"

bash "$TK" create --root "$R" --title "Tracker plane" --kind epic >/dev/null
assert_file_match "AC1 epic item carries kind: epic" "$R/.claude/backlog/tracker-plane.md" '^kind: epic$'

bash "$TK" create --root "$R" --title "Offline verbs" --kind child \
  --epic-parent CDT-628 --child-id CDT-628-C7 --estimate M --agent ic4 \
  --depends-on '["CDT-628-C6"]' >/dev/null
F="$R/.claude/backlog/offline-verbs.md"
assert_file_match "AC1 child carries kind: child" "$F" '^kind: child$'
assert_file_match "AC1 child carries epic_parent" "$F" '^epic_parent: CDT-628$'
assert_file_match "AC1 child carries child_id" "$F" '^child_id: CDT-628-C7$'
assert_file_match "AC1 child carries estimate" "$F" '^estimate: M$'
assert_file_match "AC1 child carries agent" "$F" '^agent: ic4$'
assert_file_match "AC1 child carries depends_on" "$F" '^depends_on: \["CDT-628-C6"\]$'
assert_eq "AC1 create left no lock dir" "no" "$([ -e "$R/.claude/backlog.lock" ] && echo yes || echo no)"

# usage errors
assert_rc "AC1 create with no --root exits 64" "64" "$(rc_of bash "$TK" create --title X)"
assert_rc "AC1 unknown verb exits 64" "64" "$(rc_of bash "$TK" destroy --root "$R" x)"
assert_rc "AC1 epic-parent traversal exits 64" "64" "$(rc_of bash "$TK" create --root "$R" --title T --kind child --epic-parent '../../etc')"
assert_rc "AC1 junk --kind exits 64" "64" "$(rc_of bash "$TK" create --root "$R" --title T --kind bogus)"
rm -rf "$R"

# ============================================================== AC2 claim (offline)

R=$(new_project claim)
bash "$TK" create --root "$R" --title "Offline verbs" --kind child --epic-parent CDT-628 --child-id CDT-628-C7 >/dev/null
out=$(bash "$TK" claim --root "$R" offline-verbs --owner ic4)
assert_eq "AC2 claim prints the item path" "Claimed: .claude/backlog/offline-verbs.md" "$(printf '%s\n' "$out" | head -n1)"
assert_eq "AC2 claim prints the store path" "store: $R/.claude/backlog" "$(printf '%s\n' "$out" | grep '^store: ')"
assert_eq "AC2 claim prints the owner" "owner: ic4" "$(printf '%s\n' "$out" | grep '^owner: ')"
assert_file_match "AC2 item status is IN_PROGRESS" "$R/.claude/backlog/offline-verbs.md" '^\*\*Status\*\*: IN_PROGRESS \(ic4\)$'
assert_file_match "AC2 item carries the Claimed footer" "$R/.claude/backlog/offline-verbs.md" '^\*Claimed: [0-9]{4}-[0-9]{2}-[0-9]{2} by ic4\*$'
assert_file_match "AC2 index row re-tagged" "$R/.claude/backlog.md" 'offline-verbs\.md\).*\[IN_PROGRESS\]'
assert_eq "AC2 claimed row stays under Pending" "1" \
  "$(awk '/^## Pending/{p=1} /^## Completed/{p=0} p && /offline-verbs/' "$R/.claude/backlog.md" | wc -l | tr -d ' ')"
assert_eq "AC2 claim frontmatter survives (epic fields)" "child_id: CDT-628-C7" "$(grep '^child_id:' "$R/.claude/backlog/offline-verbs.md")"

out=$(bash "$TK" claim --root "$R" offline-verbs --owner ic4)
assert_eq "AC2 re-claim by the same owner is idempotent" "Already claimed: .claude/backlog/offline-verbs.md" "$(printf '%s\n' "$out" | head -n1)"
assert_eq "AC2 idempotent claim writes no second footer" "1" "$(grep -c '^\*Claimed:' "$R/.claude/backlog/offline-verbs.md")"
assert_eq "AC2 idempotent claim leaves no lock" "no" "$([ -e "$R/.claude/backlog.lock" ] && echo yes || echo no)"

bash "$TK" claim --root "$R" offline-verbs --owner ic5 >/dev/null
assert_eq "AC2 re-claim by a new owner appends one footer" "2" "$(grep -c '^\*Claimed:' "$R/.claude/backlog/offline-verbs.md")"
assert_file_match "AC2 re-claim stamps the new owner" "$R/.claude/backlog/offline-verbs.md" '^\*\*Status\*\*: IN_PROGRESS \(ic5\)$'

bash "$TK" close --root "$R" offline-verbs --ticket CDT-628-C7 >/dev/null
assert_rc "AC2 claim of a closed item exits 1" "1" "$(rc_of bash "$TK" claim --root "$R" offline-verbs --owner ic4)"
assert_rc "AC2 claim of a missing item exits 1" "1" "$(rc_of bash "$TK" claim --root "$R" no-such-ticket)"
bash "$TK" create --root "$R" --title "Offline verbs twin" >/dev/null
# "verbs" is not a slug of its own, so it matches both items: 64, never a pick.
assert_rc "AC2 claim of an ambiguous query exits 64" "64" "$(rc_of bash "$TK" claim --root "$R" verbs)"
assert_rc "AC2 claim with no target exits 64" "64" "$(rc_of bash "$TK" claim --root "$R")"
assert_rc "AC2 claim with a junk owner exits 64" "64" "$(rc_of bash "$TK" claim --root "$R" offline-verbs --owner 'a b$c')"
assert_rc "AC2 claim with a close-only option exits 64" "64" "$(rc_of bash "$TK" claim --root "$R" offline-verbs --ticket X)"
rm -rf "$R"

# IN_PROGRESS is OPEN for every reader (terminal classifier, sweep, reconcile)
R=$(new_project open)
bash "$TK" create --root "$R" --title "Claimed work" >/dev/null
bash "$TK" claim --root "$R" claimed-work --owner ic4 >/dev/null
assert_rc "AC2 IN_PROGRESS is not terminal" "1" "$(rc_of bash "$HERE/terminal-status.sh" is-closed 'IN_PROGRESS (ic4)')"
assert_rc "AC2 IN_PROGRESS is claimed" "0" "$(rc_of bash "$HERE/terminal-status.sh" is-claimed 'IN_PROGRESS (ic4)')"
assert_rc "AC2 IN_PROGRESSX is not the claim stamp" "1" "$(rc_of bash "$HERE/terminal-status.sh" is-claimed 'IN_PROGRESSX')"
out=$(bash "$SWEEP" merge-open --root "$R")
assert_eq "AC2 sweep open set reports the claimed item" "1" "$(printf '%s\n' "$out" | grep -c '"slug":"claimed-work"')"
bash "$RECONCILE" --root "$R" >/dev/null
assert_eq "AC2 reconcile keeps an open claimed item" "yes" "$([ -f "$R/.claude/backlog/claimed-work.md" ] && echo yes || echo no)"
assert_file_match "AC2 reconcile keeps its index row" "$R/.claude/backlog.md" 'claimed-work\.md'
rm -rf "$R"

# ============================================================== AC3 close (offline)

R=$(new_project close)
bash "$TK" create --root "$R" --title "Tracker inversion" >/dev/null
out=$(bash "$TK" close --root "$R" tracker-inversion --ticket CDT-646 --sha abc1234)
assert_eq "AC3 close prints the item path" "Closed: .claude/backlog/tracker-inversion.md" "$(printf '%s\n' "$out" | head -n1)"
assert_eq "AC3 close prints the store path" "store: $R/.claude/backlog" "$(printf '%s\n' "$out" | grep '^store: ')"
assert_file_match "AC3 item status is COMPLETED" "$R/.claude/backlog/tracker-inversion.md" '^\*\*Status\*\*: COMPLETED \(CDT-646\)$'
assert_rc "AC3 close verify passes" "0" "$(rc_of bash "$CLOSE" verify tracker-inversion --root "$R")"
assert_rc "AC3 close of a missing item exits 1" "1" "$(rc_of bash "$TK" close --root "$R" no-such-ticket)"
assert_rc "AC3 close with no target exits 64" "64" "$(rc_of bash "$TK" close --root "$R")"
assert_eq "AC3 close left no lock dir" "no" "$([ -e "$R/.claude/backlog.lock" ] && echo yes || echo no)"
rm -rf "$R"

# ================================================= AC4 gate off = zero Linear work

R=$(new_project gate-off)
bridge "$R"
export BRIDGE_LOG="$R/bridge.log" BRIDGE_COUNT="$R/bridge.count" BRIDGE_STORE="$R"
rm -f "$BRIDGE_LOG"
run_verb() {
  local verb="$1"
  shift
  local out
  out=$(LINEAR_SYNC_CMD="$R/bridge.sh" bash "$TK" "$verb" "$@")
  assert_eq "AC4 $verb → gate skip line, no Linear call" \
    "linear-skip: linear_sync=off — local path only, no Linear call" \
    "$(printf '%s\n' "$out" | tail -n1)"
}
run_verb create --root "$R" --title "Offline verbs" --kind epic
run_verb claim --root "$R" offline-verbs --owner ic4
run_verb close --root "$R" offline-verbs --ticket CDT-646
assert_eq "AC4 the bridge never ran with the gate off" "no" "$([ -e "$BRIDGE_LOG" ] && echo yes || echo no)"
rm -rf "$R"

# =================================================== AC5 gate on = local first

R=$(new_project gate-on)
bridge "$R"
bash "$GATE" set --root "$R" on >/dev/null
export BRIDGE_LOG="$R/bridge.log" BRIDGE_COUNT="$R/bridge.count" BRIDGE_STORE="$R"
LINEAR_SYNC_CMD="$R/bridge.sh" bash "$TK" create --root "$R" --title "Offline verbs" --linear-id CDT-700 >/dev/null
LINEAR_SYNC_CMD="$R/bridge.sh" bash "$TK" claim --root "$R" offline-verbs --owner ic4 >/dev/null
LINEAR_SYNC_CMD="$R/bridge.sh" bash "$TK" close --root "$R" offline-verbs --ticket CDT-700 >/dev/null
assert_eq "AC5 the bridge ran once per verb" "3" "$(cat "$BRIDGE_COUNT")"
assert_eq "AC5 every call saw the local write first" "0" "$(grep -c 'order FAIL' "$BRIDGE_LOG")"
assert_eq "AC5 order proofs" "3" "$(grep -c 'order ok: local item already written' "$BRIDGE_LOG")"
assert_eq "AC5 create passed the linear id to the bridge" "1" "$(grep -c 'args=CDT-700' "$BRIDGE_LOG")"
rm -rf "$R"

# The seam value is split into argv, never glob-expanded: '*' reaches the bridge
# as one literal argument.
R=$(new_project gate-glob)
bridge "$R"
bash "$GATE" set --root "$R" on >/dev/null
export BRIDGE_LOG="$R/bridge.log" BRIDGE_COUNT="$R/bridge.count" BRIDGE_STORE="$R"
LINEAR_SYNC_CMD="$R/bridge.sh *" bash "$TK" create --root "$R" --title "Glob seam" >/dev/null
assert_eq "AC5 the seam argv keeps a glob character literal" "1" "$(grep -c '^call 0 args=\*$' "$BRIDGE_LOG")"
rm -rf "$R"

# env override: on for one run, config untouched
R=$(new_project gate-env)
bridge "$R"
export BRIDGE_LOG="$R/bridge.log" BRIDGE_COUNT="$R/bridge.count" BRIDGE_STORE="$R"
LINEAR_SYNC=on LINEAR_SYNC_CMD="$R/bridge.sh" bash "$TK" create --root "$R" --title "One off sync" >/dev/null
assert_eq "AC5 LINEAR_SYNC=on syncs one run with no config file" "1" "$(cat "$BRIDGE_COUNT")"
assert_eq "AC5 no config file was written by the env override" "no" \
  "$([ -e "$R/.claude/dev-team/config.json" ] && echo yes || echo no)"
rm -rf "$R"

# =========================================================== AC6 zero network

for f in ticket.sh add.sh close.sh linear-gate.sh; do
  HITS=$(grep -v '^[[:space:]]*#' "$HERE/$f" \
    | grep -nE 'curl|wget|mcp__|https?://|(^|[;&|[:space:]])(nc|ncat|ssh|telnet)[[:space:]]' || true)
  if [ -z "$HITS" ]; then pass "AC6 $f spawns no network client and no MCP call"
  else fail "AC6 $f spawns no network client and no MCP call" "$HITS"; fi
done

# ============================================ AC7 the verbs never stage/commit

R=$(new_project git)
bash "$TK" create --root "$R" --title "Tracker inversion" >/dev/null
bash "$TK" claim --root "$R" tracker-inversion --owner ic4 >/dev/null
bash "$TK" close --root "$R" tracker-inversion --ticket CDT-646 >/dev/null
STAGED=$(git -C "$R" diff --cached --name-only)
assert_eq "AC7 no tracker file is staged" "" "$STAGED"
assert_eq "AC7 the verbs made no commit" "1" "$(git -C "$R" rev-list --count HEAD)"
# the plugin repo's own ignore rule keeps the store out of delivery commits
IGNORED=$(git -C "$HERE/../.." check-ignore -v .claude/backlog/x.md .claude/backlog.md .claude/dev-team/config.json 2>/dev/null | wc -l | tr -d ' ')
assert_eq "AC7 backlog store, index, and config are git-ignored in the plugin" "3" "$IGNORED"
rm -rf "$R"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then printf 'FAILED CHECKS:\n%b' "$FAILED_LABELS"; printf 'FAIL DETAILS:\n%b' "$FAIL_DETAILS"; fi
[ "$FAIL" -eq 0 ]
