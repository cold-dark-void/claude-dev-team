# Clean fixture — no findings expected

```bash
MROOT=$(pwd)
for f in $(find "$MROOT" -maxdepth 1 -name '*.json'); do
  echo "$f"
done
if [ "${HOME}" = "/" ]; then echo root; fi
```

```sql
PRAGMA busy_timeout=5000; SELECT 1;
```

Text outside blocks with $UNDEFINED and a glob *.tmp is ignored.
