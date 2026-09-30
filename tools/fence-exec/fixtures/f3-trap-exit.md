# F3 fixture — trap EXIT in a fence

## Positives

POSITIVE: the action releases a lock, so the lock is gone when this fence ends.

```bash
LOCK=scheduled-lock.sh
bash "$LOCK" acquire
trap 'bash "$LOCK" release 2>/dev/null || true' EXIT
```

POSITIVE: a named handler is not a plain rm of temporary files.

```bash
trap release_lock EXIT
```

POSITIVE: the rm trap deletes WORKDIR, and the next fence still reads it.

```bash
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
echo "$WORKDIR"
```

The next fence expects the directory to be there.

```bash
ls "$WORKDIR"
```

## Negative controls

NEGATIVE: a plain rm trap of a variable that no other fence reads.

```bash
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
echo "work in $SCRATCH"
```

NEGATIVE: a script body (it starts with a shebang) owns its whole lifetime.

```bash
#!/usr/bin/env bash
LOCK=scheduled-lock.sh
trap 'bash "$LOCK" release' EXIT
```

NEGATIVE: other signals, removing a trap and an empty action.

```bash
trap 'echo interrupted' INT
trap 'rm -f "$F"' ERR
trap - EXIT
trap '' EXIT
```

NEGATIVE: a `bash template` fence is pseudocode.

```bash template
trap 'bash "$LOCK" release' EXIT
```
