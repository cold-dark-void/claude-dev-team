# F2 fixture — a function that another fence defines

## Define

This fence defines the helper and calls it. Nothing here is a finding.

```bash
fe_helper() {
  echo "helper $1"
}
fe_helper one
```

## Positive

POSITIVE: a later fence calls the helper without defining it.

```bash
fe_helper two
```

POSITIVE: calls in a command substitution and after `&&`.

```bash
out=$(fe_helper three)
true && fe_helper four
```

## Negative controls

NEGATIVE: the fence defines its own copy.

```bash
fe_helper() { echo own; }
fe_helper five
```

NEGATIVE: the name is an argument, text in a string, a comment, a quoted
heredoc body or a single-quoted word. None of these is a call.

```bash
echo fe_helper
echo "fe_helper is a function"
# fe_helper six
cat <<'EOT'
fe_helper seven
EOT
printf '%s\n' 'fe_helper'
```

NEGATIVE: the `function` keyword form defines in this fence, and a name that
no fence defines is not an F2 finding.

```bash
function fe_other { echo x; }
fe_other
fe_undefined one
```

NEGATIVE: a `bash template` fence is pseudocode.

```bash template
fe_helper eight
```

## More positives

POSITIVE: a call at every command position the lexer must see.

```bash
if fe_helper a; then fe_helper b; else fe_helper c; fi
while fe_helper d; do fe_helper e; done
case "$x" in a) fe_helper f ;; esac
echo "$(fe_helper g)"
{ fe_helper h; }
( fe_helper i )
fe_helper j | cat
! fe_helper k
X=1 fe_helper l
```
