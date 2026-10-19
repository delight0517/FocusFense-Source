import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid


ISSUER = os.environ["AMO_JWT_ISSUER"]
SECRET = os.environ["AMO_JWT_SECRET"]
ADDON_ID = os.environ.get("AMO_ADDON_ID", "sixvpn-blocker@sixvpnblocker.app")
VERSION = os.environ.get("AMO_ADDON_VERSION", "1.0.15")
OUT_PATH = sys.argv[1]


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_jwt() -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": ISSUER, "jti": str(uuid.uuid4()), "iat": now, "exp": now + 60}
    h = b64url(json.dumps(header, separators=(",", ":")).encode())
    p = b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(SECRET.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{b64url(sig)}"


def request_json(url: str) -> dict:
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"JWT {make_jwt()}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def download(url: str) -> bytes:
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"JWT {make_jwt()}")
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def main() -> int:
    status_url = (
        f"https://addons.mozilla.org/api/v5/addons/addon/{ADDON_ID}/"
        f"versions/{VERSION}/"
    )
    try:
        data = request_json(status_url)
    except urllib.error.HTTPError as exc:
        print(f"HTTP_ERROR {exc.code}: {exc.read().decode(errors='replace')[:500]}")
        return 2

    file_info = data.get("file") or {}
    signed = bool(file_info.get("is_mozilla_signed_extension"))
    status = file_info.get("status")
    print(f"status={status} signed={signed} version={VERSION}")
    url = file_info.get("url")
    if not signed and status != "public":
        return 1
    if not url:
        print("READY_BUT_NO_DOWNLOAD_URL")
        return 3

    content = download(url)
    with open(OUT_PATH, "wb") as out:
        out.write(content)
    print(f"DOWNLOADED {OUT_PATH} bytes={len(content)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
