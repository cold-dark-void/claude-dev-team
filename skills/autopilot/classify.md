<!-- /autopilot stage body — ship-gate bump classifier (SPEC-041 M5–M11).
     Companion to ship-pipeline.md Stage 0. Cites SPEC-033 (N3a baseline, M13
     card schema, BC7), SPEC-040 (M20 journal enum via walk-outcome), and
     SPEC-010 (bump-class gate at the fold); restates no contract. -->

# Ship-gate bump classifier (SPEC-041 M5–M11)

> Companion to `skills/autopilot/ship-pipeline.md` (its Stage 0) and
> `skills/autopilot/self-answer.md`. This file is a *procedure*, not a policy.
> SPEC-041 defines the classifier; this file carries it. Contract-home rule
> (SPEC-002 D1): it cites — never restates — SPEC-033 (N3a baseline; the M13
> card schema and its writer), SPEC-040 (the closed M20 journal enum, mapped
> by `sweep.sh walk-outcome`), and SPEC-010 (the B1–B6 gate at the fold,
> unchanged).

## 1. Purpose and stance

- Fires **only** under the `auto` ship-intent token, at the ship gate,
  **before** the ship-choice stages run (pre-fold, exactly once per item).
- The orchestrator classifies **in-session** (LLM judgment, no spawned agent)
  the diff against the SPEC-033 N3a worktree baseline — the **resolved push
  target**, i.e. the diff the fold will actually ship. Resolve that ref the
  way `end-state.md` §3 does (origin default branch, fetched first, same
  fail-closed posture); the fence takes it as `<baseline-ref>`.
- The orchestrator MUST NOT invoke `/release` interactively and MUST NOT
  re-run classification at fold time; the decided bump is passed explicitly
  down the existing tagged-release fold path (M5).
- Stage 0 is pure judgment: MUST NOT add a path-glob or extension-based
  filter (M8). The only deterministic step is the post-decision Surface veto
  (M9) through the shared `skills/release/detect-surfaces.sh` helper (AC8).

## 2. Frozen I/O contract

Input — the caller (ship-pipeline Stage 0) substitutes every `<…>` literal
before running §4's fence, in the worktree that carries the diff:

```
<baseline-ref>          N3a resolved push target (end-state §3 resolution, fetch included)
<stage0-code-bearing>   yes | no — the in-session stage-0 judgment
<stage1-answer>         raw stage-1 response, one token when well-formed; empty = absent
<stage0-evidence>       one line, redacted/summarized (M13 redaction rule)
<stage1-reason>         one line, redacted/summarized
<workflow> <ticket_id> <run_id> <iteration> <run_start_epoch>
                        C3 §2 envelope fields (self-answer.md §2)
```

Output — machine-read `CLASSIFY_*` lines on stdout; the caller acts on them:

```
CLASSIFY_DECISION=no-code|decided|halt
CLASSIFY_BUMP=<patch|minor>        decided path only
CLASSIFY_VETO=<one-line result>    decided path only
CLASSIFY_EVIDENCE=<one line>       decided path only — compose into card #1 rationale
CLASSIFY_CARD=<ledger path>        halt path only
CLASSIFY_JOURNAL=walk-outcome ...  no-code/halt paths — caller runs it (sweep 9e)
```

Exactly **one** card is appended, and **only on the halt path**. A decided
bump records itself through the existing stages: the caller substitutes the
decided token as the Stage-1 envelope's `autopilot_bump` (self-answer.md §2)
and composes `CLASSIFY_EVIDENCE` + the veto result into card #1's `rationale`
(M10 — the evidence rides the ship-choice card; the existing Stage 1/Stage 2
writers keep writing it). Exit 0 on a classification outcome — `halt` is an
outcome, not a failure. Exit 64 = machinery failure: no card, no decision
line, escalate out-of-band (self-answer.md §3b discipline).

## 3. Procedure

### a. Stage 0 — code-bearing judgment (LLM, in-session)

Judge the N3a baseline diff: does it contain a code-bearing change? This is
LLM judgment with the M7 fail-closed posture — MUST NOT add a path-glob or
extension-based filter (M8). **No** → the fence prints the `no-code` decision
and exits before any veto, card, tag, or fold (zero side effects, M6/AC7);
the caller journals from the closed M20 enum (sweep 9e) and the walk
continues with the next item. **Yes** → stage 1.

### b. Stage 1 — bump judgment (LLM, in-session)

Return exactly one of `{patch, minor, halt}`, judged from the same baseline
diff. A would-be `major` classifies as **`halt`** — the output space never
contains `major` (M6/M9). The raw response is what reaches the fence, even
when malformed: §4 validates it.

### c. Veto — deterministic Surface detection (after the LLM, M9)

`detect-surfaces.sh --against <baseline-ref>` runs on the same baseline diff.
Any printed path is a new top-level `commands/<name>.md` Surface (nested
paths are not; rename-onto-top-level counts as added):

| Stage-1 answer | Surface found | Result |
|---|---|---|
| `patch` | yes | **`minor`** (raised; veto recorded) |
| `minor` | yes | `minor` stands (veto recorded; no demotion) |
| `halt` | yes | `halt` stands (never rescued) |
| any | no | answer stands, veto `none` |

The veto never demotes, never rescues a `halt`, never produces `major`.

### d. Validate — fail-closed (M7)

The stage-1 response is valid iff it is exactly one token of
`{patch, minor, halt}`. Empty, non-enum, malformed, or absent → treated as
`halt`: the halt card records the raw response (redacted/summarized),
confidence 0, `blocking_condition` 7 (BC7 — the gate-answering step could not
answer); the caller raises the escalation and the walk continues, no tag, no
fold. Fleet-degradation posture per AGENTS.md applies. A deliberate stage-1
`halt` (would-be major) takes the same card shape with its reason in the
rationale.

### e. Journal — caller-owned, closed enum (M6/M7)

`no-code` and `halt` items are journaled by the caller from the **existing**
M20 enum — `sweep.sh walk-outcome --halt <condition>` maps to the walk's
non-shipped outcome (sweep.md Step 9e); the named conditions
`auto-stage-0-no-code` and `auto-classify-halt` are halt names carried in the
record's `evidence`, never new outcome values. A decided bump is journaled by
the existing post-fold flow (`walk-outcome --landed`).

## 4. The one executable fence

Every angle-bracket token is a literal substitution (§2). Fresh shell; run
from the worktree that carries the diff.

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
DETECT=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/detect-surfaces.sh)
BUDGET_CHECK=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/budget-check.sh)
APPEND_CARD=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/append-card.sh)

# §2 inputs — one line each, redacted/summarized by the caller (M13).
STAGE0="<stage0-code-bearing>"          # yes | no — in-session judgment (M8)
BASELINE_REF="<baseline-ref>"           # N3a resolved push target
STAGE1="<stage1-answer>"                # raw stage-1 response; empty = absent
STAGE0_EVIDENCE="<stage0-evidence>"
STAGE1_REASON="<stage1-reason>"

# Stage-0 No: zero side effects — no veto, no card, no tag, no fold (M6/AC7).
# A junk stage-0 input is a caller bug, not an outcome: machinery exit (§3b).
if [ "$STAGE0" != "yes" ]; then
  [ "$STAGE0" = "no" ] || exit 64
  printf 'CLASSIFY_DECISION=no-code\n'
  printf 'CLASSIFY_JOURNAL=walk-outcome --halt auto-stage-0-no-code\n'
  exit 0
fi

# Stage-1 validation — fail-closed (M7): exactly one token of patch|minor|halt.
FAILCLOSED=0
case "$STAGE1" in
  patch|minor|halt) ANSWER="$STAGE1" ;;
  *) ANSWER=halt; FAILCLOSED=1 ;;
esac

# Veto — deterministic, AFTER the LLM answer, same baseline diff (M9/AC8).
# Runs for EVERY validated answer — a halt's veto is recorded, never applied.
# A helper failure (bad ref / not a repo) is machinery: no card, exit 64.
VETO=none
VETO_OUT=""
if ! VETO_OUT=$(bash "$DETECT" --against "$BASELINE_REF"); then
  echo "classify: detect-surfaces failed against $BASELINE_REF — machinery error, no card" >&2
  exit 64
fi
if [ -n "$VETO_OUT" ]; then
  if [ "$ANSWER" = patch ]; then
    VETO="patch raised to minor — new Surface: $(printf '%s\n' "$VETO_OUT" | head -n 1)"
    ANSWER=minor
  else
    VETO="$ANSWER stands — new Surface recorded: $(printf '%s\n' "$VETO_OUT" | head -n 1)"
  fi
fi

# One line, control-char-free, <= 900 chars (writer cap 1000, M13). Newline
# family becomes spaces first so multi-line junk cannot concatenate words.
RATIONALE=$(printf 'auto classify: stage1=%s (%s); stage0=code-bearing (%s); veto=%s' \
  "$( [ "$FAILCLOSED" -eq 1 ] && printf 'fail-closed raw="%s"' "$STAGE1" || printf '%s' "$STAGE1" )" \
  "$STAGE1_REASON" "$STAGE0_EVIDENCE" "$VETO" \
  | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037\177' | tr -s ' ' | cut -c1-900)

if [ "$ANSWER" = halt ]; then
  # Exactly one M13 halt card (M10): decision halt, bump null, BC7, conf 0.
  if BC_OUT=$(bash "$BUDGET_CHECK" "<iteration>" "<run_start_epoch>"); then BC_RC=0; else BC_RC=$?; fi
  if [ "$BC_RC" -eq 64 ]; then
    echo "classify: budget-check validation failure — no card, escalate out-of-band" >&2
    exit 64
  fi
  WALL_CLOCK_S=$(printf '%s' "$BC_OUT" | jq -r '.wall_clock_s')
  if ! bash "$APPEND_CARD" \
      "<workflow>" "<ticket_id>" ship-choice halt auto \
      null 0 7 \
      "<run_id>" "<iteration>" "$WALL_CLOCK_S" orchestrator "$RATIONALE"; then
    echo "classify: append-card rejected the halt card — none was written; escalate, never retry silently" >&2
    exit 64
  fi
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)
  printf 'CLASSIFY_DECISION=halt\n'
  printf 'CLASSIFY_CARD=%s/.claude/autopilot/<ticket_id>.jsonl\n' "$MROOT"
  printf 'CLASSIFY_JOURNAL=walk-outcome --halt auto-classify-halt\n'
  exit 0
fi

# Decided: no card here — the decided bump feeds the Stage-1 envelope
# (autopilot_bump) and CLASSIFY_EVIDENCE composes into card #1's rationale
# (M10); Stage 3 passes the token explicitly to /release (end-state §5-release).
printf 'CLASSIFY_DECISION=decided\n'
printf 'CLASSIFY_BUMP=%s\n' "$ANSWER"
printf 'CLASSIFY_VETO=%s\n' "$VETO"
printf 'CLASSIFY_EVIDENCE=%s\n' "$RATIONALE"
```

`wall_clock_s` for the halt card comes from this fence's own fresh
`budget-check.sh` call (never a caller-side stale snapshot — same discipline
as self-answer.md §3f). A `budget-check.sh` exit 64 is a caller-envelope bug:
no card is written and the fence exits 64 (§3b). A BC6 breach (exit 6) does
not change the outcome — the halt stands either way and the measure is still
recorded. A writer reject means **no card exists**; escalate, never retry
silently.

## 5. Boundaries — what this classifier does NOT do

- **No spawned agent.** Stages 0 and 1 are in-session judgment (SPEC-041
  MUST NOT).
- **No deterministic stage-0 filter** (M8). `detect-surfaces.sh` is the
  post-decision veto only — it never decides the bump on its own.
- **No card on the no-code or decided paths.** Zero bump cards there (AC7);
  the decided bump's evidence rides the Stage-1 ship-choice card rationale.
- **No tag, no fold, no `/release`.** Every ref-mutating step stays with the
  caller's stages (end-state §5); the veto's `--against` ref is read-only.
- **No new journal outcome values.** The caller journals via `walk-outcome`
  from the closed M20 enum; `auto-stage-0-no-code` / `auto-classify-halt`
  are halt names, not outcomes (SPEC-040 M20).
- **No `auto` in any card bump field** (M3). `append-card.sh` rejects the
  token; the fence passes the decided concrete token or `null` only.
- **No re-classification.** Exactly one fence run per item, pre-fold; the
  decided token is carried, never re-derived at fold time (M5).
