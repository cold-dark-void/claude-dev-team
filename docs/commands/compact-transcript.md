# /compact-transcript

Write a short excerpt of the recent conversation that you can `@` in a new session (Meaning tail).

This Surface is not a host `/compact` replacement.
The Meaning tail is not a Compact seed and not an STM packet.
Those terms stay with [`/handoff`](./handoff.md).
This Surface does not truncate store `main.md`.

Governing spec: `specs/core/SPEC-036-transcript-mirror.md` (M14).

## Usage

```
/compact-transcript
/compact-transcript <sid>
```

| Args | Action |
|------|--------|
| _(none)_ | Use the live session id |
| `<sid>` | Use that sid as given |

A bare command writes the tail when the mirror `main.md` exists, even if the live session is still in progress or lagging. The tail is the mirror as of the cursor. It ends with `<!-- mirror cursor: <ident>, lag: N lines -->`. A named `<sid>` still requires a caught-up mirror.

Stdout is the absolute path of the Meaning tail.
You `@` that printed path.

## Write path

The file is a sibling of the sid dir:

```
~/.claude/transcript/<sid>.meaning-tail.md
```

It is not inside `~/.claude/transcript/<sid>/`.

## Bound

The tail is at most 32768 UTF-8 bytes (`wc -c`).

## Fail-closed

Miss is fail-closed.
The Surface does not create or update a tail.

`@~/.claude/transcript/<sid>/main.md` remains valid only as the full unbounded Meaning channel.
For compact `@`-attach, use this Surface.

## See also

- [`/handoff`](./handoff.md) — STM packet / Compact seed (separate Surface)
- [Transcript mirror](./transcript-mirror.md) — recorder; this is not `/transcript-mirror`
