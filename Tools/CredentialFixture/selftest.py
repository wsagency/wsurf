#!/usr/bin/env python3
"""Self-test of Tools/CredentialFixture/server.py.

Exercises the fixture server over real HTTPS on localhost with a throwaway CA and
certificate, synthetic passwords, RFC 6238 vectors and a synthetic P-256 passkey.
It is a fixture-server exercise only: it makes no claim about WSurf, Apple
Passwords, Apple platform authenticators or PRF. Python 3 stdlib + system openssl.
"""
import base64
import hashlib
import http.client
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import signal
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import server as fixture_server  # noqa: E402  (origin canonicalization check only; the rest runs over HTTPS)

PASSWORD = "correct-horse-FIXTURE-1"
WRONG_PASSWORD = "wrong-horse-FIXTURE-2"
RFC_SECRET = base64.b32encode(b"12345678901234567890").decode()  # RFC 6238 SHA-1 test key
LOG_SECRETS = [PASSWORD, WRONG_PASSWORD, RFC_SECRET]
RP_HOST = "localhost"

tmp = None
procs = []
checks = 0


def check(cond, label):
    global checks
    assert cond, "FAILED: " + label
    checks += 1
    print("ok: " + label)


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def private(path):
    os.chmod(path, 0o600)
    return path


def make_certs():
    """Throwaway CA and localhost leaf; every key 0600 in the 0700 tempdir."""
    ca_key, ca_crt = os.path.join(tmp, "ca.key"), os.path.join(tmp, "ca.pem")
    key, csr, crt = (os.path.join(tmp, n) for n in ("srv.key", "srv.csr", "srv.pem"))
    ca_cnf, ext = os.path.join(tmp, "ca.cnf"), os.path.join(tmp, "leaf.ext")
    with open(ca_cnf, "w") as f:
        f.write("[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n"
                "[dn]\nCN=WSurf fixture throwaway CA\n"
                "[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n"
                "subjectKeyIdentifier=hash\n")
    with open(ext, "w") as f:
        f.write("basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\n"
                "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
    openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key)
    openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key)
    private(ca_key), private(key)
    openssl("req", "-x509", "-new", "-key", ca_key, "-days", "1", "-config", ca_cnf, "-out", ca_crt)
    openssl("req", "-new", "-key", key, "-subj", "/CN=localhost", "-out", csr)
    openssl("x509", "-req", "-in", csr, "-CA", ca_crt, "-CAkey", ca_key, "-CAcreateserial",
            "-days", "1", "-extfile", ext, "-out", crt)
    return ca_crt, crt, key


class Server:
    def __init__(self, ca, crt, key, now):
        self.ctx = ssl.create_default_context(cafile=ca)
        for attempt in range(3):  # the ephemeral port is probed, then handed over: retry a lost race
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                self.port = s.getsockname()[1]
            self.origin = "https://%s:%d" % (RP_HOST, self.port)
            self.log_path = os.path.join(tmp, "server-%d-%d.log" % (len(procs), attempt))
            log = open(self.log_path, "wb")
            self.proc = subprocess.Popen(
                [sys.executable, SERVER, "--origin", self.origin, "--cert", crt, "--key", key,
                 "--now", str(now)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            log.close()
            procs.append(self.proc)
            if self._wait_ready():
                return
            self.stop()
        raise AssertionError("server did not start:\n" + self.output())

    def _wait_ready(self):
        deadline = time.time() + 10
        while time.time() < deadline and self.proc.poll() is None:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                return True
            except OSError:
                time.sleep(0.05)
        return False

    def output(self):
        with open(self.log_path, "rb") as f:
            return f.read().decode("utf-8", "replace")

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

    def request(self, method, path, body=None, raw=None):
        conn = http.client.HTTPSConnection(RP_HOST, self.port, context=self.ctx, timeout=10)
        try:
            data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
            conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
            r = conn.getresponse()
            payload = r.read()
            try:
                return r.status, json.loads(payload)
            except ValueError:
                return r.status, payload
        finally:
            conn.close()

    def post(self, path, body):
        return self.request("POST", path, body)

    def raw_status(self, headers):
        """POST /api/login with hand-built header bytes (http.client cannot send them); returns the status."""
        with socket.create_connection(("127.0.0.1", self.port), 10) as s, \
                self.ctx.wrap_socket(s, server_hostname=RP_HOST) as t:
            t.sendall(b"POST /api/login HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" + headers + b"\r\n\r\n")
            return int(t.recv(64).split()[1])

    def setup(self, secret, digits):
        return self.post("/api/setup", {"username": "fixture-user", "password": PASSWORD,
                                        "totpSecret": secret, "totpDigits": digits})


def err(resp):
    """(status, error reason) so a rejection is proven to come from the intended check."""
    return resp[0], resp[1].get("error") if isinstance(resp[1], dict) else None


def totp_vector(ca, crt, key, now, code):
    srv = Server(ca, crt, key, now)
    assert srv.setup(RFC_SECRET, 8)[0] == 200
    check(srv.post("/api/totp", {"code": code})[0] == 200, "RFC 6238 vector t=%d code %s accepted" % (now, code))
    check(srv.post("/api/totp", {"code": "%08d" % ((int(code) + 1) % 10**8)})[0] == 401,
          "RFC 6238 t=%d: another 8-digit code rejected" % now)
    srv.stop()
    return srv


def authenticator_data(rp_id, flags, counter, attested=None):
    out = hashlib.sha256(rp_id.encode()).digest() + bytes([flags]) + struct.pack(">I", counter)
    return out + attested if attested else out


def enc(v):
    """Minimal CBOR encoder for test vectors (int, bytes, str, list, dict)."""
    def head(major, n):
        if n < 24:
            return bytes([major << 5 | n])
        return bytes([major << 5 | 24, n]) if n < 256 else bytes([major << 5 | 25]) + struct.pack(">H", n)
    if isinstance(v, int):
        return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, bytes):
        return head(2, len(v)) + v
    if isinstance(v, str):
        return head(3, len(v.encode())) + v.encode()
    if isinstance(v, list):
        return head(4, len(v)) + b"".join(map(enc, v))
    return head(5, len(v)) + b"".join(enc(k) + enc(x) for k, x in v.items())


class Passkey:
    """Synthetic ES256 credential: generated key, hand-built authenticator data."""

    def __init__(self, label):
        self.key = os.path.join(tmp, label + ".key")
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", self.key)
        private(self.key)
        der = openssl("ec", "-in", self.key, "-pubout", "-outform", "DER")
        point = der[-65:]
        assert point[0] == 4
        self.x, self.y = point[1:33], point[33:]
        self.cred_id = hashlib.sha256(label.encode()).digest()[:16]

    def sign(self, data):
        return openssl("dgst", "-sha256", "-sign", self.key, data=data)

    def cose(self, x=None, y=None, alg=-7, crv=1):
        return enc({1: 2, 3: alg, -1: crv, -2: self.x if x is None else x, -3: self.y if y is None else y})

    def registration(self, srv, challenge, rp_id=RP_HOST, origin=None, flags=0x45, typ="webauthn.create",
                     cose=None, cred_id=None, fmt="none", auth_cut=None):
        cid = self.cred_id if cred_id is None else cred_id
        auth = authenticator_data(rp_id, flags, 0, b"\0" * 16 + struct.pack(">H", len(cid)) + cid
                                  + (self.cose() if cose is None else cose))
        att = enc({"fmt": fmt, "attStmt": {}, "authData": auth[:auth_cut]})
        cd = json.dumps({"type": typ, "challenge": challenge, "origin": origin or srv.origin}).encode()
        return {"id": b64u(cid), "rawId": b64u(cid), "type": "public-key",
                "response": {"clientDataJSON": b64u(cd), "attestationObject": b64u(att)}}

    def assertion(self, srv, challenge, counter, origin=None, flags=0x05, typ="webauthn.get", cred_id=None,
                  tamper=False, signer=None, user_handle=None, rp_id=RP_HOST, client_extra=None):
        auth = authenticator_data(rp_id, flags, counter)
        cd = json.dumps({"type": typ, "challenge": challenge, "origin": origin or srv.origin,
                         **(client_extra or {})}).encode()
        sig = (signer or self).sign(auth + hashlib.sha256(cd).digest())
        if tamper:
            sig = sig[:-1] + bytes([sig[-1] ^ 1])
        resp = {"clientDataJSON": b64u(cd), "authenticatorData": b64u(auth), "signature": b64u(sig)}
        if user_handle is not None:
            resp["userHandle"] = b64u(user_handle)
        cid = b64u(cred_id or self.cred_id)
        return {"id": cid, "rawId": cid, "type": "public-key", "response": resp}


def main_checks(srv):
    check(srv.request("GET", "/")[0] == 200, "GET / served over HTTPS")
    check(srv.request("GET", "/missing")[0] == 404, "unknown path is 404")
    check(srv.request("POST", "/api/login", {"username": "fixture-user", "password": PASSWORD})[0] == 409,
          "login before setup is refused")
    good = {"username": "fixture-user", "password": PASSWORD, "totpSecret": RFC_SECRET, "totpDigits": 8}
    bad_setups = [{"totpDigits": 6.0}, {"totpDigits": True}, {"totpAlgorithm": "MD5"}, {"username": "\ud800"},
                  {"password": "\udc00"}, {"totpSecret": 7}]
    got = [srv.post("/api/setup", {**good, **b})[0] for b in bad_setups]
    check(got == [400] * len(bad_setups), "malformed setup values rejected with 400 (got %s)" % got)
    check(srv.post("/api/setup", good)[0] == 200, "valid setup still accepted after the rejected attempts")
    check(srv.setup(RFC_SECRET, 8)[0] == 409, "second setup refused")
    check(srv.request("POST", "/api/login", raw=b"x" * 20000)[0] == 413, "oversized body refused")
    check(err(srv.request("POST", "/api/login", raw=b"{not json")) == (400, "json"), "malformed JSON refused")
    check(err(srv.request("POST", "/api/login", raw=b"[" * 6000)) == (400, "json"), "deeply nested JSON refused")
    check(srv.raw_status(b"Content-Length: \xb2") == 411, "non-ASCII Content-Length digit refused")
    check(err(srv.post("/api/login", {"username": "\ud800", "password": PASSWORD})) == (400, "fields"),
          "lone-surrogate login refused")
    check(srv.post("/api/login", {"username": "fixture-user", "password": WRONG_PASSWORD})[0] == 401,
          "wrong password rejected")
    check(srv.post("/api/login", {"username": "other", "password": PASSWORD})[0] == 401, "wrong username rejected")
    check(srv.post("/api/login", {"username": "fixture-user", "password": PASSWORD})[0] == 200,
          "right password accepted")

    now = 1111111109
    code = lambda t: "%08d" % totp_at(t)
    check(srv.post("/api/totp", {"code": "07081804"})[0] == 200, "RFC 6238 vector t=1111111109 code 07081804 accepted")
    check(srv.post("/api/totp", {"code": code(now - 30)})[0] == 200, "previous step (-1) accepted")
    check(srv.post("/api/totp", {"code": code(now + 30)})[0] == 200, "next step (+1) accepted")
    check(srv.post("/api/totp", {"code": code(now - 60)})[0] == 401, "step -2 rejected")
    check(srv.post("/api/totp", {"code": code(now + 60)})[0] == 401, "step +2 rejected")
    check(srv.post("/api/totp", {"code": "94287082"})[0] == 401, "RFC code for t=59 rejected at t=1111111109")
    check(srv.post("/api/totp", {"code": "7081804"})[0] == 400, "wrong-length code refused")

    pk, other, zero = Passkey("synthetic-passkey"), Passkey("synthetic-other"), Passkey("synthetic-zero")

    def challenge(kind):
        s, o = srv.post("/api/webauthn/%s/options" % kind, {})
        assert s == 200, o
        return o

    reg = challenge("register")
    check(reg["rp"]["id"] == RP_HOST and reg["pubKeyCredParams"] == [{"type": "public-key", "alg": -7}],
          "registration options carry rpID and ES256 only")
    handle = unb64u(reg["user"]["id"])
    reg_url, login_url = "/api/webauthn/register/verify", "/api/webauthn/login/verify"

    def register(**kw):
        return srv.post(reg_url, pk.registration(srv, kw.pop("challenge", None) or challenge("register")["challenge"], **kw))

    check(err(register(origin="https://evil.example")) == (400, "origin"), "registration with wrong origin rejected")
    check(err(register(rp_id="evil.example")) == (400, "rp-id-hash"), "registration with wrong rpIdHash rejected")
    check(err(register(flags=0x44)) == (400, "flags"), "registration without user presence rejected")
    check(err(register(typ="webauthn.get")) == (400, "type"), "registration with wrong clientData type rejected")
    check(err(register(challenge=b64u(b"\1" * 32))) == (400, "challenge"), "registration with unissued challenge rejected")
    check(err(register(challenge=challenge("login")["challenge"])) == (400, "challenge"),
          "registration with a login challenge rejected")

    def set_resp(k, v):
        return lambda b: b["response"].__setitem__(k, v)

    flip_y = pk.y[:-1] + bytes([pk.y[-1] ^ 1])
    malformed = [
        ("base64url", {}, set_resp("attestationObject", "AAAAA")),
        ("base64url", {}, set_resp("clientDataJSON", "AAAAA")),
        ("client-data", {}, set_resp("clientDataJSON", b64u(b"[" * 6000))),
        ("cbor", {}, lambda b: set_resp("attestationObject", b64u(unb64u(b["response"]["attestationObject"])[:20]))(b)),
        ("cbor", {"cose": b"\xa1\x81\x01\x01"}, None),  # map whose key is an array
        ("attestation", {}, set_resp("attestationObject", b64u(b"\x80"))),
        ("attestation", {"fmt": "packed"}, None),
        ("auth-data", {"auth_cut": 40}, None),
        ("credential-id", {"cred_id": b"\1" * 8}, None),
        ("credential-id", {}, lambda b: b.__setitem__("id", b64u(b"\3" * 16))),
        ("cose-key", {"cose": pk.cose(x=5)}, None),
        ("cose-key", {"cose": pk.cose(y="abc")}, None),
        ("cose-key", {"cose": pk.cose(x=[1])}, None),
        ("cose-key", {"cose": pk.cose(alg=-257)}, None),
        ("cose-key", {"cose": pk.cose(crv=2)}, None),
        ("cose-key", {"cose": pk.cose(x=pk.x[:31])}, None),
        ("cose-key", {"cose": pk.cose(y=flip_y)}, None),  # not on the curve
    ]
    failed = []
    for reason, kw, mutate in malformed:
        body = pk.registration(srv, challenge("register")["challenge"], **kw)
        if mutate:
            mutate(body)
        got = err(srv.post(reg_url, body))
        if got != (400, reason):
            failed.append((reason, got))
    check(not failed, "%d malformed registrations rejected with their typed reason (mismatches: %s)" % (len(malformed), failed))
    check(srv.request("GET", "/")[0] == 200, "server still answers after the malformed registrations")

    reg = challenge("register")
    check(srv.post(reg_url, pk.registration(srv, reg["challenge"]))[0] == 200, "signed registration accepted")
    check(err(srv.post(reg_url, pk.registration(srv, reg["challenge"]))) == (400, "challenge"),
          "registration challenge is single-use")
    check(register()[0] == 409, "duplicate credential id rejected")
    impostor = Passkey("synthetic-impostor")
    impostor.cred_id = pk.cred_id  # same id, different key: a failing ceremony must not replace the stored key
    check(srv.post(reg_url, impostor.registration(srv, challenge("register")["challenge"]))[0] == 409,
          "registration of an existing id with another key rejected")
    check(srv.post(reg_url, zero.registration(srv, challenge("register")["challenge"]))[0] == 200,
          "second credential registered (counter 0)")

    def assert_(counter, key=pk, **kw):
        c = challenge("login")["challenge"]
        return srv.post(login_url, key.assertion(srv, c, counter, **kw))

    check(assert_(1)[0] == 200, "signed assertion accepted (counter 1)")
    check(err(assert_(2, origin="https://evil.example")) == (400, "origin"), "assertion with wrong origin rejected")
    check(err(assert_(2, client_extra={"crossOrigin": True})) == (400, "origin"), "cross-origin assertion rejected")
    check(err(assert_(2, rp_id="evil.example")) == (400, "rp-id-hash"), "assertion with wrong rpIdHash rejected")
    check(err(assert_(2, flags=0x04)) == (400, "flags"), "assertion without user presence rejected")
    check(err(assert_(2, typ="webauthn.create")) == (400, "type"), "assertion with wrong clientData type rejected")
    check(err(srv.post(login_url, pk.assertion(srv, b64u(b"\1" * 32), 2))) == (400, "challenge"),
          "assertion with unissued challenge rejected")
    check(err(srv.post(login_url, pk.assertion(srv, challenge("register")["challenge"], 2))) == (400, "challenge"),
          "assertion with a registration challenge rejected")
    check(err(assert_(2, cred_id=b"\2" * 16)) == (400, "unknown-credential"), "assertion for unknown credential rejected")
    check(err(assert_(2, signer=other)) == (400, "signature"), "assertion signed by another key rejected")
    check(err(assert_(2, signer=impostor)) == (400, "signature"), "stored key was not overwritten by the failed registration")
    check(err(assert_(2, user_handle=b"not-the-user")) == (400, "user-handle"), "assertion with foreign user handle rejected")
    check(err(assert_(2, tamper=True)) == (400, "signature"), "tampered signature rejected")
    malformed = [
        ("base64url", set_resp("clientDataJSON", "AAAAA")),
        ("base64url", set_resp("authenticatorData", "AAAAA")),
        ("base64url", set_resp("signature", "AAAAA")),
        ("base64url", set_resp("userHandle", "AAAAA")),
        ("base64url", lambda b: b.__setitem__("id", "AAAAA")),
        ("base64url", lambda b: b.__setitem__("id", 7)),
        ("client-data", set_resp("clientDataJSON", b64u(b"[" * 6000))),
        ("rp-id-hash", set_resp("authenticatorData", b64u(b"\0" * 10))),
        ("signature", set_resp("signature", b64u(b"junk"))),
        ("user-handle", set_resp("userHandle", 7)),
        ("fields", lambda b: b.__setitem__("response", "x")),
    ]
    failed = []
    for reason, mutate in malformed:
        body = pk.assertion(srv, challenge("login")["challenge"], 2)
        mutate(body)
        got = err(srv.post(login_url, body))
        if got != (400, reason):
            failed.append((reason, got))
    check(not failed, "%d malformed assertions rejected with their typed reason (mismatches: %s)" % (len(malformed), failed))
    body = pk.assertion(srv, challenge("login")["challenge"], 2, user_handle=handle)
    check(srv.post(login_url, body)[0] == 200,
          "assertion with the correct userHandle accepted after failed attempts (counter 2: none advanced it)")
    check(err(srv.post(login_url, body)) == (400, "challenge"), "identical assertion replay rejected (challenge consumed)")
    check(err(assert_(2)) == (400, "counter"), "replayed counter 2 rejected")
    check(err(assert_(1)) == (400, "counter"), "decreasing counter rejected")
    check(assert_(3)[0] == 200, "counter 3 accepted")
    check(err(assert_(0)) == (400, "counter"), "counter 0 after a positive stored counter rejected")
    check(assert_(0, key=zero)[0] == 200 and assert_(0, key=zero)[0] == 200,
          "counter 0 then 0 accepted for an authenticator without a counter (fresh challenges)")


def totp_at(t):
    key = base64.b32decode(RFC_SECRET)
    import hmac
    h = hmac.new(key, struct.pack(">Q", t // 30), "sha1").digest()
    o = h[-1] & 15
    return (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10**8


def main():
    global tmp
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # a parent timeout still runs the cleanup below
    tmp = tempfile.mkdtemp(prefix="credfixture-selftest-")  # mkdtemp: owner-only 0700
    servers = []
    try:
        origins = [fixture_server.Fixture(o, None).origin
                   for o in ("https://LocalHost:443", "https://localhost", "https://localhost:8443")]
        check(origins == ["https://localhost", "https://localhost", "https://localhost:8443"],
              "origin canonicalization drops the default port and keeps another one")
        ca, crt, key = make_certs()
        srv = Server(ca, crt, key, 1111111109)
        servers.append(srv)
        main_checks(srv)
        servers.append(totp_vector(ca, crt, key, 59, "94287082"))
        servers.append(totp_vector(ca, crt, key, 1234567890, "89005924"))
        for s in servers:
            s.stop()
        for i, s in enumerate(servers, 1):
            out = s.output()
            check("listening" in out and not any(secret in out for secret in LOG_SECRETS),
                  "server %d output is non-empty and contains none of the test passwords or secrets" % i)
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
                p.wait()
        shutil.rmtree(tmp, ignore_errors=True)
    print("selftest: all checks passed")


if __name__ == "__main__":
    main()
