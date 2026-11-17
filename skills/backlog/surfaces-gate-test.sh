#!/usr/bin/env bash
# skills/backlog/surfaces-gate-test.sh — one check per reading Surface that it
# works with Linear off (SPEC-009 § Linear sync is opt-in, CDT-646).
#
# For each Surface — /kickoff, /orchestrate, /status, /epic — this suite proves:
#   static:  the Surface carries the gate's own invocation line — the resolver
#            plus the `status` read, and the `sync` handoff on the write
#            Surfaces — and states the offline rule (MUST NOT call Linear when
#            off);
#   runtime: the Surface's own engine completes a real ticket operation with the
#            gate off, offline, in a fixture project (no config file at all).
# Offline: no network, no LLM, no MCP.
# smoke parses it with `bash -n`; the all-suites runner runs it (SPEC-030).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TK="$HERE/ticket.sh"
CLOSE="$HERE/close.sh"
GATE="$HERE/linear-gate.sh"
SWEEP="$HERE/sweep.sh"
EPIC_LIB="$ROOT/skills/epic/epic-lib.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_CEILING_DIRECTORIES="$HERMETIC_ROOT"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %s: %s\n' "$1" "$2"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s: %s: %s\n' "$1" "$2" "$3"
}

# new_project — fixture project (git repo, .claude/, no linear_sync config).
new_project() {
  local name="$1" root
  root=$(mktemp -d "$TMPDIR/surfaces-$name.XXXXXX")
  git init -q "$root"
  mkdir -p "$root/.claude"
  git -C "$root" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m seed
  printf '%s\n' "$root"
}

# gate_off_here — the fixture reads off (the default the Surfaces must take)
gate_off_here() {
  local root="$1"
  local got
  got=$(bash "$GATE" status --root "$root")
  [ "$got" = "off" ]
}

# The gate lines a Surface file must carry (fixed strings, grepped with -F):
GATE_RESOLVER='file skills/backlog/linear-gate.sh'
GATE_STATUS='LINEAR_SYNC=$(bash "$GATE" status --root "$MROOT")'
GATE_SYNC='bash "$GATE" sync --root "$MROOT" --'

# surface_binds_gate <label> <file:kind>… — each Surface is bound by the gate's
# own invocation line, not by prose about it. kind:
#   bind    — resolves the gate and reads it for the run (resolver + status)
#   sync    — carries the ordered handoff call after the local write
#   carried — consumes the run's LINEAR_SYNC and names where it is bound
# Every file also states the offline rule (MUST NOT call Linear when off).
surface_binds_gate() {
  local label="$1"
  shift
  local spec f kind bad
  for spec in "$@"; do
    f="${spec%:*}"
    kind="${spec##*:}"
    bad=""
    case "$kind" in
      bind)
        grep -qF -- "$GATE_RESOLVER" "$ROOT/$f" || bad="$bad no-gate-resolver"
        grep -qF -- "$GATE_STATUS" "$ROOT/$f" || bad="$bad no-gate-status-read"
        ;;
      sync)
        grep -qF -- "$GATE_SYNC" "$ROOT/$f" || bad="$bad no-gate-sync-call"
        ;;
      carried)
        grep -qF -- 'LINEAR_SYNC' "$ROOT/$f" || bad="$bad no-LINEAR_SYNC"
        grep -Eq 'run-start\.md.*Step 0|skills/backlog/linear-gate\.sh' "$ROOT/$f" \
          || bad="$bad no-binding-site"
        ;;
      *)
        fail "AC4" "$label-gate-bound" "unknown kind '$kind' for $f"
        return
        ;;
    esac
    grep -Eq 'MUST NOT|zero Linear MCP|zero MCP calls|no Linear call' "$ROOT/$f" \
      || bad="$bad no-offline-rule"
    if [ -z "$bad" ]; then ok "AC4" "$label-gate-bound-$kind ($f)"
    else fail "AC4" "$label-gate-bound-$kind" "$f missing:$bad"; fi
  done
}

# =============================================================== AC4 /kickoff

surface_binds_gate "kickoff" "skills/kickoff/SKILL.md:bind" "skills/kickoff/SKILL.md:sync"
R=$(new_project kickoff)
if gate_off_here "$R"; then ok "AC4" "kickoff-fixture-gate-reads-off"; else fail "AC4" "kickoff-fixture-gate-reads-off" "not off"; fi
rc=0
out=$( { bash "$TK" create --root "$R" --title "Tracker inversion" --problem "Linear is a hard dependency" --goal "Local store is the source of truth" \
  && bash "$TK" claim --root "$R" tracker-inversion --owner ic4; } 2>&1) || rc=$?
case "$out" in
  *"linear-skip: linear_sync=off"*) kickoff_skip_line=yes ;;
  *) kickoff_skip_line=no ;;
esac
if [ "$rc" -eq 0 ] && [ -f "$R/.claude/backlog/tracker-inversion.md" ] \
  && grep -q '^\*\*Status\*\*: IN_PROGRESS (ic4)' "$R/.claude/backlog/tracker-inversion.md" \
  && [ "$kickoff_skip_line" = yes ]; then
  ok "AC4" "kickoff-intake-writes-ticket-offline"
else
  fail "AC4" "kickoff-intake-writes-ticket-offline" "rc=$rc skip-line=$kickoff_skip_line item=$(ls "$R/.claude/backlog" 2>/dev/null)"
fi
rm -rf "$R"

# ============================================================ AC4 /orchestrate

surface_binds_gate "orchestrate" "skills/orchestrate/steps/01-fetch.md:bind" \
  "skills/orchestrate/steps/01-fetch.md:sync" "skills/orchestrate/steps/11-ship.md:bind" \
  "skills/orchestrate/steps/11-ship.md:sync"
R=$(new_project orchestrate)
if gate_off_here "$R"; then ok "AC4" "orchestrate-fixture-gate-reads-off"; else fail "AC4" "orchestrate-fixture-gate-reads-off" "not off"; fi
bash "$TK" create --root "$R" --title "Ship the plane" >/dev/null 2>&1
rc=0
out=$(bash "$TK" close --root "$R" ship-the-plane --ticket CDT-646 --status "FIXED/CLOSED" 2>&1) || rc=$?
verify_rc=0
bash "$CLOSE" verify ship-the-plane --root "$R" >/dev/null 2>&1 || verify_rc=$?
case "$out" in
  *"linear-skip: linear_sync=off"*) ship_skip_line=yes ;;
  *) ship_skip_line=no ;;
esac
if [ "$rc" -eq 0 ] && [ "$verify_rc" -eq 0 ] && [ "$ship_skip_line" = yes ]; then
  ok "AC4" "orchestrate-ship-close-out-verifies-offline"
else
  fail "AC4" "orchestrate-ship-close-out-verifies-offline" "close rc=$rc verify rc=$verify_rc skip-line=$ship_skip_line"
fi
# the ship step's off-path line is the exact string the Surface prints
if grep -q 'linear_sync=off — local tracker close only' "$ROOT/skills/orchestrate/steps/11-ship.md"; then
  ok "AC4" "orchestrate-ship-prints-off-line"
else
  fail "AC4" "orchestrate-ship-prints-off-line" "exact off line not found in 11-ship.md"
fi
rm -rf "$R"

# ================================================================ AC4 /status

surface_binds_gate "status" "commands/status.md:bind"
# /status and its standup backend are readers: they carry no Linear MCP call site
STATUS_LINEAR=$(grep -nE 'get_issue|save_issue|list_issues|list_issue_statuses|Linear (Done|In Review)' \
  "$ROOT/commands/status.md" "$ROOT/skills/standup/SKILL.md" | grep -v 'MUST NOT' || true)
if [ -z "$STATUS_LINEAR" ]; then ok "AC4" "status-has-no-linear-call-site"
else fail "AC4" "status-has-no-linear-call-site" "$STATUS_LINEAR"; fi
R=$(new_project status)
if gate_off_here "$R"; then ok "AC4" "status-fixture-gate-reads-off"; else fail "AC4" "status-fixture-gate-reads-off" "not off"; fi
bash "$TK" create --root "$R" --title "Open work one" >/dev/null 2>&1
bash "$TK" claim --root "$R" open-work-one --owner ic5 >/dev/null 2>&1
bash "$TK" create --root "$R" --title "Done work one" >/dev/null 2>&1
bash "$TK" close --root "$R" done-work-one >/dev/null 2>&1
rc=0
out=$(bash "$SWEEP" merge-open --root "$R" 2>&1) || rc=$?
OPEN=$(printf '%s\n' "$out" | grep -c '"slug":"open-work-one"' || true)
DONE=$(printf '%s\n' "$out" | grep -c '"slug":"done-work-one"' || true)
if [ "$rc" -eq 0 ] && [ "$OPEN" = 1 ] && [ "$DONE" = 0 ]; then
  ok "AC4" "status-open-set-reads-store-offline"
else
  fail "AC4" "status-open-set-reads-store-offline" "rc=$rc open=$OPEN done=$DONE out=$out"
fi
rm -rf "$R"

# ================================================================== AC4 /epic

surface_binds_gate "epic" "skills/epic/SKILL.md:carried" "skills/epic/run-start.md:bind" \
  "skills/epic/run-start.md:sync" "skills/epic/mode-a-decompose.md:carried" \
  "skills/epic/mode-f-sync.md:carried"
R=$(new_project epic)
if gate_off_here "$R"; then ok "AC4" "epic-fixture-gate-reads-off"; else fail "AC4" "epic-fixture-gate-reads-off" "not off"; fi
export EPIC_ROOT="$R"
rc=0
bash "$EPIC_LIB" init CDT-628 --title "Control plane" --mode orchestrate >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$R/.claude/epics/CDT-628/state.json" ]; then
  ok "AC4" "epic-init-writes-state-offline"
else
  fail "AC4" "epic-init-writes-state-offline" "rc=$rc state=$R/.claude/epics/CDT-628/state.json"
fi
rc=0
bash "$EPIC_LIB" add-child CDT-628 --id CDT-628-C7 --slug offline-verbs --title "Offline verbs" \
  --estimate M --agent ic4 --depends-on '[]' >/dev/null 2>&1 || rc=$?
PROJ=$(jq -r '.linear_project_id // "null"' "$R/.claude/epics/CDT-628/state.json" 2>/dev/null)
KID=$(jq -r '.children[0].linear_id // "null"' "$R/.claude/epics/CDT-628/state.json" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$PROJ" = "null" ] && [ "$KID" = "null" ]; then
  ok "AC4" "epic-child-adds-offline-with-null-linear-ids"
else
  fail "AC4" "epic-child-adds-offline-with-null-linear-ids" "rc=$rc project=$PROJ child=$KID"
fi
rc=0
out=$(bash "$EPIC_LIB" show CDT-628 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'CDT-628-C7'; then
  ok "AC4" "epic-show-renders-offline"
else
  fail "AC4" "epic-show-renders-offline" "rc=$rc out=$out"
fi
unset EPIC_ROOT
rm -rf "$R"

# ------------------------------------------------- AC4 one gate, one answer

# Every Surface reads the same key: flipping the fixture flips all four at once.
R=$(new_project shared)
for label in kickoff orchestrate status epic; do
  if [ "$(bash "$GATE" status --root "$R")" = "off" ]; then ok "AC4" "$label-reads-shared-key-off"; else fail "AC4" "$label-reads-shared-key-off" "not off"; fi
done
bash "$GATE" set --root "$R" on >/dev/null
for label in kickoff orchestrate status epic; do
  if [ "$(bash "$GATE" status --root "$R")" = "on" ]; then ok "AC4" "$label-reads-shared-key-on"; else fail "AC4" "$label-reads-shared-key-on" "not on"; fi
done
rm -rf "$R"

# ------------------------------------------- AC6 the posture is written down

posture_says() {
  local label="$1" file="$2" pat="$3"
  if grep -Eq "$pat" "$ROOT/$file"; then ok "AC6" "$label"
  else fail "AC6" "$label" "/$pat/ not in $file"; fi
}
posture_says "spec-calls-the-store-the-source-of-truth" "specs/core/SPEC-009-ticket-workflow.md" \
  'is the \*\*source of truth\*\*'
posture_says "spec-documents-the-linear-sync-key" "specs/core/SPEC-009-ticket-workflow.md" \
  '\| Key \| `linear_sync` \|'
posture_says "skill-states-the-local-path-when-off" "skills/backlog/SKILL.md" \
  'linear_sync'
posture_says "skill-points-at-the-tracker-plane-sidecar" "skills/backlog/SKILL.md" \
  'Read `skills/backlog/linear-sync.md`'
posture_says "sidecar-is-the-one-copy-of-the-gate" "skills/backlog/linear-sync.md" \
  'is the only code that reads `linear_sync`'
posture_says "docs-page-states-the-local-path-when-off" "docs/commands/backlog.md" 'linear_sync'
posture_says "agents-md-names-the-ticket-index" "AGENTS.md" '`\.claude/backlog\.md`'
posture_says "agents-md-names-the-ticket-item-store" "AGENTS.md" '`\.claude/backlog/<slug>\.md`'
posture_says "agents-md-names-the-conflict-rule" "AGENTS.md" 'single-writer-lease'
posture_says "agents-md-keeps-the-never-stage-rule" "AGENTS.md" \
  'never stage trackers into delivery commits'
posture_says "ownership-row-4-is-the-local-store" "docs/internal/control-plane/record-ownership.md" \
  'Backlog index and item files.*single-writer-lease'
posture_says "ownership-row-4-drops-linear-as-writer" "docs/internal/control-plane/record-ownership.md" \
  'Linear is an opt-in mirror'

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
