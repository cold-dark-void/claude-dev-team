# Runbook: Telegram Intercom setup

Set up a personal Intercom bot. Every developer creates their own bot.
Do not reuse a teammate's bot or token.

See also: [`/setup`](../commands/setup.md), [`/away`](../commands/away.md),
[`/afk`](../commands/afk.md).

---

## Before you start

1. Open Telegram and talk to `@BotFather`.
2. Create a **new** bot. This bot is yours.
3. Copy the token. Never share it. Never paste it into chat.
4. Either write it to `~/.config/telegram/bot_token` (mode 600) or paste it
   at the `/setup telegram` prompt (input is hidden).

The Intercom is a member's personal bot connector. A shared bot is wrong.

Bot API has no read receipts. That is a platform limit. The Intercom cannot
show when a message was read.

---

## Run setup

```
/setup telegram
```

The script prints a BotFather preamble, then asks for the token.
It validates the token with `getMe`. Then it asks for a member name.
The default is `$USER`. Type a name if you need a different one.

Then it waits for one private message to the bot. Send any message.
The script long-polls `getUpdates` for 30s. Do not pipe Enter. The script
writes state under `~/.claude/telegram-router/` (or `INTERCOM_STATE_ROOT`
in tests). It never writes inside the repo.

Docker is available iff `ir_docker_available`: `command -v docker`,
`docker compose version`, and `docker info`. These checks inspect only.
They do not pull. They do not run. They do not print the token.

It prints a host-aware block:

- Docker missing: print the C1 `watch.sh` block. Missing Docker is not
  a setup failure. Arm `watch.sh`, not `poller.sh`, every 45 seconds.
- Docker available and daemon identity running: print daemon mode. Do
  not arm `watch.sh`. Heartbeat may be empty or stale.
- Docker available and daemon identity down: the script asks to start.
  TTY-less default is Y. Y invokes `skills/intercom/start-daemon.sh`.
  That Y is the pull approval for the CDT-509 alpine digest pin.
  Answer `n` to keep the C1 `watch.sh` block. Setup does not start.

Do not print the token.

If `~/.config/telegram/bot_token` already exists (mode 600), the script
offers reuse vs replace. Reuse does not print the token. Do not overwrite
the file without a confirm.

---

## Topics on vs topics off

### Topics on = sid per topic

Enable Topics in the private chat with the bot (Bot API 9.3+ private bot
topics / forum). Setup then sets `topics_enabled=true`.
Each session or ticket can use its own topic. General stays the
walkie-talkie.

### Topics off = one General

Leave Topics off if you want a single window. Setup then sets
`topics_enabled=false`. That is a supported mode. It is not a failed setup.
`getChat.is_forum=false` is not an error. All traffic uses one General
window (walkie-talkie only).

You can enable Topics later and re-run pairing when you want sid per topic.

---

## After pairing

1. If setup printed daemon mode, skip this step. If it printed the C1
   harness block, arm `bash <plugin>/skills/intercom/watch.sh` every 45s.
2. Keep the main UI mirrored. Use `/away on` or `/afk on` when the Intercom is primary.
3. Use `/away off` when you return.
4. Session-or-ticket topics need an open session in phase 1 harness mode.
   The phase-2 daemon relays with zero live sessions. General still
   accepts walkie-talkie traffic.
5. Already paired: run `/setup telegram --start-daemon` to start the
   sidecar. The flag is the confirm. There is no Y prompt.

---

## Phase-2 daemon (24/7)

Compose project name is `intercom`. Service name is `daemon`. Label is
`dev-team.intercom=daemon`. No inbound ports.

### Image pin (approve before pull)

Candidate (Hub metadata 2026-10-07; **not pulled** until you approve):

- Source: Docker Official Image `alpine` 3.21
- Index digest: `docker.io/library/alpine@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507`
- Default USER in the image is root. Product `user:` is **not** uid 0.
  Set `INTERCOM_UID` and `INTERCOM_GID` to your host ids so the container
  can read the mode-600 token.

Do not `docker pull` until you approve this candidate. Do not use
`:latest`. Hermetic tests never `docker pull` or `docker run`.

### Pre-deploy gate

`probe.sh` is the operator-only pre-deploy gate. It is not a setup gate.
Setup and `start-daemon.sh` do not invoke it. It must pass every SPEC-038
§ Verified-vs-assumed behavior before a live operator start. Suites never
run it.

Stop the daemon first. A second getUpdates consumer returns 409.

```
docker compose -p intercom stop
bash <plugin>/skills/intercom/probe.sh
```

### First start

First start is `/setup telegram`. It is not a manual compose block as
the only path. Pair, then let setup start the sidecar when Docker is
available.

When Docker is available and the daemon identity is down, accept the
start prompt. TTY-less default is Y. Y invokes
`skills/intercom/start-daemon.sh`. That Y is the pull approval for the
CDT-509 alpine digest pin. Answer `n` to keep the C1 `watch.sh` block.

Already paired: `/setup telegram --start-daemon`. The flag is the
confirm. There is no Y prompt.

`start-daemon.sh` runs `docker compose -p intercom up -d --build` with
host uid:gid. Never put the token in env, argv, or compose
`environment`. The compose file mounts the token file read-only.

Re-run `/setup telegram` after the daemon is up. It prints daemon mode
and does not arm `watch.sh`.

---

## Move a misrouted record (CDT-528 fix)

CDT-528 spooled some topic messages into `spool/main/inbox/`. Move each
affected record by hand. This is a one-off operator step (CDT-529 Q4).
Automated migration is out of scope (SPEC-038).

Find the sid for the thread in `topics.json`, then run:

```
jq -r 'select(.thread_id==<THREAD_ID>) | input_filename' \
  ~/.claude/telegram-router/spool/main/inbox/*.json |
  xargs -r mv -t ~/.claude/telegram-router/spool/<sid>/inbox/
```

Replace `<THREAD_ID>` and `<sid>` with the real values.

---

## Troubleshooting

| Symptom | What you do |
|---------|-------------|
| Empty pairing / no private-chat sender | Send a private message to the bot, then re-run `/setup telegram`. Do not pipe Enter before the DM. The pairing wait is a 30s long-poll. |
| Unmapped topic | An unmapped or inactive thread routes to the single active session, else the Walkie-talkie (`default_session`) with one warn. Nothing is silently dropped (CDT-529). Topics off is not a failed setup. |
| 409 conflict | Another getUpdates consumer holds the offset. Stop `watch.sh` or `docker compose -p intercom stop` before probe or a second start. One consumer only. |
| Agent names a shared bot | Refuse. Create your own bot. Do not use a username from memory. |
| Token in chat | Revoke the token with BotFather. Create a new bot. Never paste the token again. |
| Wanted Topics but `topics_enabled=false` | Enable Topics in the chat, then re-run setup. Not a failed setup. |
