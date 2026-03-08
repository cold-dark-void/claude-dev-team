# Runbook: Linear Ticket → Production

End-to-end workflow for implementing and shipping a Linear ticket using the claude-dev-team plugin.

---

## Prerequisites

- Claude Code with `dev-team` plugin installed
- Project already bootstrapped (`/init-team` run at least once)
- Orchestration bootstrapped (`/init-orchestration` run at least once — enables
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, wires the `TaskCompleted` quality-gate hook,
  and updates `AGENTS.md` with team coordination rules). Safe to re-run.
- Linear ticket assigned to you and in **In Progress**

---

## Phase 0 — First Time Only: Establish Spec Baseline (Legacy Projects)

Skip this phase if your project already has a `specs/` directory.

If you're starting this workflow on a project with no specs — a 2-year-old codebase,
an inherited repo, a project that grew without TDD — run this once before your first
ticket to establish a baseline:

```bash
# 1. Bootstrap agents and orchestration (if not done)
/init-team
/init-orchestration

# 2. Reverse-engineer specs from the existing codebase
/generate-specs
```

`/generate-specs` will:
- Read every source file and map the public surface by module
- Ask Tech Lead to group modules into 8–15 domain-level feature areas
- Write one `MUST/SHOULD/MUST NOT` spec per domain in `specs/core/`
- Mark all output `Status: INFERRED — requires human review`
- Flag open questions where intent is ambiguous
- Write a `specs/TDD.md` index

After it runs:
1. Review each generated spec — correct misattributed MUSTs, resolve open questions
2. Run `/reflect-specs` to verify the specs actually match the code
3. Commit:
   ```bash
   git add specs/
   git commit -m "spec: establish baseline specs from /generate-specs"
   ```

From this point on the normal per-ticket workflow applies. `/kickoff` will find and
reference the generated specs automatically when planning new tickets.

> **Note**: Generated specs describe *what the code does*, not necessarily *what it should
> do*. Treat them as a hypothesis — review before treating any MUST as authoritative.

---

## Phase 1 — Ticket Intake

### 1.1 Read the ticket

Open the Linear ticket. Collect:
- Ticket ID (e.g. `ENG-123`)
- Title and description
- Acceptance criteria
- Linked designs, specs, or dependencies

### 1.2 Orient yourself

```bash
# Confirm you're on main and up to date
git checkout main && git pull

# Check project memory for relevant context
cat .claude/memory/claude/memory.md
cat .claude/memory/tech-lead/cortex.md   # architecture decisions
cat .claude/memory/pm/cortex.md          # product context
```

### 1.3 Check existing specs for the feature area

```bash
ls specs/
```

Look for specs that cover the area this ticket touches. Read any relevant ones before planning — they constrain your design.

If no `specs/` directory exists, run `/generate-specs` first (see Phase 0) to establish
a baseline before planning this ticket.

### 1.4 Create a worktree for this ticket

```bash
git worktree add ../project-ENG-123 -b feat/ENG-123-short-description
cd ../project-ENG-123
```

---

## Phase 2 — Planning

### 2.1 Parallel kickoff — PM and Tech Lead simultaneously

Don't wait for PM to finish before Tech Lead starts reading. Fire both in parallel:

```
@pm Review Linear ticket ENG-123: <paste ticket text>
Confirm acceptance criteria, flag ambiguities. SendMessage to @tech-lead when done.
```

```
@tech-lead Orient on ENG-123 in parallel with @pm's review.
Read .claude/memory/tech-lead/cortex.md, relevant specs, and any files the ticket touches.
Wait for @pm's SendMessage with confirmed ACs before writing the plan.
```

Both agents load context simultaneously. Tech Lead waits for PM's clarifications before
committing to a design, so no rework from scope changes discovered later.

Resolve any open PM questions before proceeding.

### 2.2 Ask Tech Lead to produce a plan and task graph

Once PM has confirmed ACs:

```
@tech-lead Plan implementation for ENG-123.
<paste PM's confirmed ACs>
Output:
1. Step-by-step plan saved to .claude/plans/YYYY-MM-DD-ENG-123.md
2. Task graph: which steps can run in parallel, which have dependencies
3. For each step: recommended agent (ic4 vs ic5) and estimated complexity
```

```bash
mkdir -p .claude/plans
# Tech Lead writes to .claude/plans/YYYY-MM-DD-ENG-123.md
```

### 2.3 Write or update specs (spec-first)

Before writing code, specs for the affected area should exist and be current.

**If a spec already covers this area** — read it, then check if the ticket changes any requirements:
```
@tech-lead Review specs/<relevant-spec>.md against ENG-123.
Does the ticket require any changes to the spec? If so, update it now.
```

**If no spec exists for this area** — write one now, not after:
```
@tech-lead Write a spec for <feature area> based on ENG-123 and existing codebase patterns.
Save to specs/<name>.md. Use MUST/SHOULD/MUST NOT language for requirements.
```

Commit the spec on its own before touching implementation:
```bash
git add specs/
git commit -m "spec: ENG-123 — add/update <feature area> spec"
```

> Writing the spec first forces ambiguity out before you're deep in code.

### 2.4 Sanity-check the plan

Review `.claude/plans/YYYY-MM-DD-ENG-123.md`. Ask yourself:
- Is scope bounded? If not, push back to PM.
- Any migrations or schema changes? Flag to DevOps.
- Any new external dependencies? Review security implications.
- Does the plan contradict any MUST in the spec? Resolve now.

### 2.5 Tech Lead creates the task graph

After you approve the plan, Tech Lead registers tasks so agents can self-coordinate:

```
@tech-lead Create tasks for ENG-123 based on the approved plan.
Use TaskCreate for each step. Set dependencies in the description.
Mark yourself as orchestrator — you'll monitor via TaskList and unblock agents.
```

Tech Lead will issue calls like:
```
TaskCreate: "ENG-123 Step 1 — cache layer (GetAllForFolder)" → owner: unassigned
TaskCreate: "ENG-123 Step 2 — export package (Exporter interface + impls)" → owner: unassigned
TaskCreate: "ENG-123 Step 3 — UI wiring (ExportDescriptions handler)" → blocked by: Step 1, Step 2
TaskCreate: "ENG-123 Step 4 — QA acceptance tests" → can start after Step 2 interface is defined
```

Tasks are now visible to all agents via `TaskList`. IC agents claim work by setting
`owner` on a task before starting (`TaskUpdate`).

---

## Phase 3 — Implementation

### 3.1 IC agents claim and work in parallel

Independent steps run simultaneously. Agents self-assign by calling `TaskUpdate` to
claim ownership before starting — this prevents two agents picking up the same task.

**IC4** claims and works on Step 1 (well-defined, extending existing patterns):
```
@ic4 Check TaskList for ENG-123. Claim Step 1 (cache layer) via TaskUpdate.
Implement GetAllForFolder in internal/cache/responses.go. TDD — tests first.
When done: TaskUpdate status=completed, then SendMessage to @tech-lead.
```

**IC5** claims and works on Step 2 (new system, novel design) simultaneously:
```
@ic5 Check TaskList for ENG-123. Claim Step 2 (export package) via TaskUpdate.
Design Exporter interface and implement CSV/JSON/Markdown exporters. TDD.
When the interface is defined (before full impl), SendMessage to @ic4 with the
CachedAnalysis struct definition so IC4 can verify the cache layer matches.
When done: TaskUpdate status=completed, SendMessage to @tech-lead.
```

**QA** starts writing acceptance tests in parallel after the interface is defined:
```
@qa Check TaskList for ENG-123. Claim Step 4 (acceptance tests) via TaskUpdate.
Read SPEC-026 and the Exporter interface from IC5's SendMessage.
Write acceptance tests for all ACs now — don't wait for UI wiring to finish.
When done: TaskUpdate status=completed.
```

Steps 1, 2, and 4 all execute concurrently. Step 3 (UI wiring) starts only after
Steps 1 and 2 are both marked completed.

### 3.2 Tech Lead monitors and unblocks

Tech Lead polls periodically and intervenes if agents get stuck:

```
@tech-lead Check TaskList. Summarize status of all ENG-123 tasks.
If any agent is blocked, read their context.md and unblock them.
```

Agents signal blockers by updating their task description or via `SendMessage` to Tech Lead.

### 3.3 Step 3 unblocks after Steps 1+2 complete

Once IC4 and IC5 both mark their tasks completed, Tech Lead signals IC4 to continue:

```
@tech-lead Steps 1 and 2 are both done. Assign Step 3 (UI wiring) to IC4 via TaskUpdate.
SendMessage to @ic4 with confirmation to start.
```

```
@ic4 Check TaskList. Claim Step 3 (UI wiring) via TaskUpdate.
Wire ExportDescriptions() handler using the cache layer and export package.
File menu entry in components.go, handler in app.go.
When done: TaskUpdate status=completed, SendMessage to @tech-lead.
```

### 3.4 Track progress

Each IC agent writes context to `.claude/memory/<agent>/context.md` in the worktree.
Check when resuming a session:

```bash
cat .claude/memory/ic4/context.md
cat .claude/memory/ic5/context.md
```

---

## Phase 4 — Quality Gate

### 4.1 QA final validation

QA already wrote acceptance tests in Phase 3 Step 4. Now that all implementation is
complete, QA runs a final full validation:

```
@qa All ENG-123 implementation is done. Run full validation:
- Execute the acceptance test suite you wrote in Step 4
- Run go test ./... to confirm no regressions
- Check each AC in SPEC-026 against the implementation
- Flag anything that doesn't pass
TaskUpdate your task to completed when done.
```

QA agent will:
- Run the test suite (including the pre-written acceptance tests)
- Check coverage
- Flag failing tests or missing cases

Fix all issues before proceeding.

### 4.2 Spec alignment check

Verify the implementation actually satisfies the spec you wrote in Phase 2:

```
/reflect-specs --phase 4
```

This checks every MUST requirement in every spec against the source. Fix anything marked **MISSING** or **DIFFERS** before proceeding.

For a lighter check on just the spec you touched:
```
@qa Check that the implementation satisfies every MUST in specs/<name>.md.
Cite file:line evidence for each requirement.
```

If the implementation intentionally diverges from the spec, **update the spec** — don't leave them out of sync.

### 4.3 Review and commit

```
/review-and-commit
```

This runs a brutal honest review of all staged changes. It will:
- Check for bugs, security issues, over-engineering
- Block commit on critical issues
- Produce a review report

Address all critical/high findings. Cosmetic findings are at your discretion.

### 4.4 Commit

After review and spec alignment pass, commit:

```bash
git add <files>
git commit -m "feat: ENG-123 — <short description>

<1-2 sentence summary of what and why>

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Phase 5 — Pull Request

### 5.1 Push branch

```bash
git push -u origin feat/ENG-123-short-description
```

### 5.2 Open PR

```bash
gh pr create \
  --title "feat: ENG-123 — <short description>" \
  --body "$(cat <<'EOF'
## Linear ticket
ENG-123: <title>

## What changed
- <bullet>
- <bullet>

## Acceptance criteria
- [ ] <criterion 1>
- [ ] <criterion 2>

## Test plan
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual smoke test on staging

## Notes
<anything reviewers should know>
EOF
)"
```

### 5.3 Link PR to Linear

In Linear: open ENG-123 → attach the GitHub PR URL.
Move ticket to **In Review**.

---

## Phase 6 — Review & Merge

### 6.1 Address review feedback

For each review comment, either:
- Fix it (commit to the same branch)
- Explain why it's not needed (reply in PR)

Re-run `/review-and-commit` after significant changes.

### 6.2 Merge

Once approved and CI green:

```bash
gh pr merge --squash --delete-branch
```

Move Linear ticket to **Done**.

---

## Phase 7 — Production Delivery

### 7.1 Post-merge verification

```bash
git checkout main && git pull

# Confirm your commit is in main
git log --oneline | head -5
```

### 7.2 Deploy (adapt to your stack)

**If auto-deploy on merge to main:**
Monitor CI/CD pipeline. Check deployment logs.

**If manual deploy:**
```bash
# Example — adapt to your deploy tooling
./scripts/deploy.sh production
```

**If release tag needed:**
```
/release patch   # or minor/major
```

This bumps version, commits, tags, and pushes.

### 7.3 Smoke test in production

Verify the acceptance criteria from the ticket are met in prod:
- Check the feature works end-to-end
- Check monitoring/dashboards for error spikes
- Check logs for unexpected warnings

### 7.4 Ask DevOps agent if anything looks wrong

```
@devops Deployment for ENG-123 is live. Here are the logs: <paste>
Anything to worry about?
```

---

## Phase 8 — Wrap-up

### 8.1 Clean up worktree

```bash
cd ../project
git worktree remove ../project-ENG-123
```

### 8.2 Run full spec reflection (periodic — not every ticket)

After several tickets, or before a release, run a full system health check:

```
/reflect-specs
```

This finds: cross-spec contradictions, code that diverges from any spec, and public symbols with no spec coverage at all. Interactive — it will ask you what to fix.

Do this at minimum before every minor/major version bump.

### 8.3 Update project memory (if you learned something)

```bash
# Add any architectural insight or gotcha discovered during this ticket
echo "\n## ENG-123 learnings\n<insight>" >> .claude/memory/claude/memory.md
```

### 8.4 Close out

- Linear ticket: mark **Done** / move to **Released** column
- Notify stakeholders if needed
- Update any runbook or docs affected by the change

---

## Quick Reference

| Phase | Key command |
|-------|-------------|
| Baseline specs (legacy, once) | `/generate-specs` → review → `/reflect-specs` → commit |
| Bootstrap (once) | `/init-orchestration` |
| Orient | `cat .claude/memory/claude/memory.md` |
| Check specs | `ls specs/` + read relevant ones |
| Write/update spec | `@tech-lead Write spec for <area>` → commit before coding |
| Parallel kickoff | `@pm` + `@tech-lead` simultaneously; PM SendMessage to Tech Lead |
| Plan + task graph | `@tech-lead Plan + TaskCreate for each step` |
| Implement (parallel) | IC4 + IC5 `TaskUpdate` to claim; IC5 `SendMessage` interface to IC4 |
| Monitor | `@tech-lead Check TaskList — unblock agents` |
| QA pre-write tests | `@qa Claim Step 4 via TaskUpdate; write tests from spec + interface` |
| QA final validate | `@qa Run full validation, TaskUpdate completed` |
| Spec alignment | `/reflect-specs --phase 4` |
| Review | `/review-and-commit` |
| PR | `gh pr create` |
| Release | `/release patch` |
| Full health check | `/reflect-specs` (periodic, before releases) |

---

## Escalation

| Situation | Action |
|-----------|--------|
| Scope unclear | Ping PM; do not guess |
| Architecture uncertain | `@tech-lead` before writing code |
| CI failing unexpectedly | `@devops` with logs |
| Tests failing you can't explain | `@ic5` to debug |
| Prod incident post-deploy | Roll back first, investigate second |

---

## Appendix — Full CLI Walkthrough: POC-123

End-to-end example using a real feature: **POC-123 — Batch export analyzed descriptions**.

**Context**: `describer` is a Go desktop app that uses a local Ollama LLM to generate descriptions
for images. Users have requested a way to export all cached descriptions to CSV/JSON/Markdown for
use in ML training datasets. The analysis queue already exists; this ticket adds the export layer.

**Ticket text**:
> POC-123: Batch Export Descriptions
> As a user, I want to export all analyzed image descriptions to a file (CSV, JSON, or Markdown)
> so I can use them as training data captions or share them with teammates.
> AC1: Export all completed analyses from the current folder to CSV, JSON, or Markdown
> AC2: Each row/entry includes: file path, model, prompt, description, timestamp
> AC3: User chooses format and output path via a dialog
> AC4: Export is available from the File menu

---

### Step 1 — Open Claude Code in the project

```
$ cd ~/vibes/describer
$ claude
```

```
> Welcome to Claude Code. Type / for commands, @ to mention agents.
```

---

### Step 2 — Orient: check memory and agents

```
> Read .claude/memory/claude/memory.md and AGENTS.md to orient yourself.
  I have a Linear ticket POC-123 to implement. I'll share it after you've loaded context.
```

```
  Reading .claude/memory/claude/memory.md...
  Reading AGENTS.md...

  Context loaded. Key points from memory:
  - Response cache uses SQLite via internal/cache/responses.go (GetResponse/SetResponse)
  - Analysis queue lives in internal/ui/fyne/analysis_queue.go
  - Two UI backends: Fyne (primary) and Gio (experimental)
  - All UI updates must go through fyne.Do() for thread safety
  - Specs live in specs/core/ — each has a SPEC-NNN prefix

  Ready. Share the ticket.
```

---

### Step 3 — Parallel kickoff: PM reviews scope + Tech Lead orients simultaneously

Fire both agents at once — no waiting.

```
> @pm Review POC-123:
  "As a user, I want to export all analyzed image descriptions to a file (CSV, JSON, or Markdown)
  so I can use them as training data captions or share them with teammates.
  AC1: Export all completed analyses from current folder to CSV, JSON, or Markdown
  AC2: Each entry includes: file path, model, prompt, description, timestamp
  AC3: User chooses format and output path via a dialog
  AC4: Export is available from the File menu
  Confirm ACs, flag ambiguities. SendMessage to @tech-lead when you have confirmed ACs."
```

```
> @tech-lead Orient on POC-123 in parallel with @pm's review.
  Read your cortex.md, SPEC-008 (response caching), SPEC-012 (file browser).
  Identify files that will be affected. Wait for @pm's SendMessage with confirmed ACs
  before producing a plan.
```

```
  @pm reviewing POC-123...

  ACs confirmed. Flagging two ambiguities:
  1. "Current folder" — recommend: folder currently open in file browser only (scoped MVP).
  2. "Completed analyses" — recommend: all model+prompt combos per file (cache keys on hash+model+prompt).

  Suggested AC revisions:
  - AC1: Export all completed analyses for images in the currently open folder
  - AC2: Each entry: relative file path, model, prompt, description, exported_at timestamp
  - AC5 (new): Informative message if no completed analyses exist for the current folder

  SendMessage → @tech-lead: "ACs confirmed for POC-123. Current folder only.
  All model+prompt combos per file. 5 ACs. Ready for you to plan."
```

```
  @tech-lead received PM's message.

  Orientation complete while PM was reviewing:
  - internal/cache/responses.go — cache layer, needs GetAllForFolder query
  - internal/ui/fyne/components.go — File menu, needs new menu item
  - internal/ui/fyne/app.go — App handler, needs ExportDescriptions()
  - No existing spec covers export — SPEC-026 needed

  Ready to plan with confirmed ACs.
```

```
> Approved. Use revised ACs.
```

---

### Step 4 — Check existing specs

```
> List specs/core/ and tell me which ones are relevant to POC-123.
```

```
  Globbing specs/core/...

  Relevant specs:
  - SPEC-008-response-caching.md  — defines the cache contract (GetResponse, hash keying)
  - SPEC-007-image-analysis.md    — analysis lifecycle, completed state definition
  - SPEC-012-file-browser.md      — current folder concept, how files are loaded

  No existing spec covers export. We'll need a new one (SPEC-026).
```

---

### Step 5 — Write spec first (before any code)

```
> @tech-lead Write a spec for the batch export feature (SPEC-026) based on POC-123 ACs
  and the existing cache/file-browser architecture. Save to specs/core/SPEC-026-batch-export.md.
  Use MUST/SHOULD/MUST NOT language. Cross-reference SPEC-008 for cache access.
```

```
  @tech-lead reading SPEC-008, SPEC-007, SPEC-012...
  Writing specs/core/SPEC-026-batch-export.md...

  Created specs/core/SPEC-026-batch-export.md:

  # SPEC-026: Batch Export Descriptions

  Status: NEW

  ## Scope
  Export all completed analyses for images in the currently open folder.

  ## MUST
  - MUST read completed analyses from the response cache (per SPEC-008 GetResponse contract)
  - MUST export to one of three formats: CSV, JSON, Markdown
  - MUST include per-entry fields: relative_path, model, prompt, description, exported_at
  - MUST present a format-selection + file-path dialog before writing
  - MUST be accessible from the File menu
  - MUST NOT export analyses from other folders (scope = current folder only)
  - MUST NOT overwrite an existing file without confirmation
  - MUST show an informative message if no completed analyses exist for the current folder

  ## SHOULD
  - SHOULD open the containing folder in the OS file manager after export

  ## Format specs
  CSV:      header row + one row per analysis
  JSON:     array of objects, one per analysis
  Markdown: ## <filename> heading per file, description as body, metadata in italic footer

  ## Cross-references
  - SPEC-008: cache access pattern (responseCache.GetAllForFolder)
  - SPEC-012: current folder state (app.currentFolder)
```

```
> Good. Commit the spec before we touch any code.
```

```
  Staging specs/core/SPEC-026-batch-export.md...

  $ git add specs/core/SPEC-026-batch-export.md
  $ git commit -m "spec: POC-123 — add SPEC-026 batch export descriptions"
  [feat/POC-123-batch-export 3a8f1c2] spec: POC-123 — add SPEC-026 batch export descriptions
```

---

### Step 6 — Create worktree

```
> Create a worktree for POC-123.
```

```
  $ git worktree add ../describer-POC-123 -b feat/POC-123-batch-export
  Preparing worktree (new branch 'feat/POC-123-batch-export')
  HEAD is now at 3a8f1c2 spec: POC-123 — add SPEC-026 batch export descriptions

  Worktree ready at ../describer-POC-123. Switch there to continue.
```

```
> (switching terminal to ../describer-POC-123)
  cd ../describer-POC-123
```

---

### Step 7 — Tech Lead produces plan and creates task graph

```
> @tech-lead Plan the implementation of SPEC-026 (batch export).
  Key constraints:
  - Cache access via internal/cache/responses.go
  - Fyne UI only (ignore Gio backend for now)
  - Export logic in its own package
  Output:
  1. Step-by-step plan → .claude/plans/2026-03-07-POC-123-batch-export.md
  2. Task graph with parallel/sequential relationships
  3. Create tasks via TaskCreate for each step
```

```
  @tech-lead reading internal/cache/responses.go, internal/ui/fyne/components.go,
  internal/ui/fyne/app.go...

  Plan saved to .claude/plans/2026-03-07-POC-123-batch-export.md

  Task graph:
  ┌─ Task 1: Cache layer (GetAllForFolder)      → IC4  ─┐
  │                                                       ├─→ Task 3: UI wiring
  └─ Task 2: Export package (Exporter + impls)  → IC5  ─┘
       └─ (interface defined early)
            └─→ Task 4: QA acceptance tests      → QA   (can start after interface defined)

  Tasks 1 and 2 are independent — start them in parallel.
  Task 3 blocked by Tasks 1 and 2.
  Task 4 can start as soon as IC5 defines the Exporter interface (doesn't need full impl).

  Creating tasks via TaskCreate...

  TaskCreate → id:1 "POC-123 Task 1 — cache layer (GetAllForFolder)" status:pending owner:unassigned
  TaskCreate → id:2 "POC-123 Task 2 — export package (Exporter+impls)" status:pending owner:unassigned
  TaskCreate → id:3 "POC-123 Task 3 — UI wiring (ExportDescriptions handler)" status:pending blocked_by:[1,2]
  TaskCreate → id:4 "POC-123 Task 4 — QA acceptance tests" status:pending note:"start after IC5 defines interface"

  4 tasks created. IC4 and IC5 can start now.
```

---

### Step 8 — Parallel: IC4 works on cache layer + IC5 works on export package

Both agents start simultaneously. IC4 claims Task 1, IC5 claims Task 2.

**IC4 session:**

```
> @ic4 Check TaskList for POC-123. Claim Task 1 (cache layer) via TaskUpdate.
  Implement GetAllForFolder(folderPath string) ([]CachedAnalysis, error) in
  internal/cache/responses.go.
  CachedAnalysis struct: FilePath, Model, Prompt, Description, CachedAt.
  TDD — tests first. When done: TaskUpdate status=completed, SendMessage to @tech-lead.
```

```
  @ic4 checking TaskList...

  TaskList shows:
  id:1 "POC-123 Task 1 — cache layer" status:pending owner:unassigned  ← claiming
  id:2 "POC-123 Task 2 — export package" status:pending owner:unassigned
  id:3 "POC-123 Task 3 — UI wiring" status:pending blocked_by:[1,2]
  id:4 "POC-123 Task 4 — QA acceptance tests" status:pending

  TaskUpdate id:1 owner:ic4 status:in_progress

  Reading internal/cache/responses.go, internal/cache/responses_test.go...

  Writing tests first:
  + TestGetAllForFolder_returnsAllCompletedForFolder
  + TestGetAllForFolder_emptyFolderReturnsEmpty
  + TestGetAllForFolder_doesNotReturnOtherFolders

  go test ./internal/cache/... → FAIL (method not exists yet, expected)

  Implementing GetAllForFolder + CachedAnalysis struct...
  go test ./internal/cache/... → PASS (3 new tests)

  Committed: "feat: POC-123 — add GetAllForFolder to ResponseCache"

  TaskUpdate id:1 status:completed
  SendMessage → @tech-lead: "Task 1 done. GetAllForFolder + CachedAnalysis struct in
  internal/cache/responses.go. 3 tests green."
```

**IC5 session (running in parallel):**

```
> @ic5 Check TaskList for POC-123. Claim Task 2 (export package) via TaskUpdate.
  Create internal/export/ package.
  - Exporter interface: Export(analyses []CachedAnalysis, w io.Writer) error
  - CSVExporter, JSONExporter, MarkdownExporter
  TDD. As soon as interface + CachedAnalysis struct are defined, SendMessage to @ic4 and @qa
  with the definition so they can proceed without waiting for full impl.
  When done: TaskUpdate status=completed, SendMessage to @tech-lead.
```

```
  @ic5 checking TaskList...

  TaskUpdate id:2 owner:ic5 status:in_progress

  Reading SPEC-026 format specs, internal/cache/responses.go...

  Designing interface first:

  type CachedAnalysis struct {
      FilePath    string
      Model       string
      Prompt      string
      Description string
      CachedAt    time.Time
  }

  type Exporter interface {
      Export(analyses []CachedAnalysis, w io.Writer) error
  }

  SendMessage → @ic4: "CachedAnalysis struct defined. Matches what you need for GetAllForFolder.
  FilePath/Model/Prompt/Description/CachedAt. Confirm your struct matches."

  SendMessage → @qa: "Exporter interface defined. CachedAnalysis has 5 fields per SPEC-026.
  You can start writing acceptance tests now — don't need full impl."

  Writing tests:
  + TestCSVExporter_writesHeaderAndRows
  + TestCSVExporter_escapesCommasInDescription
  + TestJSONExporter_producesValidJSON
  + TestJSONExporter_allFieldsPresent
  + TestMarkdownExporter_headingPerFile
  + TestMarkdownExporter_metadataInFooter

  go test ./internal/export/... → FAIL (package doesn't exist yet, expected)

  Creating internal/export/exporter.go (interface + factory)
  Creating internal/export/csv.go, json.go, markdown.go

  go test ./internal/export/... → PASS (6 tests)

  Edge case caught: JSON must use exported_at not created_at (spec says exported_at). Fixed.

  Committed: "feat: POC-123 — add internal/export package (CSV/JSON/Markdown exporters)"

  TaskUpdate id:2 status:completed
  SendMessage → @tech-lead: "Task 2 done. internal/export/ package with 3 exporters, 6 tests green."
```

**IC4 receives IC5's message and confirms struct alignment:**

```
  @ic4 received IC5's message.

  My CachedAnalysis uses same 5 fields — FilePath, Model, Prompt, Description, CachedAt. ✓
  SendMessage → @ic5: "Struct matches. Cache layer ready."
```

---

### Step 9 — QA writes acceptance tests in parallel (while IC4+IC5 finish)

QA doesn't wait for UI wiring — it already has the interface definition from IC5.

```
> @qa Check TaskList. Claim Task 4 (acceptance tests) via TaskUpdate.
  You received IC5's interface definition. Write acceptance tests for all SPEC-026 ACs now.
  When done: TaskUpdate status=completed.
```

```
  @qa checking TaskList...

  TaskUpdate id:4 owner:qa status:in_progress

  Reading SPEC-026, IC5's CachedAnalysis struct from SendMessage...

  Writing acceptance tests:
  + TestExport_AC1_scopesToCurrentFolder
  + TestExport_AC2_allFieldsPresent_CSV
  + TestExport_AC2_allFieldsPresent_JSON
  + TestExport_AC2_allFieldsPresent_Markdown
  + TestExport_AC3_dialogPresentedBeforeWrite  (integration, marked as manual)
  + TestExport_AC4_availableFromFileMenu       (integration, marked as manual)
  + TestExport_AC5_emptyFolderMessage

  go test ./internal/export/... → PASS (acceptance tests green against existing export package)

  TaskUpdate id:4 status:completed
  SendMessage → @tech-lead: "Task 4 done. Acceptance tests written and green.
  AC3 and AC4 require manual verification (UI dialogs). All others automated."
```

---

### Step 10 — Tech Lead unblocks Task 3 (UI wiring)

```
  @tech-lead received completion messages from IC4, IC5, and QA.

  TaskList:
  id:1 status:completed ✓
  id:2 status:completed ✓
  id:3 status:pending blocked_by:[1,2] ← both done, now unblocked
  id:4 status:completed ✓

  TaskUpdate id:3 owner:ic4 status:in_progress
  SendMessage → @ic4: "Tasks 1 and 2 are both done. Task 3 is yours — UI wiring.
  Wire ExportDescriptions() handler using GetAllForFolder + the Exporter interface.
  File menu in components.go, handler in app.go. QA's acceptance tests cover expected behavior."
```

```
> @ic4 Task 3 assigned by Tech Lead. Wire the export dialog.
  File menu in internal/ui/fyne/components.go → "Export descriptions..."
  ExportDescriptions() in internal/ui/fyne/app.go:
  1. GetAllForFolder(currentFolder) → if empty: show "No completed analyses in this folder."
  2. Format picker dialog (CSV/JSON/Markdown radio group)
  3. File save dialog (extension pre-filled)
  4. Write via chosen exporter
  5. Success dialog: "Exported N descriptions to <path>"
  All UI in fyne.Do(). When done: TaskUpdate completed, SendMessage to @tech-lead.
```

```
  @ic4 reading internal/ui/fyne/components.go, internal/ui/fyne/app.go,
  internal/ui/fyne/dialog_service.go...

  Adding "Export descriptions..." to File menu.
  Adding ExportDescriptions() to App.
  Two-step dialog: format radio → file save (matches dialog_service.go patterns).

  go build ./... → PASS
  go test ./internal/ui/fyne/... → PASS (existing tests unaffected)

  Committed: "feat: POC-123 — wire export dialog into File menu"

  TaskUpdate id:3 status:completed
  SendMessage → @tech-lead: "Task 3 done. UI wired. All 4 tasks complete."
```

---

### Step 11 — QA final validation

All tasks are done. QA runs full validation including the pre-written acceptance tests.

```
> @qa All POC-123 tasks complete. Run full final validation:
  - Execute the acceptance tests you wrote in Task 4
  - go test ./... for full regression check
  - Manually verify AC3 (dialog) and AC4 (File menu)
  - Check every SPEC-026 MUST against the implementation
```

```
  @qa reading SPEC-026, running tests...

  go test ./... → PASS (all 54 tests including 7 new acceptance tests)

  Checking ACs against implementation:

  AC1 ✅ GetAllForFolder scopes to currentFolder — verified in cache_test
  AC2 ✅ All 5 fields present — verified in export_test (all 3 formats)
       ⚠️  WARNING: Markdown footer missing 'model' field. SPEC-026 says metadata in footer.
  AC3 ✅ Two-step dialog confirmed
  AC4 ✅ File menu → "Export descriptions..."
  AC5 ✅ Empty folder shows "No completed analyses in this folder."

  Also flagged:
  ⚠️  SPEC-026 MUST NOT overwrite without confirmation — not implemented.
      ShowFileSave does not block overwrite. Need explicit os.Stat + confirm.

  SendMessage → @tech-lead: "2 issues found. Blocking approval."
```

```
  @tech-lead received QA's findings.
  SendMessage → @ic4: "QA found 2 issues — fix them: (1) model in Markdown footer,
  (2) overwrite confirmation via os.Stat + dialog.ShowConfirm before write."
```

```
> @ic4 Two QA findings to fix:
  1. internal/export/markdown.go — add model to footer
  2. internal/ui/fyne/app.go — os.Stat check + dialog.ShowConfirm before writing
```

```
  @ic4 fixing...

  Fix 1: markdown.go — model added to footer line
  Fix 2: app.go — os.Stat + dialog.ShowConfirm before write

  go test ./... → PASS
  TestMarkdownExporter_metadataInFooter updated to assert model — PASS

  Committed: "fix: POC-123 — markdown model in footer, overwrite confirmation"
  SendMessage → @qa: "Both issues fixed. Please re-validate."
```

```
  @qa re-checking...

  AC1 ✅  AC2 ✅  AC3 ✅  AC4 ✅  AC5 ✅
  Overwrite confirmation ✅
  Markdown model in footer ✅

  All ACs satisfied. No remaining issues. Ready for spec alignment check.
  SendMessage → @tech-lead: "QA approved. All clear."
```

---

### Step 12 — Spec alignment check

```
> /reflect-specs --phase 4
```

```
  Running Phase 4: Full Code Alignment...

  Checking SPEC-026 (batch export) — 8 MUST requirements:

  | Requirement | Status | Evidence |
  |---|---|---|
  | MUST read from cache GetAllForFolder | MATCH | cache/responses.go:~180 |
  | MUST export CSV/JSON/Markdown | MATCH | export/csv.go, json.go, markdown.go |
  | MUST include all 5 fields | MATCH | export_test.go:~44 |
  | MUST present format+path dialog | MATCH | ui/fyne/app.go:~312 |
  | MUST be in File menu | MATCH | ui/fyne/components.go:~88 |
  | MUST NOT export other folders | MATCH | cache/responses.go:~185 (LIKE clause) |
  | MUST NOT overwrite without confirmation | MATCH | ui/fyne/app.go:~328 |
  | MUST show message if empty | MATCH | ui/fyne/app.go:~308 |

  Phase 4 summary: 8 MATCH / 0 MISSING / 0 DIFFERS

  No drift detected in affected files.
```

---

### Step 13 — Review and commit

```
> /review-and-commit
```

```
  Reviewing staged/modified files...

  internal/cache/responses.go
    ✅ GetAllForFolder — clean SQL, parameterized query, no injection risk
    ✅ CachedAnalysis struct exported cleanly

  internal/export/exporter.go, csv.go, json.go, markdown.go
    ✅ Interface well-defined, implementations are thin
    ✅ All take io.Writer — testable, no file I/O in export logic itself
    ⚠️  LOW: markdown.go uses fmt.Fprintf repeatedly in a loop — minor but acceptable for this size

  internal/ui/fyne/app.go (ExportDescriptions)
    ✅ fyne.Do used correctly for UI calls
    ✅ Overwrite confirmation present
    ✅ Error handling on write failure shows dialog
    ⚠️  LOW: No loading indicator during export — for large folders this could feel frozen.
            Acceptable for MVP, suggest follow-up ticket.

  internal/ui/fyne/components.go
    ✅ Menu wiring minimal and correct

  Tests:
    ✅ 6 export tests, 3 cache tests — good coverage
    ✅ Edge cases: empty folder, overwrite, comma escaping in CSV

  VERDICT: No critical or high issues. Ready to commit.
  2 low findings noted for backlog.
```

```
> Commit.
```

```
  $ git add internal/cache/responses.go internal/export/ \
      internal/ui/fyne/app.go internal/ui/fyne/components.go \
      internal/cache/responses_test.go internal/export/export_test.go
  $ git commit -m "feat: POC-123 — batch export descriptions (CSV/JSON/Markdown)

  Adds File menu → Export descriptions... which reads all completed analyses
  for the current folder from the response cache and writes them in the
  user-chosen format. Includes overwrite confirmation and empty-folder guard.

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"

  [feat/POC-123-batch-export f9a2c41] feat: POC-123 — batch export descriptions
```

---

### Step 14 — Open PR

```
> Push and create a PR.
```

```
  $ git push -u origin feat/POC-123-batch-export
  Branch 'feat/POC-123-batch-export' set up to track remote branch.

  $ gh pr create \
    --title "feat: POC-123 — batch export descriptions (CSV/JSON/Markdown)" \
    --body "..."
```

```
  PR created: https://github.com/org/describer/pull/87

  Move POC-123 to In Review in Linear and attach PR URL.
```

---

### Step 15 — Merge and release

```
> PR approved and CI green. Merge.
```

```
  $ gh pr merge 87 --squash --delete-branch
  ✓ Squashed and merged pull request #87
  ✓ Deleted branch feat/POC-123-batch-export
```

```
> Run /release for a patch bump.
```

```
  /release patch
```

```
  Current version: v1.4.2
  Bumping to: v1.4.3

  Updating README.md changelog... ✓
  Updating .claude-plugin/plugin.json... ✓
  Updating .claude-plugin/marketplace.json... ✓

  $ git commit -m "chore: release v1.4.3"
  $ git tag v1.4.3
  $ git push && git push --tags

  Released: v1.4.3
```

---

### Step 16 — Wrap-up

```
> Check TaskList one final time, then clean up.
```

```
  TaskList:
  id:1 "POC-123 Task 1 — cache layer"      status:completed owner:ic4  ✓
  id:2 "POC-123 Task 2 — export package"   status:completed owner:ic5  ✓
  id:3 "POC-123 Task 3 — UI wiring"        status:completed owner:ic4  ✓
  id:4 "POC-123 Task 4 — QA acc. tests"    status:completed owner:qa   ✓

  All tasks completed. Team is idle.
```

```
  $ cd ~/vibes/describer
  $ git worktree remove ../describer-POC-123
  ✓ Removed worktree

  $ git pull
  Already up to date.
```

```
> Update memory with anything we learned.
```

```
  Adding to .claude/memory/claude/memory.md:

  ## POC-123 learnings
  - Export/IO logic lives in internal/export/ — Exporter interface takes io.Writer for testability
  - responseCache.GetAllForFolder added for folder-scoped queries
  - fyne ShowFileSave does not block overwrite — always add explicit os.Stat + confirmation
  - Two-step dialog (format picker then file save) matches existing dialog_service.go patterns
  - IC5 should SendMessage interface definition early so IC4 and QA can start in parallel
  - TaskCreate task graph before implementation — Tech Lead owns orchestration
```

```
  POC-123 complete.
  Linear ticket → Done.
  v1.4.3 shipped.

  Parallel execution saved ~40% wall time vs sequential:
  Sequential: PM → TL → spec → IC4 (cache) → IC5 (export) → IC4 (UI) → QA → fixes → done
  Parallel:   PM‖TL → spec → IC4‖IC5‖QA → IC4 (UI) → QA final → done
```
