#!/usr/bin/env bash
# PostCompact + SessionStart hook — surface the latest PreCompact rescue
# artifact (SPEC-018 M16). POINTER INJECTION ONLY: prints one line naming the
# artifact path and the `/handoff <uuid>` recovery invocation. NEVER dumps
# artifact content into context (M6 discipline). Fail-open: always exits 0.
# SessionStart consumes the marker (one-shot); PostCompact leaves it so the
# NEXT session start still learns about the artifact.
set -u
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && ROOT=$(cd -- "$(dirname -- "$_gc")" && pwd) \
  || ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || exit 0
MARKER="$ROOT/.claude/handoff/.rescue-pointer.json"
[ -f "$MARKER" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Which event is this? (stdin hook JSON; empty/garbage -> treated as unknown)
EVENT=$(head -c 65536 | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("hook_event_name", "") if isinstance(d, dict) else "")' 2>/dev/null)

LINE=$(MARKER_FILE="$MARKER" python3 - <<'PYEOF' 2>/dev/null
import datetime, json, os, sys
try:
    with open(os.environ["MARKER_FILE"], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
art = d.get("artifact") or ""
sid = d.get("session_id") or ""
ca = d.get("created_at") or ""
if not art or not sid or not os.path.isfile(art):
    sys.exit(1)
try:
    age = datetime.datetime.now(datetime.timezone.utc) \
        - datetime.datetime.fromisoformat(ca.replace("Z", "+00:00"))
    if age.total_seconds() > 86400:
        sys.exit(2)   # stale (>24 h): caller deletes the marker silently
except Exception:
    pass
print(f"A pre-compaction rescue artifact exists for session {sid}: {art} — "
      f"run `/handoff {sid}` to rebuild the full brief (the artifact is raw "
      f"material, not the brief).")
PYEOF
)
RC=$?
if [ "$RC" -eq 2 ]; then
  rm -f -- "$MARKER"
  exit 0
fi
if [ "$RC" -ne 0 ] || [ -z "$LINE" ]; then
  exit 0
fi
echo "$LINE"
if [ "$EVENT" = "SessionStart" ]; then
  rm -f -- "$MARKER"
fi
exit 0
