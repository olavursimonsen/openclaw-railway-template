#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${TS_STATE_DIR:-/tmp/tailscale}"
SOCK="$STATE_DIR/tailscaled.sock"
STATE="$STATE_DIR/tailscaled.state"

mkdir -p "$STATE_DIR"

echo "[start] starting tailscaled (userspace)"
tailscaled \
  --state="$STATE" \
  --socket="$SOCK" \
  --statedir="$STATE_DIR" \
  --tun=userspace-networking \
  --verbose=1 &

echo "[start] waiting for tailscaled socket..."
for i in $(seq 1 60); do
  if tailscale --socket="$SOCK" status >/dev/null 2>&1; then
    echo "[start] tailscaled is responding"
    break
  fi
  sleep 1
done

echo "[start] tailscale up..."
tailscale --socket="$SOCK" up \
  --authkey="$TAILSCALE_AUTHKEY" \
  --hostname="${TS_HOSTNAME:-openclaw-railway}" \
  --accept-dns="${TS_ACCEPT_DNS:-false}" \
  --reset

echo "[start] waiting for tailscale to be online..."
for i in $(seq 1 90); do
  IP="$(tailscale --socket="$SOCK" ip -4 2>/dev/null | head -n1 || true)"
  if [[ -n "$IP" ]]; then
    echo "[start] tailscale is up. ip=$IP"
    break
  fi
  sleep 1
done

echo "[start] tailscale status (first lines):"
tailscale --socket="$SOCK" status 2>/dev/null | head -n 20 || true

echo "[start] launching openclaw server"
exec node src/server.js