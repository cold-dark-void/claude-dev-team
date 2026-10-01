# C8 fixture: idiom hazards in a bash fence

Each fence holds planted positives and negative controls for one sub-rule of
C8. test.sh names the expected finding lines; edit both together.

## (a) grep -c with an echo 0 fallback

```bash
n=$(grep -c . "$f" 2>/dev/null || echo 0)
m=$(printf '%s\n' "$x" | sed '/^$/d' | grep -c . || echo 0)
k=$(rg -c "a|b" "$f" || echo 0)
j=$(grep -cE "x" "$f" 2>&1 || echo "0")
```

```bash
# negatives: the safe form and look-alikes
n=$(grep -c . "$f" 2>/dev/null || true); n=${n:-0}
w=$(wc -c < "$f" 2>/dev/null || echo 0)
t=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
L=$(jq length "$f" 2>/dev/null || echo 0)
# x=$(grep -c . "$f" || echo 0)
echo 'x=$(grep -c . "$f" || echo 0)'
q=$(grep -c "a || echo 0" "$f" || true)
p=$(grep "c" "$f" || echo 0)
o=$(grep -C 2 x "$f" || echo 0)
```

## (b) "$$" in a temp path

```bash
TMPF="${TMPDIR:-/tmp}/memcap-$$"
OUT="$TMPDIR/scan-$$.json"
```

```bash
# negatives
echo "pid=$$"
LOG='${TMPDIR:-/tmp}/x-$$'
W=$(mktemp "${TMPDIR:-/tmp}/x.XXXXXX")
R="$WORK_DIR/run-$$"
# "${TMPDIR:-/tmp}/c-$$"
```

## (c) a bare /tmp/ path

```bash
cp "$f" /tmp/copy.txt
OUT="/tmp/report.json"
```

```bash
# negatives
bwrap --tmpfs /tmp --ro-bind / /
D="${TMPDIR:-/tmp}/x"
P="$TMPDIR/tmp/x"
u=https://host/tmp/x
echo '/tmp/x'
# /tmp/x
```

## (d) a brace inside a ${VAR:-...} default

```bash
SKIP=$(jq -r '.a' <<<"${CHILD_WT:-{}}")
XX=${Y:-a{b}}
```

```bash
# negatives
DEF='{}'; SKIP=$(jq -r '.a' <<<"${CHILD_WT:-$DEF}")
V=${A:-${B}}
echo '${X:-{}}'
n=${#arr[@]}
```

## (e) a "Stop here" comment without an exit

```bash
if [ -z "$X" ]; then
  echo "no"
  # Stop here
fi
echo done
# Stop here (exit 0)
```

```bash
# negatives
if [ -z "$X" ]; then
  echo "no"
  # Stop here
  exit 0
fi
[ -z "$Y" ] && exit 1  # Stop here
if [ -z "$Z" ]; then
  # Stop here (exit 2)

  return 2
fi
```

## (f) destructive git

```bash
git branch -D "feat/$T"
git -C "$MROOT" reset --hard origin/master
git clean -fd
git push origin --force-with-lease
git push --delete origin x
# lint-ok: C8 — throwaway clone in a test
git reset --hard HEAD
```

```bash
# negatives
git branch -d x
git clean -n
git push origin x
echo "git branch -D x"
# git reset --hard
git reset --soft HEAD~1
git checkout -- file
```
