# Run budget — per-model proposal

Carries AC12. Scope: phase 0 discovery of the control plane Option C+ (CDT-626). This file proposes. It ships no behavior.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Scale the run budget with the two existing SPEC-033 env caps only, chosen from the per-model proposal table below. Phase 0 adds no flag, no env name, no store, no precedence source, and no ceiling. |
| **Status** | Proposed, not implemented. Nothing in the plugin reads a per-model budget. SPEC-033 is the only budget policy in force. |
| **Date** | 2026-11-15 |
| **Sources** | `specs/core/SPEC-033-autopilot-policy.md` § AC3 (M9, M9a), § AC9 (M9b tier table, precedence, freeze, N12, N14), M6.6 (BC6); `specs/core/SPEC-037-per-agent-model-map.md` Overview, M8, M11, M12; `specs/core/SPEC-003-agent-role-system.md` § Tier table; `.claude/backlog.md:16` (CDT-610, verified PENDING 2026-11-15); `docs/internal/control-plane/index.md` § CDT-632 AC12. |
| **Phase effect** | Phase 0: proposal only, env-only scaling. Phase 1 (CDT-628): the SPEC-033 amendment that makes a Model-map budget layer real (OQ-6) — **landed by CDT-649** (§ Amendment). |
| **Residual items** | CDT-610 (BC6 wall-clock basis) still gates any wall-clock tuning; CDT-603 (Model map slug validation) owns the write-time slug check the match key fails safe without; `haiku` has no mappable agent. The aggregation rule and the ceiling scope are resolved (§ Amendment). |

## Policy owner

SPEC-033 § AC3 (M9) owns the run budget: the two caps, their defaults, their env overrides, the scope of a run, and the BC6 halt that a breach trips (SPEC-033 M6.6). This file cites that owner. It does not restate it. Read SPEC-033 § AC3 for the numbers in force. Every number below is a pointer into a SPEC-033 table, not a new measurement.

## What phase 0 proposes

- You scale a run with the existing env overrides only: `AUTOPILOT_ITERATION_CAP` and `AUTOPILOT_WALLCLOCK_CAP` (SPEC-033 § AC3).
- You pick the pair from the row of the table below that matches the model the run leans on. For a run that leans on the shipped default population, you export nothing — the static defaults already apply.
- The operator is the writer. SPEC-033 N12 forbids the engine from writing those two variables to apply auto-tune, and forbids a budget-cap flag or a seventh `parse-flags.sh` key. This proposal adds neither.
- SPEC-033 N14 forbids raising the auto-tune L ceiling above 40 / 4500 and forbids a `/setup` budget store. This proposal adds neither. That prohibition still bounds the landed map layer: no model-keyed row exceeds the L ceiling and no `/setup` budget store exists (§ Amendment).
- `AUTOPILOT_BUDGET_META` is the writer snapshot on decision cards (SPEC-033 § AC9, "Writer snapshot"). It is not an operator knob. Do not use it to set a budget.

## Resolution surface — the Model map

A per-model budget rides the Model map. The map is three JSON layers plus the Tier default (SPEC-037 M11, Overview):

| Layer | Path | Note |
|---|---|---|
| local | `$MROOT/.claude/dev-team/models.local.json` | gitignored (SPEC-037 M11 (1)) |
| repo | `$MROOT/.claude/dev-team/models.json` | committable; the plugin ships no default (SPEC-037 M11 (2)) |
| global | `~/.claude/dev-team/models.json` | `$HOME` (SPEC-037 M11 (3)) |
| **Tier default** | shipped `agents/<name>.md` frontmatter `model:` | SPEC-037 M12; values are the SPEC-003 § Tier table `Model` column |

Facts that bound the table:

- The match key is the resolved model string: `bash skills/model-map/resolve-model.sh <agent>` (SPEC-037).
- The map can carry only the 12 mappable names in `skills/model-map/mappable-names.sh` (SPEC-037 M8; `advisor` admitted under SPEC-039 M36, `council-scribe` under CDT-654). `distiller` and `project-init` always resolve empty (SPEC-037 M8).
- Empty stdout means Tier default (SPEC-037 Overview). The three shipped model tiers are the `Model` column values of the SPEC-003 § Tier table: `opus`, `sonnet`, `haiku`.

## Precedence

**env > map > tier**, per cap, independently. SPEC-033 § AC9 sets the per-cap rule for the budget ("Mixed = one cap from env and one from auto-tune"); this proposal keeps that shape for a third source.

1. **env** — `AUTOPILOT_ITERATION_CAP` / `AUTOPILOT_WALLCLOCK_CAP` when the variable is non-empty (SPEC-033 § AC3, § AC9).
2. **map** — the row of the table below for the resolved model string. Phase 0: advisory only, nothing read it. Phase 1 (CDT-628) implemented it behind the SPEC-033 amendment CDT-649 landed (§ Amendment): `control-plane/queue/` reads it as the per-model-endpoint slot cap.
3. **tier** — the **Tier default** row at the bottom of the table.

**Fallback rule:** a resolved model string that is not exactly `opus`, `sonnet`, or `haiku` has no row. The run takes the **Tier default** row. An empty resolution is the same case: no map file, an empty value, absent `jq`, or an always-empty internal name (`distiller`, `project-init`) all resolve to Tier default (SPEC-037 M6, M8, Overview).

Phase 0's position was **env > tier** (layer 2 advisory only). CDT-649 landed the amendment, so layer 2 is in force for the slot ledger: effective precedence is **env > map > tier** (§ Amendment).

## Per-model proposal table

Every cap cell is a verbatim cell from SPEC-033: the § AC3 M9 static defaults, or a row of the § AC9 M9b tier table (S = 10 / 1200, M = 25 / 2700, L = 40 / 4500).

| Model tier | Mappable agents (SPEC-037 M8) | Proposed `AUTOPILOT_ITERATION_CAP` | Proposed `AUTOPILOT_WALLCLOCK_CAP` | Source row | Status |
|---|---|---|---|---|---|
| `opus` | `tech-lead`, `pm`, `ds`, `council-judge`, `debugger`, `advisor` (6) | 10 stints | 2700 s | SPEC-033 § AC9 M9b **S** row (iteration), **M** row (wall-clock) | Phase-0 proposal, env-only. Mapping is an analogy, not a derivation — see § M9b boundary. Unmeasured → phase-1 input. |
| `sonnet` | `ic5`, `ic4`, `qa`, `devops`, `finder` (5) | 25 stints | 2700 s | SPEC-033 § AC3 M9 static defaults = § AC9 M9b **M** row | No change proposed. The AC3 rationale baseline is tuned against this population. |
| `haiku` | none — `distiller` only, and it always resolves empty (SPEC-037 M8) | no proposal | no proposal | no source row | Out of the map's reach in phase 0. `distiller` runs under `/memory distill` (SPEC-007), not as an autopilot stint. |
| **Tier default** (fallback) | all 12 mappable names whose resolution is empty, plus any string outside the three tokens above | 25 stints | 2700 s | SPEC-033 § AC3 M9 static defaults | Fallback rule (§ Precedence). |

`project-init` (`sonnet`, SPEC-003 § Tier table) is an always-empty internal (SPEC-037 M8), so it is not a map row. `sonnet` coverage above lists the mappable five.

**The open cell in this table.** A Run spans several agents, so it spans several resolved models. SPEC-033 caps are per run (§ AC3, "Scope of a run"). Phase 0 did not decide the aggregation rule (max, mode, weighted, per-spint); CDT-649 ruled it — a model-keyed cap binds per runner, not per Run (§ Amendment, input 4). The table stays a per-tier reading aid for the env pair; the runtime contract is the queue's slot ledger.

## M9b boundary

- SPEC-033 § AC9 (M9b) derives the S/M/L tier from three caller-supplied signals: `tasks`, `projected_loc`, `waves`. Auto-tune is **complexity-derived**, not model-derived.
- The resolved model is not one of those signals. `skills/autopilot/budget-check.sh derive` takes three argv signals and reads no map (SPEC-033 § AC9, "Helper argv").
- Nothing here changes that. This table is an operator-facing suggestion for the env pair. The auto-tuner never reads a model, in phase 0 or as proposed.
- The `opus` row borrows the S iteration cap because a run whose spawns are all `opus` runs few, deep stints. That is an analogy to the S row's meaning, not a derivation from it. Label: unmeasured, phase-1 input.
- `budget.tier` is not `--tier` and not `council_tier` (SPEC-033 § AC9).

## Per-run caps from the Chief

You can set both caps per run from the Chief, with the run options: the Advanced section of the new-run form carries `wallclock_cap` and `iteration_cap` (SPEC-046 M1), and chiefd puts them on that run's runner environment only (SPEC-046 M5). The env precedence above is unchanged — that per-run value is the env layer for that run.

## Open BC6 item

**CDT-610** — "BC6 wall-clock budget: exclude user wait, soft-pause ship step" — is PENDING at `.claude/backlog.md:16` (verified 2026-11-15).

Every wall-clock cell above is provisional while CDT-610 is open. It changes the basis of the wall-clock counter, which is the number this proposal scales. SPEC-033 § M9a already excludes human-approval wait from BC6 and defines the synthetic `run_start_epoch` on resume; CDT-610 generalises that to user wait and soft-pauses the ship step. Do not tune a per-model wall-clock before CDT-610 lands and is measured.

## Amendment — landed (CDT-649, phase 1)

The map layer needs a SPEC-033 amendment. Phase 0 recorded it as a phase-1 input (OQ-6) and forked no policy. Pointer: **CDT-628** (phase 1). Phase 0 changed no spec. Phase 1 (CDT-649) landed the amendment: the dated row in `specs/core/SPEC-033-autopilot-policy.md` § Version History (2026-11-17) carries the ruling, and the AC9 precedence chain gains the map layer between env and the static default. The five inputs, resolved:

1. **Precedence — landed.** The chain is **env > map > tier**, per cap, independently: the map row for the resolved model string is inserted between env and the static default (SPEC-033 § AC9; the AC9 numbered list carries the insert). Env still overrides everything; a frozen run keeps its frozen caps — the freeze is immutable mid-run; the map row applies where no freeze binds. The static M default stays the floor.
2. **The ceiling amendment scope — ruled.** N14's two clauses stay in force: a model-keyed budget row may not exceed the L ceiling (40 / 4500), so no clause is raised, and there is no `/setup` budget store — the Model map (SPEC-037 M11) is the store the budget reads. Env MAY exceed the ceiling, as SPEC-033 § AC9 already allows.
3. **N12 stays — ruled.** The engine never writes `AUTOPILOT_ITERATION_CAP` / `AUTOPILOT_WALLCLOCK_CAP` to apply a derived budget. The map layer is read-only: the reader is `control-plane/queue/` (the slot ledger), and the budget-check map read rides a later wiring child.
4. **The per-Run aggregation rule — ruled.** A model-keyed cap binds per runner, not per Run: a multi-agent Run holds one slot per runner; each runner's slot is counted against the model cap of that runner's resolved model; the Run's own concurrency setting caps the total. No runner waits on another runner's model cap. The Run's BC6 budget stays a per-Run number and the decision-card schema is unchanged.
5. **The match key — ruled.** The key is the resolved model string itself: a tier token (`opus`/`sonnet`/`haiku`, SPEC-037 M12) or a full vendor slug, compared byte-exact — never truncated, never prefix-matched, so a stale slug matches nothing rather than a family (the CDT-603 failure mode, applied to slots). An unnamed string takes the Tier default row (§ Precedence, "Fallback rule"). CDT-603 (validate slugs against the host spawn list) stays open and owns the write-time validation.

Implementation: `control-plane/queue/` (the slot ledger — one slot is one runner, one process or one container; the two caps enforced independently; overflow waits and shows as waiting; a kill-and-replay never grants a slot twice). The wall-clock basis question is unchanged: CDT-610 still gates any wall-clock tuning (§ "Open BC6 item"), and no wall-clock number is tuned by this amendment.

## Verification (AC12)

```bash
cd docs/internal/control-plane
grep -c 'SPEC-033 AC3\|§ AC3' run-budget.md          # AC3 cited as owner
grep -n 'CDT-610' run-budget.md                       # BC6 item named by id
grep -n 'CDT-628' run-budget.md                       # amendment pointer
grep -n 'env > map > tier' run-budget.md              # precedence
grep -n 'Tier default' run-budget.md                  # fallback row + rule
grep -c '^| `opus`\|^| `sonnet`\|^| `haiku`' run-budget.md                       # 3 shipped tiers
grep -c '^| \*\*Tier default\*\* (fallback)' run-budget.md                       # 1 fallback row
```
