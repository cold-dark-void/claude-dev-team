# /away

Toggle the Telegram intercom Away mode. When away is on, the intercom becomes
the primary channel immediately; the main UI still mirrors messages. The state
is shared with [`/afk`](./afk.md) — the two names drive one toggle.

## Usage

```
/away <on|off|status>
```

| Arg | Summary |
|-----|---------|
| `on` | Turn away on |
| `off` | Turn away off |
| `status` | Report the current mode without changing it |
| (bare) | Same as `status` |

## Behavior

The command calls the intercom CLI (`skills/intercom/intercom.sh`, verb
`away`) and does no network I/O. `state/away` present means on; its content is
the epoch timestamp for the audit trail. The toggle prints `away: on` /
`away: off`.

Away ON makes the poller escalate every pending intercom question immediately
instead of waiting out the timer. The escalation sweep compares timestamps, so
an expiry missed while the poller was down fires on the next poll.

## See also

- [`/afk`](./afk.md) — alias of this command
- `skills/intercom/intercom.sh` — intercom CLI (verb `away`)
- `skills/intercom/poller.sh` — Telegram↔spool bridge; owns away escalation
