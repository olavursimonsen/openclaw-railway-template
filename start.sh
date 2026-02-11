#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo "[start] OpenClaw bootstrap"
echo "=============================="

STATE_DIR="${TS_STATE_DIR:-/data/.tailscale}"
SOCK="$STATE_DIR/tailscaled.sock"
STATE="$STATE_DIR/tailscaled.state"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" || true

echo "[start] starting tailscaled (userspace + SOCKS5)"
tailscaled \
  --state="$STATE" \
  --socket="$SOCK" \
  --statedir="$STATE_DIR" \
  --tun=userspace-networking \
  --socks5-server=127.0.0.1:1055 \
  --verbose=1 &

echo "[start] DEBUG: started tailscaled, now starting background bootstrap..."

# Run Tailscale + SSH prep in background so Railway healthcheck doesn't fail
(
  # IMPORTANT: capture background logs reliably
  exec > >(tee -a /data/ts-bootstrap.log) 2>&1

  echo "[ts] DEBUG: entered background bootstrap block"
  echo "[ts] waiting for tailscaled..."

  for i in $(seq 1 60); do
    if tailscale --socket="$SOCK" status >/dev/null 2>&1; then
      echo "[ts] tailscaled OK"
      break
    fi
    sleep 1
  done

  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "[ts] WARN: missing TAILSCALE_AUTHKEY, skipping"
    exit 0
  fi

  echo "[ts] tailscale up..."
  tailscale --socket="$SOCK" up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-openclaw-railway}" \
    --accept-dns="${TS_ACCEPT_DNS:-false}" \
    || echo "[ts] WARN: tailscale up failed (non-fatal)"

  echo "[ts] tailscale ip:"
  tailscale --socket="$SOCK" ip -4 || true

  echo "[ts] tailscale status (top):"
  tailscale --socket="$SOCK" status 2>/dev/null | head -n 25 || true

  # ----------------------------------------------------------
  # DEBUG: verify SOCKS is actually listening and usable
  # ----------------------------------------------------------
  echo "--------------------------------"
  echo "[ts] DEBUG: checking SOCKS proxy"

  echo "[ts] checking if SOCKS port 1055 is listening..."
  if command -v nc >/dev/null 2>&1; then
    nc -zv 127.0.0.1 1055 && echo "[ts] SOCKS OK" || echo "[ts] SOCKS FAIL"
  else
    echo "[ts] WARN: nc missing; cannot test SOCKS port"
  fi

  if [[ -n "${OPENCLAW_SSH_HOST:-}" && command -v nc >/dev/null 2>&1 ]]; then
    echo "[ts] testing TCP to ${OPENCLAW_SSH_HOST}:22 via SOCKS..."
    nc -x 127.0.0.1:1055 -X 5 -vz "$OPENCLAW_SSH_HOST" 22 || true
  else
    echo "[ts] OPENCLAW_SSH_HOST not set (or nc missing); skipping nc test to host"
  fi

  # ----------------------------------------------------------
  # SSH key setup
  # ----------------------------------------------------------
  if [[ -n "${OPENCLAW_SSH_PRIVATE_KEY:-}" && -n "${OPENCLAW_SSH_HOST:-}" && -n "${OPENCLAW_SSH_USER:-}" ]]; then
    echo "[ts] setting up SSH key..."

    SSH_DIR="/tmp/ssh"
    KEY_FILE="$SSH_DIR/id_ed25519"
    KNOWN_HOSTS="$SSH_DIR/known_hosts"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    printf "%s\n" "$OPENCLAW_SSH_PRIVATE_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    echo "[ts] ssh-keyscan $OPENCLAW_SSH_HOST"
    ssh-keyscan -T 5 -p 22 "$OPENCLAW_SSH_HOST" > "$KNOWN_HOSTS" 2>/dev/null || true

    echo "[ts] test ssh (via SOCKS, non-fatal):"
    ssh -i "$KEY_FILE" \
      -o ProxyCommand='nc -x 127.0.0.1:1055 -X 5 %h %p' \
      -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=10 \
      "$OPENCLAW_SSH_USER@$OPENCLAW_SSH_HOST" \
      "echo SSH_OK && hostname" || true

    echo "[ts] SSH ready (key at $KEY_FILE)"
  else
    echo "[ts] SSH vars missing; skipping ssh setup"
  fi
) &

echo "--------------------------------"
echo "[start] launching OpenClaw (foreground)"
echo "--------------------------------"
exec node src/server.js