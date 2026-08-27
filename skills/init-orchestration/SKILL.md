---
name: init-orchestration
description: >
  Internal protocol for /setup orchestration — Agent Teams bootstrap (settings,
  hooks, AGENTS.md seed). Not a user entry; invoke via /setup orchestration.
---

# Init Orchestration (backend for `/setup orchestration`)

> **Entry:** `/setup orchestration`.
> This file is the skill-delegate backend for `commands/setup.md` — not a
> primary slash command. The old `/init-orchestration` command was removed at
> v1.1; this protocol body is permanent (v1.1 contract: protocol-retained backends).
> Live helpers: `check-hook-templates.sh` (template-internal hygiene
> gate — extractability/shebang/`bash -n`; dual-copy live-vs-template retired
> CDT-54); `disclose-force-overwrite.sh` (CDT-51 AC5 force-overwrite disclosure);
> `normalize-hook-paths.sh` (CDT-69 Step 1 absolute/relative hook-path upgrade);
> `sweep-legacy-orphans.sh` (CDT-76 known-legacy-orphan list sweep);
> `test-orch-allowlist.sh` (CDT-51 TL P0 matrix allow ⊇ greenfield template);
> `signing-sandbox.sh` (CDT-211 commit-signing sandbox allowlist).

Bootstrap the files needed for Claude Code Agent Teams in the current project.

## Permission batching (CDT-68 — read before mutating)

`/setup orchestration` is **not pure zero-intervention**. After posture lands
(`defaultMode: "auto"` Cell D + sandbox; see matrix winner), three self-escalation-
guarded paths still require **explicit user approval** — by design; do not remove
the guards:

| Path | Why it prompts |
|------|----------------|
| Merge / write `.claude/settings.json` | Self-modification of project permissions/hooks (Edit or jq-via-Bash); also sandbox-protected |
| Write `.claude/hooks/bash-compress.sh` | Emitted body uses `permissionDecision:"allow"` on noisy test/build rewrites — classifier treats as permission-widening; generic "approve edits" is often rejected |
| Write `.claude/hooks/escalation-gate.sh` | A `PreToolUse` hook that can **BLOCK** (exit 2) a matched `Write`/`Edit`/`NotebookEdit` call is a material behavior change (SPEC-031) — disclose before install, not just in the skill body |

**MUST batch all three approvals in ONE ask up front** (before Step 3 settings
write, before Step 4d bash-compress emit, and before Step 4i escalation-gate
emit). Include the honest-limits framing for escalation-gate.sh in the same
ask — the user approving installation should see "NOT tamper-proof" at
install time, not only buried in Step 4i. Example:

```
This /setup orchestration needs three explicit approvals (settings self-mod
guards — intentional; not removable without losing the guard):
  1. Merge into .claude/settings.json (sandbox + hooks + auto + matrix allow)
  2. Write .claude/hooks/bash-compress.sh (PreToolUse; permissionDecision:allow
     bounded to the hardcoded NOISY test/build allowlist)
  3. Write .claude/hooks/escalation-gate.sh (PreToolUse; WARNs on out-of-worktree
     writes, BLOCKs only when the run is armed — armed only on an
     escalate-and-auto-chain handoff, disarmed when it completes). NOT tamper-proof:
     Bash-issued writes (sed -i, heredocs, git apply, git commit) bypass it
     entirely; the same agent it constrains writes its own armed marker, so it
     detects drift in a compliant run but does not defend against a
     non-compliant one; only Write/Edit/NotebookEdit are gated, no other write
     path; and path matching falls back to unnormalized `..` traversal when
     `realpath` is unavailable. See SPEC-031 § Hook contract — honest limits.
Approve all three so bootstrap can finish without mid-run denials?
```

Also: sandbox denials on settings writes still need
`dangerouslyDisableSandbox: true` on the retry command (separate from the
permission classifier). Temp paths in bypass-retry snippets MUST use
`"${TMPDIR:-/tmp}/…"` or `mktemp` — bare `$TMPDIR` is often unset outside
the sandbox.

**Do not** strip `permissionDecision:"allow"` from bash-compress without
strong evidence the CC re-check on rewritten commands is gone (kept for
CC 2.1.116+). Prefer docs + batch ask over weakening the hook.

**Doctor circular gate (CDT-67):** Step 0 uses `dev-team:doctor --gate=orchestration`
so self-remediating FAILs whose fix-it is exactly `/setup orchestration` exit ≤1
instead of blocking the bootstrap that would fix them.

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
│   │   ├── friction-capture.sh        # Live friction ledger (SPEC-012 M1; PostToolUseFailure/PermissionDenied/StopFailure)
│   │   └── escalation-gate.sh         # Worktree-isolation gate (SPEC-031; PreToolUse Write/Edit/NotebookEdit — warns, blocks only when armed)
│   └── memory/
│       └── claude/
│           └── memory.md      # Orchestrator rules seeded (created or appended)
├── AGENTS.md                  # Team coordination rules (created or appended)
└── CLAUDE.md                  # AGENTS.md reference (created, existing content migrated)
```

## Instructions

### Step 0: Doctor hard-gate (before any mutation)

Hard-gate on plugin **`dev-team:doctor`** with `--gate=orchestration`
(SPEC-005 / SPEC-022 M6b/M6c). This is the plugin doctor surface — **not** the
Claude Code harness built-in `/doctor`. Exit ≤1 (PASS, WARN, or self-remediating
FAIL whose fix-it is exactly `/setup orchestration`) continues; exit 2 (blocking
FAIL) **blocks** bootstrap. Override: `--skip-doctor` prints an explicit WARNING
then continues (silent skip forbidden). Marketplace install has no gate.

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
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  DOCTOR_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/doctor/doctor.sh 2>/dev/null) || DOCTOR_SH=""
  if [ -z "$DOCTOR_SH" ] || [ ! -f "$DOCTOR_SH" ]; then
    echo "FAIL: dev-team:doctor (plugin /doctor) not found — cannot gate /setup orchestration." >&2
    echo "Remediation: reinstall the dev-team plugin, then re-run /setup orchestration (or pass --skip-doctor)." >&2
    # STOP — do not mutate settings/hooks/AGENTS.md
    exit 2
  fi
  set +e
  bash "$DOCTOR_SH" --gate=orchestration
  DOCTOR_RC=$?
  set -e
  if [ "$DOCTOR_RC" -ge 2 ]; then
    echo "FAIL: dev-team:doctor exited $DOCTOR_RC (FAIL). /setup orchestration blocked." >&2
    echo "Remediation: fix FAIL rows above, re-run /doctor (plugin surface dev-team:doctor — not the Claude Code harness /doctor), then retry /setup orchestration. Override: /setup orchestration --skip-doctor" >&2
    # STOP — do not mutate settings/hooks/AGENTS.md
    exit 2
  fi
  # exit 0 (PASS) or 1 (WARN / self-remediating under --gate=orchestration) → continue to Step 1
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

2. **Worktree-unsafe / non-portable hook paths** — two legacy forms never match the managed template and leave doctor `hooks.hygiene` WARN forever if not upgraded:

   - **Relative** — `bash .claude/hooks/<name>.sh` resolves from the agent's cwd, not the project root. Inside a git worktree (which doesn't share `.claude/`) every Bash tool call fails with "No such file or directory".
   - **Absolute under project root** — `bash /abs/path/to/proj/.claude/hooks/<name>.sh` (or the same path quoted) works only while the project stays at that path; doctor treats it as un-anchored (`hooks.hygiene` WARN). Match when the path is `$MROOT/.claude/hooks/<name>.sh` **or** ends with `/.claude/hooks/<name>.sh` and is under the project root.

   Auto-rewrite **both** forms to the managed `${CLAUDE_PROJECT_DIR}` form:
```
bash .claude/hooks/X.sh
bash /abs/path/to/proj/.claude/hooks/X.sh
bash "/abs/path/to/proj/.claude/hooks/X.sh"
  →  bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/X.sh"
```
   Leave alone: already-anchored commands, and absolute paths **outside** the project root (user-owned hooks).

   This **changes** an existing managed hook value → **MUST** disclose first (SPEC-005 / CDT-51 AC5; forced + silent = FAIL). Prefer the helper (install-aware PDH, same formula as Step 0):

```bash
# Re-resolve DISCLOSE / NORMALIZE (each fenced bash block is a fresh shell — skill-lint C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
NORMALIZE=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/normalize-hook-paths.sh 2>/dev/null) || NORMALIZE=""
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
SETTINGS="${MROOT}/.claude/settings.json"
if [ -n "$NORMALIZE" ] && [ -f "$NORMALIZE" ] && [ -f "$SETTINGS" ]; then
  set +e
  bash "$NORMALIZE" --settings "$SETTINGS" --project-root "$MROOT"
  NORM_RC=$?
  set -e
  # exit 0 → rewrote + disclosed each change; exit 1 → already normalized (no-op)
  # Helper prints FORCE-OVERWRITE key/old/new/restore per change (via disclose-force-overwrite.sh)
else
  # Fallback: agent rewrites matching commands and MUST print the same labels per change
  # before writing settings.json (use disclose-force-overwrite.sh --key/--old/--new/--restore)
  :
fi
```

   Apply for every matching hook command. Note absolute-path and relative-path rewrites in the Step 9 summary as upgrades applied.

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
  "allowWrite": ["~/.cache/go-build"]
}
```

#### Commit signing sandbox (CDT-211)

Detect ON iff `git config --bool --get commit.gpgsign` OR `tag.gpgsign`. `gpg.format` selects paths only (`openpgp` default; `x509` same paths; `ssh` does not add `~/.ssh`). OFF → skip; no mutations. ON → offer options (default 1). Apply as merge-after Step 3; do not bake `~/.gnupg` or `git` into the greenfield template.

1. Recommended: unique-append `sandbox.filesystem.allowWrite` `~/.gnupg`; macOS unique-append `sandbox.network.allowUnixSockets` `~/.gnupg/S.gpg-agent` (ssh: also `$SSH_AUTH_SOCK` when set); Linux/WSL2 set `sandbox.network.allowAllUnixSockets: true` (disclose Linux socket blast radius). If `/run/user/$(id -u)` exists, unique-append `/run/user/$(id -u)/gnupg` to `.claude/settings.local.json` allowWrite only — never a UID path in committed `settings.json`.
2. Unique-append `git` to `sandbox.excludedCommands`.
3. `git config --local commit.gpgsign false` + remote-signature warning (not default).

Re-run: same detect; no-op if mitigated (`~/.gnupg` in allowWrite AND platform socket keys, OR `git` in excludedCommands); else unique-append; preserve other filesystem keys. Adding a missing key is not force-overwrite. Flipping `allowAllUnixSockets` false→true MUST disclose (CDT-51 AC5).

```bash
# Re-resolve SIGNING (each fenced bash block is a fresh shell — skill-lint C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SIGNING=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/signing-sandbox.sh 2>/dev/null) || SIGNING=""
SETTINGS=".claude/settings.json"
SETTINGS_LOCAL=".claude/settings.local.json"
if [ -n "$SIGNING" ] && [ -f "$SIGNING" ]; then
  set +e
  bash "$SIGNING" detect
  SIGN_RC=$?
  set -e
  # exit 0 → ON (prompt options 1/2/3, default 1, then apply); exit 1 → OFF skip
  # bash "$SIGNING" apply --option N --settings "$SETTINGS" --settings-local "$SETTINGS_LOCAL"
fi
```

---

### Step 3: Write .claude/settings.json

**Precondition (CDT-68):** confirm the user already approved the settings merge
in the up-front batch ask (see **Permission batching under `dontAsk`**). If not,
ask now (settings merge + bash-compress + escalation-gate by name) before writing.

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
      },
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/escalation-gate.sh\""
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
    "defaultMode": "auto"
  }
}
```

> **RISK (intentional posture — matrix winner Cell D / CDT-75).** `defaultMode:
> "auto"` + matrix allow set (`Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task) +
> sandbox (`enabled` + `autoAllowBashIfSandboxed`) is the shipped orchestration
> posture (evidence: `docs/runbooks/permission-posture-matrix.md` `## Winner`).
> `auto` evaluates tools within policy/sandbox — allow-set core tools and
> (interactively) MCP such as Linear can run without a static `mcp__*` allow
> entry. It is **not** `bypassPermissions`: sandbox remains the OS boundary for
> Bash; settings self-mod and other high-risk paths can still deny or prompt.
> Keep the full matrix allow set so core tools stay predictable. Users who
> disable the sandbox lose that boundary. (Solo path: `/setup project` uses
> `acceptEdits` + curated Bash allowlist.) Historical Cell C (`dontAsk`)
> hard-denies non-allow tools (MCP silent-deny — CDT-74); do not re-ship it as
> default without re-proving Linear-first.

**If `settings.json` already exists** — read it, then merge in the missing keys:
- Add `"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }` if `env` key is absent
- If `env` key exists but lacks `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, add it to the existing `env` object
- Add the `PreToolUse`, `PostToolUse`, `Stop`, `TaskCompleted`, `PreCompact`, `PostCompact`, `SessionStart`, `PostToolUseFailure`, `PermissionDenied`, and `StopFailure` hooks entries if `hooks` key is absent
- If `hooks` key exists but lacks any of `PreToolUse`, `PostToolUse`, `Stop`, `TaskCompleted`, `PreCompact`, `PostCompact`, `SessionStart`, `PostToolUseFailure`, `PermissionDenied`, or `StopFailure`, add the missing ones
- **`PreToolUse` merges at the array level, not the event-key level** — every other event above is satisfied by "add the key if absent". `PreToolUse` is not: this skill contributes **two** entries (`bash-compress`, `escalation-gate`) and `/tdd-gate on` contributes a third into the *same* array. Apply the append rule below **per entry**; never replace an existing non-empty `PreToolUse` array wholesale
- `PreCompact`/`PostCompact`/`SessionStart` require a Claude Code version that supports those hook events; on older versions the entries are inert (graceful absence — SPEC-018 M18)
- `PostToolUseFailure`/`PermissionDenied`/`StopFailure` wire the shared friction ledger handler (SPEC-012 M1/M5); on older CC versions that lack an event the entry is inert (graceful absence). All three point at the same `friction-capture.sh`.
- Add `sandbox` block if absent (`enabled: true`, `autoAllowBashIfSandboxed: true`, `excludedCommands: ["docker", "docker-compose"]`, `network.allowedDomains` from Step 2). If `sandbox` exists: ensure `enabled` is `true` and `autoAllowBashIfSandboxed` is `true`; merge new domains into existing `allowedDomains` (no duplicates); preserve any existing `filesystem` overrides. Signing options apply as merge-after via `signing-sandbox.sh` (do not add `~/.gnupg` to the greenfield template)
- Ensure `permissions.allow` contains **every** entry from the greenfield template allow list above (matrix set: `Bash(*)`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `Task`) — add any missing entries; preserve any other existing allow entries. Ensure `permissions.defaultMode` matches the **managed orchestration defaultMode** from the greenfield template block above (read that template value, then write it — currently `"auto"` Cell D / CDT-75; do not hard-code a second diverging copy). Add or update as needed (including flipping a prior `bypassPermissions` / `dontAsk` / other mode to the managed value)
- **Force-overwrite disclosure (SPEC-005 / CDT-51 AC5):** when a re-run **changes** an existing managed value (especially `permissions.defaultMode`, `sandbox.enabled`, `sandbox.autoAllowBashIfSandboxed`), you **MUST** print old value, new value, and restore key/path **before** writing. Forced + silent = FAIL. Use the helper below (or print the same labeled block). Adding a missing key is not a force-overwrite (no disclosure required).
- Write the merged result back as valid JSON

#### `PreToolUse` array append rule (SPEC-031)

**The rule.** For each managed `PreToolUse` entry, in order:

1. If `hooks.PreToolUse` is **absent**, create it as an array holding that one entry.
2. If it **exists and is an array**, **append** the entry — preserving every element
   already there, whoever wrote it.
3. Before appending, **dedup by identity = `matcher` + the entry's set of `command`
   strings**. If an element with the same identity is already present, append nothing.
   Matching on `matcher` alone would wrongly collapse two different hooks that share a
   matcher; matching on `command` alone would wrongly collapse the same script
   registered under two matchers.
4. If it exists but is **not** an array (hand-malformed settings), wrap the existing
   value in a one-element array first, then apply 2–3. Never discard it.

**Why dedup rather than blind append.** Verified on Claude Code v2.1.212: multiple
`PreToolUse` entries all execute for a matching tool call, and any one of them exiting
`2` blocks the call. A duplicate entry is therefore *wasteful, not harmful* — it runs the
same script twice. Dedup keeps re-runs of `/setup orchestration` idempotent; it is not
load-bearing for correctness.

**Coexistence with `/tdd-gate on`.** `/tdd-gate on` Step 4b writes its own entry into
this same array and `/tdd-gate off` removes only the element referencing `tdd-gate.sh`.
Both directions are safe **because both sides append and remove element-wise**. Install
order does not matter:

- `/setup orchestration` first, `/tdd-gate on` second → tdd-gate appends a third element;
  `bash-compress` and `escalation-gate` are untouched.
- `/tdd-gate on` first, `/setup orchestration` second → the rule above appends to the
  array that already holds tdd-gate's element; tdd-gate's element is untouched.

The two never collide on the dedup key: tdd-gate's entry carries **no** `matcher` (it
self-filters on `tool_name` inside the script), so its identity is `("", [tdd-gate.sh])`
— distinct from `("Write|Edit|NotebookEdit", [escalation-gate.sh])`.

**Implementation.** Apply once per managed entry (`bash-compress`, `escalation-gate`):

```bash
SETTINGS=".claude/settings.json"
[ -f "$SETTINGS" ] || printf '%s\n' '{}' > "$SETTINGS"

# One managed PreToolUse entry. Repeat this block per entry, changing ENTRY only.
# ${CLAUDE_PROJECT_DIR} is deliberately literal in the stored JSON — Claude Code
# expands it at hook-run time, so single quotes here are correct.
ENTRY='{"matcher":"Write|Edit|NotebookEdit","hooks":[{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/escalation-gate.sh\""}]}'

if command -v jq >/dev/null 2>&1; then
  jq --argjson entry "$ENTRY" '
    def hookkey: [(.matcher // ""), ((.hooks // []) | map(.command // "") | sort)];
    .hooks.PreToolUse = (
      ((.hooks.PreToolUse // []) | if type == "array" then . else [.] end) as $arr
      | if any($arr[]; hookkey == ($entry | hookkey))
        then $arr
        else $arr + [$entry]
        end
    )
  ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS" \
    && echo "PreToolUse: entry present in $SETTINGS"
else
  echo "WARNING: jq not found — append this entry to hooks.PreToolUse in $SETTINGS by hand:"
  printf '%s\n' "$ENTRY"
fi
```

`jq` writes to `${SETTINGS}.tmp` and `mv`s only on success, so a jq failure leaves the
existing `settings.json` intact rather than truncating it.

#### Force-overwrite disclosure helper (managed settings)

Locate the helper (install-aware PDH, same formula as Step 0):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
DISCLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/disclose-force-overwrite.sh 2>/dev/null) || DISCLOSE=""
```

For each managed key that will change, run **before** the write. Read the new defaultMode from the greenfield template in this skill (not a second hard-coded string):

```bash
# Re-resolve DISCLOSE (each fenced bash block is a fresh shell — skill-lint C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
DISCLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/disclose-force-overwrite.sh 2>/dev/null) || DISCLOSE=""
SETTINGS=".claude/settings.json"
# NEW_DEFAULT_MODE = value of permissions.defaultMode in the greenfield template above
# (currently auto / Cell D winner — re-read the template if it changes)
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
    PDH=$(pwd)  # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza)
  else
    _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
      -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
      | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./') || _pdh_hit=""
    if [ -n "$_pdh_hit" ]; then
      # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza)
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

# Read task metadata — shadow-safe candidate set (CDT-167 / SPEC-002).
# Candidates = flat <T>.json (if present) ∪ all *-<T>.json (nullglob-safe).
# effective_requires_council = any candidate requires_council true (AC1, AC6).
# MUST NOT short-circuit on first flat false when a compound true exists.
# Live hooks need `/setup orchestration` re-run after pull (template SoT / CDT-54).
TASKS_DIR="$MROOT/.claude/tasks"
CANDIDATES=()
if [ -f "${TASKS_DIR}/${TASK_ID}.json" ]; then
  CANDIDATES+=("${TASKS_DIR}/${TASK_ID}.json")
fi
_prev_nullglob=
shopt -q nullglob && _prev_nullglob=1
shopt -s nullglob
for _cand in "${TASKS_DIR}/"*"-${TASK_ID}.json"; do
  CANDIDATES+=("$_cand")
done
if [ -z "$_prev_nullglob" ]; then
  shopt -u nullglob
fi
unset _prev_nullglob _cand

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  # Silent pass — pure-missing (AC5); task pre-dates the gate or is not tracked
  _emit_task_complete
  exit 0
fi

# Scan all candidates for any-true; prefer true compound over true flat for TASK_META.
# Multi-true compounds (CDT-186): preferred P = lex-asc min stem (basename without .json).
# Output: line1 = true|false, line2 = preferred meta path (empty if none true).
META_SCAN=$(python3 -c '
import json, os, sys
task_id = sys.argv[1]
true_compounds = []  # (stem, path) for requires_council true and stem != task_id
true_flat = None
for path in sys.argv[2:]:
    try:
        data = json.load(open(path))
        rc = bool(data.get("requires_council", False))
    except Exception:
        continue
    if not rc:
        continue
    stem = os.path.basename(path)
    if stem.endswith(".json"):
        stem = stem[:-5]
    if stem == task_id:
        if true_flat is None:
            true_flat = path
    else:
        true_compounds.append((stem, path))
if true_compounds:
    true_compounds.sort(key=lambda x: x[0])  # lex-asc basename; deterministic multi-true
    print("true")
    print(true_compounds[0][1])
elif true_flat is not None:
    print("true")
    print(true_flat)
else:
    print("false")
    print("")
' "$TASK_ID" "${CANDIDATES[@]}" 2>/dev/null || printf '%s\n' "false" "")

REQUIRES_COUNCIL=$(printf '%s\n' "$META_SCAN" | sed -n '1p')
TASK_META=$(printf '%s\n' "$META_SCAN" | sed -n '2p')

if [ "$REQUIRES_COUNCIL" != "true" ]; then
  _emit_task_complete
  exit 0  # silent pass — no candidate opted into the gate
fi

# Prefer true candidate path for COMPOUND_KEY derivation below (index gate).
# If python omitted path somehow, fall back to first candidate that is -f.
if [ -z "$TASK_META" ] || [ ! -f "$TASK_META" ]; then
  TASK_META="${CANDIDATES[0]}"
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

# Look up task in index. CDT-163 isolate scores (template SoT; regen live hooks via
# /setup orchestration — AC10). Resolve at most ONE index key; never union/extend
# scores across ≥2 keys. Dual-shape conf (CDT-122) unchanged under that single key.
# Order: exact T → distinct preferred compound P only → unique suffix of bare T.
COMPOUND_KEY=""
_meta_base=$(basename -- "$TASK_META" .json 2>/dev/null || true)
if [ -n "$_meta_base" ] && [ "$_meta_base" != "$TASK_ID" ]; then
  COMPOUND_KEY="$_meta_base"
fi
# stderr from python must reach the hook (AMBIGUOUS_SUFFIX names T + colliding keys)
MAX_CONF=$(python3 -c '
import json, sys
task_id = sys.argv[1]
index_path = sys.argv[2]
compound = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    data = json.load(open(index_path))
    def as_rows(key):
        v = data.get(key)
        return list(v) if isinstance(v, list) else []
    # CDT-163 isolate: at most one key; MUST NOT rows.extend across keys
    resolved = None
    if isinstance(data.get(task_id), list):
        resolved = task_id
    elif compound and compound != task_id:
        # Preferred compound only — missing → no verdict; never open suffix scan
        resolved = compound
    else:
        matches = []
        for k, v in data.items():
            if not isinstance(v, list):
                continue
            if k == task_id or (task_id and k.endswith("-" + task_id)):
                matches.append(k)
        if len(matches) == 0:
            print("NO_TASK_IN_INDEX")
            sys.exit(0)
        if len(matches) == 1:
            resolved = matches[0]
        else:
            keys_s = ", ".join(sorted(matches))
            print(
                "TaskCompleted council gate: ambiguous index suffix for bare id %s — colliding keys: %s"
                % (task_id, keys_s),
                file=sys.stderr,
            )
            print("AMBIGUOUS_SUFFIX")
            sys.exit(0)
    rows = as_rows(resolved) if resolved is not None else []
    if not rows:
        print("NO_TASK_IN_INDEX")
        sys.exit(0)
    scores = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        vc = r.get("max_verdict_confidence")
        fc = r.get("max_finding_confidence")
        if vc is not None:
            try:
                scores.append(int(vc))
            except (TypeError, ValueError):
                pass
        elif fc is not None:
            try:
                scores.append(int(fc))
            except (TypeError, ValueError):
                pass
    if not scores:
        print("NO_CONFIDENCE_ROWS")
    else:
        print(max(scores))
except Exception:
    print("PARSE_ERROR", file=sys.stderr)
    print("PARSE_ERROR")
' "$TASK_ID" "$INDEX" "$COMPOUND_KEY" || echo "PARSE_ERROR")

case "$MAX_CONF" in
  NO_TASK_IN_INDEX)
    echo "TaskCompleted council gate: no council verdict for task $TASK_ID (task not found in index)" >&2
    exit 2
    ;;
  NO_CONFIDENCE_ROWS)
    echo "TaskCompleted council gate: no confidence rows for task $TASK_ID (need verdict[] max_verdict_confidence or finding[] max_finding_confidence)" >&2
    exit 2
    ;;
  PARSE_ERROR)
    echo "TaskCompleted council gate: failed to parse council index $INDEX for task $TASK_ID" >&2
    exit 2
    ;;
  AMBIGUOUS_SUFFIX)
    echo "TaskCompleted council gate: ambiguous index suffix for task $TASK_ID (multiple suffix-matching keys; refuse multi-key max-merge)" >&2
    exit 2
    ;;
esac

# Numeric comparison — MAX_CONF is an integer at this point
if [ "$MAX_CONF" -lt "$THRESHOLD" ]; then
  echo "TaskCompleted council gate: max confidence $MAX_CONF below threshold $THRESHOLD for task $TASK_ID" >&2
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
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
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

**Precondition (CDT-68):** `bash-compress.sh` must be covered by the up-front
batch approval (name the hook explicitly). Its `permissionDecision:"allow"` is
intentional (bounded NOISY allowlist only) — do not remove without evidence.

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

# Resolve plugin root (PDH) — hook-runtime bootstrap, not the caller-site stanza.
# Two tiers only: (a) PDH=$(pwd) when skills/plugin-dir.sh exists in cwd (dev
# checkout), else (b) highest-version match under the installed plugin cache.
# Narrower than the canonical 4-tier caller-site stanza because hooks run detached
# with no session context — CLAUDE_PLUGIN_ROOT and the marketplace-clone tier are
# unreachable here.
PDH=""
if [ -f skills/plugin-dir.sh ]; then
  PDH=$(pwd)  # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza)
else
  _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
    -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
    | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./') || _pdh_hit=""
  if [ -n "$_pdh_hit" ]; then
    # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza)
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

### Step 4h: Sweep known legacy orphan hooks (CDT-76)

After all managed hooks are written (including `bash-compress.sh`), remove
**only** names on the known-legacy-orphan list if present and unreferenced.

v1 list: `bash-compress-wrapper.sh` only. Not free-form GC.

```bash
# Re-resolve PDH / SWEEP (fresh shell — skill-lint C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SWEEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/init-orchestration/sweep-legacy-orphans.sh 2>/dev/null) || SWEEP=""
PROJ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ -n "$SWEEP" ] && [ -f "$SWEEP" ]; then
  set +e
  bash "$SWEEP" --project-root "$PROJ_ROOT"
  SWEEP_RC=$?
  set -e
  # exit 0 success (remove / warn-keep / absent); exit 2 → report error, do not abort rest of setup
else
  # Fallback: agent applies same eligibility + bak-force + FORCE-OVERWRITE labels for list names only
  :
fi
```

Capture `LEGACY-ORPHAN:` lines for Step 9. If referenced, leave file and surface WARN.

---

### Step 4i: Create .claude/hooks/escalation-gate.sh (SPEC-031)

Backs the Escalation gate's universal worktree isolation (`skills/refactor/SKILL.md`
§ 2.2a — the contract home; this step does not restate the gate). Numbered after the
Step 4h sweep so that step's identifier stays stable; ordering within Step 4 does not
matter, the sweep only touches its known-legacy-orphan list.

**Precondition (CDT-68 / SPEC-031):** confirm the user already approved writing
this hook — honest-limits framing included — in the up-front batch ask (see
**Permission batching**). A blocking hook is a material behavior change; if not
already approved, ask now (name `escalation-gate.sh` explicitly) before writing.

**Honest limits — this hook is NOT tamper-proof.** State this wherever it is
disclosed; do not describe it as "enforcement the model cannot regress". Four
specific respects (SPEC-031 § Hook contract — honest limits):

1. **Bash bypasses it entirely.** A `PreToolUse` hook matching file-editing tools
   never observes `sed -i`, heredoc redirection, `git apply`, or `git commit` issued
   through the `Bash` tool.
2. **The arming actor is the enforced actor.** The same agent that executes the skill
   writes the armed marker and performs the edit, so the hook cannot verify that a
   user was actually asked for the edit go-ahead. It catches drift *inside a compliant
   run*; it does not defend against a non-compliant one.
3. **Coverage is tool-name-scoped.** Only `Write`, `Edit`, and `NotebookEdit` are
   gated. Any future or unlisted write path is ungated until added here.
4. **Path matching is textual, and normalization is best-effort.** Targets are compared
   as strings after `realpath -m` normalization. Where `realpath` is unavailable the raw
   path is used and `..` traversal is not normalized away, so a target such as
   `$MROOT/.worktrees/../src/a.go` reads as an in-worktree write and is not gated.

**Enforcement levels.** WARN (exit 0, stderr hint) fires whenever the hook is
installed and a matched write targets a non-allowlisted path outside
`$MROOT/.worktrees/`. HARD BLOCK (exit 2) fires only when a live skill-written armed
marker carries a `session_id` matching the request's — i.e. only for the run that
armed it. Every other path, and every internal error, exits 0.

**Allowlist — never gated (except the armed tamper carve-out below).** Enumerated
explicitly in the script, not inferred: any path under `.git/`, `.claude/`, `specs/`,
`docs/`, or `.github/`, and any file whose name ends in `.md`, `.txt`, or `.rst` (this
covers `CHANGELOG.md` and `README.md`), plus bare `LICENSE`/`NOTICE`. Rationale: these are
the surfaces a run legitimately touches in the main checkout — plan files, spec updates,
and the orchestration config itself — and gating them would make the WARN level pure noise.

**Control-plane tamper carve-out (SPEC-031).** One narrow exception runs **before** the
broad `.claude/**` allowlist: when this run is armed, a `Write`/`Edit`/`NotebookEdit` to a
file that governs the gate — `$MROOT/.claude/hooks/*`, `$MROOT/.claude/settings.json`,
`$MROOT/.claude/settings.local.json`, or `$MROOT/.claude/escalation-gate/*` — BLOCKs (exit
2), so an armed run cannot self-clear the gate by writing its own marker, the hook script,
or settings. Unarmed runs are unaffected. The broad `*.md`/`*.txt` doc exemption is kept
deliberately (finding #15 is closed by this carve-out, not by narrowing the exemption).

**Armed-marker contract (the seam `skills/refactor/SKILL.md` § 2.2a.4/2.2a.5 writes).**
Markers live in `$MROOT/.claude/escalation-gate/armed/` as `<slug>.marker`, one per
armed run, containing `key=value` lines:

```
slug=<worktree slug>
worktree=<absolute path to $MROOT/.worktrees/<slug>>
session_id=<session_id of the run that armed the gate>
agent_id=<agent_id of the arming agent, or "main" for the top-level session>
armed_at=<ISO-8601 UTC>
```

`session_id=` is **required** — it is what scopes the BLOCK to one run. `slug=` is read
for the block message; the rest is for humans and for `/status worktree`. Per
SPEC-031 § Armed-marker lifecycle the skill arms the marker **only on an
escalate-and-auto-chain handoff** (a run that has committed to `/kickoff` or `/epic` and
continues in-session) — never on a bounded run — and **disarms with exactly one
success-path call** immediately after that downstream command returns having created its
ticket/plan/task-graph. The `-mmin -480` (8-hour) leak-expiry is an
**abnormal-termination backstop**, not the primary reclaim path: a killed session or a
failed/aborted handoff legitimately leaves the guarded window open, so the marker degrades
to WARN at expiry rather than hard-blocking the repository forever.

**Why BLOCK keys on `session_id` and WARN keys on `agent_id`.** The same verified
platform fact justifies both, in opposite directions: `PreToolUse` fires inside
subagents carrying the **parent** `session_id`, with the child distinguished only by
`agent_id`. So `session_id` is exactly the run scope — it covers the arming agent plus
every subagent it spawns, and excludes concurrent unrelated sessions, which this
repository runs as the norm. A repo-global BLOCK keyed on marker existence alone would
stop an unrelated session's writes and tell it to delete another run's marker. The WARN
latch wants the opposite grain: keyed on `agent_id` so each orchestrated IC gets its own
attempt counter instead of collapsing into one. **BLOCK requires a live marker whose
`session_id` matches the request's `.session_id`; anything else — no marker, no match,
either side absent — degrades to WARN.**

The hook is registered for `PreToolUse` with matcher `Write|Edit|NotebookEdit`.
`MultiEdit` is deliberately absent — it is not a registered tool in current Claude
Code, so listing it would be decorative. Writing the `settings.json` entry (and its
coexistence with `/tdd-gate on`, which writes into the same `PreToolUse` array) is
Step 3's concern, not this step's — see Step 3 § **`PreToolUse` array append rule
(SPEC-031)**.

Use the `Write` tool to create `.claude/hooks/escalation-gate.sh` with this content:

```bash
#!/usr/bin/env bash
# escalation-gate.sh — PreToolUse hook backing SPEC-031 worktree isolation.
#
# WARN  (exit 0): installed, not armed for this run. A Write/Edit/NotebookEdit
#                 to a non-allowlisted path outside $MROOT/.worktrees/ prints a
#                 hint on stderr; the write proceeds.
# BLOCK (exit 2): a live armed marker under
#                 $MROOT/.claude/escalation-gate/armed/ carries a session_id
#                 matching this request's. The same write is refused with stderr
#                 feedback to the agent.
#
# NOT TAMPER-PROOF. Bash-issued writes (sed -i, heredocs, git apply, git commit)
# are never observed. The armed marker is written by the same agent this hook
# constrains, so it cannot verify a user was actually asked. Drift detector
# inside a compliant run — not a control. See SPEC-031 § honest limits.
#
# FAIL-OPEN: absent jq, unreadable stdin, unresolvable MROOT, missing marker
# directory, or any unexpected condition exits 0. Only the armed-for-this-run +
# outside condition ever exits 2.

set -u

allow() { exit 0; }

# jq absent -> fail open (same convention as bash-compress.sh / memory-capture.sh)
command -v jq >/dev/null 2>&1 || allow

# Stage stdin to a file and query it. NEVER cap the read: a Write payload's
# `content` field routinely exceeds any fixed cap, and a truncated body makes jq
# fail -> fail-open -> the gate silently skips exactly the large generated file
# it exists to catch.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/escgate.XXXXXX" 2>/dev/null) || allow
trap 'rm -rf "$WORKDIR"' EXIT
IN="$WORKDIR/stdin.json"
cat > "$IN" 2>/dev/null || allow
[ -s "$IN" ] || allow

TOOL_NAME=$(jq -r '.tool_name // empty' "$IN" 2>/dev/null) || allow
case "$TOOL_NAME" in
  Write|Edit|NotebookEdit) ;;
  *) allow ;;
esac

# NotebookEdit supplies notebook_path, NOT file_path (verified CC v2.1.212) —
# a file_path-only read lets every notebook write pass silently.
TARGET=$(jq -r '.tool_input.notebook_path // .tool_input.file_path // empty' "$IN" 2>/dev/null) || allow
[ -n "$TARGET" ] || allow

_eg_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd -- "$(dirname -- "$_eg_gc")" && pwd) \
  || MROOT="${CLAUDE_PROJECT_DIR:-}"
{ [ -n "$MROOT" ] && [ -d "$MROOT" ]; } || allow

case "$TARGET" in
  /*) ;;
  *) TARGET="${CLAUDE_PROJECT_DIR:-$PWD}/$TARGET" ;;
esac

# Normalize before any prefix match: $MROOT/.worktrees/../src/a.go would
# otherwise match the .worktrees/ allow pattern and escape the gate. -m works on
# paths that do not exist yet (Write creates them). Where realpath is absent the
# raw path is used and `..` traversal stays unnormalized — documented limit.
if command -v realpath >/dev/null 2>&1; then
  _eg_n=$(realpath -m -- "$TARGET" 2>/dev/null) && [ -n "$_eg_n" ] && TARGET="$_eg_n"
  _eg_r=$(realpath -m -- "$MROOT" 2>/dev/null) && [ -n "$_eg_r" ] && MROOT="$_eg_r"
fi

# Inside the worktree tree — the compliant destination, never gated.
case "$TARGET" in
  "$MROOT"/.worktrees/*) allow ;;
esac

# Resolve armed state up front: BOTH the tamper-surface carve-out below and the
# general out-of-worktree BLOCK need it, and the carve-out MUST run BEFORE the
# broad .claude/** allowlist so an armed run cannot self-clear the gate by writing
# the files that govern it.
#
# Markers live at $MROOT/.claude/escalation-gate/armed/<slug>.marker. Under
# SPEC-031 § Armed-marker lifecycle the skill arms one ONLY on an
# escalate-and-auto-chain handoff and disarms it once at handoff completion;
# -mmin -480 is the abnormal-termination backstop (a leaked marker degrades to
# WARN at 8h rather than blocking forever), not the primary reclaim path.
#
# BLOCK is scoped to ONE RUN via session_id, not to the repository. PreToolUse
# fires inside subagents carrying the PARENT session_id, so session_id covers the
# arming agent and everything it spawns while excluding concurrent unrelated
# sessions — which would otherwise be blocked. No session_id on either side =>
# no match => WARN.
SESSION_ID=$(jq -r '.session_id // empty' "$IN" 2>/dev/null) || SESSION_ID=""
ARMED_DIR="$MROOT/.claude/escalation-gate/armed"
ARMED_MARKER=""
if [ -n "$SESSION_ID" ] && [ -d "$ARMED_DIR" ]; then
  find "$ARMED_DIR" -maxdepth 1 -type f -name '*.marker' -mmin -480 \
    > "$WORKDIR/markers" 2>/dev/null || true
  while IFS= read -r _eg_m; do
    [ -n "$_eg_m" ] && [ -f "$_eg_m" ] || continue
    _eg_s=$(sed -n 's/^session_id=//p' "$_eg_m" 2>/dev/null | head -1)
    if [ -n "$_eg_s" ] && [ "$_eg_s" = "$SESSION_ID" ]; then
      ARMED_MARKER="$_eg_m"
      break
    fi
  done < "$WORKDIR/markers"
fi

# Control-plane tamper surface (SPEC-031): checked BEFORE the broad .claude/**
# allowlist. When this run is armed, a write to a file that governs the gate —
# the hook script, settings[.local].json, or the armed-marker dir — is drift and
# BLOCKs, even though .claude/** is otherwise exempt. Unarmed runs are wholly
# unaffected: this gates only when a live matching marker exists.
if [ -n "$ARMED_MARKER" ]; then
  case "$TARGET" in
    "$MROOT"/.claude/hooks/*|"$MROOT"/.claude/settings.json|"$MROOT"/.claude/settings.local.json|"$MROOT"/.claude/escalation-gate/*)
      SLUG=$(sed -n 's/^slug=//p' "$ARMED_MARKER" 2>/dev/null | head -1)
      {
        echo "Escalation gate BLOCK: $TOOL_NAME targets control-plane file $TARGET"
        echo "This run is armed${SLUG:+ for slug '$SLUG'}; the gate's own config (hook, settings, marker dir) is off-limits while armed."
        echo "Redo the edit against the worktree path; the marker clears when the escalation handoff completes."
      } >&2
      exit 2 ;;
  esac
fi

# Explicit allowlist, enumerated (SPEC-031): never gated at either level. The
# broad *.md/*.txt doc exemption is retained deliberately — SPEC-031 closes
# finding #15 via the tamper carve-out above, NOT by narrowing this exemption
# (armed escalate runs legitimately write plan/spec .md files).
case "$TARGET" in
  */.git/*|*/.claude/*|*/specs/*|*/docs/*|*/.github/*) allow ;;
esac
case "${TARGET##*/}" in
  *.md|*.txt|*.rst|LICENSE|NOTICE) allow ;;
esac

# General out-of-worktree BLOCK for an armed run: any non-allowlisted path
# outside the worktree tree is drift back toward the origin incident.
if [ -n "$ARMED_MARKER" ]; then
  SLUG=$(sed -n 's/^slug=//p' "$ARMED_MARKER" 2>/dev/null | head -1)
  {
    echo "Escalation gate BLOCK: $TOOL_NAME targets $TARGET"
    echo "This run is armed${SLUG:+ for slug '$SLUG'}; all file modification belongs in $MROOT/.worktrees/${SLUG:-<slug>}/."
    echo "Redo the edit against the worktree path; the marker clears when the escalation handoff completes."
  } >&2
  exit 2
fi

# WARN. Latch keys on agent_id (a session-keyed-only latch would collapse every
# orchestrated IC into one counter) AND folds in a session_id hash so the count
# is per-session-per-agent, not global-per-agent across unrelated sessions for
# the TMPDIR lifetime (SPEC-031). Falls back to the agent-only key when no
# session_id is present. Null agent_id = top-level session.
AGENT_KEY=$(jq -r '.agent_id // "main"' "$IN" 2>/dev/null) || AGENT_KEY="main"
[ -n "$AGENT_KEY" ] || AGENT_KEY="main"
AGENT_KEY=$(printf '%s' "$AGENT_KEY" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)

MROOT_HASH=$(printf '%s' "$MROOT" | cksum | cut -d' ' -f1)
if [ -n "$SESSION_ID" ]; then
  SESS_HASH=$(printf '%s' "$SESSION_ID" | cksum | cut -d' ' -f1)
  LATCH="${TMPDIR:-/tmp}/claude-escgate-${MROOT_HASH}-${SESS_HASH}-${AGENT_KEY}"
else
  LATCH="${TMPDIR:-/tmp}/claude-escgate-${MROOT_HASH}-${AGENT_KEY}"
fi

# Symlink guard (CWE-59/377): the latch lives at a predictable path in a shared
# TMPDIR; a pre-planted symlink there would make the count-write clobber the link
# target. Remove a pre-existing symlink before the read/write. The residual
# TOCTOU of the reject-then-write shape is accepted — the latch is a
# non-security-critical WARN counter, consistent with the hook's fail-open posture.
[ -L "$LATCH" ] && rm -f "$LATCH" 2>/dev/null

COUNT=$(cat "$LATCH" 2>/dev/null || echo 0)
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
COUNT=$((COUNT + 1))
printf '%s' "$COUNT" > "$LATCH" 2>/dev/null || true

if [ "$COUNT" -eq 1 ]; then
  {
    echo "Escalation gate: $TOOL_NAME targets $TARGET, outside $MROOT/.worktrees/."
    echo "SPEC-031 puts all file modification in a worktree. Not blocking."
  } >&2
else
  echo "Escalation gate: edit #$COUNT outside .worktrees/ — $TARGET" >&2
fi

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/escalation-gate.sh
```

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
- Caps apply to **counted** LOC (SPEC-033 M15 — cite; do not fork). Specs/tests stay exempt. Lockfile/`*.snap`/vendored prefixes and `.gitattributes linguist-generated` also excluded.
- ~1,000 counted LOC per PR (soft cap). Hard cap: 2,000 counted LOC default. No single counted file > 1,000 lines. Exceeding = stop and split.

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

When emitting this, replace `<model>` with the agent/model actually performing this commit. Do **not** hardcode Claude/Anthropic when the agent is something else (e.g. Grok, Codex, a human). Examples:
- `Co-Authored-By: Grok <noreply@x.ai>`
- `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

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
  # Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
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
- ~1k counted LOC per PR (SPEC-033 M15 — cite; specs/tests + lockfile/snap/vendor/`linguist-generated` don't count). Hard cap 2k counted default. No single counted file > 1k lines. Exceeding = stop and split.
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

Run the hook manually to confirm it passes. Use file redirection — NOT a pipe (`echo '{}' | bash ...` poisons the session). Temp paths MUST use `${TMPDIR:-/tmp}` (bare `$TMPDIR` is often unset outside the sandbox):
```bash
_HOOK_TEST="${TMPDIR:-/tmp}/hook-test-$$"
printf '{}' > "$_HOOK_TEST"
bash .claude/hooks/task-completed.sh < "$_HOOK_TEST"
echo "Hook exit code: $?"
rm -f "$_HOOK_TEST"
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
  📄 .claude/settings.json   — sandbox + auto (Cell D) + matrix allow (Bash(*)+Read/Write/Edit/Glob/Grep/Agent/Task) + PreToolUse + PostToolUse + Stop + TaskCompleted + PreCompact + PostCompact + SessionStart + PostToolUseFailure + PermissionDenied + StopFailure hooks
      Sandbox: enabled, autoAllowBash, network: [list of configured domains]
      Signing: [skipped | allowWrite ~/.gnupg | excludedCommands git | local gpgsign false]
  📄 .claude/hooks/task-completed.sh — quality-gate hook (customize for your project)
  📄 .claude/hooks/stop-review.sh   — self-review gate (one-shot warning on uncommitted changes)
  📄 .claude/hooks/memory-capture.sh — auto memory (logs Write/Edit to tier-0)
  📄 .claude/hooks/bash-compress.sh — output compression (rewrites noisy test/build commands inline)
  📄 .claude/hooks/precompact-rescue.sh — PreCompact rescue capture (SPEC-018 M12)
  📄 .claude/hooks/rescue-pointer.sh — PostCompact/SessionStart pointer surfacing (M16)
  📄 .claude/hooks/friction-capture.sh — live friction ledger (SPEC-012 M1; PostToolUseFailure/PermissionDenied/StopFailure)
  📄 legacy orphan sweep — bash-compress-wrapper.sh: [removed → restore <path> | left (still referenced) | absent]
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
- **Not pure zero-intervention (CDT-68):** settings.json merge, `bash-compress.sh`, and `escalation-gate.sh` require explicit user approval — batch all three in ONE ask up front, escalation-gate.sh's honest-limits framing included; do not strip the self-escalation guards
- **Force-overwrite disclosure (CDT-51 AC5):** any force change of a managed settings value or hook file MUST print `key` / `old` / `new` / `restore` before the write (`disclose-force-overwrite.sh` or the fallback block). Forced + silent = FAIL
- **Known-legacy-orphan sweep (CDT-76):** remove only names on the explicit finite list (`bash-compress-wrapper.sh` v1); silent orphan delete forbidden — always bak-force + FORCE-OVERWRITE disclose before rm, or WARN-keep when still referenced
- The hook script exits 0 by default (pass-through) until customized
- Agent Teams require Claude Code restart after `settings.json` changes for the env var to take effect
- Teammates do not inherit conversation history — AGENTS.md is their primary orientation document
- Temp paths in any bypass-retry or validation snippet: `"${TMPDIR:-/tmp}/…"` or `mktemp`
