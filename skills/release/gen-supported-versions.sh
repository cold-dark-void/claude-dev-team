#!/usr/bin/env bash
# gen-supported-versions.sh — emit (or rewrite) the SECURITY.md
# supported-versions table from the plugin version (CDT-296 / 10 E9 / W3-22).
#
#   gen-supported-versions.sh [X.Y.Z]           print the markdown table
#   gen-supported-versions.sh [X.Y.Z] --write   rewrite the section in SECURITY.md
#
# The version argument defaults to .claude-plugin/plugin.json ("version"),
# resolved from this script's plugin root (works in-repo and installed).
# Policy: the current minor is supported; every older minor is not.
# The docs-drift `security-versions` check fails when SECURITY.md lags this
# output, and /release regenerates the table at Step 3d.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
SECURITY="${SECURITY_MD:-$ROOT/SECURITY.md}"

usage() {
  echo "usage: gen-supported-versions.sh [X.Y.Z] [--write]" >&2
  exit 64
}

ver=""
write=false
for arg in "$@"; do
  case "$arg" in
    --write) write=true ;;
    -h|--help) usage ;;
    [0-9]*) ver="$arg" ;;
    *) usage ;;
  esac
done

if [ -z "$ver" ]; then
  [ -f "$PLUGIN_JSON" ] || { echo "gen-supported-versions.sh: no version argument and $PLUGIN_JSON not found" >&2; exit 1; }
  ver=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_JSON" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi
case "$ver" in
  *[!0-9.]*) { echo "gen-supported-versions.sh: not a semver: $ver" >&2; exit 1; } ;;
esac
case "$ver" in
  *.*.*) ;;
  *) { echo "gen-supported-versions.sh: not a semver: $ver" >&2; exit 1; } ;;
esac

minor=${ver%.*}

emit() {
  cat <<EOF
| Version | Supported |
|---------|-----------|
| ${minor}.x | Yes       |
| < ${minor} | No        |
EOF
}

if ! $write; then
  emit
  exit 0
fi

[ -f "$SECURITY" ] || { echo "gen-supported-versions.sh: $SECURITY not found" >&2; exit 1; }
tmp=$(mktemp "${TMPDIR:-/tmp}/security.md.XXXXXX")
tmpsec="$tmp.sec"
trap 'rm -f "$tmp" "$tmpsec"' EXIT
emit > "$tmpsec"
awk -v secfile="$tmpsec" '
  BEGIN { insrc = 0; done = 0
          while ((getline line < secfile) > 0) section = section line "\n" }
  !insrc && !done {
    print
    if ($0 ~ /^## Supported Versions[[:space:]]*$/) { printf "%s", section; insrc = 1; done = 1 }
    next
  }
  insrc && /^## / { insrc = 0; print ""; print; next }
  insrc { next }
  { print }
' "$SECURITY" > "$tmp"
mv "$tmp" "$SECURITY"
