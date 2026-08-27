# SPEC-037: Per-agent Model map (phase 1)

**Status**: DRAFT
**Category**: core
**Created**: 2026-08-26
**Covers**: `skills/model-map/`, `skills/orchestrate/steps/04-kickoff.md`, `skills/orchestrate/steps/06-design.md`, `skills/orchestrate/steps/08-execute.md`, `skills/orchestrate/steps/09-review.md`, `skills/orchestrate/steps/10-qa.md`, `skills/code-simplify/SKILL.md`, `skills/ci-watch/SKILL.md`, `.gitignore`

## Overview

Phase 1 of the **Model map**: a local JSON file maps behavioral agents to host
model strings. A resolver CLI emits the string (or empty). `/orchestrate` spawn
sites pass a non-empty result as the Agent `model` param. Empty stdout means
**Tier default** (shipped `agents/*.md` frontmatter). Tiers stay the SoT for
role capability intent (SPEC-003). This version reads only the local file.
Repo and global layers, writers, `/doctor`, and direct `@agent` overlay are
out of scope.

## MUST

- **M1 — Path (AC1, AC2).** The Model map file MUST be exactly
  `$MROOT/.claude/dev-team/models.local.json`. `$MROOT` MUST be
  `git rev-parse --git-common-dir` then `dirname` (same rule as
  `worktree-lib.sh`). The resolver MUST NOT read a worktree copy, a plugin-cache
  copy, or any other path. Repo `.gitignore` MUST list
  `.claude/dev-team/models.local.json`. Plugin update MUST NOT write, delete, or
  relocate that file.

- **M2 — Schema.** The file MUST be JSON of the form
  `{ "version": 1, "agents": { "<name>": "<model-string>" } }`. Partial
  `agents` is fine. Missing or unknown `version` MUST be treated as `1`. Extra
  top-level keys MUST be ignored.

- **M3 — Zero-config (AC3).** If the file is absent, or equals
  `{"version":1,"agents":{}}` (empty object), the resolver MUST print empty
  stdout for every agent and MUST NOT warn.

- **M4 — Emit (AC4, AC5, AC7).** A listed `agents.<name>` value MUST be a
  non-empty string after trim. The resolver MUST print that trimmed string on
  stdout as-is. Any host-accepted string is legal (no allowlist). Omitted
  names MUST print empty stdout. Stdout MUST be the model string or empty, with
  at most one trailing newline. Warnings MUST go to stderr only.

- **M5 — CLI (AC6, AC8).** Callers MUST invoke
  `bash skills/model-map/resolve-model.sh <agent>` as a subprocess via
  `plugin-dir.sh file` (never `source`). Implementation is bash + `jq`. No
  build step. Exit `0` on missing file, empty map, bad config, unknown agent
  name, and ignored internal keys. Exit `64` only when the `<agent>` argument
  is missing or empty. Extra argv after `$1` MUST be ignored. Usage line on
  stderr: `usage: resolve-model.sh <agent>`.

- **M6 — Config-bad (AC10).** These cases MUST warn on stderr, print empty
  stdout, and exit `0` (never abort spawn): unparseable JSON; `agents` present
  but not an object; value null / non-string / empty-after-trim; `jq` absent.
  Locked stderr prefixes (path or name filled in):
  - `model-map: jq not found; using Tier default`
  - `model-map: unparseable JSON at <path>; using Tier default`
  - `model-map: agents is not an object; using Tier default`
  - `model-map: agents.<name> is not a non-empty string; using Tier default`

- **M7 — Unknown keys (AC11).** For every `agents` key that is not in the
  mappable set (M8), the resolver MUST warn
  `model-map: unknown agent key '<name>' ignored` on stderr and ignore that
  key. Other keys MUST still resolve.

- **M8 — Mappable set (AC12).** Exact lowercase names that MAY emit:
  `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`, `council-judge`.
  `resolve-model.sh distiller` and `resolve-model.sh project-init` MUST always
  print empty stdout. If those keys exist in the file, M7 still warns.
  An argv name outside M8 and those two internals is an unknown agent: empty
  stdout, exit `0`, stderr
  `model-map: unknown agent '<name>'; using Tier default`.

- **M9 — Adversarial (AC13).** A valid string for `qa` or `council-judge` MUST
  be emitted. The resolver MUST also warn
  `model-map: override for adversarial role '<name>' is allowed and may weaken the gate`.
  It MUST NOT block, drop, or substitute the Tier default.

- **M10 — Read-only (AC14).** The resolver MUST NOT create the file or any
  directory.

- **M11 — Phase-1 files (AC15).** The resolver MUST read only
  `models.local.json`. It MUST NOT read `$MROOT/.claude/dev-team/models.json`,
  `~/.claude/dev-team/models.json`, `DEVTEAM_MODEL_*`, or any other env.

- **M12 — Frontmatter (AC16–AC18).** All 10 `agents/*.md` `model:` lines MUST
  stay unchanged. SPEC-003 Tier defaults stay SoT. Direct `@agent` / chat stays
  on frontmatter. Phase 1 MUST NOT overlay or rewrite agent files.
  `council-judge` `tools: ""` MUST stay empty; mapping its model MUST NOT add
  tools.

- **M13 — Orchestrate wiring (AC19–AC21).** Before every named-roster Agent
  spawn listed below, the orchestrator MUST run the resolver for that agent
  (fresh shell; SPEC-002 PDH stanza verbatim; `plugin-dir.sh file`). If stdout
  is non-empty, pass it as the Agent `model` param. If empty, omit `model`
  (MUST NOT pass `""`). Surface resolver stderr to the user. Continue the
  pipeline. Sites:
  1. Step 4 light `@tech-lead`
  2. Step 4 standard `@pm` and `@tech-lead`
  3. Step 6 standard `@tech-lead`
  4. Step 8 light `@ic4`
  5. Step 8 standard `@<agent>` IC
  6. Step 9 `@tech-lead` review and IC rework (light single-pass included)
  7. Step 9.5 code-simplify (`ic4`) — `skills/code-simplify/SKILL.md` spawn
     template and the Step 9.5 pointer
  8. Step 10 standard `@qa`
  9. Step 8.5 / ci-watch fixer (`ic5`) — `skills/ci-watch/SKILL.md` cron
     spawn (`<PLUGIN>/skills/model-map/resolve-model.sh ic5`)
  Light paths that do not spawn (Step 6 second TL pass, Step 10 `@qa`,
  Step 9.5) are N/A. Unnamed / `general-purpose` (Step 4 light “or a general
  agent” when not `@tech-lead`) MUST omit the Model map (AC20).

- **M14 — Host-reject (AC22).** If Agent spawn fails and the failure is
  attributed to the model param (invalid / unknown / unsupported model), retry
  **once** with `model` omitted (Tier default) and warn
  `model-map: host rejected model '<string>' for <agent>; retrying with Tier default`.
  Other spawn failures MUST NOT be retried as a model fallback. MUST NOT probe
  the host for model validity. Precedent: SPEC-018 M3e host-reject → omit
  `model`. Whether Agent `model` overrides plugin-agent frontmatter is
  unverified; this retry is the fail-soft.

- **M15 — Static CI (AC23).** `skills/model-map/spawn-site-test.sh` MUST fail
  if any M13 site’s committed template/prose lacks `resolve-model.sh`.
  Pattern: `skills/handoff/spawn-model-ac-test.sh`.

- **M16 — Other surfaces (AC24).** `/kickoff`, `/epic`, `/debug`, and
  `/council` spawn templates MUST NOT gain Model map wiring this ticket.

- **M17 — Skill doc (AC25).** `skills/model-map/SKILL.md` MUST document path,
  schema, example JSON, empty = Tier default, warn-never-block for `qa` /
  `council-judge`, and phase-1 `/orchestrate`-only coverage. Prose MUST use
  **Model map** and **Tier default** (not “model config” / “hardcoded model”).
  YAML `name` + `description` required. MUST NOT mention `--help` (smoke
  FLAG_RE).

## MUST NOT

- MUST NOT absorb or alter `HANDOFF_MINER_MODEL` / CDT-203 miner aliases.
- MUST NOT absorb SPEC-019 opencode model selection or `install.sh --assign-models`.
- MUST NOT override distiller internals (`distill_model` / `agents/distiller.md`).
- MUST NOT add tools to `council-judge`.
- MUST NOT ship `/setup models`, `/adjust-agent` writers, or a `/doctor` check.
- MUST NOT implement repo or global layers in this version.

## SHOULD

- SHOULD keep resolver under 200 lines and `test.sh` under 400 lines.
- SHOULD treat a lone newline on empty stdout as equivalent to zero bytes
  (`$(...)` strips one trailing newline).

## Test

- [ ] File absent and empty `agents` object → empty stdout, no stderr, exit 0 (M3)
- [ ] Valid `agents.pm` string → trimmed stdout, exit 0 (M4)
- [ ] Partial map: listed agent emits; omitted agent empty (M4)
- [ ] Unparseable JSON, non-object `agents`, null/non-string/empty value, `jq`
      missing from PATH → empty stdout, matching M6 prefix, exit 0 (M6)
- [ ] Unknown key (typo) warns M7 and does not block other keys (M7)
- [ ] `distiller` / `project-init` argv always empty; key present still M7-warns (M8)
- [ ] `qa` valid string emits and prints M9 adversarial warning (M9)
- [ ] Sibling `models.json` and `DEVTEAM_MODEL_pm` ignored (M11)
- [ ] Worktree/subdir `.claude/dev-team/models.local.json` ignored when
      git-common-dir MROOT has a different file (M1)
- [ ] Missing argv → exit 64 + usage line (M5)
- [ ] Resolver does not create the file or parent dirs (M10)
- [ ] Stdout/stderr split: model never on stderr; warnings never on stdout (M4)
- [ ] `spawn-site-test.sh` greps `resolve-model.sh` at every M13 site (M15)
- [ ] `spawn-site-test.sh` greps host-reject retry prose at those sites (M14)
- [ ] Negative: `skills/kickoff/SKILL.md`, `skills/epic/SKILL.md`,
      `skills/debug/SKILL.md`, `commands/council.md` have no `resolve-model.sh` (M16)
- [ ] All 10 `agents/*.md` `model:` lines match SPEC-003 roster (M12)
- [ ] `bash skills/spec-tooling/check-format.sh specs/core/SPEC-037-per-agent-model-map.md` exits 0

## Validation

- [ ] Spec reviewed against CDT-222 ACs
- [ ] Bite-tests green without a live LLM
- [ ] `/orchestrate` spawn templates call the resolver

## Version History

| Date | Change |
|------|--------|
| 2026-08-26 | Initial DRAFT — CDT-222 phase 1 local Model map + resolver + `/orchestrate` wiring |

## Cross-references

- SPEC-003 — Tier default roster; shipped `model:` frontmatter
- SPEC-002 — `plugin-dir.sh` subprocess; PDH stanza; no-build
- SPEC-018 M3e — host-reject → omit `model` precedent (do not absorb miner aliases)
- SPEC-019 — opencode model selection; out of scope
- SPEC-013 — `council-judge` tool-less contract
- SPEC-007 — distiller `haiku` / `distill_model`; out of scope
- SPEC-021 — skill-bash lint (standalone `.sh` is outside fence scan)
- SPEC-030 — smoke picks up `test.sh` / `*-test.sh`
