# Scheduled autonomous /retro --all

**Status**: PENDING

## Problem

/retro only runs when someone remembers to invoke it, so cross-session friction patterns accumulate unseen. The `--all` mode with singleton pre-filtering already exists precisely to suppress one-off noise — it just never runs on a cadence.

## Goal

A documented (and ideally scaffolded) way to run `/retro --all --auto` on a schedule (e.g. weekly cron / scheduled agent), with results delivered passively rather than requiring an interactive session.

## Implementation Notes

- Pairs with the pending `agent-notification-sink` backlog item — the sink is the natural delivery channel for scheduled retro results; consider implementing both together.
- `--auto` mode's conflict handling (manual follow-up list) needs a non-interactive destination — likely a report file under `.claude/retro/` plus a notification.
- Respect the existing Filter 2 loop-prevention and in-progress guards.

## Affects

`commands/retro.md` (report-file output mode), scheduling scaffold (docs or /init-orchestration addition), `agent-notification-sink` item.

## Effort

S-M

## Notes

Source: 2026-07-03 ideation session (idea #7).

---

*Added: 2026-07-03*
