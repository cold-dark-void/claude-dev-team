# Intercom daemon image (SPEC-038 CDT-509 AC11).
# Docker Official Image alpine 3.21, index digest (Hub 2026-10-07). Never :latest.
# Operator must approve OQ1 before any docker pull. Default USER is root;
# compose sets user: ${INTERCOM_UID}:${INTERCOM_GID} (never 0).
FROM docker.io/library/alpine@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507

# util-linux flock — BusyBox flock -n is UNVERIFIED.
RUN apk add --no-cache bash jq curl util-linux ca-certificates tzdata

# Bake the shipped runtime scripts (CDT-566). Explicit per-file COPY so
# test*.sh, test-lib.sh, fixtures/, SKILL.md and docker-compose.yml never
# enter the image. Build context is the plugin root (compose build.context:
# ..) so the runtime's one external helper — skills/lib/portable.sh, sourced
# by common.sh as ../lib/portable.sh — can ride along.
COPY skills/intercom/common.sh /app/skills/intercom/common.sh
COPY skills/intercom/daemon.sh /app/skills/intercom/daemon.sh
COPY skills/intercom/poller.sh /app/skills/intercom/poller.sh
COPY skills/intercom/intercom.sh /app/skills/intercom/intercom.sh
COPY skills/intercom/inbox-sidecar.sh /app/skills/intercom/inbox-sidecar.sh
COPY skills/intercom/inbox-watch.sh /app/skills/intercom/inbox-watch.sh
COPY skills/intercom/probe.sh /app/skills/intercom/probe.sh
COPY skills/intercom/setup-telegram.sh /app/skills/intercom/setup-telegram.sh
COPY skills/intercom/watch.sh /app/skills/intercom/watch.sh
COPY skills/intercom/start-daemon.sh /app/skills/intercom/start-daemon.sh
COPY skills/lib/portable.sh /app/skills/lib/portable.sh
