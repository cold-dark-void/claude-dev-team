# F5 fixture — path literals against the repo

## Positives

POSITIVE: literal paths that the repo does not hold.

```bash
bash "$PDH/skills/missing.sh"
source "${PDH}/skills/missing-brace.sh"
ls "$CLAUDE_PLUGIN_ROOT/skills/gone/x.sh"
LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/real/nope.sh)
```

POSITIVE: a plugin-dir.sh dir literal, and a $PLUGIN_DIR leaf next to it.

```bash
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/real/schema.sql)
sqlite3 "$MEMDB" < "$PLUGIN_DIR/absent.sql"
```

## Negative controls

NEGATIVE: the same shapes with paths that exist.

```bash
bash "$PDH/skills/plugin-dir.sh" --help
source "${PDH}/skills/real/lib.sh"
LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/real/lib.sh)
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/real/schema.sql)
sqlite3 "$MEMDB" < "$PLUGIN_DIR/schema.sql"
```

NEGATIVE: placeholders, globs, expansions, comments and heredoc text are not literals.

```bash
bash "$PDH/skills/<name>/run.sh"
ls "$PDH"/skills/*/lib.sh
ls "$PDH/skills/$NAME/lib.sh"
bash "$PDH/$REL"
LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/real/$NAME.sh)
LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/<dir>/x.sh)
# bash "$PDH/skills/in-a-comment.sh"
cat <<'EOT'
bash "$PDH/skills/in-a-heredoc.sh"
EOT
```

NEGATIVE: a $PLUGIN_DIR leaf with no known directory behind it is skipped.

```bash
sqlite3 "$MEMDB" < "$PLUGIN_DIR/unknown.sql"
```
