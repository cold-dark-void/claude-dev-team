---
name: retro
description: Session retrospective — scan past sessions for friction patterns and propose targeted behavioral adjustments for team agents or plain Claude. Supports Claude Code and Grok hosts via --host. --all --auto writes a scheduled report under .claude/retro/.
argument-hint: "[<session-id>] [--host claude|grok|all] [--all] [--auto] [--why]"
agent: build
---

# /retro

Review past Claude Code and Grok sessions. Propose an adjustment for a team agent, for Claude lessons, or for the plugin.

`--all` keeps a pattern that recurs in 2 or more sessions. One session surfaces every pattern. Phase 1 is `gate.sh`. Phase 2 reads flagged sessions only.

## Step 0: Resolve roots

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Live worktree cwd for host adapters (Grok buckets key on this, not MROOT).
HOST_CWD="${WTROOT:-$(pwd)}"
```

## Step 1: Parse arguments

Parse the raw arguments string (everything after `/retro`).

Extract flags and positional arg:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
PARSE_ARGS=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/parse-args.sh)
# A Bash-tool fence has no positional arguments: read the user's text through a
# quoted heredoc, split it with globbing off (skill-lint C9), and let the one
# parser set MODE, AUTO, WHY, EXPLICIT_SID, HOST and HOST_EXPLICIT. Step 2 runs
# the same lines again (each fence is a fresh shell).
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
PARSED=$(bash "$PARSE_ARGS" "$@") || exit 1
eval "$PARSED"
printf 'PLUGIN_ROOT=%s\n' "$PDH"
```

`parse-args.sh` rejects `--all` plus a session id, a bad `--host`, and a missing `--host` value. `--host grok` never falls back to Claude. Copy `PLUGIN_ROOT` into later shells.

### Step 1b: Scheduled path lock (`--all --auto` only)

When both `MODE=all` and `AUTO=1`, this invocation is the **scheduled runner**
path (SPEC-012 S1–S9 / CDV-190). Acquire the project lock before discovery so
concurrent cron fires no-op cleanly. `acquire` prints an owner token. This fence
stores that token at `$MROOT/.claude/retro/scheduled.owner`. Empty, smooth, and
success paths release it by calling `invoke-scheduled-report.sh` from Steps 2d,
3c, 6a, and 6i. This fence does not release the lock. A lock-held skip does
**not** write a report, and it does **not** release a lock this run did not acquire.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
SCHED_LOCK=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro-gate/scheduled-lock.sh 2>/dev/null || true)
# Instrumentation for scheduled report (SPEC-012 S2); best-effort across steps.
SCANNED=0
SKIPPED_INPROG=0
SKIPPED_FILTER2=0
GATED_PASS=0
DEEP_READ=0
SCHEDULED_LOCK_HELD=0

if [ "$MODE" = "all" ] && [ "$AUTO" = "1" ]; then  # lint-ok: C1
  if [ -x "$SCHED_LOCK" ]; then
    # stdout is the owner token. stderr still carries the lock script's own messages.
    TOKEN=$(bash "$SCHED_LOCK" acquire "$MROOT")
    LOCK_RC=$?
    if [ "$LOCK_RC" -eq 2 ]; then
      echo "scheduled retro: lock held, skipping"
      exit 0
    fi
    if [ "$LOCK_RC" -ne 0 ]; then
      echo "# retro: scheduled lock acquire failed (rc=$LOCK_RC) — continuing without lock" >&2
    else
      SCHEDULED_LOCK_HELD=1
      # A later fence is a new shell. It releases only with this token.
      if [ -n "$TOKEN" ]; then
        mkdir -p "$MROOT/.claude/retro"
        printf '%s\n' "$TOKEN" > "$MROOT/.claude/retro/scheduled.owner"
        chmod 600 "$MROOT/.claude/retro/scheduled.owner" 2>/dev/null || true
        # Later fences are new shells. They pass this token to the invoker.
        # They must not read scheduled.owner, which a newer run may overwrite.
        printf 'SCHEDULED_LOCK_TOKEN=%s\n' "$TOKEN"
      fi
    fi
  fi
fi
```

## Step 2: Session discovery

### Step 2.0: Resolve the shared transcript-parse module

`discover.sh` calls `hosts.py`, `assemble.py`, and `freshness.sh` from this plugin. Explicit `--host grok` requires `hosts.py` and python3.

### Step 2a–2b: Resolve host + collect candidate SOURCE paths

Re-parse arguments in this fresh shell, then collect source paths. `discover.sh` auto-detects the host, writes `host<TAB>source`, and prints the gate-feed `SESSIONS` list.

```bash
PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
if [ -z "$PLUGIN_ROOT" ] && [ -f skills/retro-gate/discover.sh ]; then
  PLUGIN_ROOT=$(pwd)
fi
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
PARSED=$(bash "$PLUGIN_ROOT/skills/retro-gate/parse-args.sh" "$@") || exit 1
eval "$PARSED"
export MODE HOST HOST_EXPLICIT WHY AUTO EXPLICIT_SID HOST_CWD
bash "$PLUGIN_ROOT/skills/retro-gate/discover.sh"
```

### Step 2c: Apply filters + normalize to gate feed

Pipeline (SPEC-012 multi-host):

1. **Filter-1** — `freshness.sh check` on the **source** path (60 s mid-write guard).
2. **Normalize** — `hosts.py normalize --host … --mode scoring` → Claude-shaped gate feed
   (identity for Claude; TMPDIR JSONL for Grok).
3. **Filter-2** — skip if source **or** gate feed contains a `/retro` command-name marker.

`discover.sh` runs this filter. It calls `bash "$FRESHNESS" check`. `FRESH_RC` is 9 when `AGE` is under 60 seconds (in-progress). Filter 2 skips a source or a gate feed that contains `<command-name>/[a-z:-]*retro</command-name>`.

The script prints `SESSIONS`, the gate-feed paths.

```bash
# discover.sh already applied Filter 1 and Filter 2.
:
```

### Step 2d: Empty-set guard

```bash
if [ -z "${SESSIONS:-}" ]; then  # lint-ok: C1
  echo "No sessions to retro."
  PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
  bash "$PLUGIN_ROOT/skills/retro-gate/scheduled-exit.sh" --note "No sessions to retro." --summary "Applied: 0 | empty candidate set"
  exit 0
fi
```

`SESSIONS` is now a newline-separated list of absolute **gate-feed** JSONL paths
(Claude source identity, or Grok scoring-normalized under TMPDIR) ready for
phase-1 `gate.sh`.

---

## Step 3: Phase-1 gate

### Step 3a: Locate gate.sh

`gate-sessions.sh` locates `gate.sh`. A missing gate is a hard error.

### Step 3b: Gate each session with time budget

Single-session mode stops after 5 seconds. `--all` gives each file 2 seconds. The script writes `$GATE_CACHE/<id>.out` and prints `FLAGGED_SESSIONS`.

```bash
PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
export SESSIONS="${SESSIONS:-}" MODE="${MODE:-}" WHY="${WHY:-}" GATE_CACHE="${GATE_CACHE:-}"
bash "$PLUGIN_ROOT/skills/retro-gate/gate-sessions.sh"
```

### Step 3c: Early exit if nothing flagged

```bash
if [ -z "${FLAGGED_SESSIONS:-}" ]; then  # lint-ok: C1
  echo "No friction detected — nothing to retro."
  PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
  bash "$PLUGIN_ROOT/skills/retro-gate/scheduled-exit.sh" --note "No friction detected — nothing to retro (all smooth)." --summary "Applied: 0 | all-smooth | scanned=${SCANNED:-0} gated=0"
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

For each flagged session set `SESSION_JSONL`, `ANCHOR_MESSAGE_IDS_JSON`, and `FRICTION_SIGNALS_JSON` from `$GATE_CACHE`. Name `GATE_CACHE`. Do not run `gate.sh` again. A missing rules file is the literal `empty` on the prompt path only.


### Step 4c: Spawn subagents in parallel
Spawn one Task per flagged session, in one parallel block, with the prompt in `skills/retro-subagent/SKILL.md`. Collect `SUBAGENT_RESULTS` as `<jsonl><TAB><json>`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
_gsid=$(basename "${JSONL:-}" .jsonl)  # lint-ok: C1
FRICTION_SIGNALS_JSON=""
if [ -n "${GATE_CACHE:-}" ] && [ -n "$_gsid" ] && [ -f "${GATE_CACHE}/${_gsid}.out" ]; then  # lint-ok: C1
  FRICTION_SIGNALS_JSON=$(cat "${GATE_CACHE}/${_gsid}.out")
fi
# lint-ok: C1 — ANCHOR_IDS is session-held by the orchestrating Claude
ANCHOR_MESSAGE_IDS_JSON=$(printf '%s\n' "${ANCHOR_IDS:-}" | JSONL="${JSONL:-}" python3 -c '
import os, sys, json
prefix = os.environ.get("JSONL", "") + " "
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
ids = [p.split(None, 1)[1] for p in lines if prefix.strip() and p.startswith(prefix)]
print(json.dumps(ids))
')
```

Read each `$MROOT/.claude/memory/<agent>/directives.md` (and `claude/lessons.md`) into the prompt. A missing file is the literal `empty`. Do not run `gate.sh` again. Spawn the Task from `skills/retro-subagent/SKILL.md`.

After each parallel Task call returns with its `$RETURNED_JSON`, append one row
to `SUBAGENT_RESULTS`:

```bash
SUBAGENT_RESULTS="${SUBAGENT_RESULTS}${JSONL}$(printf '\t')${RETURNED_JSON}
"
```

The accumulation above describes the logical shape of `SUBAGENT_RESULTS` that
Step 4d consumes.

### Step 4d: Parse + validate per the SKILL.md contract

`parse-subagent.sh` sanitizes newlines and tabs, recomputes `anchor_id`, and writes `RAW_PROPOSALS`. It persists anchors under `$MROOT/.claude/retro/anchors/`.

```bash
PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
export SUBAGENT_RESULTS="${SUBAGENT_RESULTS:-}"
bash "$PLUGIN_ROOT/skills/retro-gate/parse-subagent.sh"
```

### Step 4e: Rank, repeat-filter, then cap

`skills/retro-gate/classify.py` does this. In `--all` it drops patterns that
occur in only one distinct session (token overlap, so a reworded summary still
matches) **before** the top-5 cap. Other modes cap by the rank column only.

Do not sort or `head -5` in this step. The next step runs the script.

---

## Step 5: Phase-3 routing and deduplication

Classify each surviving proposal in `$RAW_PROPOSALS` as `NEW`, `TIGHTEN`, or
`DUPLICATE` against the existing rule corpus for its target. Output is
`CLASSIFIED_PROPOSALS` (TSV, schema documented at the end of this step).

`OBSERVATIONS` flows through untouched — it's handed to Step 6 as-is.

### Step 5a: Repeat filter

Handled inside `classify.py` when `MODE=all`. A pattern that shares tokens with
another session's summary is one repeat. A same-session duplicate is a singleton.

### Step 5b: Rules

`classify.py` reads each target's directives file itself. Do not load
`RULES_PM` .. `RULES_CLAUDE` here. Nothing in a later step reads those variables.

### Step 5c: Deterministic NEW / TIGHTEN / DUPLICATE classification

`classify.py` tokenizes on `[^a-z0-9]+`, drops the short stopword list, and classifies. Overlap of 2 tokens or jaccard ≥ 0.35 is a candidate. No candidate is `NEW`. Jaccard ≥ 0.65 is `DUPLICATE`. Else `TIGHTEN`.

Canonical `CLASSIFIED_PROPOSALS` columns, one TSV row:

1. `target` 2. `action` (`NEW`, `TIGHTEN`, or `DUPLICATE`) 3. `pattern_summary` 4. `proposed_text` (`classify.py` already merged a `TIGHTEN` row) 5. `citation_count` 6. `existing_ref` 7. `best_jaccard` 8. `source_jsonl` 9. `citations_json`

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
MODE=${MODE:-single}
RAW_PROPOSALS=${RAW_PROPOSALS:-}
if [ -f "$PLUGIN_ROOT/skills/retro-gate/classify.py" ]; then
  CLASSIFY="$PLUGIN_ROOT/skills/retro-gate/classify.py"
elif [ -f skills/retro-gate/classify.py ]; then
  CLASSIFY="$(pwd)/skills/retro-gate/classify.py"
else
  CLASSIFY=""
fi
if [ -n "$CLASSIFY" ]; then
  CLASSIFIED_PROPOSALS=$(printf '%s\n' "$RAW_PROPOSALS" | python3 "$CLASSIFY" --mode "$MODE" --mroot "$MROOT")
else
  echo "# retro: classify.py missing; leaving proposals unclassified" >&2
  CLASSIFIED_PROPOSALS=""
fi
```

### Step 5d: Deterministic TIGHTEN merge

`classify.py` writes column 4 for `TIGHTEN` as `existing_ref` without a trailing period, then `; additionally, `, then the proposal, cut at 200 characters. Apply uses that column. Do not rewrite it again.

### Step 5e: Anti-sprawl final sweep

`classify.py` drops a `NEW` row whose `pattern_summary` equals a `TIGHTEN` row.


### Handoff to Step 6

Pass `CLASSIFIED_PROPOSALS` (the Step 5c columns) and `OBSERVATIONS` to Step 6.

---

## Step 5.5: Trial review (SPEC-001 M4–M7 / CDV-200)

Before presenting or applying new proposals, review elapsed directive trials.
Helpers are pure subprocess CLIs under `skills/retro-gate/` (never sourced).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
TRIAL_REVIEW="$PLUGIN_ROOT/skills/retro-gate/trial-review.sh"
TRIAL_META="$PLUGIN_ROOT/skills/retro-gate/trial-meta.sh"
TRIAL_DECISIONS=""   # TSV from trial-review.sh (KEEP|REVERT rows)
if [ -n "$TRIAL_REVIEW" ] && [ -f "$TRIAL_REVIEW" ]; then  # lint-ok: C1
  # Scope: match discovery mode. --all → all projects; else current project only.
  # Session discovery inside trial-review.sh stays in sync with Step 2
  # (~/.claude/projects/, skip mtime <60s, gate.sh scores).
  SCOPE_ARG="current"
  [ "${MODE:-single}" = "all" ] && SCOPE_ARG="all"  # lint-ok: C1
  TR_ERR=$(mktemp "${TMPDIR:-/tmp}/trial-review.XXXXXX" 2>/dev/null) || TR_ERR=""
  TRIAL_DECISIONS=$(bash "$TRIAL_REVIEW" --mroot "$MROOT" --scope "$SCOPE_ARG" 2>"${TR_ERR:-/dev/null}" || true)
  if [ -n "$TR_ERR" ] && [ -s "$TR_ERR" ]; then
    # DEFER lines and diagnostics — surface lightly
    sed 's/^/# /' "$TR_ERR" 2>/dev/null | head -20 || true
  fi
  [ -z "$TR_ERR" ] || rm -f "$TR_ERR" 2>/dev/null || true
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

For each `TRIAL_DECISIONS` row, show the agent, the directive, the window, and both means.

Interactive `a` + KEEP prints `Run: /adjust-agent <agent> "Promote the following trial directive to permanent by removing only its trial annotation (leave the directive text). Do not add or remove other directives: <stripped>"`. REVERT prints `Run: /adjust-agent <agent> "Remove this directive entirely (trial REVERT): <stripped>"`. Strip with `trial-meta.sh strip` first. Do not invoke the command in interactive mode. `r` rejects with no audit line.

`--auto` invokes the same text with `--apply`. Exit 0: print `[auto-applied] trial <KEEP|REVERT> <agent>` and record the decision. A non-zero exit appends the row to `MANUAL_FOLLOWUP`.

After a successful apply, record it:

```
bash skills/retro-gate/trial-review.sh --record-decision --mroot "$MROOT" \
  --agent "$agent" --directive "$stripped_text" --source "$source" \
  --trial-start "$trial_start" \
  --baseline-mean "$baseline_mean" --baseline-n "$baseline_n" --baseline-ids "$baseline_ids" \
  --in-trial-mean "$in_trial_mean" --in-trial-n "$in_trial_n" --in-trial-ids "$in_trial_ids" \
  --decision KEEP --decided-by user
```

Use `--decision REVERT` or `--decided-by auto` when that is the case. Do not write `directives.md` from this step.

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
_short=$(printf '%s' "${CLASSIFIED_PROPOSALS:-}${OBSERVATIONS:-}${TRIAL_DECISIONS:-}" | sed '/^[[:space:]]*$/d')  # lint-ok: C1
if [ -z "$_short" ]; then
  echo "No actionable findings."
  PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
  bash "$PLUGIN_ROOT/skills/retro-gate/scheduled-exit.sh" --note "No actionable findings." --summary "Applied: 0 | no actionable findings"
  exit 0
fi
```

### Step 6b: Separate DUPLICATE proposals from actionable ones

Partition `CLASSIFIED_PROPOSALS` into two sets:

- `ACTIONABLE_PROPOSALS` — rows where `action` is `NEW` or `TIGHTEN`
- `DUPLICATE_PROPOSALS` — rows where `action` is `DUPLICATE`

DUPLICATE proposals are **never auto-applied**, even in `--auto` mode. They are
surfaced at the end as an advisory list (see Step 6d).

### Step 6c: Apply loop

Set `APPLIED=0`, `REJECTED=0`, `SUGGESTED=0`, and `MANUAL_FOLLOWUP=""`.

Group `ACTIONABLE_PROPOSALS` by column 1 (`target`). `N` is the row count. `M` is the count of distinct column 8 paths. Print `=== <target> (<N> proposal(s) across <M> session(s)) ===` in `--all`, and omit the session clause otherwise.

For each row, column 4 is `proposed_text`, column 6 is `existing_ref`, and column 9 is `citations_json`. Print one `Evidence:` line per citation (`message_id` and `excerpt` on one line). Omit the existing-rule line when the action is `NEW`.

`APPLY_TEXT` for `TIGHTEN` is column 4. `classify.py` already merged it. Do not rebuild it. Do not add trial meta.

For a team-agent `NEW` row, default to a trial. Annotate with `trial-meta.sh annotate --review-after 10-sessions` unless the user picks permanent. Interactive mode prints `Run: /adjust-agent <target> "<APPLY_TEXT>"` and does not invoke it. `--auto` runs `/adjust-agent <target> --apply "<APPLY_TEXT>"`.

```bash
SUGGESTED=$(( ${SUGGESTED:-0} + 1 ))
```

Count a printed team-agent command as `SUGGESTED`, not `APPLIED`. On `--auto` exit 0, increment `APPLIED` and print the directive count. On a non-zero exit, append the row to `MANUAL_FOLLOWUP` and print the conflict. Do not drop it.

`plugin`: interactive mode prints `Run: /backlog add "<proposed_text>"` and increments `SUGGESTED`. `--auto` direct-writes that backlog item and increments `APPLIED`.

`claude`: append one sanitized line to `$MROOT/.claude/memory/claude/lessons.md` and increment `APPLIED`.

Interactive actions: `a` apply, `r` reject (`REJECTED`), `e` edit and re-prompt, `s` skip the rest (count the rest as rejected). An unknown answer re-prompts.
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
Suggested:        <SUGGESTED>   (printed /adjust-agent or /backlog add only)
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

Anchors are persisted under `$MROOT/.claude/retro/anchors/<id>.json` after
validation (Step 4d) so `/council --from-retro <anchor-id>` can load them
without re-scanning session JSONL (CDV-212 / SPEC-012 / SPEC-013).

```bash
if [ -n "$FABRICATION_ANCHORS" ]; then  # lint-ok: C1
  FA_COUNT=$(printf '%s\n' "$FABRICATION_ANCHORS" | grep -c '.' || true); FA_COUNT=${FA_COUNT:-0}
  echo ""
  echo "Detected ${FA_COUNT} fabrication anchor(s) — consider auditing with /council:"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    AID=$(printf '%s' "$row" | cut -f1)
    echo "  - Consider: /council --from-retro $AID"
  done <<< "$FABRICATION_ANCHORS"
fi
```

### Step 6i: Scheduled report (`--all --auto` only, CDV-190)

When both flags are set, `report-step.sh` calls `write-scheduled-report.sh`, prints `Report: <path>`, and releases `scheduled-lock` with the owner token. Parked `MANUAL_FOLLOWUP` rows stay out of Applied. There is no EXIT trap.

```bash
PLUGIN_ROOT=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}  # lint-ok: C1
export MODE="${MODE:-}" AUTO="${AUTO:-}" ACTIONABLE_PROPOSALS="${ACTIONABLE_PROPOSALS:-}" MANUAL_FOLLOWUP="${MANUAL_FOLLOWUP:-}" DUPLICATE_PROPOSALS="${DUPLICATE_PROPOSALS:-}" OBSERVATIONS="${OBSERVATIONS:-}" SUGGESTED="${SUGGESTED:-0}" REJECTED="${REJECTED:-0}" SCHEDULED_LOCK_TOKEN="${SCHEDULED_LOCK_TOKEN:-}" SCANNED="${SCANNED:-0}" SKIPPED_INPROG="${SKIPPED_INPROG:-0}" SKIPPED_FILTER2="${SKIPPED_FILTER2:-0}" GATED_PASS="${GATED_PASS:-0}" DEEP_READ="${DEEP_READ:-0}"
bash "$PLUGIN_ROOT/skills/retro-gate/report-step.sh"
```

Exit 0.
