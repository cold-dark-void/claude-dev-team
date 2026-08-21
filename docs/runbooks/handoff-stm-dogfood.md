# Handoff STM packet dogfood (AC-16)

Human ship gate for SPEC-018 / CDT-79. **Not CI.** Live re-captures under the
STM packet contract (`## State now` → `## Through-line` → `## appendix`); score
human 3/3 only after real sessions.

**Spec:** [SPEC-018](../../specs/core/SPEC-018-cold-session-handoff.md) §Human ship gate (AC-16)  
**Command:** [`/handoff`](../commands/handoff.md)  
**Skill:** [`skills/handoff/`](../../skills/handoff/SKILL.md)

**Status:** protocol ready · **human 3/3 dogfood OPEN** (do not claim pass without live runs).

**Warm thesis (CDT-85 / CDT-92):** dual-host discover + session-id bridge + mode
header landed (Claude and Grok automated paths). **AC-16 warm is NOT 3/3** until
a human runs bare `/handoff` on **Claude Code** and scores anti-relitigation
(Grok unit/dogfood alone does not close AC-16). See [Warm dogfood](#warm-dogfood-cdt-85)
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
| State now | May lead with `### Where we are` (omit if summary missing/invalid). Then Product surfaces (primary + unfinished/not-product), Open ship gaps, latest decisions, surviving hypotheses, opens (mechanical) |
| Through-line | Remainder after State now occupancy: hypothesis → kill/ruling/decision/fact (`_no events_` if empty) |
| appendix | Leftover kill catalog and facts, git code-state. No `### Pointers (courtesy)` heading. Inline `↳` stays |
| No tool dumps | No raw `toolUseResult` blobs |
| No legacy brief | No `## Convergence` / `## Dead-ends` / `## Code-state` / `## Open-threads` / `## Basics` as packet sections |

PreCompact rescue files (`*-precompact-*.md`) are **not** STM packets — spine
snapshot only; cold `/handoff <uuid>` remains the quality path.

**Light packets (M10c / CDT-91) — AC-16 exclusion (same class as PreCompact):**
`/handoff --light` / `HANDOFF_LIGHT=1` warm drafts (`*-draft.md`, header
`light: true`, honesty `not AC-16-scored`) are **reduced-cost mine tips**, not
ship-quality STM. **Do not score light as AC-16.** Use bare full warm `/handoff`
(no `--light`) for any session you intend to put in the results table.

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
bash skills/handoff/grok-to-claude-jsonl-test.sh  # CDT-92 adapter (Grok → Claude-shaped)
bash skills/handoff/discover-warm-test.sh         # dual-host: Grok first, stale Claude bridge no override, Claude regression, fail honesty
bash skills/handoff/finalize-test.sh              # warm file-only + mode:warm header
bash skills/handoff/assemble-test.sh              # mode cold|warm|omit
bash skills/handoff/precompact-test.sh            # M14 carve-out scoped (warm ok / cold decline)
```

### Grok warm note (CDT-92)

Grok bare `/handoff` is a **supported automated path**: discover resolves
`chat_history.jsonl` under `~/.grok/sessions/<urlenc-cwd>/<id>/`, adapts to
Claude-shaped JSONL, then shared spine-mine. Optional env: `GROK_SESSION_ID`,
`GROK_TRANSCRIPT_PATH`, `GROK_SESSIONS_DIR`, `GROK_CWD`. When Grok is resolvable
it **wins over a stale Claude bridge**. Neither host → fail hard (still no
freeform dual path).

Grok automated green ≠ AC-16 human 3/3. Score anti-relitigation on Claude Code
for the human gate below. PDH verify still applies before any scoring run.

### Remaining human gate (Claude Code — AC-16 warm)

Warm product thesis for AC-16 still requires a real **Claude Code** session
(anti-relitigation after compact @packet). Grok dogfood may be recorded as
extra rows but does not close the gate alone.

**Exact remaining steps (operator):**

1. Open a **Claude Code** session in this repo (feat/CDT-92 or released plugin
   with CDT-85/CDT-92). Prefer a long-debug thrash session with ≥1 kill + user ruling.
2. **PDH verify (MUST):** `bash skills/plugin-dir.sh verify` → `stm_marker=stm`
   (same gate as cold — see §0 above).
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
   - Bridge file `$MROOT/.claude/handoff/.live-session.json` present (`host: claude`)
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
| Dual-host discover (explicit Grok / cwd-newest over stale Claude; live Claude env beats Grok cwd) | automated |
| Fail honesty when neither host resolvable | automated |
| Mid-write warm carve-out; cold still declines | automated |
| Human bare `/handoff` on Claude Code → compact @packet anti-relitigation | **OPEN — human** |
| AC-16 3/3 including warm | **NOT claimed** |

**Do not** score freeform live-context essays as warm STM. **Do not** claim
AC-16 warm 3/3 from cold-only dogfood, Grok-only dogfood, or unit fixtures alone.

---

## Cost knobs (CDT-90 — optional; do not change ship defaults during dogfood)

When scoring packet quality, keep these defaults unless you are deliberately
measuring a cheaper config:

| Stage / env | Default | Dogfood note |
|-------------|---------|--------------|
| Chunk-summarizer + warm annotation | **`haiku`** | Cheap stages always |
| Merged miner | **session inherit** | Opt-in: `--miner-model <fast|balanced|max|alias>` or `HANDOFF_MINER_MODEL=<tier>` |
| `HANDOFF_SPINE_TOKENS` | **120000** | Lower → more chunking + cheaper map step, but **recall risk** |
| `/handoff --light` / `HANDOFF_LIGHT` | **off** | Warm-only cost preset (haiku miner if unset, skip annotation, spine 40k if unset, `*-draft.md`, no M8 cache). **Not AC-16-scored** — measure cost only; re-capture full tip before dogfood |

Lowering spine budget compounds savings with haiku summarizers, but can drop
kills/rulings the map step fails to preserve. **Measure before adopting** a lower
budget (re-score anti-relitigation on the same sessions). Do **not** lower the
code default for AC-16 scoring runs unless the experiment is the point of the run
— record the env override in the results notes when you do.

---

## Out of scope for this runbook

- CI automation of AC-16 (human gate by design)
- Claiming pass from unit fixtures alone (`events-thrash.json`, assemble tests) — PDH `plugin-dir-test.sh` is a separate CDT-82 gate, not a substitute for human 3/3
- Claiming AC-16 warm 3/3 without Claude Code bare-`/handoff` anti-relitigation (CDT-85); Grok automated path alone is insufficient (CDT-92)
- Linear dual-write of packet content (M11c)
- Treating PreCompact rescue as ship-quality STM
- Scoring light packets (`--light` / `*-draft.md` / `light: true`) as AC-16 — **do not score light as AC-16** (M10c; same exclusion class as PreCompact)
- Freeform live-context briefs scored as warm STM when discover fails (neither host)
- “Fix” = delete entire `~/.claude/plugins/cache` (CDT-82 AC-8 forbids this as sole remedy; use PDH preference or `CLAUDE_PLUGIN_ROOT`)

---

## Related

- SPEC-018 acceptance tests (automated) — separate from AC-16
- [`docs/commands/handoff.md`](../commands/handoff.md) — cold/warm usage
- Typical loop: `/handoff` → `/branch` \| `/fork` → `/compact @packet-file`
