#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo "[start] OpenClaw bootstrap"
echo "=============================="

STATE_DIR="${TS_STATE_DIR:-/tmp/tailscale}"
SOCK="$STATE_DIR/tailscaled.sock"
STATE="$STATE_DIR/tailscaled.state"

mkdir -p "$STATE_DIR"

echo "[start] starting tailscaled (userspace + SOCKS5)"
tailscaled \
  --state="$STATE" \
  --socket="$SOCK" \
  --statedir="$STATE_DIR" \
  --tun=userspace-networking \
  --socks5-server=127.0.0.1:1055 \
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

echo "[start] tailscale status:"
tailscale --socket="$SOCK" status || true

echo "--------------------------------"
echo "[start] Debug checks"
echo "--------------------------------"

echo "[debug] ssh path: $(command -v ssh || echo MISSING)"
echo "[debug] nc path: $(command -v nc || echo MISSING)"

if command -v ss >/dev/null 2>&1; then
  echo "[debug] checking SOCKS port 1055"
  ss -lntp | grep ':1055' || echo "[debug] WARN: SOCKS port not detected"
else
  (echo > /dev/tcp/127.0.0.1/1055) >/dev/null 2>&1 \
    && echo "[debug] SOCKS port reachable" \
    || echo "[debug] WARN: SOCKS port not reachable"
fi

# ----------------------------------------------------------
# SSH Setup (only if env vars are provided)
# ----------------------------------------------------------

if [[ -n "${OPENCLAW_SSH_PRIVATE_KEY:-}" \
   && -n "${OPENCLAW_SSH_HOST:-}" \
   && -n "${OPENCLAW_SSH_USER:-}" ]]; then

  echo "[start] preparing SSH key for VPS access (via Tailscale SOCKS)"

  SSH_DIR="/tmp/ssh"
  KEY_FILE="$SSH_DIR/id_ed25519"
  KNOWN_HOSTS="$SSH_DIR/known_hosts"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  printf "%s\n" "$OPENCLAW_SSH_PRIVATE_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"

  echo "[start] scanning host key for $OPENCLAW_SSH_HOST"
  ssh-keyscan -T 5 -p 22 "$OPENCLAW_SSH_HOST" > "$KNOWN_HOSTS" 2>/dev/null || true

  echo "[start] testing SSH through SOCKS proxy..."
  tailscale --socket="$SOCK" ping -c 2 "$OPENCLAW_SSH_HOST" || true

  ssh -i "$KEY_FILE" \
    -o ProxyCommand='nc -x 127.0.0.1:1055 -X 5 %h %p' \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 \
    "$OPENCLAW_SSH_USER@$OPENCLAW_SSH_HOST" \
    "echo SSH_OK && hostname" || true

  export OPENCLAW_SSH_KEYFILE="$KEY_FILE"
  export OPENCLAW_SSH_KNOWN_HOSTS="$KNOWN_HOSTS"

else
  echo "[start] SSH env vars not fully set; skipping SSH setup"
fi

echo "--------------------------------"
echo "[start] launching OpenClaw"
echo "--------------------------------"

exec node src/server.js