---
name: retro-gate
description: |
    Phase-1 friction gate for /retro. A fast, deterministic, LLM-free heuristic
    that scans a Claude Code session JSONL and decides whether the session
    contained enough friction to warrant a deep retrospective. Used by /retro,
    /kickoff, and /orchestrate to suppress no-op runs on smooth sessions.
---

# retro-gate

The gate is a **filter, not a judge**. It exists so `/retro` can stay quiet on
smooth sessions and only spend subagent budget when something actually went
wrong. False positives are the dominant failure mode — users will disable
`/retro` if smooth sessions get flagged. Calibration bias is therefore "prefer
under-triggering."

## Invocation

```
bash skills/retro-gate/gate.sh <absolute-jsonl-path>
```

Reads from argv[1], writes one line of JSON to stdout, always exits 0.
Schema-drift warnings (no known JSONL fields seen in first 50 lines) go to
stderr so callers can `grep` stdout safely.

Override the trigger threshold via env var:
```
RETRO_THRESHOLD=7.5 bash skills/retro-gate/gate.sh /path/to/session.jsonl
```
Default threshold is `5.0`.

### Hybrid S2 ledger (SPEC-012 M4)

When a session is **ledger-covered** (≥1 well-formed row in
`$MROOT/.claude/retro/friction.jsonl` for that `session_id`), **S2 only** is
derived from the ledger; **S1/S3/S4/S5 always come from the transcript**.
Uncovered / missing / unreadable ledger → full transcript path for all signals
(pre-CDV-186 behavior). Ledger wiring is installed by `/init-orchestration`
only (handler: `.claude/hooks/friction-capture.sh`); `/retro` never installs hooks.

| Env | Default | Purpose |
|-----|---------|---------|
| `FRICTION_LEDGER` | `$MROOT/.claude/retro/friction.jsonl` | Ledger path override (tests) |
| `FRICTION_LEDGER_MAX_LINES` | `10000` | Capture-side rotation (lines) |
| `FRICTION_LEDGER_MAX_BYTES` | `5242880` | Capture-side rotation (bytes) |
| `RETRO_FORCE_TRANSCRIPT_S2` | unset | `1` → ignore ledger coverage for S2 |

Ledger line schema (no payload bodies):
```json
{"ts":"<ISO-8601>","session_id":"<id>","event":"<PostToolUseFailure|PermissionDenied|StopFailure>","tool":"<name or empty>","path":"<optional>"}
```

Ledger → S2: each of the three event types is an error observation; ≥2
consecutive events in append order form one run (no success reset on ledger).
S2 ids may be synthetic (`ledger:<event>:<ts>`).

## Output schema

```json
{"score":11.5,"passed":true,"threshold":5.0,"signals":[
  {"name":"S1","count":2,"ids":["00000000-0000-4000-8000-000000000004","00000000-0000-4000-8000-000000000002"]},
  {"name":"S3","count":1,"ids":["00000000-0000-4000-8000-000000000005"]}
]}
```

`signals[].ids` are the message UUIDs that anchored each match. They are
passed forward to the phase-2 deep-read subagent so it can quote real
evidence rather than re-scanning the whole transcript.

## Signals

| #  | Name              | Detection                                                                                                          | Weight | Cap |
|----|-------------------|--------------------------------------------------------------------------------------------------------------------|--------|-----|
| S1 | Explicit reject   | Regex on real (non-meta) `type=user` text: `\b(revert\|stop\|wrong\|don'?t\|why did you\|no that'?s\|undo\|that'?s not\|nope)\b` | 3.0    | 3   |
| S2 | Tool error run    | **Transcript (default / uncovered):** a run of >=2 consecutive `tool_result.is_error:true` blocks; reset by a successful result or a real user turn. **Ledger-covered:** ≥2 ledger friction events for the session in append order (one continuous run; no success reset). Hybrid: ledger supplies S2 only when covered; see above. | 2.0    | -   |
| S3 | Edit loop         | >=3 `Edit`/`Write`/`MultiEdit`/`NotebookEdit` tool_uses on the same `file_path` within 10 assistant turns; one score per file. **Exempt:** clean draft-polish — path whose first edit-tool is `Write` (session-created) with no intervening `tool_result.is_error` and no S1-eligible user rejection after that Write and at/before the last edit in the candidate window. Pre-existing paths and dirty session-created paths still score. | 2.5    | -   |
| S4 | Assistant retry   | Regex on assistant text: `\b(let me try again\|let me try a different\|that didn'?t work\|actually,? let me\|sorry,? let me\|my mistake\|i'?ll try)\b` (see `S4_RE` in gate.sh) | 1.5    | 3   |
| S5 | Terse follow-up   | Real user message of <=3 words immediately after an assistant turn >=500 chars                                       | 1.0    | 4   |

`score = sum(weight * min(count, cap))`. Sessions are flagged when
`score >= RETRO_THRESHOLD`.

### Why these weights

- **S1 alone (one match) does NOT trigger** (3.0 < 5.0). A single grumpy
  word should not be enough.
- **S1 twice triggers** (6.0). Two explicit rejects is a real signal.
- **S3 (one thrashing file) alone does NOT trigger** (2.5). Edit loops happen
  in healthy refactors.
- **S3 + S2** triggers (4.5+). Thrashing while errors compound is friction.
- **All weak signals together** (S4 + S5 capped) ≈ 8.5, which trips the gate
  only when retries and disengaged user turns both pile up.

The bar is intentionally "two independent signals or one very strong one."

### False-positive guards

System-injected `type=user` messages (`isMeta: true`) are skipped for S1 and
S5. Slash-command loads, skill instructions, and `<local-command-caveat>`
wrappers all arrive on the user channel and routinely contain words like
"stop", "don't", "wrong" inside plugin documentation. Without this guard the
gate trips on every session that loads a skill.

Tool-result blocks (which also live inside `type=user` messages) are never
treated as user input.

Clean draft-polish (Write-then-polish of a session-created path with no
intervening tool error or user rejection) is an intentional under-trigger:
those paths are fully exempt from S3, not merely discounted on the first Write.

## Calibration loop (`--why`)

`/retro --why` re-runs the gate and prints the signal table:

```
Session: <id>
Score: 5.5 / 5.0 (passed)
Signals matched:
  S1 (explicit reject) x2  — 00000000-0000-4000-8000-000000000004, 00000000-0000-4000-8000-000000000002
  S3 (edit loop)       x1  — 00000000-0000-4000-8000-000000000005
Signals NOT matched: S2, S4, S5
```

This is the only debugging surface. There is no telemetry. Tune weights and
regexes in `gate.sh` based on dogfood feedback — every constant is at the top
of the python block.

## Performance

The script makes a single pass over the JSONL with stateful per-turn tracking.
Measured on real sessions:

| Lines   | Size  | Wall time |
|---------|-------|-----------|
| 185     | 1.0M  | <50ms     |
| 689     | 1.4M  | <50ms     |
| 2808    | 7.1M  | ~50ms     |
| 3957    | 8.9M  | ~60ms     |

Well under the 2-second budget for 10k lines.

## Engine

`python3` is required. The per-turn state machine (sliding edit-window,
consecutive-error runs) requires it. If `python3` is absent the script
emits a JSON error verdict and exits 0.

## Schema-drift detection

If the gate processes a non-empty file and sees zero of the known top-level
JSONL fields (`type`, `uuid`, `message`, `parentUuid`, `sessionId`,
`timestamp`) in the first 50 lines, it writes a warning to stderr. Claude
Code's JSONL format is not a stable public API; this warning is the early
signal that field names changed and the gate needs updating.
