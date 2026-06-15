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
#       {"name":"S1","count":N,"ids":["00000000-0000-4000-8000-000000000004"]}, ...]}
#   (ids are real JSONL message UUIDs, or a "line:N" fallback when absent — never
#    `msg_`-prefixed; see skills/transcript-parse/SKILL.md.)
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

# Resolve the shared transcript-parse module dir relative to THIS script so the
# embedded python (fed via heredoc, where __file__ is "<stdin>") can import
# parselib regardless of the caller's CWD. Layout: skills/retro-gate/gate.sh
# and skills/transcript-parse/parselib.py share the skills/ parent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSELIB_DIR="$(cd "$SCRIPT_DIR/../transcript-parse" 2>/dev/null && pwd)"

python3 - "$JSONL" "$THRESHOLD" "${PARSELIB_DIR:-}" <<'PYEOF'
import json, re, sys, os  # json: only for serializing the verdict (parse via parselib)

JSONL_PATH = sys.argv[1]
THRESHOLD = float(sys.argv[2])
PARSELIB_DIR = sys.argv[3] if len(sys.argv) > 3 else ""

# ---- Shared parse primitives (SPEC-018 transcript-parse module) -------------
# /retro consumes the SAME JSONL parsing seam as /handoff. We import the line
# decoder, edit-tool helpers, meta-turn guard, and the canonical top-field set
# instead of re-implementing them here. The friction-scoring logic below is
# unchanged. If the import fails (module moved / partial install) we degrade to
# a clean zero verdict rather than crash, matching the other error exits above.
if PARSELIB_DIR and PARSELIB_DIR not in sys.path:
    sys.path.insert(0, PARSELIB_DIR)
try:
    from parselib import (
        parse_line,
        is_edit_tool,
        edit_file_path,
        is_meta,
        msg_text as _parselib_msg_text,
        KNOWN_TOP_FIELDS,
    )
except Exception:
    sys.stdout.write(
        '{"score":0,"passed":false,"threshold":%r,"signals":[],'
        '"error":"parselib import failed"}\n' % THRESHOLD
    )
    raise SystemExit(0)

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
# KNOWN_TOP_FIELDS imported from parselib (same canonical 6 fields). Used below
# exactly as before: `KNOWN_TOP_FIELDS & set(d.keys())` over the first 50 lines.
# gate.sh keeps its OWN drift loop + warning text ("retro-gate: WARNING ...")
# rather than parselib.iter_lines/schema_drift_warn, so stderr output is byte
# identical to the pre-refactor behavior.

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
    """Flatten content to text for friction scoring — DROPPING thinking blocks.

    CRITICAL: parselib.msg_text KEEPS thinking blocks (downstream dead-ends
    extraction needs them). Friction scoring must NOT see thinking text, so we
    strip thinking blocks here at the call site, then delegate the actual
    flattening to the shared parselib.msg_text. For list content we remove every
    block whose type == "thinking" before flattening; str content (and any
    non-list) passes straight through to parselib unchanged.

    Verified byte-for-byte identical to the previous inline flattening across
    the real-session regression corpus.
    """
    if isinstance(content, list):
        content = [
            b for b in content
            if not (isinstance(b, dict) and b.get("type") == "thinking")
        ]
    return _parselib_msg_text(content)


# is_edit_tool / edit_file_path imported from parselib (identical semantics).


with open(JSONL_PATH, "r", encoding="utf-8", errors="replace") as f:
    for line_no, raw in enumerate(f):
        total_lines += 1
        d = parse_line(raw)
        if d is None:
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
            meta = is_meta(d)  # parselib.is_meta — same bool(d.get("isMeta"))
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

            if not had_tool_result and isinstance(text, str) and text and not meta:
                # Real human user turn (not a tool_result wrapper, not meta,
                # and not a task-notification/agent-output message).
                is_system_notification = bool(re.search(r'<[a-z][a-z0-9-]*[\s>]', text))
                # Context-continuation summaries start with this sentinel; they
                # often contain rejection-like words in the session summary text.
                is_context_continuation = text.startswith(
                    "This session is being continued"
                )
                # S1: explicit reject — skip system notifications (XML-tagged)
                # and context-continuation summaries.
                if not is_system_notification and not is_context_continuation:
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
                    and not is_context_continuation
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
