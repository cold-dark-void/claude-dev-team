# F4 fixture — return outside a function

## Positives

POSITIVE: a return at the top of the fence.

```bash
[ -n "$X" ] || echo "no X"
return 1
```

POSITIVE: a return inside a brace group and inside an if, both outside any function.

```bash
[ -f "$F" ] || { echo "missing"; return 1; }
if [ -z "$Y" ]; then
  return 0
fi
```

## Negative controls

NEGATIVE: returns inside function bodies, in every function shape.

```bash
fe_one() {
  if [ -z "$1" ]; then
    return 1
  fi
  case "$1" in
    a) return 2 ;;
    *) { echo x; return 3; } ;;
  esac
  return 0
}
fe_two() { return 4; }
function fe_three {
  return 5
}
function fe_four() { echo hi; return 6; }
fe_five ()
{
  return 7
}
fe_one a
```

NEGATIVE: the word is text, not a command.

```bash
echo return
echo "return 1"
# return 1
cat <<'EOT'
return 1
EOT
cat <<EOT2
  return 2
EOT2
printf '%s\n' 'return'
```
