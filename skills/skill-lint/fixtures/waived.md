# Waiver fixture

```bash
rm /srv/known-nonempty/*.bak  # lint-ok: C3
# lint-ok: C3
rm /srv/other-nonempty/*.bak
rm /srv/unwaived/*.bak  # lint-ok: C1
```
