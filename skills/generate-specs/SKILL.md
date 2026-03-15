---
name: generate-specs
description: Reverse-engineer behavioral specs from existing source code. Reads the
  codebase, groups the public surface by domain, and writes MUST/SHOULD/MUST NOT specs
  from what the code actually does. All output is marked INFERRED and requires human
  review. Designed for legacy projects with no existing specs. Run once to establish a
  baseline, then use /reflect-specs to keep them current.
---

# Generate Specs

Establish a spec baseline for a project that has none. Reads the source code, infers
behavioral contracts from implementations (not just signatures), groups them into
domain-level specs, and writes them to `specs/core/`. All generated specs are marked
`Status: INFERRED` — they are a starting point, not ground truth.

## Arguments

- `/generate-specs` — full codebase scan, Tech Lead decides domain grouping
- `/generate-specs <path>` — limit scan to a specific package or directory

---

## Step 0: Detect project root and language

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

Detect language by checking for:
- `go.mod` → Go (`**/*.go`, exclude `*_test.go`, `vendor/`)
- `package.json` → TypeScript/JavaScript (`**/*.ts`, `**/*.tsx`, `**/*.js`, exclude `node_modules/`, `dist/`)
- `pyproject.toml` or `setup.py` → Python (`**/*.py`, exclude `__pycache__/`, `.venv/`)
- `Cargo.toml` → Rust (`**/*.rs`, exclude `target/`)
- `*.csproj` → C# (`**/*.cs`, exclude `bin/`, `obj/`)

Exclude always: `.claude/`, `specs/`, `skills/`, `commands/`, `*.md`, `*.json`, `*.yaml`,
`*.lock`, `*.sum`, generated files (`*.pb.go`, `*_gen.*`, `*_generated.*`).

If no language detected: ask the user what language/extensions to scan.

---

## Step 1: Check for existing specs

```bash
ls $MROOT/specs/ 2>/dev/null
```

If specs already exist, warn:

```
specs/ already contains N files. /generate-specs is designed for projects with no
existing specs.

Options:
  a) Continue — generate specs for areas NOT already covered (safe)
  b) Abort — use /reflect-specs to check alignment of existing specs instead

Proceed? (a/b)
```

If user chooses (b): stop and suggest `/reflect-specs`.
If user chooses (a): note which spec files already exist and skip those domains later.

---

## Step 2: Read all source files and build a surface map

Read every source file. For each file:

1. **Identify the module's responsibility** — 1–2 sentence summary of what it owns
2. **Collect the public surface**: all exported/public symbols:
   - Go: exported functions, types, interfaces, methods on exported types
   - TypeScript: exported functions, classes, interfaces, React components, API route handlers
   - Python: public functions, classes, methods (no leading `_`)
   - Rust: `pub fn`, `pub struct`, `pub trait`, `pub impl`
3. **Read the implementation** (not just the signature) — infer:
   - What inputs does it validate or reject?
   - What invariants does it enforce?
   - What side effects does it have (DB write, file I/O, network call, cache update)?
   - What does it return or mutate?
   - What error conditions does it handle?

Cap per-file reading at 300 lines. If a file exceeds this, read the first 300 lines and
note it was truncated — flag truncated files for manual review.

Skip test files — they inform specs but are not the source of truth.

Build a surface map:
```
Module: internal/cache/responses.go
  Purpose: SQLite-backed response cache keyed by (file_hash, model, prompt)
  Public surface:
    - GetResponse(hash, model, prompt) → (string, bool)      [read, cache hit/miss]
    - SetResponse(hash, model, prompt, response)              [write, upsert]
    - GetAllForFolder(folderPath) → []CachedAnalysis          [read, folder-scoped query]
    - CachedAnalysis{FilePath, Model, Prompt, Description, CachedAt}
  Inferred invariants:
    - MUST key on (hash, model, prompt) tuple — same image with different model = different entry
    - MUST NOT return partial responses (atomically written)
    - SHOULD handle concurrent reads without locking (SQLite WAL mode assumed)
```

---

## Step 3: Tech Lead groups surface into domains

```
@tech-lead You have a surface map of N modules across this codebase.
Group them into 8–15 domain-level feature areas suitable for one spec each.

Rules:
- One spec per cohesive domain (e.g. "Response Caching", "File Browser", "Analysis Queue")
- Avoid micro-specs (one function = one spec) and mega-specs (everything in one)
- If two modules share a tight contract, they belong in the same spec
- Name each domain clearly — the spec filename will be SPEC-NNN-<domain-slug>.md

Surface map:
<paste full surface map from Step 2>

Output: ordered list of domains, each with:
- Domain name
- Modules it covers
- 1-sentence scope description
```

Present Tech Lead's grouping to the user:

```
Tech Lead proposes N spec domains:

  1. Response Caching          — internal/cache/responses.go, cache/common.go
  2. Analysis Queue            — ui/fyne/analysis_queue.go, app/queue.go
  3. File Browser              — ui/fyne/filebrowser.go, services/directory/
  ...

Approve this grouping, or edit before we write specs? (approve / edit)
```

If user edits: apply their changes before proceeding.

---

## Step 4: Determine SPEC numbering

Check existing specs for the highest SPEC number:
```bash
ls $MROOT/specs/core/ 2>/dev/null | grep -oP 'SPEC-\K\d+' | sort -n | tail -1
```

Start from that number + 1 (or SPEC-001 if none exist).

Create `specs/core/` if it doesn't exist:
```bash
mkdir -p $MROOT/specs/core
```

---

## Step 5: Write one spec per domain

For each domain (in order), write `specs/core/SPEC-NNN-<domain-slug>.md`.

### Spec format:

```markdown
# SPEC-NNN: <Domain Name>

**Status**: INFERRED — generated by /generate-specs on <YYYY-MM-DD>. Requires human review.

**Covers**: <list of modules/files>

## Overview

<2–3 sentence description of what this domain does and why it exists>

## MUST

- MUST <behavioral requirement inferred from implementation>
- MUST <another requirement>
- MUST NOT <constraint — something the code actively rejects or prevents>
...

## SHOULD

- SHOULD <softer convention observed in the code>
...

## Open Questions

- [ ] <anything ambiguous — behavior that's in the code but intent is unclear>
- [ ] <edge case that's handled oddly — may be a bug or intentional>
...

## Cross-references

- <SPEC-NNN>: <why this domain interacts with that one>
...
```

### Rules for inferring MUST statements:

- If a function validates an input and returns an error → `MUST validate <X>`
- If a function writes to a store → `MUST persist <X> on <operation>`
- If a function checks a condition before proceeding → `MUST NOT allow <X> when <Y>`
- If retry/timeout logic exists → `MUST retry up to N times` / `MUST time out after N seconds`
- If a mutex or lock is used → `MUST be safe for concurrent access`
- If an interface is implemented → `MUST implement <InterfaceName> contract`
- Numeric constants (limits, timeouts, sizes) → express as `MUST NOT exceed N` / `MUST complete within N ms`

Do NOT invent requirements not evidenced in the code. When intent is unclear, put it in
**Open Questions**, not MUST.

Write all N specs before pausing — do not ask for confirmation between each one.

---

## Step 6: Write or update specs/TDD.md index

Read existing `specs/TDD.md` if present. If not, create it.

Add all generated specs to the index table:

```markdown
## Spec Index

| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | Response Caching | INFERRED | internal/cache/responses.go |
| SPEC-002 | Analysis Queue | INFERRED | internal/ui/fyne/analysis_queue.go |
...
```

Mark all new entries as `INFERRED`.

---

## Step 7: Print generation report

```
/generate-specs complete

Generated N specs in specs/core/:
  SPEC-001-response-caching.md        — 8 MUSTs, 2 SHOULDs, 1 open question
  SPEC-002-analysis-queue.md          — 12 MUSTs, 3 SHOULDs, 2 open questions
  SPEC-003-file-browser.md            — 6 MUSTs, 1 SHOULD, 0 open questions
  ...

Open questions requiring human review: N total
  SPEC-002: "Timeout behavior when Ollama is unreachable — is 2min intentional?"
  SPEC-005: "Sort order of files — alphabetical or mtime? Code does both in different places."
  ...

Truncated files (read partially — verify manually):
  internal/ui/fyne/app.go (847 lines — only first 300 read)

Next steps:
  1. Review each spec — correct any misattributed MUSTs
  2. Resolve open questions (edit specs directly or run /update-spec)
  3. Run /reflect-specs to verify the generated specs actually match the code
  4. Commit: git add specs/ && git commit -m "spec: establish baseline specs from /generate-specs"
  5. From now on: /kickoff <ticket> will find and use these specs automatically
```

---

## Error Handling

- **No source files found**: ask user to confirm the language/extensions to scan
- **File read fails** (permissions, binary): skip and note in report
- **Tech Lead grouping produces >20 domains**: ask user to consolidate — too many specs defeats the purpose
- **Tech Lead grouping produces <3 domains**: warn that grouping may be too coarse
- **Existing specs cover some domains**: skip those domains, only generate for uncovered areas
- **specs/core/ already has SPEC numbers that conflict**: start numbering after the highest existing number
- **No git repo**: use `pwd` as MROOT; warn that worktree-shared memory won't apply
