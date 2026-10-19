#!/usr/bin/env python3
"""Upload a new unlisted version of the Firefox extension to AMO and submit
it for signing. Requires AMO_JWT_ISSUER / AMO_JWT_SECRET env vars.

Usage: python3 amo_submit_version.py <path-to-xpi>
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

ISSUER = os.environ["AMO_JWT_ISSUER"]
SECRET = os.environ["AMO_JWT_SECRET"]
ADDON_ID = os.environ.get("AMO_ADDON_ID", "sixvpn-blocker@sixvpnblocker.app")


def make_jwt() -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": ISSUER, "jti": str(uuid.uuid4()), "iat": now, "exp": now + 60}
    h = _b64url(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(SECRET.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url(sig)}"


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _request(url: str, method: str, data: bytes | None = None, content_type: str | None = None) -> dict:
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"JWT {make_jwt()}")
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise SystemExit(f"HTTP_ERROR {exc.code} on {method} {url}: {body[:800]}")


def upload_file(xpi_path: str) -> str:
    boundary = uuid.uuid4().hex
    filename = os.path.basename(xpi_path)
    mime = mimetypes.guess_type(filename)[0] or "application/x-xpinstall"
    with open(xpi_path, "rb") as f:
        file_bytes = f.read()

    parts = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="channel"\r\n\r\nunlisted\r\n')
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="upload"; filename="{filename}"\r\n'
        f"Content-Type: {mime}\r\n\r\n".encode()
    )
    parts.append(file_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)

    data = _request(
        "https://addons.mozilla.org/api/v5/addons/upload/",
        "POST",
        data=body,
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    print(f"[upload] uuid={data.get('uuid')} channel={data.get('channel')}")
    return data["uuid"]


def wait_for_processing(upload_uuid: str, timeout_s: int = 120) -> None:
    url = f"https://addons.mozilla.org/api/v5/addons/upload/{upload_uuid}/"
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        data = _request(url, "GET")
        if data.get("processed"):
            validation = data.get("validation") or {}
            errors = validation.get("messages", [])
            print(f"[upload] processed=true valid={data.get('valid')}")
            if not data.get("valid"):
                print(json.dumps(errors, indent=2)[:2000])
                raise SystemExit("Upload failed validation.")
            return
        time.sleep(3)
    raise SystemExit("Timed out waiting for upload processing.")


def create_version(upload_uuid: str) -> None:
    url = f"https://addons.mozilla.org/api/v5/addons/addon/{ADDON_ID}/versions/"
    body = json.dumps({"upload": upload_uuid}).encode()
    data = _request(url, "POST", data=body, content_type="application/json")
    print(f"[version] id={data.get('id')} version={data.get('version')}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: amo_submit_version.py <xpi-path>", file=sys.stderr)
        return 2
    xpi_path = sys.argv[1]
    upload_uuid = upload_file(xpi_path)
    wait_for_processing(upload_uuid)
    create_version(upload_uuid)
    print("[done] submitted for Mozilla signing (unlisted). Poll status separately.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
