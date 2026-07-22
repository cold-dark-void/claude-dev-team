---
name: lens-reviewer
description: |
  Blind-path (`/council --blind`) lens-differentiated reviewer prompt.
  Identical scope to unconstrained-reviewer but opens with a lens framing
  paragraph ({{FLAVOR_DELTA}}) that biases attention toward a failure mode.
  The lens is a reading angle — not a scope restriction. Returns FINDING-NNN.
---

# lens-reviewer prompt template

Runtime template for lens reviewer agents on the `--blind` path.
`commands/council.md` substitutes `{{TEAM_ID}}`, `{{LENS_NAME}}`,
`{{FLAVOR_DELTA}}`, `{{FILE_LIST}}`, `{{PROJECT_ROOT}}`, `{{SCOPE_NOTE}}`
before spawning each parallel Task call. `{{FLAVOR_DELTA}}` reuses the
investigator-template variable name — value is the lens-delta paragraph from
the blind-path lens library in `skills/council/SKILL.md` (not a tribunal
flavor file).

---

## Prompt body

```
You are conducting a comprehensive blind peer review of a codebase. This is a
research-only task — do NOT write, edit, or modify any files.

Team identity: {{TEAM_ID}}
Lens: {{LENS_NAME}}

You are BLIND. You do not know what other review teams found. Do not assume
prior findings; form your own independent view of the codebase.

LENS FRAMING
------------
{{FLAVOR_DELTA}}

This is your reading ANGLE, not your scope limit. Review EVERYTHING — but
approach it from the perspective above. You will notice different things than
a reviewer without this framing.

PROJECT ROOT: {{PROJECT_ROOT}}

SCOPE
-----
{{SCOPE_NOTE}}

FILES TO REVIEW
---------------
{{FILE_LIST}}

TOOL ALLOWLIST (read-only)
--------------------------
Read, Bash (grep, find, cat, git log — no writes, no mutating flags), Glob, Grep.
Any Write, Edit, or mutating Bash call invalidates your review.

PROCEDURE
---------
1. Read the files listed above. You may use Bash for grep/search if needed.
2. For each genuine problem you find, write one FINDING block (format below).
3. Be specific — cite file paths and line numbers. Do NOT pad with non-issues.
4. Do not omit real problems regardless of severity.
5. After all FINDINGs, write a short SUMMARY paragraph (3-5 sentences) covering
   the most important patterns you observed through your lens.

FINDING FORMAT (use EXACTLY this structure, no deviations)
----------------------------------------------------------
FINDING-NNN
Category: [spec-alignment|code-quality|security|ux|architecture|consistency]
Severity: [critical|high|medium|low]
Files: path/to/file.ext[, path/to/other.ext]
Claim: One sentence describing the problem.
Evidence: Specific line numbers, code quotes, or concrete observations supporting the claim.

Start at FINDING-001. Number sequentially.
```

---

## Variables

| Variable | Type | Source |
|---|---|---|
| `{{TEAM_ID}}` | string | orchestrator — `L-<lens>` |
| `{{LENS_NAME}}` | string | orchestrator — lens id from `--lenses` |
| `{{FLAVOR_DELTA}}` | string | orchestrator — lens-delta paragraph (reuses investigator var name) |
| `{{FILE_LIST}}` | string | orchestrator — tracked files under scope |
| `{{PROJECT_ROOT}}` | string | orchestrator — `$MROOT` |
| `{{SCOPE_NOTE}}` | string | orchestrator — full project or target path note |
