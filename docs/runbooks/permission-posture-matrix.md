# Permission posture matrix (CDT-51 / CDT-46-C5 AC1)

Live A/B/C matrix for orchestration `permissions.defaultMode` under Claude Code
**2.1.190**. Evidence gate for AC2 template flip (Task 2). Spec anchors:
SPEC-002 posture MUSTs; SPEC-005 orchestration default follows this winner.

**Task 2 consumed `## Winner`** — ship default is `dontAsk` (see init-orchestration).

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
| AC2 implication | Task 2 **flipped** `init-orchestration` ship default from `bypassPermissions` → `dontAsk` (sandbox MUSTs kept) |
| C7 posture-honesty flag | **Not required** (non-bypass cell passed) |

### Residual risks

1. **Non-interactive proxy vs interactive TUI.** Matrix ran under `claude -p`
   (print mode). Interactive sessions can surface permission UI that `-p`
   converts to denials or auto-paths. Zero interactive prompt count was **not**
   measured in a full TUI session. Mitigate: smoke `/setup orchestration` + one
   real `/orchestrate` spawn under the winning mode before cutting v1.0.0.
2. **Spawn fidelity.** Flow used the **Agent** tool (minimal multi-agent spawn),
   not a full Agent-Teams `/orchestrate` multi-teammate session with TaskList /
   SendMessage. Team-mode edge cases (teammate inheritance of mode, nested
   bypass) are unproven here.
3. **Allow-list coupling.** Cell C pass assumes the matrix allow set
   (`Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task). Ship template + brownfield
   merge now require that full set (CDT-51 TL P0). Narrowing allow without sandbox
   auto-allow will fail zero-prompt under `dontAsk` (deny-not-ask).
4. **Sandbox dependency.** Without sandbox (or on hosts without bubblewrap),
   `autoAllowBashIfSandboxed` does not fire; `dontAsk` then depends entirely on
   allow rules. Current ship MUST keeps sandbox on (SPEC-002).
5. **Hook coverage.** Only PreToolUse Bash probe hook exercised; Stop /
   TaskCompleted / friction hooks not fired end-to-end in this matrix.
6. **Model / version drift.** Evidence is for host **2.1.190** + haiku probe
   model. Re-run `tools/permission-matrix-probe.sh` after CC upgrades before
   trusting the winner.

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
| `docs/runbooks/permission-posture-matrix.md` | This evidence (committed) |
| `/tmp/cdt-51-matrix-20260722-013805/` | Live run scratch (local only) |
| `…/results.tsv` | Per-flow PASS rows |
| `…/{A,B,C}-stream.jsonl` | stream-json traces with `permissionMode` + denials |
