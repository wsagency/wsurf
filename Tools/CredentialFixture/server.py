#!/usr/bin/env python3
"""Gate B fixture relying party: password, TOTP (RFC 6238) and ES256 WebAuthn checks over HTTPS.

    python3 Tools/CredentialFixture/server.py --origin https://HOST[:PORT] --cert PEM --key PEM

Python 3 stdlib + the system `openssl` CLI only. State is in memory (restart = reset).
Secrets (password, TOTP secret, request bodies) are never logged. The user supplies the
origin name, its certificate/trust and DNS/hosts entry. This verifies the *server side* of
real ceremonies; it makes no claim about Apple Passwords, platform authenticators or PRF.
"""
import argparse
import base64
import binascii
import hashlib
import hmac
import http.server
import json
import os
import re
import signal
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse

MAX_BODY = 16384
CHALLENGE_TTL = 300  # seconds (monotonic)
MAX_CHALLENGES = 64
SPKI_P256 = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

PAGE = b"""<!doctype html><meta charset="utf-8"><title>WSurf credential fixture</title>
<h1>WSurf credential fixture</h1>
<p>Synthetic relying party for Gate B checks. State is in memory only.</p>
<h2>1. Setup (once per server run)</h2>
<form id="setup" autocomplete="off">
 <input name="username" placeholder="username"> <input name="password" placeholder="password">
 <input name="totpSecret" placeholder="TOTP secret (base32)"> <select name="totpDigits"><option>6</option><option>8</option></select>
 <select name="totpAlgorithm"><option>SHA1</option><option>SHA256</option><option>SHA512</option></select>
 <button>Set up</button></form>
<h2>2. Password</h2>
<form id="login"><input name="username" autocomplete="username" placeholder="username">
 <input name="password" type="password" autocomplete="current-password" placeholder="password"><button>Sign in</button></form>
<h2>3. TOTP</h2>
<form id="totp"><input name="code" autocomplete="one-time-code" inputmode="numeric" placeholder="code"><button>Verify</button></form>
<h2>4. Passkey</h2>
<button id="register">Register passkey</button> <button id="passkey">Sign in with passkey</button>
<pre id="out"></pre>
<script>
const out = document.getElementById("out");
const show = (name, status, body) => { out.textContent = name + ": HTTP " + status + " " + JSON.stringify(body) + "\\n" + out.textContent; };
const b64u = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
const unb64u = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
async function post(path, body) {
  const r = await fetch(path, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  return [r.status, await r.json()];
}
for (const [id, path] of [["setup", "/api/setup"], ["login", "/api/login"], ["totp", "/api/totp"]]) {
  document.getElementById(id).addEventListener("submit", async e => {
    e.preventDefault();
    const body = Object.fromEntries(new FormData(e.target));
    if (body.totpDigits) body.totpDigits = Number(body.totpDigits);
    const [s, b] = await post(path, body); show(id, s, b);
  });
}
async function ceremony(kind) {
  const [s, o] = await post("/api/webauthn/" + kind + "/options", {});
  if (s != 200) return show(kind, s, o);
  const pk = {challenge: unb64u(o.challenge), timeout: 60000, userVerification: "preferred"};
  let cred, body;
  if (kind == "register") {
    pk.rp = o.rp; pk.pubKeyCredParams = o.pubKeyCredParams; pk.attestation = "none";
    pk.user = {id: unb64u(o.user.id), name: o.user.name, displayName: o.user.displayName};
    pk.authenticatorSelection = {residentKey: "preferred", userVerification: "preferred"};
    cred = await navigator.credentials.create({publicKey: pk});
    body = {attestationObject: b64u(cred.response.attestationObject)};
  } else {
    pk.rpId = o.rpId;
    cred = await navigator.credentials.get({publicKey: pk});
    body = {authenticatorData: b64u(cred.response.authenticatorData), signature: b64u(cred.response.signature)};
    if (cred.response.userHandle) body.userHandle = b64u(cred.response.userHandle);
  }
  body.clientDataJSON = b64u(cred.response.clientDataJSON);
  const [vs, vb] = await post("/api/webauthn/" + kind + "/verify", {id: cred.id, rawId: b64u(cred.rawId), type: cred.type, response: body});
  show(kind, vs, vb);
}
for (const [id, kind] of [["register", "register"], ["passkey", "login"]]) {
  document.getElementById(id).addEventListener("click", () => ceremony(kind).catch(e => show(kind, 0, String(e))));
}
</script>
"""


class Reject(Exception):
    def __init__(self, status, error):
        super().__init__(error)
        self.status, self.error = status, error


def b64u_decode(s):
    if not isinstance(s, str) or len(s) > 8192 or len(s) % 4 == 1 or not re.fullmatch(r"[A-Za-z0-9_-]*", s):
        raise Reject(400, "base64url")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def utf8(v, limit=256):
    """Non-empty str of bounded length that encodes as UTF-8 (lone surrogates cannot) -> bytes."""
    if not isinstance(v, str) or not 0 < len(v) <= limit:
        raise Reject(400, "fields")
    try:
        return v.encode("utf-8")
    except UnicodeEncodeError:
        raise Reject(400, "fields")


def cbor(data, off=0, depth=0):
    """Minimal definite-length CBOR (uint, negint, bytes, text, array, map); anything else is rejected."""
    if depth > 8 or off >= len(data):
        raise Reject(400, "cbor")
    major, info = data[off] >> 5, data[off] & 31
    off += 1
    if info < 24:
        n = info
    elif info in (24, 25, 26, 27):
        size = 1 << (info - 24)
        if off + size > len(data):
            raise Reject(400, "cbor")
        n = int.from_bytes(data[off:off + size], "big")
        off += size
    else:
        raise Reject(400, "cbor")
    if major == 0:
        return n, off
    if major == 1:
        return -1 - n, off
    if major in (2, 3):
        if off + n > len(data):
            raise Reject(400, "cbor")
        raw = data[off:off + n]
        try:
            return (raw if major == 2 else raw.decode("utf-8")), off + n
        except UnicodeDecodeError:
            raise Reject(400, "cbor")
    if major in (4, 5) and n <= 32:
        items = []
        for _ in range(n * (1 if major == 4 else 2)):
            item, off = cbor(data, off, depth + 1)
            items.append(item)
        if major == 4:
            return items, off
        if not all(isinstance(k, (int, str, bytes)) for k in items[0::2]):  # arrays/maps are not valid keys here
            raise Reject(400, "cbor")
        return dict(zip(items[0::2], items[1::2])), off
    raise Reject(400, "cbor")


def totp(secret, at, digits, algorithm):
    h = hmac.new(secret, struct.pack(">Q", int(at) // 30), algorithm.lower()).digest()
    o = h[-1] & 15
    return "%0*d" % (digits, (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits)


def spki_pem(x, y):
    if not (isinstance(x, bytes) and isinstance(y, bytes) and len(x) == len(y) == 32):
        raise Reject(400, "cose-key")
    xi, yi = int.from_bytes(x, "big"), int.from_bytes(y, "big")
    if xi >= P or yi >= P or (yi * yi - (xi ** 3 - 3 * xi + B)) % P:
        raise Reject(400, "cose-key")  # not a point on P-256
    der = SPKI_P256 + b"\x04" + x + y
    return "-----BEGIN PUBLIC KEY-----\n%s-----END PUBLIC KEY-----\n" % base64.encodebytes(der).decode()


class Fixture:
    def __init__(self, origin, now):
        u = urllib.parse.urlsplit(origin)
        if u.scheme != "https" or not u.hostname or u.path or u.query or u.fragment or u.username or u.password:
            raise SystemExit("--origin must look like https://HOST[:PORT]")
        try:
            self.port = u.port or 443
        except ValueError:
            raise SystemExit("--origin must look like https://HOST[:PORT]")
        self.rp_id = u.hostname.lower()
        host = "[%s]" % self.rp_id if ":" in self.rp_id else self.rp_id
        self.origin = "https://" + (host if self.port == 443 else "%s:%d" % (host, self.port))  # browsers omit :443
        self.now = now  # fixed clock only for the selftest harness; None = real clock
        self.lock = threading.Lock()
        self.user = None  # {username, password, secret, digits, algorithm, handle}
        self.credentials = {}  # credential id -> {pem, counter}
        self.challenges = {}  # challenge -> (kind, monotonic expiry)

    def clock(self):
        return time.time() if self.now is None else self.now

    def issue(self, kind):
        c = b64u(os.urandom(32))
        now = time.monotonic()
        self.challenges = {k: v for k, v in self.challenges.items() if v[1] > now}
        while len(self.challenges) >= MAX_CHALLENGES:
            del self.challenges[next(iter(self.challenges))]
        self.challenges[c] = (kind, now + CHALLENGE_TTL)
        return c

    def require_user(self):
        if self.user is None:
            raise Reject(409, "not-set-up")
        return self.user

    # --- API handlers: body dict -> (status, dict) ---
    def setup(self, body):
        if self.user is not None:
            raise Reject(409, "already-set-up")
        username, password, secret = body.get("username"), body.get("password"), body.get("totpSecret")
        digits, algorithm = body.get("totpDigits", 6), body.get("totpAlgorithm", "SHA1")
        for v in (username, password, secret):
            utf8(v)
        if type(digits) is not int or digits not in (6, 8) or algorithm not in ("SHA1", "SHA256", "SHA512"):
            raise Reject(400, "totp-parameters")
        s = re.sub(r"[\s=]", "", secret).upper()
        try:
            key = base64.b32decode(s + "=" * (-len(s) % 8))
        except (binascii.Error, ValueError):
            raise Reject(400, "totp-secret")
        if not key:
            raise Reject(400, "totp-secret")
        self.user = {"username": username, "password": password, "secret": key, "digits": digits,
                     "algorithm": algorithm, "handle": os.urandom(16)}
        return 200, {"ok": True, "rpId": self.rp_id}

    def login(self, body):
        u = self.require_user()
        username, password = utf8(body.get("username")), utf8(body.get("password"))
        ok = hmac.compare_digest(username, u["username"].encode())
        ok &= hmac.compare_digest(password, u["password"].encode())
        if not ok:
            raise Reject(401, "invalid-credentials")
        return 200, {"ok": True}

    def totp(self, body):
        u = self.require_user()
        code = body.get("code")
        if not isinstance(code, str):
            raise Reject(400, "fields")
        code = re.sub(r"\s", "", code)
        if not re.fullmatch(r"[0-9]{%d}" % u["digits"], code):
            raise Reject(400, "code-format")
        now, ok = self.clock(), False
        for step in (-1, 0, 1):  # RFC 6238 §5.2: one step of drift either way
            ok |= hmac.compare_digest(code, totp(u["secret"], now + 30 * step, u["digits"], u["algorithm"]))
        if not ok:
            raise Reject(401, "invalid-code")
        return 200, {"ok": True}

    def register_options(self, body):
        u = self.require_user()
        return 200, {"challenge": self.issue("create"), "rp": {"id": self.rp_id, "name": "WSurf credential fixture"},
                     "user": {"id": b64u(u["handle"]), "name": u["username"], "displayName": u["username"]},
                     "pubKeyCredParams": [{"type": "public-key", "alg": -7}]}

    def login_options(self, body):
        self.require_user()
        return 200, {"challenge": self.issue("get"), "rpId": self.rp_id}

    def client_data(self, response, kind):
        raw = b64u_decode(response.get("clientDataJSON"))
        try:
            cd = json.loads(raw.decode("utf-8"))
        except (ValueError, RecursionError):
            raise Reject(400, "client-data")
        if not isinstance(cd, dict) or cd.get("type") != "webauthn." + kind:
            raise Reject(400, "type")
        pending = self.challenges.pop(cd.get("challenge"), None) if isinstance(cd.get("challenge"), str) else None
        if pending is None or pending[0] != kind or pending[1] <= time.monotonic():
            raise Reject(400, "challenge")
        if cd.get("origin") != self.origin or cd.get("crossOrigin") is True:
            raise Reject(400, "origin")
        return hashlib.sha256(raw).digest()

    def check_auth_data(self, auth, need_flags):
        if len(auth) < 37 or auth[:32] != hashlib.sha256(self.rp_id.encode()).digest():
            raise Reject(400, "rp-id-hash")
        if auth[32] & need_flags != need_flags:
            raise Reject(400, "flags")  # 0x01 user present, 0x40 attested credential data
        return auth[32], struct.unpack(">I", auth[33:37])[0]

    def register_verify(self, body):
        u = self.require_user()
        response = body.get("response")
        if not isinstance(response, dict):
            raise Reject(400, "fields")
        self.client_data(response, "create")
        att, end = cbor(b64u_decode(response.get("attestationObject")))
        if not isinstance(att, dict) or att.get("fmt") != "none" or not isinstance(att.get("authData"), bytes):
            raise Reject(400, "attestation")  # only fmt "none": attestation is not requested
        auth = att["authData"]
        flags, counter = self.check_auth_data(auth, 0x41)
        if len(auth) < 55:
            raise Reject(400, "auth-data")
        n = int.from_bytes(auth[53:55], "big")
        cred_id = auth[55:55 + n]
        if not 16 <= n <= 1023 or len(cred_id) != n or body.get("id") != b64u(cred_id):
            raise Reject(400, "credential-id")
        key, _ = cbor(auth, 55 + n)
        if not isinstance(key, dict) or key.get(1) != 2 or key.get(3) != -7 or key.get(-1) != 1:
            raise Reject(400, "cose-key")  # EC2 / ES256 / P-256 only
        pem = spki_pem(key.get(-2), key.get(-3))
        if cred_id in self.credentials:
            raise Reject(409, "credential-exists")  # never replace a stored key
        self.credentials[cred_id] = {"pem": pem, "counter": counter}
        return 200, {"ok": True, "credentialId": b64u(cred_id), "counter": counter,
                     "userVerified": bool(flags & 0x04)}

    def login_verify(self, body):
        u = self.require_user()
        response = body.get("response")
        if not isinstance(response, dict):
            raise Reject(400, "fields")
        digest = self.client_data(response, "get")
        cred_id = b64u_decode(body.get("id"))
        cred = self.credentials.get(cred_id)
        if cred is None:
            raise Reject(400, "unknown-credential")
        auth = b64u_decode(response.get("authenticatorData"))
        flags, counter = self.check_auth_data(auth, 0x01)
        handle = response.get("userHandle")
        if handle is not None and not (isinstance(handle, str) and hmac.compare_digest(b64u_decode(handle), u["handle"])):
            raise Reject(400, "user-handle")
        if not self.verify_signature(cred["pem"], b64u_decode(response.get("signature")), auth + digest):
            raise Reject(400, "signature")
        if (counter or cred["counter"]) and counter <= cred["counter"]:
            raise Reject(400, "counter")  # both zero = authenticator without a counter (platform passkeys)
        cred["counter"] = counter
        return 200, {"ok": True, "counter": counter, "userVerified": bool(flags & 0x04)}

    def verify_signature(self, pem, sig, data):
        with tempfile.TemporaryDirectory() as d:  # 0700, removed before the reply
            pub, sigfile = os.path.join(d, "pub.pem"), os.path.join(d, "sig.der")
            with open(pub, "w") as f:
                f.write(pem)
            with open(sigfile, "wb") as f:
                f.write(sig)
            try:
                r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sigfile],
                                   input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            except (OSError, subprocess.SubprocessError):
                raise Reject(500, "openssl")
            return r.returncode == 0


ROUTES = {"/api/setup": "setup", "/api/login": "login", "/api/totp": "totp",
          "/api/webauthn/register/options": "register_options", "/api/webauthn/register/verify": "register_verify",
          "/api/webauthn/login/options": "login_options", "/api/webauthn/login/verify": "login_verify"}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "CredentialFixture"
    timeout = 10

    def reply(self, status, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; "
                         "style-src 'unsafe-inline'; connect-src 'self'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            self.reply(200, PAGE, "text/html; charset=utf-8")
        else:
            self.reply(404, {"ok": False, "error": "not-found"})

    def do_POST(self):
        name = ROUTES.get(self.path)
        try:
            if name is None:
                raise Reject(404, "not-found")
            length = self.headers.get("Content-Length", "")
            if not re.fullmatch(r"[0-9]{1,9}", length):  # isdigit() also accepts e.g. superscripts
                raise Reject(411, "length-required")
            if int(length) > MAX_BODY:
                raise Reject(413, "too-large")
            try:
                body = json.loads(self.rfile.read(int(length)).decode("utf-8"))
            except (ValueError, RecursionError):  # RecursionError: deeply nested JSON
                raise Reject(400, "json")
            if not isinstance(body, dict):
                raise Reject(400, "json")
            with self.server.fixture.lock:
                status, payload = getattr(self.server.fixture, name)(body)
        except Reject as r:
            status, payload = r.status, {"ok": False, "error": r.error}
        self.reply(status, payload)
        if status == 413:
            self.close_connection = True

    def log_message(self, fmt, *args):  # error paths echo request lines/bodies: stay silent
        pass

    def log_request(self, code="-", size="-"):  # method, path and status only; never bodies
        print("%s %s -> %s" % (self.command, self.path.split("?", 1)[0], code), flush=True)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):  # TLS probes/resets are routine; tracebacks could echo data
        print("connection error", flush=True)


def stop(*_):
    raise SystemExit(0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--origin", required=True, help="https://HOST[:PORT]; HOST is the WebAuthn rpID")
    ap.add_argument("--cert", required=True, help="PEM certificate chain for HOST")
    ap.add_argument("--key", required=True, help="PEM private key")
    ap.add_argument("--bind", default="127.0.0.1", help="listen address (default 127.0.0.1)")
    ap.add_argument("--now", type=int, help="freeze the TOTP clock at this Unix time (selftest only)")
    args = ap.parse_args()
    fixture = Fixture(args.origin, args.now)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(args.cert, args.key)
    httpd = Server((args.bind, fixture.port), Handler)
    try:
        # handshake lazily in the handler thread (bounded by Handler.timeout), not in the accept loop
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
        httpd.fixture = fixture
        signal.signal(signal.SIGTERM, stop)
        print("fixture relying party: origin=%s rpId=%s listening=%s:%d" % (fixture.origin, fixture.rp_id, args.bind, fixture.port),
              flush=True)
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
