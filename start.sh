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

# ----------------------------------------------------------
# Background: bring Tailscale up + prepare SSH key
# (Do NOT block web server startup / healthcheck)
# ----------------------------------------------------------
(
  echo "[ts] waiting for tailscaled socket..."
  for i in $(seq 1 30); do
    if tailscale --socket="$SOCK" status >/dev/null 2>&1; then
      echo "[ts] tailscaled is responding"
      break
    fi
    sleep 1
  done

  # If authkey isn't set, don't spam logs forever
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "[ts] WARN: TAILSCALE_AUTHKEY not set; skipping tailscale up"
    exit 0
  fi

  echo "[ts] tailscale up..."
  tailscale --socket="$SOCK" up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-openclaw-railway}" \
    --accept-dns="${TS_ACCEPT_DNS:-false}" \
    --reset || true

  echo "[ts] waiting for tailscale to be online..."
  for i in $(seq 1 30); do
    IP="$(tailscale --socket="$SOCK" ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n "$IP" ]]; then
      echo "[ts] tailscale is up. ip=$IP"
      break
    fi
    sleep 1
  done

  echo "[ts] tailscale status (first lines):"
  tailscale --socket="$SOCK" status 2>/dev/null | head -n 20 || true

  echo "--------------------------------"
  echo "[ts] Debug checks"
  echo "--------------------------------"
  echo "[ts][debug] ssh path: $(command -v ssh || echo MISSING)"
  echo "[ts][debug] nc path: $(command -v nc || echo MISSING)"

  if command -v ss >/dev/null 2>&1; then
    echo "[ts][debug] checking SOCKS port 1055"
    ss -lntp 2>/dev/null | grep ':1055' || echo "[ts][debug] WARN: SOCKS port not detected"
  else
    (echo > /dev/tcp/127.0.0.1/1055) >/dev/null 2>&1 \
      && echo "[ts][debug] SOCKS port reachable" \
      || echo "[ts][debug] WARN: SOCKS port not reachable"
  fi

  # ----------------------------------------------------------
  # SSH Setup (only if env vars are provided)
  # ----------------------------------------------------------
  if [[ -n "${OPENCLAW_SSH_PRIVATE_KEY:-}" \
     && -n "${OPENCLAW_SSH_HOST:-}" \
     && -n "${OPENCLAW_SSH_USER:-}" ]]; then

    echo "[ts] preparing SSH key for VPS access (via Tailscale SOCKS)"

    SSH_DIR="/tmp/ssh"
    KEY_FILE="$SSH_DIR/id_ed25519"
    KNOWN_HOSTS="$SSH_DIR/known_hosts"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Write private key from env var
    printf "%s\n" "$OPENCLAW_SSH_PRIVATE_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    echo "[ts] scanning host key for $OPENCLAW_SSH_HOST"
    ssh-keyscan -T 5 -p 22 "$OPENCLAW_SSH_HOST" > "$KNOWN_HOSTS" 2>/dev/null || true

    echo "[ts] tailscale ping to $OPENCLAW_SSH_HOST (non-fatal)"
    tailscale --socket="$SOCK" ping -c 2 "$OPENCLAW_SSH_HOST" || true

    echo "[ts] testing SSH through SOCKS proxy (non-fatal)"
    ssh -i "$KEY_FILE" \
      -o ProxyCommand='nc -x 127.0.0.1:1055 -X 5 %h %p' \
      -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=5 \
      "$OPENCLAW_SSH_USER@$OPENCLAW_SSH_HOST" \
      "echo SSH_OK && hostname" || true

    # Export helper paths (best-effort; note: exports here won't affect parent process)
    echo "[ts] SSH key prepared at $KEY_FILE"
  else
    echo "[ts] SSH env vars not fully set; skipping SSH setup"
  fi
) &

echo "--------------------------------"
echo "[start] launching OpenClaw server (foreground)"
echo "--------------------------------"

# IMPORTANT: start the HTTP server immediately so Railway healthcheck passes
exec node src/server.js