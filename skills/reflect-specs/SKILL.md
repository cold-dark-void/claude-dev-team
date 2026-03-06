---
name: reflect-specs
description: Full-system health check — exhaustive code alignment across ALL specs (not sampled),
  cross-spec conflict detection, skill/command self-consistency, and coverage gaps. Presents
  each conflict class interactively and asks the user to confirm or resolve before proceeding.
  Use when you want a holistic audit of specs + skills + code with human sign-off.
---

# Reflect Specs

A deep, interactive health check of your spec/skill/code system. Goes beyond `/check-specs`
by covering all specs (not a sample), detecting inter-spec contradictions, auditing skill
documentation against reality, and pausing for user confirmation at each conflict class.

## Phases Overview

1. **Inventory** — collect all specs, skills, commands
2. **Cross-spec conflicts** — find specs that contradict each other
3. **Skill/command consistency** — skill docs describe what the code actually does
4. **Full code alignment** — every MUST in every spec checked against source
5. **Coverage gaps** — code areas with no spec, requirements with no code
6. **Interactive confirmation** — present findings, pause for user decisions

---

## Step 0: Detect project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && PROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || PROOT=$(pwd)
```

All paths below are relative to `$PROOT`.

---

## Phase 1: Inventory

Collect everything that will be inspected:

### 1a. Spec files
- `Glob specs/**/*.md` — collect all spec files
- Also check `specs/TDD.md` as an index
- If no spec files found: print `No specs found in specs/ — nothing to reflect` and stop

### 1b. Skills and commands
- `Glob skills/*/SKILL.md` — skill definition files
- `Glob commands/*.md` — command definition files
- Note: skills/commands are only checked if they exist; skip gracefully if `skills/` or `commands/` don't exist

### 1c. Source files
Detect project language:
- Check for `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `*.csproj`
- Glob the corresponding extensions (e.g., `**/*.go`, `**/*.ts`, `**/*.py`, `**/*.rs`)
- Exclude: `specs/`, `.claude/`, `node_modules/`, `dist/`, `vendor/`, `skills/`, `commands/`, `*.md`

Print inventory summary:
```
Inventory: N specs, M skills/commands, K source files
```

---

## Phase 2: Cross-Spec Conflict Detection

Read all spec files. For each pair of specs, look for contradictions in their MUST requirements.

### What to look for:

**BLOCKER** — direct contradiction:
- Spec A: `MUST store data in-memory only`
- Spec B: `MUST persist all data to disk`

**WARNING** — overlapping scope with potentially incompatible assumptions:
- Spec A: `MUST process requests synchronously`
- Spec B: `MUST handle concurrent requests`

**TERMINOLOGY** — same concept named differently (may indicate drift):
- Spec A uses "user session", Spec B uses "auth token" for what appears to be the same thing

### How to check:
1. For each spec, extract all MUST requirements as a flat list
2. For each other spec, compare requirements — look for logical contradictions or incompatible constraints
3. Flag terminology inconsistency: same domain terms (user, session, request, data, limit, timeout) appearing with different names for what seems to be the same concept

### Phase 2 Report Format:
```
## Phase 2: Cross-Spec Conflicts

### BLOCKERs (direct contradictions)
| Spec A | Requirement A | Spec B | Requirement B | Conflict |
|--------|--------------|--------|--------------|---------|
| SPEC-001 | MUST store in-memory | SPEC-005 | MUST persist to disk | Contradicts storage model |

### WARNINGs (scope overlap)
| Spec A | Spec B | Overlap description |
...

### Terminology Drift
| Term in Spec A | Term in Spec B | Likely same concept? |
...

Phase 2 summary: X BLOCKERs, Y WARNINGs, Z terminology issues
```

**PAUSE**: If BLOCKERs > 0, stop and ask the user:

> "Found [N] direct contradictions between specs. These must be resolved before code alignment
> is meaningful. For each BLOCKER above:
> - Which spec is correct?
> - Should the other spec be updated?
> - Or is the conflict intentional (e.g., different modes/configurations)?
>
> Please confirm how to proceed."

Wait for user response. If user resolves or confirms, continue. If user says "stop" or "fix first", stop and summarize what needs to be done.

---

## Phase 3: Skill/Command Consistency

For each skill/command file found in Phase 1:

### What to check:

**Description accuracy**: Does the frontmatter `description` field match what the skill
actually does? Read the full SKILL.md body and compare — are there steps described that
aren't mentioned in the description?

**Referenced paths**: Does the skill reference specific file paths, directories, or commands
that don't exist in the project?
- Extract paths like `specs/TDD.md`, `.claude/backlog.md`, `commands/*.md`, specific filenames
- `Glob` each to verify it exists

**Tool references**: Does the skill call tools (Grep, Glob, Read, Bash) with commands that
make sense for the current project structure?

**Inter-skill dependencies**: Does any skill reference another skill (e.g., "runs init first")?
If so, verify the referenced skill exists.

### Phase 3 Report Format:
```
## Phase 3: Skill/Command Consistency

### SPEC-001 (create-spec.md)
- ✅ Description matches body
- ⚠️ References `specs/core/` but no such directory found

### review-and-commit SKILL.md
- ✅ All referenced paths exist
- ✅ No inter-skill dependency issues

Phase 3 summary: X issues found across Y skills/commands
```

**PAUSE if issues > 0**: Ask user:

> "Found [N] skill/command consistency issues. Should we update the skill docs to match
> reality, or are these paths/references planned (not yet created)?"

---

## Phase 4: Full Code Alignment

Unlike `/check-specs` which samples 3–5 recent specs, this phase checks **every spec**.

For each spec:

### 4a. Extract all MUST requirements
Parse the spec file for all bullet points under `## MUST` sections, or lines starting with
`MUST` anywhere in the spec body.

### 4b. Derive search keywords
From each MUST requirement, extract:
- Specific **nouns**: feature names, data types, identifiers, module names
- **Verbs**: operations the system must perform
- **Numeric constraints**: timeouts, limits, counts, thresholds
- **Named identifiers**: function names, config keys, API endpoints

### 4c. Search source files
`Grep` source files using keywords (exclude: `specs/`, `.claude/`, `node_modules/`, `dist/`,
`vendor/`, `skills/`, `commands/`, `*.md`, `*.json`, `*.yaml`, `*.lock`).

### 4d. Classify each MUST requirement:
- **MATCH** — code clearly satisfies requirement; cite `file:~line`
- **MISSING** — no code found implementing this behavior
- **DIFFERS** — code exists but contradicts requirement; cite `file:~line` and explain

### 4e. Detect drift
Scan code in each feature area for behavior **not mentioned in the spec** → flag **UNDOCUMENTED**.

### Phase 4 Report Format:
```
## Phase 4: Full Code Alignment

| Spec | Requirement (truncated) | Status | Evidence |
|------|------------------------|--------|----------|
| SPEC-001 | MUST validate input... | MATCH | handler.go:~42 |
| SPEC-002 | MUST limit to 100ms... | DIFFERS | worker.go:~88 (no timeout) |
| SPEC-003 | MUST log all errors... | MISSING | — |

### Undocumented Behavior (Drift)
- SPEC-001: `cache.go:~210` implements retry logic not mentioned in spec

Phase 4 summary: X MATCH / Y MISSING / Z DIFFERS / N undocumented
```

If no source files exist (pure spec/docs project): skip Phase 4, note that.

---

## Phase 5: Coverage Gaps

Identify what is NOT covered by any spec by **reading every source file independently** —
not just checking keyword hits from Phase 4.

### 5a. Read all source files

For each source file collected in Phase 1:

1. **Read the file** (use the Read tool — full file, not grep)
2. **Summarize what it does**: in 1–3 sentences, describe the module's responsibility —
   what it exports, what operations it performs, what data it owns
3. **Collect public surface**: list all exported/public functions, types, structs, classes,
   API routes, CLI commands, event handlers, and background workers found in the file

Cap per-file reading at 300 lines; if a file exceeds this, read the first 300 lines and
note it was truncated. Skip generated files (`*.pb.go`, `*.gen.ts`, `*_generated.*`,
`vendor/**`, `dist/**`, `node_modules/**`).

### 5b. Map public surface to specs

For each item in the public surface collected above:
- Search all spec MUST requirements for any that describe this behavior
- Match on: function/type name, the operation it performs, the data it handles
- Classify each surface item as:
  - **COVERED** — at least one spec MUST describes or implies this behavior
  - **UNCOVERED** — no spec touches this behavior at all

### 5c. Dead requirements
Compile all MISSING items from Phase 4 into a single list — MUST requirements that have
no code evidence.

### 5d. Module summary table

Produce a table of every source file read, its one-sentence purpose, and coverage status:

```
## Phase 5: Coverage Gaps

### Module Summary

| File | Purpose (1-sentence) | Coverage |
|------|----------------------|----------|
| auth/middleware.go | JWT validation and request authentication | ⚠️ UNCOVERED |
| storage/store.go | Key-value persistence backed by BoltDB | ✅ COVERED (SPEC-003) |
| utils/retry.go | Exponential backoff retry helper | ⚠️ UNCOVERED |
| api/handler.go | HTTP handlers for /api/v1/* routes | ✅ COVERED (SPEC-001, SPEC-002) |

### Uncovered public surface

| File | Symbol | Type | Description |
|------|--------|------|-------------|
| auth/middleware.go | ValidateToken | func | Validates JWT and sets user context |
| auth/middleware.go | RefreshHandler | http.Handler | Handles token refresh requests |
| utils/retry.go | WithBackoff | func | Retries fn up to N times with exponential backoff |

### Dead requirements (MUST with no code):
- SPEC-003: MUST log all errors to structured logger
- SPEC-007: MUST enforce rate limit of 100 req/s

Phase 5 summary: X files read, Y modules COVERED, Z UNCOVERED, N dead requirements,
M unspecified public symbols
```

If no source files exist (pure spec/docs project): skip Phase 5, note that.

---

## Phase 6: Interactive Confirmation

After all phases complete, present a consolidated summary and ask the user to confirm or take action:

```
## Reflection Summary

| Phase | Finding | Count |
|-------|---------|-------|
| Cross-spec BLOCKERs | Direct contradictions | X |
| Cross-spec WARNINGs | Scope overlap | Y |
| Terminology drift | Inconsistent naming | Z |
| Skill/command issues | Path/description mismatches | A |
| Code alignment MATCH | Requirements satisfied | B |
| Code alignment MISSING | No implementation found | C |
| Code alignment DIFFERS | Implementation contradicts spec | D |
| Undocumented behavior | Drift detected | E |
| Coverage gaps | Uncovered files/features | F |
```

Then ask:

> "What would you like to do with these findings?
>
> **Suggested actions:**
> 1. Fix DIFFERS items (code contradicts spec) — update code or spec?
> 2. Address MISSING items — implement or remove from spec?
> 3. Document UNDOCUMENTED behavior — add to spec or remove from code?
> 4. Resolve BLOCKER conflicts — which spec wins?
> 5. Update skill docs for consistency issues
>
> You can also say 'fix all' to address everything, 'skip X' to skip a category,
> or 'just the report' if you want findings without action."

Act on user's response:
- For each selected category, work through items one at a time
- For each item: propose the fix, confirm with user, apply it
- Update specs, skills, or note code changes needed
- After applying fixes, confirm: "Fixed: [item]. Continue?"

---

## Usage Examples

```
/reflect-specs              # Full reflection — all phases, interactive
/reflect-specs --report     # Report only — skip Phase 6 interactive loop
/reflect-specs --phase 2    # Run only Phase 2 (cross-spec conflicts)
/reflect-specs --phase 4    # Run only Phase 4 (full code alignment)
```

---

## Relationship to Other Commands

| Command | Scope | Coverage | Interactive? |
|---------|-------|----------|-------------|
| `/check-specs` | Format + alignment | 3–5 recent specs sampled | No |
| `/check-specs SPEC-XXX` | Single spec validation | One spec | No |
| `/review-and-commit` | Pre-commit review | Staged/modified files | No |
| `/reflect-specs` | Full system health | ALL specs + skills | **Yes** |
