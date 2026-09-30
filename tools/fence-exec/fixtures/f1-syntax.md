# F1 fixture — bash -n per fence

## Positive

POSITIVE: the stray parenthesis on the second body line fails bash -n.

```bash
echo start
echo )
```

## Negative controls

NEGATIVE: a clean fence.

```bash
if true; then
  echo one
fi
```

NEGATIVE: a `bash template` fence is pseudocode and opts out of bash -n.

```bash template
for each claim where claim_type == "x":
  do <thing> )
```

NEGATIVE: a non-bash fence is never parsed as bash.

```sql
SELECT ( FROM;
```

## Template is the second word only

POSITIVE: `template` is the third word, so this is a plain bash fence. Smoke and F2-F4 read it the same way, and bash -n runs.

```bash title template
echo )
```
