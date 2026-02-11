#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo "[start] OpenClaw bootstrap"
echo "=============================="

# Persist Tailscale state across redeploys (Railway volume)
STATE_DIR="${TS_STATE_DIR:-/data/.tailscale}"
SOCK="$STATE_DIR/tailscaled.sock"
STATE="$STATE_DIR/tailscaled.state"
PIDFILE="$STATE_DIR/tailscaled.pid"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" || true

# ----------------------------------------------------------
# Start tailscaled (userspace + SOCKS5) if not already running
# ----------------------------------------------------------
start_tailscaled() {
  # If PID exists and process is alive, reuse it
  if [[ -f "$PIDFILE" ]]; then
    local oldpid
    oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${oldpid:-}" ]] && kill -0 "$oldpid" 2>/dev/null; then
      echo "[start] tailscaled already running (pid=$oldpid)"
      return 0
    fi
  fi

  # If socket exists from a previous run, remove it to avoid confusion
  rm -f "$SOCK" || true

  echo "[start] starting tailscaled (userspace + SOCKS5)"
  tailscaled \
    --state="$STATE" \
    --socket="$SOCK" \
    --statedir="$STATE_DIR" \
    --tun=userspace-networking \
    --socks5-server=127.0.0.1:1055 \
    --verbose=1 &

  echo $! > "$PIDFILE"
}

start_tailscaled

# ----------------------------------------------------------
# Background: bring Tailscale up + prepare SSH key
# (Do NOT block web server startup / healthcheck)
# ----------------------------------------------------------
(
  echo "[ts] waiting for tailscaled to respond..."
  for i in $(seq 1 60); do
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

  echo "[ts] tailscale up... (no --reset)"
  # Important: no --reset => prevents creating a new node each deploy
  tailscale --socket="$SOCK" up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-openclaw-railway}" \
    --accept-dns="${TS_ACCEPT_DNS:-false}" || true

  echo "[ts] waiting for tailscale IP..."
  for i in $(seq 1 60); do
    IP="$(tailscale --socket="$SOCK" ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n "$IP" ]]; then
      echo "[ts] tailscale is up. ip=$IP"
      break
    fi
    sleep 1
  done

  echo "[ts] tailscale status (first lines):"
  tailscale --socket="$SOCK" status 2>/dev/null | head -n 25 || true

  # ----------------------------------------------------------
  # SSH Setup (only if env vars are provided)
  # ----------------------------------------------------------
  if [[ -n "${OPENCLAW_SSH_PRIVATE_KEY:-}" \
     && -n "${OPENCLAW_SSH_HOST:-}" \
     && -n "${OPENCLAW_SSH_USER:-}" ]]; then

    echo "[ts] preparing SSH key for VPS access (via Tailscale SOCKS)"

    # Put SSH materials on persistent disk (optional but recommended)
    SSH_DIR="/data/.ssh-openclaw"
    KEY_FILE="$SSH_DIR/id_ed25519"
    KNOWN_HOSTS="$SSH_DIR/known_hosts"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR" || true

    # Write private key from env var
    printf "%s\n" "$OPENCLAW_SSH_PRIVATE_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE" || true

    # Host key scan (non-fatal)
    echo "[ts] scanning host key for $OPENCLAW_SSH_HOST"
    ssh-keyscan -T 5 -p 22 "$OPENCLAW_SSH_HOST" > "$KNOWN_HOSTS" 2>/dev/null || true

    echo "[ts] testing SSH through SOCKS proxy (non-fatal)"
    ssh -i "$KEY_FILE" \
      -o ProxyCommand='nc -x 127.0.0.1:1055 -X 5 %h %p' \
      -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=10 \
      "$OPENCLAW_SSH_USER@$OPENCLAW_SSH_HOST" \
      "echo SSH_OK && hostname" || true

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