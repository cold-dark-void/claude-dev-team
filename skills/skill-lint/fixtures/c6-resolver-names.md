# C6 fixture — PDH and EXT_DIR are checked like the root variables (WP 2-01)

POSITIVE 1: PDH is read before the bootstrap assigns it.

```bash
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
PDH="$(pwd)"
echo "$WT_LIB"
```

POSITIVE 2: EXT_DIR is read before it is assigned (memory-recall shape).

```bash
MROOT=$(pwd)
ls "${EXT_DIR}/vec0"
EXT_DIR="$MROOT/.claude/memory/extensions"
```

POSITIVE 3: the waiver on the line above is honoured for PDH (counts as waived).

```bash
# lint-ok: C6 — fixture proves a C6 waiver covers the new names too
echo "$PDH"
PDH="$(pwd)"
```

NEGATIVE: correct order, same-line assignment, export and default-assign idioms.

```bash
PDH="$(pwd)"
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
export EXT_DIR="$PDH/ext"
ls "$EXT_DIR"
: "${PDH:=$(pwd)}"
```

NEGATIVE: single quotes, a comment and a longer name are not reads.

```bash
echo 'no $PDH expansion here'
# $EXT_DIR in a comment is prose
echo "$PDH_OTHER $EXT_DIR_OTHER"
PDH="$(pwd)"
EXT_DIR=$(pwd)
```

NEGATIVE: a fence that never assigns the name is C1's job, not C6's.

```bash
echo "$PDH/skills/plugin-dir.sh" "$EXT_DIR"
```
