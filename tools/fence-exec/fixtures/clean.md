# Clean fixture — shapes the lexer must read without a finding

## Shell shapes

NEGATIVE: case arms with alternation, a function that uses return, a loop and a
trap on a signal.

```bash
fe_parse() {
  case "$1" in
    --a|--b) FLAG=1 ;;
    --c)
      return 1
      ;;
    *) echo "other: $1" ;;
  esac
  return 0
}
for arg in "$@"; do
  fe_parse "$arg" || exit 2
done
trap 'echo bye' INT
while IFS= read -r line || [ -n "$line" ]; do
  echo "$line"
done < <(printf '%s\n' a b)
```

NEGATIVE: expansions, arithmetic, redirects, here-strings and negation.

```bash
N=$((1 + 2))
V="${N:-default} ${#N} $(( N * 2 ))"
if ! grep -q x <<< "$V" 2>/dev/null; then
  echo "absent" > /dev/null 2>&1
fi
[[ "$V" =~ ^[0-9]+ ]] && echo numeric &> /dev/null
(( N += 1 ))
x=$(cd /tmp && pwd)
echo "done $x $(echo nested "$(date +%s)")"
```

NEGATIVE: a multi-line quoted string and a heredoc with a command-like line.

```bash
MSG="first line
return 1
fe_undefined_thing two"
cat <<EOF2
trap 'x' EXIT
return 3
EOF2
echo "$MSG"
```

NEGATIVE: an unknown name at command position, and a path literal that holds a
placeholder.

```bash
some_tool --flag
bash "$PDH/skills/<name>/run.sh"
```
