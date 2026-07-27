# Handoff STM packet dogfood (AC-16)

Human ship gate for SPEC-018 / CDT-79. **Not CI.** Live re-captures under the
STM packet contract (`## State now` → `## Through-line` → `## appendix`); score
human 3/3 only after real sessions.

**Spec:** [SPEC-018](../../specs/core/SPEC-018-cold-session-handoff.md) §Human ship gate (AC-16)  
**Command:** [`/handoff`](../commands/handoff.md)  
**Skill:** [`skills/handoff/`](../../skills/handoff/SKILL.md)

**Status:** protocol ready · **human 3/3 dogfood OPEN** (do not claim pass without live runs).

**Warm thesis (CDT-85):** automated session-id bridge + mode header landed;
**AC-16 warm is NOT 3/3** until a human runs bare `/handoff` on **Claude Code**
(not Grok) and scores anti-relitigation. See [Warm dogfood](#warm-dogfood-cdt-85)
below. Cold-only dogfood ≠ full product thesis.

---

## Gate (must all hold)

| # | Requirement |
|---|-------------|
| 1 | **≥3 re-captures** under the new STM packet contract |
| 2 | **≥2 long-debug** sessions: multi-hypothesis thrash with explicit kills |
| 3 | **≥1 multi-week** session: ≥2 calendar weeks of arc **or** multi-child program |
| 4 | Re-capture → `/branch` or `/fork` → `/compact @packet` |
| 5 | Next session **does not re-propose** packet-resident kills / user rulings |
| 6 | Human scorer: **3/3 pass** on the three sessions |

---

## Session selection

### Long-debug (≥2)

Pick real (or faithfully reconstructed) debug sessions that:

- Raised **multiple competing hypotheses** (not a single straight-line fix)
- Recorded **kills** with evidence (disconfirming test, user ruling, or verified fact)
- Left at least one **open** or surviving hypothesis at handoff time

Good sources: past `/debug` tickets, thrashy IC sessions, multi-root-cause
investigations already on disk under `~/.claude/projects/`.

### Multi-week (≥1)

Pick one of:

- A session (or chain) spanning **≥2 calendar weeks**, or
- A **multi-child program** arc (epic with several tickets / workstreams)

Must still produce a usable STM packet (decisions, kills/rulings, opens, git).

---

## Protocol (per session)

Do **not** skip steps. Record paths and outcomes in the results table.

### 0. PDH verify (CDT-82 — MUST pass before scoring)

Frozen marketplace installs can leave **cache `1.0.3` legacy** (`finalize --sections`, five extractors) beside a **marketplace/dev STM** tree (`finalize --events`) at the **same version string**. PDH must resolve STM — never soft-continue on legacy when STM is available.

**Before any AC-16 re-capture or human score**, run:

```bash
# From this repo / worktree (feat/CDT-79 dogfood):
bash skills/plugin-dir.sh verify

# Or after bootstrap (consumer cwd / live /handoff host):
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
bash "$PDH/skills/plugin-dir.sh" verify
```

| Expect | Meaning |
|--------|---------|
| `stm_marker=stm` + exit 0 | OK — STM engine (`--events`); record `root=` + `tier=` in notes |
| exit 2 | FAIL — legacy root while STM peer exists; **do not score AC-16** |
| `stm_marker=legacy` + exit 0 | WARN only if no STM peer; still not valid for STM dogfood |

**Operator force (no full reinstall / no “delete entire cache”):**

```bash
# Pin worktree or marketplace STM root for this shell / session host:
export CLAUDE_PLUGIN_ROOT=/path/to/feat-CDT-79   # or …/plugins/marketplaces/cold-dark-void
bash "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" verify
```

Contract: [SPEC-002](../../specs/core/SPEC-002-plugin-infrastructure.md) §`plugin-dir.sh` CLI (CDT-82). Automated fixture: `bash skills/plugin-dir-test.sh`.

### 1. Re-capture under new contract

```text
/handoff <session-uuid> [slug]
```

- Cold mode preferred for past sessions (prints **State now + Through-line**,
  cites full packet path for appendix).
- Warm (`/handoff` bare) only for the live session mid-work.
- Confirm packet headers in fixed order:
  `## State now` → `## Through-line` → `## appendix`
- Confirm kill catalog / rulings appear in Through-line or appendix (not freeform
  essay; not legacy five-section brief).

Packet path pattern:

```text
.claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md
```

### 2. Compact seed loop

```text
/branch   # or /fork
/compact @.claude/handoff/<packet-basename>.md
```

Use the **file path** as the compact seed (M7 cite). Do not paste the full
appendix into the live window.

### 3. Fresh / continued session check

In the post-compact (or forked) session:

1. Work from the packet core (State now + Through-line).
2. Attempt to continue the investigation or program.
3. **Pass criteria:** model does **not** re-propose:
   - hypotheses already marked **killed** in the packet
   - user **rulings** already recorded
4. **Fail criteria:** re-litigation of packet-resident kills/rulings, or packet
   missing load-bearing kills so the model invents them again.

Score each session **pass** / **fail** in the table. Optional notes: which kill
or ruling was re-proposed (quote + packet line).

### 4. Aggregate

- Need **3/3 pass** across the selected sessions (mix satisfies ≥2 long-debug +
  ≥1 multi-week).
- Any fail → fix packet quality / mine / assemble, re-capture that session, re-score.
- **Do not** mark CDT-79 AC-16 closed until the table shows 3/3 live pass.

---

## What “good packet” looks like (spot-check)

| Check | Expect |
|-------|--------|
| Shape | Three sections only: State now, Through-line, appendix |
| State now | Latest decisions, surviving hypotheses, opens (mechanical) |
| Through-line | Chronological evidence: hypothesis → kill/ruling/decision/fact |
| appendix | Kill catalog, facts, git code-state, pointer index |
| No tool dumps | No raw `toolUseResult` blobs |
| No legacy brief | No `## Convergence` / `## Dead-ends` / `## Code-state` / `## Open-threads` / `## Basics` as packet sections |

PreCompact rescue files (`*-precompact-*.md`) are **not** STM packets — spine
snapshot only; cold `/handoff <uuid>` remains the quality path.

---

## Results (live fill)

Leave rows blank until a real run. Add rows if you run more than three.

| # | Session id | Packet path | Kind (long-debug / multi-week) | Compact @packet | No re-proposed kills/rulings | Pass/fail | Date | Scorer |
|---|------------|-------------|-------------------------------|-----------------|------------------------------|-----------|------|--------|
| 1 |            |             | long-debug                    |                 |                              |           |      |        |
| 2 |            |             | long-debug                    |                 |                              |           |      |        |
| 3 |            |             | multi-week                    |                 |                              |           |      |        |
| 4 |            |             |                               |                 |                              |           |      |        |

**Human 3/3:** ☐ OPEN · ☐ PASS (date: ____) · ☐ FAIL (blockers: ____)

---

## Warm dogfood (CDT-85)

Bare `/handoff` spine-mines **this** session's JSONL (shared engine) and writes
a file-only STM packet with `mode: warm` + `session: <id>` in the header and
filename `<YYYYMMDD-HHmm>-<session-id>-<slug>.md`. That id is the session-id
bridge for later cold re-capture / `Supersedes:`.

### Automated coverage (shipped — not a human 3/3 substitute)

```bash
bash skills/handoff/discover-warm-test.sh   # bridge write/read, cwd-newest, fail honesty
bash skills/handoff/finalize-test.sh        # warm file-only + mode:warm header
bash skills/handoff/assemble-test.sh        # mode cold|warm|omit
bash skills/handoff/precompact-test.sh      # M14 carve-out scoped (warm ok / cold decline)
```

### Remaining human gate (Claude Code only)

Grok / non-Claude hosts typically lack `CLAUDE_SESSION_ID` → discover **fails
honestly** (no freeform live-context dual path). Warm product thesis requires
a real Claude Code session.

**Exact remaining steps (operator):**

1. Open a **Claude Code** session in this repo (feat/CDT-79 or released plugin
   with CDT-85). Prefer a long-debug thrash session with ≥1 kill + user ruling.
2. PDH verify: `bash skills/plugin-dir.sh verify` → `stm_marker=stm`.
3. If env is empty, export before bare handoff (optional when cwd-newest works):
   ```bash
   export CLAUDE_SESSION_ID=<uuid-from-transcript-filename>
   # or: export CLAUDE_TRANSCRIPT_PATH=~/.claude/projects/<encoded>/<uuid>.jsonl
   ```
4. Run bare warm:
   ```text
   /handoff
   ```
5. Confirm:
   - Packet under **target** `$MROOT/.claude/handoff/`
   - Header meta includes `mode: warm` and `session: <same-id>`
   - Filename contains that session id
   - Bridge file `$MROOT/.claude/handoff/.live-session.json` present
   - Fixed sections: `## State now` → `## Through-line` → `## appendix`
   - Mid-write during active chat still succeeds (warm M14 carve-out)
6. Compact seed loop:
   ```text
   /branch   # or /fork
   /compact @.claude/handoff/<packet-basename>.md
   ```
7. **Pass:** next session does **not** re-propose packet-resident kills/rulings.
8. Record row in [Results](#results-live-fill) with Kind note `warm` (or
   `long-debug+warm`). Optional: second warm re-capture → new file +
   `Supersedes: <prior>`.

| Warm thesis checklist | Status |
|-----------------------|--------|
| Session-id bridge (discover + packet header/filename) | automated |
| Fail honesty when no session id (Grok) | automated |
| Mid-write warm carve-out; cold still declines | automated |
| Human bare `/handoff` on Claude Code → compact @packet anti-relitigation | **OPEN — human** |
| AC-16 3/3 including warm | **NOT claimed** |

**Do not** score freeform live-context essays as warm STM. **Do not** claim
AC-16 warm 3/3 from cold-only dogfood or unit fixtures alone.

---

## Out of scope for this runbook

- CI automation of AC-16 (human gate by design)
- Claiming pass from unit fixtures alone (`events-thrash.json`, assemble tests) — PDH `plugin-dir-test.sh` is a separate CDT-82 gate, not a substitute for human 3/3
- Claiming AC-16 warm 3/3 without Claude Code bare-`/handoff` anti-relitigation (CDT-85)
- Linear dual-write of packet content (M11c)
- Treating PreCompact rescue as ship-quality STM
- Freeform live-context briefs scored as warm STM when discover fails
- “Fix” = delete entire `~/.claude/plugins/cache` (CDT-82 AC-8 forbids this as sole remedy; use PDH preference or `CLAUDE_PLUGIN_ROOT`)

---

## Related

- SPEC-018 acceptance tests (automated) — separate from AC-16
- [`docs/commands/handoff.md`](../commands/handoff.md) — cold/warm usage
- Typical loop: `/handoff` → `/branch` \| `/fork` → `/compact @packet-file`
