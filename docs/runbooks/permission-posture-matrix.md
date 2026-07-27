# Permission posture matrix (CDT-51 / CDT-46-C5 AC1 + CDT-75 Cell D)

Live A/B/C/**D** matrix for orchestration `permissions.defaultMode` under Claude
Code **2.1.190**. Evidence gate for AC2 template flip. Spec anchors:
SPEC-002 posture MUSTs; SPEC-005 orchestration default follows this winner.

**Machine-readable last-probed CC version (CDT-59):**
`tools/permission-matrix-cc-version` — single-line semver, written by
`tools/permission-matrix-probe.sh` on a successful run. `/doctor` check
`matrix.cc_version` WARNs when installed `claude --version` drifts.

**Ship default (CDT-75):** **Cell D — `auto`** + sandbox +
`autoAllowBashIfSandboxed` + matrix allow (see `## Winner`). Prior v1.0.0–1.0.1
shipped Cell C (`dontAsk`); that mode remains valid but makes Linear-first
inoperative (MCP silent-deny — CDT-74).

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
| Interactive TUI | CDT-58 (Cell C) + live auto dogfood (CDT-75) — see sections below |

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

## Cell D (CDT-75) — `auto`

Probe re-run 2026-07-22T22:27Z (`MATRIX_CELLS="C:dontAsk D:auto"`, OUTDIR
`/tmp/cdt-75-matrix-20260722T222718Z/`, host CC **2.1.190**, model haiku).

| Field | Value |
|-------|--------|
| `defaultMode` | `auto` |
| Sandbox | enabled + `autoAllowBashIfSandboxed: true` |
| Allow | same matrix set as A/B/C |
| Core-loop zero-prompt proxy | **YES** — `permission_denials: []` |
| Overall core loop | **PASS_ZERO_PROMPT** (mem + worktree + hook + spawn) |

| Flow | Status | Evidence |
|------|--------|----------|
| memory_sqlite3 | PASS | 1 row |
| worktree_ensure_release | PASS | ensure+release clean |
| hook_execution | PASS | 3 probe fires |
| orchestrate_spawn | PASS | Agent + Write; tools Bash×3, Agent, Write |

Same-run Cell C (`dontAsk`) core loop **FAIL** with **zero tool uses** — haiku
refused the probe preamble as a “permission boundary test” (model refusal, not
a deny event). Prior CDT-51 Cell C **PASS_ZERO_PROMPT** still stands for the
allow-set core loop; CDT-58 interactive Cell C also ran allow-set work with
0 dialogs.

### Safety delta — `dontAsk` vs `auto` (same allow + sandbox)

Programmatic delta in the same harness (`mcp-safety-delta.tsv`):

| Action | `dontAsk` (Cell C) | `auto` (Cell D) |
|--------|--------------------|-----------------|
| Linear MCP `list_issues` under `claude -p` | **Denied** (not on allow; deny-not-ask) | **Denied in print mode** — stream shows permission *request* converted to denial (`Claude requested permissions to use mcp__…Linear__…`) |
| Edit/Write `.claude/settings.json` to widen allow | **Denied** (self-escalation / denyWithinAllow) | **Denied** — settings file unchanged |
| Core matrix allow tools (Bash/Write/Agent/…) | Unprompted when model cooperates | Unprompted; Cell D core loop **PASS_ZERO_PROMPT** |

**Interactive TUI (user / fable, 2026-07-22):** session switched to `auto` →
Linear MCP worked immediately, many MCP calls, **zero prompts**, sandbox still
on. That is the MCP evidence print-mode cannot fully reproduce (no human to
satisfy a permission request; `auto` still evaluates, does not mean “MCP always
auto-approved under `-p`”).

**Enumerated delta (what `auto` enables vs `dontAsk`):**

1. **MCP path (interactive):** tools outside the static matrix allow can be
   evaluated and allowed under policy/sandbox instead of hard silent-deny —
   restores Linear-first without MCP-detection machinery (CDT-74 shrinks).
2. **Settings self-mod:** still blocked under both modes in this probe — keep
   CDT-68 batch-approval guidance for `/setup orchestration`.
3. **Allow-set core loop:** both modes can be zero-dialog; `auto` is not a
   privilege upgrade to bypassPermissions (sandbox remains on).

### Older Claude Code / `auto` availability

On host **2.1.190**, `claude --help` lists `auto` among `--permission-mode`
choices. Binary string presence for mode key `auto` is high (shared token).
Hosts that predate `auto` as a mode are **unknown in this probe** (no multi-
version install). Ship note: consumers on older CC should re-run
`tools/permission-matrix-probe.sh` after upgrade; if `auto` is rejected by the
CLI, fall back to Cell C and accept MCP caveats or add explicit `mcp__*` allows.

## Winner

**Cell D — `auto`** (with `sandbox.enabled: true`, `autoAllowBashIfSandboxed: true`,
and full matrix allow set: `Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task).

| Criterion | Result |
|-----------|--------|
| Core loop PASS_ZERO_PROMPT (this probe) | **D** (C model-refused same run; prior C pass retained) |
| MCP Linear usable without allow-list surgery | **D interactive** (C deny-not-ask — CDT-58/74) |
| Settings self-widen blocked | C and D (good) |
| Least privilege vs bypass | D ≪ A; D is the epic's original “sandbox + auto” wording |
| Template implication | Ship default **flips** `dontAsk` → **`auto`** (CDT-75); CDT-74 MCP-detection machinery **not** built |
| C7 posture-honesty flag | **Not required** |

Historical: v1.0.0–1.0.1 shipped Cell C after A/B/C-only matrix (MCP never
probed). CDT-75 corrects that miss.

### Interactive evidence (CDT-58) — 2026-07-22 — Cell C

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

1. **Non-interactive `-p` vs interactive TUI.** Core-loop proxy is `permission_denials`
   under print mode. MCP under `auto` may still *request* permission in `-p`
   (becomes denial); interactive TUI is the SoT for MCP UX (CDT-75 live dogfood).
2. **Spawn fidelity.** CDT-51 used Agent tool only; CDT-58 dogfood was slim
   implement. Full multi-teammate TaskList/SendMessage lightly evidenced.
3. **Allow-list coupling.** Matrix allow still required for predictable zero-prompt
   core tools. Under Cell D (`auto`), tools outside allow are *evaluated*, not
   always hard-denied — do not treat allow as the only gate; sandbox remains MUST.
4. **Sandbox dependency.** Without sandbox, high-autonomy modes lose OS boundary.
   Doctor WARNs when `bypassPermissions` / `dontAsk` / `auto` lack sandbox.
5. **Hook coverage.** Matrix PreToolUse probe only; CDT-58 friction delta empty.
6. **Model / version drift.** Host **2.1.190**. Re-run probe after CC upgrades.
   `/doctor` `matrix.cc_version` WARNs on drift (CDT-59). Older CC without `auto`
   mode: untested — re-probe before trusting ship default.

### Reproduce

```bash
# full A/B/C/D (default MATRIX_CELLS)
bash tools/permission-matrix-probe.sh "${TMPDIR:-/tmp}/cdt-75-matrix-rerun"
# C vs D only + MCP safety delta
MATRIX_CELLS="C:dontAsk D:auto" bash tools/permission-matrix-probe.sh "${TMPDIR:-/tmp}/cdt-75-cd"
# inspect results.tsv, mcp-safety-delta.tsv, *-stream.jsonl
```

---

## Artifact index

| Path | Role |
|------|------|
| `tools/permission-matrix-probe.sh` | Reproducible harness A/B/C/D + MCP delta (committed) |
| `tools/permission-matrix-cc-version` | Last-probed CC semver (doctor drift SoT) |
| `docs/runbooks/permission-posture-matrix.md` | This evidence (committed) |
| `/tmp/cdt-51-matrix-20260722-013805/` | Original A/B/C live scratch (local) |
| `/tmp/cdt-75-matrix-20260722T222718Z/` | Cell D + MCP delta scratch (local) |
| `…/results.tsv` | Per-flow PASS rows |
| `…/mcp-safety-delta.tsv` | dontAsk vs auto MCP + settings self-edit |
| `…/{A,B,C,D}-stream.jsonl` | stream-json traces |
