<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Arguments

- `/orchestrate <ISSUE-ID>` — fetch from Linear or prompt for context
- `/orchestrate` — prompts for issue ID
- `[--autopilot[=<token>]]` — optional, any position: enable autopilot for this run
  (CDT-111-C4 / SPEC-033 / CDT-195). Bare `--autopilot` or `AUTOPILOT=1` env =
  enabled, bump `null` (PR-stop default at ship-choice);
  `--autopilot=<patch|minor|major>` = release ship intent (merge → end-state
  §5-release); `--autopilot=master` = **land-no-release** (merge → end-state §5b;
  token spelling only — land target is worktree baseline / origin default, not
  necessarily a branch named `master`; **MUST NOT** pass `master` to `/release`).
  Flag wins over env. See `skills/autopilot/parse-flags.sh` + Step 0 "Autopilot
  detection".
- `[--council-tier=<skip|light|full>]` — optional, any position: DRI-supplied
  override for every `requires_council: true` task-gate council run in this
  orchestration (CDT-126, SPEC-013 § Council tiering). Scoped like `--autopilot`
  itself — resolved once at Step 0, applies for the whole run. No env-var
  equivalent and never auto-selected; omitting it runs every task-gate council
  call at `full` (`commands/council.md` does not auto-grade any scope it
  resolves on its own — Task 3's F-A fix). See Step 0 "Council tier
  detection" and Step 9 "Council gate for `requires_council: true` tasks".
- `[--tier=<light|standard|full>]` — optional, any position: pipeline cost
  tier (CDT-206 / SPEC-009). `=` form only. No env. Not resume-seeded.
  Independent of `--council-tier`. Omit records `ORCH_TIER` as the literal
  string `"null"`; test with `[ "$ORCH_TIER" = "null" ]`. Later steps MAY
  branch on `[ "$ORCH_TIER" = "light" ]` only.
- `[--max-loc=<n|unbound>]` — optional, any position: per-run DRI LOC-cap
  override (CDT-223 / SPEC-033 AC8 / SPEC-009). `=` form only. No env. Not
  resume-seeded. Independent of `--tier` / `--council-tier`. Consume only
  when `AUTOPILOT_ON=true` (autopilot off: parse still runs; value unused).
  Omit records `MAX_LOC` as the literal string `"null"`. MUST NOT pass
  `--max-loc` on `reroute-epic` unless caller argv already has it.
  MUST NOT add a `--max-loc` analog for iteration/wall-clock caps (N12 — no
  cap flags; `parse-flags.sh` stays six-key). MUST NOT export
  `AUTOPILOT_BUDGET_META` on `reroute-epic` (N13 — child derives its own freeze).
- `[--with-advisor[=<model>]]` — optional, any position: opt-in advisor for
  this run (SPEC-039 M9/M10/M37). Parsed once at Step 0 by the sibling parser
  `skills/advisor/parse-flags.sh`; the six-key autopilot parser stays six-key.
  Flag on → enabled/source=flag; no flag and env `ADVISOR` in `{1,true}` →
  enabled/source=env; else disabled/none. Flag wins over env. Duplicate
  `--with-advisor` exits 64. The omp host flag `--advisor` neither enables the
  advisor nor exits 64. Default off; byte-identical off (M11) means no advisor
  spawn, no `ask.sh` call, no `actor:advisor` card.
  `=<model>` is the run's advisor model override: it wins over the Model map,
  it enables an unmapped advisor, and Step 0 records it in `ADVISOR_MODEL`
  (empty when absent). Pass it to every probe as `--model "$ADVISOR_MODEL"`
  only when `[ -n "$ADVISOR_MODEL" ]`, and pass it to `appeal.sh gate` the same
  way — SPEC-039 M37 owns the full rule, including the token charset and the
  reserved `null` / `--clear` values. The first decision card records
  enablement, `ADVISOR=1` when source=env (M12), and `advisor_model=<model>`
  when overridden. On `reroute-epic` with the advisor on: run
  `epic-lib set-with-advisor <EPIC-ID> true` (plus the model as the third
  argument when non-empty) before handing off, and export `ADVISOR=1` plus
  `ADVISOR_MODEL="<model>"` into the `/epic` child environment (M10/M37).
- `[--concurrency N]` — optional, any position: Spawn concurrency cap for the fleet
  council runs of this orchestration (CDT-573 / SPEC-013 § Spawn concurrency cap).
  Both forms: `--concurrency N` and `--concurrency=N`. Capture only — Step 0 stores
  the user's token verbatim in `ORCH_CONCURRENCY` (empty when the flag is absent;
  no env, no Model map read, no resume-state seeding; independent of
  `--council-tier` / `--tier` / `--max-loc`). This run resolves and validates
  nothing: the council engine's preflight owns that one merge and exits 64 on a bad
  value — print that stderr and stop, never retry unbounded. Carry the token to the
  Step 6c, Step 8, and Step 9 council gates and to the M14 ship gate
  (`skills/autopilot/ship-gate-council.md`). MUST NOT reach the Step 8 IC spawn
  fence, the Step 4 kickoff spawns, the single council-judge spawn, or any advisor
  spawn (SPEC-013 § CDT-573 AC2 — the IC DAG is not a fleet). See Step 0 "Spawn
  concurrency cap capture".
- `[--resume-ship[=<patch|minor|major|master>]]` — optional (CDT-135 / SPEC-033 /
  CDT-195): after a human overrides a BC7 ship-choice halt, run the **single
  confirmed ship sequence** (end-state land path + wrap) without re-running the
  full orchestration. Bare re-reads plan/card mode; explicit `=master|patch|minor|major`
  overrides. `=master` resumes land-no-release (token spelling; land target is
  worktree baseline). See Step 11 § Resume ship after BC7 override.

## Step 0: Resolve roots and load context

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

`$PDH` is the install-aware plugin root: helper scripts ship in the plugin
(not the user's repo), so every `skills/…` helper below is resolved through
`bash "$PDH/skills/plugin-dir.sh" file <relpath>` rather than `$MROOT/skills/…`.

Read in parallel:
- `$MROOT/AGENTS.md`
- Claude memory:
  ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='claude' AND tier > 0 AND archived=FALSE;")
    if [ "${HAS_DISTILLED:-0}" -gt 0 ]; then
      sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- Tech Lead and PM load their own memory via their agent definitions when spawned
  in Step 4 — the orchestrator does not load it here.

If ISSUE-ID missing, ask:
> "Issue ID (e.g. CDV-1):"

### Autopilot detection (CDT-111-C4)

Resolve autopilot enablement once, at run start — every gated checkpoint below
(Step 2 scope-confirm, Step 6 plan-approve, Step 11 ship-choice) reuses these values
by reference. `ITER` starts at `0` on a fresh run and increments once per
orchestration stint; resuming (`RESUMING=true`) restores it from
`resume-state.sh --iteration` instead of resetting it (SPEC-033 M9a).

```bash
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
AP=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/parse-flags.sh)
AP_JSON=$(bash "$AP" "$@") || { echo "$AP_JSON" >&2; exit 64; }   # 64 = malformed --autopilot=<bump>, --tier, --max-loc; a duplicate/near-miss --autopilot|--council-tier|--max-loc flag (SPEC-033 M16)
AUTOPILOT_ON=$(jq -r .enabled <<<"$AP_JSON")
AUTOPILOT_BUMP=$(jq -r '.bump // "null"' <<<"$AP_JSON")
AP_SOURCE=$(jq -r .source <<<"$AP_JSON")            # flag | env | none
# CDT-126: DRI --council-tier=<skip|light|full> override, resolved once for
# the whole run from the same parse-flags.sh call — no precedence interaction
# with --autopilot, no resume-state seeding (unlike AUTOPILOT_ON/BUMP, this
# is not persisted; a resumed run without the flag re-resolves to null).
COUNCIL_TIER_OVERRIDE=$(jq -r '.council_tier // "null"' <<<"$AP_JSON")
# CDT-206: DRI --tier=<light|standard|full> pipeline cost tier, resolved once
# for the whole run from the same parse-flags.sh call — independent of
# --council-tier, no env, no resume-state seeding (unlike AUTOPILOT_ON/BUMP;
# a resumed run without the flag re-resolves to the 4-character string "null").
# Identity test: [ "$ORCH_TIER" = "null" ] — never emptiness. Later steps
# MAY branch on [ "$ORCH_TIER" = "light" ] only.
ORCH_TIER=$(jq -r '.tier // "null"' <<<"$AP_JSON")
# CDT-223: DRI --max-loc=<n|unbound> per-run LOC-cap, resolved once for the
# whole run from the same parse-flags.sh call — independent of --tier /
# --council-tier, no env, no resume-state seeding (unlike AUTOPILOT_ON/BUMP;
# a resumed run without the flag re-resolves to the 4-character string "null").
# Consume only when AUTOPILOT_ON=true. Autopilot off: parse still runs
# (junk → 64 above); value unused. MUST NOT pass --max-loc on reroute-epic
# unless caller argv already has it. MUST NOT add a --max-loc analog for
# iteration/wall-clock caps (N12). MUST NOT export AUTOPILOT_BUDGET_META on
# reroute-epic (N13).
MAX_LOC=$(jq -r '.max_loc // "null"' <<<"$AP_JSON")

# SPEC-039 M9/M10: sibling --with-advisor parser — resolved once for the
# whole run. Independent of the six-key autopilot parser above (which MUST
# NOT gain a 7th key). Byte-identical off (M11): when ADVISOR_ON=false,
# nothing downstream changes — no advisor spawn, no ask.sh call, no
# actor:advisor card. When ADVISOR_ON=true, the run's FIRST decision card
# (Step 2 scope-confirm) records the enablement in its rationale; when
# ADVISOR_SOURCE=env that rationale MUST mention `ADVISOR=1` (M12).
ADVISOR_PF=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/parse-flags.sh)
ADVISOR_JSON=$(bash "$ADVISOR_PF" "$@") || { echo "$ADVISOR_JSON" >&2; exit 64; }
ADVISOR_ON=$(jq -r .enabled <<<"$ADVISOR_JSON")
ADVISOR_SOURCE=$(jq -r .source <<<"$ADVISOR_JSON")
# M37: a --with-advisor=<model> (or ADVISOR_MODEL env) override for this run.
# Empty when absent — ADVISOR_MODEL is a live env channel the probe reads, so
# never carry a sentinel string here. Pass --model only when it is non-empty.
ADVISOR_MODEL=$(jq -r '.model // empty' <<<"$ADVISOR_JSON")

# Resume detection (CDT-111-C8): only when THIS invocation gave neither
# --autopilot nor AUTOPILOT= (flag/env always win over recorded state).
RESUMING=false
ITER=0                                              # ++ once per stint; restored below on resume (SPEC-033 M9a)
if [ "$AP_SOURCE" = none ]; then
  RS=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/resume-state.sh)
  RS_JSON=$(bash "$RS" "<ISSUE-ID>")
  if [ "$(jq -r .found <<<"$RS_JSON")" = true ]; then
    REC_ON=$(jq -r '.autopilot_on // "null"' <<<"$RS_JSON")
    if [ "$REC_ON" != null ]; then
      AUTOPILOT_ON=$REC_ON
      AUTOPILOT_BUMP=$(jq -r '.autopilot_bump // "null"' <<<"$RS_JSON")
      RESUMING=true
      PLAN_PATH=$(jq -r .plan <<<"$RS_JSON")
      ITER=$(bash "$RS" --iteration "<ISSUE-ID>")   # SPEC-033 M9a: restored, not reset
      case "$ITER" in ''|*[!0-9]*) ITER=0 ;; esac
      if [ "$AUTOPILOT_ON" = true ]; then
        echo "resuming <ISSUE-ID> in recorded autopilot mode (bump=$AUTOPILOT_BUMP) — plan: $PLAN_PATH"
      else
        echo "resuming <ISSUE-ID> — recorded state: autopilot off — plan: $PLAN_PATH"
      fi
    fi
  fi
fi
```

### Spawn concurrency cap capture (CDT-573)

Capture the user's Spawn concurrency cap token once, at run start, verbatim. This
fence resolves and validates nothing: no `resolve-concurrency.sh` call, no
`COUNCIL_CONCURRENCY` env read, no Model map read. The council engine's preflight owns
that one merge (`--concurrency` > env > map, SPEC-013 § Spawn concurrency cap) and
exits 64 on a bad value; that stderr surfaces verbatim at the gate that runs it —
print it and stop, never retry unbounded.

```bash
# CDT-573: verbatim capture only. The token is carried to every fleet council
# invocation this run makes (Step 6c, Step 8 addendum, Step 9 task gate, M14 ship
# gate) and nowhere else — never the IC spawn fence (SPEC-013 AC2).
ORCH_CONCURRENCY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --concurrency)
      if [ "$#" -ge 2 ]; then ORCH_CONCURRENCY="$2"; shift; fi
      shift ;;
    --concurrency=*)
      ORCH_CONCURRENCY="${1#--concurrency=}"; shift ;;
    *) shift ;;
  esac
done
printf 'ORCH_CONCURRENCY=%s\n' "$ORCH_CONCURRENCY"
```

Empty means unbounded: the sites append nothing and the engine resolves env and the
Model map for itself. A bare `--concurrency` with no following token also captures
the empty string — the engine's missing-argument exit 64 fires only for a token that
reaches it. `--concurrency 0` and a non-integer are carried verbatim to the gate and
fail closed there. No resume-state seeding: a resumed run without the flag is
unbounded.

### Run-start epoch and RUN_ID (SPEC-033 M9a)

```bash template
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RS=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/resume-state.sh)
if [ -z "$RS" ]; then
  echo "00-resolve: cannot resolve skills/autopilot/resume-state.sh via plugin-dir.sh" >&2
  exit 1
fi
# RUN_START_EPOCH: synthetic on resume so BC6's wall-clock cap measures active
# execution time only — pause duration must never count (SPEC-033 M9a).
NOW=$(date +%s)
if [ "<RESUMING>" = true ]; then
  ACCUM=$(bash "$RS" --accumulated "<ISSUE-ID>") || ACCUM=""
  case "$ACCUM" in ''|*[!0-9]*) ACCUM=0 ;; esac
  if [ "$ACCUM" -gt 0 ]; then
    RUN_START_EPOCH=$(( NOW - ACCUM ))
  else
    RUN_START_EPOCH=$NOW
  fi
else
  RUN_START_EPOCH=$NOW
fi
RUN_ID="orchestrate-<ISSUE-ID>-$RUN_START_EPOCH"    # S3-derivable per C3 §2
```

On a fresh `/orchestrate <ISSUE-ID>`, `skills/lib/plan-resolve.sh find <ISSUE-ID>`
(via `resume-state.sh`) seeds autopilot state only when no `--autopilot`/
`AUTOPILOT=1` was given on this invocation (flag/env win over recorded state —
`parse-flags.sh`'s own precedence, `source=="none"` is the signal). A legacy
plan with no `## Tracking` `- ticket_id:` line is not found (SPEC-033 M9a
D11). Pause time is excluded from BC6 via the synthetic epoch (SPEC-033 M9a,
CDT-111-C8).

**Freeze-on-resume (SPEC-033 AC9 / M9b / N13).** Frozen caps live on the
plan-approve card nested `budget.{tier,source,signals}` — read via
`read-cards.sh`, not via `resume-state.sh`. `resume-state.sh` seeds only
`autopilot_on` / `autopilot_bump` (plus the synthetic epoch from
`--accumulated`). MUST NOT seed caps from plan frontmatter. Pre-CDT-224 cards
(nested keys absent or null) resume as static M unless env. Mid-run env
mutation MUST NOT retune. Later gates copy the freeze (engine argc=4); Step 0
does not re-derive. MUST NOT export `AUTOPILOT_BUDGET_META` on `reroute-epic`
(child `/epic` or `/orchestrate` derives its own freeze).

### Re-mint after a human approval wait

`cross-cutting.md` § "Approval wait under autopilot" runs this fence on the
human's reply, after the `approval-wait:` halt card written before the block
(SPEC-033 M9a). `RUN_ID` is unchanged — only `RUN_START_EPOCH` re-mints, from
the same synthetic-epoch rule as the run-start fence above.

```bash template
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RS=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/resume-state.sh)
if [ -z "$RS" ]; then
  echo "re-mint: cannot resolve skills/autopilot/resume-state.sh via plugin-dir.sh" >&2
  exit 1
fi
NOW=$(date +%s)
ACCUM=$(bash "$RS" --accumulated "<ISSUE-ID>" 2>&1)
ACCUM_RC=$?
if [ "$ACCUM_RC" -ne 0 ]; then
  echo "re-mint: resume-state.sh --accumulated failed: $ACCUM" >&2
  exit 1
fi
case "$ACCUM" in
  ''|*[!0-9]*)
    echo "re-mint: resume-state.sh --accumulated printed a non-integer: '$ACCUM'" >&2
    exit 1
    ;;
esac
RUN_START_EPOCH=$(( NOW - ACCUM ))
echo "RUN_START_EPOCH=$RUN_START_EPOCH"   # RUN_ID unchanged (SPEC-033 M9a)
```

Every later reference to `AUTOPILOT_ON` / `AUTOPILOT_BUMP` / `RUN_ID` /
`RUN_START_EPOCH` / `ITER` / `COUNCIL_TIER_OVERRIDE` / `ORCH_TIER` / `MAX_LOC` /
`ADVISOR_ON` / `ADVISOR_SOURCE` / `ADVISOR_MODEL` / `ORCH_CONCURRENCY` below means
these values, carried forward from this step.

---
