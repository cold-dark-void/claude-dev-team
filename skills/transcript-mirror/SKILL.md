---
name: transcript-mirror
description: >
  Opt-in Stop + SessionEnd recorder for a Transcript mirror (live compressed
  session record). Meaning channel to main.md; Channel sidecars for thinking,
  tool_result, and injection. Not a slash Surface. Copy hook-shim.sh; do not
  install via /setup orchestration.
---

# Transcript mirror

Live per-session compressed record of the **Meaning channel** (user + assistant
text) plus lossless **Channel sidecars**. This is **not** an STM packet and
**not** a compact seed — those terms stay with `/handoff`.

The recorder is not a slash Surface. `/compact-transcript` is the consumer
Surface (SPEC-036 M14).

Governing spec: `specs/core/SPEC-036-transcript-mirror.md`.

Store: `~/.claude/transcript/<session-id>/` (`main.md`, `thinking/`,
`tool_result/`, `injection/`, `meta`, `cursor`; optional `agents/<id>/`
with the same six entries). Identity is `session_id`.

## Enablement

Opt-in is hook registration. Default is off. **Do not** add this hook through
`/setup orchestration`. Greenfield Stop stays `stop-review.sh` only.

1. Copy `skills/transcript-mirror/hook-shim.sh` to
   `.claude/hooks/transcript-mirror.sh` in the project.
2. Make it executable.
3. Merge the JSON below into `.claude/settings.json`. The recorder is the
   **second** Stop command. The `command` string must not contain `|`.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/stop-review.sh\"",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

SessionEnd missing on a host is a graceful absence.

## SubagentStop (separate opt-in)

Do **not** add SubagentStop to the JSON above.
It is a separate opt-in (same shim, `timeout` 10, no pipes).
Do **not** default-on.
Measure Meaning-channel ticks vs empty or tool-only SubagentStop first.

Merge this extra event. Do not replace the Stop + SessionEnd JSON.

```json
{
  "hooks": {
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Nest: `~/.claude/transcript/<sid>/agents/<id>/` (same six entries).
Parent nest-ref (exactly one):

```
> @agents/worker-1/main.md
```

Stop/SessionEnd with a non-empty `agent_id` stay no-ops.
If a host has no SubagentStop event, the settings entry stays inert.

| Source | Meaning-channel | Empty/tool-only | Ratio | Status |
|--------|-----------------|-----------------|-------|--------|
| Live hook | — | — | — | unmeasured (no live SubagentStop) |
| `--agent` CLI | 2 | 0 | 1.00 | T3 AC8 (`subagent-child.jsonl`) |

This report is ship-blocking for default-on.

## Grok Stop holes

Grok Stop may omit `transcript_path`. Reconstruct `chat_history.jsonl` with urlencode then `.cwd` fallback. A missing reconstructed file is a silent no-op.

## Manual catch-up

```
bash skills/transcript-mirror/transcript-mirror.sh --transcript FILE.jsonl --sid SESSION-ID
bash skills/transcript-mirror/transcript-mirror.sh --transcript FILE.jsonl --sid SESSION-ID --agent AGENT-ID
```

`--agent AGENT-ID` writes the nest under that sid.
`--agent` without `--transcript` creates no dirs.

The recorder always exits 0. It does not emit `decision: block`.

## Catch-up (`transcript-sync`)

If this project is opted-in, `transcript-sync` is **mandatory**.
It is not optional.
Use cron or an equivalent periodic or on-demand job.
Stop is the fast path.
SessionEnd is an opportunistic flush.
Do not inspect crontab.

`transcript-sync` locates sessions, skips in-progress sources, and invokes
the recorder.

```
bash skills/transcript-mirror/transcript-sync.sh [--sid SID] [--transcript FILE] [--check] [--cwd DIR]
```

`--sid` and/or `--transcript` create or update that session's Transcript mirror.
With no args, refresh every existing sid dir under the store.
If this project registered the recorder (any `hooks.*.command` contains
`transcript-mirror.sh` in `.claude/settings.json` or
`.claude/settings.local.json`), also locate cwd sessions that were never
mirrored.

`transcript-sync` does not invent, enumerate, or refresh agent nests.
Use the live SubagentStop hook or the recorder `--agent` flag.

`--check` prints a lag report (cursor vs source growth / missing mirror).
It always exits 0.
`/doctor` maps `--check` stdout to `transcript.mirror_lag`.
That check WARNs. It never FAILs.

In-progress sources (modified within 60s) are skipped.

The CLI always exits 0.

### Cron

For each opted-in project, arm one cron job or equivalent:

```
cd <project> && bash skills/transcript-mirror/transcript-sync.sh
```

If the plugin is not in the project tree, resolve `transcript-sync.sh` with
`plugin-dir.sh` (`file skills/transcript-mirror/transcript-sync.sh`) and run
that path after `cd <project>`.

## `/compact-transcript` (SPEC-036 M14)

The recorder is not a slash Surface. `/compact-transcript` is the consumer
Surface.

On hit it writes a bounded Meaning-channel file (Meaning tail) at
`~/.claude/transcript/<sid>.meaning-tail.md`. Compact `@`-attach is
`/compact-transcript`. Do not `@` `main.md` as the compact attach.
`@main.md` remains valid only as the full unbounded Meaning channel.

The Meaning tail is **not** an STM packet and **not** a compact seed — those
terms stay with `/handoff`. This Surface is not a host `/compact` replacement.
It does not truncate store `main.md`.

Bare `/compact-transcript` uses the live session id. A positional `<sid>` is
that sid as given. Hit stdout is the absolute path of the Meaning tail. You
`@` that path. Miss is fail-closed (exit non-zero; no tail created or
updated).

See `commands/compact-transcript.md`. Docs: `docs/commands/compact-transcript.md`.
