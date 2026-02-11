#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${TS_STATE_DIR:-/tmp/tailscale}"
mkdir -p "$STATE_DIR"

# Start tailscaled in userspace mode (works in Railway)
tailscaled --state="$STATE_DIR/tailscaled.state" --tun=userspace-networking &
sleep 2

tailscale up \
  --authkey="${TAILSCALE_AUTHKEY}" \
  --hostname="${TS_HOSTNAME:-openclaw-railway}" \
  --accept-dns="${TS_ACCEPT_DNS:-false}"

# Start original app
exec node src/server.js
