#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# (c) 2025 Saeed Almansoori
set -euo pipefail
PARAMS_DIR="${PARAMS_DIR:-/data/params/d}"
QR_OUT="${1:-/tmp/remote_access_qr.png}"

url="$(cat "$PARAMS_DIR/RemoteAccessLoginURL" 2>/dev/null || true)"
ip="$(cat "$PARAMS_DIR/RemoteAccessIP" 2>/dev/null || true)"
qr_bytes="$(cat "$PARAMS_DIR/RemoteAccessQRCode" 2>/dev/null || true)"

echo "LoginURL: ${url:-<empty>}"
echo "IP: ${ip:-<unknown>}"

if [ -n "$qr_bytes" ]; then
  printf "%s" "$qr_bytes" > "$QR_OUT"
  if head -c 8 "$QR_OUT" | xxd -p | grep -qi '^89504e470d0a1a0a$'; then
    echo "QR PNG saved to: $QR_OUT"
  else
    echo "Note: QR data not PNG or corrupted."
    rm -f "$QR_OUT" || true
  fi
else
  echo "QR: <empty>"
fi
