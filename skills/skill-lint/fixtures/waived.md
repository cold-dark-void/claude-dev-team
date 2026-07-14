# Waiver fixture

```bash
rm /tmp/known-nonempty/*.bak  # lint-ok: C3
# lint-ok: C3
rm /tmp/other-nonempty/*.bak
rm /tmp/unwaived/*.bak  # lint-ok: C1
```
