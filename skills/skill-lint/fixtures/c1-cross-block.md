# C1 fixture

```bash
PDH=$(cd "$(dirname "$0")" && pwd)
GATE="$PDH/gate.sh"
echo "$GATE"
declare -r FIXED=1
local Y=2
readonly Z=3
```

```bash
bash "$PDH/other.sh"
echo "$HOME/$UNDEFINED_ANYWHERE"
for t in a b; do echo "$t"; done
echo "$FIXED$Y$Z"
```

# Indented same-block def — not C1 (assignment recognized despite leading spaces)
```bash
  X=hello
  echo "$X"
```

# Indented def in sibling only — C1 on use of $INDENTED_ONLY
```bash
  INDENTED_ONLY=from-sibling
```

```bash
echo "$INDENTED_ONLY"
```
