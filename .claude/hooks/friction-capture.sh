#!/usr/bin/env bash
# friction-capture.sh — Live friction telemetry ledger (SPEC-012 M1–M3/M5/M7).
#
# Shared handler for PostToolUseFailure, PermissionDenied, and StopFailure.
# Appends one NDJSON line per accepted event to
#   $MROOT/.claude/retro/friction.jsonl
# Schema (exact keys only — M2 no payload bodies):
#   {"ts":"<ISO-8601>","session_id":"<id>","event":"<name>","tool":"<name or empty>","path":"<optional>"}
#
# FAIL-OPEN (M7): ALWAYS exits 0. Never exits 2. One-line stderr on failure.
# No LLM, no network, bounded stdin read.
#
# Env knobs:
#   FRICTION_LEDGER            full path override for the ledger file (tests)
#   FRICTION_LEDGER_MAX_LINES  default 10000
#   FRICTION_LEDGER_MAX_BYTES  default 5242880 (5 MiB)

set -u   # NOT -e / NOT pipefail: every failure is handled explicitly -> exit 0

fail() { echo "friction-capture: $*" >&2; exit 0; }

command -v python3 >/dev/null 2>&1 || fail "python3 unavailable — skipping"

# Bounded stdin (match precompact-capture / memory-capture hygiene)
STDIN_JSON=$(head -c 65536) || fail "cannot read hook stdin"
[ -n "$STDIN_JSON" ] || fail "empty hook stdin"

# --- Resolve MROOT (worktree-aware) ----------------------------------------
if _fr_gc=$(git rev-parse --git-common-dir 2>/dev/null); then
  MROOT=$(cd -- "$(dirname -- "$_fr_gc")" && pwd) || fail "cannot resolve MROOT"
else
  MROOT="${CLAUDE_PROJECT_DIR:-}"
fi
{ [ -n "$MROOT" ] && [ -d "$MROOT" ]; } || fail "no repo root (not a git repo; CLAUDE_PROJECT_DIR unset)"

LEDGER="${FRICTION_LEDGER:-$MROOT/.claude/retro/friction.jsonl}"
MAX_LINES="${FRICTION_LEDGER_MAX_LINES:-10000}"
MAX_BYTES="${FRICTION_LEDGER_MAX_BYTES:-5242880}"
case "$MAX_LINES" in ''|*[!0-9]*) MAX_LINES=10000 ;; esac
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=5242880 ;; esac

LEDGER_DIR=$(dirname -- "$LEDGER")
mkdir -p "$LEDGER_DIR" 2>/dev/null || fail "cannot create $LEDGER_DIR"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/friction-cap.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$WORKDIR"' EXIT
printf '%s' "$STDIN_JSON" > "$WORKDIR/stdin.json" || fail "cannot stage stdin"

# --- Extract schema fields only; append + rotate under lock ----------------
# python owns parse + write so we never shell-interpolate tool bodies.
python3 - "$WORKDIR/stdin.json" "$LEDGER" "$MAX_LINES" "$MAX_BYTES" <<'PYEOF' || fail "capture/append failed"
import datetime, json, os, sys

stdin_path, ledger, max_lines_s, max_bytes_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    max_lines = max(1, int(max_lines_s))
except ValueError:
    max_lines = 10000
try:
    # Allow small values for tests (env override); floor at 1 byte.
    max_bytes = max(1, int(max_bytes_s))
except ValueError:
    max_bytes = 5242880
try:
    with open(stdin_path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.stderr.write("friction-capture: unparseable hook stdin JSON\n")
    sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("friction-capture: hook stdin is not a JSON object\n")
    sys.exit(1)

session_id = d.get("session_id")
if not isinstance(session_id, str) or not session_id:
    # Graceful skip — missing session_id (M1/M5/M7)
    sys.exit(0)

event = d.get("hook_event_name")
if not isinstance(event, str):
    event = ""

tool = d.get("tool_name")
if not isinstance(tool, str):
    tool = ""

path = ""
ti = d.get("tool_input")
if isinstance(ti, dict):
    for key in ("file_path", "path"):
        v = ti.get(key)
        if isinstance(v, str) and v:
            path = v
            break

ts = (
    datetime.datetime.now(datetime.timezone.utc)
    .isoformat()
    .replace("+00:00", "Z")
)

row = {
    "ts": ts,
    "session_id": session_id,
    "event": event,
    "tool": tool,
    "path": path,
}
# M2: only schema keys — never tool_result / error text / full tool_input
line = json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n"

lock_path = ledger + ".lock"
try:
    lock_fd = open(lock_path, "a+", encoding="utf-8")
except OSError as e:
    sys.stderr.write("friction-capture: cannot open lock: %s\n" % e)
    sys.exit(1)

have_lock = False
try:
    try:
        import fcntl
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        have_lock = True
    except Exception:
        have_lock = False

    try:
        with open(ledger, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())
    except OSError as e:
        sys.stderr.write("friction-capture: append failed: %s\n" % e)
        sys.exit(1)

    try:
        size = os.path.getsize(ledger)
    except OSError:
        size = 0

    need_rotate = size > max_bytes
    if not need_rotate:
        try:
            with open(ledger, "r", encoding="utf-8", errors="replace") as fh:
                nlines = sum(1 for _ in fh)
            need_rotate = nlines > max_lines
        except OSError:
            need_rotate = False

    if need_rotate:
        try:
            with open(ledger, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError as e:
            sys.stderr.write("friction-capture: rotate read failed: %s\n" % e)
            sys.exit(0)

        # Drop oldest until within both caps (keep newest).
        while lines:
            if len(lines) <= max_lines:
                byte_len = sum(len(x.encode("utf-8")) for x in lines)
                if byte_len <= max_bytes:
                    break
            lines.pop(0)

        tmp = ledger + ".tmp." + str(os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.writelines(lines)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, ledger)
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            sys.stderr.write("friction-capture: rotate write failed: %s\n" % e)
finally:
    if have_lock:
        try:
            import fcntl
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
    try:
        lock_fd.close()
    except Exception:
        pass
PYEOF

exit 0
