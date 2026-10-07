# SPEC-038: Intercom Spool Protocol (Phase 1)

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-05
**Covers**: `skills/intercom/` (`SKILL.md`, `common.sh`, `intercom.sh`, `poller.sh`, `watch.sh`, `setup-telegram.sh`, `probe.sh`, `test.sh`, `test-poller.sh`), `commands/away.md`, `commands/afk.md`, `commands/setup.md` (`telegram` and `slack` subs), `skills/doctor/checks/intercom.sh`, `README.md`

## Overview

Each member gets a personal Telegram **Intercom**: a per-member bot that relays
between the member's phone and their agent sessions. Sessions ask; the member
answers from Telegram; the **General** topic is the **walkie-talkie** for
anything, anytime. Default mode keeps the CLI primary and adds a 15-minute
**escalation** for unanswered questions. **Away mode** makes the intercom
primary. Phase 1 is file-based: per-session spool dirs, a thin `intercom` CLI,
and a harness-scheduled ephemeral poller. The phase-1 scheduler is harness
re-invocation (Claude CronCreate or a Grok silent watcher) of the host
adapter `watch.sh`; `poller.sh` stays one-shot. An idle paired cycle injects
no parent turn (CDT-512-C1). Zero new runtimes — bash, jq, curl, and flock
only (CDT-501 AC21, CDT-512-C1 AC1). A containerized daemon replaces the
poller in a phase-2 ticket; it MUST keep this spool interface
(§ Phase-2 contract).

Brainstorm: `.claude/plans/2026-10-03-brainstorm-telegram-intercom.md`
(box-level plan store). Glossary terms: Intercom, Walkie-talkie, Escalation,
Away mode (`CONTEXT.md`).

## State layout (box-level, never inside the repo)

Runtime state lives outside the repo (CDT-501 AC23). Test override:
`INTERCOM_STATE_ROOT`.

```
~/.config/telegram/bot_token          # token, 0600, owner-only dir
~/.claude/telegram-router/            # $IR_STATE
  config.json                         # member(s), thresholds, cadence
  topics.json                         # sid -> {thread_id, title}; "general" -> thread_id
  state/
    offset                            # next getUpdates offset (integer)
    heartbeat                         # epoch seconds, touched each poller cycle
    poller.lock                       # flock target (AC22)
    seen.tsv                          # "update_id<TAB>epoch" dedupe window (prune >1000)
    away                              # absent = off; present = on
    last_wake_exit                    # adapter: last non-{0,75} poller exit that already woke
    inbox.stamp                       # adapter: mtime watermark for new inbox files
  spool/<sid>/
    inbox/                            # inbound JSON for the session
    outbox/                           # outbound JSON the poller drains
    pending/                          # <qid>.json pending questions
    answered/                         # answered questions (audit)
```

`config.json` shape (schema 1; tolerates more members later — AC25):

```json
{"schema": 1,
 "members": {"197372681": {"name": "Alexander", "role": "owner"}},
 "default_session": "main",
 "concise_threshold": 1024,
 "escalation_timeout_s": 900,
 "stale_heartbeat_s": 180,
 "poll_timeout_s": 30}
```

The allowlist is exactly the `members` keys. Phase 1 pins exactly one entry.
Non-numeric keys are ignored with a warning (fail-closed, AC2).

**Spool record** (inbox/outbox, one JSON object per file,
`<epoch_ms>_<update_id>.json`):

```json
{"ts": 0, "sid": "main", "dir": "in", "kind": "message",
 "text": "", "from_id": 0, "update_id": 0, "thread_id": 0}
```

`kind`: `message` | `answer` | `escalation` | `offline`. `outbox` records use
`dir: "out"` and optional `"summary"` and `"file"` (longread attachment path).
CLI-written outbox records are named `<epoch_ms>_0_<rand>.json` — `_0` marks
a non-Telegram update (the CLI has no `update_id`) and `<rand>` keeps
same-millisecond writes unique.
**Pending question** (`pending/<qid>.json`): `{"qid", "sid", "text",
"asked_at", "escalated": false, "escalated_at": null}`.

## Session id (sid)

`intercom.sh` resolves the sid in this order: explicit `--sid` argument, then
`INTERCOM_SID`, then `CLAUDE_SESSION_ID`, then the newest directory under
`~/.claude/transcript/` (best-effort). No resolution → exit 2 with usage on
stderr. The transcript-mirror root is precedent (identity is the session).

## CLI verbs (`intercom.sh`)

Subprocess CLI — never sourced. Always exits 0 on success.

- `intercom ask [--sid S] TEXT` — write `pending/<qid>.json`; print the qid.
  No network. The poller escalates it (§ Escalation).
- `intercom send [--sid S] [--summary T] [--file PATH] TEXT` — write an
  outbox record. The poller drains outbox → Telegram. Longreads (§ Longread).
- `intercom away [on|off|status]` — toggle/read `state/away` (AC17 CLI side).
- `intercom help` — usage.

## Poller cycle (`poller.sh`)

One cycle per invocation. The harness schedule (§ Setup, § Host adapter)
re-invokes `watch.sh` every 30–60 s; `watch.sh` runs `poller.sh` once.
Inside the cycle, `getUpdates` long-polls (`timeout` = config
`poll_timeout_s`, default 30) for near-instant pickup. Never a resident
loop, never a daemon, never host crontab, never `scheduler_create` /
CronCreate / an LLM inside `poller.sh` or `watch.sh`. Idle paired cycles
write no session-facing stdout.

1. `flock -n` on `state/poller.lock`. Busy → exit 75, mutate nothing (AC22).
2. Validate `state/offset` is a non-negative integer. Missing/invalid →
   exit 2 with an instruction; fetch nothing (fail-closed, AC22).
3. Compute staleness: `now - mtime(state/heartbeat)` > `stale_heartbeat_s`
   → `was_stale=1`. Touch `heartbeat` at cycle start and end.
4. Drain `spool/*/outbox/` in filename order: send the concise summary
   (`sendMessage`), then the longread file if present (`sendDocument`);
   delete the record only after a 2xx response (at-least-once).
5. `getUpdates?offset=<offset>&timeout=<poll_timeout_s>`. Network error →
   exit 0, mutate nothing. `error_code: 409` → log, exit 4, mutate nothing
   (a second consumer holds the token).
6. Process updates in ascending `update_id`; skip ids already in `seen.tsv`.
   For each update from a chat id in the allowlist:
   - `/away` or `/afk` text → toggle `state/away`, send a confirmation to
     that chat, relay nothing (AC17 phone side; reserved command, distinct
     from v1.1 quick commands).
   - ignore when `from.id` equals this cycle's `getMe` bot id (self-echo;
     zero inbox, no pending→answered, no typing; offset still advances).
   - ignore empty-text (and empty-caption) `forum_topic_edited` /
     `forum_topic_created` / `forum_topic_closed` / `forum_topic_reopened`
     service messages the same way.
   - otherwise resolve sid: `thread_id` → `topics.json`. The general
     topic routes to `default_session`. An unmapped thread id with an empty
     map or a map that contains only `general` also routes to
     `default_session` (walkie-talkie; CDT-512-C3). An unmapped thread id
     when any non-`general` sid exists is ignored with zero artifacts
     (AC6 cross-delivery). Write an inbox record. Any other
     slash-prefixed text (commands addressed to other bots, or any other
     `/`-leading message) is session content and relays as a normal message —
     the reserved pair above is the only intercepted command (§ MUST NOT).
     On pickup send
     `sendChatAction` `typing` once (AC10). If `was_stale`, also send an
     `offline, queued` notice to that topic (AC12). If a pending question for
     that sid is unanswered, mark it answered (move to `answered/`) and set
     the record `kind: "answer"` (AC14).
   - a chat id not in the allowlist is ignored with zero artifacts (AC2).
7. After each processed update: write `state/offset` (`update_id + 1`) and
   append `seen.tsv`; prune rows older than 1000.
8. Escalation sweep (§ Escalation).

`poller.sh` success path writes no stdout. Warnings go to stderr. The host
adapter (§ Host adapter) consumes that cycle; the armed host job MUST NOT
copy poller stderr onto session-facing stdout.

## Host adapter (`watch.sh`)

Plugin-owned subprocess CLI at `skills/intercom/watch.sh`. Never sourced.
Cycle tools: bash, jq, curl, flock only (plus the same coreutils the poller
already uses: `find`, `date`, `stat`, `mktemp`). No LLM, no other
interpreter, no scheduler inside the cycle. One cycle per invocation; no
resident `while`/`sleep`.

The armed host job is `bash <absolute-plugin>/skills/intercom/watch.sh`,
not `poller.sh` directly. `watch.sh` always exits 0 so a host that treats
non-zero as a parent turn cannot wake on idle or on a repeating failure.

`watch.sh` MUST NOT read, pass, or print the bot token (no argv, no env).
It MUST NOT copy poller stderr onto stdout.

Wake predicate uses `config.json` `members` keys, never a hardcoded chat
id. Unpaired (no members): run `poller.sh` (SPEC-038 AC2: exit 0, no
heartbeat, no fetch) and print nothing.

**Inbox watermark.** `state/inbox.stamp` lives under the state root. If
the stamp is missing, create it, then run `poller.sh` (pre-existing inbox
files do not wake). After the cycle, a new allowlisted inbox record is a
`spool/<sid>/inbox/*.json` whose mtime is newer than the stamp and whose
`from_id` is a `members` key. Touch the stamp at the end of every adapter
cycle.

**Session-facing stdout** iff at least one of:

- **inbound:** this cycle wrote ≥1 new allowlisted inbox record
  (Walkie-talkie or a session topic). Phone `/away`/`/afk` write no inbox
  record. Outbox drain, Escalation sweep, ignored update types, 429 with
  poller exit 0, getUpdates transport failure with poller exit 0, and
  lock-held 75 are silent.
- **failure:** `poller.sh` exit ∉ {0, 75}, edge-triggered (below).

**Wake-line grammar** (token-free; MUST NOT dump inbound text, `from_id`,
`update_id`, or the bot token):

- inbound, one line:
  `intercom: inbound sid=<sid>[,<sid>...] path=<abs-inbox> [<abs-inbox>...]`
  Unique sids sorted lexicographically. Each `path` is the absolute inbox
  directory `$IR_STATE/spool/<sid>/inbox` (`INTERCOM_STATE_ROOT` honored),
  in the same order as `sid=`. Example:
  `intercom: inbound sid=main path=/home/u/.claude/telegram-router/spool/main/inbox`
- failure, one line: `intercom: poller exit <n>` where `<n>` is the decimal
  poller exit (never 0, never 75).
- inbound and first-failure in the same cycle: inbound line, then failure
  line.
- silent: zero bytes on stdout.

**Failure wake is edge-triggered.** `state/last_wake_exit` holds the last
non-{0,75} poller exit that already produced a failure wake. First such
exit prints the failure line and records it. A repeating identical exit
stays silent until a 0/75 cycle (delete `last_wake_exit`) or a different
non-{0,75} exit (print and update). Inbound wake fires every cycle that
wrote new inbox records, independent of the failure latch.

## Escalation

For every `spool/*/pending/*.json` not yet answered, and not yet escalated:

- Away ON (`state/away` present) → escalate immediately (AC17).
- Default mode → escalate when `now - asked_at` > `escalation_timeout_s`
  (default 900 s ≈ 15 min) (AC14).
- An expiry that elapses while the poller is down fires on the next poll
  (AC14) — the sweep compares timestamps, never timers.

Escalation sends the question text to the session's intercom topic
(auto-creating the topic — § Topics) exactly once: set `escalated: true` and
`escalated_at`. An escalated question never re-fires (AC14). Answering it —
any allowlisted inbound in that session's topic or the general topic for the
default session — cancels further escalation and relays the answer to the
session spool (AC14).

## Topics

`topics.json` maps sid → `thread_id`. Pairing seeds `general` when the
pairing message carries `message_thread_id` (CDT-512-C3). On the first
outbound or escalation for an unmapped sid, the poller calls
`createForumTopic` (title = sid) and records it — outbound notifications
auto-create the session topic (AC11). The general topic is the
walkie-talkie: its messages route to `default_session`, and that session's
replies return to the general topic (AC6). An inbound `message_thread_id`
absent from the map still routes to `default_session` when the map is `{}`
or contains only `general`. Fail-closed unmapped stays when any
non-`general` sid exists (AC6 cross-delivery). `topics_enabled` is a setup
mode flag; inbound routing uses the map shape, not that flag. Per-session
topics prevent cross-delivery (AC6).

## Longread

Outbound text longer than `concise_threshold` (default 1024 chars,
configurable) is never chunk-split. It becomes exactly one concise summary
message plus one rich file artifact (AC9): the first paragraph, capped at 280
chars, via `sendMessage`; the full text (or `--file PATH`) as a UTF-8 `.md`
via `sendDocument`. `--summary` overrides the generated summary. Inbound
messages relay whole — the Bot API bounds them already.

## Away mode

`state/away` present = away. Away is the persisted single source (AC17):
survives poller and session restarts. Both CLI (`intercom away`) and phone
(`/away`, `/afk`) toggle the same file. Away ON escalates all currently
pending questions immediately, once each. Away ON means the intercom is
primary: session replies and updates push proactively (outbox drains every
cycle), and the main UI mirrors unchanged — the session transcript already
holds the exchange. Away OFF restores the default escalation timer.

## Security

- MUST read the token only from `~/.config/telegram/bot_token` (0600).
- MUST NOT place the token in process argv (visible via `ps`). Reach curl
  through a `-K -` stdin config (`url = "..."` line), not an argv URL.
- MUST NOT write the token to logs, spool files, error text, or transcripts.
- MUST fail closed: no allowlist processed means nothing is relayed and no
  artifacts are created (AC2).
- MUST NOT change Claude Code config, settings, hooks, or docker stacks
  (AC23). `/setup telegram` writes only the box-level state in § State layout.

## Verified vs assumed Bot API behavior

Verified on this box (2026-10-05): jq 1.8.1, curl 8.18.0 present; token file
`~/.config/telegram/bot_token` exists with mode 600; outbound HTTPS to
`api.telegram.org` from host shells works (every brainstorm relay call
succeeded). Sandbox-egress fear is disproven by that evidence.

Assumed and UNVERIFIED until `skills/intercom/probe.sh` passes against the
live bot: `getUpdates` `offset`/`timeout` long-poll semantics; `409 Conflict`
response shape on a second consumer; `sendMessage` 4096-char limit and
`parse_mode=HTML`; `createForumTopic` + `message_thread_id` routing on a
topics-enabled supergroup; `sendChatAction` `typing`; `sendDocument` upload
field name and limits; `429` carrying `retry_after`; server-side retention of
unconfirmed updates (relies on ≥24h retention — mitigated by at-least-once
delivery + operator notice if the gap exceeds it). Whether the operator's chat
has topics enabled is unknown — `probe.sh` checks it and `/setup telegram`
refuses to enable topics-dependent routing without it (walkie-talkie routing
degrades to plain-chat General delivery).

- MUST NOT ship code paths that depend on an unverified behavior above before
  `probe.sh` passes for that behavior.
- MUST NOT run `probe.sh` inside the hermetic test suites; it hits the live
  API by design and is operator-invoked only.

## `/setup telegram` and `/setup slack`

`/setup telegram` (CLI-only — secrets; `commands/setup.md` routes to
`skills/intercom/setup-telegram.sh`):

1. BotFather preamble, then token: if `~/.config/telegram/bot_token`
   exists with mode 600, offer reuse vs replace without printing the
   token (default reuse). Otherwise prompt (no echo) and write the file
   (0600) plus `mkdir -m 700 -p` the parent. Creation sets modes
   explicitly — no umask reliance, no looser-perms window — and
   `chmod 700` an already-existing parent (`mkdir -p` never tightens).
   Never instruct pasting the token into chat.
2. Validate via `getMe`. Failure → print the reason, write no state beyond
   the token file.
3. Pairing: instruct the operator to send any private message to the bot
   and wait. Do not wait for a piped Enter. One
   `getUpdates?timeout=30&offset=-1` long-poll (30s) captures the chat id,
   the pairing message's `message_thread_id` when present, and the initial
   offset (`max update_id + 1`) — satisfying AC22 startup validation. An
   empty queue after that wait exits 1 with no state beyond the token
   file. The pairing update is consumed by that offset; it is not written
   as an inbox record.
4. Write `config.json` (§ State layout), create the state dirs, and write
   `topics.json` / `seen.tsv`. When pairing captured a numeric
   `message_thread_id`, `topics.json` is
   `{"general":{"thread_id":<id>,"title":"General"}}` and setup calls
   `editForumTopic` with name `General` (fail-open if the API rejects).
   Otherwise `topics.json` is `{}`. `chmod 700` an already-existing
   `state/` directory (`mkdir -m 700 -p` does not tighten).
5. Print a token-free host-aware arming block (≤ 4 KiB) that invokes
   `watch.sh` every 30–60 s with the absolute plugin path baked in
   (§ Host adapter). The block MUST include both:
   - **Grok:** a silent watcher that runs bash-only `watch.sh` cycles and
     prints only per the wake grammar (empty stdout MUST NOT start a
     parent turn). MUST NOT use Grok `scheduler_create` for idle.
   - **Claude:** CronCreate only if that job injects zero parent turn when
     `watch.sh` stdout is empty (exit 0). Otherwise the same silent-watcher
     path. Claude CronCreate bash-only no-parent-turn is UNVERIFIED until
     proven on the host — CronCreate MUST NOT be the sole arming
     instruction.
   The block MUST NOT instruct copying or shipping
   `~/.grok/long-running-background-tasks/watch-intercom.sh`. Host crontab
   is forbidden. `commands/setup.md` telegram sub matches this contract.

`/setup slack` prints `Slack ships in v1.1/v2.` and exits 0 with zero state
writes (AC5). Transport abstraction in phase 1 is one funneled API-call
function plus a `transport` config field — no premature interface (the Slack
transport itself is v1.1/v2).

## Doctor

`skills/doctor/checks/intercom.sh` is WARN-never-FAIL (models.map precedent,
SPEC-037): jq/curl presence, token file mode, config.json parse, offset
numeric, stale heartbeat age.

## Phase-2 contract (documentation only — no phase-2 planning here)

The containerized daemon (phase-2 ticket) MUST: own the token and the sole
`getUpdates` consumer role (honor `state/poller.lock` and `state/offset`);
read and write the exact spool layout, record formats, and `config.json`
schema in § State layout; keep the `intercom.sh` verbs working unchanged
(daemon may take over the poller role behind them); preserve heartbeat,
escalation, away, topic, and dedupe semantics; and require zero repo changes
to migrate. Graduating poller → daemon changes no interface.

## MUST

- MUST ship `intercom.sh`, `poller.sh`, `watch.sh`, `setup-telegram.sh`,
  `common.sh` as pure-subprocess bash CLIs (bash + jq + curl + flock only
  in the poller/adapter cycle, AC21 / CDT-512-C1 AC1); `poller.sh`,
  `watch.sh`, and `intercom.sh` are never sourced.
- MUST keep `poller.sh` one-shot: one cycle per invocation, no resident
  `while`/`sleep`, no LLM, no CronCreate / `scheduler_create` inside the
  cycle.
- MUST arm the host job on `watch.sh` (not `poller.sh` directly). Idle
  paired cycles MUST write zero session-facing stdout. `watch.sh` MUST
  always exit 0.
- MUST print session-facing stdout only per § Host adapter (inbound wake
  or edge-triggered failure wake). Wake lines MUST follow the wake-line
  grammar; MUST NOT dump inbound text or the bot token.
- MUST persist failure-wake latch in `state/last_wake_exit` and inbox
  watermark in `state/inbox.stamp` under the state root.
- MUST keep all runtime state in § State layout paths; MUST NOT write state
  inside the repo (AC23).
- MUST guard `poller.sh` with a non-blocking lock: a second concurrent start
  exits 75 without state mutation or message loss (AC22).
- MUST validate `state/offset` (non-negative integer) before the first fetch;
  refuse to start otherwise (AC22).
- MUST process only allowlisted numeric chat ids; ignore everything else with
  zero artifacts (AC2).
- MUST advance the offset only after an update is processed, and keep the
  `seen.tsv` dedupe window (at-least-once delivery, update_id dedupe, AC12).
- MUST route by `thread_id` → sid, and general-topic traffic to
  `default_session` only (AC6). An unmapped thread id with an empty map
  or a map that contains only `general` MUST route to `default_session`.
  An unmapped thread id MUST stay fail-closed when any non-`general` sid
  exists.
- MUST ignore inbound whose `from.id` equals `getMe` bot id, and
  empty-text forum topic service messages, with zero inbox artifacts and
  without answering pending questions.
- MUST `chmod 700` an already-existing `state/` directory.
- MUST honor `concise_threshold` with the summary + single-file longread rule;
  MUST NOT chunk-split any outbound message (AC9).
- MUST send `sendChatAction` typing at least once per inbound pickup (AC10).
- MUST implement escalation as a timestamp sweep, once per pending question
  and cancelled by an answer (AC14).
- MUST keep away state in `state/away` only, togglable from CLI and phone;
  away ON escalates pending questions once, immediately (AC17).
- MUST auto-create missing session topics on first outbound or escalation
  (AC11) and queue messages with an `offline, queued` notice when the
  heartbeat was stale (AC12).
- MUST keep the token out of argv, logs, spool content, and error text (AC4).
- MUST make `/setup slack` a zero-write stub (AC5).
- MUST pass `bash -n`, skill-lint (SPEC-021), smoke (SPEC-030), and the
  hermetic suites with no network access.
- SHOULD keep the temp-path rule (`${TMPDIR:-/tmp}` or `mktemp`) in every
  executable block and script (AGENTS.md).

## MUST NOT

- MUST NOT run a resident daemon, loop, or host crontab entry in phase 1
  (harness-scheduled ephemeral cycles only).
- MUST NOT use Grok `scheduler_create` for idle Intercom cycles.
- MUST NOT instruct copying or shipping
  `~/.grok/long-running-background-tasks/watch-intercom.sh`. The plugin
  tree MUST NOT contain `watch-intercom.sh`. Optional wrapper lives under
  `skills/intercom/` only.
- MUST NOT make CronCreate the sole arming instruction.
- MUST NOT add a new slash Surface for this adapter (patch; no new
  `commands/*.md`).
- MUST NOT pass the bot token via `watch.sh` argv or env, and MUST NOT
  copy poller stderr onto adapter stdout.
- MUST NOT spawn a second `getUpdates` consumer for the same token.
- MUST NOT relay non-allowlisted traffic or anything during unpaired
  operation. The reserved `/away`/`/afk` (§ Poller cycle) are the only
  intercepted commands: every other inbound text — including other
  slash-prefixed text, such as commands addressed to other bots — is session
  content that MUST reach the session spool as a normal message and MUST NOT
  be treated as an intercom-internal operation.
- MUST NOT write the token into any file except `~/.config/telegram/bot_token`.
- MUST NOT modify Claude Code config, docker stacks, or repo-tracked state at
  runtime.
- MUST NOT introduce a runtime beyond bash/jq/curl (AC21).

## Alternatives considered

- **Marketplace telegram plugin (Option B)** — rejected: session-coupled;
  per-session MCP pollers recreate the multi-consumer `getUpdates` loss; the
  timers, away flags, and topic map would still need building.
- **File-based only, no poller (Option C)** — rejected as the end state; kept
  as this phase's mechanism.
- **Telegraph/third-party longreads** — rejected per resolved design: the
  rich artifact is a `sendDocument` upload, no third-party service.
- **Host crontab** — rejected: host machine safeguard (no bare-metal
  daemons/cron ownership) and resolved design prefers harness scheduling.
- **Grok `scheduler_create` on idle** — rejected: that path spawned an
  LLM and injected a parent turn every cycle (CDT-512-C1).
- **Ship `~/.grok/long-running-background-tasks/watch-intercom.sh`** —
  rejected: local workaround (resident loop, hardcoded chat id, inbound
  body dump). Product adapter is `skills/intercom/watch.sh`.

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h).

### CDT-501

- **AC1.** `/setup telegram` is CLI-only: it writes the token file at
  `~/.config/telegram/bot_token` with mode 600 (and a 700 parent), state under
  `~/.claude/telegram-router/`, and nothing inside the repo; `stat` shows 600
  and `git status --porcelain` stays clean inside a temp repo checkout.
  Verify: bash skills/intercom/test.sh
- **AC2.** Fail-closed ingress: nothing outside the paired allowlist is ever
  relayed or recorded.
  - **a.** An unpaired bot (no `config.json` members) silently ignores all
    inbound messages: zero spool, topic, or state artifacts after a full
    poller cycle over unpaired updates.
  - **b.** A chat id absent from `config.json` `members` (and any
    non-numeric key) is ignored with zero artifacts while an allowlisted id
    on the same cycle relays normally.
  Verify: bash skills/intercom/test.sh
- **AC4.** The token value never appears in transcripts, logs, spool files,
  error text, or process argv: with a sentinel token, a full poller cycle
  leaves no sentinel in any written file, and the poller's `curl` invocation
  carries the token via stdin config, not argv (shim asserts its argv is
  token-free).
  Verify: bash skills/intercom/test.sh
- **AC5.** `/setup slack` prints `Slack ships in v1.1/v2.` and exits 0 with
  zero state writes (no token, config, or spool artifacts).
  Verify: bash skills/intercom/test.sh
- **AC6.** Thread-mapped routing with no cross-delivery: the general
  (walkie-talkie) topic and each session topic deliver to exactly one sid.
  - **a.** A message sent in a session's topic lands in that session's spool
    inbox as one JSON record within one poll cycle.
  - **b.** With ≥ 2 sessions receiving traffic in one cycle, each update
    lands only in its thread-mapped sid's inbox, and no other sid's inbox
    changes.
  - **c.** General (walkie-talkie) topic messages reach the designated
    default session, and that session's replies return to the general topic.
  Verify: bash skills/intercom/test.sh
- **AC9.** An outbound above `concise_threshold` (default 1024) produces
  exactly one concise summary `sendMessage` and one `sendDocument` file
  artifact — never two+ text messages, never 4096-char chunk-splitting; at or
  below the threshold it is one `sendMessage` and no file.
  Verify: bash skills/intercom/test.sh
- **AC10.** Each inbound pickup sends `sendChatAction` `typing` at least once
  (shim records the call).
  Verify: bash skills/intercom/test.sh
- **AC11.** An outbound notification for a sid with no prior inbound and no
  topic record lands in an auto-created topic (recorded in `topics.json`) or
  the general topic when topics are unavailable.
  Verify: bash skills/intercom/test.sh
- **AC12.** Durability and queueing across poller restarts.
  - **a.** Queue-when-offline: with a stale heartbeat, inbound messages are
    queued into spool inboxes and an `offline, queued` notice is sent to the
    topic on the resuming cycle; queued records are delivered to the session.
  - **b.** Restart durability: killing the poller mid-traffic and restarting
    reprocesses no delivered `update_id` (seen window + offset), relays
    updates sent while down, dedupes any re-delivered update, and spool
    contents survive.
  Verify: bash skills/intercom/test-poller.sh
- **AC14.** Escalation is a timestamp sweep, once per pending question.
  - **a.** A pending question unanswered for `escalation_timeout_s` (default
    900) appears exactly once in that session's intercom topic, and never
    re-fires afterwards.
  - **b.** A timer that expires while the poller is down fires on the next
    poll cycle.
  - **c.** Answering an escalated question cancels further escalation and
    relays the answer into the session spool as `kind: "answer"`.
  Verify: bash skills/intercom/test-poller.sh
- **AC17.** Away mode: one persisted flag, togglable from CLI and phone,
  making the intercom the primary channel.
  - **a.** `/away` and `/afk` toggle from both the CLI (`intercom away`) and
    the phone (reserved inbound commands), writing the same `state/away`
    persisted flag; phone commands are relayed nowhere.
  - **b.** Away ON makes the intercom primary: session outbox
    replies/updates drain proactively every cycle and the main UI side is
    unchanged (the session's own transcript holds the exchange; no tool
    output required).
  - **c.** Away ON escalates all currently pending questions immediately,
    once each; OFF restores the default timer sweep.
  - **d.** Away state survives poller and session restart: the file persists
    and both toggle paths agree on one state after restarts.
  Verify: bash skills/intercom/test-poller.sh
- **AC21.** Phase-1 executable code uses only bash, jq, and curl: every
  `skills/intercom/*.sh` shebang is `#!/usr/bin/env bash`, no interpreter
  other than bash is invoked anywhere in the skill's scripts or fences, and
  `jq`/`curl` absence produces an actionable error message instead of a
  stack trace.
  Verify: bash skills/intercom/test.sh
- **AC22.** Exactly one `getUpdates` consumer per token: a second concurrent
  poller start exits 75 with no state mutation or loss; startup validates the
  persisted offset (numeric, present) and refuses to fetch otherwise; a
  `409` response exits 4 without advancing the offset.
  Verify: bash skills/intercom/test-poller.sh
- **AC23.** Runtime state is box-level only and the repo carries code only:
  with `INTERCOM_STATE_ROOT` pointed at a temp dir, a full setup + cycle
  creates nothing under the repo, and existing docker stacks and Claude Code
  config are untouched.
  Verify: bash skills/intercom/test.sh
- **AC24.** The interface contract — spool layout, `ask|send|away` verbs,
  heartbeat file, pending-question format, state paths, poll cadence — is
  documented in this spec (§ State layout, § CLI verbs, § Poller cycle) and
  is the phase-2 daemon contract (§ Phase-2 contract).
- **AC25.** v1 configures exactly one member while the config shape is an
  object keyed by chat id that tolerates more members later: the schema
  parses a two-member fixture and processes both, and the shipped default
  writes exactly one.
  Verify: bash skills/intercom/test.sh
- **AC26.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint
  (SPEC-021), smoke (SPEC-030), and docs-drift pass; the release bump for the
  new `/away` and `/afk` surfaces is minor.

### CDT-512-C1

- **AC1.** `poller.sh` and any plugin-owned arming wrapper (`watch.sh`)
  are `#!/usr/bin/env bash` subprocess CLIs. Cycle tools: bash, jq, curl,
  flock only. No LLM, no other interpreter, no `scheduler_create` /
  CronCreate inside the cycle. One cycle per invocation; no resident
  `while`/`sleep` in `poller.sh` or `watch.sh` (daemon = CDT-509).
  Verify: bash skills/intercom/test.sh
- **AC2.** Paired Intercom (`config.json` has ≥1 member) and a cycle that
  writes zero `spool/*/inbox/*.json`: `state/heartbeat` mtime advances;
  `state/offset` changes only under existing SPEC-038 offset rules (idle
  with no processed updates: unchanged); armed host job stdout is empty;
  adapter does not copy poller stderr onto stdout. Unpaired (no members):
  SPEC-038 AC2 unchanged — exit 0, no heartbeat, no fetch.
  Verify: bash skills/intercom/test-poller.sh
- **AC3.** Armed host job prints session-facing stdout iff: (inbound)
  this cycle wrote ≥1 new `spool/<sid>/inbox/*.json` for an allowlisted
  member message (Walkie-talkie or session topic), or (failure)
  `poller.sh` exit ∉ {0, 75}. Silent: phone `/away`/`/afk` (no inbox
  record), outbox drain, Escalation sweep, ignored update types, 429 with
  exit 0, getUpdates transport failure with exit 0, lock-held 75. Wake
  line is token-free; names each affected sid; pointer to inbox path(s);
  MUST NOT dump inbound text; MUST NOT print or pass the bot token.
  Grammar: `intercom: inbound sid=<sid>[,<sid>...] path=<abs-inbox> [...]`
  and `intercom: poller exit <n>`.
  Verify: bash skills/intercom/test-poller.sh
- **AC4.** A repeating identical non-{0,75} exit MUST NOT inject a parent
  turn every 30–60s. First failure wakes; same exit stays silent until a
  0/75 cycle or a different exit. Inbound wake fires every cycle that
  wrote new inbox records.
  Verify: bash skills/intercom/test-poller.sh
- **AC5.** `setup-telegram.sh` prints a token-free arming block (≤ 4 KiB,
  absolute `watch.sh` path, cadence 30–60s) that includes both: Grok
  silent watcher that runs bash-only cycles and prints only per AC3/AC4;
  Claude CronCreate only if that job injects zero parent turn on empty
  stdout (exit 0), otherwise the same silent-watcher path. CronCreate
  MUST NOT be the sole arming instruction. Block MUST NOT instruct
  copying or shipping `~/.grok/long-running-background-tasks/watch-intercom.sh`.
  `commands/setup.md` telegram sub + this spec § Setup match.
  Verify: bash skills/intercom/test.sh
- **AC6.** Sentinel token absent from poller stdout/stderr, adapter
  stdout, setup arming block, and any new plugin file. Adapter MUST NOT
  pass the token via argv or env.
  Verify: bash skills/intercom/test.sh
- **AC7.** Plugin tree has no `watch-intercom.sh` and ships nothing under
  `~/.grok/long-running-background-tasks/`. Optional wrapper lives under
  `skills/intercom/` only (`watch.sh`).
  Verify: bash skills/intercom/test.sh
- **AC8.** This spec § Poller cycle / § Host adapter / § Setup: harness
  re-invocation (Claude CronCreate or Grok silent watcher) is the phase-1
  scheduler; `poller.sh` stays one-shot; idle injects no parent turn.
  CDT-501 ACs still pass. No new slash Surface.
  Verify: bash skills/intercom/test.sh
- **AC9.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint
  (SPEC-021), smoke (SPEC-030), and docs-drift pass; release bump is
  patch (no new `commands/*.md`).

### CDT-512-C2

- **AC1.** `/setup telegram` MUST NOT default Member name to a personal
  name. Empty input uses `$USER` when set; if `$USER` is empty, the
  script MUST refuse and write no Intercom state.
  Verify: bash skills/intercom/test.sh
- **AC2.** Before the token prompt, stderr MUST print a BotFather
  preamble: create your own bot; never share the token; never paste the
  token in chat. The token MUST NOT appear in setup stdout/stderr.
  Verify: bash skills/intercom/test.sh
- **AC3.** `commands/setup.md` telegram agent rules: do not suggest a
  shared bot username from memory; do not default the member name to a
  person; if a token file exists, ask reuse vs replace.
  Verify: bash skills/intercom/test.sh
- **AC4.** `docs/runbooks/setup-telegram.md` exists. README points at it
  with one line. Bot API has no read receipts (platform limit).
  Verify: bash skills/intercom/test.sh
- **AC5.** [process] docs-drift and cmd-index stay green (SPEC-010).
  Verify: bash skills/docs-drift/check-docs-drift.sh
- **AC6.** Setup guides enabling Topics when the operator wants sid per
  topic (Bot API 9.3+ private bot topics / forum).
  Verify: bash skills/intercom/test.sh
- **AC7.** `getChat.is_forum=false` is not an error. Topics off is a
  supported single General window (walkie-talkie only).
  Verify: bash skills/intercom/test.sh
- **AC8.** The runbook documents both modes: topics on = sid per topic;
  topics off = one General.
  Verify: bash skills/intercom/test.sh
- **AC9.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint,
  smoke, and docs-drift pass; release bump is patch (no new
  `commands/*.md`). C1 host adapter (`watch.sh`) MUST NOT regress.

### CDT-512-C3

- **AC1.** When the captured private-chat pairing update has a numeric
  `message_thread_id`, `/setup telegram` writes `topics.json` as
  `{"general":{"thread_id":<id>,"title":"General"}}`. When that field is
  absent, `topics.json` is `{}` and pairing still succeeds. Chat id and
  initial offset stay as today. The pairing update is not an inbox record.
  Verify: bash skills/intercom/test.sh
- **AC2.** When AC1 stored a general `thread_id`, setup calls
  `editForumTopic` for that chat/thread with name `General` (including
  `getChat.is_forum=false`). Pairing MUST succeed if the call fails or is
  skipped. Skip the call when no `thread_id`. The bot token MUST NOT be
  printed.
  Verify: bash skills/intercom/test.sh
- **AC3.** An allowlisted member `message` with a numeric
  `message_thread_id` absent from `topics.json` MUST write one inbox
  record on `config.json` `default_session` when `topics.json` is `{}`
  **or** contains only the `general` key. Offset advances. Typing still
  fires (AC10). This MUST work on an already-paired Intercom with empty
  `topics.json`. `topics_enabled` is not an inbound routing switch.
  Verify: bash skills/intercom/test.sh
- **AC4.** When `topics.json` has any key other than `general`, an
  unmapped `message_thread_id` is ignored with zero artifacts (no inbox,
  no pending→answered, no typing). Offset still advances. AC6
  cross-delivery with session sids still holds.
  Verify: bash skills/intercom/test.sh
- **AC5.** The poller ignores an allowlisted-chat update whose `from_id`
  equals the bot's `getMe` numeric id. Zero inbox, zero pending→answered,
  no typing, offset advances. `watch.sh` session-facing stdout is empty
  for a cycle that consumed only these updates. MUST apply without
  re-setup.
  Verify: bash skills/intercom/test.sh
- **AC6.** A `message` update with empty `text` and empty `caption` that
  carries `forum_topic_edited` (same for `forum_topic_created` /
  `forum_topic_closed` / `forum_topic_reopened`) produces zero inbox
  records and does not move pending→answered. Offset advances. Member
  non-empty text still relays and still answers pending.
  Verify: bash skills/intercom/test.sh
- **AC7.** Setup `chmod 700`s an already-existing `state/` directory.
  New `state/` stays 700. `mkdir -m 700 -p` alone is not enough.
  Verify: bash skills/intercom/test.sh
- **AC8.** `topics_enabled=false` remains a supported single General
  Walkie-talkie window (CDT-512-C2 AC7). `is_forum=false` is not a failed
  setup. Inbound with `message_thread_id` in that mode MUST deliver per
  AC3. C2 BotFather preamble and topics-on/off copy stay intact.
  Verify: bash skills/intercom/test.sh
- **AC9.** [process] Hermetic suites cover pairing seed, unmapped relay,
  bot-id ignore, and `state/` 700. `bash tools/run-all-tests.sh` exit 0;
  skill-lint, smoke, docs-drift pass. CDT-512-C1 `watch.sh` ACs pass.
  CDT-512-C2 preamble ACs pass. Patch bump; no new `commands/*.md`.
  Never print the bot token. Never commit `.claude/backlog` or
  `.claude/epics`.

### CDT-512-C4

- **AC1.** When `~/.config/telegram/bot_token` exists with mode 600,
  `setup-telegram.sh` offers reuse vs replace. Reuse does not print the
  token and does not overwrite the file. Default is reuse (`Y` / empty /
  EOF). `n` / `replace` prompts for a new token (no echo) and writes it
  0600. Never print the token.
  Verify: bash skills/intercom/test.sh
- **AC2.** Pairing prints a wait (send any private message, long-poll
  30s) and runs `getUpdates?timeout=30&offset=-1` without a piped Enter.
  An empty queue after that wait exits 1 with no Intercom state beyond
  the token file. The wait copy MUST NOT say Press Enter.
  Verify: bash skills/intercom/test.sh
- **AC3.** Setup copy MUST NOT instruct pasting the token into chat.
  "Never paste the token into chat" stays in the BotFather preamble and
  in `commands/setup.md`.
  Verify: bash skills/intercom/test.sh
- **AC4.** `commands/setup.md` telegram agent rules document the agent
  pairing wait: do not pipe Enter before the member DMs the bot; the
  wait is a 30s long-poll.
  Verify: bash skills/intercom/test.sh
- **AC5.** [process] `bash tools/run-all-tests.sh` exit 0; skill-lint,
  smoke, docs-drift pass. CDT-512-C1 `watch.sh` ACs pass. CDT-512-C2
  preamble ACs pass. CDT-512-C3 pairing-seed ACs pass. Patch bump; no
  new `commands/*.md`. Never print the bot token. Never commit
  `.claude/backlog` or `.claude/epics`.

## Test

- [ ] Token file written 0600 with 700 parent; repo stays clean (AC1)
- [ ] Unpaired cycle creates zero artifacts; non-allowlisted id ignored
      with zero artifacts beside a normal relay (AC2)
- [ ] Token sentinel absent from every written file and from curl argv (AC4)
- [ ] `/setup slack` zero-write stub (AC5)
- [ ] Thread-mapped delivery, no cross-delivery with two sids; General
      routes to the default session and replies return to General (AC6)
- [ ] Summary + single-file longread above threshold; single message below (AC9)
- [ ] sendChatAction once per pickup (AC10)
- [ ] Topic auto-create on first outbound/escalation (AC11)
- [ ] Stale heartbeat: queue + offline notice on resume; kill/restart with no
      reprocessed update_id, backlog relayed, dedupe holds (AC12)
- [ ] Escalation once per pending question; fires when expired while down;
      answer cancels and relays as `answer` (AC14)
- [ ] Away toggle from CLI and phone on one persisted flag; away ON drains
      proactively and escalates pending once; OFF restores timer (AC17)
- [ ] bash/jq/curl only; graceful jq/curl absence message (AC21)
- [ ] Second poller exits 75, mutates nothing; invalid offset refuses; 409 exits 4 (AC22)
- [ ] `INTERCOM_STATE_ROOT` reroute keeps the repo untouched (AC23)
- [ ] Two-member config fixture parses and processes; default ships one member (AC25)
- [ ] `watch.sh` and `poller.sh` are one-shot bash; shebang/interpreter scan
      covers the wrapper; no resident loop (CDT-512-C1 AC1)
- [ ] Paired idle: heartbeat mtime advances, offset unchanged, adapter
      stdout empty; unpaired: no heartbeat, no fetch (CDT-512-C1 AC2)
- [ ] Session-facing stdout only on new allowlisted inbox or poller
      exit ∉ {0,75}; wake grammar token-free with sid + inbox path
      (CDT-512-C1 AC3)
- [ ] Failure wake edge-triggered; inbound wake every new-inbox cycle
      (CDT-512-C1 AC4)
- [ ] Setup arming block ≤ 4 KiB, absolute `watch.sh`, Grok silent
      watcher + Claude CronCreate-if-zero-parent-turn; CronCreate not sole
      (CDT-512-C1 AC5)
- [ ] Sentinel absent from poller/adapter/setup paths; adapter does not
      pass the token (CDT-512-C1 AC6)
- [ ] No `watch-intercom.sh` in the plugin tree; nothing shipped under
      `~/.grok/long-running-background-tasks/` (CDT-512-C1 AC7)
- [ ] Member name defaults to `$USER`, never a personal name; empty USER
      requires a name (CDT-512-C2 AC1)
- [ ] Pairing with `message_thread_id` seeds `topics.json` general and
      calls `editForumTopic`; without it writes `{}` (CDT-512-C3 AC1/AC2)
- [ ] Unmapped thread + empty or only-general map relays to
      `default_session`; session-topic map stays fail-closed (CDT-512-C3 AC3/AC4)
- [ ] Bot `from_id` and empty-text forum service messages create zero
      inbox and do not answer pending (CDT-512-C3 AC5/AC6)
- [ ] Existing `state/` dir is chmod 700 (CDT-512-C3 AC7)
- [ ] BotFather preamble before the token prompt; token never printed
      (CDT-512-C2 AC2)
- [ ] `commands/setup.md` agent rules: no shared bot from memory (CDT-512-C2 AC3)
- [ ] Operator runbook + README pointer; no Bot API read receipts
      (CDT-512-C2 AC4/AC8)
- [ ] Topics on/off both supported; `is_forum=false` is not an error
      (CDT-512-C2 AC6/AC7)
- [ ] Mode-600 `bot_token` reuse vs replace; reuse never prints the token
      (CDT-512-C4 AC1)
- [ ] Pairing long-polls 30s without a piped Enter; empty queue exits 1
      with no state beyond the token file (CDT-512-C4 AC2)
- [ ] Setup never instructs pasting the token into chat (CDT-512-C4 AC3)
- [ ] `commands/setup.md` documents the agent pairing wait (CDT-512-C4 AC4)

## Validation

- [ ] Spec reviewed against CDT-501 ACs 1–25 (PM final, 2026-10-05) and the
      2026-10-03 brainstorm decision log
- [ ] `probe.sh` passes every § Verified vs assumed behavior before
      dependent code merges
- [ ] Hermetic suites green with no network; `tools/run-all-tests.sh` exit 0
- [ ] skill-lint, smoke, docs-drift clean; spec-lint covers findings cleared
      when T2–T8 land the covered paths
- [ ] Release bump minor (new `/away`, `/afk` surfaces)

## Version History

| Date | Change |
|------|--------|
| 2026-10-05 | CDT-501 — initial ACTIVE spec: spool protocol, `intercom` CLI, poller cycle, escalation, away, longread, `/setup telegram`/`slack`, doctor check, phase-2 contract |
| 2026-10-05 | CDT-501 — command-relay clarification (only `/away`/`/afk` are intercepted; other slash text relays) and AC consolidation to the M14 budget: 2+3→2, 6+7+8→6, 12+13→12, 14+15+16→14, 17+18+19+20→17 |
| 2026-10-07 | CDT-512-C1 — host adapter `watch.sh`: poller stays one-shot; idle injects no parent turn; host-aware arming (Grok silent watcher + Claude CronCreate-if-zero-parent-turn); wake-line grammar; edge-triggered failure wake |
| 2026-10-07 | CDT-512-C2 — per-dev bot setup: `$USER` member default, BotFather preamble, operator runbook, topics on/off both supported |
| 2026-10-07 | CDT-512-C3 — pairing seeds General `thread_id`; unmapped empty/only-general map routes to `default_session`; poller ignores bot self-echo and forum service messages; chmod 700 existing `state/` |
| 2026-10-07 | CDT-512-C4 — TTY-less `/setup telegram`: mode-600 `bot_token` reuse vs replace; pairing long-polls 30s with no Enter wait |

## Cross-references

- SPEC-021 — skill-bash lint gate (all `skills/intercom/*.sh` + fences)
- SPEC-030 — smoke harness + hermetic test conventions
- SPEC-031 — escalation gate (implementation-capable skills)
- SPEC-016 — worktree isolation (`.worktrees/CDT-501`)
- SPEC-010 — docs-drift + version pair at `/release`
- `docs/runbooks/scheduled-retro.md` — harness cron prompt pattern (ci-watch)
- `docs/internal/permission-posture-matrix.md` — sandbox egress evidence
