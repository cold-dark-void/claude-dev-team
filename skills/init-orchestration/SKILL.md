---
name: init-orchestration
description: Bootstrap Agent Teams orchestration for any project. Enables CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS, adds a TaskCompleted quality-gate hook, and creates/updates AGENTS.md with team coordination rules. Run once per project. Safe to re-run — existing files are merged, not overwritten.
---

# Init Orchestration

Bootstrap the three files needed for Claude Code Agent Teams in the current project.

## What Gets Created / Updated

```
project/
├── .claude/
│   ├── settings.json          # + env var + hooks section (merged)
│   └── hooks/
│       └── task-completed.sh  # Quality-gate hook (created)
└── AGENTS.md                  # Team coordination rules (created or appended)
```

## Instructions

### Step 1: Inventory what exists

Check for existing files:
```bash
ls .claude/settings.json 2>/dev/null && echo "settings exists"
ls AGENTS.md 2>/dev/null && echo "agents exists"
```

Note which files exist — they get merged, not overwritten.

---

### Step 2: Update .claude/settings.json

**If `settings.json` does not exist** — create it:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "hooks": {
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/task-completed.sh"
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(cat:*)",
      "Bash(echo:*)",
      "Bash(printf:*)",
      "Bash(mkdir:*)",
      "Bash(node:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(pnpm:*)",
      "Bash(yarn:*)",
      "Bash(bun:*)",
      "Bash(python:*)",
      "Bash(python3:*)",
      "Bash(pip:*)",
      "Bash(pip3:*)",
      "Bash(pytest:*)",
      "Bash(cargo:*)",
      "Bash(go:*)",
      "Bash(make:*)",
      "Bash(gh:*)",
      "Bash(docker:*)",
      "Bash(docker-compose:*)",
      "Bash(_gc=*)",
      "Bash(MROOT=*)",
      "Bash(WTROOT=*)",
      "Bash(AGENT_*)",
      "Bash(cd:*)",
      "Bash(test:*)",
      "Bash([ :*)",
      "Bash([[ :*)",
      "Bash(if :*)",
      "Bash(for :*)",
      "Bash(while :*)",
      "Bash({:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(wc:*)",
      "Bash(sort:*)",
      "Bash(uniq:*)",
      "Bash(grep:*)",
      "Bash(rg:*)",
      "Bash(sed:*)",
      "Bash(awk:*)",
      "Bash(cut:*)",
      "Bash(tr:*)",
      "Bash(touch:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(tree:*)",
      "Bash(stat:*)",
      "Bash(readlink:*)",
      "Bash(realpath:*)",
      "Bash(basename:*)",
      "Bash(dirname:*)",
      "Bash(diff:*)",
      "Bash(xargs:*)",
      "Bash(tee:*)",
      "Bash(true:*)",
      "Bash(false:*)",
      "Bash(exit:*)",
      "Bash(export:*)",
      "Bash(set:*)",
      "Bash(read:*)",
      "Bash(type:*)",
      "Bash(which:*)",
      "Bash(command:*)",
      "Bash(env:*)",
      "Bash(date:*)",
      "Bash(sleep:*)",
      "Bash(jq:*)"
    ],
    "defaultMode": "acceptEdits"
  }
}
```

**If `settings.json` already exists** — read it, then merge in the missing keys:
- Add `"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }` if `env` key is absent
- If `env` key exists but lacks `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, add it to the existing `env` object
- Add the `TaskCompleted` hooks entry if `hooks` key is absent
- If `hooks` key exists but lacks `TaskCompleted`, add it
- Leave all existing `permissions` and other keys untouched
- Write the merged result back as valid JSON

---

### Step 3: Create .claude/hooks/task-completed.sh

Create `.claude/hooks/` directory and write the hook script:

```bash
mkdir -p .claude/hooks
```

Write `.claude/hooks/task-completed.sh`:

```bash
#!/usr/bin/env bash
# TaskCompleted hook — quality gate that runs before any task is marked done.
# Exit code 2 = block completion (stderr is fed back to the agent as feedback).
# Exit code 0 = allow completion.
#
# Customize this script for your project. Examples:
#   - Run tests: npm test / go test ./... / pytest
#   - Validate JSON/YAML config files
#   - Check for lint errors
#   - Verify build artifacts exist
#
# Input (via stdin): JSON with task_id, task_subject, task_description, teammate_name, team_name

# Uncomment and adapt the check(s) relevant to your project:

# --- Example: require tests to pass ---
# if ! npm test 2>&1; then
#   echo "Tests must pass before completing task." >&2
#   exit 2
# fi

# --- Example: validate JSON config files ---
# for f in package.json tsconfig.json; do
#   if [ -f "$f" ] && ! python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
#     echo "$f is not valid JSON" >&2
#     exit 2
#   fi
# done

exit 0
```

Make it executable:
```bash
chmod +x .claude/hooks/task-completed.sh
```

---

### Step 4: Create or update AGENTS.md

**If `AGENTS.md` does not exist** — create it with a full template (see below).

**If `AGENTS.md` already exists** — read it, then check if it already has an `## Agent Teams` or `## Team Coordination` section. If not, append the team coordination section (from the template below) to the end of the existing file.

#### AGENTS.md template (new file)

```markdown
# AGENTS.md — <PROJECT NAME>

Project-specific rules for all agents (Claude Code teammates, subagents, CI).
Read this file at the start of every session before doing any work.

## Project Overview

**Description**: [What this project does]
**Tech stack**: [Primary language/framework]
**Build**: [How to build, e.g., `go build ./...` or `npm run build`]
**Test**: [How to run tests, e.g., `go test ./...` or `npm test`]

## Critical Rules

**DO:**
- [Project-specific rule 1]
- [Project-specific rule 2]

**DO NOT:**
- [Anti-pattern 1]
- [Anti-pattern 2]

## Project Structure

```
[paste your directory tree here]
```

## Key Files

- `[path]` — [what it does]

## Team Coordination

When working as a native Agent Team teammate:
- Check `~/.claude/teams/<team-name>/config.json` to discover other teammates
- Use `TaskList` to find available work; prefer lowest-ID tasks first
- Claim tasks with `TaskUpdate` (set `owner` to your agent name) before starting
- Mark tasks `completed` via `TaskUpdate` when done, then check `TaskList` again
- Communicate with teammates via `SendMessage` (DM); avoid broadcast unless critical
- Do NOT edit files another teammate is actively working on
- After finishing, send a status update to the team lead

## Commit Rules

- [Project-specific commit convention, e.g., conventional commits]
- Always include: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
```

Replace all `[bracketed]` and `<ANGLE BRACKET>` placeholders with actual values.

#### Team Coordination section only (appending to existing AGENTS.md)

```markdown

## Team Coordination

When working as a native Agent Team teammate:
- Check `~/.claude/teams/<team-name>/config.json` to discover other teammates
- Use `TaskList` to find available work; prefer lowest-ID tasks first
- Claim tasks with `TaskUpdate` (set `owner` to your agent name) before starting
- Mark tasks `completed` via `TaskUpdate` when done, then check `TaskList` again
- Communicate with teammates via `SendMessage` (DM); avoid broadcast unless critical
- Do NOT edit files another teammate is actively working on
- After finishing, send a status update to the team lead
```

---

### Step 5: Validate

Run the hook manually to confirm it passes:
```bash
echo '{}' | bash .claude/hooks/task-completed.sh
echo "Hook exit code: $?"
```

Validate settings.json is still valid JSON:
```bash
python3 -c "import json; json.load(open('.claude/settings.json')); print('settings.json OK')"
```

---

### Step 6: Summary

Print a summary of what was done:

```
✅ Agent Teams orchestration initialized!

Updated:
  📄 .claude/settings.json   — CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 + TaskCompleted hook
  📄 .claude/hooks/task-completed.sh — quality-gate hook (customize for your project)
  📄 AGENTS.md               — team coordination rules [created/appended]

Next steps:
  1. Customize .claude/hooks/task-completed.sh with project-specific checks
     (uncomment test runner, JSON validation, or add your own)
  2. Fill in AGENTS.md placeholders with actual project details
  3. Restart Claude Code for the env var to take effect

To use Agent Teams:
  "Create a team with tech-lead as lead, spawn ic5 and qa as teammates,
   assign implementation to ic5 and test validation to qa."
```

---

## Error Handling

- If `settings.json` contains invalid JSON before we touch it: warn the user and stop — do not overwrite
- If `AGENTS.md` is very large (>200 lines): append the team coordination section at the end and note it was appended
- If `.claude/hooks/` cannot be created (permissions): report the error with the manual command to run

## Important Notes

- This skill is idempotent — safe to run multiple times without clobbering existing content
- The hook script exits 0 by default (pass-through) until customized
- Agent Teams require Claude Code restart after `settings.json` changes for the env var to take effect
- Teammates do not inherit conversation history — AGENTS.md is their primary orientation document
