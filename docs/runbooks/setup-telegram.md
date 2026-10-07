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

It prints a host-aware block. Two modes:

- Daemon up (fresh heartbeat AND compose project `intercom` running):
  the script prints daemon mode. Do not arm `watch.sh`.
- Otherwise: arm `watch.sh`, not `poller.sh`. Use one bash-only cycle
  every 45 seconds.

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

`probe.sh` is the operator pre-deploy gate. It must pass every SPEC-038
§ Verified-vs-assumed behavior before you start the daemon. Suites never
run it.

Stop the daemon first. A second getUpdates consumer returns 409.

```
docker compose -p intercom stop
bash <plugin>/skills/intercom/probe.sh
```

### First start

From the plugin root, after pairing and after probe passes:

```
export INTERCOM_UID=$(id -u)
export INTERCOM_GID=$(id -g)
export INTERCOM_TOKEN_FILE="$HOME/.config/telegram/bot_token"
export INTERCOM_STATE_DIR="$HOME/.claude/telegram-router"
export INTERCOM_PLUGIN_ROOT="<plugin-root>"
docker compose -p intercom -f skills/intercom/docker-compose.yml up -d --build
```

Never put the token in env, argv, or compose `environment`. The compose
file mounts the token file read-only.

Re-run `/setup telegram` after the daemon is up. It prints daemon mode
and does not arm `watch.sh`.

---

## Troubleshooting

| Symptom | What you do |
|---------|-------------|
| Empty pairing / no private-chat sender | Send a private message to the bot, then re-run `/setup telegram`. Do not pipe Enter before the DM. The pairing wait is a 30s long-poll. |
| Unmapped topic | Empty map or only General: traffic stays in the Walkie-talkie (`default_session`). Session topics already mapped: an unknown thread is dropped. Topics off is not a failed setup. |
| 409 conflict | Another getUpdates consumer holds the offset. Stop `watch.sh` or `docker compose -p intercom stop` before probe or a second start. One consumer only. |
| Agent names a shared bot | Refuse. Create your own bot. Do not use a username from memory. |
| Token in chat | Revoke the token with BotFather. Create a new bot. Never paste the token again. |
| Wanted Topics but `topics_enabled=false` | Enable Topics in the chat, then re-run setup. Not a failed setup. |
