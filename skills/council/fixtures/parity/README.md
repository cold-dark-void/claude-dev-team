# Council path parity fixtures (CDV-196)

Minimal fixtures for AC3 parity runs: same claim set through engine.sh Task path
and Workflow path (`skills/council/workflow.js` → `engine.sh finalize`).

## Fixtures

| File | Purpose |
|------|---------|
| `false-claim.json` | Known-false claim (expect FABRICATED / CONTRADICTED) |
| `true-claim.json` | True claim grounded in repo files |
| `mini-diff.patch` | Tiny staged-diff style input for finding[] path |

## Manual parity procedure

1. **Engine path (default):**
   ```bash
   /council "$(jq -r .claim skills/council/fixtures/parity/false-claim.json)"
   ```
2. **Workflow path (opt-in):**
   ```bash
   /council --workflow "$(jq -r .claim skills/council/fixtures/parity/false-claim.json)"
   # or: COUNCIL_WORKFLOW=1 /council "…"
   ```
3. Diff consumer-visible artifacts (normalize timestamps + path slugs):
   - judge JSON: verdict taxonomy + confidence
   - `.claude/council/index.json` row shape (`report_path`, max confidences, `created_at`)
   - report frontmatter + body sections (modulo timestamps)

Downstream (TaskCompleted gate, `/retro`) must not distinguish path.

## Fallback smoke (AC2)

```bash
COUNCIL_WORKFLOW=1 COUNCIL_WORKFLOW_FORCE_FALLBACK=1 /council "…"
# expect stderr: council: Workflow unavailable; falling back to engine.sh
# expect verification_mode: full (not degraded)
```

## Degradation smoke (AC6)

Inject failing investigator on Workflow path (host-level rate limit or mock
`agent` returning null) → finalize `--verification-mode self-verified` → report
contains exact marker from engine finalize (CDV-199).

## Resume (AC9)

Kill mid-run + resume is Workflow-native; if CI cannot kill/resume non-interactively,
manual QA only — do not fake resume in unit tests.
