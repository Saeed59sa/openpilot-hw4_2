#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Saeed Almansoori
#
# Remote Access — Unified one-shot patcher for SDpilot
# - Dev-only Toggle (UI) under Developer panel
# - Params registry entries (EnableRemoteAccess, RemoteAccessLoginURL, RemoteAccessQRCode, RemoteAccessIP, RemoteAccessLastUpdated, RemoteAccessError)
# - Remote agent (Python) with auto-install of Tailscale and qrcode lib; regenerates URL & QR on each enable
# - Manager registration for remote agent
# - Dev tools: remote_ctl.sh (enable/disable/status), show_url.sh (prints URL/IP and extracts QR to /tmp)
#
# Usage:
#   bash tools/remote_access_patch.sh
#
# Notes:
# - Idempotent and safe to re-run.
# - Adjust paths below if your tree differs.

set -euo pipefail

### ────────────── PATHS ──────────────
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$ROOT_DIR"
[ -d selfdrive ] || { echo "ERROR: run from repo root (selfdrive/ not found)"; exit 1; }

UI_SETTINGS_CPP="selfdrive/ui/qt/offroad/settings.cc"
PARAMS_PY="common/params.py"
PROC_CFG_PY="system/manager/process_config.py"
REMOTE_DIR="selfdrive/remote"
TOOLS_DIR="tools/remote_access"

mkdir -p "$REMOTE_DIR" "$TOOLS_DIR"

### ────────────── HELPERS ──────────────
backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.${ts}.bak"
  echo "[backup] $f -> ${f}.${ts}.bak"
}

append_once_after_anchor() {
  local file="$1" anchor="$2" token="$3" block="$4"
  if grep -Fq "$token" "$file" 2>/dev/null; then
    echo "[skip] block ($token) already present in $file"
    return
  fi
  if ! grep -Eq "$anchor" "$file"; then
    echo "[warn] anchor not found in $file — appending block at EOF."
    backup_file "$file"
    printf "\n%s\n" "$block" >> "$file"
    return
  fi
  backup_file "$file"
  awk -v a="$anchor" -v t="$token" -v b="$block" '
    BEGIN{done=0}
    {print $0}
    $0 ~ a && !done {
      print ""; print b; print ""; done=1
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  echo "[write] inserted ($token) into $file"
}

append_once_at_eof() {
  local file="$1" token="$2" block="$3"
  if grep -Fq "$token" "$file" 2>/div null; then
    echo "[skip] block ($token) already present in $file"
    return
  fi
  backup_file "$file"
  printf "\n%s\n" "$block" >> "$file"
  echo "[write] appended ($token) to $file"
}

### ────────────── PARAMS REGISTRY ──────────────
if [ -f "$PARAMS_PY" ]; then
  if ! grep -Fq "BEGIN_REMOTE_ACCESS_PARAMS" "$PARAMS_PY"; then
    backup_file "$PARAMS_PY"
    cat >> "$PARAMS_PY" <<'PY'
# BEGIN_REMOTE_ACCESS_PARAMS  # SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
# Remote Access params registry (multiple-tree compatible)
try:
  _params_types  # guard for alt registries
except NameError:
  pass

for _name, _ptype, _default in [
  ("EnableRemoteAccess", "bool",  b"0"),
  ("RemoteAccessLoginURL", "bytes", b""),
  ("RemoteAccessQRCode", "bytes", b""),
  ("RemoteAccessIP", "bytes", b""),
  ("RemoteAccessLastUpdated", "bytes", b""),
  ("RemoteAccessError", "bytes", b""),
]:
  try:
    if 'keys' in globals() and isinstance(keys, dict) and _name not in keys:
      keys[_name] = (_ptype, _default)
  except Exception:
    pass
  try:
    if '_keys' in globals() and isinstance(_keys, dict) and _name not in _keys:
      _keys[_name] = (_ptype, _default)
  except Exception:
    pass
  try:
    if '_params_types' in globals() and isinstance(_params_types, dict) and _name not in _params_types:
      _params_types[_name] = _ptype
      if '_default_values' in globals() and isinstance(_default_values, dict):
        _default_values[_name] = _default
  except Exception:
    pass
# END_REMOTE_ACCESS_PARAMS
PY
    echo "[write] Added Remote Access params to $PARAMS_PY"
  else
    echo "[skip] Params already present."
  fi
else
  echo "[warn] $PARAMS_PY not found; skipping params registry patch."
fi

### ────────────── REMOTE AGENT (Python) ──────────────
cat > "$REMOTE_DIR/remote_agent.py" <<'PY'
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Saeed Almansoori
"""
Remote Access Agent (daemon)
- Watches EnableRemoteAccess
- Ensures tailscale + daemon, runs `tailscale up --ssh --reset` on each enable
- Captures login URL into RemoteAccessLoginURL
- Generates QR PNG (qrcode lib; auto-installs if missing) into RemoteAccessQRCode
- Stores Device IP (local/public) into RemoteAccessIP
- Sets RemoteAccessLastUpdated ISO8601 timestamp
- Clears all on disable
"""
import os, re, subprocess, time, shlex, pathlib, sys, base64, datetime

PARAMS_DIR = os.environ.get("PARAMS_DIR", "/data/params/d")
P_ENABLE = "EnableRemoteAccess"
P_URL    = "RemoteAccessLoginURL"
P_QR     = "RemoteAccessQRCode"
P_IP     = "RemoteAccessIP"
P_TS     = "RemoteAccessLastUpdated"
P_ERR    = "RemoteAccessError"

def ppath(name): return os.path.join(PARAMS_DIR, name)
def read_param(name, default=b""):
  try:
    with open(ppath(name), "rb") as f: return f.read()
  except Exception:
    return default
def write_param(name, data: bytes):
  pathlib.Path(PARAMS_DIR).mkdir(parents=True, exist_ok=True)
  with open(ppath(name), "wb") as f: f.write(data)
def clear_param(name): 
  try: os.remove(ppath(name))
  except FileNotFoundError: pass
  except Exception: pass

def shell(cmd, capture=False, timeout=8):
  try:
    if capture:
      p = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
      return p.stdout
    return subprocess.run(cmd, shell=True, check=False, timeout=timeout)
  except subprocess.TimeoutExpired as e:
    return e.stdout if capture else None

def ensure_tailscale():
  if subprocess.call("command -v tailscale >/dev/null 2>&1", shell=True) != 0:
    shell("curl -fsSL https://tailscale.com/install.sh | sh")
  shell("pgrep -x tailscaled >/dev/null || nohup tailscaled >/dev/null 2>&1 &")

def extract_login_url(s: str) -> str:
  m = re.search(r'https?://\S+', s or "")
  return m.group(0) if m else ""

def ensure_qrcode_lib():
  try:
    import qrcode  # noqa: F401
    from PIL import Image  # noqa: F401
    return True
  except Exception:
    shell("python3 -m pip install --disable-pip-version-check -q qrcode[pil]")
    try:
      import qrcode  # noqa: F401
      from PIL import Image  # noqa: F401
      return True
    except Exception:
      return False

def gen_qr_png_bytes(data: str) -> bytes:
  if not data:
    return b""
  ok = ensure_qrcode_lib()
  if not ok:
    return b""
  import qrcode
  qr = qrcode.QRCode(border=2, box_size=6)
  qr.add_data(data)
  qr.make(fit=True)
  img = qr.make_image(fill_color="black", back_color="white")
  from io import BytesIO
  bio = BytesIO()
  img.save(bio, format="PNG")
  return bio.getvalue()

def get_ips() -> str:
  def get_ip_cmd(dev):
    out = shell(f"ip -4 addr show {dev} 2>/dev/null | awk '/inet /{{print $2}}' | cut -d/ -f1", capture=True)
    return (out or "").strip()
  wlan = get_ip_cmd("wlan0")
  eth  = get_ip_cmd("eth0")
  pub  = (shell("curl -s --max-time 3 https://ifconfig.me 2>/dev/null", capture=True) or "").strip()
  parts = []
  if wlan: parts.append(f"wlan0:{wlan}")
  if eth:  parts.append(f"eth0:{eth}")
  if pub:  parts.append(f"public:{pub}")
  return " | ".join(parts)

def bring_up():
  ensure_tailscale()
  out = shell("tailscale up --ssh --reset 2>&1 || true", capture=True)
  url = extract_login_url(out)
  if not url:
    st = shell("tailscale status 2>&1 || true", capture=True)
    url = extract_login_url(st) or ""
  write_param(P_URL, url.encode())
  write_param(P_QR, gen_qr_png_bytes(url))
  write_param(P_IP, get_ips().encode())
  write_param(P_TS, datetime.datetime.utcnow().isoformat().encode())
  write_param(P_ERR, b"")

def bring_down():
  shell("tailscale down >/dev/null 2>&1 || true")
  for k in (P_URL, P_QR, P_IP, P_TS, P_ERR):
    clear_param(k)

def main():
  last = None
  while True:
    en = read_param(P_ENABLE, b"0") == b"1"
    if en != last:
      try:
        if en: bring_up()
        else:  bring_down()
      except Exception as e:
        write_param(P_ERR, str(e).encode())
      last = en
    time.sleep(2)

if __name__ == "__main__":
  try:
    main()
  except KeyboardInterrupt:
    sys.exit(0)
PY
echo "[write] $REMOTE_DIR/remote_agent.py"

### ────────────── MANAGER REGISTRATION ──────────────
if [ -f "$PROC_CFG_PY" ]; then
  if ! grep -Fq "BEGIN_REMOTE_ACCESS_MANAGER" "$PROC_CFG_PY"; then
    backup_file "$PROC_CFG_PY"
    cat >> "$PROC_CFG_PY" <<'PY'

# BEGIN_REMOTE_ACCESS_MANAGER  # SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
try:
  from system.manager.process_config import managed_processes  # guard for alt trees
except Exception:
  pass

try:
  if isinstance(managed_processes, dict) and "remoteAgent" not in managed_processes:
    managed_processes["remoteAgent"] = {
      "proc": ["python3", "selfdrive/remote/remote_agent.py"],
      "enable": True,
      "sigkill": True,
    }
except Exception:
  pass
# END_REMOTE_ACCESS_MANAGER
PY
    echo "[write] Patched manager process config."
  else
    echo "[skip] Manager already patched."
  fi
else
  echo "[warn] $PROC_CFG_PY not found; skipping manager patch."
fi

### ────────────── UI: DEV-ONLY TOGGLE ──────────────
if [ -f "$UI_SETTINGS_CPP" ]; then
  if ! grep -Fq "BEGIN_REMOTE_ACCESS_DEV_TOGGLE" "$UI_SETTINGS_CPP"; then
    backup_file "$UI_SETTINGS_CPP"
    cat >> "$UI_SETTINGS_CPP" <<'CPP'

// BEGIN_REMOTE_ACCESS_DEV_TOGGLE  // SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
#include "selfdrive/common/params.h"

class RemoteAccessDevToggle final : public QWidget {
  Q_OBJECT
public:
  explicit RemoteAccessDevToggle(QWidget *parent=nullptr) : QWidget(parent) {
    auto *lay = new QVBoxLayout(this);
    auto *toggle = new ParamControl("EnableRemoteAccess",
                                    tr("Remote Access"),
                                    tr("Enable secure remote access for support/maintenance."), "");
    lay->addWidget(toggle);
    lay->addStretch(1);
  }
};
// END_REMOTE_ACCESS_DEV_TOGGLE
CPP
    echo "[write] Appended RemoteAccessDevToggle class."
  else
    echo "[skip] Dev toggle class already exists."
  fi

  if grep -Fq "class DeveloperPanel" "$UI_SETTINGS_CPP"; then
    if ! grep -Fq "new RemoteAccessDevToggle" "$UI_SETTINGS_CPP"; then
      append_once_after_anchor "$UI_SETTINGS_CPP" "class DeveloperPanel" "REMOTE_ACCESS_DEV_TOGGLE_INJECT" $'  // REMOTE_ACCESS_DEV_TOGGLE_INJECT\n  layout->addWidget(new RemoteAccessDevToggle(this));'
    else
      echo "[skip] RemoteAccessDevToggle already added to Developer panel."
    fi
  else
    cat <<'MSG'
[note] Could not locate DeveloperPanel in settings.cc.
Please add manually inside Developer panel layout:
  layout->addWidget(new RemoteAccessDevToggle(this));  // Remote Access (dev-only)
MSG
  fi
else
  echo "[warn] $UI_SETTINGS_CPP not found; UI dev toggle not injected."
fi

### ────────────── DEV TOOLS ──────────────
cat > "$TOOLS_DIR/remote_ctl.sh" <<'SH'
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
SH
chmod +x "$TOOLS_DIR/remote_ctl.sh"
echo "[write] $TOOLS_DIR/remote_ctl.sh"

cat > "$TOOLS_DIR/show_url.sh" <<'SH'
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
SH
chmod +x "$TOOLS_DIR/show_url.sh"
echo "[write] $TOOLS_DIR/show_url.sh"

### ────────────── DONE ──────────────
echo "✅ Remote Access (dev-only toggle) patch applied."
echo "- Build the UI; in Developer panel you'll see: Remote Access toggle."
echo "- Backend will generate URL + QR + IP on enable (stored in params)."
echo "- Dev tools:"
echo "    tools/remote_access/remote_ctl.sh enable|status|disable"
echo "    tools/remote_access/show_url.sh [/tmp/remote_access_qr.png]"
