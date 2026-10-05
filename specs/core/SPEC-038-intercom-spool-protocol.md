# SPEC-038: Intercom Spool Protocol (Phase 1)

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-05
**Covers**: `skills/intercom/` (`SKILL.md`, `common.sh`, `intercom.sh`, `poller.sh`, `setup-telegram.sh`, `probe.sh`, `test.sh`, `test-poller.sh`), `commands/away.md`, `commands/afk.md`, `commands/setup.md` (`telegram` and `slack` subs), `skills/doctor/checks/intercom.sh`, `README.md`

## Overview

Each member gets a personal Telegram **Intercom**: a per-member bot that relays
between the member's phone and their agent sessions. Sessions ask; the member
answers from Telegram; the **General** topic is the **walkie-talkie** for
anything, anytime. Default mode keeps the CLI primary and adds a 15-minute
**escalation** for unanswered questions. **Away mode** makes the intercom
primary. Phase 1 is file-based: per-session spool dirs, a thin `intercom` CLI,
and a harness-scheduled ephemeral poller. Zero new runtimes — bash, jq, and
curl only (CDT-501 AC21). A containerized daemon replaces the poller in a
phase-2 ticket; it MUST keep this spool interface (§ Phase-2 contract).

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

One cycle per invocation; the harness schedule (§ Setup) invokes it every
30–60 s. Inside the cycle, `getUpdates` long-polls (`timeout` = config
`poll_timeout_s`, default 30) for near-instant pickup. Never a resident loop,
never a daemon, never host crontab.

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
   - otherwise resolve sid: `thread_id` → `topics.json`, else the general
     topic routes to `default_session`. Write an inbox record. Any other
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

`topics.json` maps sid → `thread_id`. On the first outbound or escalation for
an unmapped sid, the poller calls `createForumTopic` (title = sid) and records
it — outbound notifications auto-create the session topic (AC11). The general
topic is the walkie-talkie: its messages route to `default_session`, and that
session's replies return to the general topic (AC6). Per-session topics
prevent cross-delivery (AC6).

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

1. Prompt for the token; write `~/.config/telegram/bot_token` (0600) and
   `mkdir -m 700 -p` the parent. Creation sets modes explicitly — no umask
   reliance, no looser-perms window — and `chmod 700` an already-existing
   parent (`mkdir -p` never tightens).
2. Validate via `getMe`. Failure → print the reason, write no state beyond
   the token file.
3. Pairing: instruct the operator to message the bot, then one
   `getUpdates?timeout=30&offset=-1` captures the chat id and the initial
   offset (`max update_id + 1`) — satisfying AC22 startup validation.
4. Write `config.json` (§ State layout), create the state dirs and empty
   `topics.json` / `seen.tsv`.
5. Print the self-contained harness schedule prompt (≤ 4 KiB, ci-watch
   pattern) that invokes `poller.sh` every 30–60 s, with the absolute plugin
   path baked in and no token content (§ Poller cycle).

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

- MUST ship `intercom.sh`, `poller.sh`, `setup-telegram.sh`, `common.sh` as
  pure-subprocess bash CLIs (bash + jq + curl only, AC21); `poller.sh` and
  `intercom.sh` are never sourced.
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
  `default_session` only (AC6).
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

## Cross-references

- SPEC-021 — skill-bash lint gate (all `skills/intercom/*.sh` + fences)
- SPEC-030 — smoke harness + hermetic test conventions
- SPEC-031 — escalation gate (implementation-capable skills)
- SPEC-016 — worktree isolation (`.worktrees/CDT-501`)
- SPEC-010 — docs-drift + version pair at `/release`
- `docs/runbooks/scheduled-retro.md` — harness cron prompt pattern (ci-watch)
- `docs/internal/permission-posture-matrix.md` — sandbox egress evidence
