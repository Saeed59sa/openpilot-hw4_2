#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# (c) 2025 Saeed Almansoori
set -euo pipefail
PARAMS_DIR="${PARAMS_DIR:-/data/params/d}"
mkdir -p "$PARAMS_DIR"

case "${1:-}" in
  enable)  printf "1" > "$PARAMS_DIR/EnableRemoteAccess" ;;
  disable) printf "0" > "$PARAMS_DIR/EnableRemoteAccess" ;;
  status)
    s="$(cat "$PARAMS_DIR/EnableRemoteAccess" 2>/dev/null || echo 0)"
    url="$(cat "$PARAMS_DIR/RemoteAccessLoginURL" 2>/dev/null || true)"
    ip="$(cat "$PARAMS_DIR/RemoteAccessIP" 2>/dev/null || true)"
    ts="$(cat "$PARAMS_DIR/RemoteAccessLastUpdated" 2>/dev/null || true)"
    err="$(cat "$PARAMS_DIR/RemoteAccessError" 2>/dev/null || true)"
    echo "EnableRemoteAccess=$s"
    [ -n "$url" ] && echo "LoginURL=$url" || echo "LoginURL=<empty>"
    [ -n "$ip" ] && echo "IP=$ip" || echo "IP=<unknown>"
    [ -n "$ts" ] && echo "LastUpdated=$ts" || true
    [ -n "$err" ] && echo "Error=$err" || true
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}"
    exit 2
    ;;
 esac
