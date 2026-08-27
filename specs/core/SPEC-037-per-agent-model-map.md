# SPEC-037: Per-agent Model map

**Status**: DRAFT
**Category**: core
**Created**: 2026-08-26
**Covers**: `skills/model-map/` (`resolve-model.sh`, `write-model.sh`, `test.sh`, `write-model-test.sh`, `spawn-site-test.sh`, `SKILL.md`), `commands/setup.md` (`/setup models`), `commands/adjust-agent.md` (`--model` / `--model-unset`), `skills/doctor/doctor.sh` (`models.map`), `skills/orchestrate/steps/04-kickoff.md`, `skills/orchestrate/steps/06-design.md`, `skills/orchestrate/steps/08-execute.md`, `skills/orchestrate/steps/09-review.md`, `skills/orchestrate/steps/10-qa.md`, `skills/code-simplify/SKILL.md`, `skills/ci-watch/SKILL.md`, `skills/kickoff/SKILL.md`, `skills/epic/SKILL.md`, `skills/debug/SKILL.md`, `skills/fix-ticket/SKILL.md`, `skills/council/SKILL.md`, `commands/council.md`, `skills/bug-hunt/SKILL.md`, `.gitignore`

## Overview

The **Model map** maps behavioral agents to host model strings across three
JSON layers (local, repo, global). A resolver CLI emits the string (or empty).
Named-roster Agent spawn sites (M13 `/orchestrate` plus M16 remaining
surfaces) pass a non-empty result as the Agent `model` param. Empty stdout
means **Tier default** (shipped `agents/*.md` frontmatter). Tiers stay the SoT
for role capability intent (SPEC-003). A local-only writer (`write-model.sh`)
backs `/setup models` and `/adjust-agent --model`. `/doctor` check `models.map`
is WARN-never-FAIL. Direct `@agent` overlay is out of scope (Option B).

## MUST

- **M1 — Path (AC1, AC2).** `$MROOT` MUST be `git rev-parse --git-common-dir`
  then `dirname` (same rule as `worktree-lib.sh`). The local layer MUST be
  `$MROOT/.claude/dev-team/models.local.json`. Repo `.gitignore` MUST list
  `.claude/dev-team/models.local.json` and MUST NOT list
  `.claude/dev-team/models.json`. Plugin update MUST NOT write, delete, or
  relocate those files. The resolver MUST NOT read a worktree copy or a
  plugin-cache copy. Layer files and precedence: M11.

- **M2 — Schema.** Each layer file MUST be JSON of the form
  `{ "version": 1, "agents": { "<name>": "<model-string>" } }`. Partial
  `agents` is fine. Missing or unknown `version` MUST be treated as `1`. Extra
  top-level keys MUST be ignored.

- **M3 — Zero-config (AC3).** If every layer is absent or has an empty
  `agents` object (`{"version":1,"agents":{}}`), the resolver MUST print empty
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

- **M6 — Config-bad (AC10).** These cases MUST warn on stderr and exit `0`
  (never abort spawn): unparseable JSON; `agents` present but not an object;
  value null / non-string / empty-after-trim; `jq` absent. Unparseable JSON
  or non-object `agents` MUST skip that layer and continue. A listed key with
  a bad value MUST fall through to the next layer (MUST NOT freeze the Tier
  default while a lower layer has a string). If no lower layer supplies a
  string, stdout is empty. `jq` absent: empty stdout; MUST NOT read any layer.
  Locked stderr prefixes (path or name filled in):
  - `model-map: jq not found; using Tier default`
  - `model-map: unparseable JSON at <path>; using Tier default`
  - `model-map: agents is not an object; using Tier default`
  - `model-map: agents.<name> is not a non-empty string; using Tier default`

- **M7 — Unknown keys (AC11).** For every `agents` key that is not in the
  mappable set (M8), the resolver MUST warn
  `model-map: unknown agent key '<name>' ignored` on stderr and ignore that
  key (per layer). Other keys MUST still resolve.

- **M8 — Mappable set (AC12).** Exact lowercase names that MAY emit:
  `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`, `council-judge`.
  `resolve-model.sh distiller` and `resolve-model.sh project-init` MUST always
  print empty stdout. If those keys exist in the file, M7 still warns.
  An argv name outside M8 and those two internals is an unknown agent: empty
  stdout, exit `0`, stderr
  `model-map: unknown agent '<name>'; using Tier default`.

- **M9 — Adversarial (AC13).** A valid string for `qa` or `council-judge` MUST
  be emitted. The resolver MUST also warn once
  `model-map: override for adversarial role '<name>' is allowed and may weaken the gate`.
  It MUST NOT block, drop, or substitute the Tier default.

- **M10 — Read-only (AC14).** The resolver MUST NOT create the file or any
  directory. MUST NOT mkdir or write.

- **M11 — Layers (AC15).** The resolver MUST read, in this order, at most
  these three files (same M2 schema). First hit wins per agent:
  1. local: `$MROOT/.claude/dev-team/models.local.json` (gitignored)
  2. repo: `$MROOT/.claude/dev-team/models.json` (committable; MUST NOT
     gitignore; the plugin MUST NOT ship a default)
  3. global: `~/.claude/dev-team/models.json` (`$HOME`)
  Absent file: skip that layer, MUST NOT warn. Unparseable JSON or `agents`
  present but not an object: M6 warn for that path, skip the layer, continue.
  Listed key with null / non-string / empty-after-trim: M6 warn, fall through
  to the next layer. Unknown keys: M7 warn per layer; other keys still
  resolve. Winning `qa` / `council-judge`: emit + M9 warn once. Internals
  argv (`distiller` / `project-init`): always empty (M8); those keys still
  M7-warn. MUST NOT read `DEVTEAM_MODEL_*` or any other env. MUST NOT mkdir
  or write (M10). `jq` absent: M6 warn, empty stdout, exit 0; MUST NOT read
  any layer.

- **M12 — Frontmatter (AC16–AC18).** All 10 `agents/*.md` `model:` lines MUST
  stay unchanged. SPEC-003 Tier defaults stay SoT. Direct `@agent` / chat stays
  on frontmatter. MUST NOT overlay or rewrite agent files.
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
  if any M13 ∪ M16 site’s committed template/prose lacks `resolve-model.sh`
  or M14 host-reject language (`retry once` and `host rejected`). Negatives:
  `commands/handoff.md` and `skills/handoff/` MUST NOT contain
  `resolve-model.sh`. Pattern: `skills/handoff/spawn-model-ac-test.sh`.

- **M16 — Remaining spawn surfaces (CDT-226).** Before every named-roster
  Agent spawn listed below, the orchestrator MUST run the resolver for that
  agent (fresh shell; SPEC-002 PDH stanza verbatim; `plugin-dir.sh file`;
  last fence line `printf '%s\n' "$MODEL"`). If stdout is non-empty, pass it
  as the Agent `model` param. If empty, omit `model` (MUST NOT pass `""`).
  Surface resolver stderr. M14 host-reject retry-once-omit applies. Resolve
  the agent actually spawned. Named fallback `ic5`→`ic4` resolves `ic4`.
  Unnamed / `general-purpose` / Explore MUST omit the fence. Sites:
  1. `/kickoff` (`skills/kickoff/SKILL.md`) — Step 2 `@pm`, Step 2
     `@tech-lead`, Step 3 feed-back `@pm`, Step 5 create-spec `@tech-lead`,
     Step 5 update-spec `@tech-lead`, Step 6 plan `@tech-lead`. MUST NOT
     fence Codebase Explorer or Step 4b verifier.
  2. `/epic` (`skills/epic/SKILL.md`) — A.2 `@pm` and `@tech-lead` only
     (Mode E `--redecompose` reuses A.2 fences). No ICs.
  3. `/debug ticket` (`skills/fix-ticket/SKILL.md`) — Step 3 premise `ic5`,
     Step 4 implement `--agent ic4|ic5`, Step 5 refuters `qa`.
     `skills/debug/SKILL.md` cites that contract. No `full` / `patch` /
     `arch` named-roster spawns.
  4. `/council` — Phase 2 investigators `ic5`, Phase 2.5 cross-reviewers
     `ic4`, Phase 5 `council-judge`. One Model map protocol section in
     `skills/council/SKILL.md`; `commands/council.md` points at it and
     contains one fence per role. Mapping `council-judge` MUST NOT add
     tools. MUST NOT wire Phase 1 extractor, Phase 3 specialist, Phase 4
     prosecutor/advocate, or `--blind` extra waves.
  5. `/bug-hunt` (`skills/bug-hunt/SKILL.md`) — S1 unconstrained / lens /
     quorum `ic5` and S2 investigators `ic5`.
  MUST NOT wire: `/handoff` miner (`HANDOFF_MINER_MODEL`), `/memory
  validate`, `/retro`.

- **M17 — Skill doc (AC25).** `skills/model-map/SKILL.md` MUST document the
  three layer paths and precedence (local → repo → global → Tier default),
  schema, example JSON, empty = Tier default, warn-never-block for `qa` /
  `council-judge`, named-roster spawn-surface coverage (M13 ∪ M16), and the
  omit list (explorer, Step 4b, unnamed / `general-purpose` / Explore,
  `/handoff` miner, `/memory validate`, `/retro`). Prose MUST use
  **Model map** and **Tier default** (not “model config” / “hardcoded model”).
  YAML `name` + `description` required. MUST NOT mention `--help` (smoke
  FLAG_RE). MUST document the local writer, `/setup models`, `/adjust-agent`
  `--model` sugar, and `/doctor` `models.map`.

- **M18 — Local writer (CDT-228).** `skills/model-map/write-model.sh` MUST be a
  subprocess CLI (never `source`). Commands: `list`, `set <agent> <string>`,
  `unset <agent>`. MUST write only `$MROOT/.claude/dev-team/models.local.json`
  (same MROOT as M1). MUST NOT write repo `models.json` or
  `~/.claude/dev-team/models.json`. `list` MUST print the 8 M8 names with the
  winning resolved string (MUST call `resolve-model.sh`; MUST NOT reimplement
  merge) or `Tier default` when empty, plus the local path. `list` is
  read-only (MUST NOT mkdir or write). `set` MUST merge
  `{version:1, agents:{...}}`, create parent dirs, and trim the string. Empty
  after trim or unknown agent (not in M8) → exit 64 + usage. `qa` /
  `council-judge` allowed + M9 warn on stderr. `unset` deletes that key;
  missing key OK (exit 0); unknown agent → 64. Unparseable existing local
  file: refuse to write, warn, exit 1. Extra argv after required args
  ignored. Bad argv → 64 + usage. `jq` required for set/unset (missing →
  warn, exit 1); list MAY still call resolve. Tests:
  `skills/model-map/write-model-test.sh`.

- **M19 — Doctor `models.map` (CDT-228).** `/doctor` MUST register check id
  `models.map`, group `config`. No map files at any of the three M11 paths →
  SKIP. All present files valid JSON + `agents` object + values non-empty
  strings + keys known → PASS. Unparseable / `agents` not object / bad value
  / unknown key / `jq` missing → WARN (never FAIL). `qa` or `council-judge`
  override present → WARN (M9 text). `--fix` MUST NOT rewrite the map (not
  on the allowlist). WARN MUST NOT block `/setup team` (doctor exit 1, not
  2).

- **M20 — `/setup models` (CDT-228).** `/setup` MUST dispatch sub `models`.
  Bare `/setup models` → `write-model.sh list`. `set` / `unset` pass through.
  Unknown `/setup` sub still prints usage and MUST NOT mutate; `models` is a
  known sub. MUST NOT hard-gate on doctor. Usage and routing table MUST list
  `models`. Command markdown MUST call `write-model.sh` via `plugin-dir.sh
  file` (MUST NOT inline JSON writes).

- **M21 — `/adjust-agent` model sugar (CDT-228).**
  `/adjust-agent <agent> --model <string>` → `write-model.sh set`.
  `/adjust-agent <agent> --model-unset` → `write-model.sh unset`. Parse these
  flags BEFORE treating remainder as a directives prompt. MUST NOT mix into
  Step 5 conversational directives. `council-judge` is mappable (M8) even
  though it is not in the 7-agent dashboard roster.

## MUST NOT

- MUST NOT absorb or alter `HANDOFF_MINER_MODEL` / CDT-203 miner aliases.
- MUST NOT absorb SPEC-019 opencode model selection or `install.sh --assign-models`.
- MUST NOT override distiller internals (`distill_model` / `agents/distiller.md`).
- MUST NOT add tools to `council-judge`.
- MUST NOT write repo or global Model map files from `write-model.sh`.
- MUST NOT overlay or rewrite `agents/*.md` (Option B).
- MUST NOT read `DEVTEAM_MODEL_*`.
- MUST NOT FAIL `/doctor` `models.map` (WARN or SKIP only).

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
- [ ] Local beats repo beats global for the same agent (M11)
- [ ] Partial maps compose across layers (M11)
- [ ] Bad local value (null/empty) + good repo → repo string + M6 warn (M11)
- [ ] Unparseable local + good repo → repo string + unparseable warn (M11)
- [ ] Absent local, present repo → repo (M11)
- [ ] All layers absent → empty, no warn (M3)
- [ ] Local + repo `models.json` at MROOT → local wins; `DEVTEAM_MODEL_pm`
      ignored (M11)
- [ ] Worktree/subdir `.claude/dev-team/models.local.json` ignored when
      git-common-dir MROOT has a different file (M1)
- [ ] Missing argv → exit 64 + usage line (M5)
- [ ] Resolver does not create the file or parent dirs (M10)
- [ ] Stdout/stderr split: model never on stderr; warnings never on stdout (M4)
- [ ] `spawn-site-test.sh` greps `resolve-model.sh` at every M13 ∪ M16 site (M15)
- [ ] `spawn-site-test.sh` greps host-reject retry prose at those sites (M14)
- [ ] Positive M16 sites: `skills/kickoff/SKILL.md`, `skills/epic/SKILL.md`,
      `skills/debug/SKILL.md`, `skills/fix-ticket/SKILL.md`,
      `skills/council/SKILL.md`, `commands/council.md`,
      `skills/bug-hunt/SKILL.md` contain `resolve-model.sh` (M16)
- [ ] Negative: `commands/handoff.md` and `skills/handoff/` have no
      `resolve-model.sh` (M16)
- [ ] All 10 `agents/*.md` `model:` lines match SPEC-003 roster (M12)
- [ ] `bash skills/spec-tooling/check-format.sh specs/core/SPEC-037-per-agent-model-map.md` exits 0
- [ ] `write-model.sh set` writes only local `models.local.json`; repo/global unchanged (M18)
- [ ] `write-model.sh list` prints 8 M8 names + local path; empty resolve → `Tier default` (M18)
- [ ] `write-model.sh list` calls `resolve-model.sh` (repo string wins when local omits) (M18)
- [ ] Unknown agent / empty string / bad argv → exit 64 + usage; extra argv ignored (M18)
- [ ] Unparseable existing local → set/unset refuse, exit 1, file unchanged (M18)
- [ ] `qa` / `council-judge` set emits M9 warn and writes (M18)
- [ ] `/setup` usage lists `models`; unknown sub still MUST NOT mutate (M20)
- [ ] `/adjust-agent` documents `--model` / `--model-unset` before Step 5 (M21)
- [ ] `/doctor --only models.map`: no files SKIP; valid PASS; unparseable/unknown/bad/jq-missing/M9 WARN; never FAIL (M19)
- [ ] `/doctor --fix` does not rewrite the map (M19)
- [ ] `spawn-site-test.sh` still forbids production `.sh` redirect onto `models.local.json` except `write-model.sh` (M18)

## Validation

- [ ] Spec reviewed against CDT-222 + CDT-226 + CDT-227 + CDT-228 ACs
- [ ] Bite-tests green without a live LLM
- [ ] `/orchestrate` and remaining named-roster spawn templates call the resolver
- [ ] Status stays DRAFT (do not silently ACTIVE)

## Version History

| Date | Change |
|------|--------|
| 2026-08-26 | CDT-228 — retitle Per-agent Model map; M18 local writer; M19 doctor `models.map` WARN-never-FAIL; M20 `/setup models`; M21 `/adjust-agent --model` sugar. Status stays DRAFT. |
| 2026-08-26 | CDT-227 — M11 three-layer merge (local → repo → global); bad-value fallthrough; DEVTEAM_MODEL_* still ignored |
| 2026-08-26 | CDT-226 — M16 remaining named-roster spawn surfaces; M15 covers M13 ∪ M16; M17 not orchestrate-only |
| 2026-08-26 | Initial DRAFT — CDT-222 phase 1 local Model map + resolver + `/orchestrate` wiring |

## Cross-references

- SPEC-003 — Tier default roster; shipped `model:` frontmatter
- SPEC-002 — `plugin-dir.sh` subprocess; PDH stanza; no-build
- SPEC-018 M3e — host-reject → omit `model` precedent (do not absorb miner aliases)
- SPEC-019 — opencode model selection; out of scope
- SPEC-013 — `council-judge` tool-less contract
- SPEC-007 — distiller `haiku` / `distill_model`; out of scope
- SPEC-005 — `/setup models` dispatch
- SPEC-022 — `/doctor` `models.map` (WARN-never-FAIL)
- SPEC-001 — `/adjust-agent` directives; `--model` is not a directives conversation
- SPEC-021 — skill-bash lint (standalone `.sh` is outside fence scan)
- SPEC-030 — smoke picks up `test.sh` / `*-test.sh`
