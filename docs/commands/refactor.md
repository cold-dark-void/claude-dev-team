# /refactor

Design-first code restructuring that preserves observable behavior. Before any file is touched, the design problem is written down; when test coverage is thin, characterization tests are written and confirmed passing on the original code; and after the change, the full suite must pass with zero observable behavior change. Use `/refactor` to improve internal structure (extract, rename, decouple, deduplicate) — use [`/debug`](debug.md) to fix incorrect behavior.

## Usage

```
/refactor <description>
/refactor inline <description>
/refactor
```

## Subcommands

| Form | Description |
|------|-------------|
| `/refactor <description>` | Default mode. Enforces the full sequence: design problem statement (hard gate) → approach decision → coverage check (gate) → implement → validate → self-calibration checklist. |
| `/refactor inline <description>` | Inline mode. For handoff from [`/debug`](debug.md) (scope=refactor-first) or `/orchestrate`, where the approach is already decided. Skips the design-problem and approach-decision steps; keeps the coverage check and validation. |
| `/refactor` | No description. Prompts: "What is the area or change to refactor?" then proceeds in default mode. |

**Parser rule:** if the first token is exactly `inline` (case-sensitive), it selects inline mode and the remainder is the description; otherwise the whole argument is the description in default mode. A description that legitimately starts with the word "inline" is ambiguous — rephrase it.

## Examples

**Default — extract a duplicated validation block:**
```
/refactor extract credential validation out of auth/handler.go
```
The session first prints the design problem (no file is edited before this appears):
```
Design problem: auth/handler.go HandleLogin performs parsing, validation,
session creation, and audit logging in one 180-line body (1). The validation
block is duplicated in HandleSignup, HandleReset, HandlePasswordChange —
duplication smell — and its test must build a full HTTP request — coupling
smell (2). Refactored design extracts validation into
auth/validate.go:ValidateCredentials(Credentials) error (3).
```
Coverage is checked next. If tests near the affected path are thin, characterization tests are written and confirmed passing on the original code before any edit:
```
Coverage: thin — wrote auth/validate_test.go (4 cases).
PASS on ORIGINAL code. Proceeding to implement.
```

**Inline — approach already decided upstream:**
```
/refactor inline extract validation from auth/handler.go per /debug handoff
```
Skips the design-problem gate; states the approach in one sentence, then runs the coverage check and validation:
```
Inline refactor: extracting validation from auth/handler.go HandleLogin into
auth/validate.go:ValidateCredentials per upstream /debug handoff.
```

**Validation and completion** — after the change, the full suite runs and the no-change claim is made explicit, followed by the self-calibration checklist:
```
All tests pass (12 pre-existing + 4 characterization).
No observable behavior was changed in this refactor.

Self-calibration checklist:
  [x] Design problem written before any file was edited (default mode)
  [x] Characterization tests written and passing on original code
  [x] All tests pass after refactor
  [x] No feature or bug-fix changes mixed into this refactor
```
If any test needs its expected output updated, the workflow stops: a behavioral diff means the change is a bug or feature, not a refactor, and it is routed to [`/debug`](debug.md) or `/kickoff` via the escalation handoff format.

## See Also

- [`/debug`](debug.md) — fix incorrect behavior; hands off to `/refactor inline` when the fix is purely structural
- [`/orchestrate`](orchestrate.md) — full lifecycle orchestrator; may dispatch a refactor as an isolated step
- [`/kickoff`](kickoff.md) — planning phase for refactors that exceed inline scope (cross-directory or architectural)
