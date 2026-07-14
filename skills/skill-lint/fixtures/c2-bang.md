# C2 fixture

```bash
python3 <<'PY'
print("include marker: <!-- include: x -->")
print("wow!bang")
PY
MSG="deploy failed!retry now"
echo "$MSG"
```

```bash
if ! command -v jq >/dev/null; then echo no; fi
[ ! -f /tmp/x ] && echo absent
X=1
if [ "$X" != "2" ]; then echo ok; fi
wait $!
echo "${!X}" 2>/dev/null || true
```
