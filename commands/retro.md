---
name: retro
description: Session retrospective — scan past sessions for friction patterns and propose targeted behavioral adjustments for team agents or plain Claude. --all --auto writes a scheduled report under .claude/retro/.
argument-hint: "[<session-id>] [--all] [--auto] [--why]"
agent: build
---

# /retro

Review past Claude session(s) for friction patterns and propose concrete behavioral
adjustments. Adjustments target a team agent (via `/adjust-agent`), plain Claude
(via `$MROOT/.claude/memory/claude/lessons.md`), or the plugin itself (via
`/backlog add` when the friction was caused by a gate bug, skill defect, or
missing feature).

When invoked with `--all`, `/retro` walks every project's sessions under `~/.claude/projects/`, pre-filters singleton patterns, and surfaces only patterns that recurred across 2+ sessions. This prevents the noise of one-off frustrations from becoming directives. Single-session mode (the default) surfaces all patterns regardless of recurrence.

Two-phase design keeps smooth sessions cheap:
- **Phase 1 (Gate):** cheap grep-based heuristic scoring. Smooth sessions exit immediately.
- **Phase 2 (Deep read):** subagent reads flagged sessions anchored at friction turns.

## Step 0: Resolve roots

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

## Step 1: Parse arguments

Parse the raw arguments string (everything after `/retro`).

Extract flags and positional arg:

```bash
MODE="single"        # single | all
AUTO=0               # 1 if --auto present
WHY=0                # 1 if --why present
EXPLICIT_SID=""      # non-empty if a bare word (not starting with --) was given

for arg in $ARGUMENTS; do
  case "$arg" in
    --all)  MODE="all" ;;
    --auto) AUTO=1 ;;
    --why)  WHY=1 ;;
    --*)    echo "Unknown flag: $arg" >&2 ;;
    *)      EXPLICIT_SID="$arg" ;;
  esac
done
```

Rules:
- `--all` and `<session-id>` are mutually exclusive. If both are present, print an
  error and exit non-zero.
- All other flag combinations are valid.

### Step 1b: Scheduled path lock (`--all --auto` only)

When both `MODE=all` and `AUTO=1`, this invocation is the **scheduled runner**
path (SPEC-012 S1–S9 / CDV-190). Acquire the project lock before discovery so
concurrent cron fires no-op cleanly. Empty/smooth/success paths MUST release
the lock (trap or explicit release). Lock-held skip does **not** write a report.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
SCHED_LOCK=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/scheduled-lock.sh 2>/dev/null || true)
SCHED_WRITER=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/write-scheduled-report.sh 2>/dev/null || true)
# Instrumentation for scheduled report (SPEC-012 S2); best-effort across steps.
SCANNED=0
SKIPPED_INPROG=0
SKIPPED_FILTER2=0
GATED_PASS=0
DEEP_READ=0
SCHEDULED_LOCK_HELD=0

if [ "$MODE" = "all" ] && [ "$AUTO" = "1" ]; then  # lint-ok: C1
  if [ -x "$SCHED_LOCK" ]; then
    bash "$SCHED_LOCK" acquire "$MROOT"
    LOCK_RC=$?
    if [ "$LOCK_RC" -eq 2 ]; then
      echo "scheduled retro: lock held, skipping"
      exit 0
    fi
    if [ "$LOCK_RC" -ne 0 ]; then
      echo "# retro: scheduled lock acquire failed (rc=$LOCK_RC) — continuing without lock" >&2
    else
      SCHEDULED_LOCK_HELD=1
      # Release on any exit from this shell block path.
      trap 'bash "$SCHED_LOCK" release "$MROOT" 2>/dev/null || true' EXIT
    fi
  fi
fi

# Helper: write scheduled report when --all --auto (no-op otherwise).
# Call sites: empty-set (2d), smooth gate (3c), empty findings (6a), end of 6h.
write_scheduled_report_if_needed() {
  # Args via env: NOTE, APPLIED_FILE, FOLLOWUP_FILE, DUP_FILE, OBS_FILE, SUMMARY
  [ "$MODE" = "all" ] && [ "$AUTO" = "1" ] || return 0  # lint-ok: C1
  [ -x "$SCHED_WRITER" ] || {
    echo "# retro: write-scheduled-report.sh missing — skip report" >&2
    return 0
  }
  # Session counters and paths are set in earlier orchestrator steps (not this fence).
  SKIPPED_TOTAL=$(( ${SKIPPED_INPROG:-0} + ${SKIPPED_FILTER2:-0} ))  # lint-ok: C1
  set -- --mroot "$MROOT" --mode all-auto \
    --scanned "${SCANNED:-0}" --skipped "${SKIPPED_TOTAL:-0}" \
    --gated "${GATED_PASS:-0}" --deep "${DEEP_READ:-0}"  # lint-ok: C1
  [ -n "${NOTE:-}" ] && set -- "$@" --note "$NOTE"  # lint-ok: C1
  [ -n "${APPLIED_FILE:-}" ] && [ -f "$APPLIED_FILE" ] && set -- "$@" --applied-file "$APPLIED_FILE"  # lint-ok: C1
  [ -n "${FOLLOWUP_FILE:-}" ] && [ -f "$FOLLOWUP_FILE" ] && set -- "$@" --followup-file "$FOLLOWUP_FILE"  # lint-ok: C1
  [ -n "${DUP_FILE:-}" ] && [ -f "$DUP_FILE" ] && set -- "$@" --duplicate-file "$DUP_FILE"  # lint-ok: C1
  [ -n "${OBS_FILE:-}" ] && [ -f "$OBS_FILE" ] && set -- "$@" --observations-file "$OBS_FILE"  # lint-ok: C1
  [ -n "${SUMMARY:-}" ] && set -- "$@" --summary "$SUMMARY"  # lint-ok: C1
  REPORT_PATH=$(bash "$SCHED_WRITER" "$@" 2>/dev/null) || REPORT_PATH=""  # lint-ok: C1
  if [ -n "$REPORT_PATH" ]; then
    echo "Report: $REPORT_PATH"
  fi
}
```

## Step 2: Session discovery

### Step 2.0: Resolve the shared transcript-parse module

`/retro` reuses the SPEC-018 `transcript-parse` module for two things in this
step: resolving an explicit session-id to its canonical file (`assemble.py
locate`) and the in-progress freshness guard (`freshness.sh check`). Locate the
module the same way Step 3a locates `gate.sh` (installed-plugin cache first,
then any cache match), so both seams come from the same plugin version.

```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ASSEMBLE=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-parse/assemble.py)
FRESHNESS=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-parse/freshness.sh)
```

If the module is missing, the two consumers below fall back to their original
inline behavior (noted at each site) so `/retro` still runs on a partial install.

### Step 2a: Locate the project directory under `~/.claude/projects/`

The project directory name is the absolute path to `MROOT` with every `/` replaced
by `-`. This matches Claude's own encoding scheme.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# Encode MROOT: replace each '/' with '-'
ENCODED=$(echo "$MROOT" | sed 's|/|-|g')
PROJECT_DIR="$HOME/.claude/projects/$ENCODED"
```

Verify the directory exists:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ENCODED=$(echo "$MROOT" | sed 's|/|-|g')
PROJECT_DIR="$HOME/.claude/projects/$ENCODED"
if [ ! -d "$PROJECT_DIR" ]; then
  echo "No Claude project directory found for this repo."
  echo "Expected: $PROJECT_DIR"
  echo "Available directories under ~/.claude/projects/:"
  ls "$HOME/.claude/projects/" 2>/dev/null | head -20
  exit 1
fi
```

### Step 2b: Collect candidate JSONL paths

**Default (single, no explicit SID):** most recently modified `.jsonl` in the project dir.

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ASSEMBLE=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-parse/assemble.py)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ENCODED=$(echo "$MROOT" | sed 's|/|-|g')
PROJECT_DIR="$HOME/.claude/projects/$ENCODED"
if [ "$MODE" = "single" ] && [ -z "$EXPLICIT_SID" ]; then  # lint-ok: C1
  CANDIDATES=$(find "$PROJECT_DIR" -maxdepth 1 -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-)

# Explicit SID: resolve to the canonical transcript via the shared module's
# `assemble.py locate`. This handles forked sessions correctly — when a uuid
# appears in several files (a fork copies its chosen-path prefix into the child),
# locate returns the *latest descendant* (greatest max-timestamp), i.e. the one
# canonical file, instead of every basename match.
elif [ -n "$EXPLICIT_SID" ]; then
  # Validate UUID shape before handing it to locate/find: unvalidated input would
  # allow glob metacharacters (`*`, `[a-f]*`) to enumerate the filesystem.
  case "$EXPLICIT_SID" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*) ;;
    *)
      echo "error: session-id must be a UUID (e.g. 00000000-0000-4000-8000-000000000004)" >&2
      exit 1
      ;;
  esac
  CANDIDATES=""
  if [ -f "$ASSEMBLE" ] && command -v python3 >/dev/null 2>&1; then
    # locate prints the canonical path on stdout (exit 0) or warns + exits 1.
    CANDIDATES=$(python3 "$ASSEMBLE" locate "$EXPLICIT_SID" 2>/dev/null || true)
  else
    # Fallback (module/python3 unavailable): original basename match across dirs.
    CANDIDATES=$(find "$HOME/.claude/projects" -name "${EXPLICIT_SID}.jsonl" 2>/dev/null)
    if [ -z "$CANDIDATES" ]; then
      CANDIDATES=$(find "$HOME/.claude/projects" -name "${EXPLICIT_SID}" 2>/dev/null)
    fi
  fi
  if [ -z "$CANDIDATES" ]; then
    echo "Session not found: $EXPLICIT_SID"
    exit 1
  fi

# --all: every JSONL under every project dir.
elif [ "$MODE" = "all" ]; then
  CANDIDATES=$(find "$HOME/.claude/projects" -name "*.jsonl" 2>/dev/null)
  SESSION_COUNT=$(printf '%s\n' "$CANDIDATES" | grep -c '\.jsonl$' || echo 0)
  if [ "$SESSION_COUNT" -gt 500 ]; then
    echo "# retro: --all found $SESSION_COUNT sessions; this will take a while" >&2
  fi
fi
```

### Step 2c: Apply filters

Two filters apply in every mode.

**Filter 1 — Skip in-progress sessions (modified within the last 60 seconds).**

Files that are still being written by an active Claude session must be excluded to
avoid reading a partial or live JSONL.

This is the 60 s in-progress guard shared with `/handoff`. Delegate the decision
to `freshness.sh check`, which returns exit 9 when the file was modified < 60 s
ago (and exit 0 when it is old enough). We suppress its stderr warning so the
`--why` output below stays in `/retro`'s own format; the local `stat`/`AGE`
computation now exists ONLY to render that `--why` line, not to make the skip
decision. If the module is unavailable we fall back to the original inline test.

```bash
NOW=$(date +%s)
FILTERED=""
SKIPPED_INPROG=${SKIPPED_INPROG:-0}
while IFS= read -r f; do
  [ -z "$f" ] && continue

  # mtime/AGE kept only for the --why message (same threshold: 60 s).
  MTIME=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  AGE=$(( NOW - ${MTIME:-NOW} ))

  if [ -f "$FRESHNESS" ]; then  # lint-ok: C1
    sh "$FRESHNESS" check "$f" >/dev/null 2>&1
    FRESH_RC=$?
  else
    # Fallback: replicate the original inline AGE<60 test (rc 9 == too fresh).
    if [ "$AGE" -lt 60 ]; then FRESH_RC=9; else FRESH_RC=0; fi
  fi

  if [ "$FRESH_RC" -eq 9 ]; then
    SKIPPED_INPROG=$(( SKIPPED_INPROG + 1 ))
    if [ "$WHY" = "1" ]; then  # lint-ok: C1
      echo "[skip] $(basename "$f" .jsonl)  (modified ${AGE}s ago — in-progress threshold: 60s)"
    fi
    continue
  fi
  FILTERED="$FILTERED
$f"
done <<< "$CANDIDATES"
CANDIDATES="$FILTERED"
```

**Filter 2 — Skip sessions where `/retro` was itself invoked.**

This prevents retro-of-retros loops. Claude Code records slash command
invocations as XML-style tags embedded in the message text payload, e.g.
`<command-name>/dev-team:retro</command-name>`. The marker is matched against
any retro-flavored command (the plugin is namespaced `/dev-team:retro`; bare
`/retro` forms are also tolerated). If that marker appears anywhere in the
file, skip it.

```bash
FILTERED=""
SKIPPED_FILTER2=${SKIPPED_FILTER2:-0}
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -qE '<command-name>/[a-z:-]*retro</command-name>' "$f" 2>/dev/null; then
    SKIPPED_FILTER2=$(( SKIPPED_FILTER2 + 1 ))
    if [ "$WHY" = "1" ]; then  # lint-ok: C1
      echo "[skip] $(basename "$f" .jsonl)  (contains /retro invocation — loop prevention)"
    fi
    continue
  fi
  FILTERED="$FILTERED
$f"
done <<< "$CANDIDATES"  # lint-ok: C1
SESSIONS=$(echo "$FILTERED" | sed '/^[[:space:]]*$/d')
SCANNED=$(printf '%s\n' "$SESSIONS" | sed '/^[[:space:]]*$/d' | grep -c . || echo 0)
```

### Step 2d: Empty-set guard

```bash
if [ -z "$SESSIONS" ]; then  # lint-ok: C1
  echo "No sessions to retro."
  # CDV-190 S3: empty-set still writes a short scheduled report when --all --auto.
  NOTE="No sessions to retro."
  SUMMARY="Applied: 0 | empty candidate set"
  write_scheduled_report_if_needed
  exit 0
fi
```

`SESSIONS` is now a newline-separated list of absolute paths to JSONL files ready
for analysis.

---

## Step 3: Phase-1 gate

### Step 3a: Locate gate.sh

Step 2.0's `$PDH` is from a separate shell; re-resolve it here (shell variables do not persist across the command's bash blocks):

```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
GATE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/gate.sh)

if [ ! -x "$GATE_SH" ]; then
  echo "# retro: gate.sh not found — cannot run phase-1 gate" >&2
  echo "# Check the installed plugin cache for skills/retro-gate/gate.sh" >&2
  exit 1
fi
```

Unlike the kickoff hook (which soft-skips when gate.sh is missing), `/retro` treats a missing gate as a hard error: the gate is the gating mechanism for the entire command.

### Step 3b: Gate each session with time budget

Budget policy (two modes):
- **single/explicit-SID mode**: 5s total budget (per SPEC-012 "exit in under 5 seconds on smooth sessions").
- **`--all` mode**: no total budget cap; instead a hard 2s per-file cap prevents any one session from dominating.

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
GATE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-parse/freshness-gate.sh)
FLAGGED_SESSIONS=""
ANCHOR_IDS=""        # newline-separated "<jsonl-path> <id>" pairs for Step 4
GATE_START=$(date +%s)
TOTAL=$(echo "$SESSIONS" | wc -l)  # lint-ok: C1
N=0

# Total budget: 5s for single/explicit mode; unlimited for --all (per-file cap applies instead).
TOTAL_BUDGET=5

while IFS= read -r JSONL; do
  [ -z "$JSONL" ] && continue
  N=$(( N + 1 ))

  # Total-budget check — only enforce in single/explicit mode.
  if [ "$MODE" != "all" ]; then  # lint-ok: C1
    ELAPSED=$(( $(date +%s) - GATE_START ))
    if [ "$ELAPSED" -ge $TOTAL_BUDGET ]; then
      REMAINING=$(( TOTAL - N + 1 ))
      echo "# retro: gate budget exceeded after $(( N - 1 ))/$TOTAL sessions (${ELAPSED}s >= ${TOTAL_BUDGET}s) — skipping remaining $REMAINING"
      break
    fi
  fi

  # Per-file hard cap: 2s timeout for --all, unlimited (timeout(1) not assumed) for single.
  if [ "$MODE" = "all" ]; then
    FILE_START=$(date +%s)
    GATE_OUT=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)
    FILE_ELAPSED=$(( $(date +%s) - FILE_START ))
    if [ "$FILE_ELAPSED" -ge 2 ]; then
      echo "# retro: gate timed out on $(basename "$JSONL" .jsonl) (${FILE_ELAPSED}s >= 2s per-file cap) — skipping" >&2
      continue
    fi
  else
    GATE_OUT=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)
  fi
  PASSED=$(echo "$GATE_OUT" | grep -o '"passed": *true' | head -1)
  SCORE=$(echo "$GATE_OUT" | grep -o '"score": *[0-9][0-9.]*' | head -1 | grep -o '[0-9][0-9.]*')
  THRESHOLD=$(echo "$GATE_OUT" | grep -o '"threshold": *[0-9][0-9.]*' | head -1 | grep -o '[0-9][0-9.]*')

  if [ -n "$PASSED" ]; then
    GATED_PASS=$(( ${GATED_PASS:-0} + 1 ))
    DEEP_READ=$(( ${DEEP_READ:-0} + 1 ))
    FLAGGED_SESSIONS="$FLAGGED_SESSIONS
$JSONL"
    # Collect anchor message IDs from signals[].ids[] for Step 4.
    # gate.sh emits real Claude Code UUIDs (not `msg_*` prefixed), so parse JSON
    # directly rather than regex-matching a prefix.
    IDS=$(echo "$GATE_OUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    for s in d.get("signals", []):
        for i in s.get("ids", []):
            print(i)
except Exception:
    pass')
    while IFS= read -r ID; do
      [ -z "$ID" ] && continue
      ANCHOR_IDS="$ANCHOR_IDS
$JSONL $ID"
    done <<< "$IDS"
  fi

  # --why output: per-session signal table
  if [ "$WHY" = "1" ]; then  # lint-ok: C1
    SID=$(basename "$JSONL" .jsonl)
    PASSED_LABEL="passed"
    [ -z "$PASSED" ] && PASSED_LABEL="not passed"
    echo "Session: $SID"
    echo "Score: ${SCORE:-?} / ${THRESHOLD:-5.0} ($PASSED_LABEL)"

    echo "$GATE_OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
matched = {s["name"]: s["count"] for s in d.get("signals", [])}
if matched:
    print("Matched signals:")
    for name, count in sorted(matched.items()):
        print("  %s x%s" % (name, count))
else:
    print("Matched signals: (none)")
not_matched = [s for s in ("S1","S2","S3","S4","S5") if s not in matched]
if not_matched:
    print("Not matched: " + ", ".join(not_matched))
'
    echo ""
  fi

done <<< "$SESSIONS"

FLAGGED_SESSIONS=$(echo "$FLAGGED_SESSIONS" | sed '/^[[:space:]]*$/d')
ANCHOR_IDS=$(echo "$ANCHOR_IDS" | sed '/^[[:space:]]*$/d')
```

### Step 3c: Early exit if nothing flagged

```bash
if [ -z "$FLAGGED_SESSIONS" ]; then  # lint-ok: C1
  echo "No friction detected — nothing to retro."
  # CDV-190 S3: all-smooth still writes a short scheduled report when --all --auto.
  NOTE="No friction detected — nothing to retro (all smooth)."
  SUMMARY="Applied: 0 | all-smooth | scanned=${SCANNED:-0} gated=0"  # lint-ok: C1
  write_scheduled_report_if_needed  # lint-ok: C1
  exit 0
fi
```

---

## Step 4: Phase-2 subagent spawn

At this point `$FLAGGED_SESSIONS` holds the newline-separated JSONL paths that
passed the phase-1 gate, and `$ANCHOR_IDS` holds newline-separated
`<jsonl-path> <message-id>` pairs. See `skills/retro-subagent/SKILL.md` for the
full input/output contract — this section enforces it.

### Step 4b: Build per-session Task inputs

For every flagged session, assemble the four inputs the subagent expects:

- `SESSION_JSONL` — absolute path (one line of `$FLAGGED_SESSIONS`)
- `ANCHOR_MESSAGE_IDS_JSON` — JSON array of message IDs collected by the gate
  for this specific JSONL, extracted from `$ANCHOR_IDS`
- `FRICTION_SIGNALS_JSON` — verbatim stdout of `gate.sh` for this JSONL.
  Before each Task spawn, re-run the gate per session:
  `FRICTION_SIGNALS_JSON=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)`.
  Re-invocation is cheap (~60ms per session) and avoids caching complexity.
- `EXISTING_RULES` — per-target rules text, coalesced to the literal sentinel
  `empty` for any missing/empty file (SKILL.md:50 input contract). Built in the
  Step 4c block below via `load_rules_for_prompt`. NOTE: only the SUBAGENT-PROMPT
  path gets the sentinel — Step 5b's classifier (load_rules_raw) keeps the raw
  empty string (it needs a real emptiness test, see retro.md Step 5b).


### Step 4c: Spawn subagents in parallel

IMPORTANT — instruction to the Claude interpreting this command:

Count the flagged sessions (`N = wc -l <<< "$FLAGGED_SESSIONS"`). For each one,
you (the orchestrating Claude) MUST spawn a `Task` tool call using the prompt
template from `skills/retro-subagent/SKILL.md` §"Subagent prompt template",
substituting the inputs built in Step 4b. When `N > 1`, emit all `Task` calls
in a single tool-use block so they run in parallel — do not await them one at a
time.

Use `subagent_type: "general-purpose"` (or "Explore" if available). This is
read-only analysis work; do NOT route to one of the team roles (pm, tech-lead,
ic5, ic4, devops, qa, ds) — those are the *subjects* of the retro, not the
analyst. The rationale: we want an impartial reader who is not itself one of the
agents whose behavior is being critiqued.

Each Task returns exactly one line of JSON matching the output schema in
`skills/retro-subagent/SKILL.md` §"Output schema". Collect all returned strings
into `SUBAGENT_RESULTS` (newline-separated, one row per flagged session, each
row `<absolute_jsonl_path>\t<returned_json>`). This is the single canonical
variable name and format — Step 4d iterates `SUBAGENT_RESULTS` and splits on
the first tab.

Per-session construction, to be performed by the orchestrating Claude before
each Task spawn:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
GATE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-parse/freshness-gate.sh)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# For each $JSONL in $FLAGGED_SESSIONS:  # lint-ok: C1
FRICTION_SIGNALS_JSON=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)
ANCHOR_MESSAGE_IDS_JSON=$(echo "$ANCHOR_IDS" | python3 -c "  # lint-ok: C1
import sys, json
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
ids = [p.split(None,1)[1] for p in lines if p.startswith('$JSONL ')]
print(json.dumps(ids))
")
# EXISTING_RULES for the prompt: load each per-target rules file and coalesce a
# missing/empty file to the literal sentinel "empty" (SKILL.md:50 input contract).
# load_rules_for_prompt returns the raw file text, or the literal "empty" when the
# file is absent/empty. This sentinel lives ONLY on the prompt-substitution path;
# Step 5b's classifier deliberately uses the raw empty string instead (it needs a
# real emptiness test), so do NOT route the classifier through this helper.
load_rules_for_prompt() {
  # $* (all args) instead of $1 — avoids Claude Code arg substitution in command text.
  [ -s "$*" ] && cat "$*" || printf 'empty'
}
ER_PM=$(load_rules_for_prompt       "$MROOT/.claude/memory/pm/directives.md")
ER_TL=$(load_rules_for_prompt       "$MROOT/.claude/memory/tech-lead/directives.md")
ER_IC5=$(load_rules_for_prompt      "$MROOT/.claude/memory/ic5/directives.md")
ER_IC4=$(load_rules_for_prompt      "$MROOT/.claude/memory/ic4/directives.md")
ER_DEVOPS=$(load_rules_for_prompt   "$MROOT/.claude/memory/devops/directives.md")
ER_QA=$(load_rules_for_prompt       "$MROOT/.claude/memory/qa/directives.md")
ER_DS=$(load_rules_for_prompt       "$MROOT/.claude/memory/ds/directives.md")
ER_CLAUDE=$(load_rules_for_prompt   "$MROOT/.claude/memory/claude/lessons.md")
# ... substitute FRICTION_SIGNALS_JSON, ANCHOR_MESSAGE_IDS_JSON, SESSION_JSONL,
# and the EXISTING_RULES.* entries (ER_PM..ER_CLAUDE above) into the prompt
# template from skills/retro-subagent/SKILL.md §"Subagent prompt template", then
# spawn Task.
```

After each parallel Task call returns with its `$RETURNED_JSON`, append one row
to `SUBAGENT_RESULTS`:

```bash
SUBAGENT_RESULTS="${SUBAGENT_RESULTS}${JSONL}$(printf '\t')${RETURNED_JSON}
"
```

All Task calls for the flagged sessions MUST be emitted in one tool-use block
so they run in parallel; the accumulation above describes the logical shape of
`SUBAGENT_RESULTS` that Step 4d consumes.

### Step 4d: Parse + validate per the SKILL.md contract

Use `python3` to parse the JSON. Emit tab-separated rows to stdout:

```
proposal<TAB>target<TAB>proposed_text<TAB>confidence<TAB>citation_count<TAB>citations_json<TAB>pattern_summary<TAB>source_jsonl
observation<TAB>description<TAB>source_jsonl
fabrication_anchor<TAB>anchor_id<TAB>turn_id<TAB>fabricated_claim_text<TAB>evidence_for_fabrication
```

`citation_count` (an int) drives ranking (`confidence * citation_count`, SPEC-012
SHOULD); `citations_json` carries the actual `[{message_id, excerpt}, …]` array as
a single JSON-encoded field so the Step 6 `Evidence:` display can render the real
excerpt text. `json.dumps` escapes tabs/newlines, so the array is TSV-safe in one
column.

```bash
ALLOWED_TARGETS="pm tech-lead ic5 ic4 devops qa ds claude plugin"

parse_one() {
  # Caller sets RETRO_JSON and RETRO_SRC before invoking.
  # No function parameters — avoids Claude Code $1/$2 arg substitution in skill text.
  python3 - <<'PY'
import json, os
src = os.environ.get("RETRO_SRC", "")
raw = os.environ.get("RETRO_JSON", "")
try:
    d = json.loads(raw)
except Exception:
    raise SystemExit(0)
for p in d.get("proposals", []) or []:
    cites = p.get("citations") or []
    # Keep BOTH: the count (for the confidence*citation_count rank key) and the
    # actual {message_id, excerpt} pairs (for the Step 6 Evidence: display). The
    # JSON array is one TSV-safe field — json.dumps escapes any tab/newline in
    # the excerpt text, so it cannot break the column structure.
    # Validation rule 2 (SKILL.md:225): drop any citation missing message_id or
    # excerpt, or with empty values, BEFORE counting. len(norm) then feeds the
    # rank key and the Rule-1 count gate (Step 4d), so a proposal whose only
    # citation is empty drops to zero valid citations and fails Rule 1.
    norm = []
    for c in cites:
        if not isinstance(c, dict):
            continue
        mid = c.get("message_id", "")
        exc = c.get("excerpt", "")
        if not isinstance(mid, str) or not isinstance(exc, str):
            continue
        if mid == "" or exc == "":
            continue
        norm.append({"message_id": mid, "excerpt": exc})
    cites_json = json.dumps(norm, separators=(",", ":"))
    print("proposal\t%s\t%s\t%s\t%d\t%s\t%s\t%s" % (
        p.get("target",""),
        (p.get("proposed_text","") or "").replace("\t"," "),
        p.get("confidence",0), len(norm), cites_json,
        p.get("pattern_summary",""), src))
for o in d.get("observations", []) or []:
    print("observation\t%s\t%s" % (
        (o.get("description","") or "").replace("\t"," "), src))
# fabrication_anchors (SPEC-012 §Phase 2 / SPEC-013 §Integration Hooks)
for fa in d.get("fabrication_anchors", []) or []:
    aid   = (fa.get("anchor_id","") or "").replace("\t"," ")
    tid   = (fa.get("turn_id","") or "").replace("\t"," ")
    claim = (fa.get("fabricated_claim_text","") or "").replace("\t"," ")
    evid  = (fa.get("evidence_for_fabrication","") or "").replace("\t"," ")
    # Drop records missing required fields (SKILL.md validation contract)
    if not tid or not evid or not aid or not claim:
        continue
    print("fabrication_anchor\t%s\t%s\t%s\t%s" % (aid, tid, claim, evid))
PY
}

RAW_PROPOSALS=""
OBSERVATIONS=""
RAW_FABRICATION_ANCHORS=""   # newline-separated: anchor_id<TAB>turn_id<TAB>claim<TAB>evidence

while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  # Each line in SUBAGENT_RESULTS is "<src-jsonl>\t<json>" (see Step 4c).
  SRC=$(printf '%s' "$LINE" | cut -f1)
  JSON=$(printf '%s' "$LINE" | cut -f2-)

  while IFS=$'\t' read -r KIND F1 F2 F3 F4 F5 F6 F7; do
    case "$KIND" in
      fabrication_anchor)
        AID="$F1"; TID="$F2"; CLAIM="$F3"; EVID="$F4"
        [ -z "$AID" ] || [ -z "$TID" ] || [ -z "$EVID" ] && continue
        RAW_FABRICATION_ANCHORS="$RAW_FABRICATION_ANCHORS
$AID	$TID	$CLAIM	$EVID"
        ;;
      proposal)
        TARGET="$F1"; TEXT="$F2"; CONF="$F3"; CITES="$F4"; CITESJSON="$F5"; PSUM="$F6"; SRCJ="$F7"
        # Rule 1: citations.length > 0
        if [ "${CITES:-0}" -lt 1 ]; then
          echo "# retro: dropped proposal (reason: zero citations) target=$TARGET summary=$PSUM" >&2
          continue
        fi
        # Rule 2: target in allowlist (pure string match, not regex — TARGET may
        # contain metacharacters from an adversarial subagent).
        case " $ALLOWED_TARGETS " in
          *" $TARGET "*) ;;
          *)
            echo "# retro: dropped proposal (reason: disallowed target=$TARGET) summary=$PSUM" >&2
            continue
            ;;
        esac
        # Rule 3: proposed_text non-empty and <= 200 chars
        LEN=${#TEXT}
        if [ -z "$TEXT" ] || [ "$LEN" -gt 200 ]; then
          echo "# retro: dropped proposal (reason: bad text length=$LEN) target=$TARGET" >&2
          continue
        fi
        # Rule 3b: reject control characters (tab/newline corrupt the downstream
        # TSV and ANSI escapes would injure the operator terminal).
        case "$TEXT" in
          *[$'\t\n\r'$'\001'-$'\037'$'\177']*)
            echo "# retro: dropped proposal (control chars in text) target=$TARGET" >&2
            continue
            ;;
        esac
        # Rule 3c: reject obvious prompt-injection / exfil strings.
        case "$TEXT" in
          *http://*|*https://*|*"curl "*|*"wget "*|*"sudo "*|*"ignore previous"*|*"<command-name>"*|*'`'*)
            echo "# retro: dropped proposal (suspicious content) target=$TARGET" >&2
            continue
            ;;
        esac
        # Rule 5 (SKILL.md): pattern_summary non-empty.
        if [ -z "$PSUM" ]; then
          echo "# retro: dropped proposal (reason: empty pattern_summary) target=$TARGET" >&2
          continue
        fi
        # Rule 6 (SKILL.md:225): confidence present, numeric, and within [0.0, 1.0].
        # MUST run BEFORE the rank multiply — an out-of-range or non-numeric
        # confidence would otherwise inflate RANK=confidence*citation_count and
        # float a bogus proposal into the top-5 (Step 4e sort). The awk regex
        # rejects non-numeric / empty CONF; the range check rejects <0 or >1. awk
        # exits 0 only when CONF is a valid in-range number (avoid `!` here so the
        # gate is copy-paste safe under zsh).
        if awk -v c="$CONF" 'BEGIN{ if (c ~ /^-?[0-9]+(\.[0-9]+)?$/) { v=c+0; if (v >= 0.0 && v <= 1.0) exit 0 } exit 1 }'; then
          : # confidence valid — fall through to ranking
        else
          echo "# retro: dropped proposal (reason: confidence not in [0.0,1.0]) target=$TARGET conf=$CONF" >&2
          continue
        fi
        # Compute rank key = confidence * citation_count (awk for float math).
        # CONF is validated numeric+in-range above, so the multiply cannot inflate.
        RANK=$(awk -v c="$CONF" -v n="$CITES" 'BEGIN{printf "%.6f", c*n}')
        # RAW_PROPOSALS columns (TSV): 1 rank, 2 target, 3 confidence,
        # 4 citation_count, 5 pattern_summary, 6 proposed_text, 7 source_jsonl,
        # 8 citations_json. col8 (JSON array) is TSV-safe (see Step 4d parser).
        RAW_PROPOSALS="$RAW_PROPOSALS
$RANK	$TARGET	$CONF	$CITES	$PSUM	$TEXT	$SRCJ	$CITESJSON"
        ;;
      observation)
        DESC="$F1"; SRCJ="$F2"
        [ -z "$DESC" ] && continue
        OBSERVATIONS="$OBSERVATIONS
$DESC	$SRCJ"
        ;;
    esac
  done < <(RETRO_JSON="$JSON" RETRO_SRC="$SRC" parse_one)
done <<< "$SUBAGENT_RESULTS"  # lint-ok: C1

RAW_PROPOSALS=$(echo "$RAW_PROPOSALS" | sed '/^[[:space:]]*$/d')
OBSERVATIONS=$(echo "$OBSERVATIONS"  | sed '/^[[:space:]]*$/d')
RAW_FABRICATION_ANCHORS=$(echo "$RAW_FABRICATION_ANCHORS" | sed '/^[[:space:]]*$/d')

# Dedup fabrication anchors by anchor_id — per SPEC-012 §Integration Hooks,
# surface at most one hint per distinct anchor_id within a single retro run.
# Cross-run dedup is automatic via the deterministic hash in anchor_id.
FABRICATION_ANCHORS=""
SEEN_ANCHOR_IDS=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  AID=$(printf '%s' "$row" | cut -f1)
  if printf '%s\n' "$SEEN_ANCHOR_IDS" | grep -Fxq -- "$AID"; then
    echo "# retro: dedup fabrication_anchor anchor_id=$AID (already seen in this run)" >&2
    continue
  fi
  SEEN_ANCHOR_IDS="$SEEN_ANCHOR_IDS
$AID"
  FABRICATION_ANCHORS="$FABRICATION_ANCHORS
$row"
done <<< "$RAW_FABRICATION_ANCHORS"
FABRICATION_ANCHORS=$(echo "$FABRICATION_ANCHORS" | sed '/^[[:space:]]*$/d')
```

### Step 4e: Rank and cap to top 5

Per SPEC-012 SHOULD: rank surviving proposals by `confidence * len(citations)`
descending, keep the top 5.

```bash
# Sort numerically by rank key (column 1), descending, then take top 5.
RAW_PROPOSALS=$(printf '%s\n' "$RAW_PROPOSALS" | sort -t$'\t' -k1,1 -nr | head -5)
```

### Step 4f: --all repeat-filter pre-grouping (hint for Step 5)

When `$MODE = "all"` the spec asks us to collapse patterns that occur in only
one session. Step 5 (routing/dedup) is the natural home for that, but we pre-tag
singletons here so Step 5 has the info without re-parsing. We group by
`pattern_summary` and mark any summary with a single occurrence across the whole
RAW_PROPOSALS set — Step 5 may drop those when `$MODE = "all"`.

```bash
if [ "$MODE" = "all" ] && [ -n "$RAW_PROPOSALS" ]; then  # lint-ok: C1
  # Count occurrences of each pattern_summary (column 5 after the rank key).
  SINGLETON_PATTERNS=$(printf '%s\n' "$RAW_PROPOSALS" \
    | cut -f5 | sort | uniq -c \
    | while read -r _cnt _pat; do [ "$_cnt" -eq 1 ] && printf '%s\n' "$_pat"; done)
  # Step 5 will consume $SINGLETON_PATTERNS alongside $RAW_PROPOSALS.
fi
```

`RAW_PROPOSALS`, `OBSERVATIONS`, and (when `--all`) `SINGLETON_PATTERNS` are the
handoff to Step 5.

---

## Step 5: Phase-3 routing and deduplication

Classify each surviving proposal in `$RAW_PROPOSALS` as `NEW`, `TIGHTEN`, or
`DUPLICATE` against the existing rule corpus for its target. Output is
`CLASSIFIED_PROPOSALS` (TSV, schema documented at the end of this step).

`OBSERVATIONS` flows through untouched — it's handed to Step 6 as-is.

### Step 5a: `--all` singleton filter

SPEC-012 says `--all` should only surface patterns that repeated across sessions.
Step 4f tagged singleton `pattern_summary` values in `$SINGLETON_PATTERNS`; drop
any proposal whose column-5 `pattern_summary` matches, and log each drop so the
user can see why the proposal was suppressed.

```bash
if [ "$MODE" = "all" ] && [ -n "$SINGLETON_PATTERNS" ]; then  # lint-ok: C1
  FILTERED=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    psum=$(printf '%s' "$row" | cut -f5)
    if printf '%s\n' "$SINGLETON_PATTERNS" | grep -Fxq -- "$psum"; then
      echo "# retro: dropped singleton pattern '$psum' (--all mode)" >&2
      continue
    fi
    FILTERED="${FILTERED}${row}"$'\n'
  done <<< "$RAW_PROPOSALS"
  RAW_PROPOSALS=$(printf '%s' "$FILTERED" | sed '/^[[:space:]]*$/d')
fi
```

### Step 5b: Re-load existing rules per target

We re-load each per-target rules file here rather than trust variable
persistence across the interpreted `.md` boundaries. Missing files collapse to
the empty string (NOT the literal `"empty"` — the classifier needs a real
emptiness test here, unlike the Step 4c prompt-substitution helper).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
load_rules_raw() {
  # Use $* (all args) instead of $1 — avoids Claude Code arg substitution in skill text.
  [ -s "$*" ] && cat "$*" || printf ''
}

RULES_PM=$(load_rules_raw       "$MROOT/.claude/memory/pm/directives.md")
RULES_TL=$(load_rules_raw       "$MROOT/.claude/memory/tech-lead/directives.md")
RULES_IC5=$(load_rules_raw      "$MROOT/.claude/memory/ic5/directives.md")
RULES_IC4=$(load_rules_raw      "$MROOT/.claude/memory/ic4/directives.md")
RULES_DEVOPS=$(load_rules_raw   "$MROOT/.claude/memory/devops/directives.md")
RULES_QA=$(load_rules_raw       "$MROOT/.claude/memory/qa/directives.md")
RULES_DS=$(load_rules_raw       "$MROOT/.claude/memory/ds/directives.md")
RULES_CLAUDE=$(load_rules_raw   "$MROOT/.claude/memory/claude/lessons.md")

```

### Step 5c: Deterministic NEW / TIGHTEN / DUPLICATE classification

We run a single Python pass per proposal. Python3 is the Step 4 fallback
tool; it computes jaccard on token sets with the tokenization rules below and
emits one TSV line per proposal containing the action, best-match line, and best
jaccard score.

**Tokenization contract (explicit, short stopword list):**
- lowercase
- split on `[^a-z0-9]+`
- drop stopwords: `a an the to of for is are be was were in on at by with and or
  not no must should will can do does did it its this that these those as if`
- drop empty tokens

**Thresholds (from plan §6; do not tune without measurement):**
- Pass 1 (keyword overlap): ≥ 2 shared non-stopword tokens between a rule line
  and `pattern_summary` → candidate.
- Pass 2 (fuzzy jaccard ≥ 0.35 on `proposed_text` vs rule line) → candidate.
- No candidates → `NEW`.
- Any candidate with jaccard ≥ 0.65 vs `proposed_text` → `DUPLICATE`.
- Otherwise → `TIGHTEN`; `existing_ref` is the highest-scoring candidate line.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
CLASSIFIED_PROPOSALS=""
TIGHTEN_PATTERNS=""

while IFS= read -r row; do
  [ -z "$row" ] && continue
  # RAW_PROPOSALS columns: 1 rank, 2 target, 3 confidence, 4 citation_count,
  # 5 pattern_summary, 6 proposed_text, 7 source_jsonl, 8 citations_json.
  target=$(printf '%s' "$row" | cut -f2)
  citation_count=$(printf '%s' "$row" | cut -f4)
  pattern_summary=$(printf '%s' "$row" | cut -f5)
  proposed_text=$(printf '%s' "$row" | cut -f6)
  source_jsonl=$(printf '%s' "$row" | cut -f7)
  citations_json=$(printf '%s' "$row" | cut -f8)

  if [ "$target" = "claude" ]; then
    rules_text=$(cat "$MROOT/.claude/memory/claude/lessons.md" 2>/dev/null || true)
  elif [ "$target" = "plugin" ]; then
    # Plugin proposals go to the backlog — no existing-rule corpus to diff against.
    rules_text=""
  else
    rules_text=$(cat "$MROOT/.claude/memory/$target/directives.md" 2>/dev/null || true)
  fi

  # Run the classifier. Inputs travel via env vars to avoid quoting hell.
  CLASS_OUT=$(
    RULES="$rules_text" \
    PATTERN="$pattern_summary" \
    PROPOSED="$proposed_text" \
    python3 - <<'PY'
import os, re

STOP = {
    "a","an","the","to","of","for","is","are","be","was","were","in","on","at",
    "by","with","and","or","not","no","must","should","will","can","do","does",
    "did","it","its","this","that","these","those","as","if",
}

def tokens(s: str):
    return {t for t in re.split(r"[^a-z0-9]+", (s or "").lower()) if t and t not in STOP}

def jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0

rules_text = os.environ.get("RULES", "")
pattern = os.environ.get("PATTERN", "")
proposed = os.environ.get("PROPOSED", "")

lines = [ln.strip() for ln in rules_text.splitlines() if ln.strip()]
if not lines:
    # Empty rules file -> NEW
    print("NEW\t\t0.0")
    raise SystemExit

pat_toks = tokens(pattern)
prop_toks = tokens(proposed)

# Pass 1 -- keyword overlap on pattern_summary (>= 2 shared tokens).
# Pass 2 -- fuzzy jaccard on proposed_text (>= 0.35).
candidates = []  # list of (line, jaccard_vs_proposed)
seen = set()
for ln in lines:
    ln_toks = tokens(ln)
    j = jaccard(ln_toks, prop_toks)
    overlap = len(ln_toks & pat_toks)
    if overlap >= 2 or j >= 0.35:
        if ln not in seen:
            seen.add(ln)
            candidates.append((ln, j))

if not candidates:
    print("NEW\t\t0.0")
    raise SystemExit

candidates.sort(key=lambda x: x[1], reverse=True)
best_line, best_j = candidates[0]

if best_j >= 0.65:
    action = "DUPLICATE"
else:
    action = "TIGHTEN"

# Sanitize best_line for TSV: collapse tabs/newlines.
best_line = re.sub(r"[\t\r\n]+", " ", best_line)
print(f"{action}\t{best_line}\t{best_j:.3f}")
PY
  )

  action=$(printf '%s' "$CLASS_OUT" | cut -f1)
  existing_ref=$(printf '%s' "$CLASS_OUT" | cut -f2)
  best_j=$(printf '%s' "$CLASS_OUT" | cut -f3)

  # For TIGHTEN we leave proposed_text as-is in the TSV. The orchestrating
  # Claude performs the inline rewrite step below (Step 5d) when presenting
  # proposals to the user in Step 6.
  #
  # ============================================================================
  # CANONICAL CLASSIFIED_PROPOSALS SCHEMA (TSV, one proposal per line).
  # This block is the ONE authoritative definition. Every other site that reads
  # or documents these columns (Step 5d, Step 5e, the Step 5 handoff, Step 6c)
  # MUST reference this block by name — do NOT restate the column list elsewhere,
  # so an off-by-one cut -fN cannot drift back in.
  #   1 target           pm|tech-lead|ic5|ic4|devops|qa|ds|claude|plugin
  #   2 action           NEW|TIGHTEN|DUPLICATE
  #   3 pattern_summary  short tag from Phase-2 subagent
  #   4 proposed_text    imperative sentence (deterministically merged by Step 5d for TIGHTEN)
  #   5 citation_count   int — number of citations (rank key = confidence*count)
  #   6 existing_ref     rule line matched (empty for NEW)
  #   7 best_jaccard     float, "0.000".."1.000" — debug/telemetry
  #   8 source_jsonl     originating session file (per-proposal provenance; drives
  #                      the --all per-target session count M in Step 6c)
  #   9 citations_json   JSON array of {message_id, excerpt} — TSV-safe (json.dumps
  #                      escapes tab/newline). Renders the Step 6 Evidence: display.
  # ============================================================================
  CLASSIFIED_PROPOSALS="${CLASSIFIED_PROPOSALS}${target}	${action}	${pattern_summary}	${proposed_text}	${citation_count}	${existing_ref}	${best_j}	${source_jsonl}	${citations_json}"$'\n'

  if [ "$action" = "TIGHTEN" ]; then
    TIGHTEN_PATTERNS="${TIGHTEN_PATTERNS}${pattern_summary}"$'\n'
  fi
done <<< "$RAW_PROPOSALS"  # lint-ok: C1

CLASSIFIED_PROPOSALS=$(printf '%s' "$CLASSIFIED_PROPOSALS" | sed '/^[[:space:]]*$/d')
```

### Step 5d: Deterministic TIGHTEN merge

For each row in `$CLASSIFIED_PROPOSALS` with `action == TIGHTEN`, replace
column 4 (`proposed_text`) with a deterministic concatenation:

```
new_text = f"{existing_ref.strip().rstrip('.')}; additionally, {proposed_text}"
```

Truncate to 200 characters if needed. This happens in the same Python pass as
Step 5c or as a post-loop substitution — no subagent, no LLM call. DUPLICATE
and NEW rows are never rewritten.

### Step 5e: Anti-sprawl final sweep

Drop any `NEW` proposal whose `pattern_summary` (column 3) collides with a
`TIGHTEN` proposal's `pattern_summary`. Plan §6: if we're already tightening an
existing rule for a pattern, adding a new rule for the same pattern is sprawl.

```bash
if [ -n "$TIGHTEN_PATTERNS" ] && [ -n "$CLASSIFIED_PROPOSALS" ]; then  # lint-ok: C1
  SWEPT=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    action=$(printf '%s' "$row" | cut -f2)
    psum=$(printf '%s' "$row" | cut -f3)
    if [ "$action" = "NEW" ] && printf '%s\n' "$TIGHTEN_PATTERNS" | grep -Fxq -- "$psum"; then
      echo "# retro: dropped NEW proposal for pattern '$psum' (TIGHTEN exists)" >&2
      continue
    fi
    SWEPT="${SWEPT}${row}"$'\n'
  done <<< "$CLASSIFIED_PROPOSALS"
  CLASSIFIED_PROPOSALS=$(printf '%s' "$SWEPT" | sed '/^[[:space:]]*$/d')
fi
```

### Handoff to Step 6

Step 5 produces two variables for Step 6 to consume:

- `CLASSIFIED_PROPOSALS` — TSV, 9 columns per row. The column layout is defined
  ONCE in the **canonical CLASSIFIED_PROPOSALS schema** block in Step 5c; Step 6
  MUST read that block rather than a copy here (single source — prevents column
  drift).
- `OBSERVATIONS` — pass-through, unchanged from Step 4.

---

## Step 5.5: Trial review (SPEC-001 M4–M7 / CDV-200)

Before presenting or applying new proposals, review elapsed directive trials.
Helpers are pure subprocess CLIs under `skills/retro-gate/` (never sourced).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
TRIAL_REVIEW=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/trial-review.sh 2>/dev/null || true)
TRIAL_META=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/trial-meta.sh 2>/dev/null || true)
TRIAL_DECISIONS=""   # TSV from trial-review.sh (KEEP|REVERT rows)
if [ -n "$TRIAL_REVIEW" ] && [ -f "$TRIAL_REVIEW" ]; then  # lint-ok: C1
  # Scope: match discovery mode. --all → all projects; else current project only.
  # Session discovery inside trial-review.sh stays in sync with Step 2
  # (~/.claude/projects/, skip mtime <60s, gate.sh scores).
  SCOPE_ARG="current"
  [ "${MODE:-single}" = "all" ] && SCOPE_ARG="all"  # lint-ok: C1
  TRIAL_DECISIONS=$(bash "$TRIAL_REVIEW" --mroot "$MROOT" --scope "$SCOPE_ARG" 2>"${TMPDIR:-/tmp}/trial-review-$$.err" || true)
  if [ -s "${TMPDIR:-/tmp}/trial-review-$$.err" ]; then
    # DEFER lines and diagnostics — surface lightly
    sed 's/^/# /' "${TMPDIR:-/tmp}/trial-review-$$.err" 2>/dev/null | head -20 || true
  fi
  rm -f "${TMPDIR:-/tmp}/trial-review-$$.err" 2>/dev/null || true
else
  echo "# retro: trial-review.sh missing — skip trial review" >&2
fi
```

`TRIAL_DECISIONS` TSV columns (from `trial-review.sh`):
1. `action` — `KEEP` | `REVERT`
2. `agent`
3. `directive_text` (may include leading `N. `)
4. `source`
5. `trial_start`
6. `baseline_mean`
7. `baseline_n`
8. `in_trial_mean`
9. `in_trial_n`
10. `baseline_ids` (comma-separated)
11. `in_trial_ids`
12. `review_after`

### Step 5.5b: Present / apply trial decisions

**Default mode (no `--auto`):** for each row in `TRIAL_DECISIONS`, present:

```
[KEEP|REVERT] trial target=<agent>
  Directive: <directive_text>
  Trial start: <trial_start>  source: <source>  window: <review_after>
  Baseline mean=<baseline_mean> n=<baseline_n> sessions=<baseline_ids>
  In-trial mean=<in_trial_mean> n=<in_trial_n> sessions=<in_trial_ids>
  Evidence rule: mean(in_trial) < mean(baseline) → KEEP; else REVERT

Action: [a]pply / [r]eject / [s]kip remaining ?
```

- **`a` + KEEP:** strip text via `trial-meta.sh strip`, then print (do not invoke
  from within retro in interactive mode):
  ```
  Run: /adjust-agent <agent> "Promote the following trial directive to permanent by removing only its trial annotation (leave the directive text). Do not add or remove other directives: <stripped_text>"
  ```
  After successful apply, audit:
  ```bash
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
    || MROOT=$(pwd)
  PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
  TRIAL_REVIEW=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/trial-review.sh 2>/dev/null || true)
  # agent/source/trial_start/means/ns/ids from the current TRIAL_DECISIONS row.
  bash "$TRIAL_REVIEW" --record-decision --mroot "$MROOT" \
    --agent "$agent" --directive "$stripped_text" --source "$source" \
    --trial-start "$trial_start" \
    --baseline-mean "$baseline_mean" --baseline-n "$baseline_n" --baseline-ids "$baseline_ids" \
    --in-trial-mean "$in_trial_mean" --in-trial-n "$in_trial_n" --in-trial-ids "$in_trial_ids" \
    --decision KEEP --decided-by user
  ```

- **`a` + REVERT:** print:
  ```
  Run: /adjust-agent <agent> "Remove this directive entirely (trial REVERT): <stripped_text>"
  ```
  Then `--record-decision … --decision REVERT --decided-by user` after success.

- **`r`:** reject — no mutation, no audit line.

**`--auto` mode:** for each row, print the full evidence block, then invoke:

- KEEP: `/adjust-agent <agent> --apply "Promote the following trial directive to permanent by removing only its trial annotation (leave the directive text). Do not add or remove other directives: <stripped_text>"`
- REVERT: `/adjust-agent <agent> --apply "Remove this directive entirely (trial REVERT): <stripped_text>"`

On exit 0: print `[auto-applied] trial <KEEP|REVERT> <agent>: <stripped_text>` and
`--record-decision … --decided-by auto`.
On conflict (non-zero): append to `MANUAL_FOLLOWUP` with evidence (never silent
drop). **MUST NOT** write `directives.md` directly. **MUST NOT** auto-revert
without `--auto` or explicit confirm (M6).

Include applied trial decisions in the scheduled report summary when
`--all --auto` (append to applied list or a short "Trial decisions" note) if
cheap; otherwise list under MANUAL_FOLLOWUP / follow-up file.

---

## Step 6: Phase-4 confirm / apply

### Step 6a: Short-circuit on empty input

If `CLASSIFIED_PROPOSALS`, `OBSERVATIONS`, **and** `TRIAL_DECISIONS` are all
empty or contain only whitespace, print:

```
No actionable findings.
```

(If only trial decisions exist, skip this short-circuit — Step 5.5 already
handled or still needs confirm/auto apply.)

When `MODE=all` and `AUTO=1`, still write a short scheduled report (S3), then
exit 0:

```bash
if [ -z "$(printf '%s' "$CLASSIFIED_PROPOSALS$OBSERVATIONS" | sed '/^[[:space:]]*$/d')" ]; then  # lint-ok: C1
  echo "No actionable findings."
  NOTE="No actionable findings."
  SUMMARY="Applied: 0 | no actionable findings"
  write_scheduled_report_if_needed
  exit 0
fi
```

### Step 6b: Separate DUPLICATE proposals from actionable ones

Partition `CLASSIFIED_PROPOSALS` into two sets:

- `ACTIONABLE_PROPOSALS` — rows where `action` is `NEW` or `TIGHTEN`
- `DUPLICATE_PROPOSALS` — rows where `action` is `DUPLICATE`

DUPLICATE proposals are **never auto-applied**, even in `--auto` mode. They are
surfaced at the end as an advisory list (see Step 6f).

### Step 6c: Apply loop

Initialize accounting counters:

```bash
APPLIED=0
REJECTED=0
MANUAL_FOLLOWUP=""   # newline-separated proposals that --auto could not apply
```

Iterate `ACTIONABLE_PROPOSALS` grouped by `target` agent. For each group, compute
`N` (proposals for this target) and `M` (distinct `source_jsonl` paths for this
target — that is **column 8**, the canonical CLASSIFIED_PROPOSALS schema's
per-proposal provenance). `M` is computable because each proposal carries its
originating session in col 8:

```bash
# Rows of this target's group are in $GROUP_ROWS (TSV, canonical schema).
N=$(printf '%s\n' "$GROUP_ROWS" | sed '/^[[:space:]]*$/d' | wc -l)
# M = distinct source_jsonl (col 8) across this target's proposals.
M=$(printf '%s\n' "$GROUP_ROWS" | sed '/^[[:space:]]*$/d' \
      | cut -f8 | sort -u | grep -c .)
```

Print a group header before the first proposal:

```bash
# In single/explicit mode:
echo "=== <target> (<N> proposal(s)) ==="
# In --all mode:
echo "=== <target> (<N> proposal(s) across <M> session(s)) ==="
```

So for example: `=== ic5 (3 proposal(s) across 2 session(s)) ===`

For each proposal row, read fields per the **canonical CLASSIFIED_PROPOSALS
schema** (Step 5c) — that block is the only place the column list lives.
`target`/`action` come from the group context above; the per-proposal display
below additionally reads (a usage subset, not a schema restatement):
- col 4: `proposed_text` (`cut -f4`)
- col 6: `existing_ref` (`cut -f6`)
- col 9: `citations_json` (`cut -f9`) — JSON `[{message_id, excerpt}, …]`, the
  source for the `Evidence:` block below

#### Default mode (no `--auto`)

Present the proposal:

```
[<ACTION>] target=<target>
  Proposed: <proposed_text>
  Evidence:
    - [<message_id 1>] <excerpt 1>
    - [<message_id 2>] <excerpt 2>
    ...
  Existing rule (TIGHTEN/DUPLICATE only): <existing_ref>

Action: [a]pply / [r]eject / [e]dit / [s]kip remaining ?
```

Render the `Evidence:` lines by decoding `citations_json` (col 9) — this is the
actual `{message_id, excerpt}` array the subagent cited, NOT a count. Each line
shows the real excerpt text:

```bash
# $citations_json is column 9 of the current CLASSIFIED_PROPOSALS row.  # lint-ok: C1
CIT="$citations_json" python3 - <<'PY'
import json, os
try:
    cites = json.loads(os.environ.get("CIT", "") or "[]")
except Exception:
    cites = []
for c in cites:
    mid = (c.get("message_id", "") or "").strip()
    exc = (c.get("excerpt", "") or "").replace("\n", " ").replace("\t", " ").strip()
    tag = f"[{mid}] " if mid else ""
    print(f"    - {tag}{exc}")
PY
```

(Omit the "Existing rule" line entirely for `NEW` proposals.)

Handle the user's response:

- **`a` (apply):**
  - If `target` is a **team agent** (`pm`, `tech-lead`, `ic5`, `ic4`, `devops`,
    `qa`, `ds`):
    - **NEW (default trial tag, SPEC-001 M3):** before printing the apply
      command, annotate `proposed_text` with trial metadata unless the user
      chose strip-to-permanent. Confirm UI for NEW team-agent proposals:
      ```
      Trial: [t]rial (default, review after 10 sessions) / [p]ermanent (no trial meta) ?
      ```
      Default `t`. Build annotated text (re-read fields from the current
      CLASSIFIED_PROPOSALS row — col 4 proposed_text, col 8 source_jsonl,
      col 9 citations_json):
      ```bash
      _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
        && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
        || MROOT=$(pwd)
      PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
      TRIAL_META=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/trial-meta.sh 2>/dev/null || true)
      # $row = current CLASSIFIED_PROPOSALS TSV line (orchestrator loop).  # lint-ok: C1
      proposed_text=$(printf '%s' "$row" | cut -f4)
      source_jsonl=$(printf '%s' "$row" | cut -f8)
      citations_json=$(printf '%s' "$row" | cut -f9)
      SESSION_UUID=$(basename "${source_jsonl:-unknown}" .jsonl)
      ANCHOR_ID=$(CIT="$citations_json" python3 -c 'import json,os
try:
  c=json.loads(os.environ.get("CIT") or "[]")
  print((c[0].get("message_id") or "na") if c else "na")
except Exception:
  print("na")' 2>/dev/null || echo na)
      START_DAY=$(date -u +%Y-%m-%d)
      if [ -n "$TRIAL_META" ] && [ -f "$TRIAL_META" ]; then  # lint-ok: C1
        APPLY_TEXT=$(bash "$TRIAL_META" annotate \
          --text "$proposed_text" \
          --start "$START_DAY" \
          --source "${SESSION_UUID}#${ANCHOR_ID}" \
          --review-after "10-sessions")
      else
        APPLY_TEXT="$proposed_text"
      fi
      ```
      Permanent choice (`p`): set `APPLY_TEXT="$proposed_text"` (no annotate).
    - **TIGHTEN:** pass `proposed_text` unchanged (`APPLY_TEXT="$proposed_text"`).
      Do not invent trial metadata; if the existing line already has a trial
      comment, `/adjust-agent` holistic rewrite preserves it (SPEC-001 M1/M3).
    - Print the slash command for the user to run manually — do NOT invoke it
      from within the retro command:
      ```
      Run: /adjust-agent <target> "<APPLY_TEXT>"
      ```
    Then print the current directive count for that agent:
    ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
    FILE="$MROOT/.claude/memory/<target>/directives.md"
    COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null || echo 0)
    printf '%s: %s directive(s) currently (run the command above to update)\n' "<target>" "$COUNT"
    ```
    Increment `APPLIED`.
  - If `target` is **`plugin`**: add `proposed_text` to the project backlog via
    `/backlog add`. Print the command for the user to confirm — do NOT auto-invoke:
    ```
    Plugin improvement identified:
      <proposed_text>
    Run: /backlog add "<proposed_text>"
    ```
    Increment `APPLIED`. In `--auto` mode, invoke `/backlog add "<proposed_text>"`
    directly and print `[auto-added] plugin backlog: <proposed_text>`.
  - If `target` is **`claude`**: append `proposed_text` to
    `$MROOT/.claude/memory/claude/lessons.md`. Create the file and parent
    directory if absent:
    ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
    mkdir -p "$MROOT/.claude/memory/claude"
    # Belt-and-braces: re-sanitize at write time. The Step 4 validator already
    # strips control chars, but defense-in-depth in case proposed_text reached
    # here through an unexpected path.
    proposed_text=$(printf '%s' "$proposed_text" | tr -d '\r\n\t\000-\037' | cut -c1-200)
    printf '- %s\n' "$proposed_text" >> "$MROOT/.claude/memory/claude/lessons.md"
    ```
    Print: `Appended to claude/lessons.md`
    Increment `APPLIED`.

- **`r` (reject):** Print `Rejected.` Increment `REJECTED`.

- **`e` (edit):** Prompt:
  ```
  Enter replacement text (blank to cancel):
  ```
  Read the replacement. If non-blank, update `proposed_text` to the replacement
  and re-present the proposal for re-confirm (restart the action prompt for this
  proposal). If blank, treat as rejected.

- **`s` (skip remaining):** Print `Skipping remaining proposals.` Break out of
  the proposal loop immediately. Count unprocessed proposals as rejected for
  the final summary.

Any unrecognized input: re-display the action prompt.

#### `--auto` mode

Skip the confirm UI. For each proposal, apply immediately:

- If `target` is a **team agent**: build `APPLY_TEXT` then invoke
  `/adjust-agent <target> --apply "<APPLY_TEXT>"`.

  - **NEW:** always annotate with trial metadata (default; no permanent
    prompt under `--auto`). Re-read cols from current row:
    ```bash
    _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
      && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
      || MROOT=$(pwd)
    PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
    TRIAL_META=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/trial-meta.sh 2>/dev/null || true)
    # $row = current CLASSIFIED_PROPOSALS TSV line (orchestrator loop).  # lint-ok: C1
    proposed_text=$(printf '%s' "$row" | cut -f4)
    source_jsonl=$(printf '%s' "$row" | cut -f8)
    citations_json=$(printf '%s' "$row" | cut -f9)
    SESSION_UUID=$(basename "${source_jsonl:-unknown}" .jsonl)
    ANCHOR_ID=$(CIT="$citations_json" python3 -c 'import json,os
try:
  c=json.loads(os.environ.get("CIT") or "[]")
  print((c[0].get("message_id") or "na") if c else "na")
except Exception:
  print("na")' 2>/dev/null || echo na)
    START_DAY=$(date -u +%Y-%m-%d)
    if [ -n "$TRIAL_META" ] && [ -f "$TRIAL_META" ]; then  # lint-ok: C1
      APPLY_TEXT=$(bash "$TRIAL_META" annotate \
        --text "$proposed_text" \
        --start "$START_DAY" \
        --source "${SESSION_UUID}#${ANCHOR_ID}" \
        --review-after "10-sessions")
    else
      APPLY_TEXT="$proposed_text"
    fi
    ```
  - **TIGHTEN:** `APPLY_TEXT="$proposed_text"` (no new trial meta).

  This is a non-interactive apply: the slash command applies on no conflict and
  exits non-zero on conflict (never prompts). Handle the two outcomes:

  - **Exit 0 (success):** Increment `APPLIED`. Print the updated directive count:
    ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
    FILE="$MROOT/.claude/memory/<target>/directives.md"
    COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null || echo 0)
    printf '[auto-applied] %s: %s directive(s) now\n' "<target>" "$COUNT"
    ```
  - **Exit non-zero (conflict refused):** Do NOT silently drop. Append the
    proposal to `MANUAL_FOLLOWUP` with the conflict message captured from
    stderr. Print immediately:
    ```
    [conflict] <target>: "<APPLY_TEXT>"
      Conflict: <stderr from /adjust-agent --apply>
      → Added to manual follow-up list.
    ```

- If `target` is **`plugin`**: invoke `/backlog add "<proposed_text>"` directly.
  Print `[auto-added] plugin backlog: <proposed_text>`. Increment `APPLIED`.

- If `target` is **`claude`**: append directly to
  `$MROOT/.claude/memory/claude/lessons.md` (no slash command needed):
  ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  mkdir -p "$MROOT/.claude/memory/claude"
  # Belt-and-braces: re-sanitize at write time (see default-mode apply above).
  proposed_text=$(printf '%s' "$proposed_text" | tr -d '\r\n\t\000-\037' | cut -c1-200)
  printf '- %s\n' "$proposed_text" >> "$MROOT/.claude/memory/claude/lessons.md"
  printf '[auto-applied] claude: appended to lessons.md\n'
  ```
  Increment `APPLIED`.

### Step 6d: DUPLICATE advisory

If `DUPLICATE_PROPOSALS` is non-empty, print:

```
--- Duplicate / Already-Covered Rules ---
The following rules already cover observed patterns but didn't prevent
recurrence — consider tightening or removing:
```

For each duplicate proposal:
```
  [DUPLICATE] target=<target>
    Existing rule: <existing_ref>
    Pattern seen: <pattern_summary>
    Proposed text (not applied): <proposed_text>
```

These are advisory only. No action is taken. Count them in the final summary.

### Step 6e: Manual follow-up list (--auto mode only)

If `MANUAL_FOLLOWUP` is non-empty, print:

```
--- Manual Follow-Up Required ---
The following proposals could not be auto-applied due to conflicts.
Review and apply manually:
```

For each item in `MANUAL_FOLLOWUP`:
```
  /adjust-agent <target> "<proposed_text>"
    Conflict: <conflict message>
```

### Step 6f: Non-actionable observations

If `OBSERVATIONS` is non-empty, print:

```
--- Observed Patterns (no fix proposed) ---
```

Then bullet each observation line from `$OBSERVATIONS`:
```
  - <observation>
```

These are for visibility only — no action is taken.

### Step 6g: Final summary

Print a summary line:

```
--- Retro Summary ---
Applied:          <APPLIED>
Rejected/skipped: <REJECTED>
Duplicates:       <count of DUPLICATE_PROPOSALS>
Manual follow-up: <count of MANUAL_FOLLOWUP items>   (--auto mode only)
Observations:     <count of OBSERVATIONS lines>
```

### Step 6h: Council integration hints (SPEC-012 §Integration Hooks, SPEC-013 §Integration Hooks)

Print AFTER the retro summary, BEFORE exit. Silent skip when no anchors detected.

These hints are plain suggestions — NOT auto-invocations. This command does NOT
call `/council` itself, does NOT block completion on fabrication anchor detection,
and does NOT require user action. They are advisory only.

In COUNCIL-001 (v0.18.0), `/council --from-retro <anchor-id>` fails loudly with
"not implemented in COUNCIL-001, planned for COUNCIL-002" — this is expected per
the locked deferred-scope decision. The hint is printed for forward-compat.

```bash
if [ -n "$FABRICATION_ANCHORS" ]; then  # lint-ok: C1
  FA_COUNT=$(printf '%s\n' "$FABRICATION_ANCHORS" | grep -c '.' || echo 0)
  echo ""
  echo "Detected ${FA_COUNT} fabrication anchor(s) — consider auditing with /council:"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    AID=$(printf '%s' "$row" | cut -f1)
    echo "  - Consider: /council --from-retro $AID"
  done <<< "$FABRICATION_ANCHORS"
  echo "(Note: /council --from-retro is deferred to COUNCIL-002; the hint is for forward-compat.)"
fi
```

### Step 6i: Scheduled report (`--all --auto` only, CDV-190)

After Step 6g summary and Step 6h hints, when both `--all` and `--auto` are set,
write the non-interactive report under `$MROOT/.claude/retro/`. Build temp
files from the in-memory apply/follow-up/dup/obs state accumulated above, then
call `write-scheduled-report.sh`. Print `Report: <absolute-path>`. The EXIT trap
from Step 1b releases `scheduled.lock`.

```bash
if [ "$MODE" = "all" ] && [ "$AUTO" = "1" ]; then  # lint-ok: C1
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
    || MROOT=$(pwd)
  PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
  SCHED_WRITER=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/write-scheduled-report.sh 2>/dev/null || true)

  APPLIED_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-applied.XXXXXX")
  FOLLOWUP_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-followup.XXXXXX")
  DUP_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-dup.XXXXXX")
  OBS_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-obs.XXXXXX")

  # Applied rows: best-effort from ACTIONABLE that were counted in APPLIED.
  # TSV target\taction\tsummary — orchestrating Claude fills from apply loop state.
  : >"$APPLIED_FILE"
  if [ -n "${ACTIONABLE_PROPOSALS:-}" ]; then
    printf '%s\n' "$ACTIONABLE_PROPOSALS" | while IFS= read -r row; do
      [ -z "$row" ] && continue
      t=$(printf '%s' "$row" | cut -f1)
      a=$(printf '%s' "$row" | cut -f2)
      s=$(printf '%s' "$row" | cut -f4)
      # Only NEW/TIGHTEN that were not parked in MANUAL_FOLLOWUP.
      case "$a" in NEW|TIGHTEN)
        printf '%s\t%s\t%s\n' "$t" "$a" "$s" >>"$APPLIED_FILE"
        ;;
      esac
    done
  fi

  : >"$FOLLOWUP_FILE"
  if [ -n "${MANUAL_FOLLOWUP:-}" ]; then  # lint-ok: C1
    printf '%s\n' "$MANUAL_FOLLOWUP" >>"$FOLLOWUP_FILE"  # lint-ok: C1
  fi

  : >"$DUP_FILE"
  if [ -n "${DUPLICATE_PROPOSALS:-}" ]; then  # lint-ok: C1
    printf '%s\n' "$DUPLICATE_PROPOSALS" | while IFS= read -r row; do  # lint-ok: C1
      [ -z "$row" ] && continue
      t=$(printf '%s' "$row" | cut -f1)
      s=$(printf '%s' "$row" | cut -f4)
      ref=$(printf '%s' "$row" | cut -f6)
      printf 'target=%s existing=%s proposed=%s\n' "$t" "$ref" "$s" >>"$DUP_FILE"
    done
  fi

  : >"$OBS_FILE"
  if [ -n "${OBSERVATIONS:-}" ]; then  # lint-ok: C1
    printf '%s\n' "$OBSERVATIONS" | while IFS= read -r row; do  # lint-ok: C1
      [ -z "$row" ] && continue
      printf '%s\n' "$(printf '%s' "$row" | cut -f1)" >>"$OBS_FILE"
    done
  fi

  DUP_N=$(grep -c . "$DUP_FILE" 2>/dev/null || echo 0)
  MF_N=$(grep -c . "$FOLLOWUP_FILE" 2>/dev/null || echo 0)
  OBS_N=$(grep -c . "$OBS_FILE" 2>/dev/null || echo 0)
  SUMMARY="Applied: ${APPLIED:-0} | Rejected: ${REJECTED:-0} | Duplicates: ${DUP_N} | Manual follow-up: ${MF_N} | Observations: ${OBS_N}"  # lint-ok: C1
  NOTE=""
  write_scheduled_report_if_needed  # lint-ok: C1
  rm -f "$APPLIED_FILE" "$FOLLOWUP_FILE" "$DUP_FILE" "$OBS_FILE"
fi
```

Exit 0.
