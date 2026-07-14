# /fix-ticket

Premise → implement → adversarial refuters for a **known** bug ticket. Verifies
the bug still exists, applies the smallest fix in a SPEC-016 worktree, spawns
parallel qa refuters, and writes a report. **Never commits, never bumps
versions, never calls `/release`.**

Governing spec: [SPEC-028](../../specs/core/SPEC-028-fix-ticket-workflow.md).
Protocol: `skills/fix-ticket/SKILL.md`.

## Usage

```
/fix-ticket <ticket-id> "<bug/premise>"
/fix-ticket CDV-42 "off-by-one in pagination offset" --fix "clamp offset to >= 0"
/fix-ticket AUDIT-P0.8 "migrate-v3 corrupts CURRENT_VERSION" --agent ic5 --lenses correctness,completeness
/fix-ticket CDV-42 "X is wrong" --worktree /path/to/.worktrees/CDV-42
```

## Flags

| Flag / argument | Required | Default | Description |
|-----------------|----------|---------|-------------|
| `<ticket-id>` | Yes | — | Ticket id used for worktree slug + report name |
| `"<bug/premise>"` | Yes | — | Documented bug description |
| `--fix "<instructions>"` | No | (empty / premise-only) | Explicit fix instructions for implementer |
| `--agent ic4\|ic5` | No | `ic4` | Implementer agent |
| `--lenses a,b` | No | `correctness,completeness` | Comma-separated adversarial lenses |
| `--worktree <path>` | No | `worktree-lib.sh ensure <ticket-id>` | Existing worktree path |

Missing required args → usage error; no agents spawn.

## Phases

1. **Verify-premise (ic5, read-only)** — confirm bug still present; sibling grep.
   If `holds=false` → hard stop + report; no implement/refute.
2. **Implement (ic4/ic5)** — smallest patch in worktree; no version files; no git
   commit/add/checkout/reset; draft one changelog bullet for the caller.
3. **Adversarial-verify (qa × N)** — one refuter per lens in parallel. Prefer
   read-only; bite-tests restore via `cp` backup / sed-reverse only —
   **never** `git checkout` / `git restore` / `git reset`.
4. **Orchestrator review + report** — synthesize `all_hold`; write
   `.claude/fix-ticket/<YYYY-MM-DD>-<ticket-id>.md`.

## Spawn-failure degradation

If any refuter is unusable (rate-limit, empty, refusal), the **orchestrator**
self-verifies missing lenses with real tools. Actor is never the implementer.
Report includes the exact marker:

```
> **self-verified — refuters unavailable**
```

Frontmatter sets `verification_mode: self-verified`. Protocol home:
`skills/council/SKILL.md` § Spawn-failure degradation (CDV-199) — do not invent
a second string.

## Report frontmatter

```yaml
ticket: <id>
worktree: <path>
premise_holds: true|false
all_hold: true|false
verification_mode: full|self-verified
created_at: <ISO-8601 UTC>
```

## Distinct from

| Command | Use when |
|---------|----------|
| `/debug` | Root cause unknown; need investigation discipline first |
| `/orchestrate` | Full ticket lifecycle through PR |
| `/council` | Pure audit of a claim/session/diff (no implement) |
| `/review-and-commit` | Review uncommitted/staged diff and optionally commit |

## Next steps after a run

1. `cd <worktree> && git diff`
2. Address failed lenses if `all_hold=false`
3. Optional: `/review-and-commit`
4. When ready: commit, then `/release` (caller owns version)

## Adjacent

- **CDV-196** — council Workflow re-platform (out of scope here).
- **CDV-199** — shared spawn-failure marker/actor rule.
- Optional reference Workflow: `skills/fix-ticket/workflow.js` (markdown path
  is authoritative; args-as-JSON-string guard documented for Workflow authors).
