# SPEC-039: Advisor Agent

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-13
**Covers**: `agents/advisor.md`, `skills/advisor/` (`SKILL.md`, `ask.sh`, `parse-flags.sh`, `classify.sh`, `gates.sh`, `residue.sh`, `appeal.sh`, `static-check.sh`, `test.sh`, `test-classify.sh`, `test-gates.sh`, `test-residue.sh`), `skills/agent-memory/advisor-protocol.md`, `skills/model-map/mappable-names.sh`, `skills/lib/require-agent.sh`, `.gitignore`, `AGENTS.md`, `README.md`, `docs/README.md`, `docs/runbooks/omp.md`, `commands/setup.md`, `commands/adjust-agent.md` <!-- drift-ok: skill-ref --> (skills/advisor/* and mappable-names.sh ship with later SPEC-039 children)

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
  The one exception is an explicit M37 model override: it replaces the mapped
  choice, and enables the probe when unmapped, by design.

### Flag (AC1, AC3, AC25)

- **M9 — Sibling parser.** `skills/advisor/parse-flags.sh` is a subprocess
  CLI. stdout one JSON object:
  `{"enabled":true|false,"source":"flag|env|none"}`, plus an optional
  `"model":"<model>"` key when M37 resolves an override.
  `--with-advisor` → enabled, source=flag. `--with-advisor=<model>` →
  enabled, source=flag, model=<model>. No flag and `ADVISOR` in
  `{1,true}` → enabled, source=env. Else disabled, source=none. Flag wins
  over env. Duplicate `--with-advisor` or `--with-advisor=*` → exit 64.
  An empty model or one carrying whitespace/control characters → exit 64.
  `--advisor` (omp host flag) MUST NOT enable this feature and MUST NOT
  exit 64. Default off. When disabled, `ADVISOR_MODEL` is ignored and the
  output stays the two-key object. `skills/autopilot/parse-flags.sh` stays
  six-key. MUST NOT add a 7th key.
- **M10 — Surfaces.** `--with-advisor[=<model>]` is accepted on
  `/orchestrate` (including its autopilot mode) and `/review-and-commit`.
  Standalone `/kickoff`, `/debug`, `/bug-hunt` are out of this spec. When
  `/orchestrate --with-advisor[=<model>]` reroutes to `/epic`, epic state
  MUST persist `with_advisor: true` and, when overridden, `advisor_model`,
  so children inherit env `ADVISOR=1` and `ADVISOR_MODEL`. Standalone
  `/epic` without the flag stays off.
- **M11 — Byte-identical off.** Flag absent and `ADVISOR` unset → no
  advisor spawn, no `ask.sh` invocation, no `actor:advisor` cards.
- **M12 — First card.** When enabled, the run's first decision-card MUST
  record enablement. Flag is primary. If source=env, rationale MUST mention
  `ADVISOR=1`. When M37 resolves a model override, the rationale MUST
  mention `advisor_model=<model>`.

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
  (exit 64). A trigger-(d) finalize validates the M39 class-verify
  vocabulary instead (CDT-589-C3).
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

### Trigger (a) enforce — the Step 6c BC1 mis-fire clear (CDT-589-C5)

- **M42 — Enforce is opt-in and narrow.** `ADVISOR_ENFORCE` is a human config
  that does not exist by default (off/absent). `1|true|on` enable; `0|false|off`
  are explicit off; any other value is junk → one stderr line and off (never
  parsed as code). With the config off, every behavior is byte-identical to
  the M25 shadow path (one `class=gate-shadow` row, `applied: false`, the halt
  stands). When on, `gates.sh mode --run-id ID` reports `mode: enforce` and
  `gates.sh apply` is the deterministic clear decision. The M25 invariant is
  unchanged: the mode value transitions only from the human config, never from
  code — no state write computes a mode. The clear is scoped to the Step 6c
  BC1 halt ONLY: bc1-mis-fire + a `mis-fire` ruling at confidence ≥ 80 on a
  `plan-approve` halt. BC2–BC8, the M23 denylist, the Step 9 task-gate
  council, and the M14 ship-gate have no clearing path, and no clearing path
  reaches Step 8 IC spawns outside 6c. Fail-closed: `halt-stands`, confidence
  < 80, timeout, spawn-fail, refuse, cap, junk config, a writer reject, a
  missing/unparseable ruling file — the halt stands. The clear writes exactly
  ONE decision card (`gate: plan-approve`, `decision: proceed`,
  `blocking_condition: null`, `decided_by: auto`, `actor: advisor`,
  `schema_version` 1 unchanged, rationale
  `trigger=a bc=bc1-mis-fire ruling=mis-fire model=<m>`, M30 advisor object
  with `trigger: "a"` and the `mis-fire` ruling) — no duplicate human/auto
  card for the same gate — and Step 7 proceeds with no `task_blocked`. A
  mis-fire clear and a CDT-589-C3 class-verify demotion are distinct paths
  with distinct provenance (trigger `a` vs `d`; no `class-verify.jsonl` row).

### Trigger (d) — class verify (CDT-589-C3)

- **M38 — Seam.** `ask.sh probe --trigger d` is accepted (the `a|b|c` set
  extends to `a|b|c|d`). Step 6c runs AT MOST ONE class-verify probe per run
  on `ticket_class: auth-secrets`, BEFORE any `/council` invoke. The fixed
  question text has ONE named home: the `CLASS_VERIFY_QUESTION=` line of the
  advisor SKILL trigger table — no other doc or fence copies the question
  body. Evidence travels as a directory (M18): the staged ticket text
  (title, body, ACs). `gates.sh allow --bc class-verify` extends the M24
  allowed set for the deterministic pre-probe fence; the M23 denylist is
  unchanged.
- **M39 — Vocabulary.** The trigger-d ruling is exactly `auth-relevant` or
  `not-auth-relevant` with `confidence` integer 0–100 — anything else exits
  64. `ask.sh finalize` validates the trigger-d vocabulary on a trigger-d
  spawn request (M18 applies to the other triggers); `gates.sh ruling --bc
  class-verify` mirrors it.
- **M40 — Demotion.** `not-auth-relevant` at confidence ≥ 80 demotes: 6c
  prints the existing skip line with `class-verify` named as the reason and
  continues to Step 7 — the council is NOT run. A demotion writes exactly
  one decision card: `gate: plan-approve` (no new gate enum), `decision:
  proceed`, `blocking_condition: null`, `actor: advisor`, confidence =
  the ruling's, rationale `trigger=d ruling=<r> model=<m>`. The ruling is
  also logged for precision measurement: one `class-verify` row
  (`decision: demote|council`) per trigger-d finalize in
  `runs/<run_id>/class-verify.jsonl` under the advisor state root.
- **M41 — Demotion-only, fail-closed.** The verifier never raises: a `none`
  classification is never `auth-secrets`, and the ruling never rewrites the
  plan's `ticket_class`. Fail-closed to the council — never a halt:
  `auth-relevant` at any confidence; confidence < 80; advisor off/unmapped;
  probe `refuse`/`cap`; finalize `--timeout`/`--spawn-fail`. Cap exhaustion
  on trigger d MUST NOT emit BC8 (the §3g BC8 unavailable fence stays
  `a|b|c`); a non-demotion trigger-d finalize writes no card.

### Caps (AC19)

- **M26 — Caps.** Per-run reserves: (a)=3, (b)=4, (c)=2, (d)=1. Global per-run
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
  - trigger d (class verify, CDT-589-C3): `not-auth-relevant` and
    confidence ≥ 80 → `decision: proceed`, `blocking_condition: null`;
    every other trigger-d outcome writes NO card (M41 — fail-closed to the
    council)
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
    "trigger": "a|b|c|d",
    "cache_hit": false,
    "timeout": false,
    "marker": null
  }
  ```

  `model` is the spawned map-string. `evidence_over_memory` MUST be true
  whenever a tool result disagrees with a memory row. `rationale` stays a
  one-line ≤1000-char summary: `trigger=<a|b|c|d> ruling=<…> model=<…>`
  (the trigger-d ruling is the M39 vocabulary). Gate enum stays 3 values.
  Decision enum stays 6 values.

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
- **M37 — Model override.** A per-run model override wins over the Model
  map. `--with-advisor=<model>` supplies it; a bare flag or `ADVISOR=1` may
  take it from env `ADVISOR_MODEL`. Precedence: `ask.sh probe --model` >
  `ADVISOR_MODEL` env > Model map. An explicit override enables the advisor
  even when no Model map layer carries `advisor`; without one, M8's mapped
  rule and `advisor not configured` refusal stay in force.
  - **Token grammar.** A model MUST match `[A-Za-z0-9._:+@~/-]+` and MUST NOT
    contain `..`. `null` and `--clear` are reserved and never name a model, so
    an "absent" sentinel cannot be mistaken for one. The allowlist (not a
    whitespace denylist) keeps the token safe in an env assignment, in jq
    transport, and in state.
  - **Absence is empty.** Callers represent "no override" as an empty
    `ADVISOR_MODEL`, never a sentinel string: the variable name is the live
    env channel the probe reads, and bash keeps the export attribute across
    reassignment. Identity test is `[ -n "$ADVISOR_MODEL" ]`.
  - **Malformed input.** A malformed flag value exits 64 at the parser. A
    malformed ambient `ADVISOR_MODEL` makes `ask.sh probe` refuse with reason
    `advisor model invalid` (never a silent fallback), and is validated even
    when `--model` wins precedence. A duplicate `--model` exits 64.
    `appeal.sh gate --model` validates the same grammar and forwards it to the
    probe, so the trigger-(c) appeal cannot silently fall back to the map.
  - **Visibility.** When an override replaces a mapped choice, the probe
    prints one stderr line naming the model and its source, and
    `spawn-request.json` records `model_source` (`flag|env|model-map`).
  - **Cache.** The override does not change the question hash, so a cached
    ruling for the same question is still a free cache hit. The cache entry
    records the model that produced the ruling, and a `cache-hit` emits that
    model — never the requesting run's — so a ruling is never attributed to a
    model that did not compute it.
  - **Persistence.** The override is per-run: the parser and the seam MUST NOT
    write any Model map layer (`write-model.sh` stays the only local writer —
    a durable model choice is a `/setup models` action). It lives only in
    `runs/<run_id>/spawn-request.json` and, on a reroute, in epic state.
    On a reroute to `/epic`, `epic-lib set-with-advisor` accepts an optional
    model, follows the sibling-setter discipline (`null`/`--clear` clear it, an
    unknown `- flag` exits 64, a model with `false` exits 64), and persists
    `advisor_model`. B.4 reads it, MUST fail loudly when `epic-lib show` errors
    or returns non-JSON, and exports `ADVISOR_MODEL="<model>"` only when the
    value is non-empty. A child re-validates it, so a tampered state value
    refuses rather than spawns. `advisor_model` is null when no override is
    active.
  - **Parser dependency.** `skills/advisor/parse-flags.sh` stays jq-free: every
    output path prints with `printf`, because exit 0 with empty stdout would
    read as "advisor off" to a fence that gates only on exit status.

### MUST NOT

- MUST NOT add a file under `commands/` (no `/advise` Surface).
- MUST NOT add a 7th key to `skills/autopilot/parse-flags.sh`.
- MUST NOT invent a ninth blocking condition.
- MUST NOT change the marker `self-verified — refuters unavailable`.
- MUST NOT spawn advisor when the flag is off and `ADVISOR` is unset.
- MUST NOT use Tier default or frontmatter retry when unmapped.
- MUST NOT accept `null` or `--clear` as an advisor model name, and MUST NOT
  write a resolved override into any Model map layer.
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
  README/AGENTS.md roster lines, the M29 decision-map card (proceed at
  AGREE ≥ 80; halt/BC7 otherwise; fail-closed 0 on a high-confidence
  refutation; no-card backward compatibility; card-context misuse), and the
  BC8 unavailable card with the exact marker.
- `bash skills/advisor/test-classify.sh` covers disposition `--action`,
  identity-claim hits (`omp is Open MPI`, `omp on this machine is Open MPI`),
  misses (`ic4 is the well-defined seat`), miss-sample modulo, static-check
  paths-only evidence, the receipt/verify gate and probe hash parity
  (CDT-564), and the wave-plan/disposition hook wiring asserts.
- `bash skills/advisor/test-gates.sh` covers the trigger-(a) restricted gate +
  shadow (CDT-563): M23 denylist refusals with stable reasons, M24 outcome
  vocabularies (halt|decompose for BC2/BC6 diagnosis), M25 shadow N=5 logging
  to `runs/<run_id>/shadow.jsonl` with the no-grow invariant, and the
  `self-answer.md` §3g gate fence.
- `bash skills/advisor/test-class-verify.sh` covers trigger (d) class verify
  (CDT-589-C3) per AC: probe/finalize `a|b|c|d` acceptance, the
  `class-verify` allow fence and vocabulary, reserve d=1, demotion card
  shape, the class-verify precision log, demotion-only, fail-closed
  outcomes, byte-identical-off, roster unchanged, and the SPEC-009/SPEC-039
  prose bites.
- `bash skills/model-map/spawn-site-test.sh` includes `advisor:opus:high`
  and tools exactly `Read, Grep, Glob, Bash`.
- `bash install-test.sh` strips `tools:` from `agents/advisor.md`.
- `bash skills/autopilot/test-card-validation.sh` accepts `--advisor-json`,
  backfills `advisor: null` on old cards, and extracts/runs the
  `self-answer.md` §3g BC8 fence for all four unavailable modes.
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
- A ruling finalize with card context writes the M29 map: `AGREE` ≥ 80 →
  `proceed`/null at the ruling's confidence; `CONTRADICT`/`INSUFFICIENT` or
  < 80 → `halt`/7 at the ruling's confidence when below 80, else fail-closed 0
  (`skills/advisor/test.sh`).
- The card envelope is 19 top-level keys with `advisor` last; `read-cards.sh`
  materializes absent ≡ null in frozen order
  (`skills/autopilot/test-card-validation.sh`).
- `/doctor` prints an advisor memory row (`skills/doctor/test.sh`).
- `install-test.sh` passes with `agents/advisor.md` present.

## Version History

| Date | Change |
|------|--------|
| 2026-10-31 | CDT-589-C5: `### CDT-589-C5` ACs for the opt-in Step 6c BC1 mis-fire enforce clear — M42 (`ADVISOR_ENFORCE` human config, default off; `gates.sh mode` reports `enforce`; `gates.sh apply` clears a `bc1-mis-fire` `mis-fire` ruling at confidence ≥ 80 on a `plan-approve` halt only, fail-closed otherwise); `append-card.sh` M30 shape accepts trigger-a `halt-stands\|mis-fire`; §3g enforce fence + `06-design.md` 6c exception; one auto/advisor clear card, distinct from the C3 demotion. |
| 2026-10-31 | CDT-589-C3: `### CDT-589-C3` ACs for trigger (d) class verify — M38 seam (`a|b|c|d`, reserve d=1, question home in the SKILL trigger table), M39 vocabulary (`auth-relevant`/`not-auth-relevant`, `gates.sh allow`/`ruling` fence), M40 demotion card (`gate: plan-approve`, proceed/null) + `class-verify.jsonl` precision log, M41 demotion-only fail-closed (never BC8); M18/M26/M29/M30 amended; `append-card.sh` M30 shape accepts trigger d. |
| 2026-10-20 | M37: per-run advisor model override — `--with-advisor=<model>`, `ADVISOR_MODEL`, `ask.sh probe --model`, `appeal.sh gate --model`, epic `advisor_model` persistence; M8/M9/M10/M12 amended (council diff-mode review). |
| 2026-10-18 | CDT-561: `### CDT-561` ACs for trigger (c) — `residue.sh` detector, `appeal.sh` gate/authority/check-bundle-set, the ship-gate-council §4a hook, M20 clean-pass zero-advisor, M21 authority fence, M22 label + outside-bundle evidence (epic child C6). |
| 2026-10-18 | CDT-563: `### CDT-563` ACs for the trigger-(a) restricted gates + shadow mode — `gates.sh` (M23 denylist, M24 vocabularies, M25 shadow N=5), the `self-answer.md` §3g gate fence, and `SKILL.md` documentation (epic child C7). |
| 2026-10-18 | CDT-564: `### CDT-564` ACs for the trigger-(b) mechanical front-end — `classify.sh`, `static-check.sh`, both hook points, M17 miss sampling, receipt/verify probe gate (epic child C5). |
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

### CDT-560

- **AC1.** `skills/model-map/mappable-names.sh` is the single source of the mappable set. `--is NAME` exits 0 exactly for the 11 mappable names (`pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`, `council-judge`, `finder`, `debugger`, `advisor`) and 1 otherwise; `--list` prints the 11 names one per line; `--internal-empty` prints `distiller` and `project-init` one per line. `spawn-site-test.sh` ROSTER gains `advisor:opus:high` (covered by `skills/model-map/spawn-site-test.sh`, also run at the gate).
  Verify: bash skills/model-map/test.sh
- **AC2.** `resolve-model.sh --mapped <agent>` prints exactly `unmapped` when no Model map layer carries a valid string for the agent (no layers, internals, unknown agents, and invalid values are all unmapped) and `mapped` otherwise; it never consults the Tier default.
  Verify: bash skills/model-map/test.sh
- **AC3.** `resolve-model.sh`, `write-model.sh` (guard plus `list` loop), and `skills/doctor/checks/models.sh` call `mappable-names.sh`; no hand-copied case list remains in any of the three.
  Verify: bash skills/doctor/test.sh

### CDT-557

- **AC1.** `skills/advisor/parse-flags.sh` is a subprocess CLI printing exactly one JSON object `{"enabled":true|false,"source":"flag|env|none"}`, plus an optional `"model"` key when M37 resolves an override. Every path prints with `printf` — the parser takes no jq dependency, so a missing jq can never yield exit 0 with empty stdout. `--with-advisor` → flag; `--with-advisor=<model>` → flag+model; a bare flag plus `ADVISOR_MODEL` → flag+model; no flag and `ADVISOR` in `{1,true}` → env (plus model when `ADVISOR_MODEL` is set); else disabled/none (model ignored). A model MUST match `[A-Za-z0-9._:+@~/-]+`; `null` and `--clear` are reserved. `ADVISOR_MODEL` is validated even when a flag value wins precedence. Duplicate `--with-advisor` or `--with-advisor=*` exits 64; so does a malformed value. `--advisor` (omp host flag) neither enables nor exits 64; unknown tokens pass through. `skills/autopilot/parse-flags.sh` stays six-key (`--with-advisor` and `--with-advisor=<model>` pass through it unchanged).
  Verify: bash skills/advisor/parse-flags-test.sh
- **AC2.** `--with-advisor[=<model>]` is accepted and parsed on `/orchestrate` (Step 0, `skills/orchestrate/steps/00-resolve.md`) and `/review-and-commit` (Step 0) via the sibling parser; default off and byte-identical when disabled (M11: no advisor spawn, no `ask.sh` call, no `actor:advisor` card); the run's first decision card records enablement, an env-sourced rationale mentions `ADVISOR=1`, and an overridden model appears as `advisor_model=<model>` (M12 — asserted as a doc bite on both caller fences); no new `commands/*.md`; the omp `--advisor` name collision is documented in `docs/runbooks/omp.md` (AC25).
  Verify: bash skills/advisor/parse-flags-test.sh
- **AC3.** When `/orchestrate --with-advisor[=<model>]` reroutes to `/epic`, the orchestrate reroute blocks (`02-scope.md`, `06-design.md`, `08-execute.md`) run `epic-lib set-with-advisor <EPIC-ID> true` (persists `with_advisor: true`, and `advisor_model` when overridden; the setter clears on `null`/`--clear`, rejects an unknown `- flag` and a model paired with `false`, all exit 64) and pass `ADVISOR=1` plus a quoted `ADVISOR_MODEL` into the `/epic` child environment. `skills/epic/mode-b-execute.md` B.4 exits nonzero when `epic-lib show` fails or returns non-JSON, exports `ADVISOR=1` when the epic carries `with_advisor: true`, and exports the model only when `advisor_model` is non-empty; a bare `true` clears `advisor_model`; standalone `/epic` without the flag persists nothing.
  Verify: bash skills/advisor/parse-flags-test.sh
- **AC4.** `ask.sh probe` accepts `--model MODEL` with precedence `--model` > `ADVISOR_MODEL` env > Model map. An explicit override spawns even when the advisor is unmapped; a malformed ambient `ADVISOR_MODEL` returns `action=refuse`, reason `advisor model invalid`, and is checked even when `--model` wins; duplicate or empty `--model` exits 64. `spawn-request.json` carries the model plus `model_source`, and an override that replaces a mapped choice warns once on stderr. The question hash excludes the model (cache hits stay free) and a `cache-hit` reports the model recorded in the cache entry, not the requesting run's. `appeal.sh gate` accepts `--model` and forwards it to the probe, rejecting a reserved or malformed token with exit 64. A resolved override leaves `$MROOT/.claude/dev-team/models.local.json` byte-identical, and neither `ask.sh` nor `parse-flags.sh` references `write-model.sh`.
  Verify: bash skills/advisor/test.sh

### CDT-559

- **AC1.** `skills/advisor/ask.sh` is a subprocess CLI (never sourced) with `probe` and `finalize`. `probe` prints exactly one JSON object `{action, model, spawn_request_path, cached_ruling_path, reason}` with `action` ∈ `spawn|cache-hit|refuse|cap`; probe never spawns an agent; a re-entrant probe (advisor lock `$MROOT/.claude/advisor/lock` already held) exits 64; state lives under `$MROOT/.claude/advisor/` (gitignored) and `ADVISOR_STATE_ROOT` reroutes it for tests.
  Verify: bash skills/advisor/test.sh
- **AC2.** Model resolution applies M37 first (`--model` > `ADVISOR_MODEL` > Model map); without an override it probes `resolve-model.sh --mapped advisor`: unmapped → `action=refuse`, reason `advisor not configured`, never a tier default. `finalize --ruling-file` rejects any `ruling` other than `AGREE|CONTRADICT|INSUFFICIENT` (exit 64), requires integer `confidence` 0–100 and `evidence[].locator` of `path:line` (M18); `--timeout`/`--spawn-fail`/`--refuse` record run status and never write the cache — a timeout is not a partial ruling; a valid ruling caches under the question hash so the next identical probe is a free `cache-hit`.
  Verify: bash skills/advisor/test.sh
- **AC3.** Caps per M26: per-trigger reserves a=3, b=4, c=2; global per-run total 5; `ADVISOR_MAX_CALLS` only lowers the global 5 (integer ≥ 1, any other value ignored); retries count; dedupe by question hash (sha256 of trigger + whitespace-normalized question + evidence-dir content hash) so changed evidence is a new question; cache hits never increment caps; epic children share an epic total default 8 stored under `.claude/advisor/epic/<epic_id>/counters.json`; exhaustion → `action=cap` with no spawn.
  Verify: bash skills/advisor/test.sh

### CDT-565

- **AC1.** `skills/autopilot/append-card.sh` accepts an optional `--advisor-json PATH` flag (position-independent, at most once, value must not be flag-like); when given it reads the M30 advisor ruling object from disk and writes it as the 19th top-level key `advisor` (after `actor`); `schema_version` stays 1; argc 13–16 stays valid with the flag present or absent; the object travels on disk, never embedded in argv or shell interpolation.
  Verify: bash skills/autopilot/test-card-validation.sh
- **AC2.** Flag absent or an empty advisor file writes `advisor: null`. A present non-empty file must parse as exactly one JSON object with the M30 shape (`ruling` AGREE|CONTRADICT|INSUFFICIENT|null, `corrected_claim` string|null, `evidence` array of `{cmd, exit, sha256, locator}` objects, `model` string, `evidence_over_memory` boolean, `question_hash` string, `trigger` a|b|c, `cache_hit` boolean, `timeout` boolean, `marker` string|null) — malformed JSON, a non-object, a multi-object file, or an unknown ruling exits 64 with no ledger line; injection content inside the object is data (no execution, verbatim on the card). (Amended by CDT-589-C3: `trigger` extends to a|b|c|d and a trigger-d object carries the M39 vocabulary — see M30.)
  Verify: bash skills/autopilot/test-card-validation.sh
- **AC3.** `skills/autopilot/read-cards.sh` backfills a missing top-level `advisor` as explicit `null` in frozen key order (19th, after `actor`); pre-CDT-565 18-key cards read back with the full 19-key shape and `schema_version` 1; a mixed ledger round-trips (the object intact on new cards, explicit null on old cards).
  Verify: bash skills/autopilot/test-card-validation.sh
- **AC4.** Decision map (M29): with card context (all five of `--card-workflow` `--card-ticket` `--card-gate` `--card-iteration` `--card-run-start-epoch`), a `--ruling-file` finalize writes the advisor decision card via `append-card.sh --advisor-json` — `AGREE` at confidence ≥ 80 → `decision: proceed`, `blocking_condition: null`, `confidence` = the ruling's (the autopilot self-answer recorded as the decision); `actor: advisor`, `decided_by: auto`, `bump: null`; rationale one-line `trigger=<t> ruling=<r> model=<m>`; the M30 advisor object written to `runs/<run_id>/advisor-object.json` and passed as a path.
  Verify: bash skills/advisor/test.sh
- **AC5.** `CONTRADICT` or `INSUFFICIENT`, or confidence < 80 regardless of ruling → `decision: halt`, `blocking_condition: 7`. The BC7 card carries the ruling confidence when it is below 80, else fail-closed 0: append-card cross-field invariant (b) rejects a BC7 card at confidence ≥ 80, so a high-confidence refutation cannot carry its own confidence (the M14(b) CONTRADICTED→0 precedent); `AGREE` at exactly 80 proceeds.
  Verify: bash skills/advisor/test.sh
- **AC6.** A ruling finalize without card context writes no card (the C4 seam records status + cache only); a partial card context exits 64; card context on a `--timeout`/`--spawn-fail`/`--refuse` finalize exits 64; a card-writer reject exits 64 and leaves the ruling uncached and the ledger untouched, so a retry re-spawns instead of silently losing the card.
  Verify: bash skills/advisor/test.sh
- **AC7.** Under autopilot, advisor unavailable (probe `refuse`/`cap`, or a `--timeout`/`--spawn-fail` finalize) halts with exactly one BC8 card — `decision: halt`, `blocking_condition: 8`, `decided_by: auto`, `actor: advisor`, `confidence: 0` — carrying the exact marker `advisor unavailable — fell back` inside the `advisor` object (`ruling: null`). The `self-answer.md` §3g fence is the one executable pattern (fresh `budget-check.sh` wall_clock_s, mktemp advisor-object file under TMPDIR, writer reject → exit 64, no silent retry) and it accepts only `refuse|cap|timeout|spawn-fail`; no ninth blocking condition exists anywhere (the writer still rejects `blocking_condition: 9`).
  Verify: bash skills/autopilot/test-card-validation.sh

### CDT-564

- **AC1.** `skills/advisor/classify.sh` is a deterministic POSIX-ERE classifier invoked as a subprocess CLI and never sourced; its source contains no LLM or spawn primitives (no Agent tool, no spawn-request, no `subagent_type`, no network calls). It scans `--file PATH`, `--text TEXT`, or stdin, prints exactly one JSON array of hits `{trigger:"b", class, span, question_hash}` (empty array = no fire), and exits 0 on any scan (64 only on usage errors: unknown `--kind`, `--action` on `wave-plan`, invalid `--action` value).
  Verify: bash skills/advisor/test-classify.sh
- **AC2.** The disposition class (M15) fires only from the structured `--action` in `close|block|descope|reassign` — one `disposition` hit per such write — and the verbs are never scanned from freeform prose; a disposition scan additionally reports identity-claim hits from the same text.
  Verify: bash skills/advisor/test-classify.sh
- **AC3.** The identity-claim class (M16) fires on `wave-plan` and `disposition` scans for the three case rules with a lowercase-token or absolute-path subject: (1) `<subject> on this (machine|host|box) (is|is not|isn't|are|aren't) …`; (2) `<subject> (is|is not|isn't) (installed|present|available|missing|not installed)`; (3) `<subject> (is|is not|isn't) <ProperName>` (`[A-Z]` start). `omp is Open MPI`, `omp on this machine is Open MPI`, and `omp is not installed` hit; `ic4 is the well-defined seat` and an uppercase subject miss; a later pattern match overlapping an earlier span on the same line is skipped (`omp on this machine is Open MPI` yields exactly one identity hit).
  Verify: bash skills/advisor/test-classify.sh
- **AC4.** Miss sampling (M17): a zero-hit scan is a silent skip that writes nothing without `--run-id`; with `--run-id`, `sha256(input) % 10 == 0` (first 13 hex chars) appends exactly one `class=miss-sample` row to `$ADVISOR_STATE_ROOT/runs/<run_id>/shadow.jsonl` and nothing else — no spawn-request, no spawn.
  Verify: bash skills/advisor/test-classify.sh
- **AC5.** The trigger-(b) probe is gated caller-side (M19): at every hook point the documented order places `static-check.sh run` between the classifier and `ask.sh probe` (AC9), and `static-check.sh verify --run-id ID --question-hash H` exits 0 only once `run` has recorded the receipt for that hash (nonzero before, nonzero for a wrong hash) — the probe MUST NOT start un-checked. `run` derives cheap checks from the question (`command -v` per candidate token, repo-docs grep, and `pacman -Q`/`file`/`strings` only when `ADVISOR_STATIC_HOST_CMDS=1`), writes every check output to a file inside the evidence dir and docs hits as `path:line` locators, and `static-check.json` carries paths + exit codes, never embedded command output or prose.
  Verify: bash skills/advisor/test-classify.sh
- **AC6.** The static-check question hash equals the `ask.sh probe` question hash over the same evidence dir (the hash covers the written evidence-dir content), and `static-check.sh verify --run-id ID --question-hash H` exits 0 only once `run` has recorded the receipt for that hash (nonzero before, nonzero for a wrong hash) — the caller-side gate that keeps the probe from starting un-checked.
  Verify: bash skills/advisor/test-classify.sh
- **AC7.** Hook point 1 — wave-plan write (M13.1): `skills/orchestrate/steps/06-design.md` and `skills/orchestrate/steps/07-tasks.md` each carry a `classify.sh --kind wave-plan` guard fence covering the composed plan and any mid-run rewrite of its `## Waves` / Task Map sections: the doc states the classifier runs BEFORE persisting and the fence states a halt MUST NOT persist; the fence is gated on `ADVISOR_ON=true` with an `ADVISOR_SKIP_TRIGGER=1` interactive bypass; and the fence text, extracted and executed, exits 0 with no output when the advisor is off or bypassed (silent skip) and emits the `advisor trigger-(b) hits` halt signal on stderr when the classifier returns hits.
  Verify: bash skills/advisor/test-classify.sh
- **AC8.** Hook point 2 — disposition write (M13.2): `skills/orchestrate/steps/12-wrap.md` (wrap-ticket close), `skills/epic/mode-b-execute.md` B.5 (child `set-status completed|blocked`, with `descope`/`reassign` named), and `skills/backlog/SKILL.md` (backlog close, Linear state change) each carry a `classify.sh --kind disposition --action <action>` guard fence placed before the state-change instruction; the doc states a halt outcome MUST NOT apply the state change; the fence has the same `ADVISOR_ON`/`ADVISOR_SKIP_TRIGGER` seams; and the fence text, extracted and executed, exits 0 with no output when the advisor is off and emits the halt signal on stderr when the classifier returns hits.
  Verify: bash skills/advisor/test-classify.sh
- **AC9.** `skills/advisor/SKILL.md` documents the classify-hits → static-check → probe order, the M17 miss-sample behavior, the receipt/verify gate, and evidence travel as directory paths end-to-end (the spawn-request carries the evidence dir path).
  Verify: bash skills/advisor/test-classify.sh

### CDT-561

- **AC1.** `skills/advisor/residue.sh` is a deterministic subprocess CLI (never sourced; bash+jq only — its source contains no `ask.sh`/`resolve-model` reference, no Agent tool, no `spawn-request`, no network calls) invoked as `residue.sh --meta PATH.finalize-meta.json [--report PATH] [--threshold N]`; it prints exactly one JSON object with a `residue` boolean, a `kinds` array, and the four kind objects `below_threshold`, `contradicted`, `unverified`, `degraded` (each `{present, count, items|reasons}` plus `threshold`); exit 0 on any scan, 64 on usage errors (missing `--meta`, missing file, unparseable or non-object meta, missing `--report` file, `--threshold` not an integer 0–100).
  Verify: bash skills/advisor/test-residue.sh
- **AC2.** Residue kinds (M20): any unstruck verdict or finding with confidence < the threshold (default 80; `--threshold` overrides) fires `below-threshold` with per-item claim or `file:line` locator and confidence; `CONTRADICTED` and `FABRICATED` counts fire `contradicted`; `UNVERIFIED` fires `unverified`; `verification_mode == "self-verified"` and a `self-verified — refuters unavailable` banner in `--report` each fire `degraded` (one reason each); a residue-free sidecar (all unstruck verdicts `VERIFIED`/`PARTIALLY_VERIFIED` at confidence ≥ 80, `verification_mode` `full`, no banner) emits `residue: false` with an empty `kinds` array and all four kinds `present: false`; confidence exactly 80 is not below-threshold, 79 is.
  Verify: bash skills/advisor/test-residue.sh
- **AC3.** `skills/advisor/appeal.sh gate` is the trigger-(c) seam (M20): on a residue-free sidecar it exits 0 with no stdout and writes nothing under `ADVISOR_STATE_ROOT` — no probe, no `spawn-request.json` — so a clean council pass produces zero advisor calls even with the advisor mapped and `ADVISOR_ON=true`; on residue it exits 0 silently with no probe when `ADVISOR_ON` is unset or `ADVISOR_SKIP_TRIGGER=1`.
  Verify: bash skills/advisor/test-residue.sh
- **AC4.** On a residue sidecar with the advisor on, `gate` stages the appeal evidence as a directory (`runs/<RUN_ID>/appeal-evidence/` under the advisor state root, structurally outside the council bundle set, M22; `--evidence-dir` overrides) and prints exactly one `ask.sh probe` action object with `trigger: "c"`; the probe's `spawn-request.json` carries trigger `c`, the staged evidence dir, and a question hash that covers the staged evidence content (changed staged evidence is a new question hash).
  Verify: bash skills/advisor/test-residue.sh
- **AC5.** `appeal.sh authority --ruling-file PATH [--run-id ID]` is the M21 authority fence: `AGREE` maps to `sustain-halt`, `CONTRADICT` and `INSUFFICIENT` map to `re-council`; stdout is exactly one JSON object `{authority, advisor_appeal: true, ruling, confidence}` — `proceed` is not an emit-able authority; with `--run-id` it writes `runs/<RUN_ID>/appeal.json` carrying `advisor_appeal: true`; an unknown ruling value exits 64.
  Verify: bash skills/advisor/test-residue.sh
- **AC6.** `appeal.sh check-bundle-set --file PATH` (M22) exits 0 on a bundle set in which no object carries the `advisor_appeal` provenance key and exits 64 when any object carries `advisor_appeal: true` — advisor-gathered evidence is rejected if injected into a council bundle set; unparseable input exits 64.
  Verify: bash skills/advisor/test-residue.sh
- **AC7.** `skills/autopilot/ship-gate-council.md` §4a carries the trigger-(c) hook fence after the verdict mapper — gated on `ADVISOR_ON=true` with `ADVISOR_SKIP_TRIGGER=1` documented as the interactive bypass — and states a `sustain-halt` appeal outcome MUST NOT persist any proceed/ship state and `re-council` runs only a fresh council pass; the fence text, extracted and executed against a clean-pass fixture with the advisor on, exits 0 with no output, and against a residue fixture emits the `advisor trigger-(c) appeal` stderr signal with the probe recorded. `skills/advisor/SKILL.md` documents the trigger-(c) end-to-end order (gate → probe → native spawn → finalize → authority) and the M22 label/outside-bundle rule.
  Verify: bash skills/advisor/test-residue.sh

### CDT-562

- **AC1.** `skills/agent-memory/advisor-protocol.md` documents the M31 memory rule with the re-verify predicate `{cmd, sha256, version, ts}` (a row goes stale when `version` changes) and the `evidence_over_memory` enforcement — persisted advisor memory rows are tool-backed facts; a row without reproducible evidence may suggest a check but never serves as a ruling reason — exhibited by `skills/advisor/test.sh` doc-bite tests.
  Verify: bash skills/advisor/test.sh
- **AC2.** `skills/agent-memory/advisor-protocol.md` documents the M32 never-persist list: rulings-as-facts, gate waivers / "we proceeded", unverified issue/PR/council text, secrets, per-run state; and that user-overridden rulings persist as a pattern only — exhibited by `skills/advisor/test.sh` doc-bite tests.
  Verify: bash skills/advisor/test.sh
- **AC3.** `bash skills/lib/require-agent.sh --memory advisor` exits 0 and plain `bash skills/lib/require-agent.sh advisor` exits 64 (run output exhibited by `skills/lib/require-agent-test.sh`); memory-store, `/memory distill`, and `/doctor` docs name `--memory` for advisor rows; `/doctor` reports advisor memory status (present/empty/n/a, exercised by `skills/doctor/test.sh` T32); the `/adjust-agent` dashboard does not list advisor (asserted by the `skills/doctor/test.sh` dashboard-exclusion test).
  Verify: bash skills/doctor/test.sh
- **AC4.** SPEC-003 documents the third category (advisory-internal) with tier-table row `advisor`/`opus`/`high`; the behavioral-7 and non-behavioral-6 counts are unchanged; the README and AGENTS.md rosters list `advisor` at HEAD.
  Verify: bash skills/doctor/test.sh
- **AC5.** The memory protocol (skills/agent-memory/) documents the M31/M32 advisor memory content rules and the `--memory` write-path gate.
  Verify: bash skills/advisor/test.sh

### CDT-563

- **AC1.** `skills/advisor/gates.sh` is a deterministic trigger-(a) gate CLI (subprocess, never sourced): `gates.sh allow --bc <id>` exits 0 with `allowed: true` exactly for the M24 set `bc7`, `bc2-diagnosis`, `bc6-diagnosis`, `bc1-mis-fire`; the M23 denylist — `bc3`, `bc8`, `bc6-extension`, `bc1-as-human-preference` — is structurally unreachable, each id refused with exit 64, an `allowed: false` JSON object on stdout, and a stable stderr refusal reason naming `SPEC-039 M23 denylist`; an unknown id also exits 64.
  Verify: bash skills/advisor/test-gates.sh
- **AC2.** `gates.sh ruling --bc <gate> --ruling <ruling>` restricts trigger-(a) outcome vocabulary (M24): `bc2-diagnosis` and `bc6-diagnosis` accept only `halt` or `decompose` — a `proceed` ruling is rejected with exit 64 and can never be emitted; `bc1-mis-fire` accepts only `halt-stands` or `mis-fire`; `bc7` accepts the M18 vocabulary `AGREE`, `CONTRADICT`, `INSUFFICIENT`.
  Verify: bash skills/advisor/test-gates.sh
- **AC3.** `gates.sh shadow --run-id ID --bc <gate> --ruling <ruling>` records every allowed trigger-(a) ruling as SHADOW: one `class=gate-shadow` JSONL row carrying the bc id, ruling, question, card context, and timestamp appended to `$ADVISOR_STATE_ROOT/runs/<run_id>/shadow.jsonl` (default state root `$MROOT/.claude/advisor/`), with `applied: false` on stdout — the ruling is logged, never auto-applied; the human decides. A denylisted or unknown bc never reaches the log (exit 64 first), and an out-of-vocabulary ruling never reaches the log (exit 64 first).
  Verify: bash skills/advisor/test-gates.sh
- **AC4.** Shadow window defaults (M25): `gates.sh mode --run-id ID` reports `shadow_n` default `5`; `ADVISOR_SHADOW_N` only lowers it (an invalid value is ignored); `shadow_used` increments by one per recorded ruling; and `mode` reads `shadow` before, at, and after the N=5 boundary — the counter never flips the mode.
  Verify: bash skills/advisor/test-gates.sh
- **AC5.** No automatic growth past shadow: the `gates.sh` source contains zero widen transitions (a case-insensitive grep for `widen` over the file is empty) and after seven recorded rulings `gates.sh mode` still reports `mode: shadow` — growth past shadow is a human config edit with no code path.
  Verify: bash skills/advisor/test-gates.sh
- **AC6.** The autopilot surface wires the gate: `skills/autopilot/self-answer.md` §3g carries a trigger-(a) fence gated on `ADVISOR_ON=true` with the `ADVISOR_SKIP_TRIGGER=1` interactive bypass; the extracted fence text, executed, exits 0 with no output when the advisor is off or bypassed, and emits the `advisor trigger-(a) gate refused — the halt stands` signal on stderr when the gate refuses; the fence text states the halt `MUST NOT` persist.
  Verify: bash skills/advisor/test-gates.sh
- **AC7.** `skills/advisor/SKILL.md` documents the trigger-(a) gate: the `allow`, `ruling`, `shadow`, `mode` subcommands, the M23 denylist ids, the M24 vocabularies, and the `runs/<run_id>/shadow.jsonl` log path.
  Verify: bash skills/advisor/test-gates.sh

### CDT-589-C3

- **AC1.** `ask.sh probe --trigger d` is accepted (the `a|b|c` set extends to `a|b|c|d`) and `gates.sh allow --bc class-verify` exits 0 with `allowed: true`; the trigger-d ruling vocabulary is exactly `auth-relevant` / `not-auth-relevant` with `confidence` 0–100 — any other ruling or confidence exits 64 in `ask.sh finalize` and `gates.sh ruling`; the `SPEC-039 M23 denylist` ids still exit 64; the trigger-d reserve is 1 probe per run and the global per-run cap stays 5 (`GLOBAL_LIMIT=5`; `ADVISOR_MAX_CALLS` still only lowers it); the fixed question text has one named home, the `CLASS_VERIFY_QUESTION=` line of the advisor SKILL trigger table.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC1
- **AC2.** Step 6c runs at most one class-verify probe per run on `ticket_class: auth-secrets`, before any `/council` invoke: a second trigger-d spawn-probe in the same run returns `action: cap`; the executed 6c probe fence probes once with the advisor on and its text precedes the council invoke in `06-design.md`; the spawn-request question equals the SKILL trigger-table question.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC2
- **AC3.** `ticket_class: none` produces zero advisor calls, zero cards, and zero added lines: the executed probe fence is silent, no runs state is created, no ledger is written, and the existing none skip line is unchanged.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC3
- **AC4.** `not-auth-relevant` at confidence ≥ 80 demotes: the executed demotion fence prints the existing skip line `Step 6c (security council): skipped — class-verify: not-auth-relevant`, and the prose continues to Step 7 with the council NOT run; confidence 79, an `auth-relevant` ruling, and a junk confidence each print nothing.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC4
- **AC5.** A demotion writes exactly one decision card: `gate: plan-approve`, `decision: proceed`, `blocking_condition: null`, `actor: advisor`, confidence = the ruling's, rationale `trigger=d ruling=not-auth-relevant model=test-model`, with the M30 advisor object carrying `trigger: "d"`; the ruling is also logged for precision measurement as one `class-verify` row with `decision: demote` in `runs/<run_id>/class-verify.jsonl`.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC5
- **AC6.** Demotion-only: a `none` classification is never raised to `auth-secrets` — the 6c section states demotion-only, never assigns `ticket_class`, and a demotion finalize writes no ticket_class artifact.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC6
- **AC7.** Fail-closed to the council, never a halt: `auth-relevant` at any confidence and confidence < 80 write no card and log `decision: council`; an unmapped advisor probes to `refuse` (`advisor not configured`); finalize `--timeout` / `--spawn-fail` record status only and never cache; cap exhaustion on this trigger emits no `BC8` (the §3g BC8 fence stays `a|b|c`).
  Verify: bash skills/advisor/test-class-verify.sh --ac AC7
- **AC8.** Advisor off: the 6c path is byte-identical to today — with `ADVISOR_ON` unset the probe and demotion fences are silent and no state is written (no probe line, no card); the `ADVISOR_SKIP_TRIGGER=1` bypass is equally silent.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC8
- **AC9.** No new agent role and no new user-invoked Surface: no `agents/class-verify.md` and no `commands/class-verify.md` exist, `agents/advisor.md` still names the single advisor role, and the README and AGENTS.md rosters keep exactly one advisor row each.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC9
- **AC10.** The checks live in the hermetic engine-side suite `skills/advisor/test-class-verify.sh` (no live LLM, scratch `ADVISOR_STATE_ROOT`, fixture-ledger MROOT) sourcing `tests/lib/ac-receipt.sh` with `--ac AC<n>` filtered runs.
  Verify: bash skills/advisor/test-class-verify.sh --ac AC10
- **AC11.** `SPEC-039` gains the Class verify section (`CDT-589-C3` ACs plus the Trigger (d) MUST) and the `SPEC-009` Step 6c MUST names the probe, the skip line, the demotion card, and the fail-closed rule (`not-auth-relevant`, `BC8`, `plan-approve`, `never a halt`).
  Verify: bash skills/advisor/test-class-verify.sh --ac AC11

### CDT-589-C5

- **AC1.** `ADVISOR_ENFORCE` is a human config that defaults off/absent: with it unset, `gates.sh apply --run-id ID --bc bc1-mis-fire --ruling mis-fire --confidence 93` exits 0 with `applied: false`, `gates.sh mode` still reports `shadow`, the trigger-(a) shadow row stands with `applied: false`, and the executed §3g enforce fence is a no-op (halt stands, no card, no added lines).
  Verify: bash skills/advisor/test-enforce.sh --ac AC1
- **AC2.** With a valid on config (`1|true|on`), a `bc1-mis-fire` `mis-fire` ruling at confidence ≥ 80 on a `plan-approve` halt clears: `apply` exits 0 with `applied: true`, the executed §3g enforce fence writes exactly ONE decision card (`gate: plan-approve`, `decision: proceed`, `blocking_condition: null`, `decided_by: auto`, `actor: advisor`, confidence = the ruling's, rationale `trigger=a bc=bc1-mis-fire ruling=mis-fire model=<m>`, M30 advisor object with `trigger: "a"`, `schema_version` 1) and prints the one clear line — Step 7 proceeds, no `task_blocked`, and no duplicate human/auto card for the same gate.
  Verify: bash skills/advisor/test-enforce.sh --ac AC2
- **AC3.** Fail-closed: with the config on, `halt-stands`, confidence < 80 (79), a non-integer or out-of-range confidence (exit 64), timeout, spawn-fail, refuse, cap, and a missing/unparseable ruling file each leave the halt standing — `applied: false`, no card, no clear line.
  Verify: bash skills/advisor/test-enforce.sh --ac AC3
- **AC4.** Scope is the 6c BC1 halt only: `apply` on any other allowed gate id (`bc7`, `bc2-diagnosis`, `bc6-diagnosis`) exits 0 with `applied: false` naming the scope; a denylisted id (`bc3`) exits 64; the executed fence is a no-op for any `<gate-id>` other than `bc1-mis-fire` or any `<halt-gate>` other than `plan-approve`.
  Verify: bash skills/advisor/test-enforce.sh --ac AC4
- **AC5.** The M25 invariant holds: the mode value transitions only from the human config, never from code — `gates.sh mode` reports `enforce` exactly when `ADVISOR_ENFORCE` is validly on and `shadow` otherwise, regardless of `shadow_used` (seven recorded rulings included) and with no mode state written; a junk config reports `shadow` plus exactly one stderr line and is never parsed as code.
  Verify: bash skills/advisor/test-enforce.sh --ac AC5
- **AC6.** A C5 mis-fire clear and a C3 class-verify demotion are distinct paths with distinct card provenance: the clear card carries `trigger: "a"` and rationale `trigger=a bc=bc1-mis-fire ruling=mis-fire model=<m>`, the demotion card carries `trigger: "d"` and rationale `trigger=d ruling=not-auth-relevant model=<m>`, and the enforce path writes no `class-verify.jsonl` row.
  Verify: bash skills/advisor/test-enforce.sh --ac AC6
- **AC7.** Card-schema compatibility: `append-card.sh` accepts a trigger-a M30 advisor object whose ruling is `halt-stands` or `mis-fire` (the M24 vocabulary) and still rejects `halt`/`decompose` on trigger a; trigger-b/c objects keep the M18 vocabulary; `schema_version` stays 1; the written clear card passes `read-cards.sh` unchanged.
  Verify: bash skills/advisor/test-enforce.sh --ac AC7
- **AC8.** The config value is validated before use (junk → off + one stderr line, never executed) and the M23 denylist, M24 vocabularies, M26 caps, and `ADVISOR_SHADOW_N` semantics are unchanged.
  Verify: bash skills/advisor/test-enforce.sh --ac AC8
- **AC9.** The checks live in the hermetic engine-side suite `skills/advisor/test-enforce.sh` (no live LLM, scratch `ADVISOR_STATE_ROOT`, fixture-ledger MROOT) sourcing `tests/lib/ac-receipt.sh` with `--ac AC<n>` filtered runs, covering default-off, on-clears, on-below-80-stands, non-6c BC1 unaffected, card provenance, and mode-report.
  Verify: bash skills/advisor/test-enforce.sh --ac AC9
- **AC10.** `skills/advisor/SKILL.md` documents `ADVISOR_ENFORCE` (default off/absent, valid values, junk handling) and the `apply` subcommand; there is no new Surface (no `commands/*.md`), no new flag on any command, and no new agent role.
  Verify: bash skills/advisor/test-enforce.sh --ac AC10

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
