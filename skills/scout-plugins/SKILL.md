---
name: scout-plugins
description: Research new/updated Claude Code plugins, MCP servers, and skills
  released in the last week (or custom time window). Evaluates each against the
  current dev-team plugin setup, identifies gaps, and proposes enhancements with
  priority and effort. Usage /scout-plugins or /scout-plugins 2w or /scout-plugins 30d
argument-hint: "[time window, e.g. 1w, 2w, 30d — default: 1w]"
---

# Scout Plugins

Systematic competitive intelligence scan of the Claude Code plugin ecosystem.

## Arguments

- `/scout-plugins` — scan the last 1 week (default)
- `/scout-plugins 2w` — scan the last 2 weeks
- `/scout-plugins 30d` — scan the last 30 days
- `/scout-plugins 3m` — scan the last 3 months

Parse the argument to determine the time window. Default to 1 week if omitted.

---

## Step 0: Load current capabilities

Read in parallel to understand what the dev-team plugin already provides:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

- `$MROOT/README.md` — current feature set, commands, agents, changelog
- `$MROOT/AGENTS.md` — project rules and conventions
- `$MROOT/.claude-plugin/plugin.json` — current version

Build a mental inventory of:
- All commands/skills and what they do
- All agents and their capabilities
- Review workflow, memory system, TDD gates, orchestration features
- Recent changelog entries (what was added recently — avoid re-discovering it)

---

## Step 1: Research (parallel web searches)

Run these searches in parallel, adjusting date terms for the time window:

### Search batch 1 (plugin ecosystem)
1. `Claude Code plugins released updated <month> <year>`
2. `Claude Code MCP servers new plugins <month> <year>`
3. `Claude Code plugin marketplace new releases <date range>`

### Search batch 2 (community & repos)
4. `site:github.com claude code plugin <year> <month>`
5. `awesome claude code extensions plugins <year>`
6. `Claude Code skills hooks agents new <month> <year>`

### Search batch 3 (specific categories)
7. `Claude Code code review plugin <year>`
8. `Claude Code memory context plugin <year>`
9. `Claude Code testing TDD plugin <year>`
10. `Claude Code orchestration workflow plugin <year>`

Collect all unique plugins, skills, MCP servers, and tools mentioned.

---

## Step 2: Filter and deduplicate

From the search results, build a candidate list. For each candidate:

1. **Name** and author
2. **What it does** (1-2 sentences)
3. **When released/updated** (within the time window?)
4. **Install count or stars** (if available)
5. **Source URL** (GitHub repo or marketplace link)

Discard:
- Anything released before the time window
- Anything already installed or incorporated into dev-team (check changelog)
- Anything clearly low-quality (no README, no stars, abandoned)

---

## Step 3: Deep evaluation of top candidates

For each candidate that passes the filter (up to 10), do a deeper dive:

### 3a. Fetch details
Read the plugin's README, SKILL.md, or documentation page. Understand:
- Exact features and commands provided
- Architecture (sub-agents, hooks, MCP servers, etc.)
- Dependencies and requirements
- License

### 3b. Gap analysis against dev-team
For each candidate, answer:

| Question | Answer |
|----------|--------|
| Does dev-team already do this? | fully / partially / no |
| If partially, what's missing? | specific gap |
| Would adopting this improve dev-team? | yes / maybe / no |
| Effort to incorporate | low / medium / high |
| Could we steal the idea instead of the plugin? | yes / no |

### 3c. Classify
Assign each candidate to one of:
- **ADOPT** — install or incorporate this; clear value add
- **STEAL** — don't adopt wholesale, but steal specific ideas/patterns
- **WATCH** — interesting but not actionable yet; revisit next scan
- **SKIP** — not relevant or already covered

---

## Step 4: Output the report

```
═══ PLUGIN SCOUT REPORT ═══════════════════════════════
Time window: <start date> → <end date>
Current version: dev-team v<version>
Candidates scanned: <N>
═══════════════════════════════════════════════════════

## ADOPT (clear value — incorporate into dev-team)

### <plugin-name> by <author> — <stars/installs>
What: <1-2 sentences>
Gap: <what dev-team is missing>
Effort: <low/medium/high>
Source: <URL>

---

## STEAL (borrow ideas, not the whole plugin)

### <plugin-name> by <author>
What: <1-2 sentences>
Idea to steal: <specific technique or pattern>
How to apply: <where in dev-team this would go>
Effort: <low/medium/high>

---

## WATCH (revisit next scan)

- <plugin-name> — <why it's interesting but not ready>

---

## SKIP (already covered or not relevant)

- <plugin-name> — <reason>

═══════════════════════════════════════════════════════
```

Omit any section with no entries.

---

## Step 5: Enhancement proposal

If any ADOPT or STEAL candidates were found, produce an enhancement table:

```
## Proposed Enhancements

| Priority | Enhancement | Inspired By | Effort | Affects |
|----------|-------------|-------------|--------|---------|
| High     | <what>      | <plugin>    | Low    | <files> |
| Medium   | <what>      | <plugin>    | Medium | <files> |
```

---

## Step 6: Save the report

Save the full report to:
```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# .claude/plans/<YYYY-MM-DD>-scout-plugins.md
```

Print:
```
Report saved to: .claude/plans/<date>-scout-plugins.md

Next steps:
  - Review ADOPT items and decide which to implement
  - Schedule implementation with /kickoff for each approved enhancement
  - Run /scout-plugins again in <time window> to stay current
```

---

## Rules

- Always compare against the CURRENT state of dev-team, not an older version
- Be honest about gaps — don't dismiss competitors to protect ego
- Be skeptical about install counts — read the actual code/README
- Prefer stealing ideas over adopting whole plugins (less dependency, more control)
- If a plugin does something dev-team does but better, say so explicitly
- Note license compatibility (dev-team is MIT — flag GPL/AGPL conflicts)
- If nothing interesting was found in the time window, say so — don't invent findings
