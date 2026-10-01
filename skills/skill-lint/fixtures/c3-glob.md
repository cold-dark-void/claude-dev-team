# C3 fixture

```bash
for f in /srv/data/*.json; do echo "$f"; done
FILES=$(ls "$HOME"/logs/*.jsonl)
rm .claude/tasks/CDV-1-*.json
```

```bash
for f in $(find /srv/data -maxdepth 1 -name '*.json'); do echo "$f"; done
case "$1" in
  *.md) echo md ;;
  *) echo other ;;
esac
X="star literal *"
if [[ "$X" == *literal* ]]; then echo match; fi
grep -c '\.jsonl$' /srv/list.txt
```
