#!/usr/bin/env bash
#
# retro-gate/gate.sh — Phase-1 friction gate for /retro
#
# Reads a Claude Code session JSONL, scores it against five friction signals,
# and emits a single-line JSON verdict on stdout. Always exits 0 so callers
# can pipeline-grep without trapping. Schema-drift warnings go to stderr.
#
# Usage:    gate.sh <absolute-jsonl-path>
# Env:      RETRO_THRESHOLD  (float, default 5.0)
#
# Output:
#   {"score":N,"passed":bool,"threshold":N,"signals":[
#       {"name":"S1","count":N,"ids":["msg_..."]}, ...]}
#
# Design notes: see skills/retro-gate/SKILL.md and
# .claude/plans/2026-04-08-RETRO-001-session-retrospective.md §4.

set -u

JSONL="${1:-}"
THRESHOLD="${RETRO_THRESHOLD:-5.0}"

if [ -z "$JSONL" ]; then
  echo '{"score":0,"passed":false,"threshold":'"$THRESHOLD"',"signals":[],"error":"missing jsonl path"}'
  exit 0
fi

if [ ! -f "$JSONL" ]; then
  echo '{"score":0,"passed":false,"threshold":'"$THRESHOLD"',"signals":[],"error":"file not found"}'
  exit 0
fi

# Empty file → emit a clean zero verdict.
if [ ! -s "$JSONL" ]; then
  echo '{"score":0,"passed":false,"threshold":'"$THRESHOLD"',"signals":[]}'
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  THRESHOLD="${RETRO_THRESHOLD:-5.0}"
  echo "{\"score\":0,\"passed\":false,\"threshold\":${THRESHOLD},\"signals\":[],\"error\":\"python3 required\"}"
  exit 0
fi

python3 - "$JSONL" "$THRESHOLD" <<'PYEOF'
import json, re, sys

JSONL_PATH = sys.argv[1]
THRESHOLD = float(sys.argv[2])

# ---- Signal regexes ---------------------------------------------------------
# S1: explicit user rejection — strongest signal. Word-bounded to avoid
# matching "stopwatch", "wrongful", etc. Case-insensitive.
S1_RE = re.compile(
    r"\b(revert|stop|wrong|don'?t|why did you|no that'?s|undo|that'?s not|nope)\b",
    re.IGNORECASE,
)
# S4: assistant self-corrective retry phrasing.
S4_RE = re.compile(
    r"\b(let me try again|let me try a different|that didn'?t work|"
    r"actually,? let me|sorry,? let me|my mistake|i'?ll try)\b",
    re.IGNORECASE,
)

# ---- Tunables ---------------------------------------------------------------
S1_WEIGHT, S1_CAP = 3.0, 3
S2_WEIGHT          = 2.0  # per run of >=2 consecutive same-target tool errors
S3_WEIGHT, S3_MIN_EDITS, S3_WINDOW = 2.5, 3, 10  # >=3 edits same file in 10 turns
S4_WEIGHT, S4_CAP = 1.5, 3
S5_WEIGHT, S5_CAP = 1.0, 4
S5_LONG_ASSISTANT_CHARS = 500
S5_TERSE_USER_WORDS = 3

# ---- Schema-drift detection -------------------------------------------------
KNOWN_TOP_FIELDS = {"type", "uuid", "message", "parentUuid", "sessionId", "timestamp"}

# ---- Per-signal accumulators ------------------------------------------------
s1_hits, s4_hits, s5_hits = [], [], []
s2_runs = []                       # list of starting message ids per run
s3_files = {}                      # file_path -> list[(turn_idx, msg_id)]
edit_history_per_file = {}         # file_path -> set of turn_idx already counted

assistant_turn_idx = -1
last_assistant_len = 0
last_assistant_id = None
last_tool_was_error_run_len = 0
last_error_run_start_id = None
known_field_seen_in_first_50 = False
total_lines = 0


def msg_text(content):
    """Flatten an assistant or user message content into a single string."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t == "text":
                out.append(b.get("text", ""))
            elif t == "thinking":
                # Thinking blocks are not user-visible; skip.
                continue
        return "\n".join(out)
    return ""


def is_edit_tool(name):
    return name in ("Edit", "Write", "MultiEdit", "NotebookEdit")


def edit_file_path(inp):
    if isinstance(inp, dict):
        v = inp.get("file_path") or inp.get("notebook_path") or inp.get("path")
        if isinstance(v, str):
            return v
    return None


with open(JSONL_PATH, "r", encoding="utf-8", errors="replace") as f:
    for line_no, raw in enumerate(f):
        total_lines += 1
        raw = raw.strip()
        if not raw:
            continue
        try:
            d = json.loads(raw)
        except Exception:
            continue
        if not isinstance(d, dict):
            continue

        if line_no < 50 and KNOWN_TOP_FIELDS & set(d.keys()):
            known_field_seen_in_first_50 = True

        ttype = d.get("type")
        uuid = d.get("uuid") or d.get("messageId") or f"line:{line_no}"
        msg = d.get("message") if isinstance(d.get("message"), dict) else {}
        content = msg.get("content")

        if ttype == "assistant":
            assistant_turn_idx += 1
            text = msg_text(content)
            last_assistant_len = len(text)
            last_assistant_id = uuid

            # S4: retry phrases
            for _ in S4_RE.findall(text):
                s4_hits.append(uuid)

            # Walk content blocks for tool_use (S2 baseline + S3 edit-loop)
            if isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    name = b.get("name", "")
                    inp = b.get("input", {})

                    if is_edit_tool(name):
                        fp = edit_file_path(inp)
                        if fp:
                            s3_files.setdefault(fp, []).append(
                                (assistant_turn_idx, uuid)
                            )

        elif ttype == "user":
            # Skip system-injected user turns (slash command loads, skill
            # context, local-command caveats). These often contain plugin
            # docs that include words like "stop", "don't", "wrong" and
            # produced false positives during calibration.
            is_meta = bool(d.get("isMeta"))
            text = msg_text(content)

            # tool_result blocks live inside user messages
            had_tool_result = False
            if isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict) or b.get("type") != "tool_result":
                        continue
                    had_tool_result = True
                    is_err = bool(b.get("is_error"))
                    if is_err:
                        if last_tool_was_error_run_len == 0:
                            last_error_run_start_id = uuid
                        last_tool_was_error_run_len += 1
                    else:
                        if last_tool_was_error_run_len >= 2:
                            s2_runs.append(last_error_run_start_id)
                        last_tool_was_error_run_len = 0
                        last_error_run_start_id = None

            if not had_tool_result and isinstance(text, str) and text and not is_meta:
                # Real human user turn (not a tool_result wrapper, not meta,
                # and not a task-notification/agent-output message).
                is_system_notification = bool(re.search(r'<[a-z][a-z0-9-]*[\s>]', text))
                # S1: explicit reject — skip system notifications (contain XML tags
                # from task/agent output that embed rejection-like words)
                if not is_system_notification:
                    for _ in S1_RE.findall(text):
                        s1_hits.append(uuid)
                # S5: terse follow-up after long assistant turn — skip system
                # notifications (XML-tagged command/task messages) and plain
                # slash command invocations that represent user approval/delegation
                words = len(text.split())
                word_set = {w.lower().strip(".,!?") for w in text.split()}
                is_approval = bool(word_set & {
                    "waive","ok","okay","yes","sure","proceed","done","approved",
                    "ship","merge","lgtm","ack","go","yep","yup","fine","agreed",
                })
                if (
                    last_assistant_len >= S5_LONG_ASSISTANT_CHARS
                    and 0 < words <= S5_TERSE_USER_WORDS
                    and not is_system_notification
                    and not text.lstrip().startswith("/")
                    and not is_approval
                ):
                    s5_hits.append(uuid)
                # Reset error run on real user input
                if last_tool_was_error_run_len >= 2:
                    s2_runs.append(last_error_run_start_id)
                last_tool_was_error_run_len = 0
                last_error_run_start_id = None

# Flush a trailing error run at EOF.
if last_tool_was_error_run_len >= 2:
    s2_runs.append(last_error_run_start_id)

# ---- S3 windowed evaluation -------------------------------------------------
# A file scores once per distinct sliding window of S3_WINDOW assistant turns
# that contains >= S3_MIN_EDITS edits to that file.
s3_hits = []  # list of (file_path, anchor_msg_id)
for fp, edits in s3_files.items():
    if len(edits) < S3_MIN_EDITS:
        continue
    flagged = False
    for i in range(len(edits) - S3_MIN_EDITS + 1):
        window = edits[i : i + S3_MIN_EDITS]
        if window[-1][0] - window[0][0] <= S3_WINDOW:
            s3_hits.append((fp, window[0][1]))
            flagged = True
            break
    # One score per distinct file regardless of how many windows match.

# ---- Scoring ----------------------------------------------------------------
def capped(n, cap):
    return min(n, cap)

s1_count = capped(len(s1_hits), S1_CAP)
s2_count = len(s2_runs)
s3_count = len(s3_hits)
s4_count = capped(len(s4_hits), S4_CAP)
s5_count = capped(len(s5_hits), S5_CAP)

score = (
    s1_count * S1_WEIGHT
    + s2_count * S2_WEIGHT
    + s3_count * S3_WEIGHT
    + s4_count * S4_WEIGHT
    + s5_count * S5_WEIGHT
)
score = round(score, 2)
passed = score >= THRESHOLD

signals = []
if len(s1_hits):
    signals.append({"name": "S1", "count": s1_count, "ids": s1_hits[:S1_CAP]})
if s2_runs:
    signals.append({"name": "S2", "count": s2_count, "ids": s2_runs[:10]})
if s3_hits:
    signals.append(
        {
            "name": "S3",
            "count": s3_count,
            "ids": [mid for _, mid in s3_hits[:10]],
        }
    )
if len(s4_hits):
    signals.append({"name": "S4", "count": s4_count, "ids": s4_hits[:S4_CAP]})
if len(s5_hits):
    signals.append({"name": "S5", "count": s5_count, "ids": s5_hits[:S5_CAP]})

if total_lines > 0 and not known_field_seen_in_first_50:
    sys.stderr.write(
        "retro-gate: WARNING — no known JSONL fields seen in first 50 lines of "
        f"{JSONL_PATH}; possible schema drift.\n"
    )

out = {
    "score": score,
    "passed": passed,
    "threshold": THRESHOLD,
    "signals": signals,
}
sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
PYEOF

exit 0
