#!/bin/bash
# =============================================================================
# SDpilot Remote Access - One Shot Setup
# Author: Saeed Almansoori
# License: MIT (International)
# =============================================================================
# Purpose:
# - Install and configure Tailscale for remote access on SDpilot devices.
# - Provide two CLIs: `sdremote` (control) and `sdremote-daemon` (watcher).
# - Create a systemd service `sdremote.service`.
# - Persist state in /data/params/d without interactive prompts.
# Notes:
# - Idempotent: safe to run multiple times.
# - Defaults to disabled (RemoteAccessEnabled=0).
# =============================================================================

set -euo pipefail

# ---------- Logging ----------
log()  { printf '[SDREMOTE] %s\n' "$*"; }
fail() { printf '[SDREMOTE][ERROR] %s\n' "$*" >&2; exit 1; }

# ---------- Paths / Params ----------
PARAMS_DIR="/data/params/d"
ENABLED_PARAM="${PARAMS_DIR}/RemoteAccessEnabled"   # "1" enable / "0" disable
STATUS_PARAM="${PARAMS_DIR}/RemoteAccessStatus"     # Ready / NeedsLogin / Offline / Initializing / Error
LOGIN_URL_PARAM="${PARAMS_DIR}/RemoteAccessLoginURL"
TS_IPS_PARAM="${PARAMS_DIR}/RemoteAccessIPs"
MARK_FILE="/data/openpilot/remote_access_installed"

BIN_DIR="/usr/local/bin"
CTL_BIN="${BIN_DIR}/sdremote"
DAEMON_BIN="${BIN_DIR}/sdremote-daemon"

SERVICE_FILE="/etc/systemd/system/sdremote.service"

# ---------- Helpers ----------
retry() { # retry <attempts> <sleep> <cmd...>
  local attempts=$1; shift
  local sleep_s=$1; shift
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@"; then return 0; fi
    log "Attempt $i/$attempts failed, retrying in ${sleep_s}s: $*"
    sleep "$sleep_s"
  done
  return 1
}

apt_update_once() {
  DEBIAN_FRONTEND=noninteractive retry 2 3 sudo apt-get update -y >/dev/null
}

apt_install() { # apt_install <pkgs...>
  DEBIAN_FRONTEND=noninteractive retry 2 3 sudo apt-get install -y "$@" >/dev/null
}

# ---------- 1) Install dependencies (tailscale + optional inotify-tools) ----------
install_deps() {
  log "Installing dependencies"
  if ! command -v tailscale >/dev/null 2>&1; then
    apt_update_once
    if ! apt-cache show tailscale >/dev/null 2>&1; then
      . /etc/os-release || true
      local CODENAME="${VERSION_CODENAME:-focal}"
      log "Adding Tailscale repo for ${CODENAME}"
      retry 2 3 curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.gpg" | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main" | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
      apt_update_once
    fi
    apt_install tailscale || fail "Failed to install tailscale"
  else
    log "tailscale already present"
  fi

  if ! command -v inotifywait >/dev/null 2>&1; then
    apt_update_once || true
    apt_install inotify-tools || log "inotify-tools unavailable; daemon will use polling"
  fi
}

# ---------- 2) Install CLIs (sdremote, sdremote-daemon) ----------
install_binaries() {
  log "Installing CLIs"
  sudo mkdir -p "$BIN_DIR"
  sudo mkdir -p "$PARAMS_DIR"
  sudo touch "$ENABLED_PARAM" "$STATUS_PARAM" "$LOGIN_URL_PARAM" "$TS_IPS_PARAM"
  sudo chmod 666 "$ENABLED_PARAM" "$STATUS_PARAM" "$LOGIN_URL_PARAM" "$TS_IPS_PARAM" || true

  # sdremote (control CLI)
  sudo tee "$CTL_BIN" >/dev/null <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

PARAMS_DIR="/data/params/d"
ENABLED_PARAM="${PARAMS_DIR}/RemoteAccessEnabled"
STATUS_PARAM="${PARAMS_DIR}/RemoteAccessStatus"
LOGIN_URL_PARAM="${PARAMS_DIR}/RemoteAccessLoginURL"
TS_IPS_PARAM="${PARAMS_DIR}/RemoteAccessIPs"

wp(){ printf "%s" "$2" > "$1"; }
rp(){ [ -f "$1" ] && cat "$1" || echo ""; }

cmd="${1:-help}"

case "$cmd" in
  enable)  wp "$ENABLED_PARAM" "1"; systemctl restart sdremote.service || true; echo "ENABLED";;
  disable) wp "$ENABLED_PARAM" "0"; systemctl restart sdremote.service || true; echo "DISABLED";;
  status)  echo "Service: $(systemctl is-active sdremote.service 2>/dev/null || echo inactive)"
           echo "Status:  $(rp "$STATUS_PARAM")"
           echo "URL:     $(rp "$LOGIN_URL_PARAM")"
           echo "IPs:     $(rp "$TS_IPS_PARAM")";;
  login)   tailscale logout >/dev/null 2>&1 || true
           OUT="$(tailscale up --reset --accept-dns=false --accept-routes=false --operator=root 2>&1 || true)"
           URL="$(echo "$OUT" | grep -Eo '(https?://[^ ]+)' | head -n1 || true)"
           [ -n "$URL" ] && wp "$LOGIN_URL_PARAM" "$URL"
           echo "${URL:-"(no URL parsed)"}";;
  qr)      tailscale logout >/dev/null 2>&1 || true
           tailscale up --reset --accept-dns=false --accept-routes=false --operator=root --qr || true;;
  ip)      tailscale ip -4 -6 || true;;
  down)    tailscale down || true;;
  *)       cat <<USAGE
sdremote <command>
  enable|disable|status|login|qr|ip|down
USAGE
           ;;
esac
EOS
  sudo chmod +x "$CTL_BIN"

  # sdremote-daemon (watcher)
  sudo tee "$DAEMON_BIN" >/dev/null <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

PARAMS_DIR="/data/params/d"
ENABLED_PARAM="${PARAMS_DIR}/RemoteAccessEnabled"
STATUS_PARAM="${PARAMS_DIR}/RemoteAccessStatus"
LOGIN_URL_PARAM="${PARAMS_DIR}/RemoteAccessLoginURL"
TS_IPS_PARAM="${PARAMS_DIR}/RemoteAccessIPs"

s_status(){ printf "%s" "$1" > "$STATUS_PARAM"; }
s_url(){    printf "%s" "$1" > "$LOGIN_URL_PARAM"; }
s_ips(){    printf "%s" "$1" > "$TS_IPS_PARAM"; }

ensure_ts() {
  systemctl is-active tailscaled >/dev/null 2>&1 || {
    systemctl enable tailscaled >/dev/null 2>&1 || true
    systemctl start tailscaled
    sleep 1
  }
}

bring_up() {
  ensure_ts
  tailscale status >/dev/null 2>&1 || \
    tailscale up --accept-dns=false --accept-routes=false --operator=root >/dev/null 2>&1 || true
}

main() {
  s_status "Initializing"
  ensure_ts
  while true; do
    EN="$(cat "$ENABLED_PARAM" 2>/dev/null || echo 0)"
    if [ "$EN" = "1" ]; then
      bring_up
      if tailscale status >/dev/null 2>&1; then
        IPs="$(tailscale ip -4 -6 2>/dev/null | xargs | tr ' ' ',')"
        [ -n "$IPs" ] && s_ips "$IPs"
        s_status "Ready"
        : > "$LOGIN_URL_PARAM" || true
      else
        s_status "NeedsLogin"
        if [ ! -s "$LOGIN_URL_PARAM" ]; then
          OUT="$(tailscale up --reset --accept-dns=false --accept-routes=false --operator=root 2>&1 || true)"
          URL="$(echo "$OUT" | grep -Eo '(https?://[^ ]+)' | head -n1 || true)"
          [ -n "$URL" ] && s_url "$URL"
        fi
      fi
    else
      tailscale down >/dev/null 2>&1 || true
      s_status "Offline"
      s_ips ""
    fi

    if command -v inotifywait >/dev/null 2>&1; then
      inotifywait -q -t 3 -e modify,close_write,move,create,delete "$ENABLED_PARAM" "$LOGIN_URL_PARAM" >/dev/null 2>&1 || sleep 2
    else
      sleep 3
    fi
  done
}
main
EOS
  sudo chmod +x "$DAEMON_BIN"
}

# ---------- 3) Install systemd service ----------
install_service() {
  log "Installing systemd service"
  sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=SDpilot Remote Access Controller
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=${DAEMON_BIN}
Restart=always
RestartSec=2
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable tailscaled >/dev/null 2>&1 || true
  sudo systemctl start  tailscaled || true
  sudo systemctl enable sdremote.service
  sudo systemctl restart sdremote.service
}

# ---------- 4) Bootstrap params ----------
bootstrap_params() {
  log "Bootstrapping params"
  [ -s "$ENABLED_PARAM" ] || echo "0" | sudo tee "$ENABLED_PARAM" >/dev/null
  sudo touch "$MARK_FILE" || true
}

# ---------- 5) Health check (optional, non-fatal) ----------
health_check() {
  log "Health check"
  systemctl is-active sdremote.service >/dev/null && log "sdremote.service active" || log "sdremote.service inactive"
  command -v tailscale >/dev/null 2>&1 && log "tailscale OK" || log "tailscale missing"
}

# ---------- Execute ----------
install_deps
install_binaries
install_service
bootstrap_params
health_check

log "Done."
echo "Usage:"
echo "  sdremote enable | disable | status | login | qr | ip | down"
