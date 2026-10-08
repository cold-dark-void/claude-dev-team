# SPEC-038: Intercom Spool Protocol

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-05
**Covers**: `skills/intercom/` (`SKILL.md`, `common.sh`, `intercom.sh`, `poller.sh`, `watch.sh`, `daemon.sh`, `start-daemon.sh`, `docker-compose.yml`, `Dockerfile`, `setup-telegram.sh`, `probe.sh`, `test.sh`, `test-poller.sh`, `test-daemon.sh`), `commands/away.md`, `commands/afk.md`, `commands/setup.md` (`telegram` and `slack` subs), `skills/doctor/checks/intercom.sh`, `docs/runbooks/setup-telegram.md`, `README.md`

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
no parent turn (CDT-512-C1). Zero new **host** runtimes — bash, jq, curl, and
flock only (CDT-501 AC21, CDT-512-C1 AC1). Phase 2 (CDT-509) is a
containerized daemon that owns `getUpdates` 24/7. It MUST keep this spool
interface (§ Phase-2 contract). The host stays clean: no new bare-metal
runtime, no host crontab, no unofficial image pull.

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
  No network. The record carries `route: {sid, thread_id}` in the single
  atomic creation write: `sid` is the resolved asking session (always
  non-empty); `thread_id` is a best-effort `topics.json` lookup for that
  sid, `null` when unmapped (the poller back-fills it on the escalated
  send). A topics.json lookup failure never yields a route-less record
  (CDT-529 AC4/AC6/Q5). The poller escalates it (§ Escalation).
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
   - otherwise resolve sid (CDT-529 resolution order; first hit wins):
     (a) no `thread_id` (plain chat) → `default_session` (walkie-talkie;
     CDT-512-C3). When any non-`default` sid has an unanswered pending
     question, one stderr warn names the correlation miss (CDT-529 Q3) —
     plain chat is never re-routed to a session.
     (b) `thread_id` mapped to a sid whose `spool/<sid>/pending/` holds ≥1
     unanswered question (an *active* session) → that sid (CDT-529 AC1).
     (c) `thread_id` unmapped, or mapped to a sid with no unanswered
     pending (no longer active; CDT-529 AC5): exactly one active session
     → that sid (CDT-529 AC2); zero or ≥2 active sessions →
     `default_session` plus one stderr warn line naming the unmapped
     thread id (CDT-529 AC3). This supersedes the CDT-512-C3
     zero-artifacts ignore for unmapped thread ids: unmapped traffic is
     never silently dropped, and cross-delivery to a non-default sid other
     than the single active one cannot occur. Write an inbox record. Any other
     slash-prefixed text (commands addressed to other bots, or any other
     `/`-leading message) is session content and relays as a normal message —
     the reserved pair above is the only intercepted command (§ MUST NOT).
     Pickup MUST NOT send `sendChatAction` (AC10). If `was_stale`, also send an
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
`escalated_at`. When the send succeeds through a created or resolved topic,
the sweep also back-fills the record's `route.thread_id` in the same
rewrite (CDT-529 AC4/AC6). An escalated question never re-fires (AC14).
Answering it —
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
or contains only `general`. CDT-529 supersedes the fail-closed ignore for
unmapped thread ids: an unmapped thread id (or a thread whose mapped sid is
no longer active) routes to the single *active* session when exactly one
exists, else to `default_session` with one warn line naming the thread id
(§ Poller cycle; CDT-529 AC2/AC3/AC5). An active session is one whose
`spool/<sid>/pending/` holds ≥1 unanswered question — the definition of
"currently orchestrating" (CDT-529 Q1). `topics_enabled` is a setup
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
  other than compose project `intercom` (AC23 / CDT-527). `/setup telegram`
  writes box-level state in § State layout and MAY inspect or start project
  `intercom` only. MUST NOT mutate any other compose project or stack.

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
5. Print a token-free host-aware block (≤ 4 KiB). Mode selection is
   CDT-527 (identity running or post-`up`, heartbeat optional) — not
   CDT-509 AC10's heartbeat conjunct. When Docker is unavailable or the
   operator answers `n`, print the CDT-512-C1 `watch.sh` arming block
   that invokes `watch.sh` every 30–60 s with the absolute plugin path
   baked in (§ Host adapter). That C1 block MUST include both:
   - **Grok:** a silent watcher that runs bash-only `watch.sh` cycles and
     prints only per the wake grammar (empty stdout MUST NOT start a
     parent turn). MUST NOT use Grok `scheduler_create` for idle.
   - **Claude:** CronCreate only if that job injects zero parent turn when
     `watch.sh` stdout is empty (exit 0). Otherwise the same silent-watcher
     path. Claude CronCreate bash-only no-parent-turn is UNVERIFIED until
     proven on the host — CronCreate MUST NOT be the sole arming
     instruction.
   Daemon mode replaces that block: the daemon is the sole `getUpdates`
   consumer; do not arm `watch.sh`. The block MUST NOT instruct copying
   or shipping `~/.grok/long-running-background-tasks/watch-intercom.sh`.
   Host crontab is forbidden. `commands/setup.md` telegram sub forwards
   remaining args (including `--start-daemon`) and matches this contract.

`/setup slack` prints `Slack ships in v1.1/v2.` and exits 0 with zero state
writes (AC5). Transport abstraction in phase 1 is one funneled API-call
function plus a `transport` config field — no premature interface (the Slack
transport itself is v1.1/v2).

## Doctor

`skills/doctor/checks/intercom.sh` is WARN-never-FAIL (models.map precedent,
SPEC-037): jq/curl presence, token file mode, config.json parse, offset
numeric, stale heartbeat age. Stale heartbeat already covers a down
daemon. Doctor MUST NOT FAIL when docker is absent. Heartbeat WARN copy names daemon-or-harness.
A daemon-running check (compose project `intercom` + heartbeat freshness)
is informational PASS/WARN, never FAIL.

## Phase-2 contract (CDT-509 — normative)

The containerized daemon replaces harness-scheduled `getUpdates` for 24/7
coverage. Zero live sessions MUST still land allowlisted inbound in the
session spool within one long-poll return (`poll_timeout_s`, default 30).

**Spool interface (load-bearing).** The daemon MUST read and write the exact
§ State layout, record shapes, pending-question format, `config.json` schema
1, heartbeat, offset, `seen.tsv`, `state/away`, and `state/poller.lock`.
`intercom.sh` verbs `ask|send|away` MUST keep working unchanged. Additive
files and extra JSON keys are allowed. Breaking or renaming those paths is
not. Schema stays 1. Phase-1 `poller.sh` and `watch.sh` stay one-shot and
MUST keep passing CDT-501 / CDT-512 when the daemon is absent.

**Token and volumes.** The daemon owns the bot token. It MUST mount
`~/.config/telegram/bot_token` (mode 600) read-only. It MUST bind-mount
`~/.claude/telegram-router/` (tests: `INTERCOM_STATE_ROOT`). It MUST NOT copy
the token into the image, env, argv, logs, or spool. The container MUST NOT
write the token file.

**Sole consumer.** `poller.sh` remains the only process that takes
`state/poller.lock` (`flock -n`). The daemon entrypoint MUST NOT hold that
lock across cycles (a held lock would make the next `poller.sh` exit 75
forever). A second start (host `watch.sh`/`poller.sh`, a second container,
or probe while a cycle holds the lock) MUST exit 75 with no state mutation,
or surface `409` as exit 4 without advancing offset (AC22). `/setup telegram`
MUST NOT arm `watch.sh` as a second consumer when the daemon is running.

**Loop placement.** The resident loop is `skills/intercom/daemon.sh` (container
entrypoint / compose `command`). Each iteration invokes `poller.sh` once and
MUST NOT rewrite the spool cycle. `poller.sh` and `watch.sh` MUST NOT gain a
`while`/`sleep` loop. Host crontab is still forbidden. Host machine
safeguard: no new bare-metal runtime. Cycle tools inside the container stay
bash, jq, curl, and flock (`apk add` `util-linux` on Alpine so `flock` is
not BusyBox — BusyBox `flock -n` is UNVERIFIED). Fast `poller.sh` exit 0
(unpaired, transport fail) MUST backoff; a long-poll success may re-invoke
immediately. Exit 2 terminates the loop. Exit 75/4/other nonzero backoff and
continue.

**Semantics preserved.** Topic map (`topics.json`) is the session registry.
Walkie-talkie, fail-closed unmapped, auto-create, Escalation timestamp
sweep, Away mode, longread, send-path typing (AC10 / CDT-512-C5), allowlist,
and restart durability (volume state) MUST match phase 1. The daemon MUST
NOT add a typing-keepalive loop.

**Image and probe.** The shipped compose/Dockerfile MUST pin a Docker
Official Image by digest (not `:latest`). The runbook MUST present the
candidate (source, digest, root vs non-root). The CDT-509 alpine digest is
approved. TTY-less default Y on `/setup telegram` (pairing and
keep-existing) is the pull approval for that digest; `--start-daemon` is
the same approval (flag is the confirm, no Y prompt). MUST NOT pull an
unapproved or unpinned image. Hermetic suites MUST NOT `docker pull` or
`docker run` a real image. `probe.sh` is the operator pre-deploy gate.
Suites, `start-daemon.sh`, and `/setup telegram` MUST NOT invoke it
(CDT-527 AC8; supersedes CDT-509 AC12 for the automated start path). Stop
the daemon before probe (a second `getUpdates` consumer 409s).

**Setup.** Docker is available iff `ir_docker_available`: `command -v
docker`, `docker compose version`, `docker info` (inspect only; never
pull, run, or print the token). First miss names the check: `docker CLI`,
`compose v2`, or `engine`. `/setup telegram` after pairing and on
keep-existing:

- Not available → CDT-512-C1 `watch.sh` arming plus one token-free line
  naming the first failed check; exit 0. Missing Docker is not a setup
  failure.
- Available and identity running (compose project `intercom`, service
  `daemon`, label `dev-team.intercom=daemon`) → daemon mode; do not arm
  `watch.sh`; do not start a second consumer. Heartbeat MAY be empty or
  stale (CDT-527 AC3; supersedes CDT-509 AC10 heartbeat conjunct for
  setup mode). `ir_daemon_running` (heartbeat AND compose) stays the
  doctor liveness check and is NOT the setup-mode predicate. Setup uses
  `ir_daemon_identity_running` (compose/label only).
- Available and identity down → prompt to start. TTY-less default Y
  (empty, `Y`/`y`/`yes`, EOF) invokes `skills/intercom/start-daemon.sh`.
  Answer `n`/`N`/`no` keeps C1 and MUST NOT start. After `up` returns 0,
  print daemon mode even if `state/heartbeat` is empty or stale. Host
  uid 0 or compose `up` failure on pairing/keep-existing: refuse line
  plus C1, exit 0. Held `state/poller.lock`: `start-daemon.sh` exits 75
  (stop host `watch.sh` first); setup MUST NOT print C1 on that path.

`--start-daemon` is for an already-paired box (`config.json` has ≥1
member and the token file exists). The flag is the confirm (no Y
prompt). Unpaired: fail closed, no start, nonzero. Already running:
daemon mode, exit 0, no second consumer. uid 0 or `up` failure on this
flag: nonzero, no C1. `commands/setup.md` forwards remaining args to
`setup-telegram.sh`. Blocks stay token-free and ≤ 4 KiB. First-time
start is no longer runbook-only.

**Compose identity (locked).** Project name `intercom`. Service `daemon`.
Label `dev-team.intercom=daemon`. Setup and doctor detect that label or
`docker compose -p intercom`. No inbound published ports. Runtime user is
not uid 0. Numeric uid MUST be able to read the 0600 token (same host owner).

**Out of scope (CDT-509).** Slack, voice notes, group chats, v1.1 quick
commands. Open-session parent-turn wake through `watch.sh` stdout while the
daemon holds the lock (spool is the 24/7 relay; the next session turn reads
inbox). Host crontab. Unofficial images. Typing keepalive. No new slash
Surface (`commands/*.md`).

## MUST

- MUST ship `intercom.sh`, `poller.sh`, `watch.sh`, `setup-telegram.sh`,
  `start-daemon.sh`, `common.sh` as pure-subprocess bash CLIs (bash + jq
  + curl + flock only in the poller/adapter cycle, AC21 / CDT-512-C1
  AC1); `poller.sh`, `watch.sh`, `intercom.sh`, and `start-daemon.sh` are
  never sourced.
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
  or a map that contains only `general` MUST route per the CDT-529
  resolution order (§ Poller cycle): the single active session when
  exactly one exists, else `default_session` plus one warn line naming
  the thread id. Plain chat (no `thread_id`) MUST always route to
  `default_session` (CDT-529 Q3); the zero-artifacts ignore for unmapped
  thread ids is superseded (CDT-529 AC3/AC5).
- MUST write every pending-question record's `route` fields
  (`sid`, `thread_id`) in the single atomic creation write; `route.sid`
  MUST be present and non-empty even when the `topics.json` lookup fails
  (CDT-529 AC6).
- MUST ignore inbound whose `from.id` equals `getMe` bot id, and
  empty-text forum topic service messages, with zero inbox artifacts and
  without answering pending questions.
- MUST `chmod 700` an already-existing `state/` directory.
- MUST honor `concise_threshold` with the summary + single-file longread rule;
  MUST NOT chunk-split any outbound message (AC9).
- MUST send `sendChatAction` typing once immediately before each outbound
  `sendMessage` (outbox drain, including records from `intercom send`);
  MUST NOT send typing on inbound pickup; MUST NOT loop or keep typing
  alive (AC10, CDT-509).
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
- MUST (CDT-509) run the 24/7 `getUpdates` loop only in `daemon.sh` inside
  the container; each iteration MUST invoke `poller.sh` once; MUST NOT hold
  `state/poller.lock` across cycles; MUST mount the token file read-only and
  the state dir as a bind mount; MUST keep `poller.sh` / `watch.sh` one-shot;
  MUST NOT arm `watch.sh` as a second consumer when the daemon identity is
  running (CDT-527 AC3: identity running is enough; heartbeat optional).
  `ir_daemon_running` (heartbeat AND compose) remains the doctor liveness
  conjunct, not the setup-mode predicate.
- MUST (CDT-509) pin a Docker Official Image by digest. The CDT-509 alpine
  digest is approved. TTY-less Y on `/setup telegram` and `--start-daemon`
  are the pull approval for that digest only.
- MUST (CDT-527) treat Docker as available only via `ir_docker_available`
  (`command -v docker` + `docker compose version` + `docker info`, inspect
  only); MUST start the sidecar only through `start-daemon.sh` (host
  uid:gid, never uid 0, token file `:ro` via compose, never token in
  env/argv, `INTERCOM_PLUGIN_ROOT` = plugin root via `plugin-dir.sh` not
  cwd, `docker compose -p intercom up -d --build`); MUST print daemon mode
  after `up` rc 0 even if heartbeat is empty; MUST refuse a held
  `state/poller.lock` with exit 75 and no C1 re-arm.
- SHOULD keep `probe.sh` as the operator pre-deploy gate; MUST NOT invoke
  it from `start-daemon.sh` or `/setup telegram` (CDT-527 AC8).
- SHOULD keep the temp-path rule (`${TMPDIR:-/tmp}` or `mktemp`) in every
  executable block and script (AGENTS.md).

## MUST NOT

- MUST NOT run a resident daemon, loop, or host crontab entry in phase 1
  (harness-scheduled ephemeral cycles only). The CDT-509 daemon is the
  container exception; the host still MUST NOT run a bare-metal poller loop.
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
- MUST NOT modify Claude Code config, docker stacks other than compose
  project `intercom`, or repo-tracked state at runtime. Starting,
  inspecting, or stopping project `intercom` from `/setup telegram` /
  `start-daemon.sh` is allowed. MUST NOT mutate any other compose project.
- MUST NOT introduce a host runtime beyond bash/jq/curl (AC21). The
  container uses the same four cycle tools. MUST NOT add Python/Node/Go
  inside the daemon image for this ticket.
- MUST NOT `docker pull` an unapproved or unpinned image. MUST NOT publish
  inbound ports. MUST NOT run the daemon as uid 0. MUST NOT invoke
  `probe.sh` from setup or `start-daemon.sh`.
- MUST NOT break the spool interface (additive compose/daemon assets and
  extra `config.json` keys only).

## Alternatives considered

- **Marketplace telegram plugin (Option B)** — rejected: session-coupled;
  per-session MCP pollers recreate the multi-consumer `getUpdates` loss; the
  timers, away flags, and topic map would still need building.
- **File-based only, no poller (Option C)** — rejected as the end state; kept
  as this phase's mechanism.
- **Telegraph/third-party longreads** — rejected per resolved design: the
  rich artifact is a `sendDocument` upload, no third-party service.
- **Host crontab** — rejected: host machine safeguard (no bare-metal
  daemons/cron ownership). Phase 1 uses harness scheduling. Phase 2 uses
  the container, not host cron.
- **Grok `scheduler_create` on idle** — rejected: that path spawned an
  LLM and injected a parent turn every cycle (CDT-512-C1).
- **Ship `~/.grok/long-running-background-tasks/watch-intercom.sh`** —
  rejected: local workaround (resident loop, hardcoded chat id, inbound
  body dump). Product adapter is `skills/intercom/watch.sh`.
- **Rewrite `poller.sh` as a resident loop** — rejected: spool cycle stays
  one-shot; `daemon.sh` loops it (CDT-509).
- **Inject into an existing docker compose stack** — rejected: AC23; the
  sidecar is a separate project named `intercom`.
- **Token via env or compose `environment`** — rejected: AC4; bind-mount
  the 0600 file read-only.
- **Custom published image / `:latest`** — rejected: Docker Official Image
  pinned by digest after operator approval.
- **"Active session" via spool-dir existence** — rejected (CDT-529 Q1):
  every session that ever used the intercom has spool dirs, so "exactly
  one" would never hold and AC2 would be untestable. Pending-question
  presence is the observable definition of *currently orchestrating*.
- **"Active session" via spool mtime recency window** — rejected: adds a
  knob and an mtime heuristic with no semantic anchor; pending presence
  self-deactivates exactly when the question is answered.
- **Correlate inbound to the ask record via `reply_to_message.message_id`**
  — rejected: requires the poller to remember every escalation send's
  `message_id`, and a member replying from a different client or quoting
  manually carries no `reply_to_message`. Topic mapping + active-session
  fallback covers the same traffic with less state.
- **Configurable fallback target (`fallback_session` key)** — rejected for
  this ticket (CDT-529 Q2): the single-active-session default plus
  `default_session` for zero/≥2 covers all confirmed ACs; config surface
  is deferred to CDT-531 if a need appears.
- **Rewriting misrouted CDT-528 records in `spool/main/inbox/`** —
  rejected as code (CDT-529 Q4): one-off operator `jq` move documented in
  the runbook; automated migration of past misroutes is out of scope.

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
- **AC10.** Inbound pickup MUST NOT send `sendChatAction` `typing` (pickup
  MUST NOT imply a reply is in flight). Each outbound `sendMessage` on the
  poller send path (outbox drain, including records written by
  `intercom send`) MUST send `sendChatAction` `typing` once immediately
  before `sendMessage`. Typing failure MUST NOT skip the send. MUST NOT
  run a resident typing-keepalive loop (CDT-509).
  Verify: bash skills/intercom/test.sh ; bash skills/intercom/test-poller.sh
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
  **or** contains only the `general` key. Offset advances. Pickup MUST
  NOT send typing (AC10). This MUST work on an already-paired Intercom with empty
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

### CDT-512-C5

- **AC1.** Inbound pickup MUST NOT send `sendChatAction` `typing`. Pickup
  writes the inbox record and advances offset without implying a reply is
  in flight.
  Verify: bash skills/intercom/test.sh
- **AC2.** Each outbound `sendMessage` via `ir_send_text` (poller outbox
  drain, including records from `intercom send`) MUST send
  `sendChatAction` `typing` once immediately before `sendMessage`.
  Typing failure MUST NOT skip the send. `test-poller.sh` also covers
  the drain path.
  Verify: bash skills/intercom/test.sh
- **AC3.** SPEC-038 AC10 is this contract: no pickup typing; typing on the
  send path; no resident keepalive.
  Verify: bash skills/intercom/test.sh
- **AC4.** Hermetic tests assert no `sendChatAction` on pickup and
  `sendChatAction` immediately before `sendMessage` on the send path.
  Verify: bash skills/intercom/test.sh
- **AC5.** `poller.sh` MUST NOT run a resident typing-keepalive loop
  (`while`/`sleep` around `sendChatAction`; daemon = CDT-509).
  Verify: bash skills/intercom/test.sh
- **AC6.** [process] `bash tools/run-all-tests.sh` exit 0; skill-lint,
  smoke, docs-drift pass. CDT-512-C1 `watch.sh` ACs pass. CDT-512-C2
  preamble ACs pass. CDT-512-C3 pairing-seed ACs pass. CDT-512-C4 TTY-less
  setup ACs pass. Patch bump; no new `commands/*.md`. Never print the bot
  token. Never commit `.claude/backlog` or `.claude/epics`.

### CDT-509

- **AC1.** The daemon owns the bot token: it mounts
  `~/.config/telegram/bot_token` (mode 600) read-only. A sentinel token is
  absent from image metadata, container env, argv, logs, spool files, and
  setup/daemon prompt text. The container cannot write the token file.
  Verify: bash skills/intercom/test-daemon.sh
- **AC2.** State is the bind-mounted § State layout at
  `~/.claude/telegram-router/` (`INTERCOM_STATE_ROOT` in tests). A daemon
  cycle plus `/setup telegram` writes nothing inside the repo, does not
  edit existing docker stacks other than compose project `intercom`, does
  not edit Claude Code config, and installs no new host runtime or crontab.
  CDT-527 may start project `intercom` only.
  Verify: bash skills/intercom/test-daemon.sh
- **AC3.** Exact spool contract: layout
  `spool/<sid>/{inbox,outbox,pending,answered}`,
  `state/{offset,heartbeat,poller.lock,seen.tsv,away}`, schema-1
  `config.json`, inbox/outbox record shapes (outbox
  `<epoch_ms>_0_<rand>.json`), pending-question format, and `intercom.sh`
  verbs `ask|send|away` are unchanged. Additive compose/daemon assets and
  extra JSON keys only. Schema stays 1. With the daemon absent, CDT-501 and
  CDT-512 poller/watch ACs still pass.
  Verify: bash skills/intercom/test.sh
- **AC4.** Exactly one `getUpdates` consumer per token: each `poller.sh`
  cycle takes `state/poller.lock` with `flock -n`. Contended lock exits 75
  with no mutation. A `409` exits 4 without advancing offset. `daemon.sh`
  MUST NOT hold that lock across cycles. Daemon-up setup MUST NOT arm
  `watch.sh` as a second consumer (AC10). Do not claim `watch.sh` itself
  exits 75 — it wraps poller 75 and exits 0 (CDT-512-C1). Do not claim a
  second daemon process exits 75 — it backoffs and continues (AC5).
  Verify: bash skills/intercom/test-daemon.sh
- **AC5.** 24/7 long-poll with zero live sessions: the resident loop is
  `skills/intercom/daemon.sh` (compose `command`); each iteration invokes
  `poller.sh` once. `poller.sh` and `watch.sh` stay one-shot. Fast poller
  exit 0 (wall time under 2s) MUST backoff ≥1s; exit 2 terminates the
  loop; 75/4/other nonzero backoff and continue. With no session and no
  `watch.sh` job, an allowlisted inbound lands in `spool/<sid>/inbox/`
  within one `getUpdates` return (`poll_timeout_s`, default 30). Heartbeat
  is touched each cycle. Volume state survives restart. No host crontab.
  No inbound published ports.
  Verify: bash skills/intercom/test-daemon.sh
- **AC6.** Topic map is the session registry: `topics.json` sid →
  `thread_id`; General is the walkie-talkie to `default_session`; empty or
  only-general map routes unmapped threads there; any non-`general` sid
  keeps unmapped fail-closed (no cross-delivery). First outbound or
  Escalation auto-creates the session topic. Daemon adds no second map.
  Verify: bash skills/intercom/test.sh
- **AC7.** Escalation is the same timestamp sweep, 24/7 with zero
  sessions: unanswered pending fires once after `escalation_timeout_s`
  (default 900); Away ON fires immediately once; expiry while down fires
  on the next cycle; an answer cancels and relays `kind: "answer"`.
  Verify: bash skills/intercom/test-poller.sh
- **AC8.** Away mode stays `state/away` only, toggled by `intercom away`
  and phone `/away`/`/afk` (no inbox relay). Away ON drains outbox every
  cycle and survives container restart. OFF restores the default timer.
  Verify: bash skills/intercom/test-poller.sh
- **AC9.** Typing stays send-path only (CDT-512-C5): no `sendChatAction` on
  inbound pickup; one `typing` immediately before each outbound
  `sendMessage`; typing failure MUST NOT skip the send; the daemon MUST
  NOT run a typing-keepalive loop. Send-path coverage is CDT-512-C5 in
  `bash skills/intercom/test.sh`.
  Verify: bash skills/intercom/test-daemon.sh
- **AC10.** `/setup telegram` prints daemon mode iff both: heartbeat mtime
  age ≤ `stale_heartbeat_s` AND compose identity running (project
  `intercom`, service `daemon`, label `dev-team.intercom=daemon`). Daemon
  mode: replace the harness schedule prompt; do not arm `watch.sh` as a
  `getUpdates` consumer; token-free; ≤ 4 KiB. Fail closed (stale
  heartbeat, compose down, or docker CLI absent): CDT-512-C1 arming block
  unchanged; missing docker is not a setup failure. Re-run keep-existing
  prints the current mode. `commands/setup.md` and
  `docs/runbooks/setup-telegram.md` document both modes.
  CDT-527 AC3 supersedes the heartbeat conjunct for `/setup telegram`
  mode selection (identity running is enough). This AC remains the
  `ir_daemon_running` doctor/liveness contract.
  Verify: bash skills/intercom/test.sh
- **AC11.** Shipped compose/Dockerfile pins a Docker Official Image by
  digest (`docker.io/library/<name>@sha256:<hex>`, no `:latest`). Alpine
  packages: `bash jq curl util-linux ca-certificates` (not BusyBox
  `flock`). The runbook presents the candidate (source, digest,
  default-root vs required non-root). Operator approval is required
  before any pull. Hermetic suites never `docker pull` or `docker run` a
  real image. Runtime `user:` is a non-zero host uid:gid that can read
  the 0600 token. `read_only: true` plus `tmpfs` `/tmp`. `cap_drop: [ALL]`.
  CDT-527: TTY-less default Y and `--start-daemon` are the pull approval
  for this digest. No new image.
  Verify: bash skills/intercom/test-daemon.sh
- **AC12.** `probe.sh` is the operator pre-deploy gate: it MUST pass every
  § Verified-vs-assumed behavior before dependent daemon start. Suites
  never invoke it. The runbook says stop the daemon before probe (409).
  CDT-527 AC8: `start-daemon.sh` and `/setup telegram` MUST NOT invoke
  `probe.sh`. Probe stays operator-only; it is not a setup gate.
  Verify: bash skills/intercom/test.sh
- **AC13.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint
  (SPEC-021), smoke (SPEC-030), and docs-drift pass. CDT-501 and CDT-512
  suites still pass. Release bump is patch (no new `commands/*.md`). Never
  print the bot token. Never commit `.claude/backlog` or `.claude/epics`.

### CDT-527

- **AC1.** Docker is available for Intercom daemon start iff all three
  inspect-only checks succeed, in this order: `command -v docker`,
  `docker compose version`, `docker info`. Any miss means not available.
  The checks MUST NOT `docker pull`, `docker run`, or print the bot token.
  Verify: bash skills/intercom/test.sh
- **AC2.** After pairing and on keep-existing, when Docker is not
  available: print the CDT-512-C1 `watch.sh` arming block, print one
  token-free line that names the first failed check (docker CLI, compose
  v2, or engine), and exit 0. Missing Docker is not a setup failure.
  Verify: bash skills/intercom/test.sh
- **AC3.** After pairing and on keep-existing, when Docker is available
  and the daemon identity is already running (compose project `intercom`,
  service `daemon`, label `dev-team.intercom=daemon`): print daemon mode
  (token-free, ≤ 4 KiB, do not arm `watch.sh`). MUST NOT start a second
  getUpdates consumer. Heartbeat MAY be empty or stale — identity
  running is enough (this ticket supersedes CDT-509 AC10's heartbeat
  conjunct for `/setup telegram` mode selection). Walkie-talkie,
  Escalation, and Away mode stay unchanged. Doctor heartbeat health is
  out of scope (stale heartbeat remains a liveness signal, not a
  setup-mode conjunct).
  Verify: bash skills/intercom/test.sh
- **AC4.** After pairing and on keep-existing, when Docker is available
  and the daemon identity is down: prompt to start the Intercom daemon.
  TTY-less default is Y (empty, `Y`/`y`/`yes`, and EOF). Answer `n`/`N`/`no`
  keeps the C1 `watch.sh` arming block and MUST NOT start the daemon.
  Default Y invokes `skills/intercom/start-daemon.sh`. Host uid 0: helper
  refuses, setup prints one refuse line and the C1 block, exit 0. Compose
  `up` failure: no daemon-mode block; print a token-free error plus C1;
  pairing and keep-existing exit 0.
  Verify: bash skills/intercom/test.sh
- **AC5.** `skills/intercom/start-daemon.sh` is a subprocess CLI (never
  sourced). It starts the shipped compose sidecar with the host uid:gid
  (never uid 0), mounts the mode-600 token file `:ro` via compose, and
  MUST NOT put the token in env, argv, or printed text. The start
  command is `docker compose -p intercom up -d --build`. After `up`
  returns 0, `/setup telegram` prints daemon mode even if
  `state/heartbeat` is empty or stale, and MUST NOT arm `watch.sh`. Uses
  the CDT-509 AC11 alpine digest pin; no new image.
  Verify: bash skills/intercom/test-daemon.sh
- **AC6.** When `state/poller.lock` is held, `start-daemon.sh` refuses
  (exit 75): one getUpdates consumer. Copy tells the operator to stop
  host `watch.sh` first. `/setup telegram` (pairing, keep-existing, and
  `--start-daemon`) MUST NOT start the daemon and MUST NOT print the C1
  arming block on this path.
  Verify: bash skills/intercom/test-daemon.sh
- **AC7.** `/setup telegram --start-daemon` is for an already-paired
  Intercom (`config.json` has ≥1 member and the token file exists).
  `commands/setup.md` telegram sub forwards remaining args to
  `setup-telegram.sh`, which forwards `--start-daemon` to
  `start-daemon.sh`. Unpaired: fail closed, no start, nonzero exit.
  Already running: print daemon mode, exit 0, no second consumer. The
  flag is the confirm (no Y prompt). `--start-daemon` on uid 0 or compose
  failure exits nonzero (no C1).
  Verify: bash skills/intercom/test.sh
- **AC8.** Hermetic suites never `docker pull` or `docker run` a real
  image. `probe.sh` stays operator-only: `start-daemon.sh` and `/setup
  telegram` MUST NOT invoke it (this ticket supersedes CDT-509 AC12 for
  the automated start path).
  Verify: bash skills/intercom/test-daemon.sh
- **AC9.** `commands/setup.md` telegram sub, `skills/intercom/SKILL.md`,
  and `docs/runbooks/setup-telegram.md` document: the Docker availability
  gate; auto-start via `start-daemon.sh`; C1 fallback when Docker is
  missing or the operator answers n; `--start-daemon` for an
  already-paired box; remaining args forwarded; never print the bot token.
  Verify: bash skills/intercom/test.sh
- **AC10.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint,
  smoke, and docs-drift pass. Intercom `test.sh` and `test-daemon.sh`
  suites stay green. Release bump is patch; no new `commands/*.md`. Never
  print the bot token. Never commit `.claude/backlog` or `.claude/epics`.

### CDT-528

- **AC1.** `ir_send_longread` in `skills/intercom/poller.sh` materializes
  the summary fallback (summary present, `file` set but missing) with a
  BusyBox-safe sequence: `mktemp -d` a suffix-free
  `${TMPDIR:-/tmp}/intercom-longread-XXXXXX` directory, write the record
  text to `longread.md` inside it, `sendDocument` that path, and
  `rm -rf` the directory on the success path and on every failure path
  (write failure, send failure). No mktemp template in the file carries a
  suffix after the `X` run. The document path still matches
  `intercom-longread-*.md` (directory prefix + `longread.md`).
  Verify: bash skills/intercom/test-poller.sh
- **AC2.** The hermetic suite proves the BusyBox shape: with a PATH-stub
  `mktemp` that rejects any template carrying a suffix after the `X` run
  (exit nonzero, BusyBox-style) and delegates suffix-free templates to
  the real mktemp, a summary record with a missing file materializes,
  uploads `longread.md`, and its outbox record is deleted.
  Verify: bash skills/intercom/test-poller.sh
- **AC3.** Under the same stub with `sendDocument` failing: the temp
  directory is removed (no stale files remain) and the outbox record is
  kept for retry (one warn line, cycle still exits 0).
  Verify: bash skills/intercom/test-poller.sh
- **AC4.** GNU mktemp behavior is unchanged: the existing hermetic
  materialize test still passes against the host's real mktemp, and the
  other mktemp callsites (`poller.topics`, `poller.esc`, `poller.seen`)
  are untouched.
  Verify: bash skills/intercom/test-poller.sh
- **AC5.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint
  and docs-drift pass. Release bump is patch; no new `commands/*.md`.
  Never print the bot token.
An *active* session is one whose `spool/<sid>/pending/` holds ≥1
unanswered question (resolved Q1). Route resolution order is § Poller
cycle; the CDT-529 ACs pin it.

### CDT-529

- **AC1.** An inbound reply in a forum topic whose `message_thread_id` is
  mapped to a `sid` in `topics.json` whose pending dir holds ≥1
  unanswered question writes the message JSON to
  `spool/<that-sid>/inbox/` (existing record shape unchanged).
  Verify: bash skills/intercom/test-poller.sh
- **AC2.** A thread with no `topics.json` mapping and exactly one active
  session routes to that session's `inbox/`. The target is the single
  active session itself — no configuration key is added (resolved Q2).
  Verify: bash skills/intercom/test-poller.sh
- **AC3.** A thread with no mapping and zero or ≥2 active sessions writes
  to `spool/<default_session>/inbox/` and emits exactly one stderr warn
  line naming the unmapped thread id. No artifacts beyond the record
  (no topic creation, no pending mutation).
  Verify: bash skills/intercom/test-poller.sh
- **AC4.** `intercom.sh ask` resolves the route before any delivery: the
  pending record written by `ir_pending_write` carries
  `route: {sid, thread_id}` — `sid` is the asking session, `thread_id`
  the best-effort `topics.json` lookup for that sid (`null` when
  unmapped) — so a reply returns to the asking session even if no
  session ever posted to that topic before. The poller back-fills
  `route.thread_id` in the same rewrite that marks `escalated` when the
  escalated send went through a created/resolved topic.
  Verify: bash skills/intercom/test.sh
- **AC5.** A thread mapped to a sid with no unanswered pending question
  (no longer active) behaves per AC3: `default_session` inbox + one warn
  line naming the thread id. The message is never silently dropped.
  Verify: bash skills/intercom/test-poller.sh
- **AC6.** The pending record's route fields are written in the single
  atomic creation write (one tmp + rename). A failed or unreadable
  `topics.json` lookup cannot produce a question without a non-empty
  `route.sid`; `route.thread_id` is `null` in that case and is
  back-filled best-effort later.
  Verify: bash skills/intercom/test.sh
- **AC7.** Existing `topics.json` files without new fields remain
  readable: a map holding only legacy `{sid: {thread_id, title}}` entries
  routes exactly as before (no migration step, no new required keys);
  absent route data falls back to the § Poller cycle order.
  Verify: bash skills/intercom/test-poller.sh
- **AC8.** Guardrail (CDT-531 out of scope): the topic-creation failure
  path for an unmapped sid is unchanged — `ir_resolve_outbound` still
  degrades to plain chat with the same warn, and inbound still follows
  the AC3 fallback; the escalation loop error's frequency and severity
  are unchanged (the createForumTopic retry cadence is untouched).
  Verify: bash skills/intercom/test-poller.sh
- **AC9.** The CDT-528 scenario does not recur: with exactly one
  orchestrating session and a reply in the question thread (the topic the
  escalation was delivered into), the routed inbox record appears within
  the monitor's existing expiry window — `watch.sh` is not modified.
  Verify: bash skills/intercom/test-poller.sh
- **AC10.** Outbound routing is unaffected: `ir_resolve_outbound`
  behavior (map hit → topic; default session → general/plain;
  auto-create otherwise) and its call sites are unchanged in contract;
  all existing poller tests pass.
  Verify: bash skills/intercom/test-poller.sh
- **AC11.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint,
  docs-drift, and spec-lint pass. Release bump is patch (no new
  `commands/*.md`; the check-bump-class gate is surface-based). The
  routing-fallback default-behavior change is recorded; `/release` owns
  the final bump-class call. Never print the bot token.

### CDT-530

- **AC1.** `ir_drain_outbox` / `ir_send_longread` in
  `skills/intercom/poller.sh` track per-part delivery in the outbox
  record: after the message part of a record is delivered successfully
  (the summary `sendMessage` when a summary is present, or the full-text
  `sendMessage` when it is not), the poller rewrites that record with the
  optional flag `summary_sent: true` / `text_sent: true` (jq to a tmp
  file, atomic `mv` publish). The record-schema comment on
  `ir_outbox_write` in `skills/intercom/common.sh` documents the flag.
  Records without the flag — including records written by earlier
  versions — drain unchanged (flag absent = part not yet sent).
  Verify: bash skills/intercom/test-poller.sh
- **AC2.** On a retry cycle a record whose message part is marked
  delivered does not re-send it: the cycle sends only the remaining part
  (`sendDocument`), and the record is deleted only after all parts
  succeed. At-least-once semantics hold: a failed part send or a failed
  flag rewrite keeps the record (a redelivered part is then possible;
  exactly-once is not claimed, no record → no offset advance).
  Verify: bash skills/intercom/test-poller.sh
- **AC3.** Regression test (hermetic): a summary + file record whose
  `sendDocument` fails twice then succeeds. Across the accumulated
  `ARGV_LOG` of the three cycles the summary text appears exactly once
  (the marked-delivered part is never re-sent); each failed cycle may log
  a `sendDocument` attempt (at-least-once, per AC2), the successful
  delivery happens on the success cycle only, and the outbox record is
  deleted after the third cycle.
  Verify: bash skills/intercom/test-poller.sh
- **AC4.** The same once-only guarantee covers a no-summary record with
  a file: when its `sendDocument` fails, the full-text `sendMessage` is
  not repeated on the retry cycle (the `text_sent` path).
  Verify: bash skills/intercom/test-poller.sh
- **AC5.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint
  and docs-drift pass. Release bump is patch; no new `commands/*.md`.
  No poller surface change: one-shot cycle, no LLM, no resident loop.
  Never print the bot token (existing hermetic sentinel still passes).

### CDT-531

- **AC1.** The auto-create call in `ir_resolve_outbound` sends the Bot
  API parameter `name` (not `title`): `createForumTopic -F
  "chat_id=$OWNER_CHAT" -F "name=$sid"`. A successful create records
  `topics.json` exactly as before (thread_id + title = sid).
  Verify: bash skills/intercom/test-poller.sh
- **AC2.** `createForumTopic` is never invoked with an empty name: if
  the derived name would be empty, the call is skipped, exactly one
  one-line stderr warn is emitted, and delivery degrades to plain chat.
  Verify: bash skills/intercom/test-poller.sh
- **AC3.** A 4xx API rejection of the auto-create is cached per sid in
  a state file (one `sid<TAB>rejected_at_epoch` line per entry, written
  and pruned under the existing poller lock, 0600). While a sid's
  rejection is cached, later cycles skip the create call for that sid
  (zero `createForumTopic` argv entries), degrade to plain chat, and do
  not repeat the warn every cycle.
  Verify: bash skills/intercom/test-poller.sh
- **AC4.** Cache invalidation: a cached rejection is retried (entry
  dropped) after a TTL, and a transport failure or non-4xx (5xx/429)
  response is never cached. A `topics.json` mapping hit for the sid
  short-circuits before the cache is consulted.
  Verify: bash skills/intercom/test-poller.sh
- **AC5.** The CDT-529 AC8 failure-path contract is updated, not
  reverted: an auto-create rejection still degrades to plain chat, but
  the retry cadence is now cache-gated per AC3/AC4 (this supersedes the
  CDT-529 AC8 sentence leaving the createForumTopic retry cadence
  untouched). Inbound routing (`ir_route_inbound`) and the CDT-530
  functions (`ir_send_longread`, `ir_drain_outbox` flag shape) are not
  modified.
  Verify: bash skills/intercom/test-poller.sh
- **AC6.** `probe.sh` sends the same fix (`name` parameter) so the
  live topic probe passes against the real Bot API.
  Verify: bash skills/intercom/test-poller.sh
- **AC7.** The argv assertion for auto-create checks `name=` (the
  `title=fresh-sid` assertion is updated), and a hermetic test proves
  an unmapped-thread cycle emits at most one `createForumTopic` call
  with a non-empty `name=` value, with a second cycle emitting zero.
  Verify: bash skills/intercom/test.sh
- **AC8.** [process] `bash tools/run-all-tests.sh` exits 0; skill-lint,
  docs-drift, and spec-lint pass. Release bump is patch (no new
  `commands/*.md`). The bot token never appears in argv, logs, spool
  files, or error text.

## Test

- [ ] Token file written 0600 with 700 parent; repo stays clean (AC1)
- [ ] Unpaired cycle creates zero artifacts; non-allowlisted id ignored
      with zero artifacts beside a normal relay (AC2)
- [ ] Token sentinel absent from every written file and from curl argv (AC4)
- [ ] `/setup slack` zero-write stub (AC5)
- [ ] Thread-mapped delivery, no cross-delivery with two sids; General
      routes to the default session and replies return to General (AC6)
- [ ] Summary + single-file longread above threshold; single message below (AC9)
- [ ] no typing on pickup; typing immediately before sendMessage (AC10)
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
- [ ] Pickup sends no typing; outbox drain types once immediately before
      `sendMessage`; no typing-keepalive loop (CDT-512-C5 AC1–AC5)
- [ ] Token file mounted read-only; sentinel absent from image/env/argv
      (CDT-509 AC1)
- [ ] State bind-mount; repo and host stacks untouched (CDT-509 AC2)
- [ ] Spool contract byte-stable; additive daemon assets only (CDT-509 AC3)
- [ ] Sole getUpdates consumer; second start 75 or 409/exit 4 (CDT-509 AC4)
- [ ] Zero-session inbound lands in spool within one long-poll (CDT-509 AC5)
- [ ] Topic map / walkie-talkie / fail-closed unmapped (CDT-509 AC6)
- [ ] Escalation sweep 24/7; away-immediate; answer cancels (CDT-509 AC7)
- [ ] Away file survives container restart (CDT-509 AC8)
- [ ] No pickup typing; no keepalive in the daemon (CDT-509 AC9)
- [ ] Setup daemon-mode iff heartbeat fresh AND compose running (CDT-509 AC10;
      doctor/liveness — CDT-527 AC3 supersedes the hb conjunct for setup mode)
- [ ] `daemon.sh` loops `poller.sh`; does not hold `poller.lock` across cycles (CDT-509 AC4/AC5)
- [ ] Image digest-pinned; no hermetic pull; non-root (CDT-509 AC11)
- [ ] probe.sh pre-deploy; suites never call it (CDT-509 AC12)
- [ ] Docker available iff CLI + compose v2 + `docker info`; inspect only
      (CDT-527 AC1)
- [ ] Docker missing: C1 `watch.sh` arming + one missing-check line, rc 0
      (CDT-527 AC2)
- [ ] Identity running: daemon mode, no second consumer, heartbeat optional
      (CDT-527 AC3)
- [ ] Daemon down: TTY-less Y starts helper; n keeps C1; uid 0 / up-fail
      fall back to C1 on pairing path (CDT-527 AC4)
- [ ] `start-daemon.sh`: host uid:gid, refuse uid 0, token `:ro`,
      `compose -p intercom up -d --build`; daemon mode after up (CDT-527 AC5)
- [ ] `poller.lock` held: start-daemon exit 75, no C1 re-arm (CDT-527 AC6)
- [ ] `--start-daemon` + remaining args forwarded; unpaired fail-closed
      (CDT-527 AC7)
- [ ] Hermetic never pull/run a real image; probe not invoked (CDT-527 AC8)
- [ ] setup.md / SKILL.md / runbook document start vs C1 (CDT-527 AC9)
- [ ] Mapped topic + active sid routes to that sid's inbox (CDT-529 AC1)
- [ ] Unmapped thread + exactly one active session routes there (CDT-529 AC2)
- [ ] Unmapped thread + zero/≥2 active → `default_session` + one warn line
      naming the thread id (CDT-529 AC3)
- [ ] Pending record carries `route: {sid, thread_id}` from the single
      creation write; back-fill on the escalated send (CDT-529 AC4/AC6)
- [ ] Mapped-but-inactive sid falls back per AC3, never silent (CDT-529 AC5)
- [ ] Legacy `topics.json` (no route fields) routes unchanged (CDT-529 AC7)
- [ ] Plain chat always `default_session`; correlation-miss warn only when a
      non-default sid has a pending question (CDT-529 Q3)
- [ ] createForumTopic failure path and its warn unchanged (CDT-529 AC8)
- [ ] `ir_resolve_outbound` contract unchanged; existing outbound tests pass
      (CDT-529 AC10)

## Validation

- [ ] Spec reviewed against CDT-501 ACs 1–25 (PM final, 2026-10-05), the
      2026-10-03 brainstorm decision log, CDT-509 ACs 1–13 (PM kickoff,
      2026-10-07), CDT-527 ACs 1–10 (PM scope, 2026-10-07), and CDT-529
      ACs 1–10 (PM confirmed, 2026-10-08)
- [ ] `probe.sh` remains operator-only (CDT-527 AC8); not a setup or
      merge gate. Operator may run it before a first live start.
- [ ] Hermetic suites green with no network; `tools/run-all-tests.sh` exit 0
- [ ] skill-lint, smoke, docs-drift clean; spec-lint covers findings cleared
      when T2–T8 land the covered paths
- [ ] Release bump minor (new `/away`, `/afk` surfaces) for CDT-501; CDT-509
      is patch (no new `commands/*.md`)
- [ ] Operator approved the pinned digest before any `docker pull` (CDT-509);
      CDT-527 TTY-less Y / `--start-daemon` is that approval for the alpine digest

## Open questions

- **OQ1 (blocks pull, not code).** Operator must approve one official
  image before any `docker pull`. TL recommendation (Hub metadata
  2026-10-07; **not pulled**): `docker.io/library/alpine:3.21` index
  `sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507`
  (linux/amd64 `sha256:3c81aa9a3d770b316568f4499e30461a5cd3fbd7180bd89e28e34894c7845832`;
  Docker Official Image; Hub rebuild 2026-09-18; ~3.6 MB; default USER
  root — product `user:` is host uid). Alternative:
  `docker.io/library/debian:bookworm-slim` index
  `sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587`
  (linux/amd64 `sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91`;
  official; glibc; bash in base; ~28 MB; Hub 2026-10-06). PM named
  alpine 3.22.2 (index `sha256:4b7ce070…`, last_pushed 2025-10-09) —
  official but a year-old rebuild; do not pin it unless the operator
  insists. This host already has `alpine:3.20` (zero new pull if the
  operator refuses 3.21). Unofficial images are not in scope.

## Version History

| Date | Change |
|------|--------|
| 2026-10-05 | CDT-501 — initial ACTIVE spec: spool protocol, `intercom` CLI, poller cycle, escalation, away, longread, `/setup telegram`/`slack`, doctor check, phase-2 contract |
| 2026-10-05 | CDT-501 — command-relay clarification (only `/away`/`/afk` are intercepted; other slash text relays) and AC consolidation to the M14 budget: 2+3→2, 6+7+8→6, 12+13→12, 14+15+16→14, 17+18+19+20→17 |
| 2026-10-07 | CDT-512-C1 — host adapter `watch.sh`: poller stays one-shot; idle injects no parent turn; host-aware arming (Grok silent watcher + Claude CronCreate-if-zero-parent-turn); wake-line grammar; edge-triggered failure wake |
| 2026-10-07 | CDT-512-C2 — per-dev bot setup: `$USER` member default, BotFather preamble, operator runbook, topics on/off both supported |
| 2026-10-07 | CDT-512-C3 — pairing seeds General `thread_id`; unmapped empty/only-general map routes to `default_session`; poller ignores bot self-echo and forum service messages; chmod 700 existing `state/` |
| 2026-10-07 | CDT-512-C4 — TTY-less `/setup telegram`: mode-600 `bot_token` reuse vs replace; pairing long-polls 30s with no Enter wait |
| 2026-10-07 | CDT-512-C5 — typing is send-path only: no `sendChatAction` on inbound pickup; `ir_send_text` types once immediately before `sendMessage`; no keepalive loop |
| 2026-10-07 | CDT-509 — phase-2 containerized daemon: `daemon.sh` loops one-shot `poller.sh`; token `:ro` + state bind; flock per cycle not across; setup daemon-mode = heartbeat fresh AND compose `intercom`; digest-pin + approve-before-pull; `probe.sh` pre-deploy; C1 harness remains |
| 2026-10-07 | CDT-527 — `/setup telegram` starts the Intercom daemon when Docker is available (`start-daemon.sh`); availability = CLI + compose v2 + `docker info`; identity-running or post-`up` prints daemon mode even if heartbeat is empty (supersedes CDT-509 AC10 heartbeat conjunct for setup mode); `probe.sh` stays operator-only (supersedes CDT-509 AC12 for the automated start path); C1 fallback when Docker is missing or operator answers n; `--start-daemon` for an already-paired box; patch, no new Surface |
| 2026-10-08 | CDT-529 — inbound routing: unmapped threads resolve via the single *active* session (≥1 unanswered pending) else `default_session` + warn (supersedes the CDT-512-C3 zero-artifacts ignore for unmapped threads); plain chat always `default_session`; `ir_pending_write` records `route: {sid, thread_id}` atomically at ask time and the sweep back-fills `thread_id` on the escalated send; mapped-but-inactive sid falls back per AC3; CDT-528 misrouted records get a documented manual fix only |

## Cross-references

- SPEC-021 — skill-bash lint gate (all `skills/intercom/*.sh` + fences)
- SPEC-030 — smoke harness + hermetic test conventions
- SPEC-031 — escalation gate (implementation-capable skills)
- SPEC-016 — worktree isolation (`.worktrees/CDT-501`)
- SPEC-010 — docs-drift + version pair at `/release`
- `docs/runbooks/scheduled-retro.md` — harness cron prompt pattern (ci-watch)
- `docs/internal/permission-posture-matrix.md` — sandbox egress evidence
