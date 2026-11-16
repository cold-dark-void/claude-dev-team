# Run budget — per-model proposal

Carries AC12. Scope: phase 0 discovery of the control plane Option C+ (CDT-626). This file proposes. It ships no behavior.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Scale the run budget with the two existing SPEC-033 env caps only, chosen from the per-model proposal table below. Phase 0 adds no flag, no env name, no store, no precedence source, and no ceiling. |
| **Status** | Proposed, not implemented. Nothing in the plugin reads a per-model budget. SPEC-033 is the only budget policy in force. |
| **Date** | 2026-11-15 |
| **Sources** | `specs/core/SPEC-033-autopilot-policy.md` § AC3 (M9, M9a), § AC9 (M9b tier table, precedence, freeze, N12, N14), M6.6 (BC6); `specs/core/SPEC-037-per-agent-model-map.md` Overview, M8, M11, M12; `specs/core/SPEC-003-agent-role-system.md` § Tier table; `.claude/backlog.md:16` (CDT-610, verified PENDING 2026-11-15); `docs/internal/control-plane/index.md` § CDT-632 AC12. |
| **Phase effect** | Phase 0: proposal only, env-only scaling. Phase 1 (CDT-628): the SPEC-033 amendment that makes a Model-map budget layer real (OQ-6). |
| **Residual items** | Run-level aggregation rule for a model-keyed cap (open); the ceiling amendment; CDT-610 (BC6 wall-clock basis); CDT-603 (Model map slug validation) affects the table's match key; `haiku` has no mappable agent. |

## Policy owner

SPEC-033 § AC3 (M9) owns the run budget: the two caps, their defaults, their env overrides, the scope of a run, and the BC6 halt that a breach trips (SPEC-033 M6.6). This file cites that owner. It does not restate it. Read SPEC-033 § AC3 for the numbers in force. Every number below is a pointer into a SPEC-033 table, not a new measurement.

## What phase 0 proposes

- You scale a run with the existing env overrides only: `AUTOPILOT_ITERATION_CAP` and `AUTOPILOT_WALLCLOCK_CAP` (SPEC-033 § AC3).
- You pick the pair from the row of the table below that matches the model the run leans on. For a run that leans on the shipped default population, you export nothing — the static defaults already apply.
- The operator is the writer. SPEC-033 N12 forbids the engine from writing those two variables to apply auto-tune, and forbids a budget-cap flag or a seventh `parse-flags.sh` key. This proposal adds neither.
- SPEC-033 N14 forbids raising the auto-tune L ceiling above 40 / 4500 and forbids a `/setup` budget store. This proposal adds neither. That prohibition is the reason the map layer below is a proposal and not a feature (see § Deferral).
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
- The map can carry only the 11 mappable names in `skills/model-map/mappable-names.sh` (SPEC-037 M8, admitted `advisor` under SPEC-039 M36). `distiller` and `project-init` always resolve empty (SPEC-037 M8).
- Empty stdout means Tier default (SPEC-037 Overview). The three shipped model tiers are the `Model` column values of the SPEC-003 § Tier table: `opus`, `sonnet`, `haiku`.

## Precedence

**env > map > tier**, per cap, independently. SPEC-033 § AC9 sets the per-cap rule for the budget ("Mixed = one cap from env and one from auto-tune"); this proposal keeps that shape for a third source.

1. **env** — `AUTOPILOT_ITERATION_CAP` / `AUTOPILOT_WALLCLOCK_CAP` when the variable is non-empty (SPEC-033 § AC3, § AC9).
2. **map** — the row of the table below for the resolved model string. Phase 0: advisory only, nothing reads it. Phase 1 (CDT-628) implements it behind a SPEC-033 amendment.
3. **tier** — the **Tier default** row at the bottom of the table.

**Fallback rule:** a resolved model string that is not exactly `opus`, `sonnet`, or `haiku` has no row. The run takes the **Tier default** row. An empty resolution is the same case: no map file, an empty value, absent `jq`, or an always-empty internal name (`distiller`, `project-init`) all resolve to Tier default (SPEC-037 M6, M8, Overview).

In force today, layer 2 does not exist, so effective precedence is **env > tier**. That is the phase-0 position: propose env-only scaling, fork no policy.

## Per-model proposal table

Every cap cell is a verbatim cell from SPEC-033: the § AC3 M9 static defaults, or a row of the § AC9 M9b tier table (S = 10 / 1200, M = 25 / 2700, L = 40 / 4500).

| Model tier | Mappable agents (SPEC-037 M8) | Proposed `AUTOPILOT_ITERATION_CAP` | Proposed `AUTOPILOT_WALLCLOCK_CAP` | Source row | Status |
|---|---|---|---|---|---|
| `opus` | `tech-lead`, `pm`, `ds`, `council-judge`, `debugger`, `advisor` (6) | 10 stints | 2700 s | SPEC-033 § AC9 M9b **S** row (iteration), **M** row (wall-clock) | Phase-0 proposal, env-only. Mapping is an analogy, not a derivation — see § M9b boundary. Unmeasured → phase-1 input. |
| `sonnet` | `ic5`, `ic4`, `qa`, `devops`, `finder` (5) | 25 stints | 2700 s | SPEC-033 § AC3 M9 static defaults = § AC9 M9b **M** row | No change proposed. The AC3 rationale baseline is tuned against this population. |
| `haiku` | none — `distiller` only, and it always resolves empty (SPEC-037 M8) | no proposal | no proposal | no source row | Out of the map's reach in phase 0. `distiller` runs under `/memory distill` (SPEC-007), not as an autopilot stint. |
| **Tier default** (fallback) | all 11 mappable names whose resolution is empty, plus any string outside the three tokens above | 25 stints | 2700 s | SPEC-033 § AC3 M9 static defaults | Fallback rule (§ Precedence). |

`project-init` (`sonnet`, SPEC-003 § Tier table) is an always-empty internal (SPEC-037 M8), so it is not a map row. `sonnet` coverage above lists the mappable five.

**The open cell in this table.** A Run spans several agents, so it spans several resolved models. SPEC-033 caps are per run (§ AC3, "Scope of a run"). Phase 0 does not decide the aggregation rule (max, mode, weighted, per-spint). Recorded as a phase-1 input for CDT-628 (§ Residual items). Until it is decided, the table is a per-tier reading aid for the env pair, not a runtime contract.

## M9b boundary

- SPEC-033 § AC9 (M9b) derives the S/M/L tier from three caller-supplied signals: `tasks`, `projected_loc`, `waves`. Auto-tune is **complexity-derived**, not model-derived.
- The resolved model is not one of those signals. `skills/autopilot/budget-check.sh derive` takes three argv signals and reads no map (SPEC-033 § AC9, "Helper argv").
- Nothing here changes that. This table is an operator-facing suggestion for the env pair. The auto-tuner never reads a model, in phase 0 or as proposed.
- The `opus` row borrows the S iteration cap because a run whose spawns are all `opus` runs few, deep stints. That is an analogy to the S row's meaning, not a derivation from it. Label: unmeasured, phase-1 input.
- `budget.tier` is not `--tier` and not `council_tier` (SPEC-033 § AC9).

## Open BC6 item

**CDT-610** — "BC6 wall-clock budget: exclude user wait, soft-pause ship step" — is PENDING at `.claude/backlog.md:16` (verified 2026-11-15).

Every wall-clock cell above is provisional while CDT-610 is open. It changes the basis of the wall-clock counter, which is the number this proposal scales. SPEC-033 § M9a already excludes human-approval wait from BC6 and defines the synthetic `run_start_epoch` on resume; CDT-610 generalises that to user wait and soft-pauses the ship step. Do not tune a per-model wall-clock before CDT-610 lands and is measured.

## Deferral — the SPEC-033 amendment (phase 1: CDT-628)

The map layer needs a SPEC-033 amendment. Phase 0 records it as a phase-1 input (OQ-6) and forks no policy. Pointer: **CDT-628** (phase 1). This ticket changes no spec.

Inputs the amendment must carry:

1. **Precedence.** Insert a map source between env and the static default. Today: env > auto-tune > static M (SPEC-033 § AC9).
2. **The ceiling amendment.** N14 forbids raising the auto-tune L ceiling above 40 / 4500 and forbids a `/setup` budget store. A model-keyed budget that exceeds L needs both clauses amended. This is the ceiling amendment; it is a phase-1 input, not a phase-0 change.
3. **N12 stays.** The engine must never write the env caps to apply a derived budget.
4. **The aggregation rule** for a model-keyed cap on a multi-agent Run (open question above).
5. **The match key** must survive full vendor model slugs, not only the three tier tokens. CDT-603 ("Model map: validate slugs against the host spawn list", PENDING) is the related open item.

## Verification (AC12)

```bash
cd docs/internal/control-plane
grep -c 'SPEC-033 AC3\|§ AC3' run-budget.md          # AC3 cited as owner
grep -n 'CDT-610' run-budget.md                       # BC6 item named by id
grep -n 'CDT-628' run-budget.md                       # deferral pointer
grep -n 'env > map > tier' run-budget.md              # precedence
grep -n 'Tier default' run-budget.md                  # fallback row + rule
grep -c '^| `opus`\|^| `sonnet`\|^| `haiku`' run-budget.md                       # 3 shipped tiers
grep -c '^| \*\*Tier default\*\* (fallback)' run-budget.md                       # 1 fallback row
```
