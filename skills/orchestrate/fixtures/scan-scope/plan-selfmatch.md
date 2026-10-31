# Fixture — self-match removed on re-scan (CDT-589-C2)

## Tracking
- source: fixture
- ticket_id: C2-FIX-1
- closes:
- autopilot_on: false
- autopilot_bump: null

## Ticket class
ticket_class: auth-secrets

Word-boundary hits on "auth" and "session" in this note only. The old
contract fed the whole plan text (this section included) to the classifier,
so every re-scan re-triggered on the plan's own record. The CDT-589-C2
re-scan input excludes this section.

## Summary

Add a retry budget to the export worker. A stalled drain drops the batch and
sends one overflow frame; the client reconnects with the stored cursor.

## Acceptance criteria

- A1. A stalled drain drops at most one batch per drain cycle.
- A2. Reconnect sends the stored offset, not a replay.
