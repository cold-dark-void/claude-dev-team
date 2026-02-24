---
name: scaffold-project
description: Scaffolds a new project with TDD workflow structure including .claude/plans/, specs/TDD.md, AGENTS.md, and .gitignore. Use when creating new projects, setting up project templates, initializing TDD workflow, or preparing AI agent collaboration structure.
---

# Scaffold Project with TDD Workflow

This skill sets up a complete project structure for AI agent collaboration using the TDD.md specification workflow.

## When to Use This Skill

- Creating a new project from scratch
- Adding TDD workflow to an existing project
- Setting up AI agent collaboration structure
- Initializing project documentation and planning system

## What Gets Created

```
project/
├── .claude/
│   ├── CLAUDE.md             # Project memory pointer for Claude Code
│   ├── plans.md              # Master plan index
│   ├── plans/                # Individual plan files
│   │   └── .gitkeep
│   ├── context/              # Task progress tracking
│   │   └── .gitkeep
│   └── memory/
│       └── claude/           # Claude Code's project-local memory
│           └── memory.md
├── specs/
│   └── TDD.md                # Living behavioral specifications
├── AGENTS.md                 # Project-specific rules
└── .gitignore                # Git ignore patterns (if needed)
```

## Instructions

### Step 1: Verify and Prepare

Before creating files, check:
1. Are we in the correct directory? If user provided a project name, create that directory first.
2. Do any files already exist? If so, ask user how to handle (skip/overwrite/cancel).
3. Is this a git repository? If not, ask if user wants to initialize git.

### Step 2: Create Directory Structure

```bash
mkdir -p .claude/plans .claude/context .claude/memory/claude specs
touch .claude/plans/.gitkeep .claude/context/.gitkeep
```

### Step 3: Create .claude/CLAUDE.md

Create `.claude/CLAUDE.md` with the project memory pointer so Claude Code uses project-local memory:

```markdown
# Project Memory

Your memory for this project lives at `.claude/memory/claude/memory.md` (project-local, worktree-shared).

At session start:
1. Resolve project root: `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)`
2. Read `$MROOT/.claude/memory/claude/memory.md` if it exists
3. Write new memories here — not to the global `~/.claude/projects/...` path

This file is shared across all git worktrees since they share the same `.git` common directory.
Fits the per-agent convention: each team agent uses `$MROOT/.claude/memory/<agent>/`; Claude Code uses `$MROOT/.claude/memory/claude/`.
```

Also seed `.claude/memory/claude/memory.md` with a minimal header:

```markdown
# Claude Code Memory — <PROJECT NAME>
_Initialized: <TODAY'S DATE>_

## Project Context
[Add project-specific notes here as you work]
```

Replace `<PROJECT NAME>` and `<TODAY'S DATE>` with actual values.

### Step 4: Create plans.md

Create `.claude/plans.md` with this content:

```markdown
# Master Plan Index

**Purpose**: Quick reference for all planning documents and specifications in this project.

**Last Updated**: <TODAY'S DATE>

---

## Active Specifications

### [TDD Specifications](specs/TDD.md)
**Status**: ✅ BASELINE
**Purpose**: Living behavioral specifications that MUST be maintained across all changes
**Specs**: 3 starter specifications (customize as needed)
**Usage**: Read BEFORE making any code changes. Update DURING planning. Verify AFTER implementation.

---

## Active Plans

_No active plans yet. Create your first plan in `.claude/plans/<YYYY-MM-DD>-title.md`_

---

## Completed Plans (Recent)

_Plans completed in the last 2 weeks will appear here_

---

## Archived Plans

_Plans older than 2 weeks. See `plans/archive/` for detailed documentation._

---

## Quick Reference

| When | Action |
|------|--------|
| **Start new task** | 1. Check `AGENTS.md` for project rules<br>2. Read `./specs/TDD.md` for current behaviors<br>3. Check `.claude/plans.md` for existing work<br>4. Create new `<YYYY-MM-DD>-title.md` plan |
| **Before coding** | 1. Read `./specs/TDD.md`<br>2. Draft new specs if adding features<br>3. Get user approval on spec changes |
| **After changes** | 1. Verify affected specs still pass<br>2. Update TDD.md version history<br>3. Mark specs as ✅/❌ |
| **Before commit** | ⚠️ **CRITICAL**: Check and update `specs/` and `.claude/plans.md` |
| **Task complete** | 1. Verify all specs pass<br>2. Update status in `.claude/plans.md` to [COMPLETED] |

---

## Notes

- Plans use date-based naming: `YYYY-MM-DD-descriptive-title.md`
- Archive completed plans older than 2 weeks
- Update this index when creating/completing plans
- Plans.md is committed to git (contains project history)
```

### Step 5: Create TDD.md


Create `specs/TDD.md` with starter specifications:

```markdown
# TDD Specifications - <PROJECT NAME>

**Last Updated**: <TODAY'S DATE>
**Version**: 1.0.0
**Status**: ✅ BASELINE

---

## Purpose

This file contains living behavioral specifications that define how the application MUST behave. These specifications:
- Prevent regressions when adding new features
- Guide AI agents in understanding current functionality
- Serve as acceptance criteria for changes
- Evolve with the project (living documentation)

**Workflow**: Read BEFORE coding → Update DURING planning → Verify AFTER implementation

---

## Quick Status Table

| SPEC | Title | Status | Last Verified |
|------|-------|--------|---------------|
| 001 | Application Launch | ✅ PASS | <TODAY'S DATE> |
| 002 | Basic Navigation | ✅ PASS | <TODAY'S DATE> |
| 003 | Data Persistence | ✅ PASS | <TODAY'S DATE> |

**Legend**: ✅ PASS | ❌ FAIL | ⚠️ UNDER REVIEW | 🚧 NEW | 🔄 CHANGED

---

## Core Specifications

### SPEC-001: Application Launch

**MUST**: Application starts successfully and displays main interface

**Behavior**:
- Application launches within 5 seconds
- Main window appears with correct title
- All UI components render properly
- No errors or crashes on startup

**Test**:
1. Run application
2. Verify main window appears
3. Verify all UI elements visible
4. Check console for errors

**Validation**:
- [ ] Application starts without errors
- [ ] Main window displays correctly
- [ ] All controls are interactive
- [ ] Startup time < 5 seconds

---

### SPEC-002: Basic Navigation

**MUST**: Users can navigate core application features

**Behavior**:
- Menu/navigation system is accessible
- All primary views can be reached
- Navigation is intuitive and responsive
- State persists across navigation

**Test**:
1. Navigate to each main section
2. Verify back/forward navigation works
3. Verify state is preserved

**Validation**:
- [ ] All main sections accessible
- [ ] Navigation responds immediately (<100ms)
- [ ] No broken links/routes
- [ ] State persists correctly

---

### SPEC-003: Data Persistence

**MUST**: Application data persists across sessions

**Behavior**:
- User settings/data saved automatically
- Data restored on application restart
- Data stored in appropriate location
- Corrupted data handled gracefully

**Test**:
1. Make changes to settings/data
2. Close application
3. Restart application
4. Verify changes persisted

**Validation**:
- [ ] Settings persist across restarts
- [ ] Data saved in correct location
- [ ] No data loss on normal shutdown
- [ ] Graceful handling of corrupted data

---

## Cross-Cutting Concerns

### Performance Requirements
- Application startup: < 5 seconds
- UI responsiveness: < 100ms for user actions
- Memory usage: Reasonable for application type
- No memory leaks over extended usage

### Safety & Error Handling
- No crashes under normal operation
- Graceful degradation when errors occur
- User-friendly error messages
- Data integrity maintained

### Compatibility
- Runs on target platform(s)
- Compatible with specified dependencies
- Works with different screen sizes/resolutions

---

## Testing Protocol

### Before Implementation
1. Read all existing specs to understand current behavior
2. Draft new specs for planned features
3. Get user approval on new specs

### After Implementation
1. Verify affected specs manually
2. Mark each spec as ✅ PASS or ❌ FAIL
3. Update version history with changes

### Spec Status Meanings
- ✅ **PASS**: Verified working as specified
- ❌ **FAIL**: Broken, needs immediate fix
- ⚠️ **UNDER REVIEW**: Being modified with user approval
- 🚧 **NEW**: Recently added, needs initial verification
- 🔄 **CHANGED**: User approved breaking change

---

## Version History

### v1.0.0 - <TODAY'S DATE>
- Initial specification baseline
- Added SPEC-001: Application Launch
- Added SPEC-002: Basic Navigation
- Added SPEC-003: Data Persistence

---

## Instructions for AI Agents

### When Adding Features
1. Read this file first to understand what must NOT break
2. Add new SPEC-XXX sections for your feature
3. Get user approval before implementing
4. Implement feature
5. Verify both new and existing specs pass
6. Update version history

### When Fixing Bugs
1. Identify which spec(s) are failing
2. Fix the code to make spec pass
3. Verify fix doesn't break other specs
4. Update version history

### When Breaking Changes are Required
1. Mark affected spec(s) as ⚠️ UNDER REVIEW
2. Explain to user WHY change must break existing behavior
3. Get explicit approval
4. Update spec with 🔄 CHANGED status
5. Document in version history with justification

---

## Organizing Large Projects

When specs exceed ~10 items (~200 lines), reorganize into:

```
specs/
├── TDD.md                    # Main index (lightweight)
├── core/
│   ├── SPEC-001-*.md
│   └── SPEC-002-*.md
├── performance/
│   └── SPEC-010-*.md
├── safety/
│   └── SPEC-020-*.md
└── compatibility/
    └── SPEC-030-*.md
```
```

**IMPORTANT**: Replace `<PROJECT NAME>` with actual project name and `<TODAY'S DATE>` with today's date (YYYY-MM-DD format).

### Step 6: Create AGENTS.md

Create `AGENTS.md` with this template:

```markdown
# <PROJECT NAME> - Agent Instructions

**Purpose**: Project-specific rules and context that override general Claude Code instructions.

**IMPORTANT**: AI agents MUST read this file before starting any work on this project.

---

## Project Overview

**Description**: [Brief description of what this project does]

**Status**: [Development stage: Prototype, Alpha, Beta, Production]

**Goal**: [Primary goal or purpose of the project]

---

## Technology Stack

**Language**: [Primary language, e.g., Go, TypeScript, Python]

**Framework**: [Main framework if applicable]

**Key Dependencies**:
- [Dependency 1] - [Purpose]
- [Dependency 2] - [Purpose]

**Build System**: [How to build, e.g., go build, npm run build]

**Testing**: [How to run tests, e.g., go test ./..., npm test]

---

## Critical Rules

### DO
- ✅ [Rule 1, e.g., "Use functional components in React"]
- ✅ [Rule 2, e.g., "Always use context.Context for cancellation"]
- ✅ [Rule 3, e.g., "Write thread-safe code with proper locking"]

### DO NOT
- ❌ [Rule 1, e.g., "DO NOT USE PYTHON (this is a Go project)"]
- ❌ [Rule 2, e.g., "Never commit directly to main branch"]
- ❌ [Rule 3, e.g., "Don't add dependencies without discussing first"]

---

## Known Issues

### Issue 1: [Brief Title]
**Problem**: [Description]
**Workaround**: [How to work around it]
**Status**: [Known limitation, planning to fix, etc.]

---

## Architecture Notes

**Project Structure**:
```
project/
├── [directory] - [Purpose]
├── [directory] - [Purpose]
└── [directory] - [Purpose]
```

**Key Files**:
- `[file.ext]` - [What it does]

**Patterns Used**:
- [Pattern 1, e.g., "Repository pattern for data access"]

---

## Development Guidelines

### Code Style
- [Style rule 1]
- [Style rule 2]

### Testing Strategy
- [Testing approach]
- [Coverage goals]

### Performance Considerations
- [Performance concern 1]

---

## Before Making Changes

1. ✅ Read `./specs/TDD.md` to understand current behavior
2. ✅ Check `.claude/plans.md` for existing work
3. ✅ Review this file for project-specific constraints
4. ✅ Plan changes and get user approval
5. ✅ Verify specs after implementation

---

## Commit Guidelines

- Write clear, descriptive commit messages
- Include `Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>`
- Always update `specs/` if behavior changes
- Always update `.claude/plans.md` if completing work
```

**IMPORTANT**: Tell user to fill in the placeholder sections with actual project details.

### Step 7: Update or Create .gitignore

If `.gitignore` doesn't exist, create it with:

```gitignore
# Claude Code - AI agent working directory
# Ignore by default (user-specific files)
.claude/

# But allow project-wide plans and specs (using negation)
!.claude/plans.md
!.claude/plans/
!.claude/plans/**

# Context files are session-specific, don't commit
.claude/context/

# Specs are in ./specs/ (NOT in .claude/), committed normally
```

If `.gitignore` already exists, ask user if they want to append these patterns.

### Step 8: Summary and Next Steps

After creating all files, output:

```
✅ Project scaffolded successfully!

Created:
  📁 .claude/plans/ - Plan files directory
  📁 .claude/context/ - Progress tracking directory
  📁 .claude/memory/claude/ - Claude Code project-local memory
  📄 .claude/CLAUDE.md - Project memory pointer
  📄 .claude/memory/claude/memory.md - Claude Code's memory (project-local)
  📄 .claude/plans.md - Master plan index
  📄 specs/TDD.md - Behavioral specifications (3 starter specs)
  📄 AGENTS.md - Project-specific rules (NEEDS CUSTOMIZATION)
  📄 .gitignore - Git ignore patterns [if created]

Next steps:

1. ✏️  Edit AGENTS.md with your project details:
   - Project overview and goals
   - Technology stack
   - Critical rules (DO/DO NOT)
   - Known issues
   - Architecture notes

2. 📋 Customize specs/TDD.md:
   - Replace example specs with your actual requirements
   - Or keep them as starting point and add more
   - Update project name in header

3. 🎯 Create your first plan (optional):
   - .claude/plans/<YYYY-MM-DD>-initial-setup.md
   - Add entry to .claude/plans.md

4. 📝 Commit the scaffold:
   - git add specs/ AGENTS.md
   - git add -f .claude/plans.md
   - git commit -m "Initial project scaffold with TDD workflow

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"

💡 Tip: Read ~/.claude/CLAUDE.md for full workflow documentation
💡 The 3 starter specs are examples - customize them for your project!
```

## Error Handling

### If files already exist:
1. List which files exist
2. Ask user: "[1] Skip existing files (recommended), [2] Overwrite all, [3] Cancel"
3. Proceed based on choice

### If not in a suitable directory:
1. Ask user: "No project directory detected. Create new directory? [name]"
2. If yes, create directory and change into it
3. Then proceed with scaffold

## Important Notes

- Replace ALL placeholder text (e.g., `<PROJECT NAME>`, `<TODAY'S DATE>`)
- Use today's actual date in YYYY-MM-DD format
- AGENTS.md is a template - user MUST customize it
- The 3 starter specs are examples - they should be replaced with actual project requirements
- Don't overwrite existing files without user confirmation
- If .gitignore exists, append patterns carefully (don't duplicate)

## Files Created Checklist

Before completing, verify:
- [ ] .claude/plans/ directory exists
- [ ] .claude/context/ directory exists
- [ ] .claude/memory/claude/ directory exists
- [ ] .claude/CLAUDE.md created with project memory pointer
- [ ] .claude/memory/claude/memory.md created with project header
- [ ] .claude/plans.md created
- [ ] specs/ directory exists
- [ ] specs/TDD.md created with 3 starter specs
- [ ] AGENTS.md created
- [ ] .gitignore created or updated (if needed)
- [ ] .gitkeep files in empty directories
- [ ] All placeholders replaced with actual values
- [ ] User notified to customize AGENTS.md
