---
name: transcript-mirror
description: >
  Opt-in Stop + SessionEnd recorder for a Transcript mirror (live compressed
  session record). Meaning channel to main.md; Channel sidecars for thinking,
  tool_result, and injection. Not a slash Surface. Copy hook-shim.sh; do not
  install via /setup orchestration.
user-invocable: false
---

# Transcript mirror

Live per-session compressed record of the **Meaning channel** (user + assistant
text) plus lossless **Channel sidecars**. This is **not** an STM packet and
**not** a compact seed — those terms stay with `/handoff`.

The recorder is not a slash Surface. `/compact-transcript` is the consumer
Surface (SPEC-036 M14). On-demand Meaning-channel overlay is skill CLI
`summarize-transcript` (SPEC-036 M15). It is not a slash Surface.

Governing spec: `specs/core/SPEC-036-transcript-mirror.md`.

The store is as sensitive as `~/.claude/projects`. It holds unredacted tool
output. Files are created mode 0600 and directories mode 0700 (`umask 077`).
`@`-attaching `main.md` or a Meaning tail into another session re-exposes
that text.

`TRANSCRIPT_MIRROR_REDACT_CMD`, when set, filters each Channel sidecar.
The command reads the sidecar on stdin and writes the replacement on stdout.
Exit 0 and a non-empty stdout replace the file. Otherwise the original
sidecar is kept. Unset leaves sidecars unchanged.

Store: `~/.claude/transcript/<session-id>/` (`main.md`, `thinking/`,
`tool_result/`, `injection/`, `meta`, `cursor`; optional `agents/<id>/`
with the same six entries; optional `verbatim/` for Verbatim originals).
Identity is `session_id`.

## Enablement

Opt-in is hook registration. Default is off. **Do not** add this hook through
`/setup orchestration`. Greenfield Stop stays `stop-review.sh` only.

Run the installer from the project you want to opt in.
Resolve it through `plugin-dir.sh`. Do not use a cwd-relative `skills/` path.

```bash
PDH="${PLUGIN_ROOT:?set PLUGIN_ROOT to the plugin root}"
INSTALL=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/install.sh)
bash "$INSTALL"
```

`--subagent` also merges SubagentStop. `--cron` prints one cron line and
does not edit crontab. The line sets
`PATH=/usr/local/bin:/opt/homebrew/bin:$PATH` and calls the absolute
`transcript-sync.sh`.

Manual copy:

```bash
PDH="${PLUGIN_ROOT:?set PLUGIN_ROOT to the plugin root}"
SHIM=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/hook-shim.sh)
cp "$SHIM" .claude/hooks/transcript-mirror.sh
chmod +x .claude/hooks/transcript-mirror.sh
```

The shim lives in the plugin cache or marketplace clone, not in the project.
`CLAUDE_PLUGIN_ROOT` wins when that directory contains `skills/plugin-dir.sh`.
Otherwise the shim uses the highest cached `dev-team` version.
A copied shim runs with the project as cwd, so the cwd plugin check misses
the install. Cron that does not set `CLAUDE_PLUGIN_ROOT` keeps the cache tier.

Merge the JSON below into `.claude/settings.json` when you skip the installer.
The recorder is the **second** Stop command. The `command` string must not
contain `|`.

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

Fixture ratio = meaning-text lines / (meaning-text lines + empty files + tool-only files).
`subagent-child.jsonl` contributes 2 meaning-text lines.
`subagent-child-empty.jsonl` and `subagent-child-tool-only.jsonl` contribute one each.
Ratio = 0.50. Live hook stays unmeasured.

| Source | Meaning-channel | Empty/tool-only | Ratio | Status |
|--------|-----------------|-----------------|-------|--------|
| Live hook | — | — | — | unmeasured (no live SubagentStop) |
| `--agent` CLI fixtures | 2 | 2 | 0.50 | three child fixtures (meaning, empty, tool-only) |

This report is ship-blocking for default-on.

## Grok Stop holes

Grok Stop may omit `transcript_path`. Reconstruct `chat_history.jsonl` with urlencode then `.cwd` fallback. A missing reconstructed file is a silent no-op.

## Manual catch-up

```bash
PDH="${PLUGIN_ROOT:?set PLUGIN_ROOT to the plugin root}"
REC=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/transcript-mirror.sh)
bash "$REC" --transcript FILE.jsonl --sid SESSION-ID
bash "$REC" --transcript FILE.jsonl --sid SESSION-ID --agent AGENT-ID
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

```bash
PDH="${PLUGIN_ROOT:?set PLUGIN_ROOT to the plugin root}"
SYNC=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/transcript-sync.sh)
bash "$SYNC" --sid SID
bash "$SYNC" --transcript FILE --sid SID
bash "$SYNC" --check
bash "$SYNC" --cwd DIR
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
It does not invoke `summarize-transcript`.

### Cron

For each opted-in project, arm one cron job or equivalent:

```cron
0 * * * * cd <PROJECT> && PATH=/usr/local/bin:/opt/homebrew/bin:$PATH bash <ABS-SYNC>
```

`<ABS-SYNC>` is the absolute path from
`plugin-dir.sh file skills/transcript-mirror/transcript-sync.sh`.
`install.sh --cron` prints the line with the project directory and that path.
The `PATH=` prefix is there because cron often has no Homebrew `jq` or `python3`.

## `/compact-transcript` (SPEC-036 M14)

The recorder is not a slash Surface. `/compact-transcript` is the consumer
Surface.

On hit it writes a bounded Meaning-channel file (Meaning tail) at
`~/.claude/transcript/<sid>.meaning-tail.md`. Compact `@`-attach is
`/compact-transcript`. Do not `@` `main.md` as the compact attach.
`@main.md` remains the (optionally overlaid) unbounded Meaning channel.

The Meaning tail is **not** an STM packet and **not** a compact seed — those
terms stay with `/handoff`. This Surface is not a host `/compact` replacement.
It does not truncate store `main.md`.

Bare `/compact-transcript` uses the live session id. A positional `<sid>` is
that sid as given. Hit stdout is the absolute path of the Meaning tail. You
`@` that path. Miss is fail-closed (exit non-zero; no tail created or
updated).

See `commands/compact-transcript.md`. Docs: `docs/commands/compact-transcript.md`.

## Meaning-channel overlay (SPEC-036 M15)

This skill CLI overlays oversized Meaning-channel bodies in parent `main.md`.
It is not a slash Surface. Default is off. You invoke it explicitly.
Do not invoke `/summarize-transcript`.

The recorder still writes verbatim. Overlay is on-demand only.

Overlay:

`skills/transcript-mirror/summarize-transcript.sh --sid <sid>`

Restore one turn:

`skills/transcript-mirror/summarize-transcript.sh --sid <sid> --restore T00000N`

`--sid` is required. Do not pass a positional sid. Do not omit `--sid`.
`<sid>` is one path component. Do not use `/`, `.`, or `..`.
`<turn-id>` is `T` plus a 6-digit 1-based heading ordinal (`T000001`).

Do not hang this CLI on `transcript-sync` no-args or cron.
Do not run it from `/compact-transcript`, `/handoff`, `/doctor`,
`/setup orchestration`, or the recorder.

### Verbatim original store

Originals live in `<sid>/verbatim/`. That dir is optional.
It is not a Channel sidecar kind.

- `verbatim/T00000N.txt` — Verbatim original. Bytes equal the
  pre-replacement Meaning-channel payload.
- `verbatim/T00000N.sum` — summary text for rebuild re-apply.
  Not a Verbatim original.

The `@ref` in `main.md` is `> @verbatim/T00000N.txt`.
Rebuild re-applies from `.sum` without an LLM.

### Seam

`SUMMARIZE_TRANSCRIPT_CMD` is the only summarizer seam.
The command reads the Meaning-channel payload on stdin.
It writes a summary on stdout. It must exit 0.

If the env is unset or empty, skip eligible turns.
Leave those turns verbatim.

The plugin does not ship a live LLM caller.
`--restore` does not read this env. Rebuild re-apply does not read this env.

### Eligibility

Meaning payload = turn-block lines that are not the heading and do not
match `^>\s*@`.

A turn is eligible only when UTF-8 `wc -c` of that payload is **> 8192**.
Use size only. Do not use age.
A payload of exactly 8192 is not eligible.
Already-replaced turns (body has `^>\s*@verbatim/`) are not eligible.

Parent sid `main.md` only. Nests are OUT.
Do not overlay `agents/*/main.md`.

Keep the heading. Keep leading and trailing `^>\s*@` lines.
Replace the Meaning-channel payload with the summary plus exactly one
`> @verbatim/<turn-id>.txt`.
If the summary is empty, the command exits non-zero, or the summary is
not shorter than the payload, leave that turn verbatim.
Do not write `[summarization failed]`.

### Fail-closed

Detect uses `transcript-sync.sh --check --sid <sid>` only.
Consume only `status=ok`. Else exit 1 and do not write.

Do not copy `transcript-sync` fail-open. A miss must not exit 0.

| Case | Exit |
|------|------|
| Detect miss / helper missing / `python3` missing | 1 |
| Usage (no-args, missing `--sid`, unknown flags, `--restore` without `<turn-id>`) | 64 |
| Zero eligible turns | 0 |
| Overlay success | 0; stdout `sid=<sid> replaced=<n>` |
| Restore success | 0; stdout `sid=<sid> restored=<turn-id>` |
| Missing or not-overlaid restore id | 1 |

`--restore T00000N` splices the Verbatim original back.
It drops that turn's `@verbatim/` line.
It deletes that turn's `.txt` and `.sum`.
It does not invoke the seam.

### Consumers

`@main.md` remains the (optionally overlaid) unbounded Meaning channel.
Compact `@`-attach stays `/compact-transcript`.
This CLI does not write a Meaning tail.
`/compact-transcript` does not overlay.

The Transcript mirror Channel sidecar taxonomy stays
`thinking | tool_result | injection`.
