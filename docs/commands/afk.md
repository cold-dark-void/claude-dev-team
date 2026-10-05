# /afk

Alias of [`/away`](./away.md). Toggle the Telegram intercom Away mode. When
away is on, the intercom becomes the primary channel immediately; the main UI
still mirrors messages.

## Usage

```
/afk <on|off|status>
```

| Arg | Summary |
|-----|---------|
| `on` | Turn away on |
| `off` | Turn away off |
| `status` | Report the current mode without changing it |
| (bare) | Same as `status` |

## Behavior

`/afk` delegates to the intercom CLI verb `away`
(`skills/intercom/intercom.sh`). The state is one file (`state/away`), so both
names see the same toggle. See [`/away`](./away.md) for the full behavior.

## See also

- [`/away`](./away.md) — the primary surface
- `skills/intercom/intercom.sh` — intercom CLI (verb `away`)
