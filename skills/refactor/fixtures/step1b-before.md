# Step 1b as shipped in v1.18.32 (CDT-356)

This fixture holds the Step 1b section of `skills/refactor/SKILL.md` before the path-guard fix. `skills/refactor/test-fences.sh` runs its fences to prove that the test fails on the old text.

## Step 1b: Load desc-specific context

> Runs after Step 1 (mode parse) because it requires `$DESC`.

**a. Existing plans for the refactor area** — extract first 3-5 meaningful words from `$DESC` (strip articles/prepositions). Strip non-`[A-Za-z0-9_-]` characters from each keyword AND use `grep -F` (fixed strings, disables regex):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ls "$MROOT/.claude/plans/" 2>/dev/null | grep -iF -e "keyword1" -e "keyword2" -e "keyword3"
```

Read matches in full. No matches → "No existing plans matched — proceeding fresh."

**Plan-file exemption check** (SPEC-031 § Closing the self-satisfiable plan-file exemption): a matched plan's mere existence is never authorization to skip `/kickoff`. The plan file itself is never a ticket — it can only carry a *reference* to one, scoped to its Tracking section (SPEC-009):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
RAW_FILE='<matched-file>'
SAFE_FILE=$(printf '%s' "$RAW_FILE" | tr -cd 'A-Za-z0-9_.-')
TRACKING=$(awk '/^## Tracking/{f=1;next} /^## /{f=0} f' "$MROOT/.claude/plans/$SAFE_FILE" 2>/dev/null)
printf '%s\n' "$TRACKING" | grep -E '^\s*-?\s*(ticket_id|closes):'
BACKLOG_REF=$(printf '%s\n' "$TRACKING" | grep -oE 'backlog/[A-Za-z0-9_-]+\.md' | head -1)
[ -n "$BACKLOG_REF" ] && [ -f "$MROOT/.claude/$BACKLOG_REF" ] && echo "resolved: $BACKLOG_REF"
```

- **The Tracking section carries `ticket_id:` or a `closes:` entry naming `linear:<ID>` or `backlog/<slug>.md`, that reference resolves (the named backlog item file exists on disk — see `BACKLOG_REF` check above; a `linear:<ID>` reference is taken on the string alone), and the file was not written by this run** → the *referenced* ticket-id — not the plan file — satisfies the ticket requirement in 2.2a.1's routing test. The plan file is only the carrier of that reference.
- **No such reference, an unresolved `backlog/<slug>.md` reference (item file absent — e.g. `closes: backlog/nonexistent.md`), or the file was written during this run** → the plan does not qualify, regardless of its contents. Never skip `/kickoff` merely because a `.claude/plans/` file exists.
- Do not use file timestamps, mtime, or invocation-time comparisons to decide whether a plan predates this run — timestamp checks are explicitly out of scope. Resolving a referenced backlog item's existence is a content check, not a timestamp check, and is in scope.

**b. Recent git log for affected path (when identifiable from `$DESC`):**

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Validate path: strip non-[A-Za-z0-9_./-], reject if empty
RAW_PATH='<affected-path>'
SAFE_PATH=$(printf '%s' "$RAW_PATH" | tr -cd 'A-Za-z0-9_./-')
[ -z "$SAFE_PATH" ] && echo "Could not identify affected path — skip git log" && SAFE_PATH=""
# Reject traversal attempts
case "$SAFE_PATH" in
  *..* ) echo "Path traversal detected — skip" && SAFE_PATH="" ;;
esac
[ -n "$SAFE_PATH" ] && [[ "$SAFE_PATH" != "$WTROOT"* ]] && SAFE_PATH=""
git log --oneline -20 -- "$SAFE_PATH"
```

> Use single-quoted assignment for RAW_PATH to prevent command substitution in the path before sanitization. Reject paths containing `..` and paths resolving outside `$WTROOT`.

If no path identifiable: skip and note "Affected path not identifiable — git log skipped."

**c. Existing tests near the affected area:**

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RAW_PATH='<affected-path>'
SAFE_PATH=$(printf '%s' "$RAW_PATH" | tr -cd 'A-Za-z0-9_./-')
[ -z "$SAFE_PATH" ] && echo "Could not identify affected path — skip test scan" && SAFE_PATH=""
# Reject traversal attempts
case "$SAFE_PATH" in
  *..* ) echo "Path traversal detected — skip" && SAFE_PATH="" ;;
esac
[ -n "$SAFE_PATH" ] && [[ "$SAFE_PATH" != "$WTROOT"* ]] && SAFE_PATH=""
find "$(dirname "$SAFE_PATH")" -name "*test*" -o -name "*_test.*" 2>/dev/null | head -20
# Fallback: project-wide
find "$WTROOT" -name "*test*" -o -name "*_test.*" 2>/dev/null | head -30
```

These results drive the coverage-check branch decision.

**Summarize:**

```
Desc-specific context loaded:
  Plans matched:    [N files: <names> | none]
  Git log:          [N commits for <path> | skipped]
  Test files found: [N files near <path> | N project-wide]
```

---

