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
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
```

`$PDH` is the install-aware plugin root: helper scripts ship in the plugin
(not the user's repo), so every `skills/…` helper below is resolved through
`bash "$PDH/skills/plugin-dir.sh" file <relpath>` rather than `$MROOT/skills/…`.

Read in parallel:
- `$MROOT/AGENTS.md`
- Claude memory:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
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
by reference. `ITER` starts at `0` and increments once per orchestration stint.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
AP=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/parse-flags.sh)
AP_JSON=$(bash "$AP" "$@") || { echo "$AP_JSON" >&2; exit 64; }   # 64 = malformed --autopilot=<bump> or --tier or --max-loc
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

# Resume detection (CDT-111-C8): only when THIS invocation gave neither
# --autopilot nor AUTOPILOT= (flag/env always win over recorded state).
RESUMING=false
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
      if [ "$AUTOPILOT_ON" = true ]; then
        echo "resuming <ISSUE-ID> in recorded autopilot mode (bump=$AUTOPILOT_BUMP) — plan: $PLAN_PATH"
      else
        echo "resuming <ISSUE-ID> — recorded state: autopilot off — plan: $PLAN_PATH"
      fi
    fi
  fi
fi

# RUN_START_EPOCH: synthetic on resume so BC6's wall-clock cap measures active
# execution time only — pause duration must never count (SPEC-033 M9a).
NOW=$(date +%s)
if [ "$RESUMING" = true ]; then
  ACCUM=$(bash "$RS" --accumulated "<ISSUE-ID>")   # $RS resolved above, same script
  if [ "$ACCUM" -gt 0 ]; then
    RUN_START_EPOCH=$(( NOW - ACCUM ))
  else
    RUN_START_EPOCH=$NOW
  fi
else
  RUN_START_EPOCH=$NOW
fi
RUN_ID="orchestrate-<ISSUE-ID>-$RUN_START_EPOCH"    # S3-derivable per C3 §2
ITER=0                                              # ++ once per stint
```

On a fresh `/orchestrate <ISSUE-ID>`, an existing `.claude/plans/*-<ISSUE-ID>-*.md`
seeds autopilot state only when no `--autopilot`/`AUTOPILOT=1` was given on this
invocation (flag/env win over recorded state — `parse-flags.sh`'s own precedence,
`source=="none"` is the signal). Pause time is excluded from BC6 via the synthetic
epoch (SPEC-033 M9a, CDT-111-C8).

**Freeze-on-resume (SPEC-033 AC9 / M9b / N13).** Frozen caps live on the
plan-approve card nested `budget.{tier,source,signals}` — read via
`read-cards.sh`, not via `resume-state.sh`. `resume-state.sh` seeds only
`autopilot_on` / `autopilot_bump` (plus the synthetic epoch from
`--accumulated`). MUST NOT seed caps from plan frontmatter. Pre-CDT-224 cards
(nested keys absent or null) resume as static M unless env. Mid-run env
mutation MUST NOT retune. Later gates copy the freeze (engine argc=4); Step 0
does not re-derive. MUST NOT export `AUTOPILOT_BUDGET_META` on `reroute-epic`
(child `/epic` or `/orchestrate` derives its own freeze).

Every later reference to `AUTOPILOT_ON` / `AUTOPILOT_BUMP` / `RUN_ID` /
`RUN_START_EPOCH` / `ITER` / `COUNCIL_TIER_OVERRIDE` / `ORCH_TIER` / `MAX_LOC`
below means these values, carried forward from this step.

---
