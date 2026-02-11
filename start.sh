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

# --- SSH setup for VPS access (from Railway env vars) ---
if [[ -n "${OPENCLAW_SSH_PRIVATE_KEY:-}" && -n "${OPENCLAW_SSH_HOST:-}" && -n "${OPENCLAW_SSH_USER:-}" ]]; then
  echo "[start] preparing SSH key for VPS access"

  SSH_DIR="/tmp/ssh"
  KEY_FILE="$SSH_DIR/id_ed25519"
  KNOWN_HOSTS="$SSH_DIR/known_hosts"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  # Write private key from env var
  printf "%s\n" "$OPENCLAW_SSH_PRIVATE_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"

  # Add host key to known_hosts (avoid interactive prompt)
  ssh-keyscan -T 5 -p 22 "$OPENCLAW_SSH_HOST" > "$KNOWN_HOSTS" 2>/dev/null || true

  # Quick connectivity test (non-fatal)
  ssh -i "$KEY_FILE" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=5 "$OPENCLAW_SSH_USER@$OPENCLAW_SSH_HOST" "echo SSH_OK && hostname" || true

  # Export helper paths for anything running in this container
  export OPENCLAW_SSH_KEYFILE="$KEY_FILE"
  export OPENCLAW_SSH_KNOWN_HOSTS="$KNOWN_HOSTS"
else
  echo "[start] SSH env vars not fully set; skipping VPS SSH setup"
fi
# --- end SSH setup ---

echo "[start] launching openclaw server"
exec node src/server.js