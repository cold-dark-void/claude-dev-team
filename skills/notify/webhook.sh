#!/usr/bin/env bash
# webhook.sh — fail-open POST to AGENT_WEBHOOK_URL (CDV-210 notification sink).
#
# Usage:
#   bash skills/notify/webhook.sh <event> [detail]
#
# Env:
#   AGENT_WEBHOOK_URL   required to POST; unset/empty → silent no-op (exit 0)
#   NOTIFY_SOURCE       default "orchestrate" (e.g. task_completed)
#   NOTIFY_AGENT        optional agent name
#   NOTIFY_TASK         optional task id
#   NOTIFY_TICKET       optional ticket id
#   NOTIFY_DRY_RUN=1    print JSON payload to stdout; do not POST
#
# Events (CDV-210 enum): task_complete | task_blocked | qa_pass | qa_fail |
#   council_verdict | council_findings | error
# scheduled_retro is CDV-190-owned (write-scheduled-report.sh); same URL OK.
#
# Payload: {event, time (ISO-UTC), source, agent?, task?, ticket?, detail?≤500}
# Never includes secrets, transcripts, or file bodies.
# Always exits 0 (fail-open). curl -m 5 || true.
set -u

EVENT="${1:-}"
DETAIL="${2:-}"

# Silent when URL unset or event missing
[ -n "${AGENT_WEBHOOK_URL:-}" ] || exit 0
[ -n "$EVENT" ] || exit 0

TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
[ -n "$TIME" ] || TIME="1970-01-01T00:00:00Z"

SOURCE="${NOTIFY_SOURCE:-orchestrate}"
AGENT="${NOTIFY_AGENT:-}"
TASK="${NOTIFY_TASK:-}"
TICKET="${NOTIFY_TICKET:-}"

# Truncate detail to 500 chars (bash substring; portable enough for this helper)
if [ -n "$DETAIL" ] && [ "${#DETAIL}" -gt 500 ]; then
  DETAIL="${DETAIL:0:500}"
fi

# Build JSON safely (python3 preferred). Fail-open if unavailable.
JSON=""
if command -v python3 >/dev/null 2>&1; then
  JSON=$(
    NOTIFY_EVENT="$EVENT" NOTIFY_TIME="$TIME" NOTIFY_SRC="$SOURCE" \
    NOTIFY_AG="$AGENT" NOTIFY_TK="$TASK" NOTIFY_TICKET_V="$TICKET" \
    NOTIFY_DET="$DETAIL" python3 -c '
import json, os
d = {
    "event": os.environ.get("NOTIFY_EVENT", ""),
    "time": os.environ.get("NOTIFY_TIME", ""),
    "source": os.environ.get("NOTIFY_SRC", "orchestrate"),
}
for key, env in (
    ("agent", "NOTIFY_AG"),
    ("task", "NOTIFY_TK"),
    ("ticket", "NOTIFY_TICKET_V"),
    ("detail", "NOTIFY_DET"),
):
    v = os.environ.get(env, "")
    if v:
        d[key] = v
print(json.dumps(d, separators=(",", ":")))
' 2>/dev/null
  ) || JSON=""
fi

[ -n "$JSON" ] || exit 0

if [ "${NOTIFY_DRY_RUN:-}" = "1" ]; then
  printf '%s\n' "$JSON"
  exit 0
fi

curl -sS -m 5 -X POST "$AGENT_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$JSON" \
  >/dev/null 2>&1 || true
exit 0
