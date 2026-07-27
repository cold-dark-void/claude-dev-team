# /handoff

Session handoff (SPEC-018, CDT-79). Produces one **STM packet** (short-term
working memory / **compact seed**): a noise-stripped, jury-style evidence
artifact so a fresh or post-compact session continues from outcomes, kills, and
user rulings without re-litigating dead ends.

Packet section order is fixed: **State now → Through-line → appendix**.

**Primary consumer loop:**

```
long session → /handoff → /branch|/fork → /compact @packet-file
```

This is a **compact seed**, not a replacement for `/compact`. Not a Linear
dual-write.

## Usage

```
/handoff <session-uuid> [slug]
/handoff [--slug <slug>]
/handoff --help
```

Slug is optional (second positional or `--slug`); sanitized to `[a-z0-9-]+`;
default `stm`.

## Modes

| Mode | Invocation | What it does |
|------|------------|--------------|
| **Cold** | `/handoff <session-uuid> [slug]` | Spine-mines that past session; writes the full STM packet; **prints State now + Through-line** and **cites the packet path** for appendix (M7). Cache hit serves core + path without re-mine (M8). |
| **Warm** | bare `/handoff` or `/handoff --slug <s>` | Spine-mines **this** session's live JSONL via the same engine; **writes packet file only** (M10). Packet header includes `mode: warm` + `session: <id>` (CDT-85 / CDT-92 bridge). Not printed as primary product — you are still in the session. Works on **Claude Code and Grok** (dual-host discover). Neither host resolvable → clear fail (no freeform live-context dual path). |
| **Help** | `/handoff --help` | Prints usage and exits. Any unknown flag prints usage too. |

The `<session-uuid>` is a UUID like `00000000-0000-4000-8000-000000000004` — one
surfaced by [`/recall`](./recall.md) or visible in a transcript filename.

### Warm discover — Grok vs Claude (CDT-92)

Bare `/handoff` resolves the live host via `skills/handoff/discover-warm.sh`
(command fence stays thin — no host branch after discover):

| Host | Session id | Transcript for prepare | Bridge `host` |
|------|------------|------------------------|---------------|
| **Grok** | Grok session id | Claude-shaped **adapted** JSONL under `${TMPDIR}` (from raw `chat_history.jsonl`) | `grok` (bridge stores **source** `chat_history` path) |
| **Claude** | Claude session id | live `*.jsonl` under projects dir | `claude` |

**Host selection:**

1. **Explicit Grok env** wins over Claude.
2. **Grok cwd-newest** wins over a *stale* Claude bridge, but **yields** when
   live Claude env is set (`CLAUDE_SESSION_ID` / non-Grok `*_TRANSCRIPT_PATH`) —
   so dual-host repos do not mine the wrong session.
3. Else **Claude** (CDT-85 env → bridge → stem → cwd-newest).
4. Else **fail hard** (clear diagnostic; no freeform warm STM).

**Grok env** (optional; defaults: cwd + `~/.grok/sessions`):
`GROK_SESSION_ID`, `GROK_TRANSCRIPT_PATH`, `GROK_SESSIONS_DIR`, `GROK_CWD`.

Shared spine-mine after prepare is unchanged (M3b). Packet still lands under
the **target** project MROOT (CDT-80).

### The STM packet

Both modes produce the same packet shape, fixed order:

| Section | Contents |
|---------|----------|
| **State now** | Mechanical selection from the **tail** of the event log: latest decisions, surviving unkilled hypotheses, all opens. Not a freeform essay. |
| **Through-line** | Chronological evidence events (hypothesis / killed / ruling / decision / fact), grouped by `workstream` when multiple. Short-verbatim user rulings and kill reasons inline (M6). |
| **appendix** | Longer kill catalog if needed, deterministic git code-state, dense basics, conflict/open catalog, courtesy pointers. |

Product success is measured by post-`/compact @packet` continuity — not by how
much text is dumped into a blank session.

- Quotes and kill reasons are **load-bearing** when short; raw tool dumps are
  defects (M6).
- Pointers (`transcript:L*`, `commit:`, `file:`) are **courtesy** drill-downs,
  never required to understand a claim.
- Stated-intent vs git mismatches surface as lightweight `conflict`/`open`
  events (M5) — deep audit is [`/council`](./council.md).

Packet files live under the **target session project's** `.claude/handoff/`
(not the invoker's cwd — CDT-80):

```
<target-MROOT>/.claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md
```

- **Cold** `/handoff <uuid>` resolves the project from the located transcript
  (session `cwd`, then git-common-dir). Invoking from `~/.claude` or `/tmp`
  still writes under the target repo (e.g. `…/claude-dev-team/.claude/handoff/`),
  never `~/.claude/.claude/handoff/`.
- **Warm** bare `/handoff` uses this live session's project MROOT.
- Worktree sessions share the main repo MROOT via `git-common-dir`.
- Non-git target: `HANDOFF_DIR = <project-dir>/.claude/handoff/`; git appendix
  may be empty. If the target root cannot be determined → fail hard (no invoker
  write).

Re-capturing the same session writes a **new** file with `Supersedes: <prior>`
(M11). Cache for cold re-invokes lives under `$MROOT/.claude/handoff/cache/`
(outside `memory.db`). Printed packet path must match the actual write path.

### How the pipeline works

Cold and warm share one **spine-mine** engine after prepare (they differ only
in entry, exit, and warm-only annotation):

1. **Cache check (cold)** — unchanged session → serve cached core + path (M8).
2. **Pre-pass** — deterministic, LLM-free: locate canonical transcript via
   shared [transcript-parse](../../skills/transcript-parse/SKILL.md), dedup
   fork copies, strip raw tool output, size-decide (M1, M2). Cold declines
   transcripts modified < 60 s ago (M9). Warm may read mid-write via a
   warm-only carve-out (M14).
3. **Optional chunk map** — monster spines are chunk-summarized in parallel,
   then reduced (M3).
4. **One merged miner** — single Task, one spine read; writes both event
   files (`through_line.json` + `state.json`, all 7 kinds). Code-state is
   **git only** — no LLM miner (M3b).
5. **Warm annotation (optional)** — labels/rank on existing event IDs only;
   never invents evidence.
6. **Assemble (LLM-free)** — merge events into **State now → Through-line →
   appendix**; write packet file. Cold prints core + path; warm prints path only.

## Examples

**Reconstruct a past session (cold):**
```
/handoff 00000000-0000-4000-8000-000000000004
```
Prints State now + Through-line and cites the full packet path. Expected
shape (abridged):
```
## State now
- decision: Fix TOCTOU race in `cache.go:Get` (not the mutex)
- open: confirm pool stats under load

## Through-line
- hypothesis: lock contention in the pool
- killed: pprof showed no blocking — "no, it's not the mutex, we already ruled that out"
- decision: race is TOCTOU in Get; fix landed

Full packet: .claude/handoff/20260723-1410-00000000-0000-4000-8000-000000000004-stm.md
```

**Serve from cache (re-invoking on an unchanged session):**
```
/handoff 00000000-0000-4000-8000-000000000004
```
```
(served from cache — session unchanged since last handoff)
## State now
...
```

**Capture the current live session (warm):**
```
/handoff
```
```
Warm handoff written → /home/you/project/.claude/handoff/20260723-1422-abcd1234-cache-race-fix.md
```

Typical next step after warm:
```
/branch
/compact @.claude/handoff/20260723-1422-abcd1234-cache-race-fix.md
```

**In-progress session is declined (cold freshness guard):**
```
/handoff 00000000-0000-4000-8000-000000000004
```
```
That session looks in-progress (its transcript was modified < 60 s ago). To avoid
producing a partial handoff, /handoff declines to parse it mid-write. Try again
once the session has settled (≥ 60 s idle).
```

## Rescue artifacts (PreCompact)

Before any compaction (manual `/compact` or auto), a `PreCompact` hook can capture a
deterministic, LLM-free **rescue artifact** so context loss is not permanent
(SPEC-018 M12–M18).

| What | Detail |
|------|--------|
| **When** | `PreCompact` fires for both manual and auto compaction (matcher-less registration) |
| **Writes** | `<repo>/.claude/handoff/<session-id>-precompact-<seq>.md` — spine snapshot + `[L<n>]` drill-down pointers |
| **Not** | An STM packet (State now / Through-line / appendix quality needs spine-mine; cold `/handoff <uuid>` remains the quality path) |
| **Surfacing** | `PostCompact` / `SessionStart` print a one-line pointer (path + `/handoff <uuid>` suggestion); SessionStart consumes the marker; body is never dumped into context |
| **Retention** | Keep newest N per session (default 3, env `HANDOFF_PRECOMPACT_MAX_PER_SESSION`); only `*-precompact-*.md` — STM packets and M8 cache are untouched |
| **Fail-open** | Capture failure → one stderr line + exit 0; never blocks compaction (never exit 2) |
| **Timeout** | Soft prepare timeout default 30 s (`HANDOFF_PRECOMPACT_TIMEOUT`); spine tail-cap default 2 MB (`HANDOFF_PRECOMPACT_SPINE_BYTES`) |

**Recovery:** after compaction (or on the next session start) follow the pointer and run
`/handoff <session-id>` for the full STM packet. Artifacts are machine-local (gitignored under
`.claude/handoff/`). If hooks are unregistered or the Claude Code version lacks
`PreCompact`/`PostCompact`, cold + warm `/handoff` behave exactly as before (graceful
absence). Wire hooks via `/setup orchestration` (init-orch templates are SoT;
`check-hook-templates` is template-hygiene only — dual-copy retired CDT-54;
live `settings.json` is machine-local).

## See Also

- [`/recall`](./recall.md) — find a past session's uuid to hand off (cross-session discovery)
- [`/retro`](./retro.md) — shares the same read-only transcript parsing seam (SPEC-012)
- [`/council`](./council.md) — owns deep adversarial claim verification; handoff's intent-vs-git flag is only a lightweight heuristic
- [`/orchestrate`](./orchestrate.md) — long-running flow whose session you might later hand off
