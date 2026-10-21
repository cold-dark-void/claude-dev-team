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
  [--evidence-dir PATH] [--run-id ID] [--epic-id ID] [--bc N] [--model MODEL]
```

stdout: exactly one JSON object
`{action, model, spawn_request_path, cached_ruling_path, reason}`.

Model resolution (SPEC-039 M8/M36/M37 own the rule): `--model` wins over the
ambient `ADVISOR_MODEL` env, and either override wins over the Model map and
enables an unmapped advisor. A token MUST match `[A-Za-z0-9._:+@~/-]+`; `null`
and `--clear` are reserved. `ask.sh` validates an ambient `ADVISOR_MODEL` even
when `--model` wins, and refuses with `advisor model invalid` rather than fall
back silently. A duplicate `--model` exits 64. An override that replaces a
mapped choice warns on stderr. The caller passes the run's model explicitly with
`--model` on both `ask.sh probe` and `appeal.sh gate`. The question hash stays
model-blind, so a cache hit is still free — and it reports the model that
produced the cached ruling, not the one this run asked for. The override is
per-run and never written to a Model map layer; a durable choice is
`/setup models set advisor <model>`.

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

## Trigger (b) — classifier and static checks (SPEC-039 M13–M19, CDT-564)

The mechanical front-end decides WHEN a trigger-(b) probe is warranted; the
probe itself is the two-phase seam above. Order at every hook point
(wave-plan write: `skills/orchestrate/steps/06-design.md`, `07-tasks.md`,
and mid-run rewrites; disposition write: `12-wrap.md`,
`skills/epic/mode-b-execute.md` B.5, `skills/backlog/SKILL.md` close):

1. `classify.sh` — deterministic POSIX-ERE scan, no LLM, no spawn. CLI:
   `classify.sh --kind wave-plan (--file PATH | --text TEXT) [--run-id ID]`
   or `classify.sh --kind disposition --action <close|block|descope|reassign>
   (--file PATH | --text TEXT) [--run-id ID]`; stdin is scanned when neither
   `--file` nor `--text` is given. stdout is
   exactly one JSON array of hits
   `{"trigger":"b","class":"identity|disposition","span":...,"question_hash":...}`;
   empty array = no fire (silent skip, M17). `--kind disposition` fires its
   structured hit only for `--action close|block|descope|reassign` (M15 —
   never scanned from prose). With `--run-id`, a zero-hit scan appends one
   `class=miss-sample` row to `runs/<run_id>/shadow.jsonl` when
   `sha256(input) % 10 == 0` and never spawns (M17).
2. `static-check.sh run --question <hit span> --evidence-dir DIR --run-id ID`
   — cheap pre-probe checks before the probe is spent (M19): `command -v`
   per candidate token, repo-docs grep, and `pacman -Q` / `file` / `strings`
   only when `ADVISOR_STATIC_HOST_CMDS=1` (host safeguards). Every output
   lands as a file in the evidence dir; docs hits are `path:line` locators;
   `static-check.json` holds paths and exit codes, never embedded prose.
   It prints the question hash and writes a receipt —
   `static-check.sh verify --run-id ID --question-hash H` exits 0 only after
   the run. Probe MUST NOT start without it (M19).
3. `ask.sh probe --trigger b ...` — the seam above. `ADVISOR_SKIP_TRIGGER=1`
   bypasses steps 1–2 interactively; advisor off means both skip silently.

## Trigger (a) — restricted gates + shadow (SPEC-039 M23–M25, CDT-563)

`skills/advisor/gates.sh` is the deterministic trigger-(a) gate (subprocess CLI,
never sourced). The orchestrator runs it before any
`ask.sh probe --trigger a --bc <id>` (fence in `skills/autopilot/self-answer.md`
§3g):

1. `allow --bc <gate-id>` — exit 0 only for the M24 allowed set: `bc7`,
   `bc2-diagnosis`, `bc6-diagnosis`, `bc1-mis-fire`. The M23 denylist — `bc3`,
   `bc8`, `bc6-extension`, `bc1-as-human-preference` — and any unknown id exit
   64 with a stable refusal reason on stderr
   (`advisor gate refused: <id> ... — SPEC-039 M23 denylist`) and an
   `allowed: false` JSON object on stdout. A denied id is structurally
   unreachable: no probe, no spawn.
2. `ruling --bc <gate> --ruling <ruling>` — the M24 outcome vocabularies:
   `bc2-diagnosis`/`bc6-diagnosis` accept only `halt|decompose` (proceed can
   never be emitted, exit 64 otherwise); `bc1-mis-fire` accepts only
   `halt-stands|mis-fire`; `bc7` accepts the M18
   `AGREE|CONTRADICT|INSUFFICIENT`.
3. `shadow --run-id ID --bc <gate> --ruling <ruling> [--question TEXT]
   [--card-context FILE]` — records an allowed ruling as SHADOW: one
   `class=gate-shadow` row (bc, ruling, question, card context, ts) appended
   to `runs/<run_id>/shadow.jsonl`. The ruling is never auto-applied
   (`applied: false`) — the human decides. The first N=5 runs
   (`ADVISOR_SHADOW_N`, only lowers) are the measured window; the mode stays
   `shadow` at and after the boundary. Growth past shadow is a human config
   edit — no code path transitions the mode (M25).
4. `mode --run-id ID` — prints `{"mode":"shadow","shadow_used":N,"shadow_n":N}`.
5. Subprocess form: `gates.sh mode --run-id ID` — never sourced.
   Full form: `gates.sh shadow --run-id ID --bc <gate> --ruling <ruling>` — every allowed ruling logged as SHADOW.
## Trigger (c) — council-residue appeal (SPEC-039 M20–M22, CDT-561)

Council always runs first (M20). After a council verdict, the orchestrator
(including `/review-and-commit`, `skills/autopilot/ship-gate-council.md` §4a)
may ask for a second opinion — only on residue:

1. `appeal.sh gate --meta <report>.finalize-meta.json [--report <report>]
   [--run-id ID] [--model MODEL]` — deterministic. `residue.sh` classifies the sidecar
   (`below-threshold`, `contradicted` (CONTRADICTED/FABRICATED), `unverified`,
   `degraded` (`self-verified` mode or report banner), default threshold 80).
   A clean pass exits 0 with no output and writes nothing — zero advisor
   calls (M20). Advisor off or `ADVISOR_SKIP_TRIGGER=1`: silent skip. On
   residue with the advisor on: stages the appeal evidence under
   `runs/<run_id>/appeal-evidence/` (advisor state root — structurally
   OUTSIDE the council bundle set, M22) and prints the `ask.sh probe
   --trigger c` action JSON (reserve c=2). Spawn/finalize per the seam
   above.
2. `appeal.sh authority --ruling-file <ruling> [--run-id ID]` — the M21
   authority fence. `AGREE` → `sustain-halt` (the halt stands; the appeal
   outcome MUST NOT persist any proceed/ship state); `CONTRADICT` or
   `INSUFFICIENT` → `re-council` (fail-closed): a FRESH council pass with
   new tool evidence decides — the appeal's word alone never ships
   (CONTRADICTED → fresh council pass only). Never `proceed`. With
   `--run-id`, writes `runs/<run_id>/appeal.json` with the provenance key
   `advisor_appeal: true`.
3. `appeal.sh check-bundle-set --file <bundle set>` — M22 injection guard:
   exits 64 when any object in a council bundle set carries
   `advisor_appeal`, so advisor-gathered evidence cannot enter the bundle
   set; the labelled record lives under the advisor state root instead.

End-to-end order: `gate` → `probe` → `native spawn` → `finalize` → `authority`.

Authority recipe (PATH form): `appeal.sh authority --ruling-file PATH [--run-id ID]` emits exactly one JSON object `{authority, advisor_appeal: true, ruling, confidence}` on stdout.

`residue.sh` classifies the sidecar into four kind objects, each with the
span `{present, count, items|reasons}`: `below_threshold`, `contradicted`,
and `unverified` carry `{present, count, items}`; `degraded` carries
`{present, count, reasons}`; the object also carries `threshold`.


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
