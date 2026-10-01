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

# Silent when URL unset or event missing. Unknown events do not POST.
[ -n "${AGENT_WEBHOOK_URL:-}" ] || exit 0
[ -n "$EVENT" ] || exit 0
case "$EVENT" in
  task_complete|task_blocked|qa_pass|qa_fail|council_verdict|council_findings|error) ;;
  *) exit 0 ;;
esac

TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
[ -n "$TIME" ] || TIME="1970-01-01T00:00:00Z"

SOURCE="${NOTIFY_SOURCE:-orchestrate}"
AGENT="${NOTIFY_AGENT:-}"
TASK="${NOTIFY_TASK:-}"
TICKET="${NOTIFY_TICKET:-}"

# Build JSON safely. Redact secrets and cut detail to 500 code points here,
# not with a bash substring (that can split a UTF-8 character).
JSON=""
if command -v python3 >/dev/null 2>&1; then
  JSON=$(
    NOTIFY_EVENT="$EVENT" NOTIFY_TIME="$TIME" NOTIFY_SRC="$SOURCE" \
    NOTIFY_AG="$AGENT" NOTIFY_TK="$TASK" NOTIFY_TICKET_V="$TICKET" \
    NOTIFY_DET="$DETAIL" python3 -c '
import json, os, re
def redact(v):
    v = re.sub(r"(?i)\bBearer\s+\S+", "Bearer [redacted]", v)
    v = re.sub(r"\bsk-[A-Za-z0-9]{8,}\b", "[redacted]", v)
    v = re.sub(r"\bghp_[A-Za-z0-9]{8,}\b", "[redacted]", v)
    v = re.sub(r"\bAKIA[0-9A-Z]{16}\b", "[redacted]", v)
    v = re.sub(r"\bxox[baprs]-[A-Za-z0-9-]{8,}\b", "[redacted]", v)
    v = re.sub(r"https://hooks\.slack\.com/\S+", "https://hooks.slack.com/[redacted]", v)
    if len(v) > 500:
        v = v[:500]
    return v
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
    if key == "detail":
        v = redact(v)
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

# URL and body stay off argv (a Slack or Discord secret in the URL shows in ps).
cfg=$(mktemp "${TMPDIR:-/tmp}/webhook-cfg.XXXXXX") || exit 0
body=$(mktemp "${TMPDIR:-/tmp}/webhook-body.XXXXXX") || { rm -f -- "$cfg"; exit 0; }
trap 'rm -f -- "$cfg" "$body"' EXIT
url_esc=$(printf '%s' "$AGENT_WEBHOOK_URL" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf 'url = "%s"\nheader = "Content-Type: application/json"\n' "$url_esc" > "$cfg"
printf '%s' "$JSON" > "$body"
curl -sS --fail --connect-timeout 5 --max-time 5 --proto '=https' \
  -K "$cfg" --data-binary @"$body" \
  >/dev/null 2>&1 || true
exit 0
