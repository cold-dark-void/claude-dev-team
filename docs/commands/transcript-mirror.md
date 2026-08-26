# Transcript mirror

The **Transcript mirror** is a live compressed session record.
It writes the **Meaning channel** (user + assistant text) to `main.md`.
It writes lossless **Channel sidecar** files for thinking, tool results, and injection.

This is **not** an STM packet and **not** a compact seed.
Those terms stay with [`/handoff`](./handoff.md).
Do **not** call `main.md` an STM packet or compact seed.

Governing spec: `specs/core/SPEC-036-transcript-mirror.md`.
This is not a slash command. Do not invoke `/transcript-mirror`.

## Enablement

Opt-in is hook registration. Default is off.
Do **not** add this hook through `/setup orchestration`.
Greenfield Stop stays `stop-review.sh` only.

1. Copy `skills/transcript-mirror/hook-shim.sh` to `.claude/hooks/transcript-mirror.sh` in the project.
2. Make it executable.
3. Merge the JSON below into `.claude/settings.json`.

The recorder is the **second** Stop command.
The `command` string must not contain `|`.
Both commands use `timeout` 10.

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

## Store

The store path is `~/.claude/transcript/<sid>/`.
Identity is `session_id`, not the repo or worktree.

Each sid dir has `main.md`, `thinking/`, `tool_result/`, `injection/`, `meta`, and `cursor`.

To attach the Meaning channel in a later session, mention:

```
@~/.claude/transcript/<sid>/main.md
```

`@refs` inside `main.md` are relative to that sid dir (`@thinking/…`, `@tool_result/…`, `@injection/…`).

## Fail-open

The recorder always exits 0.
It does not emit `decision: block`.
Failures append one line to `~/.claude/transcript/.errors.log`.
An unregistered invocation creates no new store dirs.

## SessionEnd

Register `hooks.SessionEnd[]` as well as Stop.
SessionEnd is an opportunistic flush at session end.
It ignores Stop `reason` filters.
If a host has no SessionEnd event, the settings entry stays inert.

## Grok Stop holes

Grok Stop delivery is incomplete.
Use SessionEnd and `transcript-sync` as the backstop.

- Grok may omit `transcript_path`. The recorder reconstructs `chat_history.jsonl` with urlencode then `.cwd` fallback. A missing reconstructed file is a no-op.
- Grok may pass `updates.jsonl`. The recorder switches to sibling `chat_history.jsonl`.
- Grok SessionEnd is unverified. Treat a missing event as a graceful absence.
- Stop `reason` values other than empty, `end_turn`, `channel_closed`, or `shutdown` are a no-op.

Do not trust per-turn Stop alone.
Run `transcript-sync` after sessions that skip Stop.

## Catch-up (`transcript-sync`)

If you opt in, `transcript-sync` is **mandatory**.
It is not optional.
Use cron or an equivalent periodic or on-demand job.
Stop is the fast path.
SessionEnd is an opportunistic flush.
Do not inspect crontab.

`transcript-sync` always exits 0.

```
bash skills/transcript-mirror/transcript-sync.sh
bash skills/transcript-mirror/transcript-sync.sh --sid SESSION-ID
bash skills/transcript-mirror/transcript-sync.sh --transcript FILE.jsonl --sid SESSION-ID
bash skills/transcript-mirror/transcript-sync.sh --check
```

- No args: refresh existing sid dirs. If this project registered the recorder, also create mirrors for cwd sessions that never fired Stop.
- `--sid` and/or `--transcript`: create or update that mirror.
- `--check`: print a lag report. Exit 0. `/doctor` maps this stdout to `transcript.mirror_lag` (WARN, never FAIL).
- In-progress sources are skipped.

### Cron

Arm one cron job or equivalent per opted-in project.
The recorder must be registered in that project.

```cron
# Hourly catch-up for one opted-in project
0 * * * * cd <PROJECT> && bash skills/transcript-mirror/transcript-sync.sh
```

Replace `<PROJECT>` with the project directory.

## Manual recorder

```
bash skills/transcript-mirror/transcript-mirror.sh --transcript FILE.jsonl --sid SESSION-ID
```

The recorder always exits 0.

## See also

- [`/handoff`](./handoff.md) — session handoff (separate Surface)
- Skill: `skills/transcript-mirror/SKILL.md`
