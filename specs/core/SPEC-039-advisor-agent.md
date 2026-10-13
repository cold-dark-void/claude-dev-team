# SPEC-039: Advisor Agent

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-13
**Covers**: `agents/advisor.md`, `skills/advisor/` (`SKILL.md`, `ask.sh`, `parse-flags.sh`, `classify.sh`, `static-check.sh`, `test.sh`, `test-classify.sh`), `skills/agent-memory/advisor-protocol.md`, `skills/model-map/mappable-names.sh`, `skills/lib/require-agent.sh`, `.gitignore`, `AGENTS.md`, `README.md`, `docs/README.md`, `docs/runbooks/omp.md`, `commands/setup.md`, `commands/adjust-agent.md`

## Overview

The Advisor is an internal agent on a top-tier mapped model. The orchestrator
spawns it only through `skills/advisor/ask.sh` to check critical empirical
claims and council residue during unsupervised runs. It never ships or lands
code. Opt-in `--with-advisor` (default off) is byte-identical when absent.
This spec is the contract home. Roster category is SPEC-003. Blocking
conditions and decision-card envelope are SPEC-033. Model map is SPEC-037.

Glossary term: Advisor (`CONTEXT.md`).

## MUST

### Third roster category (AC4, AC6)

- **M1 — Category.** SPEC-003 MUST add a third roster category
  **advisory-internal** with exactly one member: `advisor`. Behavioral count
  stays 7. Non-behavioral count stays 6. Total agent files become 14.
  Advisory-internal MUST have tiered memory (SQLite `agent='advisor'` and
  fallback `.md`). It MUST NOT have directives, cortex, an `init-team`
  bootstrap cortex entry, or an `/adjust-agent` directives surface. It MUST
  NOT carry the 7-agent managed-inline `protocol.md` include (that block
  loads directives and cortex). `agents/advisor.md` MUST carry a managed
  include of `skills/agent-memory/advisor-protocol.md` (path resolution,
  tiered read without directives/cortex, append-only write, context.md).
- **M2 — Agent file.** `agents/advisor.md` MUST exist with YAML frontmatter
  `name`, `description`, `tools`, `model`, `effort`. Tier-table row (SPEC-003
  SoT): `advisor` / `opus` / `high` / `advisory-internal`. `mode: subagent`.
  Body MUST state: spawned only by the orchestrator through `ask.sh`; never
  routed directly; read-only; advisory-but-logged; findings via final-message
  hand-back.
- **M3 — Tools.** `tools:` MUST be exactly `Read, Grep, Glob, Bash`. MUST NOT
  include `Write`, `Edit`, or `SendMessage`. Finder/debugger keep
  `SendMessage`; advisor MUST NOT copy that list. Host-reject of an advisor
  spawn MUST NOT fall back to `ic5` (or any other roster agent).
- **M4 — Docs same patch.** `AGENTS.md` roster and `README.md` agents section
  (and `docs/README.md` internal-agent sentence) MUST list `advisor` in the
  same patch that adds `agents/advisor.md`. SPEC-003 MUST document the third
  category. This spec documents the role.

### Spawn seam (AC5, AC2, AC9)

- **M5 — Two-phase CLI.** `skills/advisor/ask.sh` is the only spawn seam.
  Only the orchestrator invokes it. Bash cannot call the Agent tool, so the
  seam is two-phase:
  1. `ask.sh probe` — acquire lock, check caps, check map, check cache,
     write spawn-request JSON, print `{action, model, spawn_request_path,
     cached_ruling_path, reason}` on stdout.
  2. Orchestrator-native Agent spawn when `action=spawn` (`subagent_type`
     `dev-team:advisor`, `model` = probe's mapped string, prompt from the
     spawn-request). Agent tool has no timeout param (SPEC-037 F1); the
     orchestrator owns the wall-clock cap.
  3. `ask.sh finalize` — record ruling or timeout/spawn-fail, write the
     decision-card, update caps/cache, release lock.
  `action` values: `spawn` | `cache-hit` | `refuse` | `cap`. Probe MUST NOT
  spawn.
- **M6 — Re-entrancy.** A nested `ask.sh probe` while this run holds
  `.claude/advisor/lock` MUST exit 64. Finalize always releases the lock.
- **M7 — Timeout.** Default wall-clock is 120 s (`ADVISOR_TIMEOUT_S`, integer
  seconds, only lowers). On timeout the orchestrator MUST call
  `ask.sh finalize --timeout` and MUST NOT pass a partial model transcript
  as a ruling.
- **M8 — Inert-if-unmapped.** Probe MUST call
  `resolve-model.sh --mapped advisor`. stdout `unmapped` → `action=refuse`,
  stderr `advisor not configured`, exit 0. MUST NOT spawn. MUST NOT treat
  empty `resolve-model.sh advisor` stdout as mapped (empty means Tier
  default for other agents; that path is forbidden here). MUST NOT retry
  onto frontmatter `model:`. MUST NOT pass an empty Agent `model` param.
  `resolve-model.sh --mapped` is new; default resolve behavior is unchanged.

### Flag (AC1, AC3, AC25)

- **M9 — Sibling parser.** `skills/advisor/parse-flags.sh` is a subprocess
  CLI. stdout one JSON object:
  `{"enabled":true|false,"source":"flag|env|none"}`.
  `--with-advisor` → enabled, source=flag. No flag and `ADVISOR` in
  `{1,true}` → enabled, source=env. Else disabled, source=none. Flag wins
  over env. Duplicate `--with-advisor` → exit 64. `--advisor` (omp host
  flag) MUST NOT enable this feature and MUST NOT exit 64. Default off.
  `skills/autopilot/parse-flags.sh` stays six-key. MUST NOT add a 7th key.
- **M10 — Surfaces.** `--with-advisor` is accepted on `/orchestrate`
  (including its autopilot mode) and `/review-and-commit`. Standalone
  `/kickoff`, `/debug`, `/bug-hunt` are out of this spec. When
  `/orchestrate --with-advisor` reroutes to `/epic`, epic state MUST persist
  `with_advisor: true` so children inherit env `ADVISOR=1`. Standalone
  `/epic` without the flag stays off.
- **M11 — Byte-identical off.** Flag absent and `ADVISOR` unset → no
  advisor spawn, no `ask.sh` invocation, no `actor:advisor` cards.
- **M12 — First card.** When enabled, the run's first decision-card MUST
  record enablement. Flag is primary. If source=env, rationale MUST mention
  `ADVISOR=1`.

### Trigger (b) — empirical claims (AC8, AC9, AC10, AC12)

- **M13 — Hook points (both).** The mechanical classifier MUST run at:
  1. **Wave-plan write** — after the plan file (`## Waves` / Task Map) is
     composed and before persist (`skills/orchestrate/steps/06-design.md`,
     `skills/orchestrate/steps/07-tasks.md`, and any mid-run rewrite of
     those sections). Kind `wave-plan`.
  2. **Disposition write** — before a ticket-state change whose action is
     `close` | `block` | `descope` | `reassign` (orchestrator disposition
     protocol, wrap-ticket close, Linear/backlog state change). Kind
     `disposition` with structured `--action`.
  Both points. Cache-hit on the same question hash is free (M26).
- **M14 — Classifier CLI.** `skills/advisor/classify.sh` is deterministic
  POSIX ERE, case-insensitive, never an LLM. stdout JSON array of hits
  `{trigger:"b", class, span, question_hash}`. Empty array = no fire.
- **M15 — Disposition class.** Fires only when `--action` is in
  `{close,block,descope,reassign}`. MUST NOT scan freeform prose for those
  verbs (false positives).
- **M16 — Identity-claim class.** Fires on kind `wave-plan` and
  `disposition` when the scanned text matches any of:
  1. `<subject> on this (machine|host|box) (is|is not|isn't|are|aren't) …`
  2. `<subject> (is|is not|isn't) (installed|present|available|missing|not installed)`
  3. `<subject> (is|is not|isn't) <ProperName>`
  `<subject>` MUST match `^[a-z][a-z0-9._+-]*$` or a path `^/[^[:space:]]+$`.
  `<ProperName>` MUST start with `[A-Z]`. This catches `omp is Open MPI`
  and misses `ic4 is the well-defined seat`.
- **M17 — Miss sampling.** Non-matching text is a silent skip. When a scan
  returns zero hits, hash the file; if `hash % 10 == 0`, append one
  `class=miss-sample` row to `.claude/advisor/runs/<run_id>/shadow.jsonl`
  and MUST NOT spawn. v1 accepts silent-skip of non-matches.
- **M18 — Evidence.** Probe/finalize pass evidence as directory paths, never
  pre-digested summaries. Ruling JSON:
  `{ruling: AGREE|CONTRADICT|INSUFFICIENT, confidence: 0-100,
  corrected_claim?: string, evidence: [{cmd, exit, sha256, locator}]}`.
  `locator` is `path:line`. Finalize rejects any other `ruling` value
  (exit 64).
- **M19 — Static checks first.** `skills/advisor/static-check.sh` MUST run
  before every trigger-(b) probe. It runs package queries (`pacman -Q*`,
  `command -v`), `file`, `strings`, and repo docs. Binary execution only
  where host safeguards allow (AGENTS.md machine-safeguard rules). Output
  lands in the evidence directory. Probe MUST NOT start if this step has
  not run for that question hash.

### Trigger (c) — council residue (AC13, AC14, AC15)

- **M20 — Council first.** Council always runs first. Advisor on residue
  only: below-threshold confidence, `CONTRADICTED`/`UNVERIFIED` splits, or
  degraded runs. A clean council pass MUST produce zero advisor calls.
  Hook: after `skills/council/engine-finalize.sh` / ship-gate-council
  produces the verdict, the orchestrator (including `/review-and-commit`)
  inspects residue and may `ask.sh probe --trigger c`.
- **M21 — Authority.** Advisor output for trigger (c) is `halt` (sustain)
  or `re-council` (request a fresh council pass with new tool evidence).
  `CONTRADICTED` → ship MUST go through a fresh council pass, never the
  advisor's word.
- **M22 — Label.** Advisor-gathered evidence files MUST be labelled
  `advisor-gathered` (filename prefix or JSON field) and stored outside
  the council bundle directory.

### Trigger (a) — restricted gates (AC16, AC17, AC18)

- **M23 — Never.** Advisor MUST NOT be invoked to answer BC3 (destructive),
  BC8 (product / unverified-external as a gate question), BC6-extension, or
  BC1-as-human-preference.
- **M24 — Allowed.** BC7 second opinion; BC2/BC6 diagnosis whose output is
  only `halt` or `decompose`; BC1 mis-fire detection (`halt-stands` |
  `mis-fire` + spec line), valid only when the deterministic checker
  agrees. BC2/BC6 diagnosis MUST NOT emit `proceed`.
- **M25 — Shadow.** First N runs (default N=5, `ADVISOR_SHADOW_N`, only
  lowers) log advisor rulings while the human decides. End-of-run report
  lists every gate the advisor answered. Widening past shadow is a human
  action after measured agreement ≥ 90% and zero
  proceed-where-human-halted. MUST NOT auto-widen.

### Caps (AC19)

- **M26 — Caps.** Per-run reserves: (a)=3, (b)=4, (c)=2. Global per-run
  total 5. `ADVISOR_MAX_CALLS` only lowers the global 5 (integer ≥ 1).
  Retries count. Dedupe by question hash (sha256 of trigger+normalized
  question+evidence hashes); cache hits are free and MUST NOT increment
  caps. Epic children own the same per-run caps. Epic total default 8
  (stored under `.claude/advisor/epic/<epic_id>/counters.json`). Cap
  exhaustion → `action=cap`, no spawn; under autopilot this is unavailable
  (M27).

### Unavailable and BC8 reuse (AC11)

- **M27 — Documented BC8 reuse.** SPEC-033 M6 has eight blocking
  conditions and MUST NOT gain a ninth. Under autopilot, advisor
  unavailable (unconfigured / timeout / spawn-fail / cap with no cache)
  MUST halt with `blocking_condition: 8`, `decision: halt`, marker exactly
  `advisor unavailable — fell back`. This is documented reuse of BC8
  (same class as M6.8: an external capability a confirmed AC depends on is
  unavailable), parallel to M14's documented reuse of BC7. Kickoff GATE 1
  semantics are unchanged. Interactive (autopilot off): continue with
  fallback, write the marker, do not halt. The
  `self-verified — refuters unavailable` contract is unchanged.

### Decision-card record (AC20)

- **M28 — Writer.** `ask.sh finalize` (not the model) writes the
  decision-card via `append-card.sh`. `actor` is `advisor`. Join via
  `run_id`. Closest canonical `gate` of the enclosing run. Standalone
  `/review-and-commit` mints `run_id` `review-<id>-<epoch>` and records
  `workflow: orchestrate`, `gate: ship-choice` (frozen 3-value workflow
  and gate enums; MUST NOT add a fourth).
- **M29 — Decision map.**
  - `AGREE` and confidence ≥ 80 → `decision: proceed`, `blocking_condition: null`
  - `CONTRADICT` or `INSUFFICIENT` → `decision: halt`, `blocking_condition: 7`
  - confidence < 80 → `decision: halt`, `blocking_condition: 7` regardless of ruling
  - unavailable (M27) → `decision: halt`, `blocking_condition: 8` (autopilot)
  `decided_by: auto`. `bump: null`. `confidence` is the ruling's 0–100.
- **M30 — Additive `advisor` object.** SPEC-033 M13 gains one additive
  nullable top-level key `advisor` (object or null). `schema_version` stays
  1. Absent key ≡ null. Top-level key count 18 → 19. `read-cards.sh` MUST
  backfill missing `advisor` as `null`. `append-card.sh` argc 13–16 stays
  valid; optional flag `--advisor-json PATH` sets the object. Shape:

  ```json
  {
    "ruling": "AGREE|CONTRADICT|INSUFFICIENT|null",
    "corrected_claim": null,
    "evidence": [{"cmd": "", "exit": 0, "sha256": "", "locator": ""}],
    "model": "",
    "evidence_over_memory": true,
    "question_hash": "",
    "trigger": "a|b|c",
    "cache_hit": false,
    "timeout": false,
    "marker": null
  }
  ```

  `model` is the spawned map-string. `evidence_over_memory` MUST be true
  whenever a tool result disagrees with a memory row. `rationale` stays a
  one-line ≤1000-char summary: `trigger=<a|b|c> ruling=<…> model=<…>`.
  Gate enum stays 3 values. Decision enum stays 6 values.

### Memory (AC21, AC22, AC23)

- **M31 — Persist.** Tool-backed facts only, with a re-verify predicate
  `{cmd, sha256, version, ts}`. Stale when `version` changes. A memory row
  without a reproducible evidence reference MAY suggest a check and MUST
  NOT serve as a ruling reason (`evidence_over_memory` enforces this).
- **M32 — Never persist.** Rulings-as-facts; gate waivers / "we proceeded";
  unverified issue/PR/council text; secrets; per-run state. User-overturned
  rulings MAY persist as a pattern (not as a fact that skips a check).
- **M33 — Roster wiring.** `require-agent.sh` keeps the 7-name default.
  `require-agent.sh --memory <name>` accepts the 7 plus `advisor`.
  memory-store, `/memory distill`, and `/doctor` MUST use `--memory` for
  advisor rows. `/doctor` MUST report advisor memory status (present /
  empty / n/a). `/adjust-agent` directives dashboard MUST NOT list
  `advisor`.

### State dir (AC24)

- **M34 — Layout.** `$MROOT/.claude/advisor/` (gitignored) holds:

  ```
  lock
  runs/<run_id>/counters.json
  runs/<run_id>/cache/<hash>.json
  runs/<run_id>/spawn-request.json
  runs/<run_id>/shadow.jsonl
  epic/<epic_id>/counters.json
  ```

  Decision-cards stay in `$MROOT/.claude/autopilot/<ticket_id>.jsonl`.
- **M35 — gitignore.** `.gitignore` MUST list `.claude/advisor/` in the
  same patch as the seam.

### Model map extract (AC2)

- **M36 — Mappable set.** `advisor` joins SPEC-037 M8. `distiller` and
  `project-init` stay always-empty. The 11-name set plus two internals
  MUST live in one helper `skills/model-map/mappable-names.sh`
  (`--is NAME` exit 0/1; `--list` one name per line; `--internal-empty`).
  `resolve-model.sh`, `write-model.sh`, and `skills/doctor/checks/models.sh`
  MUST call that helper. MUST NOT keep a third hand-copied case list.
  `spawn-site-test.sh` ROSTER gains `advisor:opus:high`.

### MUST NOT

- MUST NOT add a file under `commands/` (no `/advise` Surface).
- MUST NOT add a 7th key to `skills/autopilot/parse-flags.sh`.
- MUST NOT invent a ninth blocking condition.
- MUST NOT change the marker `self-verified — refuters unavailable`.
- MUST NOT spawn advisor when the flag is off and `ADVISOR` is unset.
- MUST NOT use Tier default or frontmatter retry when unmapped.
- MUST NOT fall back to `ic5` on advisor host-reject.
- MUST NOT let the advisor ship, land, Write, or Edit.
- MUST NOT pass evidence summaries in place of paths.

## SHOULD

- SHOULD keep miss-sample rate at 10% unless a later ticket measures recall.
- SHOULD print the end-of-run advisor gate list even when every ruling was
  a cache hit.
- SHOULD document the omp `--advisor` name collision in `README.md` and
  `docs/runbooks/omp.md` (AC25).

## Test

- `bash skills/advisor/test.sh` covers probe/finalize, caps, cache, timeout,
  unmapped refuse, flag parse, first-card enablement, ruling schema, BC7
  floor, BC8 unavailable marker, static-check-before-probe, trigger (c)
  residue skip on clean council, `advisor-gathered` label, trigger (a)
  denylist, shadow N default, gitignore line, CONTEXT.md Advisor row,
  README/AGENTS.md roster lines.
- `bash skills/advisor/test-classify.sh` covers disposition `--action`,
  identity-claim hits (`omp is Open MPI`, `omp on this machine is Open MPI`),
  misses (`ic4 is the well-defined seat`), and miss-sample modulo.
- `bash skills/model-map/spawn-site-test.sh` includes `advisor:opus:high`
  and tools exactly `Read, Grep, Glob, Bash`.
- `bash install-test.sh` strips `tools:` from `agents/advisor.md`.
- `bash skills/autopilot/test-card-validation.sh` accepts `--advisor-json`
  and backfills `advisor: null` on old cards.
- `bash skills/doctor/test.sh` reports advisor memory status.
- `bash skills/spec-tooling/check-format.sh specs/core/SPEC-039-advisor-agent.md`
  exits 0.
- Tests use `hermetic_init` and write only under `TMPDIR`.

## Validation

- Flag off produces zero `ask.sh` calls and zero `actor:advisor` cards
  (`skills/advisor/test.sh`).
- Unmapped advisor refuses with `advisor not configured` and does not spawn
  (`skills/advisor/test.sh`).
- Classifier is regex-only; a planted `omp is Open MPI` wave-plan hits;
  a planted `ic4 is the well-defined seat` misses
  (`skills/advisor/test-classify.sh`).
- Autopilot + unmapped + `--with-advisor` writes a halt card with
  `blocking_condition: 8` and marker `advisor unavailable — fell back`
  (`skills/advisor/test.sh`).
- `append-card.sh` 13-arg form still writes `advisor: null`
  (`skills/autopilot/test-card-validation.sh`).
- `/doctor` prints an advisor memory row (`skills/doctor/test.sh`).
- `install-test.sh` passes with `agents/advisor.md` present.

## Version History

| Date | Change |
|------|--------|
| 2026-10-13 | CDT-558: `### CDT-558` ACs for the agent file + `advisor-protocol.md` include (epic child C1). M4 roster-docs and the 14-file SPEC-003 count stay with CDT-562. |
| 2026-10-13 | Initial DRAFT (CDT-556). Third roster category; two-phase ask.sh; `--with-advisor`; triggers (b)/(c)/(a); BC8 reuse for unavailable; additive card key `advisor`. |

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h).

### CDT-556

- **AC1.** `--with-advisor` is accepted on `/orchestrate` (including autopilot) and `/review-and-commit`; default off; flag absent and `ADVISOR` unset produces zero advisor spawns, zero `ask.sh` calls, and zero `actor:advisor` cards.
  Verify: bash skills/advisor/test.sh
- **AC2.** Flag on and no `advisor` entry in any Model map layer (local > repo > global) makes `ask.sh probe` refuse with `advisor not configured`; the run continues the normal fallback; never Tier default; never frontmatter-model retry.
  Verify: bash skills/advisor/test.sh
- **AC3.** `ADVISOR=1` (env source) is recorded on the run's first decision-card; the flag remains primary.
  Verify: bash skills/advisor/test.sh
- **AC4.** `agents/advisor.md` exists; `tools:` is exactly `Read, Grep, Glob, Bash`; SPEC-003 lists the third roster category (advisory-internal, tiered memory, no directives, no cortex).
  Verify: bash skills/model-map/spawn-site-test.sh
- **AC5.** `skills/advisor/ask.sh` is the only spawn seam; only the orchestrator invokes it; re-entrant `probe` exits 64; timeout >120 s (or `ADVISOR_TIMEOUT_S`) returns fallback, not a partial ruling.
  Verify: bash skills/advisor/test.sh
- **AC6.** README and AGENTS.md rosters list `advisor` in the same patch; SPEC-003 documents the third category; this spec documents the role.
  Verify: bash skills/advisor/test.sh
- **AC7.** `install.sh` opencode transform strips `tools:` from `agents/advisor.md`; `install-test.sh` passes.
  Verify: bash install-test.sh
- **AC8.** Mechanical classifier fires at wave-plan write and at disposition write for (i) structured `--action` in close/block/descope/reassign and (ii) identity-claim regexes; it is deterministic and has no "feels unsure" branch.
  Verify: bash skills/advisor/test-classify.sh
- **AC9.** Evidence bundles are passed as paths, never summaries; ruling output is `{ruling: AGREE|CONTRADICT|INSUFFICIENT, confidence 0-100, corrected_claim?, evidence[]}`.
  Verify: bash skills/advisor/test.sh
- **AC10.** Confidence < 80 writes a BC7 halt card regardless of ruling direction.
  Verify: bash skills/advisor/test.sh
- **AC11.** Under autopilot, advisor unavailable (unconfigured/timeout/spawn-fail/cap) HALTs with a BC8 card and exact marker `advisor unavailable — fell back`; the `self-verified — refuters unavailable` contract is unchanged.
  Verify: bash skills/advisor/test.sh
- **AC12.** Static checks (package queries, `file`, `strings`, repo docs) run before any trigger-(b) advisor call; binary execution only where host safeguards allow.
  Verify: bash skills/advisor/test.sh
- **AC13.** Council always runs first; advisor runs only on residue (below-threshold, CONTRADICTED/UNVERIFIED splits, degraded runs); a clean pass produces zero advisor calls.
  Verify: bash skills/advisor/test.sh
- **AC14.** Trigger (c) authority is sustain-halt or request re-council with new tool evidence; CONTRADICTED→ship only via a fresh council pass.
  Verify: bash skills/advisor/test.sh
- **AC15.** Advisor-gathered evidence is labelled `advisor-gathered` and stored outside the council bundle.
  Verify: bash skills/advisor/test.sh
- **AC16.** Advisor is never invoked to answer BC3, BC8, BC6-extension, or BC1-as-human-preference; BC1 mis-fire detection is valid only if the deterministic checker agrees.
  Verify: bash skills/advisor/test.sh
- **AC17.** BC2/BC6 diagnosis output is restricted to halt or decompose.
  Verify: bash skills/advisor/test.sh
- **AC18.** Shadow mode defaults: first N=5 runs logged; agreement threshold 90%; zero proceed-where-human-halted; end-of-run report lists every gate the advisor answered.
  Verify: bash skills/advisor/test.sh
- **AC19.** Per-trigger reserves (a)=3, (b)=4, (c)=2; global 5; `ADVISOR_MAX_CALLS` only lowers; retries count; dedupe by question hash (cache hits free); epic children own caps plus epic total 8.
  Verify: bash skills/advisor/test.sh
- **AC20.** Every ruling is written by `ask.sh` (not the model) as a SPEC-033 decision-card with `actor: advisor`, joinable via `run_id`, carrying commands+exit codes+output hashes, path:line locators, spawned model string, and `evidence_over_memory`.
  Verify: bash skills/autopilot/test-card-validation.sh
- **AC21.** Persisted memory is tool-backed facts only WITH a re-verify predicate (command, output hash, version, timestamp; stale on version change); a memory entry without reproducible evidence can suggest a check but never serve as a ruling reason.
  Verify: bash skills/advisor/test.sh
- **AC22.** Never persisted: rulings-as-facts, gate waivers/"we proceeded", unverified issue/PR/council text, secrets, per-run state.
  Verify: bash skills/advisor/test.sh
- **AC23.** `require-agent.sh --memory`, memory-store, `/memory distill`, and `/doctor` handle the advisor category; `/doctor` reports advisor memory status.
  Verify: bash skills/doctor/test.sh
- **AC24.** `.claude/advisor/` is gitignored in the same patch as the seam.
  Verify: bash skills/advisor/test.sh
- **AC25.** omp host `--advisor` name collision is documented in README or `docs/runbooks/omp.md`.
  Verify: bash skills/advisor/test.sh
- **AC26.** Glossary term Advisor is present in CONTEXT.md.
  Verify: bash skills/advisor/test.sh
- **AC27.** Shadow mode has no auto-widen path: no skill writes a widen flag or sets shadow off; a test greps the advisor skill for auto-widen and expects zero hits.
  Verify: bash skills/advisor/test.sh
- **AC28.** [process] `bash tools/run-all-tests.sh` exits 0.

### CDT-558

- **AC1.** `agents/advisor.md` exists. YAML frontmatter has `name: advisor`, a `description`, `tools: Read, Grep, Glob, Bash` (that exact string; no `Write`, `Edit`, or `SendMessage`), `model: opus`, `effort: high`, and `mode: subagent`.
  Verify: bash skills/agent-memory/agent-blocks-test.sh
- **AC2.** `skills/agent-memory/advisor-protocol.md` exists as a managed partial. It is `protocol.md` minus the directives-load fence (no `directives.md` cat) and minus `cortex` from the fallback `for TYPE in ...` loop (`memory lessons` only). Fences keep the PDH stanza. `agents/advisor.md` carries `<!-- include: skills/agent-memory/advisor-protocol.md agent=advisor -->` and does not include `protocol.md`, `glossary-handback.md`, or `cortex-load.md`. `sync-includes.py check` exits 0 on that region (the suite invokes it).
  Verify: bash skills/agent-memory/agent-blocks-test.sh
- **AC3.** `agents/advisor.md` body states: spawned only by the orchestrator through `ask.sh`; never routed directly; read-only; advisory-but-logged; findings as your final message. Body restates no-mutating-Bash: do not run a `Bash` command that mutates state (no writes, no installs, no git commands that change refs or the working tree).
  Verify: bash skills/agent-memory/agent-blocks-test.sh
- **AC4.** `advisor` is absent from the `agents/project-init.md` cortex-bootstrap `for agent in pm tech-lead ic5 ic4 devops qa ds` list, from the `commands/adjust-agent.md` dashboard `for AGENT in pm tech-lead ic5 ic4 devops qa ds` list, and from `PIN_AGENTS` in `install.sh` and `uninstall.sh`. `agent-blocks-test.sh` `INTERNAL=` stays the six non-behavioral names; advisor is a separate ADVISORY check, not folded into `INTERNAL=`.
  Verify: bash skills/agent-memory/agent-blocks-test.sh
- **AC5.** `specs/OWNERS` has exactly one `agents/advisor.md` row; the owner is `SPEC-003`.
  Verify: bash skills/agent-memory/agent-blocks-test.sh
- **AC6.** `install.sh` `strip_frontmatter` drops the frontmatter `tools:` line from `agents/advisor.md`. `install-test.sh` has a case that generates the opencode copy of `agents/advisor.md` and asserts that copy's frontmatter has no `tools:` line.
  Verify: bash install-test.sh

## Alternatives considered

- **Spawn from bash via host CLI.** Rejected: host CLI is not portable across
  Claude Code / Grok / omp; Agent `model` param works (SPEC-037 F2) when the
  orchestrator spawns natively. Two-phase CLI is the portable seam.
- **Skill-protocol only (no CLI).** Rejected: caps, lock, and card writes
  must be deterministic and testable without an LLM.
- **Rationale-JSON for the ruling.** Rejected: `rationale` is one line ≤1000
  chars and cannot hold evidence hashes. Additive nullable `advisor` object
  follows the CDT-223/CDT-224 pattern (`schema_version` stays 1).
- **Map unavailable onto BC7.** Rejected: AC11 locks BC8; M14 already
  documents reuse of an existing BC. Unavailable is an external capability
  gap (BC8 class), not orchestrator self-uncertainty (BC7).
- **SendMessage on advisor tools (finder parity).** Rejected: AC4 locks the
  four-tool list; advisor has no named running teammate; hand-back is the
  final message.
- **7th parse-flags key.** Rejected: DRI locked six-key freeze; sibling
  parser owns `--with-advisor`.
- **Wave-plan-only or disposition-only classifier.** Rejected: the omp miss
  was a wave-plan identity claim that later became a disposition. Both
  hooks, with hash dedupe so a repeat is free.
- **Silent-skip with no miss sampling.** Rejected: zero recall signal.
  10% shadow sample of misses, no spawn.

## Open questions

- [x] Trigger-(b) hook point — **both** (M13).
- [x] Classifier-miss guard — silent-skip plus 10% shadow sample (M17).
- [x] Shadow N and widening — N=5, ≥90%, zero proceed-where-human-halted;
  no auto-widen path (M25, AC27); widening is a human action.
- [x] ask.sh architecture — two-phase probe / native spawn / finalize (M5).
- [x] Ruling record — additive `advisor` object, schema_version 1 (M30).
- [x] BC8 vs BC7 — documented BC8 reuse (M27).
- [x] SendMessage — omit (M3).
- [x] `.claude/advisor/` contents — M34; cards stay in `.claude/autopilot/`.
- [x] Bump class — patch (no new `commands/*.md`; opt-in flag default off).

## Cross-references

- SPEC-003: roster categories and tier table
- SPEC-004 / SPEC-006 / SPEC-007: memory write / read / distill
- SPEC-010: bump class (opt-in flag, no new Surface → patch)
- SPEC-013: council residue taxonomy
- SPEC-021: TMPDIR; PDH stanza in new fences
- SPEC-022: `/doctor` WARN-never-FAIL for `models.map`
- SPEC-025: epic children own caps
- SPEC-031: advisor is not an edit path
- SPEC-033: eight BCs, decision-card envelope, M14 BC-reuse precedent
- SPEC-037: Model map; `--mapped`; F1 no Agent timeout param; F2 model param works
