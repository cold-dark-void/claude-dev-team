#!/usr/bin/env bash
# W3-31 / 10 F24 bite-test for skills/standup/SKILL.md.
# Static: jq guards, quoted context path, --grep (never --author) staleness,
# guarded EPIC_LIB resolution. Scripted: the Step 2 fence reads the ticket's
# worktree context, not the caller's, in a two-worktree fixture.
# Run: bash skills/standup/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL="$HERE/SKILL.md"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- static: fences only (a prose mention is not executable) ---
FENCES=$(awk '/^```bash$/{f=1;buf="";next} /^```$/{if(f)print buf; f=0;next} f{buf=buf $0 "\n"}' "$SKILL")
[ -n "$FENCES" ] || { bad "no bash fences found in SKILL.md"; echo "standup tests: 0 passed, 1 failed"; exit 1; }

echo "$FENCES" | grep -q 'command -v jq >/dev/null 2>&1' \
  && ok || bad "no jq guard in standup fences (old code called jq unguarded)"
echo "$FENCES" | grep -q -- '--author=' \
  && bad "staleness still uses --author (never matches user-authored commits)" || ok
echo "$FENCES" | grep -q -- '--grep=' \
  && ok || bad "staleness does not grep the ticket id"
echo "$FENCES" | grep -q 'cat $WTROOT/' \
  && bad "unquoted caller-only context read (cat \$WTROOT/...)" || ok
echo "$FENCES" | grep -q 'CTX_ROOT="${TASK_WT:-$WTROOT}"' \
  && ok || bad "no per-task worktree fallback for context read"
echo "$FENCES" | grep -q 'file skills/epic/epic-lib.sh' \
  && ok || bad "EPIC_LIB not resolved via plugin-dir.sh"
echo "$FENCES" | grep -q '\[ -f "$EPIC_LIB" \]' \
  && ok || bad "EPIC_LIB used without a -f existence guard"
grep -q 'No active tasks found. Run /kickoff' "$SKILL" \
  && ok || bad "unified no-tasks wording missing"
grep -q 'No tasks found. Run /kickoff' "$SKILL" \
  && bad "old divergent no-tasks wording survives" || ok
grep -q 'Recommend escalation to Tech Lead when:' "$SKILL" \
  && ok || bad "escalation is still worded as auto-send"
grep -q 'Auto-escalate' "$SKILL" \
  && bad "Auto-escalate wording survives (contradicts do-not-send)" || ok
grep -q 'never as .🟡 LIKELY-DONE' "$SKILL" \
  && ok || bad "LIKELY-DONE rule does not defer to the file store"

# --- scripted: Step 2 fence reads the ticket's worktree context ---
TMP=$(mktemp -d "${TMPDIR:-/tmp}/standup-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
git -C "$TMP" init -q "$REPO" 2>/dev/null
git -C "$REPO" commit -q --allow-empty -m init 2>/dev/null
mkdir -p "$REPO/.worktrees/poc-123-impl/.claude/memory/ic5" \
         "$REPO/.worktrees/other-ticket/.claude/memory/ic5" \
         "$REPO/.claude/memory/ic5"
echo "IMPL-CTX"  > "$REPO/.worktrees/poc-123-impl/.claude/memory/ic5/context.md"
echo "OTHER-CTX" > "$REPO/.worktrees/other-ticket/.claude/memory/ic5/context.md"
echo "CALLER-CTX" > "$REPO/.claude/memory/ic5/context.md"

FENCE=$(awk '/^```bash$/{f=1;buf="";next} /^```$/{if(f && buf ~ /CTX_ROOT=/){printf "%s",buf; exit}; f=0;next} f{buf=buf $0 "\n"}' "$SKILL")
[ -n "$FENCE" ] && ok || bad "Step 2 context fence not found"

printf '%s' "$FENCE" | sed 's/<TICKET-ID>/POC-123/g; s/<owner>/ic5/g' > "$TMP/step2.sh"
OUT=$(cd "$REPO" && bash "$TMP/step2.sh" 2>/dev/null)
echo "$OUT" | grep -q 'IMPL-CTX' && ok || bad "context fence did not read the ticket worktree (got: $OUT)"
echo "$OUT" | grep -q 'OTHER-CTX' && bad "context fence leaked the sibling worktree" || ok
echo "$OUT" | grep -q 'CALLER-CTX' && bad "context fence fell back to the caller despite a ticket worktree" || ok

# No matching worktree -> caller fallback.
printf '%s' "$FENCE" | sed 's/<TICKET-ID>/NO-SUCH-TICKET/g; s/<owner>/ic5/g' > "$TMP/step2b.sh"
OUT2=$(cd "$REPO" && bash "$TMP/step2b.sh" 2>/dev/null)
echo "$OUT2" | grep -q 'CALLER-CTX' && ok || bad "no matching worktree should fall back to the caller's context"

echo "standup tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
