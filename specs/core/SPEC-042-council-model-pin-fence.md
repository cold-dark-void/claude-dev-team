# SPEC-042: Council model-pin fence

**Status**: DRAFT
**Category**: core
**Created**: 2026-11-18
**Covers**: `commands/council.md`, `skills/council/model-map.md`, `skills/council/phases-0-2.md`, `skills/council/phases-4-5.md`, `skills/council/phases-blind.md`, `skills/council/SKILL.md`, `skills/council/workflow.js`, `skills/council/test-workflow-static.sh`, `skills/council/test-workflow-f21.sh`, `skills/model-map/spawn-site-test.sh`, `skills/autopilot/ship-gate-council.md`, `skills/model-map/SKILL.md`, `skills/model-map/spawn-fence.md`, `specs/core/SPEC-037-per-agent-model-map.md` (amendments), `specs/core/SPEC-013-adversarial-council-tribunal.md` (§ Workflow execution path), `specs/core/SPEC-033-autopilot-policy.md` (§ M14 gate recipe)

## Overview

On the Grok host, `spawn_subagent` and Workflow `agent()` / `parallel()`
inherit the session model when no `model` is passed; the Model map
(SPEC-037) does not auto-apply to unnamed spawns. The CDT-632 M14 ship-gate
council ran 668 of 697 subagents (~96%) on opus because the covered spawn
sites omitted `model`. This spec fences the council tribunal and the
Workflow execution path: every covered spawn block carries an explicit
model pin. Mappable roles resolve through the Model map and never omit when
the map is empty — the role's SPEC-003 § Tier-default alias is passed
instead. Tool-less scribe-class roles pin the literal `sonnet` by policy
(maintainer ruling 2026-11-18). A model-attributed spawn failure retries
once with the sibling alias — never by omitting `model`. A fail-closed,
LLM-free lint asserts the fence on the committed text.

Two boundaries bound this spec. CDT-654 lands `council-scribe` joining the
mappable set (SPEC-037 M8) and converts the Workflow-path scribe sites to the
unified map fence; the P2 `sonnet` policy value survives as the fence floor
there and as the Task-path scribe literal. The plugin ships no scribe map key.
The never-omit host-reject rule covers council/workflow sites only; a
fleet-wide never-omit rule for non-council Grok-host spawns is future work.

## MUST

- **M1 — Covered Task-path sites (AC1).** Every covered Task-path spawn
  block carries an explicit model on every spawn. The covered set:
  Phase 1 extractor (claim/plan extraction, incl. the M14 per-AC split),
  Phase 2 investigators and the named fallback chain
  (`dev-team:ic5` → `general-purpose` → `"Explore"`), Phase 2.5
  cross-reviewers, Phase 3 classifier and specialist, Phase 4 prosecutor
  and Devil's Advocate, Phase 5 judge (including the bundle-cap judge
  parts), the `--blind` reviewer wave and its quorum analyst, and the
  `commands/council.md` mirrors of every stage fence. Home files:
  `commands/council.md`, `skills/council/model-map.md`,
  `skills/council/phases-0-2.md`, `skills/council/phases-4-5.md`,
  `skills/council/phases-blind.md`, `skills/council/SKILL.md`.

- **M2 — Pin classes (AC1).** Two pin classes cover every spawn in M1:
  - **P1 — map-resolved roles.** A mappable role (`finder`, `council-judge`,
    and the Phase 3 specialist's named roster `dev-team:<agent>`) resolves
    its model through `skills/model-map/resolve-model.sh` (SPEC-037 M5
    subprocess rule; SPEC-002 PDH stanza; never sourced) at spawn time.
    Non-empty stdout is passed as the `model` param. **Empty stdout is NOT
    omit at council sites**: the spawn passes the role's SPEC-003
    § Tier-default alias instead (sonnet-tier roles → `sonnet`,
    opus-tier roles → `opus`). MUST NOT pass `""`. This deliberately
    overrides the SPEC-037 M13/M16 omit path at council sites only; the
    M16/MUST-NOT amendments recording that override land in SPEC-037.
  - **P2 — scribe-class roles.** A tool-less `council-scribe`-class role
    (Phase 1 extractor, Phase 2.5 cross-reviewer, Phase 4 prosecutor/advocate,
    `--blind` reviewers and quorum analyst) pins the literal `sonnet` per the
    2026-11-18 maintainer ruling. On the Task path this stays a literal — no
    `resolve-model.sh` call at that spawn. As of CDT-654 `council-scribe` is
    mappable (SPEC-037 M8): the Workflow-path scribe sites resolve through the
    P1 fence, and this `sonnet` is their floor. The plugin ships no scribe
    `models.local.json` key.
  - **P1 fallback chain.** `dev-team:ic5` map-resolves `ic5` (empty stdout
    → `sonnet`, ic5's Tier alias). The unnamed `general-purpose` and
    `"Explore"` fallbacks have no Tier row and pin `sonnet` (P2 policy
    value). Every fallback spawn carries an explicit pin; the chain never
    falls back to an unpinned spawn.

- **M3 — Workflow path (AC2).** `skills/council/workflow.js` passes
  `model` at all five `safeAgent` sites (Extract, Investigate,
  Cross-review, Phase4, Judge) under the M2 policy: map-resolved roles
  (`dev-team:finder`, `dev-team:council-judge`) resolve through
  `resolve-model.sh` as a subprocess; scribe-class sites
  (`dev-team:council-scribe`) resolve through the same fence (CDT-654), with
  the P2 `sonnet` alias as the floor. On resolve failure (helper missing,
  non-zero exit, unparseable layer) the site passes the role's alias — the
  Tier-default for finder / council-judge, `sonnet` for council-scribe — never
  omits. The
  Workflow-path model value MUST equal the Task-path value for the same
  role and run (parity; SPEC-013 § Workflow execution path).

- **M4 — Host-reject sibling retry (AC4).** At every covered
  council/workflow site, a model-attributed spawn failure (invalid,
  unknown, or unsupported model) retries **once** with the sibling alias
  and warns exactly
  `model-map: host rejected model '<string>' for <agent>; retrying with sibling alias '<alias>'`.
  The sibling alias is the role's Tier-default alias for map-resolved
  roles and `sonnet` for pinned roles, chosen at pin time — never derived
  from the rejected string. **Pin==sibling carve-out:** a P2 pin whose
  value already equals its sibling alias (the scribe-class literal
  `sonnet`) performs no retry and no warn — the retry value equals the
  rejected value, so a second spawn is the same spawn. That site degrades
  per its existing failure path (Workflow path: `skills/council/workflow.js`
  degradation; Task path: the site's own spawn-failure handling). The retry
  MUST NOT omit `model` and MUST NOT be combinatorial. Ambiguous spawn
  failures still never retry as a model
  fallback (SPEC-013 § Spawn-failure degradation unchanged). This rewrites
  the "retry once with model omitted" prose at `commands/council.md` and
  `skills/council/model-map.md`; the non-council M13 ∪ M16 sites keep the
  SPEC-037 M14 omit path unchanged.

- **M5 — Gate recipe Phase-4 pin (AC3).** The M14 ship-gate recipe
  (`skills/autopilot/ship-gate-council.md` §3b) drives the council run
  whose Phase-4 prosecutor/advocate briefs are pinned at `sonnet` by
  default (maintainer ruling 2026-11-18). A per-gate escalation of the
  Phase-4 briefs back to `opus` is allowed: the recipe exports
  `COUNCIL_PHASE4_MODEL=opus` before the council dispatch. The value is a
  closed set (`sonnet`, `opus`); any other value MUST be ignored with one
  stderr warning and the default used. When the escalation is exercised,
  the gate record (the M14 decision card #2 the recipe appends) MUST name
  the escalation: the card rationale carries the token
  `phase4_model=opus`. `ship-gate-verdict.sh` stays byte-identical — the
  recipe composes the rationale, the mapper does not learn the token.
  Direct `/council` runs outside the gate recipe MUST NOT set the
  variable; their Phase-4 pin is always `sonnet`.

- **M6 — Fail-closed lint (AC5).** `skills/model-map/spawn-site-test.sh`
  gains a deterministic, LLM-free check that asserts every covered spawn
  block (M1 Task-path prose, `workflow.js` `agent()` entries, gate-recipe
  dispatch prose) carries an explicit model pin per M2. An unparseable or
  unrecognizable covered spawn block is a finding, not a pass
  (fail-closed). A `# lint-ok:` waiver at the finding line or on the line
  above waives it. The check MUST NOT reuse the reserved C7 id
  (SPEC-021); it reports under its own check name in the suite's output.
  A defect fixture bites; the clean tree passes. The suite already rides
  the SPEC-030 all-suites runner and `/release` Step 4 — no new lane.

- **M7 — Parity guard (AC8).** On Claude Code, passing the Tier-default
  alias explicitly MUST be behavior-equivalent to today's omit path
  (frontmatter `model:` matches SPEC-003; F2/F8). The suite asserts the
  alias values used at pin time equal the SPEC-003 § Tier table value for
  each mappable role, so the pin cannot drift from the tiers. The
  scribe-class policy pin (`sonnet`) is exempt from the Tier-table
  equality assertion: it deliberately differs from the
  `agents/council-scribe.md` frontmatter value (`opus`) and cites the
  maintainer ruling instead.

- **M8 — Boundary with CDT-654 (AC6).** CDT-641 owns: the explicit pins
  at all covered sites, the never-omit host-reject rewrite, the lint, and
  the Workflow-path seam that passes `model`. CDT-654 lands:
  `council-scribe` joining `skills/model-map/mappable-names.sh` (M8) with
  the SPEC-037 M8 amendment, dashboard listings, `resolve-model.sh`
  support (delegated to the helper, no literal name), and converting the
  Workflow-path scribe sites to the map fence. The join does NOT wire
  `--effort` on the Workflow path (SPEC-037 F1: no Agent `effort` param;
  workflow `opts.effort` untested — out of scope), which stays the CDT-641
  boundary.

## MUST NOT

- MUST NOT omit `model`, or pass `""`, at any covered council/workflow
  spawn site (M1–M3). The M13 ∪ M16 omit path stays valid only outside
  the covered set.
- MUST NOT derive the sibling alias from the rejected model string; the
  alias is chosen at pin time (M4).
- MUST NOT combinatorial-retry model and effort on an ambiguous failure,
  or retry any non-model-attributed spawn failure as a model fallback.
- MUST NOT probe the host for model validity beyond the single
  host-reject retry (M4).
- MUST NOT ship a Model map layer that carries a `council-scribe` key,
  hard-code a literal `council-scribe` name in `resolve-model.sh` (it delegates
  to `mappable-names.sh`), or write `models.local.json` from a dedicated scribe
  path (the scribe resolves through the map fence; M8; CDT-654).
- MUST NOT wire `--effort` on the Workflow path, or pass `effort` from
  `workflow.js` (M8; F1).
- MUST NOT wire `skills/fix-ticket/workflow.js` — the `/debug ticket`
  premise spawn is out of scope; it is a discovered follow-up ticket
  candidate (recorded in the CDT-641 plan). `.grok/workflows/*.rhai`
  files are untracked local run artifacts and out of scope.
- MUST NOT name the new lint check C7 (reserved, SPEC-021).
- MUST NOT fork a second Model map fence implementation into
  `workflow.js` — the Workflow path reuses the same resolver subprocess
  and the same alias policy (SPEC-013 single-source rule).
- MUST NOT let the new pins move a `skills/council/spawn-contract.md`
  line: the contract line keeps its placement (after the fleet
  instruction, before the per-spawn prompt blocks) at every fleet wave.

## SHOULD

- VOID (CDT-654): the single-site scribe constant is gone — the scribe
  sites take the model-map fence; the P2 sonnet value survives as the fence
  floor and the M4 sibling alias.
- SHOULD record the fleet-wide never-omit follow-up (non-council Grok-host
  spawns) and the `skills/fix-ticket/workflow.js` premise-spawn fence as
  backlog candidates in the CDT-641 plan — noted here as future work, not
  contracted here.

## Test

- `spawn-site-test.sh` asserts every covered Task-path spawn block carries
  an explicit model pin; a planted unpinned block bites (M1, M6)
- `spawn-site-test.sh` asserts an unparseable covered block is a finding,
  not a pass (fail-closed) (M6)
- `spawn-site-test.sh` asserts the `# lint-ok:` waiver grammar at the line
  or line above (M6)
- `spawn-site-test.sh` asserts the alias table equals the SPEC-003
  § Tier table for every mappable role, and that `council-scribe` is
  present in `mappable-names.sh --list` (M7, M8; CDT-654)
- `test-workflow-static.sh` asserts all five `safeAgent` sites pass
  `model`, the three scribe sites take `mapModel('council-scribe')` and the
  single-site `SCRIBE_MODEL_PIN` constant is absent (M3, M4; CDT-654), and
  the host-reject retry carries the sibling alias — never an omitted model
- `test-workflow-f21.sh` asserts the map-wins case for a scribe key
  (Extract carries the map value over the P2 sonnet floor) alongside the
  unmapped-floor and degrade cases (M3; CDT-654)
- `test-workflow-f21.sh` fake-runtime fixtures cover a model-attributed
  host-reject retry once with the sibling alias (M4), and the pin==sibling
  carve-out: a scribe-class `sonnet` reject retries nothing, warns nothing,
  and degrades (M4 carve-out)
- `skills/autopilot/test-contract-prose.sh` asserts the gate recipe's
  Phase-4 pin default and the escalation recording rule (M5)
- Host-reject prose at `commands/council.md` and
  `skills/council/model-map.md` names the sibling alias and no longer
  says "retrying with model omitted" at covered sites (M4)

## Validation

- Spec reviewed against the CDT-641 confirmed AC list (2026-11-18 PM
  scope review) and the CDT-654 boundary fold-in
- Bite-tests green without a live LLM
- Status promoted DRAFT → ACTIVE after the CDT-641 ship gate

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h).

### CDT-641

- **AC1.** Task-path council spawn sites carry an explicit model. Every
  covered Task-path spawn block — Phase 1 extractor, Phase 2
  investigators, Phase 2.5 cross-reviewers, Phase 3 specialist, Phase 4
  prosecutor/advocate, Phase 5 judge (incl. bundle-cap parts), the
  `--blind` waves, and the `commands/council.md` mirrors — passes an
  explicit `model` on every spawn: mappable roles resolve through
  `resolve-model.sh` (SPEC-002 PDH stanza, `plugin-dir.sh file`, never
  sourced); empty map stdout is NOT omit at council sites — the role's
  SPEC-003 Tier-default alias is passed instead, never `""`. This
  deliberately overrides SPEC-037 M13/M16's omit path at council sites
  only (M16/MUST-NOT amendments). Scribe-class roles pin the literal
  `sonnet` on the Task path per the 2026-11-18 maintainer ruling (the plugin
  ships no scribe map key). Fallback spawns in the Phase 2 chain
  (`dev-team:ic5` → `general-purpose` → `"Explore"`) each carry an
  explicit pin too.
  Verify: bash skills/model-map/spawn-site-test.sh
- **AC2.** Workflow path pins `model` on every `agent()`/`parallel()`
  entry: `skills/council/workflow.js` resolves and passes `model` at all
  five `safeAgent` sites under the AC1 policy, amending SPEC-037 M27 and
  SPEC-013 § Workflow execution path. As of CDT-654 the scribe-class sites
  resolve through the map fence (the P2 `sonnet` is their floor), the same
  fence the finder and council-judge sites use.
  Verify: bash skills/council/test-workflow-static.sh
- **AC3.** Gate recipe Phase-4 pin: the M14 ship-gate brief dispatch pins
  prosecutor/advocate at `sonnet` by default (maintainer ruling
  2026-11-18); a per-gate escalation back to `opus` is allowed and MUST
  be recorded in the gate record when exercised.
  Verify: bash skills/autopilot/test-contract-prose.sh
- **AC4.** Host-reject retry never omits: at every covered
  council/workflow site, a model-attributed spawn failure retries once
  with the sibling alias (Tier-default alias for map-resolved roles; the
  policy alias for pinned roles) and warns
  `model-map: host rejected model '<string>' for <agent>; retrying with sibling alias '<alias>'`
  — never by omitting `model`, never combinatorial. A P2 pin that already
  equals its sibling alias performs no retry and no warn; it degrades per
  the site's existing failure path (M4 carve-out). The "retry once with
  model omitted" prose in `commands/council.md` and
  `skills/council/model-map.md` is rewritten. Ambiguous failures still
  never retry as model fallback.
  Verify: bash skills/model-map/spawn-site-test.sh
- **AC5.** Fail-closed lint: a deterministic, LLM-free check asserts every
  covered spawn block (Task-path prose, `workflow.js` `agent()` entries,
  gate-recipe dispatches) carries an explicit model; an unparseable or
  unrecognizable spawn block is a finding, not a pass. Waivable via
  `# lint-ok:` at the line or line above. Runs in CI/`/release` pre-commit
  alongside the existing gates. Defect fixture bites; clean tree passes.
  Verify: bash skills/model-map/spawn-site-test.sh
- **AC6.** Boundary with CDT-654: CDT-641 owns the explicit pins at all
  covered sites (map-resolve for mappable names, literal `sonnet` for
  scribe-class), the never-omit host-reject rewrite, the lint, and the
  Workflow-path model seam. CDT-654 lands `council-scribe` joining
  `mappable-names.sh` (M8) with the SPEC-037 M8 amendment, dashboard
  listings, `resolve-model.sh` support, and converting the Workflow-path
  scribe sites to the map fence with the P2 `sonnet` as the floor.
  `council-scribe` is now in the mappable set; the Workflow path stays
  `--effort`-free and the plugin ships no scribe map key.
  Verify: bash skills/model-map/test.sh
- **AC7.** [process] Spec/doc coherence: SPEC-037 (M14 host-reject scope,
  M16 site list + omit list, M17 omit-list prose), SPEC-013 § Workflow
  execution path invariants, `skills/model-map/SKILL.md`,
  `skills/council/model-map.md`, and `docs/host-tool-map.md` are updated
  together in the CDT-641 change; the docs-drift gate stays clean; the
  SPEC-003 Tier table stays SoT for the alias values.
- **AC8.** Claude Code parity guard: on Claude Code, passing the
  Tier-default alias explicitly is behavior-equivalent to today's omit
  path (frontmatter `model:` matches SPEC-003); the suite asserts alias
  values equal the SPEC-003 § Tier table so the pin cannot drift from the
  tiers.
  Verify: bash skills/model-map/spawn-site-test.sh

## Version History

| Date | Change |
|------|--------|
| 2026-11-24 | CDT-654 — the CDT-654 boundary fold-in lands: `council-scribe` joins `mappable-names.sh` (M8, 12 names), the Workflow-path scribe sites convert to the map fence (P2 `sonnet` floor), and `resolve-model.sh` support is delegated to the helper. The Task-path scribe keeps the P2 literal; the plugin ships no scribe map key. Stays MUST NOT: a shipped scribe map key, a literal `council-scribe` in `resolve-model.sh`, and any `effort` on the Workflow path. Boundary intro, M2/M3/M8, the Test bullet, AC1/AC2/AC6, and the MUST NOT list amended. Status DRAFT. |
| 2026-11-18 | M4 pin==sibling carve-out (TL review): a P2 pin whose value already equals its sibling alias performs no retry and no warn, and degrades per the site's existing failure path. AC4 and the `test-workflow-f21.sh` Test bullet carry the same rule; AC7 guard-1 wording. Status DRAFT. |
| 2026-11-18 | Initial DRAFT — CDT-641: explicit model pins on every covered council/workflow spawn (map-resolve with Tier-alias floor for mappable roles, literal `sonnet` policy pin for scribe-class), never-omit sibling-alias host-reject retry, M14 gate Phase-4 pin + escalation recording, fail-closed spawn-site lint, CDT-654 boundary. Status DRAFT. |

## Cross-references

- SPEC-037 — Model map; M14/M16/M17/M27 amendments land there; Tier alias floor
- SPEC-013 — § Workflow execution path; § Spawn-failure degradation (unchanged)
- SPEC-003 — § Tier table is SoT for the mappable alias values
- SPEC-033 — M14 gate recipe; the gate record is decision card #2
- SPEC-021 — C7 id reserved; the new lint must not reuse it
- SPEC-002 — PDH stanza; `plugin-dir.sh file` subprocess rule
- CDT-654 — backlog item: `council-scribe` joins the mappable set; scribe-pin conversion
