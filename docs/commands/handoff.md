# /handoff

Session handoff (SPEC-018). Reconstructs the hard-won state of a session — the root cause it converged on, the hypotheses it killed, the verbatim user corrections, the git code-state, open threads, and established basics — into one dense, pointer-bearing brief. It transfers *convergence*, not just *what changed* (git already has that), so a fresh session starts from the answer instead of re-deriving it. Two modes: **cold** reconstructs a *past* session from disk and injects the brief into the current one; **warm** captures the *current* live session to a file for a future one.

## Usage

```
/handoff <session-uuid>
/handoff
/handoff --help
```

## Modes

| Mode | Invocation | What it does |
|------|------------|--------------|
| **Cold** | `/handoff <session-uuid>` | Reconstructs that past session from its recorded transcript and **injects** the brief into THIS session (M7). Survives `/compact`, multiday gaps, and multi-fork transcripts. |
| **Warm** | `/handoff` (no args) | Captures the **current** live session into the same five-section brief and **writes** it to `.claude/handoff/<session-id>-<slug>.md` (M10). Not injected — you are still in the session. |
| **Help** | `/handoff --help` | Prints usage and exits. Any unknown flag prints usage too. |

The `<session-uuid>` is a UUID like `00000000-0000-4000-8000-000000000004` — one surfaced by [`/recall`](./recall.md) or visible in a transcript filename.

### The five-section brief

Both modes produce the same five labeled sections, in this fixed order:

| Section | Contents |
|---------|----------|
| **Convergence** | The current correct mental model / root cause the session landed on, stated operationally ("X happens because Y; the fix is Z"). If still open, the leading hypothesis. |
| **Dead-ends** | The anti-gaslighting payload: rejected hypotheses and why each was killed, plus user corrections quoted **verbatim** — so the new session never re-proposes them. |
| **Code-state** | What `git` actually shows (diff/log/status): changed files, recent relevant commits, staged/uncommitted state. Ground truth, independent of what the transcript claimed. |
| **Open-threads & conflicts** | Unfinished tasks, unanswered questions, contradictions, plus a lightweight heuristic flag for stated intents with no matching change in git (M5 — a flag to verify, not a verdict). |
| **Basics** | Established context a newcomer needs: what is being built, vocabulary, hard constraints (quoted verbatim), environment, conventions. |

Every non-trivial claim carries a drill-down pointer — `transcript:L<n>`, `commit:<hash>`, or `file:path:symbol` — never a raw tool-output dump (M6).

### How cold mode works

Cold mode is robust against `/compact`, multiday gaps, and 70 MB+ multi-fork "monster" transcripts because the heavy lifting is split between a deterministic engine and a parallel LLM fan-out:

1. **Cache check** — if an unchanged session was already handed off, the cached brief is served and the command stops (M8).
2. **Pre-pass** — a deterministic, LLM-free stage locates the canonical transcript via the shared [transcript-parse](../../skills/transcript-parse/SKILL.md) seam, dedups copied fork messages, strips raw tool output, and size-decides (M1, M2). Transcripts modified < 60 s ago are declined as in-progress (M9).
3. **Fan-out of five extractors** — five specialized subagents (Convergence / Dead-ends / Code-state / Open-threads / Basics) run **in parallel, in one block**, each producing one section. Monster transcripts are first chunked and summarized, then reduced (M3).
4. **Finalize** — the engine merges the sections into the bounded brief (≤ ~400 lines), prints it into the session, and writes the cache.

A second `/handoff` on the same unchanged session is a single cheap cache hit — no re-distillation.

## Examples

**Reconstruct a past session and start from its conclusion:**
```
/handoff 00000000-0000-4000-8000-000000000004
```
Builds the brief and injects it. Expected output (abridged):
```
## Convergence
The flake was a TOCTOU race in `cache.go:Get`, not the mutex (`transcript:L1840`).
Fix landed in `commit:a1b2c3d`.

## Dead-ends
### Rejected hypotheses
- Lock contention in the pool — killed: pprof showed no blocking (`transcript:L902`).
### User corrections (verbatim)
- > "no, it's not the mutex, we already ruled that out" (`transcript:L1210`) — overruled the lock hypothesis.
...
```

**Serve from cache (re-invoking on an unchanged session):**
```
/handoff 00000000-0000-4000-8000-000000000004
```
```
(served from cache — session unchanged since last handoff)
## Convergence
...
```

**Capture the current live session for the next one:**
```
/handoff
```
```
Warm handoff written → /home/you/project/.claude/handoff/abcd1234-cache-race-fix.md
```

**In-progress session is declined (freshness guard):**
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
| **Not** | The five-section M4 brief (that still needs a model; cold `/handoff <uuid>` remains the quality path) |
| **Surfacing** | `PostCompact` / `SessionStart` print a one-line pointer (path + `/handoff <uuid>` suggestion); SessionStart consumes the marker; body is never dumped into context |
| **Retention** | Keep newest N per session (default 3, env `HANDOFF_PRECOMPACT_MAX_PER_SESSION`); only `*-precompact-*.md` |
| **Fail-open** | Capture failure → one stderr line + exit 0; never blocks compaction (never exit 2) |
| **Timeout** | Soft prepare timeout default 30 s (`HANDOFF_PRECOMPACT_TIMEOUT`); spine tail-cap default 2 MB (`HANDOFF_PRECOMPACT_SPINE_BYTES`) |

**Recovery:** after compaction (or on the next session start) follow the pointer and run
`/handoff <session-id>` for the full brief. Artifacts are machine-local (gitignored under
`.claude/handoff/`). If hooks are unregistered or the Claude Code version lacks
`PreCompact`/`PostCompact`, cold + warm `/handoff` behave exactly as before (graceful
absence). Wire hooks via `/init-orchestration` (templates + `check-hook-templates` are the
ship gate; live `settings.json` is machine-local).

## See Also

- [`/recall`](./recall.md) — find a past session's uuid to hand off (cross-session discovery)
- [`/retro`](./retro.md) — shares the same read-only transcript parsing seam (SPEC-012)
- [`/council`](./council.md) — owns deep adversarial claim verification; handoff's intent-vs-git flag is only a lightweight heuristic
- [`/orchestrate`](./orchestrate.md) — long-running flow whose session you might later hand off
