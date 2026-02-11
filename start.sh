#!/usr/bin/env bash
set -euo pipefail

echo "[start] start.sh running"
echo "[start] whoami=$(whoami) uid=$(id -u) gid=$(id -g)"
echo "[start] uname=$(uname -a)"
echo "[start] env (filtered):"
env | grep -E '^(TAILSCALE_|TS_)' || true

STATE_DIR="${TS_STATE_DIR:-/tmp/tailscale}"
mkdir -p "$STATE_DIR"

echo "[start] starting tailscaled (userspace)"
tailscaled \
  --state="$STATE_DIR/tailscaled.state" \
  --socket="$STATE_DIR/tailscaled.sock" \
  --tun=userspace-networking \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1056 \
  --verbose=2 &

echo "[start] waiting for tailscaled to be ready..."
for i in $(seq 1 45); do
  if tailscale --socket="$STATE_DIR/tailscaled.sock" status >/dev/null 2>&1; then
    echo "[start] tailscaled is ready"
    break
  fi
  sleep 1
done

echo "[start] running tailscale up"
tailscale --socket="$STATE_DIR/tailscaled.sock" up \
  --authkey="${TAILSCALE_AUTHKEY}" \
  --hostname="${TS_HOSTNAME:-openclaw-railway}" \
  --accept-dns="${TS_ACCEPT_DNS:-false}" \
  --reset

echo "[start] tailscale status:"
tailscale --socket="$STATE_DIR/tailscaled.sock" status || true
tailscale --socket="$STATE_DIR/tailscaled.sock" ip -4 || true

echo "[start] launching openclaw server"
exec node src/server.js