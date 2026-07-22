# Permission posture matrix (CDT-51 / CDT-46-C5 AC1)

Live A/B/C matrix for orchestration `permissions.defaultMode` under Claude Code
**2.1.190**. Evidence gate for AC2 template flip (Task 2). Spec anchors:
SPEC-002 posture MUSTs; SPEC-005 orchestration default follows this winner.

**Machine-readable last-probed CC version (CDT-59):**
`tools/permission-matrix-cc-version` — single-line semver, written by
`tools/permission-matrix-probe.sh` on a successful run. `/doctor` check
`matrix.cc_version` WARNs when installed `claude --version` drifts.

**Task 2 consumed `## Winner`** — ship default is `dontAsk` (see `/setup orchestration` / `skills/init-orchestration`).

---

## Method

| Item | Value |
|------|--------|
| Host | `claude --version` → **2.1.190 (Claude Code)** |
| Date (UTC) | 2026-07-22T05:38Z–05:40Z |
| Harness | `tools/permission-matrix-probe.sh` |
| Scratch | `${TMPDIR}/cdt-51-matrix-20260722-013805/` (throwaway; not committed) |
| Model | `haiku` (`claude-haiku-4-5-20251001`) via `claude -p` |
| Zero-prompt proxy | stream-json `result.permission_denials` must be `[]`; no ask/deny events |
| Interactive TUI | **Not fully automated** — residual risk below |

### Setting keys (empirical)

CLI `--permission-mode` choices (from `claude --help`):

```
acceptEdits | auto | bypassPermissions | default | dontAsk | plan
```

Binary string presence (`/opt/claude-code/bin/claude`, host 2.1.190):

| Key | Occurrences (approx) | Notes |
|-----|----------------------|--------|
| `bypassPermissions` | ~123 | CLI + settings mode |
| `acceptEdits` | ~72 | CLI + settings mode |
| `dontAsk` | ~44 | CLI + settings mode |
| `autoAllowBashIfSandboxed` | ~9 | under `sandbox.*` |
| `defaultMode` | ~27 | under `permissions.*` |
| `sandbox.enabled` | ~10 | sandbox block |

Runtime string (sandbox auto-allow path):

> `Auto-allowed with sandbox (autoAllowBashIfSandboxed enabled)`

Session `system/init.permissionMode` matched the intended cell mode for A/B/C
(confirmed in each cell's stream-json init event).

### Shared cell fixture

Every cell used the same sandbox + allow surface; only `defaultMode` changed:

```json
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["docker", "docker-compose"],
    "network": { "allowedDomains": ["api.anthropic.com", "github.com"] }
  },
  "permissions": {
    "allow": ["Bash(*)", "Read", "Write", "Edit", "Glob", "Grep", "Agent", "Task"],
    "defaultMode": "<cell mode>"
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/probe-hook.sh\""
      }]
    }]
  }
}
```

### Required flows (each cell)

| Flow | How verified |
|------|----------------|
| Memory sqlite3 write | Side-effect: row in `.claude/memory/memory.db` with content `cdt-51-matrix-write` |
| Worktree ensure/release | Agent ran `skills/worktree-lib.sh ensure|release cdt-51-probe-wt`; no leftover worktree |
| Hook execution | PreToolUse probe hook wrote ≥1 line to `.claude/hooks/probe-fires.log` |
| Orchestrate spawn | Agent tool (`Agent`) invoked; `spawn-ok.txt` written (`SPAWN_OK`) |

Programmatic baseline (no Claude API): sqlite3 + worktree-lib ensure/release +
hook script alone → **PASS** (scripts work outside permission gate).

### Pass bar

- All four flows succeed **and**
- `permission_denials == []` (zero-prompt proxy under non-interactive `-p`)

---

## Cell A

| Field | Value |
|-------|--------|
| `defaultMode` | `bypassPermissions` |
| Applied session mode | `bypassPermissions` (init) |
| Sandbox | enabled + `autoAllowBashIfSandboxed: true` |
| Allow | `Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task |
| Zero-prompt | **YES** — `permission_denials: []` |
| Overall | **PASS_ZERO_PROMPT** |

| Flow | Status | Evidence |
|------|--------|----------|
| memory_sqlite3 | PASS | 1 row `cdt-51-matrix-write` |
| worktree_ensure_release | PASS | ensure+release in Bash; no leftover wt |
| hook_execution | PASS | 3 probe fires |
| orchestrate_spawn | PASS | Agent tool + `spawn-ok.txt` = `SPAWN_OK` |

Tools observed: Bash×3, Agent, Write×2. Result: `MATRIX_DONE cell-ok`, 6 turns,
~25s. Privilege rank: **highest** (mode skips permission checks entirely).

---

## Cell B

| Field | Value |
|-------|--------|
| `defaultMode` | `acceptEdits` |
| Applied session mode | `acceptEdits` (init) |
| Sandbox | enabled + `autoAllowBashIfSandboxed: true` |
| Allow | same as A |
| Zero-prompt | **YES** — `permission_denials: []` |
| Overall | **PASS_ZERO_PROMPT** |

| Flow | Status | Evidence |
|------|--------|----------|
| memory_sqlite3 | PASS | 1 row |
| worktree_ensure_release | PASS | ensure+release clean |
| hook_execution | PASS | 3 probe fires |
| orchestrate_spawn | PASS | Agent + `spawn-ok.txt` = `SPAWN_OK` |

Tools observed: Bash×3, Agent, Write, ScheduleWakeup. Result: `MATRIX_DONE cell-ok`,
6 turns, ~18s. Privilege rank: **middle** (auto-approves edits; bash via allow +
sandbox auto-allow).

---

## Cell C

| Field | Value |
|-------|--------|
| `defaultMode` | `dontAsk` |
| Applied session mode | `dontAsk` (init) |
| Sandbox | enabled + `autoAllowBashIfSandboxed: true` |
| Allow | same as A |
| Zero-prompt | **YES** — `permission_denials: []` |
| Overall | **PASS_ZERO_PROMPT** |

| Flow | Status | Evidence |
|------|--------|----------|
| memory_sqlite3 | PASS | 1 row |
| worktree_ensure_release | PASS | ensure+release clean |
| hook_execution | PASS | 3 probe fires |
| orchestrate_spawn | PASS | Agent + `spawn-ok.txt` = `SPAWN_OK` |

Tools observed: Bash×3, Agent, Write. Result: `MATRIX_DONE cell-ok` (incl. nested
agent completion), 5+1 turns, ~22s. Privilege rank: **lowest** among A/B/C (no
bypass; no auto-accept-edits elevation; pre-allow + sandbox auto-allow only).

---

## Supporting probes (not matrix cells)

### Sandbox auto-allow without `Bash(*)`

With `sandbox.enabled` + `autoAllowBashIfSandboxed: true` and **no** `Bash(*)`
in allow:

| Mode | Bash `echo …` | `permission_denials` |
|------|---------------|----------------------|
| `dontAsk` | ran (`NEG_SHOULD_DENY` in tool result) | `[]` |
| `acceptEdits` | ran (`ACCEPT_BASH_TEST` present) | `[]` |

Confirms OS sandbox auto-allow path is live on 2.1.190 and is the primary
zero-prompt mechanism for Bash under orchestration-style settings.

### Privilege ordering (modes only)

Least → most privilege (for equal allow+sandbox):

1. **`dontAsk`** — never prompts; allows only pre-allowed / sandbox-auto paths; denies the rest
2. **`acceptEdits`** — same + auto-approves file edits beyond strict allow semantics
3. **`bypassPermissions`** — skips permission checks (blast radius unbounded if sandbox off)

---

## Winner

**Cell C — `dontAsk`** (with `sandbox.enabled: true`, `autoAllowBashIfSandboxed: true`,
and full matrix allow set: `Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task).

| Criterion | Result |
|-----------|--------|
| Passing cells (zero-prompt, all 4 flows) | A, B, **C** |
| Least privilege among passers | **C** |
| AC2 implication | Task 2 **flipped** `/setup orchestration` (`skills/init-orchestration`) ship default from `bypassPermissions` → `dontAsk` (sandbox MUSTs kept) |
| C7 posture-honesty flag | **Not required** (non-bypass cell passed) |

### Interactive evidence (CDT-58) — 2026-07-22

Live TUI dogfood on this plugin checkout under shipped Cell C (CC **2.1.190**,
status bar `dont ask on`). Dogfood ticket **CDT-73** (throwaway marker write).

| Field | Value |
|-------|--------|
| Host | `claude-dev-team` @ `192733b` / v1.0.1 posture |
| Mode | `dontAsk` + sandbox + `autoAllowBashIfSandboxed` + matrix allow |
| User-facing permission dialogs | **0** |
| Friction ledger delta | **0** new `PermissionDenied` rows (pre=1 historical setup-era Edit) |
| Outcome | `.claude/dogfood/cdt-58-marker.txt` = `CDT-58-OK` |

**Silent denials observed (deny-not-ask — correct, not prompts):**

| Tool / path | Result |
|-------------|--------|
| Linear MCP `get_issue` (CDT-73) | Denied — MCP not on matrix allow |
| Edit `.claude/settings.json` (agent tried to widen allow for MCP) | Denied — self-escalation / denyWithinAllow |

**Claim (extended, caveated):** under Cell C, an interactive implement path that
stays inside matrix allow (Write marker under `.claude/dogfood/`) runs with
**zero permission dialogs**. Enterprise “zero-prompt” does **not** mean “all MCP
and settings self-mod work unprompted”:

1. **MCP tools** (Linear, Slack, …) are **outside** the ship matrix allow →
   silent deny under `dontAsk`. Feed issue text or add an explicit allow entry
   (product decision — do not mid-run self-edit settings to chase it).
2. **`.claude/settings.json` / permission-widening hooks** remain self-escalation
   guards (CDT-68). Batch-approve only for `/setup orchestration`; never strip.
3. **Full multi-teammate** Agent-Teams (TaskList / SendMessage / nested teammates)
   was **not** required for CDT-73 marker; residual for that denser path remains
   low-risk given same mode + allow inheritance, not re-measured here.

### Residual risks

1. **Non-interactive proxy vs interactive TUI.** Matrix used `claude -p`; CDT-58
   interactive TUI measured **0 dialogs** for allow-set work (see above). MCP and
   settings self-mod remain deny-not-ask, not dialog.
2. **Spawn fidelity.** CDT-51 used Agent tool only; CDT-58 dogfood was a slim
   orchestrate/implement path (marker file), not a full multi-teammate TaskList /
   SendMessage session. Team-mode edge cases still lightly evidenced.
3. **Allow-list coupling.** Cell C pass assumes the matrix allow set
   (`Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task). Ship template + brownfield
   merge now require that full set (CDT-51 TL P0). Narrowing allow without sandbox
   auto-allow will fail zero-prompt under `dontAsk` (deny-not-ask). MCP is not
   in that set by design until a deliberate product allow is added.
4. **Sandbox dependency.** Without sandbox (or on hosts without bubblewrap),
   `autoAllowBashIfSandboxed` does not fire; `dontAsk` then depends entirely on
   allow rules. Current ship MUST keeps sandbox on (SPEC-002).
5. **Hook coverage.** Only PreToolUse Bash probe hook exercised in the matrix;
   Stop / TaskCompleted / friction hooks not fired end-to-end there. CDT-58
   friction ledger showed no new rows during dogfood.
6. **Model / version drift.** Evidence is for host **2.1.190** + haiku probe
   model (matrix) and interactive TUI (CDT-58). Re-run
   `tools/permission-matrix-probe.sh` after CC upgrades before trusting the
   winner. `/doctor` `matrix.cc_version` WARNs when `claude --version` ≠
   `tools/permission-matrix-cc-version` (CDT-59).

### Reproduce

```bash
# from plugin checkout / worktree
bash tools/permission-matrix-probe.sh "${TMPDIR:-/tmp}/cdt-51-matrix-rerun"
# inspect results.tsv + *-stream.jsonl permission_denials
```

---

## Artifact index

| Path | Role |
|------|------|
| `tools/permission-matrix-probe.sh` | Reproducible harness (committed) |
| `tools/permission-matrix-cc-version` | Last-probed CC semver (doctor drift SoT) |
| `docs/runbooks/permission-posture-matrix.md` | This evidence (committed) |
| `/tmp/cdt-51-matrix-20260722-013805/` | Live run scratch (local only) |
| `…/results.tsv` | Per-flow PASS rows |
| `…/{A,B,C}-stream.jsonl` | stream-json traces with `permissionMode` + denials |
