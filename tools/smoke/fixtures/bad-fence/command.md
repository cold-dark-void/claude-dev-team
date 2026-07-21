---
name: bad-fence
description: A surface with a bash fence that fails bash -n.
---

The fence below has a syntax error (unclosed if).

```bash
if true
  echo "unclosed if with no fi"
```
