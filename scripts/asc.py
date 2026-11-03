#!/usr/bin/env python3
"""A small client for the App Store Connect API, for the listing that scripts can set.

The key is the one the release scripts sign with: ASC_KEY_PATH (a .p8), ASC_KEY_ID and
ASC_ISSUER_ID in the environment. The token is an ES256 JWT signed with openssl, which
needs no Python crypto library: openssl writes a DER signature, and the raw r||s the
JWT wants is unwrapped from it here.

    scripts/asc.py app                       the app record for the bundle id
    scripts/asc.py get <path> [key=value…]   any GET, e.g. get /v1/apps limit=5
    scripts/asc.py patch <path> <json>       any PATCH with a JSON body
    scripts/asc.py post <path> <json>        any POST with a JSON body
    scripts/asc.py delete <path>             any DELETE
"""
import base64, json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request

BUNDLE_ID = "com.artsy.app"
BASE = "https://api.appstoreconnect.apple.com"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """An ECDSA DER SEQUENCE of two INTEGERs, to the 64-byte r||s a JWT carries."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        value = der[i + 2:i + 2 + length]
        out += value[-32:].rjust(32, b"\0")
        i += 2 + length
    return out


_token = None


def token() -> str:
    global _token
    if _token:
        return _token
    key_path = os.environ["ASC_KEY_PATH"]
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(signing_input)
        name = f.name
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, name], check=True, capture_output=True).stdout
    finally:
        os.unlink(name)
    _token = f"{header}.{payload}.{b64url(der_to_raw(der))}"
    return _token


def call(method: str, path: str, body=None, params=None, raw=False):
    url = path if path.startswith("http") else BASE + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read()
            return text if raw else (json.loads(text) if text else {})
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"{method} {path} → {error.code}\n{detail}")


def get(path, **params):
    return call("GET", path, params=params or None)


def patch(path, body):
    return call("PATCH", path, body=body)


def post(path, body):
    return call("POST", path, body=body)


def delete(path):
    return call("DELETE", path)


def app():
    """The app record for the bundle id, with its id, name and SKU."""
    found = get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not found:
        raise SystemExit(f"no app with bundle id {BUNDLE_ID}")
    return found[0]


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    command, rest = args[0], args[1:]
    if command == "app":
        result = app()
    elif command == "get":
        params = dict(item.split("=", 1) for item in rest[1:])
        result = get(rest[0], **params)
    elif command in ("patch", "post"):
        result = (patch if command == "patch" else post)(rest[0], json.loads(rest[1]))
    elif command == "delete":
        result = delete(rest[0])
    else:
        raise SystemExit(f"unknown command {command}")
    print(json.dumps(result, indent=2))
