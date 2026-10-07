---
name: intercom
description: >
  Intercom spool protocol (SPEC-038 phase 1). The intercom CLI verbs
  (ask/send/away), the per-session spool layout, the record and heartbeat
  file formats, and the tg_api token funnel shared by poller.sh,
  watch.sh, setup-telegram.sh, and the hermetic suites. Agent-internal protocol skill,
  not a slash Surface. bash + jq + curl only (AC21).
user-invocable: false
---

# Intercom

The Intercom is a member's personal bot connector. Sessions write spool
records; the poller relays them to Telegram and back. This document is the
shared contract for sessions, the poller, and the phase-2 daemon. The
governing spec is `specs/core/SPEC-038-intercom-spool-protocol.md`.

Glossary terms: **Intercom**, **Walkie-talkie**, **Escalation**, **Away mode**
(`CONTEXT.md`).

## Call the CLI

`intercom.sh` is a subprocess CLI. Never source it. Source `common.sh` for the
library. Resolve the script through the plugin root:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
INTERCOM=$(bash "$PDH/skills/plugin-dir.sh" file skills/intercom/intercom.sh)
bash "$INTERCOM" ask "Which staging tag is live?"
```

## Verbs and exit codes

- `ask [--sid S] TEXT` — write `pending/<qid>.json`; print the qid. No network.
  The poller escalates unanswered questions (§ Escalation in the spec).
- `send [--sid S] [--summary T] [--file P] TEXT` — write one outbox record;
  print its path. No network. The poller drains outbox to Telegram.
- `away [on|off|status]` — toggle or read `state/away`; print `away: on` or
  `away: off`. Bare `away` means `status`. No network.
- `help` — usage on stdout.

Exit codes: `0` success, `1` operational failure (missing tool, bad `--file`,
unwritable state), `2` usage error or unresolved sid. A missing `jq` or `curl`
produces one actionable stderr line, never a stack trace (AC21). TEXT may be
one quoted argument; extra words are joined with single spaces. `--` stops
option parsing.

## Session id (sid)

Resolution order: explicit `--sid`, then `INTERCOM_SID`, then
`CLAUDE_SESSION_ID`, then the newest directory under `~/.claude/transcript/`
(best-effort; `TRANSCRIPT_MIRROR_ROOT` overrides that root for harnesses). No
resolution exits `2` with usage. A sid must match `[A-Za-z0-9._-]+`, must not
be `.` or `..`, and must be at most 128 characters. The sid names the spool
directory, so an unsafe sid is rejected, never mapped.

## State layout

State is box-level only — never inside the repo (AC23).
`INTERCOM_STATE_ROOT` reroutes the root for tests. Default root is
`~/.claude/telegram-router/`.

```
~/.config/telegram/bot_token     token, 0600, owner-only parent (700)
~/.claude/telegram-router/
  config.json                    schema 1; members allowlist keyed by chat id
  topics.json                    sid -> {thread_id, title}; "general" -> thread_id
  state/
    offset                       next getUpdates offset; non-negative integer
    heartbeat                    touched each poller cycle (epoch seconds line)
    poller.lock                  flock target
    seen.tsv                     "update_id<TAB>epoch" dedupe window, prune > 1000
    away                         absent = off; present = on
    inbox.stamp                  adapter mtime watermark for new inbox files
    last_wake_exit               adapter: last non-{0,75} poller exit that already woke
  spool/<sid>/
    inbox/                       inbound JSON for the session
    outbox/                      outbound JSON the poller drains
    pending/                     <qid>.json pending questions
    answered/                    answered questions (audit)
```

`common.sh` reads `config.json` but never creates it — `/setup telegram`
(T4) owns setup. Missing `config.json` degrades reads to defaults (for
example `concise_threshold` 1024).

## File formats

Spool record (inbox/outbox), one JSON object per file:

```json
{"ts": 0, "sid": "main", "dir": "in", "kind": "message",
 "text": "", "from_id": 0, "update_id": 0, "thread_id": 0}
```

`kind` is `message`, `answer`, `escalation`, or `offline`. Outbox records use
`dir: "out"` with optional `summary` and `file`. Inbox filenames are
`<epoch_ms>_<update_id>.json`. CLI-written outbox filenames are
`<epoch_ms>_0_<rand>.json` — the epoch prefix keeps drain order chronological,
`_0` marks a non-Telegram update, and the random suffix keeps same-millisecond
writes unique. Pending question (`pending/<qid>.json`, qid
`q_<epoch>_<rand>`):

```json
{"qid": "q_1791197624_ab12cd", "sid": "main", "text": "",
 "asked_at": 0, "escalated": false, "escalated_at": null}
```

Heartbeat: one line, integer epoch seconds, written by atomically replacing
the file. Readers compute staleness from the file mtime, not the content
(`now - mtime > stale_heartbeat_s`). The CLI never touches it.

`state/away` holds the epoch when written; presence is the signal. `seen.tsv`
rows are `update_id<TAB>epoch`; keep at most 1000. All writes are tmp-plus-rename
(`ir_record_tmp` + `ir_record_publish`), never partial in place.

## Outbox delivery contract

The poller is mechanical; `send` decides. The CLI sets `summary` when
`--summary` is given, or when the text exceeds `concise_threshold`
(generated: first paragraph, capped at 280 characters). The poller then:

- record with `summary` — `sendMessage(summary)`, then `sendDocument(file)`
  when present, else materialize `text` as a UTF-8 `.md` and upload it.
- record without `summary` — `sendMessage(text)`, then `sendDocument(file)`
  when present.

One outbound message is never chunk-split (AC9). `--file` must exist when
`send` runs; the poller keeps the record if a later upload fails
(at-least-once).

## Token and tg_api

Read the token only from `~/.config/telegram/bot_token` (mode 600). Never put
the token in argv, logs, spool files, or error text (AC4). Make every Telegram
call through the `tg_api METHOD [curl-args...]` funnel in `common.sh`:

- The funnel passes `url = "https://api.telegram.org/bot<TOKEN>/<METHOD>"` to
  curl through a `-K -` stdin config, so the token is never in argv.
- The funnel captures curl stderr, scrubs the token with a literal
  (`ir_scrub_token`), then re-emits it — the request URL can never leak.
- Callers pass their own `--max-time`; the funnel never retries. Do not pass
  `-K` to `tg_api`.

## Host adapter (`watch.sh`)

`watch.sh` is a subprocess CLI. Never source it. One cycle per invocation.
The armed host job is `bash <absolute-plugin>/skills/intercom/watch.sh`
every 30–60 s. `watch.sh` always exits 0. It sources `common.sh` for the
state root only. It never calls `tg_api` and never reads the bot token.

Each cycle:

1. Create `state/inbox.stamp` if missing, then run `poller.sh` once.
2. Discard poller stdout. Keep poller stderr in a temp file. Do not copy
   it to stdout. Delete the temp file.
3. Wake on new allowlisted inbox files (mtime newer than the stamp;
   `from_id` is a `config.json` `members` key). Print one inbound line.
4. Wake on a poller exit other than 0 or 75 only when that code differs
   from `state/last_wake_exit`. Print one failure line. A 0 or 75 cycle
   deletes the latch.
5. Touch the stamp.

Wake lines (token-free; no inbound body):

```
intercom: inbound sid=<sid>[,<sid>...] path=<abs-inbox> [<abs-inbox>...]
intercom: poller exit <n>
```

Unique sids are lexicographic. Each `path` is `$IR_STATE/spool/<sid>/inbox`
in the same order. When both fire, print inbound then failure. Idle paired
cycles write zero bytes on stdout.

`/setup telegram` prints a host-aware arming block: absolute `watch.sh`,
45 s cadence, Grok silent watcher, and Claude CronCreate only if empty
stdout injects zero parent turn.

## Hermetic testing

Point `INTERCOM_STATE_ROOT` at `mktemp -d` and shim `curl` on `PATH`; the
suites run with no network. `common.sh` is sourceable; `intercom.sh`,
`poller.sh`, and `watch.sh` refuse to be sourced. Temp paths use `mktemp` or
`${TMPDIR:-/tmp}`. Probe the live API only with `probe.sh` (operator-invoked,
never inside suites).
