---
name: init-orchestration
description: >
  DEPRECATED — init-orchestration (Agent Teams bootstrap) was removed at v1.0.0
  (CDT-46-C4). This stub disappears at v1.1.
---

# Init Orchestration (protocol retained for /setup)

> **Entry:** `/setup orchestration`.
> Discovery Surface is `/setup` — this file is **not** a primary skill.
> Protocol body kept for skill-delegate from `commands/setup.md` (CDT-46-C4).
> Live helpers retained: `check-hook-templates.sh` (template-internal hygiene
> gate — extractability/shebang/`bash -n`; dual-copy live-vs-template retired
> CDT-54); `disclose-force-overwrite.sh` (CDT-51 AC5 force-overwrite disclosure);
> `test-orch-allowlist.sh` (CDT-51 TL P0 matrix allow ⊇ greenfield template).

Bootstrap the files needed for Claude Code Agent Teams in the current project.

## What Gets Created / Updated

```
project/
├── .claude/
│   ├── settings.json          # + env var + hooks section (merged)
│   ├── hooks/
│   │   ├── task-completed.sh          # Quality-gate hook (created)
│   │   ├── stop-review.sh             # Self-review gate — checks diff before agent exits (created)
│   │   ├── memory-capture.sh          # Auto memory — logs Write/Edit to tier-0 (created)
│   │   ├── bash-compress.sh           # Output compression — rewrites noisy commands inline (created)
│   │   ├── precompact-rescue.sh       # PreCompact rescue capture (SPEC-018 M12)
│   │   ├── rescue-pointer.sh          # PostCompact/SessionStart pointer surfacing (M16)
│   │   └── friction-capture.sh        # Live friction ledger (SPEC-012 M1; PostToolUseFailure/PermissionDenied/StopFailure)
│   └── memory/
│       └── claude/
│           └── memory.md      # Orchestrator rules seeded (created or appended)
├── AGENTS.md                  # Team coordination rules (created or appended)
└── CLAUDE.md                  # AGENTS.md reference (created, existing content migrated)
```

## Instructions

### Step 0: Doctor hard-gate (before any mutation)

Hard-gate on plugin **`dev-team:doctor`** (SPEC-005 / SPEC-022 M6b). This is the
plugin doctor surface — **not** the Claude Code harness built-in `/doctor`.
Exit ≤1 (PASS or WARN-only) continues; exit 2 (FAIL) **blocks** bootstrap.
Override: `--skip-doctor` prints an explicit WARNING then continues (silent skip
forbidden). Marketplace install has no gate.

Parse `--skip-doctor` from remaining args passed through from `/setup orchestration`.

```bash
# Parse --skip-doctor from remaining args (do not strip other flags)
SKIP_DOCTOR=0
for _a in "$@"; do
  case "$_a" in --skip-doctor) SKIP_DOCTOR=1 ;; esac
done

if [ "$SKIP_DOCTOR" -eq 1 ]; then
  echo "WARNING: doctor gate skipped (--skip-doctor). Proceeding without dev-team:doctor health check." >&2
else
  # Locate plugin root (PDH) — same install-aware formula as /doctor
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
  DOCTOR_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/doctor/doctor.sh 2>/dev/null) || DOCTOR_SH=""
  if [ -z "$DOCTOR_SH" ] || [ ! -f "$DOCTOR_SH" ]; then
    echo "FAIL: dev-team:doctor (plugin /doctor) not found — cannot gate /setup orchestration." >&2
    echo "Remediation: reinstall the dev-team plugin, then re-run /setup orchestration (or pass --skip-doctor)." >&2
    # STOP — do not mutate settings/hooks/AGENTS.md
    exit 2
  fi
  set +e
  bash "$DOCTOR_SH"
  DOCTOR_RC=$?
  set -e
  if [ "$DOCTOR_RC" -ge 2 ]; then
    echo "FAIL: dev-team:doctor exited $DOCTOR_RC (FAIL). /setup orchestration blocked." >&2
    echo "Remediation: fix FAIL rows above, re-run /doctor (plugin surface dev-team:doctor — not the Claude Code harness /doctor), then retry /setup orchestration. Override: /setup orchestration --skip-doctor" >&2
    # STOP — do not mutate settings/hooks/AGENTS.md
    exit 2
  fi
  # exit 0 (PASS) or 1 (WARN-only) → continue to Step 1
fi
```

### Step 1: Inventory what exists

Check for existing files:
```bash
ls .claude/settings.json 2>/dev/null && echo "settings exists"
ls AGENTS.md 2>/dev/null && echo "agents exists"
ls CLAUDE.md 2>/dev/null && echo "claude.md exists"
```

Note which files exist — they get merged, not overwritten.

**Upgrade check — always run regardless of prior initialization:**

Even if the project was previously initialized, scan ALL hook commands in settings.json for:

1. **Pipe operators (`|`)** — pipes in hooks fail in the sandbox and poison the session, every subsequent bash command fails. Warn the user:
```
⚠️  Piped hook commands detected — these will poison the session and break all bash:
  [list the commands]
Fix: remove '| <cmd>' from each. Example: 'go vet ./... 2>&1 | head -20' → 'go vet ./... 2>&1'
Restart required after fixing.
```

2. **Worktree-unsafe relative paths** — commands of the form `bash .claude/hooks/<name>.sh` resolve from the agent's cwd, not the project root. Inside a git worktree (which doesn't share `.claude/`) every Bash tool call fails with "No such file or directory". Auto-rewrite these to use `${CLAUDE_PROJECT_DIR}`:
```
bash .claude/hooks/X.sh  →  bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/X.sh"
```
Apply this rewrite for every hook command matching the relative pattern. Note this in the Step 9 summary as an upgrade applied.

If any upgrade keys are missing, proceed through the relevant steps to add them. Report what was upgraded in the Step 9 summary.

---

### Step 2: Detect sandbox network needs

The sandbox blocks all outbound network by default. Auto-detect what the project needs, then confirm with the user before writing settings.json.

**Auto-detect** — check for these files and map to domains:

| File | Domains to add |
|------|---------------|
| `package.json` or `pnpm-lock.yaml` or `yarn.lock` | `registry.npmjs.org`, `npmjs.com` |
| `go.mod` | `proxy.golang.org`, `sum.golang.org` |
| `requirements.txt` or `pyproject.toml` or `Pipfile` | `pypi.org`, `files.pythonhosted.org` |
| `Cargo.toml` | `crates.io`, `static.crates.io` |
| `Gemfile` | `rubygems.org` |
| `.git/config` containing `github.com` | `github.com` |
| `.git/config` containing `gitlab.com` | `gitlab.com` |
| `.git/config` containing `bitbucket.org` | `bitbucket.org` |

```bash
# Example detection
ls package.json pnpm-lock.yaml yarn.lock 2>/dev/null
ls go.mod 2>/dev/null
ls requirements.txt pyproject.toml Pipfile 2>/dev/null
ls Cargo.toml 2>/dev/null
ls Gemfile 2>/dev/null
git remote get-url origin 2>/dev/null
```

**Present to user:**

```
Sandbox network configuration — the sandbox blocks all outbound network by default.

Auto-detected from your project:
  ✓ github.com          (git remote)
  ✓ registry.npmjs.org  (package.json)
  ✓ npmjs.com           (package.json)

Other common domains you might need:
  · pypi.org, files.pythonhosted.org    (Python)
  · proxy.golang.org, sum.golang.org    (Go)
  · crates.io, static.crates.io        (Rust)
  · rubygems.org                        (Ruby)
  · registry.hub.docker.com, ghcr.io   (Docker images)

Add any of the above, or custom domains? (comma-separated, or "none" to use only auto-detected)
```

Collect the user's answer. Build the final `allowedDomains` list (auto-detected + user-specified). Hold this list for Step 3.

If the user says "none" and auto-detection found domains, still use the auto-detected ones.
If the user says "skip" or "no sandbox", note that sandbox should be disabled — Step 3 will set `sandbox.enabled` to `false`.

#### Go project sandbox workarounds

If `go.mod` was detected, agents will need writable Go build and module caches.
The sandbox blocks `~/.cache/go-build/` by default. Inform the user:

```
Go project detected. Agents running `go build` or `go test` in sandbox mode need
a writable build cache. Two options:

1. (Recommended) Agents will use GOCACHE=$TMPDIR/go-cache GOWORK=off automatically
2. Add ~/.cache/go-build to sandbox filesystem write allowlist

Option 1 requires no config changes — I'll seed this into orchestrator memory.
```

If user picks option 1 (default), append this to the orchestrator memory content in Step 7:
```
- Go project: agents MUST prefix build/test commands with `GOWORK=off GOCACHE=$TMPDIR/go-cache`
  to avoid sandbox read-only cache errors. Inject this into IC agent prompts.
```

If user picks option 2, add to `.claude/settings.json` sandbox filesystem section:
```json
"filesystem": {
  "write": {
    "allowOnly": ["~/.cache/go-build"]
  }
}
```

---

### Step 3: Write .claude/settings.json

Using the `allowedDomains` list from Step 2, write the settings file.

**If `settings.json` does not exist** — create it:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-compress.sh\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/memory-capture.sh\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/stop-review.sh\""
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/task-completed.sh\""
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/precompact-rescue.sh\""
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/rescue-pointer.sh\""
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/rescue-pointer.sh\""
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/friction-capture.sh\""
          }
        ]
      }
    ],
    "PermissionDenied": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/friction-capture.sh\""
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/friction-capture.sh\""
          }
        ]
      }
    ]
  },
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["docker", "docker-compose"],
    "network": {
      "allowedDomains": ["<domains from Step 2>"]
    }
  },
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Agent",
      "Task"
    ],
    "defaultMode": "dontAsk"
  }
}
```

> **RISK (intentional posture — matrix winner Cell C).** `defaultMode: "dontAsk"` +
> matrix allow set (`Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task) + sandbox
> (`enabled` + `autoAllowBashIfSandboxed`) is the shipped orchestration posture
> (CDT-51 AC1 evidence: `docs/runbooks/permission-posture-matrix.md`). `dontAsk`
> never prompts: tools on the allowlist (or auto-allowed by the sandbox) run
> unprompted; everything else is **denied** (not asked). Under `dontAsk`, a
> bare `Bash(*)`-only allowlist fails zero-prompt for non-Bash tools — the full
> matrix set is required. The OS sandbox is the containment boundary for
> `Bash(*)`. Users who disable the sandbox (or run where bubblewrap is
> unavailable) lose that boundary — keep sandbox enabled unless you fully trust
> every task source. (Interactive/solo path is separate: `/setup project` uses
> `acceptEdits` + a curated Bash allowlist, not this wildcard.)

**If `settings.json` already exists** — read it, then merge in the missing keys:
- Add `"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }` if `env` key is absent
- If `env` key exists but lacks `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, add it to the existing `env` object
- Add the `PreToolUse`, `PostToolUse`, `Stop`, `TaskCompleted`, `PreCompact`, `PostCompact`, `SessionStart`, `PostToolUseFailure`, `PermissionDenied`, and `StopFailure` hooks entries if `hooks` key is absent
- If `hooks` key exists but lacks any of `PreToolUse`, `PostToolUse`, `Stop`, `TaskCompleted`, `PreCompact`, `PostCompact`, `SessionStart`, `PostToolUseFailure`, `PermissionDenied`, or `StopFailure`, add the missing ones
- `PreCompact`/`PostCompact`/`SessionStart` require a Claude Code version that supports those hook events; on older versions the entries are inert (graceful absence — SPEC-018 M18)
- `PostToolUseFailure`/`PermissionDenied`/`StopFailure` wire the shared friction ledger handler (SPEC-012 M1/M5); on older CC versions that lack an event the entry is inert (graceful absence). All three point at the same `friction-capture.sh`.
- Add `sandbox` block if absent (`enabled: true`, `autoAllowBashIfSandboxed: true`, `excludedCommands: ["docker", "docker-compose"]`, `network.allowedDomains` from Step 2). If `sandbox` exists: ensure `enabled` is `true` and `autoAllowBashIfSandboxed` is `true`; merge new domains into existing `allowedDomains` (no duplicates); preserve any existing `filesystem` overrides
- Ensure `permissions.allow` contains **every** entry from the greenfield template allow list above (matrix set: `Bash(*)`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `Task`) — add any missing entries; preserve any other existing allow entries. Ensure `permissions.defaultMode` matches the **managed orchestration defaultMode** from the greenfield template block above (read that template value, then write it — currently `"dontAsk"`; do not hard-code a second diverging copy). Add or update as needed (including flipping a prior `bypassPermissions` / other mode to the managed value)
- **Force-overwrite disclosure (SPEC-005 / CDT-51 AC5):** when a re-run **changes** an existing managed value (especially `permissions.defaultMode`, `sandbox.enabled`, `sandbox.autoAllowBashIfSandboxed`), you **MUST** print old value, new value, and restore key/path **before** writing. Forced + silent = FAIL. Use the helper below (or print the same labeled block). Adding a missing key is not a force-overwrite (no disclosure required).
- Write the merged result back as valid JSON

#### Force-overwrite disclosure helper (managed settings)

Locate the helper (install-aware PDH, same formula as Step 0):

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
DISCLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/disclose-force-overwrite.sh 2>/dev/null) || DISCLOSE=""
```

For each managed key that will change, run **before** the write. Read the new defaultMode from the greenfield template in this skill (not a second hard-coded string):

```bash
# Re-resolve DISCLOSE (each fenced bash block is a fresh shell — skill-lint C1)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
DISCLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/disclose-force-overwrite.sh 2>/dev/null) || DISCLOSE=""
SETTINGS=".claude/settings.json"
# NEW_DEFAULT_MODE = value of permissions.defaultMode in the greenfield template above
# (currently dontAsk / Cell C winner — re-read the template if it changes)
NEW_DEFAULT_MODE="<new defaultMode value from greenfield template>"

# permissions.defaultMode — primary AC5 path
if [ -n "$DISCLOSE" ] && [ -f "$DISCLOSE" ]; then
  set +e
  bash "$DISCLOSE" \
    --settings "$SETTINGS" \
    --key permissions.defaultMode \
    --new "$NEW_DEFAULT_MODE" \
    --backup-dir .claude
  DISC_RC=$?
  set -e
  # exit 0 → disclosed (force write ok); exit 1 → already matches (no-op)
else
  # Fallback: agent MUST print the same labels if helper missing
  OLD_DM=$(python3 -c "import json; d=json.load(open('$SETTINGS')); print(d.get('permissions',{}).get('defaultMode',''))" 2>/dev/null || true)
  if [ -n "$OLD_DM" ] && [ "$OLD_DM" != "$NEW_DEFAULT_MODE" ]; then
    cat <<EOF
FORCE-OVERWRITE: managed value will be replaced
  key:     permissions.defaultMode
  old:     ${OLD_DM}
  new:     ${NEW_DEFAULT_MODE}
  restore: permissions.defaultMode  (set back to: ${OLD_DM})
EOF
  fi
fi

# sandbox.enabled / sandbox.autoAllowBashIfSandboxed — same disclosure if forcing true over a different value
for _sk in sandbox.enabled:true sandbox.autoAllowBashIfSandboxed:true; do
  _key="${_sk%%:*}"
  _new="${_sk#*:}"
  if [ -n "$DISCLOSE" ] && [ -f "$DISCLOSE" ]; then
    bash "$DISCLOSE" --settings "$SETTINGS" --key "$_key" --new "$_new" --backup-dir .claude || true
  fi
done
```

Disclosure block labels are fixed (`key:`, `old:`, `new:`, `restore:`) so re-runs never silently clobber. The `restore:` line is either a backup path under `.claude/settings.force-*.json` or the exact setting key plus previous value.

---

### Step 4: Create .claude/hooks/task-completed.sh

Create `.claude/hooks/` directory:

```bash
mkdir -p .claude/hooks
```

**IMPORTANT — use the `Write` tool (NOT a bash heredoc) to create each hook file below.**

> **Template SoT (CDT-54):** each fenced bash block below is the sole source of
> truth for that hook body. Live `.claude/hooks/<name>.sh` is **generated** here
> (executable, registered via Step 3 with `${CLAUDE_PROJECT_DIR}`). Dual-copy
> byte-identity against package-tracked live hooks is not required.
> `check-hook-templates.sh` enforces template-internal hygiene only
> (extractability, shebang, `bash -n`) as `/release` Step 4.7. Edit templates
> here; re-run `/setup orchestration` to regenerate live hooks.

Use the `Write` tool to create `.claude/hooks/task-completed.sh` with this content:

> **Note (bootstrap vs hook runtime):** the `git-common-dir` MROOT resolution inside this template is *intentional for hook runtime* after the file is written into the target project. Do NOT rewrite it to `$PROJ_ROOT` / `show-toplevel` during bootstrap — shared `.claude/tasks` / council state must resolve via common-dir at runtime.

```bash
#!/usr/bin/env bash
# TaskCompleted hook — plugin JSON validation + council quality gate
# Council gate enforces SPEC-002 + SPEC-013 + SPEC-009 contracts.
# Stdin is the primary task-id transport per the verified Claude Code contract
# (see .claude/plans/2026-04-09-taskcompleted-hook-spike.md). CLAUDE_TASK_ID env
# var is a fallback for non-native invocations only.

set -uo pipefail  # not -e — we handle errors explicitly per gate case

# Resolve roots once (set-u-safe).
# WTROOT = working-tree root: plugin manifests are PER-WORKTREE tracked artifacts;
#   validate THIS worktree's copy (show-toplevel resolves it from any subdir).
# MROOT = git-common-dir root: .claude/tasks, .claude/council, settings.json are
#   SHARED across worktrees per SPEC-002 "MUST resolve $MROOT from
#   git rev-parse --git-common-dir (NOT from cwd) ... under the shared worktree root".
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

# CDV-210: emit task_complete on successful completion paths only (never on exit 2).
# Fail-open — never blocks TaskCompleted. Dual delivery with orchestrate MCP/webhook OK.
_emit_task_complete() {
  [ -n "${TASK_ID:-}" ] || return 0
  local PDH="" helper="" _pdh_hit=""
  if [ -f skills/plugin-dir.sh ]; then
    PDH=$(pwd)
  else
    _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
      -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
      | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./') || _pdh_hit=""
    if [ -n "$_pdh_hit" ]; then
      PDH=$(CDPATH= cd -- "$(dirname -- "$_pdh_hit")/.." && pwd) || PDH=""
    fi
  fi
  [ -n "$PDH" ] || return 0
  helper=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh 2>/dev/null) || helper=""
  [ -n "$helper" ] && [ -f "$helper" ] || return 0
  NOTIFY_SOURCE=task_completed NOTIFY_TASK="$TASK_ID" \
    bash "$helper" task_complete 2>/dev/null || true
}

# === plugin JSON validation ===

ERRORS=()

for f in "$WTROOT/.claude-plugin/plugin.json" "$WTROOT/.claude-plugin/marketplace.json"; do
  if [ -f "$f" ]; then
    if ! python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
      ERRORS+=("$f is not valid JSON")
    fi
  fi
done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "TaskCompleted hook: fix these before marking task done:" >&2
  for e in "${ERRORS[@]}"; do
    echo "  - $e" >&2
  done
  exit 2
fi

# === council gate ===
# Uses $MROOT (git-common-dir root, resolved at top) for shared council state.

# Read stdin once (one-shot); timeout 1 avoids hanging on direct shell invocations
STDIN_JSON=$(timeout 1 cat 2>/dev/null || true)

# Resolve task_id: stdin .task_id first, then CLAUDE_TASK_ID env var fallback
# Use heredoc to pass STDIN_JSON safely (avoids shell injection on backticks/quotes)
TASK_ID=$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("task_id", ""))
except Exception:
    print("")
' <<< "$STDIN_JSON" 2>/dev/null || true)

if [ -z "$TASK_ID" ]; then
  TASK_ID="${CLAUDE_TASK_ID:-}"
fi

# If no task id resolved, silent pass — gate cannot apply.
# Per SPEC-002 "If neither stdin JSON nor CLAUDE_TASK_ID yields a task id, the
# hook MUST treat the event as non-gated and silent no-op pass" a missing task id
# is ALWAYS a silent pass; the "cannot gate without task id" hard-fail (SPEC-002
# "requires_council: true declared but no task id can be resolved ... structural
# impossibility") is unreachable past this guard, so it is intentionally not implemented.
if [ -z "$TASK_ID" ]; then
  exit 0
fi

# Read task metadata
# Support both legacy flat key (1.json) and compound key (TICKET-1.json).
# TaskCreate resets integers to 1 each new process; compound keys prevent
# cross-run collisions. Fallback: pick most-recently-modified *-<ID>.json.
TASKS_DIR="$MROOT/.claude/tasks"
TASK_META="${TASKS_DIR}/${TASK_ID}.json"
if [ ! -f "$TASK_META" ]; then
  TASK_META=$(ls -t "${TASKS_DIR}/"*"-${TASK_ID}.json" 2>/dev/null | head -1 || true)
fi
if [ -z "$TASK_META" ] || [ ! -f "$TASK_META" ]; then
  # Silent pass — task pre-dates the gate or is not council-tracked
  _emit_task_complete
  exit 0
fi

# Parse requires_council
REQUIRES_COUNCIL=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print("true" if data.get("requires_council", False) else "false")
except Exception:
    print("false")
' "$TASK_META" 2>/dev/null || echo "false")

if [ "$REQUIRES_COUNCIL" != "true" ]; then
  _emit_task_complete
  exit 0  # silent pass — gate not opted in
fi

# Read threshold from settings.json (default 80)
SETTINGS="$MROOT/.claude/settings.json"
THRESHOLD=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("council", {}).get("taskgate", {}).get("min_confidence", 80))
except Exception:
    print(80)
' "$SETTINGS" 2>/dev/null || echo "80")
THRESHOLD="${THRESHOLD:-80}"

# Read council index — required when gate is opted in
INDEX="$MROOT/.claude/council/index.json"
if [ ! -f "$INDEX" ]; then
  echo "TaskCompleted council gate: council index missing at $INDEX (task $TASK_ID requires_council=true)" >&2
  exit 2
fi

# Look up task in index; find max verdict confidence; ignore finding[]-shape rows (max_verdict_confidence: null)
MAX_VERDICT=$(python3 -c '
import json, sys
task_id = sys.argv[1]
index_path = sys.argv[2]
try:
    data = json.load(open(index_path))
    rows = data.get(task_id, [])
    if not rows:
        print("NO_TASK_IN_INDEX")
        sys.exit(0)
    verdict_rows = [r for r in rows if r.get("max_verdict_confidence") is not None]
    if not verdict_rows:
        print("NO_VERDICT_ROWS")
    else:
        print(max(r["max_verdict_confidence"] for r in verdict_rows))
except Exception as e:
    print("PARSE_ERROR", file=sys.stderr)
    print("PARSE_ERROR")
' "$TASK_ID" "$INDEX" 2>/dev/null || echo "PARSE_ERROR")

case "$MAX_VERDICT" in
  NO_TASK_IN_INDEX)
    echo "TaskCompleted council gate: no council verdict for task $TASK_ID (task not found in index)" >&2
    exit 2
    ;;
  NO_VERDICT_ROWS)
    echo "TaskCompleted council gate: no verdict[]-shape council run for task $TASK_ID (only finding[] rows or no rows)" >&2
    exit 2
    ;;
  PARSE_ERROR)
    echo "TaskCompleted council gate: failed to parse council index $INDEX for task $TASK_ID" >&2
    exit 2
    ;;
esac

# Numeric comparison — MAX_VERDICT is an integer at this point
if [ "$MAX_VERDICT" -lt "$THRESHOLD" ]; then
  echo "TaskCompleted council gate: max verdict confidence $MAX_VERDICT below threshold $THRESHOLD for task $TASK_ID" >&2
  exit 2
fi

# Pass
_emit_task_complete
exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/task-completed.sh
```

---

### Step 4b: Create .claude/hooks/stop-review.sh

Use the `Write` tool to create `.claude/hooks/stop-review.sh` with this content:

```bash
#!/usr/bin/env bash
# Stop hook — non-blocking self-review reminder.
# Prints once per (cwd + HEAD-sha) when uncommitted changes exist; never blocks exit.
# The stamp re-fires when HEAD moves (a commit lands), not on every `claude --resume`.

if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT=$(pwd)

# Drain stdin so the harness doesn't block on the pipe; we don't need its content.
TMPF="${TMPDIR:-/tmp}/stop-review-$$"
timeout 1 cat > "$TMPF" 2>/dev/null || true
rm -f "$TMPF"

HEAD_SHA=$(git -C "$_MROOT" rev-parse --short HEAD 2>/dev/null || echo "nohead")
CWD_HASH=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
STAMP_KEY="${CWD_HASH}-${HEAD_SHA}"
STAMP="$_MROOT/.claude/.stop-review-${STAMP_KEY}"

[ -f "$STAMP" ] && exit 0

DIRTY=$(git status --porcelain 2>/dev/null)
[ -z "$DIRTY" ] && exit 0

MODIFIED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Count any porcelain XY status except untracked (??) and ignored (!!).
  # Dual-index codes (MM, AM, MD, RM, UU, …) must count — not only single-side M/A/D/R/C.
  case "$line" in
    \?\?*|\!\!*) ;;
    *) MODIFIED=$(( MODIFIED + 1 )) ;;
  esac
done <<< "$DIRTY"

if [ "$MODIFIED" -gt 0 ]; then
  # Sweep stale stamps from prior HEAD shas to keep .claude/ tidy.
  find "$_MROOT/.claude" -maxdepth 1 -name '.stop-review-*' \
    ! -name ".stop-review-${STAMP_KEY}" -delete 2>/dev/null || true
  touch "$STAMP"
  printf "Stop hook: %d file(s) modified but not committed.\n" "$MODIFIED"
fi

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/stop-review.sh
```

**Re-running on an existing install**: if `.claude/hooks/stop-review.sh` already exists and contains `exit 2` (the legacy blocking version) or references `SESSION_ID` for its stamp key, **force-overwrite** it with the content above — but **MUST** disclose first (SPEC-005 / CDT-51 AC5; forced + silent = FAIL):

```bash
# Re-resolve DISCLOSE (each fenced bash block is a fresh shell — skill-lint C1)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
DISCLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/disclose-force-overwrite.sh 2>/dev/null) || DISCLOSE=""
HOOK=".claude/hooks/stop-review.sh"
if [ -f "$HOOK" ] && grep -qE 'exit 2|SESSION_ID' "$HOOK" 2>/dev/null; then
  ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
  bak=".claude/hooks/stop-review.sh.bak-force-${ts}"
  cp -p -- "$HOOK" "$bak" 2>/dev/null || cp -p "$HOOK" "$bak"
  if [ -n "$DISCLOSE" ] && [ -f "$DISCLOSE" ]; then
    bash "$DISCLOSE" --key "$HOOK" --old "legacy-blocking-or-SESSION_ID-stamp" \
      --new "non-blocking self-review (current template)" --restore "$bak"
  else
    cat <<EOF
FORCE-OVERWRITE: managed value will be replaced
  key:     ${HOOK}
  old:     legacy-blocking-or-SESSION_ID-stamp
  new:     non-blocking self-review (current template)
  restore: ${bak}
EOF
  fi
  # then Write the template content above over $HOOK
fi
```

Sweep stale stamps with `find .claude -maxdepth 1 -name '.stop-review-*' -delete`.

---

### Step 4c: Create .claude/hooks/memory-capture.sh

Use the `Write` tool to create `.claude/hooks/memory-capture.sh` with this content:

> **Note (bootstrap vs hook runtime):** the `MEMDB="$MROOT/.claude/memory/memory.db"` line below uses `git-common-dir` intentionally — this is *hook-runtime* resolution of the shared memory DB after the template is emitted into the target project. Step 7's seed path uses `$PROJ_ROOT`/`show-toplevel` instead; the two look contradictory but run in different contexts.

```bash
#!/usr/bin/env bash
# PostToolUse hook — memory capture for Write/Edit only (not Bash).
# High-signal events only: file changes are worth remembering, shell commands are not.

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

[ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null || exit 0

TMPF="${TMPDIR:-/tmp}/memcap-$$"
# timeout 1: match stop-review.sh — a stuck stdin must not hang PostToolUse.
timeout 1 cat > "$TMPF" 2>/dev/null || { rm -f "$TMPF"; exit 0; }

TOOL_NAME=$(jq -r '.tool_name // empty' "$TMPF" 2>/dev/null)

case "$TOOL_NAME" in
  Write|Edit) ;;
  *) rm -f "$TMPF"; exit 0 ;;
esac

AGENT=$(jq -r '.teammate_name // "auto"' "$TMPF" 2>/dev/null || echo "auto")
FILE_PATH=$(jq -r '.tool_input.file_path // empty' "$TMPF" 2>/dev/null)
rm -f "$TMPF"

[ -z "$FILE_PATH" ] && exit 0

OBSERVATION="${TOOL_NAME,,} $FILE_PATH"

# Per-repo dedup marker (hash of MROOT) so concurrent projects/agents on the
# same host do not share or race a single global file.
MROOT_HASH=$(printf '%s' "$MROOT" | cksum | cut -d' ' -f1)
DEDUP_FILE="${TMPDIR:-/tmp}/.claude-memcap-${MROOT_HASH}"
LAST=$(cat "$DEDUP_FILE" 2>/dev/null || true)
[ "$OBSERVATION" = "$LAST" ] && exit 0
printf '%s' "$OBSERVATION" > "$DEDUP_FILE"

AGENT_ESC=$(printf '%s' "$AGENT" | sed "s/'/''/g")
OBS_ESC=$(printf '%s' "$OBSERVATION" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; INSERT INTO memories(agent, type, content) VALUES ('$AGENT_ESC', 'memory', '$OBS_ESC');" 2>/dev/null || true

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/memory-capture.sh
```

---

### Step 4d: Create .claude/hooks/bash-compress.sh

Use the `Write` tool to create `.claude/hooks/bash-compress.sh` with this content:

```bash
#!/usr/bin/env bash
# PreToolUse hook — compresses output of noisy Bash commands inline.
# Inlines the compression logic so no wrapper script is invoked (avoids
# permission re-checks on the rewritten command in CC 2.1.116+).

TMPF="${TMPDIR:-/tmp}/bcompress-$$"
cat > "$TMPF"

TOOL_NAME=$(jq -r '.tool_name // empty' "$TMPF" 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || { rm -f "$TMPF"; exit 0; }

COMMAND=$(jq -r '.tool_input.command // empty' "$TMPF" 2>/dev/null)
rm -f "$TMPF"
[ -z "$COMMAND" ] && exit 0

NOISY=false
case "$COMMAND" in
  npm\ test*|npx\ jest*|npx\ vitest*|yarn\ test*|pnpm\ test*) NOISY=true ;;
  pytest*|python\ -m\ pytest*) NOISY=true ;;
  go\ test*) NOISY=true ;;
  cargo\ test*) NOISY=true ;;
  mvn\ test*|gradle\ test*) NOISY=true ;;
  npm\ run\ build*|yarn\ build*|pnpm\ build*) NOISY=true ;;
  cargo\ build*) NOISY=true ;;
  make\ *|make) NOISY=true ;;
  tsc\ *|tsc) NOISY=true ;;
esac

[ "$NOISY" = "false" ] && exit 0

# Wrap via bash -c with the original command as a single %q-quoted argument so
# an inline `#` comment (e.g. `go test ./... # note`) cannot comment out the
# wrapper's closing `)`. printf %q expands at hook time into WRAPPED.
# Use `$( ( ... ) 2>&1 )` (space after `$(`) so this is unambiguously a
# command substitution containing a subshell — NOT `$(( ... ))` arithmetic
# expansion. The later `$((_ccn - 40))` IS real arithmetic.
# NOTE: permissionDecision:"allow" re-grant below applies ONLY to commands the
# hardcoded NOISY test/build allowlist already matched — bounded exposure.
_CMD_Q=$(printf '%q' "$COMMAND")
WRAPPED="_ccout=\$( ( bash -c ${_CMD_Q} ) 2>&1 ); _ccexit=\$?; _ccf=\$(mktemp); printf '%s\n' \"\$_ccout\" > \"\$_ccf\"; _ccn=\$(awk 'END{print NR}' \"\$_ccf\"); if [ \"\$_ccn\" -le 50 ]; then cat \"\$_ccf\"; else head -20 \"\$_ccf\"; printf '\n... %d lines omitted ...\n\n' \"\$((_ccn - 40))\"; tail -20 \"\$_ccf\"; fi; rm -f \"\$_ccf\"; exit \$_ccexit"

jq -n --arg cmd "$WRAPPED" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"output compression","updatedInput":{"command":$cmd}}}'
```

Make it executable:
```bash
chmod +x .claude/hooks/bash-compress.sh
```

---

### Step 4e: Create .claude/hooks/precompact-rescue.sh

Use the `Write` tool to create `.claude/hooks/precompact-rescue.sh` with this content:

```bash
#!/usr/bin/env bash
# PreCompact hook — delegate to the dev-team plugin's rescue-capture engine
# (SPEC-018 M12/M13). FAIL-OPEN (M17): always exits 0; exit 2 would block
# compaction and is forbidden. Graceful absence (M18): plugin not installed
# -> log one line, exit 0, compaction proceeds untouched.
#
# Locator: skills/plugin-dir.sh (product lock — not an ad-hoc third locator).
set -u

# Resolve plugin root (PDH): dev-checkout cwd fast path, else highest installed
# cache version. Same bootstrap as /orchestrate and init-orchestration Step 7.
PDH=""
if [ -f skills/plugin-dir.sh ]; then
  PDH=$(pwd)
else
  _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
    -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
    | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./') || _pdh_hit=""
  if [ -n "$_pdh_hit" ]; then
    PDH=$(CDPATH= cd -- "$(dirname -- "$_pdh_hit")/.." && pwd) || PDH=""
  fi
fi

if [ -z "$PDH" ] || [ ! -f "$PDH/skills/plugin-dir.sh" ]; then
  echo "precompact-rescue: dev-team plugin not found — skipping rescue capture" >&2
  exit 0
fi

CAPTURE=$(bash "$PDH/skills/plugin-dir.sh" file skills/handoff/precompact-capture.sh 2>/dev/null) || CAPTURE=""
if [ -z "$CAPTURE" ] || [ ! -f "$CAPTURE" ]; then
  echo "precompact-rescue: precompact-capture.sh not found — skipping rescue capture" >&2
  exit 0
fi

bash "$CAPTURE"   # stdin (the hook JSON) passes through; engine always exits 0
exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/precompact-rescue.sh
```

---

### Step 4f: Create .claude/hooks/rescue-pointer.sh

Use the `Write` tool to create `.claude/hooks/rescue-pointer.sh` with this content:

```bash
#!/usr/bin/env bash
# PostCompact + SessionStart hook — surface the latest PreCompact rescue
# artifact (SPEC-018 M16). POINTER INJECTION ONLY: prints one line naming the
# artifact path and the `/handoff <uuid>` recovery invocation. NEVER dumps
# artifact content into context (M6 discipline). Fail-open: always exits 0.
# SessionStart consumes the marker (one-shot); PostCompact leaves it so the
# NEXT session start still learns about the artifact.
set -u
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && ROOT=$(cd -- "$(dirname -- "$_gc")" && pwd) \
  || ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || exit 0
MARKER="$ROOT/.claude/handoff/.rescue-pointer.json"
[ -f "$MARKER" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Which event is this? (stdin hook JSON; empty/garbage -> treated as unknown)
EVENT=$(head -c 65536 | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("hook_event_name", "") if isinstance(d, dict) else "")' 2>/dev/null)

LINE=$(MARKER_FILE="$MARKER" python3 - <<'PYEOF' 2>/dev/null
import datetime, json, os, sys
try:
    with open(os.environ["MARKER_FILE"], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
art = d.get("artifact") or ""
sid = d.get("session_id") or ""
ca = d.get("created_at") or ""
if not art or not sid or not os.path.isfile(art):
    sys.exit(1)
try:
    age = datetime.datetime.now(datetime.timezone.utc) \
        - datetime.datetime.fromisoformat(ca.replace("Z", "+00:00"))
    if age.total_seconds() > 86400:
        sys.exit(2)   # stale (>24 h): caller deletes the marker silently
except Exception:
    pass
print(f"A pre-compaction rescue artifact exists for session {sid}: {art} — "
      f"run `/handoff {sid}` to rebuild the full brief (the artifact is raw "
      f"material, not the brief).")
PYEOF
)
RC=$?
if [ "$RC" -eq 2 ]; then
  rm -f -- "$MARKER"
  exit 0
fi
if [ "$RC" -ne 0 ] || [ -z "$LINE" ]; then
  exit 0
fi
echo "$LINE"
if [ "$EVENT" = "SessionStart" ]; then
  rm -f -- "$MARKER"
fi
exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/rescue-pointer.sh
```


### Step 4g: Create .claude/hooks/friction-capture.sh

Use the `Write` tool to create `.claude/hooks/friction-capture.sh` with this content:

```bash
#!/usr/bin/env bash
# friction-capture.sh — Live friction telemetry ledger (SPEC-012 M1–M3/M5/M7).
#
# Shared handler for PostToolUseFailure, PermissionDenied, and StopFailure.
# Appends one NDJSON line per accepted event to
#   $MROOT/.claude/retro/friction.jsonl
# Schema (exact keys only — M2 no payload bodies):
#   {"ts":"<ISO-8601>","session_id":"<id>","event":"<name>","tool":"<name or empty>","path":"<optional>"}
#
# FAIL-OPEN (M7): ALWAYS exits 0. Never exits 2. One-line stderr on failure.
# No LLM, no network, bounded stdin read.
#
# Env knobs:
#   FRICTION_LEDGER            full path override for the ledger file (tests)
#   FRICTION_LEDGER_MAX_LINES  default 10000
#   FRICTION_LEDGER_MAX_BYTES  default 5242880 (5 MiB)

set -u   # NOT -e / NOT pipefail: every failure is handled explicitly -> exit 0

fail() { echo "friction-capture: $*" >&2; exit 0; }

command -v python3 >/dev/null 2>&1 || fail "python3 unavailable — skipping"

# Bounded stdin (match precompact-capture / memory-capture hygiene)
STDIN_JSON=$(head -c 65536) || fail "cannot read hook stdin"
[ -n "$STDIN_JSON" ] || fail "empty hook stdin"

# --- Resolve MROOT (worktree-aware) ----------------------------------------
if _fr_gc=$(git rev-parse --git-common-dir 2>/dev/null); then
  MROOT=$(cd -- "$(dirname -- "$_fr_gc")" && pwd) || fail "cannot resolve MROOT"
else
  MROOT="${CLAUDE_PROJECT_DIR:-}"
fi
{ [ -n "$MROOT" ] && [ -d "$MROOT" ]; } || fail "no repo root (not a git repo; CLAUDE_PROJECT_DIR unset)"

LEDGER="${FRICTION_LEDGER:-$MROOT/.claude/retro/friction.jsonl}"
MAX_LINES="${FRICTION_LEDGER_MAX_LINES:-10000}"
MAX_BYTES="${FRICTION_LEDGER_MAX_BYTES:-5242880}"
case "$MAX_LINES" in ''|*[!0-9]*) MAX_LINES=10000 ;; esac
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=5242880 ;; esac

LEDGER_DIR=$(dirname -- "$LEDGER")
mkdir -p "$LEDGER_DIR" 2>/dev/null || fail "cannot create $LEDGER_DIR"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/friction-cap.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$WORKDIR"' EXIT
printf '%s' "$STDIN_JSON" > "$WORKDIR/stdin.json" || fail "cannot stage stdin"

# --- Extract schema fields only; append + rotate under lock ----------------
# python owns parse + write so we never shell-interpolate tool bodies.
python3 - "$WORKDIR/stdin.json" "$LEDGER" "$MAX_LINES" "$MAX_BYTES" <<'PYEOF' || fail "capture/append failed"
import datetime, json, os, sys

stdin_path, ledger, max_lines_s, max_bytes_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    max_lines = max(1, int(max_lines_s))
except ValueError:
    max_lines = 10000
try:
    # Allow small values for tests (env override); floor at 1 byte.
    max_bytes = max(1, int(max_bytes_s))
except ValueError:
    max_bytes = 5242880
try:
    with open(stdin_path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.stderr.write("friction-capture: unparseable hook stdin JSON\n")
    sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("friction-capture: hook stdin is not a JSON object\n")
    sys.exit(1)

session_id = d.get("session_id")
if not isinstance(session_id, str) or not session_id:
    # Graceful skip — missing session_id (M1/M5/M7)
    sys.exit(0)

event = d.get("hook_event_name")
if not isinstance(event, str):
    event = ""

tool = d.get("tool_name")
if not isinstance(tool, str):
    tool = ""

path = ""
ti = d.get("tool_input")
if isinstance(ti, dict):
    for key in ("file_path", "path"):
        v = ti.get(key)
        if isinstance(v, str) and v:
            path = v
            break

ts = (
    datetime.datetime.now(datetime.timezone.utc)
    .isoformat()
    .replace("+00:00", "Z")
)

row = {
    "ts": ts,
    "session_id": session_id,
    "event": event,
    "tool": tool,
    "path": path,
}
# M2: only schema keys — never tool_result / error text / full tool_input
line = json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n"

lock_path = ledger + ".lock"
try:
    lock_fd = open(lock_path, "a+", encoding="utf-8")
except OSError as e:
    sys.stderr.write("friction-capture: cannot open lock: %s\n" % e)
    sys.exit(1)

have_lock = False
try:
    try:
        import fcntl
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        have_lock = True
    except Exception:
        have_lock = False

    try:
        with open(ledger, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())
    except OSError as e:
        sys.stderr.write("friction-capture: append failed: %s\n" % e)
        sys.exit(1)

    try:
        size = os.path.getsize(ledger)
    except OSError:
        size = 0

    need_rotate = size > max_bytes
    if not need_rotate:
        try:
            with open(ledger, "r", encoding="utf-8", errors="replace") as fh:
                nlines = sum(1 for _ in fh)
            need_rotate = nlines > max_lines
        except OSError:
            need_rotate = False

    if need_rotate:
        try:
            with open(ledger, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError as e:
            sys.stderr.write("friction-capture: rotate read failed: %s\n" % e)
            sys.exit(0)

        # Drop oldest until within both caps (keep newest).
        while lines:
            if len(lines) <= max_lines:
                byte_len = sum(len(x.encode("utf-8")) for x in lines)
                if byte_len <= max_bytes:
                    break
            lines.pop(0)

        tmp = ledger + ".tmp." + str(os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.writelines(lines)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, ledger)
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            sys.stderr.write("friction-capture: rotate write failed: %s\n" % e)
finally:
    if have_lock:
        try:
            import fcntl
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
    try:
        lock_fd.close()
    except Exception:
        pass
PYEOF

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/friction-capture.sh
```

This shared handler is registered for `PostToolUseFailure`, `PermissionDenied`, and `StopFailure` (Step 3). Fail-open always (exit 0). Appends NDJSON to `$MROOT/.claude/retro/friction.jsonl` (schema: `ts`, `session_id`, `event`, `tool`, `path` only — no payload bodies). On older Claude Code versions that lack an event key, the settings entry is inert (graceful absence — SPEC-012 M5).

---

### Step 5: Create or update AGENTS.md

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
- Update spec files whenever behavioral changes are made
- Use project-local paths for all plans, specs, and memory — never global `~/.claude/` paths
- When releasing, bump ALL version references (code, config, changelog, tags)
- When comparing or cross-checking documents, analyze differences first — never blindly merge

**DO NOT:**
- Over-plan: if asked for a fix or implementation, proceed quickly unless a plan is explicitly requested
- Write to global paths (`~/.claude/`) when project-local paths exist
- Commit implementation changes without checking if related specs need updating

## Change Discipline

All agents MUST follow these rules. The orchestrator enforces them, but agents should self-police.

**Atomic PRs:**
- One logical change per PR. One ticket = one branch = one PR. Never bundle.
- If a task description needs "and" to explain it, split it first.

**Size limits:**
- ~1,000 LOC of real code per PR (soft cap). Tests, generated code, migrations don't count.
- Hard cap: 2,000 LOC total including tests. Exceeding this = stop and split.
- No single file > 1,000 lines. If approaching this, pause and discuss decomposition with Tech Lead.

**Refactoring is always separate:**
- Never mix refactoring with feature work in the same PR.
- If you need to refactor before implementing: stop, flag to orchestrator/Tech Lead, ship refactor PR first, then resume feature work on the clean base.
- Large refactors get their own ticket.

**Discovered work → new tickets:**
- Never absorb unplanned work into the current change.
- Flag it to the orchestrator. It becomes a new ticket (Linear or backlog).
- If it blocks current work, escalate — don't silently expand scope.

**Replan on deviation:**
- If your approach changes materially from the plan (new deps, scope grew, architecture assumption broken): stop all work and request a replan from Tech Lead.
- Small deviations compound. When in doubt, stop and ask.

## Tool-Offload Discipline

Tool I/O (file reads, command output) is the dominant consumer of the context
window and is what forces compaction. Keep the window clean by offloading bulk
tool I/O to subagents that return **conclusions, not raw dumps**. Applies to both
the main orchestrating loop and every spawned agent.

You **MUST** offload when a step would read **3+ files**, read **> ~400 lines**
from one file, or run a command whose output is **> ~50 lines or unbounded**
(test suites, builds, full `git log`/`diff`, recursive `grep`/`find`) — when you
need the *answer*, not the raw text in-window. Below that bar — a single known
file you must edit, a short targeted read, a bounded command, or any case where
you genuinely need the raw text (e.g. an exact string to edit) — read directly;
the rule does not apply (it is not an exception to it).

Offload by spawning a subagent (`Task`, `subagent_type: "general-purpose"`, or
`"Explore"` if available) that returns findings + pointers (`file:symbol`,
`path:Ln`) and never pasted raw output. Add `Output mode: terse`.

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
- `SendMessage` is for **peer-to-peer** DMs only. Spawned sub-agents have NO addressable parent — there is no agent named `main` or `orchestrator`. Return work to the orchestrator as your final message; the orchestrator reads it from your spawn-return value, not from an inbound SendMessage.
- Do NOT edit files another teammate is actively working on
- After finishing, send a status update to the team lead

## Commit Rules

- [Project-specific commit convention, e.g., conventional commits]
- Always include: `Co-Authored-By: Claude <model> <noreply@anthropic.com>`
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
- `SendMessage` is for **peer-to-peer** DMs only. Spawned sub-agents have NO addressable parent — there is no agent named `main` or `orchestrator`. Return work to the orchestrator as your final message; the orchestrator reads it from your spawn-return value, not from an inbound SendMessage.
- Do NOT edit files another teammate is actively working on
- After finishing, send a status update to the team lead
```

---

### Step 6: Create or update CLAUDE.md

**If `CLAUDE.md` does not exist** — create it with just the reference line (see template below).

**If `CLAUDE.md` already exists and has content beyond an AGENTS.md reference:**
1. Read the existing `CLAUDE.md` content
2. Migrate any rules, instructions, or project details into the appropriate sections of `AGENTS.md` (created/updated in Step 5):
   - Workflow rules → `## Critical Rules`
   - Build/test/tech stack info → `## Project Overview`
   - File conventions → `## Code Conventions` or `## Critical Rules`
   - Any other project-specific instructions → appropriate AGENTS.md section
3. Do NOT duplicate — if equivalent rules already exist in AGENTS.md, skip them
4. Replace `CLAUDE.md` contents with just the reference line

**If `CLAUDE.md` already exists and is only the reference line** — no changes needed, skip.

#### CLAUDE.md template

```markdown
Read and follow [AGENTS.md](./AGENTS.md) before starting any work.
```

All project rules live in AGENTS.md. CLAUDE.md just ensures Claude Code loads them.

---

### Step 7: Seed orchestrator memory

Create the Claude Code memory directory and seed it with learned patterns from past sessions. These prevent known mistakes from being repeated in every new project.

**Single-root anchor.** Resolve ONE project root and put every Step-7 `.claude/` op under it. All-or-nothing — never mix absolute and relative siblings. Use `--show-toplevel`, **not** `--git-common-dir` (common-dir would resolve a parent worktree's shared root, not the project being bootstrapped). (Emitted hook templates above that resolve `MEMDB` via `git-common-dir` are intentional — those run at *hook runtime* in the target project, not during this bootstrap.)

```bash
PROJ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$PROJ_ROOT/.claude/memory/claude"
MEMDB="$PROJ_ROOT/.claude/memory/memory.db"
```

If sqlite3 is available and the DB does not yet exist, initialize it:
```bash
PROJ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$PROJ_ROOT/.claude/memory/memory.db"
if command -v sqlite3 &>/dev/null && [ ! -f "$MEMDB" ]; then
  # Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (dead in Bash fences today — FR #48230; forward-compat), else dev checkout, else installed cache (pre-release-safe sort -V). Slug-free.
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
  SCHEMA=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/schema.sql)
  if [ -f "$SCHEMA" ]; then
    sqlite3 "$MEMDB" < "$SCHEMA"

    # Probe journal mode. Some sandboxed filesystems (bubblewrap
    # tmpdirs, NFS, certain CI containers) reject WAL and SQLite
    # silently degrades to journal_mode=delete. The DB still works
    # but writes serialize across agents — surface this so the user
    # knows what they're getting.
    JMODE=$(sqlite3 "$MEMDB" "PRAGMA journal_mode;" 2>/dev/null | tr 'A-Z' 'a-z')
    if [ "$JMODE" != "wal" ]; then
      echo "⚠️  memory.db journal_mode=$JMODE (WAL rejected by this filesystem)." >&2
      echo "    DB works correctly; concurrent agent writes will serialize" >&2
      echo "    instead of running in parallel. Common cause: sandboxed tmpdir" >&2
      echo "    or NFS-backed project root. Re-running outside the sandbox or" >&2
      echo "    on a local filesystem will enable WAL." >&2
    fi
  fi
fi
```

**If `$PROJ_ROOT/.claude/memory/claude/memory.md` does not exist AND no DB row exists** — create/seed both paths below.

**If it already exists** — read it, check if the orchestrator rules section is present. If not, append it. Do not duplicate.

#### Baseline memory content

```markdown
# Project Memory

## Orchestrator rules (seeded by /setup orchestration)

- When acting as orchestrator/coordinator, NEVER implement code directly — not even "quick fixes" for broken agent output. Always create a task and assign to an IC agent.
- After each agent phase completes, create an explicit "validate and debug" task before starting the next phase. Quality gaps between defined tasks are where bugs hide.
- Agents stuck after 2 genuine attempts → escalate to user. Don't let them loop.
- Scope creep discovered mid-implementation → pause and ask user whether to expand scope or defer to backlog. Never silently absorb extra work.
- Breaking changes (schema, API contracts, dependency bumps) → always escalate to user before proceeding.
- Batch questions for the user — don't interrupt for routine progress. Protect their time.
- When spawning agents, give them the worktree path, spec path, and plan path explicitly. Don't assume they'll find context on their own.
- Atomic PRs only — one ticket, one branch, one PR. Never bundle multiple tickets.
- ~1k LOC real code per PR (tests don't count). Hard cap 2k total. No single file > 1k lines. Exceeding = stop and split.
- Refactoring is always a separate PR — never mixed with feature work. Ship refactor first, then feature on top.
- Discovered work becomes a new ticket — never silently absorb unplanned work into the current change.
- Material approach changes → pause all IC work, Tech Lead replans, user approves before resuming.
- `dangerouslyDisableSandbox` is per-command, not a session state. Only use it when the specific command needs it (heredocs, process substitution). Never carry it forward after one command requires it — `pwd`, `ls`, `python3 -c`, `chmod` and similar never need it.
```

Write this content using the DB-first dual path.

**If DB exists:** use the `Bash` tool to run the python3 sqlite3 insert:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
python3 -c "
import sqlite3, sys, datetime
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('DELETE FROM memories WHERE agent=? AND type=? AND content LIKE ?',
           ('claude', 'memory', '%seeded by /setup orchestration%'))
db.execute('INSERT INTO memories(agent, type, content, updated_at) VALUES (?, ?, ?, ?)',
           ('claude', 'memory', sys.argv[2], datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')))
db.commit()
" "$MEMDB" "$CONTENT"
```

**If no DB:** use the `Write` tool to create `$PROJ_ROOT/.claude/memory/claude/memory.md` with the baseline content above.

---

### Step 8: Validate

Run the hook manually to confirm it passes. Use file redirection — NOT a pipe (`echo '{}' | bash ...` poisons the session):
```bash
printf '{}' > "$TMPDIR/hook-test-$$"
bash .claude/hooks/task-completed.sh < "$TMPDIR/hook-test-$$"
echo "Hook exit code: $?"
rm -f "$TMPDIR/hook-test-$$"
```

Validate settings.json is still valid JSON:
```bash
python3 -c "import json; json.load(open('.claude/settings.json')); print('settings.json OK')"
```

**Warn about piped user hooks:** Check whether any existing hooks in settings.json use pipe operators (`|`). If found, warn the user:
```
⚠️  WARNING: The following hook commands use pipes ('|') which fail in the sandbox
and will poison the session, causing all subsequent bash commands to fail:

  [list the piped hook commands]

Fix: remove the pipe and any command after it, or replace with a non-piped equivalent.
Example: 'go vet ./... 2>&1 | head -20' → 'go vet ./... 2>&1'
A restart is required after fixing hooks.
```

---

### Step 9: Summary

Print a summary of what was done:

```
✅ Agent Teams orchestration initialized!

Updated:
  📄 .claude/settings.json   — sandbox + dontAsk + matrix allow (Bash(*)+Read/Write/Edit/Glob/Grep/Agent/Task) + PreToolUse + PostToolUse + Stop + TaskCompleted + PreCompact + PostCompact + SessionStart + PostToolUseFailure + PermissionDenied + StopFailure hooks
      Sandbox: enabled, autoAllowBash, network: [list of configured domains]
  📄 .claude/hooks/task-completed.sh — quality-gate hook (customize for your project)
  📄 .claude/hooks/stop-review.sh   — self-review gate (one-shot warning on uncommitted changes)
  📄 .claude/hooks/memory-capture.sh — auto memory (logs Write/Edit to tier-0)
  📄 .claude/hooks/bash-compress.sh — output compression (rewrites noisy test/build commands inline)
  📄 .claude/hooks/precompact-rescue.sh — PreCompact rescue capture (SPEC-018 M12)
  📄 .claude/hooks/rescue-pointer.sh — PostCompact/SessionStart pointer surfacing (M16)
  📄 .claude/hooks/friction-capture.sh — live friction ledger (SPEC-012 M1; PostToolUseFailure/PermissionDenied/StopFailure)
  📄 AGENTS.md               — team coordination rules [created/appended]
  📄 CLAUDE.md                — AGENTS.md reference [created/migrated]
  📄 .claude/memory/claude/memory.md — orchestrator rules seeded [created/updated]

Next steps:
  1. Customize .claude/hooks/task-completed.sh with project-specific checks
     (uncomment test runner, JSON validation, spec-change check, or add your own)
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
- If `CLAUDE.md` already exists and references AGENTS.md: no changes needed, skip this step
- If `.claude/hooks/` cannot be created (permissions): report the error with the manual command to run

## Important Notes

- This skill is idempotent — safe to run multiple times without clobbering existing content
- **Force-overwrite disclosure (CDT-51 AC5):** any force change of a managed settings value or hook file MUST print `key` / `old` / `new` / `restore` before the write (`disclose-force-overwrite.sh` or the fallback block). Forced + silent = FAIL
- The hook script exits 0 by default (pass-through) until customized
- Agent Teams require Claude Code restart after `settings.json` changes for the env var to take effect
- Teammates do not inherit conversation history — AGENTS.md is their primary orientation document
