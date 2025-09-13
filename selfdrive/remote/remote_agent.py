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
