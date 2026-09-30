# C10 fixture — comments and waivers must not sit where they change the command

POSITIVE 1: a trailing waiver after a line-continuation backslash ends the command.

```bash
"$ENGINE" finalize --plan-file "$PLAN" \  # lint-ok: C1
  --evidence-file "$EVIDENCE"
```

POSITIVE 2: a backslash followed by a trailing space is an escaped space, not a continuation.

```bash
"$ENGINE" finalize --plan-file "$PLAN" \ 
  --evidence-file "$EVIDENCE"
```

POSITIVE 3: a comment line between continuation lines swallows the rest of the command.

```bash
"$ENGINE" finalize \
# the evidence file comes next
  --evidence-file "$EVIDENCE"
```

POSITIVE 4: a waiver inside an open double quote is string text, not a waiver.

```bash
git commit -m "release notes
second line  # lint-ok: C1
third line"
```

POSITIVE 5: a shell comment inside an open SQL string is SQL text (parse error).

```bash
AGENTS=$(sqlite3 "$MEMDB" \
  "SELECT agent FROM memories
   GROUP BY agent
   HAVING COUNT(*) >= $THRESHOLD  # distill threshold
   ORDER BY agent;")
```

POSITIVE 6: a single-quoted SQL argument is also an open quote.

```bash
sqlite3 "$MEMDB" 'SELECT 1
  # stray comment
;'
```

NEGATIVE: every idiom below is correct and must stay silent.

```bash
# The waiver and the comment sit on their own line above the command.
# lint-ok: C1 — PLAN comes from the Step 3 fence
"$ENGINE" finalize --plan-file "$PLAN" \
  --evidence-file "$EVIDENCE" \
  --judge-output "$JUDGE"
echo "closed quote"  # lint-ok: C1
echo "issue #12 is open"
echo 'a \ b' "a\ b" a\ b
N=${#PLAN}; M=$#
sqlite3 "$MEMDB" "SELECT '#tag', 'a#b';"
sqlite3 "$MEMDB" <<'SQL'
-- a # inside a heredoc body is not scanned by this rule
SELECT 1;
SQL
sqlite3 "$MEMDB" "SELECT 1;"; echo "note # after the sqlite3 command ended"
command -v sqlite3 >/dev/null 2>&1 && echo "ok # not sql"
```
