---
name: retro
description: Session retrospective — scan past sessions for friction patterns and propose targeted behavioral adjustments for team agents or plain Claude.
argument-hint: "[<session-id>] [--all] [--auto] [--why]"
---

# /retro

Review past Claude session(s) for friction patterns and propose concrete behavioral
adjustments. Adjustments target either a team agent (via `/adjust-agent`) or plain
Claude (via `$MROOT/.claude/memory/claude/lessons.md`).

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

for arg in $ARGS; do
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

## Step 2: Session discovery

### Step 2a: Locate the project directory under `~/.claude/projects/`

The project directory name is the absolute path to `MROOT` with every `/` replaced
by `-`. This matches Claude's own encoding scheme.

```bash
# Encode MROOT: replace each '/' with '-'
ENCODED=$(echo "$MROOT" | sed 's|/|-|g')
PROJECT_DIR="$HOME/.claude/projects/$ENCODED"
```

Verify the directory exists:

```bash
if [ ! -d "$PROJECT_DIR" ]; then
  echo "No Claude project directory found for this repo."
  echo "Expected: $PROJECT_DIR"
  echo "Available directories under ~/.claude/projects/:"
  ls "$HOME/.claude/projects/" 2>/dev/null | head -20
  exit 1
fi
```

<!-- Encoding verified: /home/user/vibes/claude-dev-team encodes to
     -home-user-vibes-claude-dev-team, and ls ~/.claude/projects/ confirms
     -home-user-vibes-claude-dev-team exists. Worktree
     /home/user/vibes/claude-dev-team-RETRO-001 shares git-common-dir with the
     main checkout so MROOT resolves to /home/user/vibes/claude-dev-team. -->

### Step 2b: Collect candidate JSONL paths

**Default (single, no explicit SID):** most recently modified `.jsonl` in the project dir.

```bash
if [ "$MODE" = "single" ] && [ -z "$EXPLICIT_SID" ]; then
  CANDIDATES=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1)

# Explicit SID: locate a JSONL whose basename matches across all project dirs.
elif [ -n "$EXPLICIT_SID" ]; then
  # Validate UUID shape before handing to find(1): unvalidated input would allow
  # glob metacharacters (`*`, `[a-f]*`) to enumerate the filesystem.
  case "$EXPLICIT_SID" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*) ;;
    *)
      echo "error: session-id must be a UUID (e.g. 00000000-0000-4000-8000-000000000004)" >&2
      exit 1
      ;;
  esac
  CANDIDATES=$(find "$HOME/.claude/projects" -name "${EXPLICIT_SID}.jsonl" 2>/dev/null)
  if [ -z "$CANDIDATES" ]; then
    # Also try with .jsonl already stripped
    CANDIDATES=$(find "$HOME/.claude/projects" -name "${EXPLICIT_SID}" 2>/dev/null)
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

```bash
NOW=$(date +%s)
FILTERED=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  MTIME=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  AGE=$(( NOW - MTIME ))
  if [ "$AGE" -lt 60 ]; then
    if [ "$WHY" = "1" ]; then
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
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -qE '<command-name>/[a-z:-]*retro</command-name>' "$f" 2>/dev/null; then
    if [ "$WHY" = "1" ]; then
      echo "[skip] $(basename "$f" .jsonl)  (contains /retro invocation — loop prevention)"
    fi
    continue
  fi
  FILTERED="$FILTERED
$f"
done <<< "$CANDIDATES"
SESSIONS=$(echo "$FILTERED" | sed '/^[[:space:]]*$/d')
```

### Step 2d: Empty-set guard

```bash
if [ -z "$SESSIONS" ]; then
  echo "No sessions to retro."
  exit 0
fi
```

`SESSIONS` is now a newline-separated list of absolute paths to JSONL files ready
for analysis.

---

## Step 3: Phase-1 gate

### Step 3a: Locate gate.sh

Use the PLUGIN_VER lookup pattern (mirrors the kickoff friction-check hook):

```bash
PLUGIN_VER=$(cat ~/.claude/plugins/cache/cold-dark-void/dev-team/*/.claude-plugin/plugin.json 2>/dev/null | grep -o '"version": *"[^"]*"' | tail -1 | grep -o '[0-9][0-9.]*')
GATE_SH="$HOME/.claude/plugins/cache/cold-dark-void/dev-team/${PLUGIN_VER}/skills/retro-gate/gate.sh"
if [ ! -x "$GATE_SH" ]; then
  GATE_SH=$(find ~/.claude/plugins/cache -path "*/dev-team/*/skills/retro-gate/gate.sh" 2>/dev/null | sort -V | tail -1)
fi

if [ ! -x "$GATE_SH" ]; then
  echo "# retro: gate.sh not found — cannot run phase-1 gate" >&2
  echo "# Expected: $HOME/.claude/plugins/cache/cold-dark-void/dev-team/<ver>/skills/retro-gate/gate.sh" >&2
  exit 1
fi
```

Unlike the kickoff hook (which soft-skips when gate.sh is missing), `/retro` treats a missing gate as a hard error: the gate is the gating mechanism for the entire command.

### Step 3b: Gate each session with time budget

Budget policy (two modes):
- **single/explicit-SID mode**: 5s total budget (per SPEC-012 "exit in under 5 seconds on smooth sessions").
- **`--all` mode**: no total budget cap (too many sessions to constrain to 5s); instead a hard 2s per-file cap prevents any one session from dominating. Rationale: at 500 sessions, 5s ÷ 500 = 10ms/session — tighter than gate.sh can run. We relax the total cap and rely on the per-file timeout.

```bash
FLAGGED_SESSIONS=""
ANCHOR_IDS=""        # newline-separated "<jsonl-path> <id>" pairs for T5
GATE_START=$(date +%s)
TOTAL=$(echo "$SESSIONS" | wc -l)
N=0

# Total budget: 5s for single/explicit mode; unlimited for --all (per-file cap applies instead).
TOTAL_BUDGET=5

while IFS= read -r JSONL; do
  [ -z "$JSONL" ] && continue
  N=$(( N + 1 ))

  # Total-budget check — only enforce in single/explicit mode.
  if [ "$MODE" != "all" ]; then
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
    FLAGGED_SESSIONS="$FLAGGED_SESSIONS
$JSONL"
    # Collect anchor message IDs from signals[].ids[] for T5.
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
  if [ "$WHY" = "1" ]; then
    SID=$(basename "$JSONL" .jsonl)
    PASSED_LABEL="passed"
    [ -z "$PASSED" ] && PASSED_LABEL="not passed"
    echo "Session: $SID"
    echo "Score: ${SCORE:-?} / ${THRESHOLD:-5.0} ($PASSED_LABEL)"

    # Matched signals — names present in signals[] with count > 0
    MATCHED=$(echo "$GATE_OUT" | grep -o '"name": *"[^"]*", *"count": *[1-9][0-9]*[^}]*"ids": *\[[^]]*\]' | \
      awk -F'"' '{
        for(i=1;i<=NF;i++) {
          if($i=="name") name=$(i+2)
          if($i=="count") { split($0, a, "\"count\": "); split(a[2], b, ","); count=b[1] }
        }
        ids=""
        n=split($0, parts, "\"ids\": [")
        if(n>1) { split(parts[2], id_parts, "]"); ids=id_parts[1] }
        if(name!="") printf "  %s x%s\n", name, count
      }')
    ALL_SIGNALS="S1 S2 S3 S4 S5"
    NOT_MATCHED=""
    for SIG in $ALL_SIGNALS; do
      if ! echo "$GATE_OUT" | grep -q "\"name\": *\"$SIG\""; then
        NOT_MATCHED="$NOT_MATCHED $SIG"
      fi
    done
    if [ -n "$MATCHED" ]; then
      echo "Matched:$MATCHED"
    else
      echo "Matched: (none)"
    fi
    echo "Not matched:$NOT_MATCHED"
    echo ""
  fi

done <<< "$SESSIONS"

FLAGGED_SESSIONS=$(echo "$FLAGGED_SESSIONS" | sed '/^[[:space:]]*$/d')
ANCHOR_IDS=$(echo "$ANCHOR_IDS" | sed '/^[[:space:]]*$/d')
```

### Step 3c: Early exit if nothing flagged

```bash
if [ -z "$FLAGGED_SESSIONS" ]; then
  echo "No friction detected — nothing to retro."
  exit 0
fi
```

---

## Step 4: Phase-2 subagent spawn

At this point `$FLAGGED_SESSIONS` holds the newline-separated JSONL paths that
passed the phase-1 gate, and `$ANCHOR_IDS` holds newline-separated
`<jsonl-path> <message-id>` pairs. See `skills/retro-subagent/SKILL.md` for the
full input/output contract — this section enforces it.

### Step 4a: Load EXISTING_RULES for every possible target

We need the current rule text for each of the 7 team agents plus plain Claude so
the subagent can avoid re-proposing things already covered. `$MROOT` was resolved
in Step 0.

```bash
# Load each directives file (team agents) / lessons.md (claude). Missing files
# become the literal string "empty" — matches the SKILL.md input contract.
load_rules() {
  local f="$1"
  if [ -s "$f" ]; then
    cat "$f"
  else
    echo "empty"
  fi
}

RULES_PM=$(load_rules       "$MROOT/.claude/memory/pm/directives.md")
RULES_TL=$(load_rules       "$MROOT/.claude/memory/tech-lead/directives.md")
RULES_IC5=$(load_rules      "$MROOT/.claude/memory/ic5/directives.md")
RULES_IC4=$(load_rules      "$MROOT/.claude/memory/ic4/directives.md")
RULES_DEVOPS=$(load_rules   "$MROOT/.claude/memory/devops/directives.md")
RULES_QA=$(load_rules       "$MROOT/.claude/memory/qa/directives.md")
RULES_DS=$(load_rules       "$MROOT/.claude/memory/ds/directives.md")
RULES_CLAUDE=$(load_rules   "$MROOT/.claude/memory/claude/lessons.md")
```

### Step 4b: Build per-session Task inputs

For every flagged session, assemble the four inputs the subagent expects:

- `SESSION_JSONL` — absolute path (one line of `$FLAGGED_SESSIONS`)
- `ANCHOR_MESSAGE_IDS_JSON` — JSON array of message IDs collected by the gate
  for this specific JSONL, extracted from `$ANCHOR_IDS`
- `FRICTION_SIGNALS_JSON` — verbatim stdout of `gate.sh` for this JSONL.
  Re-invoke the gate per flagged session (~60ms, deterministic); do NOT try to
  cache `GATE_OUT` from Step 3. Concretely, inside the per-session loop of
  Step 4c you MUST run:
  `FRICTION_SIGNALS_JSON=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)`
  BEFORE constructing the Task prompt, so `${FRICTION_SIGNALS_JSON}` inside
  the `skills/retro-subagent/SKILL.md` prompt template resolves to the real
  gate JSON rather than an empty string.
- `EXISTING_RULES` — the eight variables from Step 4a

```bash
# For each flagged JSONL, build its anchor-id JSON array.
build_anchor_json() {
  local jsonl="$1"
  local ids
  ids=$(echo "$ANCHOR_IDS" | awk -v p="$jsonl" '$1==p {print $2}')
  # Compose as JSON array without relying on jq.
  local out="["
  local first=1
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [ $first -eq 1 ]; then first=0; else out="$out,"; fi
    out="$out\"$id\""
  done <<< "$ids"
  out="$out]"
  echo "$out"
}
```

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
# For each $JSONL in $FLAGGED_SESSIONS:
FRICTION_SIGNALS_JSON=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)
ANCHOR_MESSAGE_IDS_JSON=$(build_anchor_json "$JSONL")
# ... substitute FRICTION_SIGNALS_JSON, ANCHOR_MESSAGE_IDS_JSON, SESSION_JSONL,
# and the EXISTING_RULES.* entries into the prompt template from
# skills/retro-subagent/SKILL.md §"Subagent prompt template", then spawn Task.
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

Do NOT grep nested JSON by hand — use `jq` when available, otherwise fall back
to a `python3 -c` one-liner. Both paths emit tab-separated rows to stdout:

```
proposal<TAB>target<TAB>proposed_text<TAB>confidence<TAB>citation_count<TAB>pattern_summary<TAB>source_jsonl
observation<TAB>description<TAB>source_jsonl
```

```bash
ALLOWED_TARGETS="pm tech-lead ic5 ic4 devops qa ds claude"

parse_one() {
  local json="$1"
  local src="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg src "$src" '
      (.proposals // [])[] |
        "proposal\t" + (.target // "") + "\t" + (.proposed_text // "") + "\t" +
        ((.confidence // 0)|tostring) + "\t" +
        ((.citations // []|length)|tostring) + "\t" +
        (.pattern_summary // "") + "\t" + $src
    ' 2>/dev/null
    echo "$json" | jq -r --arg src "$src" '
      (.observations // [])[] |
        "observation\t" + (.description // "") + "\t" + $src
    ' 2>/dev/null
  else
    RETRO_JSON="$json" RETRO_SRC="$src" python3 - <<'PY'
import json, os
src = os.environ.get("RETRO_SRC", "")
raw = os.environ.get("RETRO_JSON", "")
try:
    d = json.loads(raw)
except Exception:
    raise SystemExit(0)
for p in d.get("proposals", []) or []:
    cites = p.get("citations") or []
    print("proposal\t%s\t%s\t%s\t%d\t%s\t%s" % (
        p.get("target",""),
        (p.get("proposed_text","") or "").replace("\t"," "),
        p.get("confidence",0), len(cites),
        p.get("pattern_summary",""), src))
for o in d.get("observations", []) or []:
    print("observation\t%s\t%s" % (
        (o.get("description","") or "").replace("\t"," "), src))
PY
  fi
}

RAW_PROPOSALS=""
OBSERVATIONS=""

while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  # Each line in SUBAGENT_RESULTS is "<src-jsonl>\t<json>" (see Step 4c).
  SRC=$(printf '%s' "$LINE" | cut -f1)
  JSON=$(printf '%s' "$LINE" | cut -f2-)

  while IFS=$'\t' read -r KIND F1 F2 F3 F4 F5 F6; do
    case "$KIND" in
      proposal)
        TARGET="$F1"; TEXT="$F2"; CONF="$F3"; CITES="$F4"; PSUM="$F5"; SRCJ="$F6"
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
        # Secondary checks from SKILL.md (pattern_summary non-empty, confidence in [0,1])
        if [ -z "$PSUM" ]; then
          echo "# retro: dropped proposal (reason: empty pattern_summary) target=$TARGET" >&2
          continue
        fi
        # Compute rank key = confidence * citation_count (awk for float math)
        RANK=$(awk -v c="$CONF" -v n="$CITES" 'BEGIN{printf "%.6f", c*n}')
        RAW_PROPOSALS="$RAW_PROPOSALS
$RANK	$TARGET	$CONF	$CITES	$PSUM	$TEXT	$SRCJ"
        ;;
      observation)
        DESC="$F1"; SRCJ="$F2"
        [ -z "$DESC" ] && continue
        OBSERVATIONS="$OBSERVATIONS
$DESC	$SRCJ"
        ;;
    esac
  done < <(parse_one "$JSON" "$SRC")
done <<< "$SUBAGENT_RESULTS"

RAW_PROPOSALS=$(echo "$RAW_PROPOSALS" | sed '/^[[:space:]]*$/d')
OBSERVATIONS=$(echo "$OBSERVATIONS"  | sed '/^[[:space:]]*$/d')
```

### Step 4e: Rank and cap to top 5

Per SPEC-012 SHOULD: rank surviving proposals by `confidence * len(citations)`
descending, keep the top 5.

```bash
# Sort numerically by rank key (column 1), descending, then take top 5.
RAW_PROPOSALS=$(printf '%s\n' "$RAW_PROPOSALS" | sort -t$'\t' -k1,1 -nr | head -5)
```

### Step 4f: --all repeat-filter pre-grouping (hint for T6)

When `$MODE = "all"` the spec asks us to collapse patterns that occur in only
one session. T6 (routing/dedup) is the natural home for that, but we pre-tag
singletons here so T6 has the info without re-parsing. We group by
`pattern_summary` and mark any summary with a single occurrence across the whole
RAW_PROPOSALS set — T6 may drop those when `$MODE = "all"`.

```bash
if [ "$MODE" = "all" ] && [ -n "$RAW_PROPOSALS" ]; then
  # Count occurrences of each pattern_summary (column 5 after the rank key).
  SINGLETON_PATTERNS=$(printf '%s\n' "$RAW_PROPOSALS" \
    | awk -F'\t' '{print $5}' | sort | uniq -c \
    | awk '$1==1 {sub(/^ *1 /,""); print}')
  # T6 will consume $SINGLETON_PATTERNS alongside $RAW_PROPOSALS.
fi
```

`RAW_PROPOSALS`, `OBSERVATIONS`, and (when `--all`) `SINGLETON_PATTERNS` are the
handoff to Step 5 (T6).

---

## Step 5: Phase-3 routing and deduplication (T6)

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
if [ "$MODE" = "all" ] && [ -n "$SINGLETON_PATTERNS" ]; then
  FILTERED=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    psum=$(printf '%s' "$row" | awk -F'\t' '{print $5}')
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

We mirror Step 4a rather than trust variable persistence across the interpreted
`.md` boundaries. Missing files collapse to the empty string (NOT the literal
`"empty"` — the classifier needs a real emptiness test here).

```bash
load_rules_raw() {
  local f="$1"
  [ -s "$f" ] && cat "$f" || printf ''
}

RULES_PM=$(load_rules_raw       "$MROOT/.claude/memory/pm/directives.md")
RULES_TL=$(load_rules_raw       "$MROOT/.claude/memory/tech-lead/directives.md")
RULES_IC5=$(load_rules_raw      "$MROOT/.claude/memory/ic5/directives.md")
RULES_IC4=$(load_rules_raw      "$MROOT/.claude/memory/ic4/directives.md")
RULES_DEVOPS=$(load_rules_raw   "$MROOT/.claude/memory/devops/directives.md")
RULES_QA=$(load_rules_raw       "$MROOT/.claude/memory/qa/directives.md")
RULES_DS=$(load_rules_raw       "$MROOT/.claude/memory/ds/directives.md")
RULES_CLAUDE=$(load_rules_raw   "$MROOT/.claude/memory/claude/lessons.md")

target_rules_for() {
  case "$1" in
    pm)        printf '%s' "$RULES_PM" ;;
    tech-lead) printf '%s' "$RULES_TL" ;;
    ic5)       printf '%s' "$RULES_IC5" ;;
    ic4)       printf '%s' "$RULES_IC4" ;;
    devops)    printf '%s' "$RULES_DEVOPS" ;;
    qa)        printf '%s' "$RULES_QA" ;;
    ds)        printf '%s' "$RULES_DS" ;;
    claude)    printf '%s' "$RULES_CLAUDE" ;;
    *)         printf '' ;;
  esac
}
```

### Step 5c: Deterministic NEW / TIGHTEN / DUPLICATE classification

We run a single Python pass per proposal. Python3 is the T5-established fallback
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
CLASSIFIED_PROPOSALS=""
TIGHTEN_PATTERNS=""

while IFS= read -r row; do
  [ -z "$row" ] && continue
  # Columns: rank \t target \t confidence \t citations \t pattern \t text \t source
  target=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
  citations=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
  pattern_summary=$(printf '%s' "$row" | awk -F'\t' '{print $5}')
  proposed_text=$(printf '%s' "$row" | awk -F'\t' '{print $6}')

  rules_text=$(target_rules_for "$target")

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

  action=$(printf '%s' "$CLASS_OUT" | awk -F'\t' '{print $1}')
  existing_ref=$(printf '%s' "$CLASS_OUT" | awk -F'\t' '{print $2}')
  best_j=$(printf '%s' "$CLASS_OUT" | awk -F'\t' '{print $3}')

  # For TIGHTEN we leave proposed_text as-is in the TSV. The orchestrating
  # Claude performs the inline rewrite step below (Step 5d) when presenting
  # proposals to the user in Step 6.
  #
  # CLASSIFIED_PROPOSALS schema (TSV, one proposal per line):
  #   1 target           pm|tech-lead|ic5|ic4|devops|qa|ds|claude
  #   2 action           NEW|TIGHTEN|DUPLICATE
  #   3 pattern_summary  short tag from Phase-2 subagent
  #   4 proposed_text    imperative sentence (may be rewritten by Step 5d for TIGHTEN)
  #   5 citations        comma-joined message IDs / line refs
  #   6 existing_ref     rule line matched (empty for NEW)
  #   7 best_jaccard     float, "0.000".."1.000" — debug/telemetry
  CLASSIFIED_PROPOSALS="${CLASSIFIED_PROPOSALS}${target}	${action}	${pattern_summary}	${proposed_text}	${citations}	${existing_ref}	${best_j}"$'\n'

  if [ "$action" = "TIGHTEN" ]; then
    TIGHTEN_PATTERNS="${TIGHTEN_PATTERNS}${pattern_summary}"$'\n'
  fi
done <<< "$RAW_PROPOSALS"

CLASSIFIED_PROPOSALS=$(printf '%s' "$CLASSIFIED_PROPOSALS" | sed '/^[[:space:]]*$/d')
```

### Step 5d: Inline TIGHTEN rewrite (Claude, not a subagent)

For each row in `$CLASSIFIED_PROPOSALS` with `action == TIGHTEN`, the
orchestrating Claude rewrites column 4 (`proposed_text`) in place so it
unambiguously covers BOTH the `existing_ref` directive AND the new cited
evidence from column 5. This is a single-sentence transformation — do NOT spawn
a subagent and do NOT call any tool beyond string substitution on the TSV.

Rewrite prompt (apply mentally per TIGHTEN row):

> Rewrite `proposed_text` into one imperative sentence, ≤ 200 characters, same
> scope as `existing_ref`, that unambiguously covers both the existing directive
> and the new cited evidence. Do not add new scope. Do not weaken the existing
> rule. Preserve any concrete file paths, commands, or error strings from the
> citations. Output the rewritten sentence only — no prose, no quotes.

After rewriting, replace column 4 in the matching TSV row. All other columns
stay identical. DUPLICATE and NEW rows are never rewritten.

### Step 5e: Anti-sprawl final sweep

Drop any `NEW` proposal whose `pattern_summary` (column 3) collides with a
`TIGHTEN` proposal's `pattern_summary`. Plan §6: if we're already tightening an
existing rule for a pattern, adding a new rule for the same pattern is sprawl.

```bash
if [ -n "$TIGHTEN_PATTERNS" ] && [ -n "$CLASSIFIED_PROPOSALS" ]; then
  SWEPT=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    action=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    psum=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
    if [ "$action" = "NEW" ] && printf '%s\n' "$TIGHTEN_PATTERNS" | grep -Fxq -- "$psum"; then
      echo "# retro: dropped NEW proposal for pattern '$psum' (TIGHTEN exists)" >&2
      continue
    fi
    SWEPT="${SWEPT}${row}"$'\n'
  done <<< "$CLASSIFIED_PROPOSALS"
  CLASSIFIED_PROPOSALS=$(printf '%s' "$SWEPT" | sed '/^[[:space:]]*$/d')
fi
```

### Handoff to Step 6 (T7/T8)

Step 5 produces two variables for Step 6 to consume:

- `CLASSIFIED_PROPOSALS` — TSV, 7 columns per row. Schema (repeated here so T7
  can parse without re-reading Step 5c):
  1. `target` — one of `pm tech-lead ic5 ic4 devops qa ds claude`
  2. `action` — `NEW` | `TIGHTEN` | `DUPLICATE`
  3. `pattern_summary` — short tag
  4. `proposed_text` — imperative sentence (rewritten for TIGHTEN per Step 5d)
  5. `citations` — comma-joined message IDs / line refs
  6. `existing_ref` — matched rule line (empty string for NEW)
  7. `best_jaccard` — float in `[0.000, 1.000]` (debug/telemetry)
- `OBSERVATIONS` — pass-through, unchanged from Step 4.

---

## Step 6: Phase-4 confirm / apply

<!-- T8 (--all mode) extends Steps 2 and 5 — it does NOT add a new step here. -->

### Step 6a: Short-circuit on empty input

If both `CLASSIFIED_PROPOSALS` and `OBSERVATIONS` are empty or contain only
whitespace, print:

```
No actionable findings.
```

Exit 0.

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
`N` (proposals for this target) and `M` (distinct source JSONL paths for this
target, from column 7). Print a group header before the first proposal:

```bash
# In single/explicit mode:
echo "=== <target> (<N> proposal(s)) ==="
# In --all mode:
echo "=== <target> (<N> proposal(s) across <M> session(s)) ==="
```

So for example: `=== ic5 (3 proposal(s) across 2 session(s)) ===`

For each proposal row (columns per Step 5 handoff schema):
- col 1: `target`
- col 2: `action`
- col 3: `pattern_summary`
- col 4: `proposed_text`
- col 5: `citations`
- col 6: `existing_ref`
- col 7: `best_jaccard`

#### Default mode (no `--auto`)

Present the proposal:

```
[<ACTION>] target=<target>
  Proposed: <proposed_text>
  Evidence:
    - <citation 1>
    - <citation 2>
    ...
  Existing rule (TIGHTEN/DUPLICATE only): <existing_ref>

Action: [a]pply / [r]eject / [e]dit / [s]kip remaining ?
```

(Omit the "Existing rule" line entirely for `NEW` proposals.)

Handle the user's response:

- **`a` (apply):**
  - If `target` is a **team agent** (`pm`, `tech-lead`, `ic5`, `ic4`, `devops`,
    `qa`, `ds`): print the slash command for the user to run manually — do NOT
    invoke it from within the retro command:
    ```
    Run: /adjust-agent <target> "<proposed_text>"
    ```
    Then print the current directive count for that agent:
    ```bash
    FILE="$MROOT/.claude/memory/<target>/directives.md"
    COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null || echo 0)
    printf '%s: %s directive(s) currently (run the command above to update)\n' "<target>" "$COUNT"
    ```
    Increment `APPLIED`.
  - If `target` is **`claude`**: append `proposed_text` to
    `$MROOT/.claude/memory/claude/lessons.md`. Create the file and parent
    directory if absent:
    ```bash
    mkdir -p "$MROOT/.claude/memory/claude"
    # Belt-and-braces: re-sanitize at write time. The T5 validator already
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

- If `target` is a **team agent**: invoke
  `/adjust-agent <target> --apply "<proposed_text>"`.

  This is a non-interactive apply: the slash command applies on no conflict and
  exits non-zero on conflict (never prompts). Handle the two outcomes:

  - **Exit 0 (success):** Increment `APPLIED`. Print the updated directive count:
    ```bash
    FILE="$MROOT/.claude/memory/<target>/directives.md"
    COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null || echo 0)
    printf '[auto-applied] %s: %s directive(s) now\n' "<target>" "$COUNT"
    ```
  - **Exit non-zero (conflict refused):** Do NOT silently drop. Append the
    proposal to `MANUAL_FOLLOWUP` with the conflict message captured from
    stderr. Print immediately:
    ```
    [conflict] <target>: "<proposed_text>"
      Conflict: <stderr from /adjust-agent --apply>
      → Added to manual follow-up list.
    ```

- If `target` is **`claude`**: append directly to
  `$MROOT/.claude/memory/claude/lessons.md` (no slash command needed):
  ```bash
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

Exit 0.
