# Fixture — bot-token :ro mount hit survives narrowing (CDT-589-C2)

## Tracking
- source: fixture
- ticket_id: C2-FIX-3
- closes:
- autopilot_on: false
- autopilot_bump: null

## Ticket class
ticket_class: auth-secrets

Word-boundary hit on "token". The scan input excludes this note and the line
above (CDT-589-C2); the hit stands on the ticket text only.

## Summary

Bake the poller into the daemon image. Copy only the shipped runtime
scripts, so test scripts and any credential bytes never enter the image
layers.

## Acceptance criteria

- A1. The compose service keeps the bot token `:ro` mount and drops the
  plugin-root bind; the token never appears in argv or logs.
- A2. The baked image runs as a non-root user with cap_drop ALL.
