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
Press Enter. The script writes state under `~/.claude/telegram-router/`
(or `INTERCOM_STATE_ROOT` in tests). It never writes inside the repo.

It prints a host-aware arming block. Arm `watch.sh`, not `poller.sh`.
Use one bash-only cycle every 45 seconds. Do not print the token.

If `~/.config/telegram/bot_token` already exists, ask reuse vs replace.
Do not overwrite the file without a confirm.

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

1. Arm the host job from the printed block (`bash <plugin>/skills/intercom/watch.sh` every 45s).
2. Keep the main UI mirrored. Use `/away on` or `/afk on` when the Intercom is primary.
3. Use `/away off` when you return.
4. Phase 1 opens one session at a time for session-or-ticket topics. General still accepts walkie-talkie traffic.

---

## Troubleshooting

| Symptom | What you do |
|---------|-------------|
| Empty pairing / no private-chat sender | Send a message to the bot, then re-run `/setup telegram`. |
| Unmapped topic | Topics on: create or map the topic. Topics off: traffic stays in General. |
| 409 conflict | Another poller holds the getUpdates offset. Stop the other job. One host job only. |
| Agent names a shared bot | Refuse. Create your own bot. Do not use a username from memory. |
| Token in chat | Revoke the token with BotFather. Create a new bot. Never paste the token again. |
| Wanted Topics but `topics_enabled=false` | Enable Topics in the chat, then re-run setup. Not a failed setup. |
