```bash
X=${2:-}; shift 2
```
```bash
while [ $# -gt 0 ]; do
  case "$1" in
    --flag)
      case "${2:-}" in ""|-*) exit 1 ;; esac
      V="$2"
      shift 2 ;;
  esac
done
```
```bash
f() {
  local a=$1 b=$2
  shift 2
}
```
```bash
[ "$#" -ge 2 ] || usage
shift 2
```
```bash
need_arg "$1" "$#"; V="$2"; shift 2 ;;
```
```bash
V="${2:-}"; shift 2 || { usage; exit 64; }
```
```bash
shift 1
shift 1;
```
```bash
while [ $# -gt 1 ]; do shift 9; done
```
