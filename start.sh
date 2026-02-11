#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo "[start] OpenClaw bootstrap v2026-02-11-1338"
echo "=============================="

STATE_DIR="${TS_STATE_DIR:-/data/.tailscale}"
SOCK="$STATE_DIR/tailscaled.sock"
STATE="$STATE_DIR/tailscaled.state"
PIDFILE="$STATE_DIR/tailscaled.pid"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" || true

echo "[start] env check:"
echo "[start] TS_STATE_DIR=${TS_STATE_DIR:-<default>}"
echo "[start] TS_HOSTNAME=${TS_HOSTNAME:-openclaw-railway}"
echo "[start] TS_ACCEPT_DNS=${TS_ACCEPT_DNS:-false}"
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  echo "[start] TAILSCALE_AUTHKEY is set (len=${#TAILSCALE_AUTHKEY})"
else
  echo "[start] WARN: TAILSCALE_AUTHKEY is NOT set"
fi

start_tailscaled() {
  if [[ -f "$PIDFILE" ]]; then
    oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${oldpid:-}" ]] && kill -0 "$oldpid" 2>/dev/null; then
      echo "[start] tailscaled already running (pid=$oldpid)"
      return 0
    fi
  fi

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
  echo "[start] tailscaled pid=$(cat "$PIDFILE")"
}

start_tailscaled

# ---- background: tailscale up + optional SSH prep (no blocking) ----
(
  echo "[ts] waiting for tailscaled socket..."
  for i in $(seq 1 60); do
    if tailscale --socket="$SOCK" status >/dev/null 2>&1; then
      echo "[ts] tailscaled is responding"
      break
    fi
    sleep 1
  done

  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "[ts] skipping tailscale up: missing TAILSCALE_AUTHKEY"
    exit 0
  fi

  echo "[ts] running tailscale up (no --reset)"
  tailscale --socket="$SOCK" up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-openclaw-railway}" \
    --accept-dns="${TS_ACCEPT_DNS:-false}" \
    || echo "[ts] WARN: tailscale up failed (non-fatal)"

  echo "[ts] waiting for tailscale IP..."
  for i in $(seq 1 60); do
    IP="$(tailscale --socket="$SOCK" ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n "$IP" ]]; then
      echo "[ts] tailscale is up. ip=$IP"
      break
    fi
    sleep 1
  done

  echo "[ts] status (top):"
  tailscale --socket="$SOCK" status 2>/dev/null | head -n 25 || true

) &

echo "--------------------------------"
echo "[start] launching OpenClaw server (foreground)"
echo "--------------------------------"
exec node src/server.js