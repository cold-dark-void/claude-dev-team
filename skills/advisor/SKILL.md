---
name: advisor
description: |
    Advisor probe/finalize spawn seam (SPEC-039 T6). Two-phase seam — Bash
    cannot spawn agents. Probe is deterministic and never spawns; finalize
    records rulings. Driven by the orchestrator. Agent-internal — not a
    user slash command.
user-invocable: false
---

# advisor — probe/finalize spawn seam (SPEC-039 T6)

Bash cannot spawn agents. The advisor runs as a two-phase seam the orchestrator
drives:

1. `probe` — deterministic, never spawns. Decides one action:
   `spawn | cache-hit | refuse | cap`.
2. Caller spawns the advisor Agent natively (host Agent tool) when
   `action=spawn`, then runs `finalize` with the ruling.
3. `finalize` — the only place outcomes are recorded (and, from T9/C8, the
   only place decision cards are written).

## Probe

```bash
bash skills/advisor/ask.sh probe --trigger a|b|c --question TEXT \
  [--evidence-dir PATH] [--run-id ID] [--epic-id ID] [--bc N]
```

stdout: exactly one JSON object
`{action, model, spawn_request_path, cached_ruling_path, reason}`.

- `spawn` — caller spawns the advisor with `model`; drive it with
  `spawn_request_path` (run dir `spawn-request.json` carries the question,
  hash, model, evidence dir).
- `cache-hit` — `cached_ruling_path` holds the ruling; spawn nothing. Free
  (no cap increment).
- `refuse` — do not spawn. Unmapped model → reason `advisor not configured`
  (never a tier default — SPEC-039 M36).
- `cap` — do not spawn. Reason names the exhausted budget.

Re-entrant probe (advisor lock already held) exits 64.

## Finalize

```bash
bash skills/advisor/ask.sh finalize --run-id ID --ruling-file PATH
bash skills/advisor/ask.sh finalize --run-id ID --timeout
bash skills/advisor/ask.sh finalize --run-id ID --spawn-fail
bash skills/advisor/ask.sh finalize --run-id ID --refuse
```

`--ruling-file` validates M18 shape before caching: `ruling` MUST be
`AGREE|CONTRADICT|INSUFFICIENT` (any other value exits 64), `confidence`
integer 0–100, `evidence[].locator` `path:line`. A valid ruling is written to
the question-hash cache — the next identical probe is a free cache-hit.

`--timeout`, `--spawn-fail`, `--refuse` record run status only. A timeout is
never a partial ruling: nothing is cached, so a retry probe is a fresh spawn
(retries count against caps).

### Decision card (SPEC-039 M28/M29/M30)

A `--ruling-file` finalize writes the decision card when the caller also passes
ALL five card-context flags: `--card-workflow <orchestrate|kickoff|epic>`,
`--card-ticket <id>`, `--card-gate <scope-confirm|plan-approve|ship-choice>`
(the enclosing run's closest canonical gate), `--card-iteration <n>` and
`--card-run-start-epoch <n>`. Without them, finalize records outcomes only
(no card) — the C4 behavior is unchanged. The card is written via
`skills/autopilot/append-card.sh --advisor-json` with `actor: advisor`,
`decided_by: auto`, `bump: null`, and rationale
`trigger=<t> ruling=<r> model=<m>`; the M30 advisor object is written to
`runs/<run_id>/advisor-object.json` and passed as a file path (never embedded
in argv). The M29 map: `AGREE` + confidence ≥ 80 → `decision: proceed`,
`blocking_condition: null`; `CONTRADICT`, `INSUFFICIENT`, or confidence < 80 →
`decision: halt`, `blocking_condition: 7`. A BC7 card carries the ruling confidence when it is below 80,
else fail-closed 0 — append-card cross-field invariant (b) rejects a BC7 card
at confidence ≥ 80 (the M14(b) CONTRADICTED→0 precedent). The card is written
BEFORE the cache: a writer reject exits 64 and leaves nothing cached, so a
retry re-spawns instead of losing the card. A status finalize rejects card
context (exit 64).

## Caps (M26)

- Per-trigger reserves per run: `a`=3, `b`=4, `c`=2.
- Global per-run total 5. `ADVISOR_MAX_CALLS` only lowers the global 5
  (integer ≥ 1; any other value is ignored).
- Retries count; cache hits are free and never increment.
- Epic children share an epic-level total, default 8, stored at
  `.claude/advisor/epic/<epic_id>/counters.json`.
- Exhaustion → `action=cap`, no spawn. Under autopilot the caller maps
  unavailable (unconfigured / timeout / spawn-fail / cap with no cache) to
  BC8 (M27) — this seam only reports. The halt card (exact marker
  `advisor unavailable — fell back`, `blocking_condition: 8`) is written by
  the caller per `skills/autopilot/self-answer.md` §3g; interactively the
  run continues with the fallback and does not halt.

## State

All state lives under `$MROOT/.claude/advisor/` (gitignored): `lock`,
`runs/<run_id>/` (spawn-request, counters, status, ruling), `cache/<hash>.json`,
`epic/<epic_id>/counters.json`. Question hash = sha256 of trigger +
whitespace-normalized question + evidence-dir content hash (sorted rel paths +
file sha256s), so changed evidence is a new question.

This CLI is a subprocess — never source it. It never reads the bot token and
never touches the intercom spool.
