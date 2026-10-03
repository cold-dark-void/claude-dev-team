# C9 fixture: argument pass-through in a command fence

C9 reads only commands/<name>.md. test.sh copies this file to a commands/
directory, runs skill-lint on the copy, and checks the same copy under
skills/ for silence. Edit the expected lines in test.sh with this file.

## (a) positional parameters at the top level

```bash
bash "$AUDIT_SH" "$@"
[ "${1:-}" = "models" ] && shift
bash "$WRITE" "${@:2}"
echo "n=$#"
x="$(echo $1)"
```

A read before "set --" is flagged, a read after it is not. A function body
has its own arguments. After the function closes, the top level is empty again.

```bash
echo "$1"
set -f; set -- a b; set +f
echo "$1 $@ $*"
```

```bash
f() { echo "$1"; }
echo "$1"
```

```bash
# negatives
helper() {
  local a="$1"
  echo "$@ $* $#"
}
g() { echo "$2"; }
function h {
  echo "$3"
}
n=${#arr[@]}
echo "${arr[@]}"
awk '{print $1}' "$f"
echo '$@ $1'
# "$@" and $1
echo "$0 $$ $? $!"
```

## (b) $ARGUMENTS outside a quoted heredoc

```bash
for arg in $ARGUMENTS; do echo "$arg"; done
bash "$EXPORT_SH" $ARGUMENTS "$MROOT"
cat <<EOF
text: $ARGUMENTS
EOF
```

```bash
# negatives: the heredoc convention and double-quoted words
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
while [ $# -gt 0 ]; do
  case "$1" in
    --x) [ "$#" -ge 2 ] || exit 1; XV="$2"; shift 2 ;;
    *) shift ;;
  esac
done
grep -F "$ARGUMENTS" "$f"
echo '$ARGUMENTS'
# $ARGUMENTS
```
