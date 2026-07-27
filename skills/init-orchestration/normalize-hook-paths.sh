#!/usr/bin/env bash
# normalize-hook-paths.sh — CDT-69 Step 1 upgrade rewrite for hook commands
#
# Normalize hook commands in settings.json that use relative or absolute
# project-root paths under .claude/hooks/ to the managed form:
#   bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.sh"
#
# Absolute paths under $project_root (or ending in /.claude/hooks/<name>.sh
# when that path is under project root) were left un-rewritten by the relative-
# only upgrade, causing permanent doctor hooks.hygiene WARN.
#
# Changing an existing managed hook value MUST disclose first (CDT-51 AC5):
# key / old / new / restore via disclose-force-overwrite.sh (or identical labels).
#
# Usage:
#   bash normalize-hook-paths.sh --settings FILE [--project-root DIR] \
#       [--disclose PATH] [--dry-run]
#
# Exit:
#   0  rewrote one or more commands (disclosed each change), or dry-run would
#   1  no-op (already normalized / no matching hooks / missing hooks key)
#   2  usage / IO error
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

usage() {
  cat >&2 <<'EOF'
Usage:
  normalize-hook-paths.sh --settings FILE [--project-root DIR] \
      [--disclose PATH] [--dry-run]
EOF
  exit 2
}

SETTINGS=""
PROJECT_ROOT=""
DISCLOSE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --settings)     SETTINGS="${2:-}"; shift 2 ;;
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --disclose)     DISCLOSE="${2:-}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage ;;
    *) echo "normalize-hook-paths: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$SETTINGS" ] || usage

if [ ! -f "$SETTINGS" ]; then
  echo "normalize-hook-paths: settings not found: $SETTINGS" >&2
  exit 2
fi

# Resolve project root: flag > parent of .claude holding settings > git common-dir
if [ -z "$PROJECT_ROOT" ]; then
  # settings typically at <root>/.claude/settings.json
  _sdir=$(CDPATH= cd -- "$(dirname -- "$SETTINGS")" && pwd) || exit 2
  case "$_sdir" in
    */.claude) PROJECT_ROOT=$(CDPATH= cd -- "$_sdir/.." && pwd) || exit 2 ;;
    *)
      if _gc=$(git -C "$_sdir" rev-parse --git-common-dir 2>/dev/null); then
        PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$_gc")" && pwd) || exit 2
      else
        PROJECT_ROOT="$_sdir"
      fi
      ;;
  esac
fi
PROJECT_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT" && pwd) || {
  echo "normalize-hook-paths: cannot resolve project root" >&2
  exit 2
}

# Locate disclose helper (sibling by default)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -z "$DISCLOSE" ]; then
  DISCLOSE="$SCRIPT_DIR/disclose-force-overwrite.sh"
fi
# Missing disclose is OK — we print the same labels inline (fallback)

if ! command -v python3 >/dev/null 2>&1; then
  echo "normalize-hook-paths: python3 required" >&2
  exit 2
fi

# Plan rewrites (stdout: TSV event\told\tnew); exit 1 from python = none
PLAN=$(SETTINGS_FILE="$SETTINGS" PROJECT_ROOT="$PROJECT_ROOT" python3 - <<'PY'
import json, os, re, sys

settings_path = os.environ["SETTINGS_FILE"]
root = os.path.realpath(os.environ["PROJECT_ROOT"]).rstrip("/")

try:
    with open(settings_path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as e:
    sys.stderr.write("normalize-hook-paths: cannot parse %s: %s\n" % (settings_path, e))
    sys.exit(2)

hooks = data.get("hooks")
if not isinstance(hooks, dict) or not hooks:
    sys.exit(1)

# bash + optional quotes + path containing .claude/hooks/<name>.sh
# Relative: .claude/hooks/X.sh
# Absolute: /.../.claude/hooks/X.sh
# Anchored: ${CLAUDE_PROJECT_DIR}/.claude/hooks/X.sh
CMD_RE = re.compile(
    r"""^bash\s+(?P<q>["']?)(?P<path>
        (?:\$\{CLAUDE_PROJECT_DIR\}|\$CLAUDE_PROJECT_DIR)?
        (?:/?\.claude/hooks/|/.+?/\.claude/hooks/)
        (?P<name>[A-Za-z0-9_.-]+\.sh)
    )(?P=q)\s*$""",
    re.VERBOSE,
)

def canonical(name: str) -> str:
    return 'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/%s"' % name

def should_rewrite(path: str, name: str) -> bool:
    """True if relative .claude/hooks or absolute under project root (not yet anchored)."""
    if "${CLAUDE_PROJECT_DIR}" in path or "$CLAUDE_PROJECT_DIR" in path:
        return False
    if path == ".claude/hooks/%s" % name or path == "./.claude/hooks/%s" % name:
        return True
    if path.startswith("/"):
        try:
            real = os.path.realpath(path)
        except OSError:
            real = os.path.normpath(path)
        prefix = root + "/"
        suffix = "/.claude/hooks/" + name
        if real.startswith(prefix) and real.endswith(suffix):
            return True
        if path.startswith(prefix) and path.endswith(suffix):
            return True
    return False

changes = []

for event, entries in hooks.items():
    if not isinstance(entries, list):
        continue
    for ent in entries:
        if not isinstance(ent, dict):
            continue
        for h in ent.get("hooks") or []:
            if not isinstance(h, dict):
                continue
            cmd = h.get("command")
            if not isinstance(cmd, str) or not cmd:
                continue
            m = CMD_RE.match(cmd.strip())
            if not m:
                continue
            path = m.group("path")
            name = m.group("name")
            new_cmd = canonical(name)
            if cmd == new_cmd:
                continue
            if should_rewrite(path, name):
                changes.append((event, cmd, new_cmd))

if not changes:
    sys.exit(1)

for event, old, new in changes:
    if "\t" in old or "\t" in new or "\n" in old or "\n" in new:
        sys.stderr.write("normalize-hook-paths: command contains tab/newline; skip\n")
        continue
    sys.stdout.write("%s\t%s\t%s\n" % (event, old, new))
PY
) || {
  _py_rc=$?
  if [ "$_py_rc" -eq 1 ]; then
    exit 1
  fi
  exit 2
}

if [ -z "$PLAN" ]; then
  exit 1
fi

# Disclose each change (AC5). Forced + silent = FAIL.
CHANGED=0
while IFS=$'\t' read -r EVENT OLD_CMD NEW_CMD; do
  [ -n "${OLD_CMD:-}" ] || continue
  KEY="hooks.${EVENT}.command"
  RESTORE_HINT="${KEY}  (set back to: ${OLD_CMD})"
  if [ -n "$DISCLOSE" ] && [ -f "$DISCLOSE" ]; then
    bash "$DISCLOSE" \
      --key "$KEY" \
      --old "$OLD_CMD" \
      --new "$NEW_CMD" \
      --restore "$RESTORE_HINT" || true
  else
    cat <<EOF
FORCE-OVERWRITE: managed value will be replaced
  key:     ${KEY}
  old:     ${OLD_CMD}
  new:     ${NEW_CMD}
  restore: ${RESTORE_HINT}
EOF
  fi
  CHANGED=$((CHANGED + 1))
done <<< "$PLAN"

if [ "$CHANGED" -eq 0 ]; then
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi

# Backup settings before write
_sdir=$(dirname -- "$SETTINGS")
ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
BAK="${_sdir}/settings.force-hooks-paths.${ts}.json"
cp -p -- "$SETTINGS" "$BAK" 2>/dev/null || cp -p "$SETTINGS" "$BAK" || {
  echo "normalize-hook-paths: backup failed" >&2
  exit 2
}

# Apply rewrites (same match rules as plan phase)
SETTINGS_FILE="$SETTINGS" PROJECT_ROOT="$PROJECT_ROOT" BAK_PATH="$BAK" python3 - <<'PY' || exit 2
import json, os, re, sys

settings_path = os.environ["SETTINGS_FILE"]
root = os.path.realpath(os.environ["PROJECT_ROOT"]).rstrip("/")
bak = os.environ.get("BAK_PATH", "")

with open(settings_path, encoding="utf-8") as fh:
    data = json.load(fh)

CMD_RE = re.compile(
    r"""^bash\s+(?P<q>["']?)(?P<path>
        (?:\$\{CLAUDE_PROJECT_DIR\}|\$CLAUDE_PROJECT_DIR)?
        (?:/?\.claude/hooks/|/.+?/\.claude/hooks/)
        (?P<name>[A-Za-z0-9_.-]+\.sh)
    )(?P=q)\s*$""",
    re.VERBOSE,
)

def canonical(name: str) -> str:
    return 'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/%s"' % name

def should_rewrite(path: str, name: str) -> bool:
    if "${CLAUDE_PROJECT_DIR}" in path or "$CLAUDE_PROJECT_DIR" in path:
        return False
    if path == ".claude/hooks/%s" % name or path == "./.claude/hooks/%s" % name:
        return True
    if path.startswith("/"):
        try:
            real = os.path.realpath(path)
        except OSError:
            real = os.path.normpath(path)
        prefix = root + "/"
        suffix = "/.claude/hooks/" + name
        if real.startswith(prefix) and real.endswith(suffix):
            return True
        if path.startswith(prefix) and path.endswith(suffix):
            return True
    return False

hooks = data.get("hooks") or {}
n = 0
for event, entries in hooks.items():
    if not isinstance(entries, list):
        continue
    for ent in entries:
        if not isinstance(ent, dict):
            continue
        for h in ent.get("hooks") or []:
            if not isinstance(h, dict):
                continue
            cmd = h.get("command")
            if not isinstance(cmd, str) or not cmd:
                continue
            m = CMD_RE.match(cmd.strip())
            if not m:
                continue
            path, name = m.group("path"), m.group("name")
            new_cmd = canonical(name)
            if cmd == new_cmd:
                continue
            if should_rewrite(path, name):
                h["command"] = new_cmd
                n += 1

tmp = settings_path + ".tmp." + str(os.getpid())
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, settings_path)
sys.stderr.write(
    "normalize-hook-paths: rewrote %d hook command(s); backup %s\n" % (n, bak)
)
PY

echo "normalize-hook-paths: backup at $BAK" >&2
exit 0
