# Intercom daemon image (SPEC-038 CDT-509 AC11).
# Docker Official Image alpine 3.21, index digest (Hub 2026-10-07). Never :latest.
# Operator must approve OQ1 before any docker pull. Default USER is root;
# compose sets user: ${INTERCOM_UID}:${INTERCOM_GID} (never 0).
FROM docker.io/library/alpine@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507

# util-linux flock — BusyBox flock -n is UNVERIFIED.
RUN apk add --no-cache bash jq curl util-linux ca-certificates tzdata

# Bake the shipped runtime scripts (CDT-566). Explicit per-file COPY so
# test*.sh, test-lib.sh, fixtures/, SKILL.md and docker-compose.yml never
# enter the image. Build context is skills/intercom/ (compose build.context).
COPY common.sh /app/skills/intercom/common.sh
COPY daemon.sh /app/skills/intercom/daemon.sh
COPY poller.sh /app/skills/intercom/poller.sh
COPY intercom.sh /app/skills/intercom/intercom.sh
COPY inbox-watch.sh /app/skills/intercom/inbox-watch.sh
COPY probe.sh /app/skills/intercom/probe.sh
COPY setup-telegram.sh /app/skills/intercom/setup-telegram.sh
COPY watch.sh /app/skills/intercom/watch.sh
COPY start-daemon.sh /app/skills/intercom/start-daemon.sh
