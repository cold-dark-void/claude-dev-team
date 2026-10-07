#!/usr/bin/env bash
# setup-telegram.sh — /setup telegram backend (SPEC-038 § /setup telegram).
# Subprocess CLI: never source it. Secrets stay CLI-only.
#
# Steps: prompt token -> 0600 token file + 0700 parent -> getMe validate
# (failure: no state beyond the token file) -> one getUpdates?timeout=30&offset=-1
# pairing call (chat id + initial offset) -> getChat topics check -> write
# config.json / topics.json / seen.tsv / state dirs / offset under the state
# root (INTERCOM_STATE_ROOT honored, AC23) -> print the host-aware arming block
# (absolute watch.sh, 45s, <= 4 KiB, token-free). Re-run with a valid config asks
# before overwriting. bash/jq/curl only (AC21); token never in argv/logs (AC4):
# every call goes through the tg_api funnel in common.sh.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "setup-telegram.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

die() {
  echo "setup-telegram: $*" >&2
  exit 1
}

ir_require_tools jq curl || exit 1

# ---- 0. re-run safety (idempotent) --------------------------------------------

root=$(ir_state_root)
cfg="$root/config.json"
if [ -f "$cfg" ] && jq -e '.schema == 1 and (.members | type == "object") and (.members | length > 0)' "$cfg" >/dev/null 2>&1; then
  echo "setup-telegram: $cfg already exists and looks valid." >&2
  printf 'Overwrite config, topics.json, seen.tsv and offset? [y/N] ' >&2
  ans=""
  IFS= read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) ;;
    *)
      echo "setup-telegram: keeping existing config — nothing changed."
      exit 0
      ;;
  esac
fi

# ---- 1. token: prompt (no echo), 0700 parent, 0600 file ------------------------

printf 'Telegram bot token (from @BotFather): ' >&2
token=""
IFS= read -rs token || die "cannot read the token from stdin"
token="${token//[[:space:]]/}"
[ -n "$token" ] || die "empty token"

tokdir="$HOME/.config/telegram"
if [ -d "$tokdir" ]; then
  # mkdir -p never tightens: an existing parent must be chmod'ed explicitly.
  chmod 700 "$tokdir" || die "cannot chmod 700 $tokdir"
fi
mkdir -m 700 -p "$tokdir" || die "cannot create $tokdir (mode 700)"
# atomic_write is tmp+rename; with the new file the mode comes from umask, so
# chmod 600 explicitly — modes are set explicitly, never via umask reliance.
if ! atomic_write "$tokdir/bot_token" printf '%s\n' "$token"; then
  die "cannot write $tokdir/bot_token"
fi
chmod 600 "$tokdir/bot_token" || die "cannot chmod 600 $tokdir/bot_token"

# ---- 2. validate via getMe (fail => no state beyond the token file) ------------

resp=$(tg_api getMe --max-time 15) || die "getMe call failed (curl rc $?) — no state written beyond the token file"
if ! jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
  desc=$(jq -r '.description // "unparseable response"' <<<"$resp")
  die "getMe rejected the token: $desc — no state written beyond the token file"
fi
bot_username=$(jq -r '.result.username // "UNKNOWN"' <<<"$resp")

# ---- 3. member name ------------------------------------------------------------

printf 'Member name [Alexander]: ' >&2
name=""
IFS= read -r name || name=""
[ -n "$name" ] || name="Alexander"

# ---- 4. pairing: one long-poll getUpdates?timeout=30&offset=-1 ------------------

echo "Now send ANY message to @${bot_username} in Telegram (private chat with the bot)." >&2
printf 'Press Enter once you have sent it: ' >&2
IFS= read -r _ || true

resp=$(tg_api "getUpdates?timeout=30&offset=-1" --max-time 45) \
  || die "pairing getUpdates failed (curl rc $?) — no state written beyond the token file"
chat_id=$(jq -r '[.result[] | select(.message.chat.type == "private")][0].message.chat.id // empty' <<<"$resp")
case "$chat_id" in
  ''|*[!0-9]*) die "no private-chat sender captured — send a message to @${bot_username} and re-run (no state beyond the token file)" ;;
esac
offset=$(jq -r '[.result[] | .update_id] | max + 1' <<<"$resp")
case "$offset" in
  ''|*[!0-9]*) die "could not derive the initial offset (max update_id + 1)" ;;
esac

# ---- 5. topics-enabled check ----------------------------------------------------
# The operator chat may be a plain private chat: topics-dependent routing is
# enabled only when getChat reports is_forum. Any doubt => false (fail-safe;
# walkie-talkie degrades to plain General delivery).

topics_enabled=false
if gc=$(tg_api "getChat?chat_id=${chat_id}" --max-time 15) \
  && jq -e '.ok == true and .result.is_forum == true' <<<"$gc" >/dev/null 2>&1; then
  topics_enabled=true
fi

# ---- 6. write state (only after every validation passed) ------------------------

if [ -d "$root" ]; then
  chmod 700 "$root" || die "cannot chmod 700 $root"
fi
mkdir -m 700 -p "$root" || die "cannot create state root $root"

statedir=$(ir_state_dir) || die "cannot create $root/state"
for bucket in inbox outbox pending answered; do
  ir_spool_dir "main" "$bucket" >/dev/null || die "cannot create spool/main/$bucket"
done

# config.json — schema 1 (SPEC-038 § State layout); v1 pins exactly one member.
atomic_write "$cfg" jq -n \
  --arg chat "$chat_id" --arg name "$name" --argjson topics "$topics_enabled" '
  {schema: 1,
   transport: "telegram",
   members: {($chat): {name: $name, role: "owner"}},
   default_session: "main",
   concise_threshold: 1024,
   escalation_timeout_s: 900,
   stale_heartbeat_s: 180,
   poll_timeout_s: 30,
   topics_enabled: $topics}' || die "cannot write $cfg"
chmod 600 "$cfg" || die "cannot chmod 600 $cfg"

atomic_write "$root/topics.json" printf '{}\n' || die "cannot write $root/topics.json"
chmod 600 "$root/topics.json" || die "cannot chmod 600 $root/topics.json"

: > "$statedir/seen.tsv"
chmod 600 "$statedir/seen.tsv" || die "cannot chmod 600 $statedir/seen.tsv"

atomic_write "$statedir/offset" printf '%s\n' "$offset" || die "cannot write $statedir/offset"
chmod 600 "$statedir/offset" || die "cannot chmod 600 $statedir/offset"

# ---- 7. host-aware arming block (token-free, ≤ 4 KiB) ---------------------------

watch="$SCRIPT_DIR/watch.sh"
[ -f "$watch" ] || echo "setup-telegram: note: $watch not found" >&2

echo "Paired: chat $chat_id ($name, owner), initial offset $offset, topics_enabled=$topics_enabled."
echo "State root: $root"
echo
echo "--- BEGIN harness schedule prompt (host-aware arming) ---"
cat <<EOF
Arm the Intercom host job on watch.sh, not poller.sh. One bash-only cycle per invocation.
Command (absolute):
  bash $watch
Cadence: every 45 seconds (30–60s allowed).

Grok: silent watcher. Run bash-only watch.sh cycles. Print only per the wake grammar (inbound or edge-triggered poller exit). Empty stdout MUST NOT start a parent turn. Do not use scheduler_create for idle.

Claude: CronCreate only if that job injects zero parent turn when watch.sh stdout is empty (exit 0). Otherwise the same silent-watcher path. CronCreate bash-only no-parent-turn is UNVERIFIED until proven on this host. CronCreate MUST NOT be the sole arming instruction.

Rules:
- watch.sh always exits 0.
- Never set INTERCOM_STATE_ROOT. Never read, pass, or print the bot token.
- One cycle per invocation. Do not loop and do not sleep between cycles.
- Do not copy poller stderr onto stdout.
- Do not re-arm. Do not open interactive confirms.
- Host crontab is forbidden.

Schedule: every 45 seconds, durable: true
EOF
echo "--- END harness schedule prompt ---"
