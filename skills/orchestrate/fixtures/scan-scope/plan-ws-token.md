# Fixture — WS token hit survives narrowing (CDT-589-C2)

## Tracking
- source: fixture
- ticket_id: C2-FIX-2
- closes:
- autopilot_on: false
- autopilot_bump: null

## Ticket class
ticket_class: auth-secrets

Word-boundary hit on A3 "token". Record as returned. This note must not
decide a re-scan: the scan input excludes this section (CDT-589-C2), so the
hit below stands on the ticket text only.

## Summary

Stamp per-connection seq on every server frame at the pump write. A full
buffer drops the frame and coalesces one overflow write; the client
reconnects and the server replies with the connect-time snapshot.

## Acceptance criteria

- A3. In-flight token replay is bounded: the reconnect handshake carries an
  opaque renewal token, one per connection, rotated on resume.
