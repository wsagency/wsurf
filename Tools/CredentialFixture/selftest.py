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
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
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


def cbor_bytes(b):
    assert len(b) < 256
    return (b"\x58" + bytes([len(b)]) if len(b) > 23 else bytes([0x40 + len(b)])) + b


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

    def cose(self):
        return b"\xa5\x01\x02\x03\x26\x20\x01\x21" + cbor_bytes(self.x) + b"\x22" + cbor_bytes(self.y)

    def registration(self, srv, challenge, rp_id=RP_HOST, origin=None, flags=0x45, typ="webauthn.create"):
        attested = b"\0" * 16 + struct.pack(">H", len(self.cred_id)) + self.cred_id + self.cose()
        auth = authenticator_data(rp_id, flags, 0, attested)
        att = (b"\xa3\x63fmt\x64none\x67attStmt\xa0\x68authData\x58" + bytes([len(auth)]) + auth)
        cd = json.dumps({"type": typ, "challenge": challenge, "origin": origin or srv.origin}).encode()
        return {"id": b64u(self.cred_id), "rawId": b64u(self.cred_id), "type": "public-key",
                "response": {"clientDataJSON": b64u(cd), "attestationObject": b64u(att)}}

    def assertion(self, srv, challenge, counter, origin=None, flags=0x05, typ="webauthn.get",
                  cred_id=None, tamper=False, signer=None, user_handle=None):
        auth = authenticator_data(RP_HOST, flags, counter)
        cd = json.dumps({"type": typ, "challenge": challenge, "origin": origin or srv.origin}).encode()
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
    check(srv.setup(RFC_SECRET, 8)[0] == 200, "one-time setup accepted")
    check(srv.setup(RFC_SECRET, 8)[0] == 409, "second setup refused")
    check(srv.request("POST", "/api/login", raw=b"x" * 20000)[0] == 413, "oversized body refused")
    check(srv.request("POST", "/api/login", raw=b"{not json")[0] == 400, "malformed JSON refused")
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

    pk = Passkey("synthetic-passkey")
    other = Passkey("synthetic-other")

    def challenge(kind):
        s, o = srv.post("/api/webauthn/%s/options" % kind, {})
        assert s == 200, o
        return o

    reg = challenge("register")
    check(reg["rp"]["id"] == RP_HOST and reg["pubKeyCredParams"] == [{"type": "public-key", "alg": -7}],
          "registration options carry rpID and ES256 only")

    def register(**kw):
        return srv.post("/api/webauthn/register/verify",
                        pk.registration(srv, kw.pop("challenge", None) or challenge("register")["challenge"], **kw))

    check(err(register(origin="https://evil.example")) == (400, "origin"), "registration with wrong origin rejected")
    check(err(register(rp_id="evil.example")) == (400, "rp-id-hash"), "registration with wrong rpIdHash rejected")
    check(err(register(flags=0x44)) == (400, "flags"), "registration without user presence rejected")
    check(err(register(typ="webauthn.get")) == (400, "type"), "registration with wrong clientData type rejected")
    check(err(register(challenge=b64u(b"\1" * 32))) == (400, "challenge"), "registration with unissued challenge rejected")
    reg = challenge("register")
    check(srv.post("/api/webauthn/register/verify", pk.registration(srv, reg["challenge"]))[0] == 200,
          "signed registration accepted")
    check(err(srv.post("/api/webauthn/register/verify", pk.registration(srv, reg["challenge"]))) == (400, "challenge"),
          "registration challenge is single-use")
    check(register()[0] == 409, "duplicate credential id rejected")
    impostor = Passkey("synthetic-impostor")
    impostor.cred_id = pk.cred_id  # same id, different key: a failing ceremony must not replace the stored key
    check(srv.post("/api/webauthn/register/verify",
                   impostor.registration(srv, challenge("register")["challenge"]))[0] == 409,
          "registration of an existing id with another key rejected")

    def assert_(counter, **kw):
        c = challenge("login")["challenge"]
        return srv.post("/api/webauthn/login/verify", pk.assertion(srv, c, counter, **kw))

    check(assert_(1)[0] == 200, "signed assertion accepted (counter 1)")
    check(err(assert_(2, origin="https://evil.example")) == (400, "origin"), "assertion with wrong origin rejected")
    check(err(assert_(2, flags=0x04)) == (400, "flags"), "assertion without user presence rejected")
    check(err(assert_(2, typ="webauthn.create")) == (400, "type"), "assertion with wrong clientData type rejected")
    check(err(assert_(2, cred_id=b"\2" * 16)) == (400, "unknown-credential"), "assertion for unknown credential rejected")
    check(err(assert_(2, signer=other)) == (400, "signature"), "assertion signed by another key rejected")
    check(err(assert_(2, signer=impostor)) == (400, "signature"), "stored key was not overwritten by the failed registration")
    check(err(assert_(2, user_handle=b"not-the-user")) == (400, "user-handle"), "assertion with foreign user handle rejected")
    check(err(assert_(2, tamper=True)) == (400, "signature"), "tampered signature rejected")
    c = challenge("login")["challenge"]
    body = pk.assertion(srv, c, 2)
    check(srv.post("/api/webauthn/login/verify", body)[0] == 200, "failed attempts did not advance the counter (2 accepted)")
    check(err(srv.post("/api/webauthn/login/verify", body)) == (400, "challenge"), "identical assertion replay rejected (challenge consumed)")
    check(err(assert_(2)) == (400, "counter"), "replayed counter 2 rejected")
    check(err(assert_(1)) == (400, "counter"), "decreasing counter rejected")
    check(assert_(3)[0] == 200, "counter 3 accepted")


def totp_at(t):
    key = base64.b32decode(RFC_SECRET)
    import hmac
    h = hmac.new(key, struct.pack(">Q", t // 30), "sha1").digest()
    o = h[-1] & 15
    return (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10**8


def main():
    global tmp
    tmp = tempfile.mkdtemp(prefix="credfixture-selftest-")  # mkdtemp: owner-only 0700
    servers = []
    try:
        check(os.stat(tmp).st_mode & 0o777 == 0o700, "tempdir is 0700")
        ca, crt, key = make_certs()
        check(os.stat(key).st_mode & 0o777 == 0o600, "private key is 0600")
        srv = Server(ca, crt, key, 1111111109)
        servers.append(srv)
        main_checks(srv)
        servers.append(totp_vector(ca, crt, key, 59, "94287082"))
        servers.append(totp_vector(ca, crt, key, 1234567890, "89005924"))
        for s in servers:
            s.stop()
        for s in servers:
            out = s.output()
            for secret in LOG_SECRETS:
                check(secret not in out, "server output does not contain a test secret")
        check(all(p.poll() is not None for p in procs), "all subprocesses stopped")
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
                p.wait()
        shutil.rmtree(tmp, ignore_errors=True)
    print("selftest: all checks passed")


if __name__ == "__main__":
    main()
