#!/usr/bin/env bash
# build.sh — the node agent's build entry (CDT-644).
#
# Builds control-plane/cmd/node-agent for the three phase-0 targets
# (docs/internal/control-plane/node-agent-build-probe.md § AC-8) inside the
# G-02-approved Go image, digest-pinned:
#
#   docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
#
# The maintainer approved this image for the build on 2026-11-17 — official
# Docker Library golang, digest-pinned. The container runs as the host user
# (--user), so the build outputs land on the mounted worktree owned by the
# host user, not root. The image compiles the binary; the binary itself has no
# Docker dependency in the contract, the code, or the build.
#
# GOCACHE, GOMODCACHE, and HOME live outside the mount (/tmp in the
# container), so no build cache lands on the worktree. Artifacts land in
# control-plane/dist/ (git-ignored), one binary per target:
#
#   node-agent-linux-amd64    the development machine (built and started on
#                             the host in the phase-0 probe)
#   node-agent-linux-arm64    the DGX Spark (built, not run here)
#   node-agent-darwin-arm64   the Mac (built, not run here)
#
# Usage: bash control-plane/build.sh [target ...]
#   target is one of: linux-amd64, linux-arm64, darwin-arm64. No argument
#   builds all three.

set -euo pipefail

IMAGE='docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea'

die() {
  printf 'error: %s\n' "$*" >&2
  exit 64
}

cd "$(dirname -- "$0")"
ROOT=$(CDPATH= cd -- .. && pwd)
DIST="$ROOT/control-plane/dist"
mkdir -p "$DIST"

# target os:arch pairs, in the phase-0 order.
TARGETS="linux-amd64 linux-arm64 darwin-arm64"
if [ "$#" -gt 0 ]; then
  TARGETS="$*"
fi

for target in $TARGETS; do
  os=${target%%-*}
  arch=${target#*-}
  out="dist/node-agent-$target"
  printf 'building %s...\n' "$target"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp/gohome \
    -v "$ROOT":/src -w /src/control-plane \
    -e GOOS="$os" -e GOARCH="$arch" -e CGO_ENABLED=0 \
    -e GOCACHE=/tmp/gocache -e GOMODCACHE=/tmp/gomodcache \
    -e GOFLAGS=-buildvcs=false \
    "$IMAGE" \
    go build -o "$out" ./cmd/node-agent
done

printf '\nbuilt:\n'
ls -l "$DIST"
