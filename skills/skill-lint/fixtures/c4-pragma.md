# C4 fixture

```bash
DB=/srv/x.db
VAL=$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; SELECT content FROM memories;")
echo "$VAL"
```

```bash
DB=/srv/x.db
sqlite3 "$DB" <<'SQL'
PRAGMA busy_timeout=5000;
SELECT 1;
SQL
OK=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT 1;")
echo "$OK"
```
