# C6 fixture — roots must be assigned before use inside one fence

POSITIVE 1: MEMDB is assigned from $MROOT before MROOT exists (kickoff / brainstorm shape).

```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
echo "$WTROOT $MEMDB"
```

POSITIVE 2: the USE_DB test reads MEMDB before MEMDB is assigned (old AGENTS.md shape).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
MEMDB="$MROOT/.claude/memory/memory.db"
```

POSITIVE 3: PLUGIN_DIR is used before it is assigned.

```bash
bash "${PLUGIN_DIR}/migrate.sh"
PLUGIN_DIR="$HOME/.claude/plugin"
```

POSITIVE 4: a use inside an unquoted heredoc body counts (the body expands).

```bash
cat <<EOF
root is $MROOT
EOF
MROOT=$(pwd)
```

POSITIVE 5: the waiver on the line above is honoured for C6 (counts as waived).

```bash
# lint-ok: C6 — fixture proves a C6 waiver is counted
echo "$MROOT"
MROOT=$(pwd)
```

NEGATIVE: correct order, and every idiom below must stay silent.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

NEGATIVE: same-line assignment then use; export form; default-assign idiom.

```bash
MROOT=$(pwd); MEMDB="$MROOT/m.db"
export PLUGIN_DIR="$MROOT/plugin"
: "${WTROOT:=$(pwd)}"
echo "$WTROOT"
```

NEGATIVE: single-quoted text, a comment, a quoted heredoc and a longer name are not uses.

```bash
echo 'no $MROOT expansion here'
# $MEMDB in a comment is prose
cat <<'EOF'
literal $WTROOT in a quoted heredoc
EOF
echo "$MROOT_OTHER"
MROOT=$(pwd)
```

NEGATIVE: a fence that never assigns the name is C1's job, not C6's.

```bash
echo "$MROOT/AGENTS.md"
```
