#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Owned, memory-only HTTPS fixture. No virtual authenticator or global trust changes.

Controller checks: python3 Tools/CredentialFixture/server.py --self-check
Serve: --cert /owned/cert.pem --key /owned/key.pem [--port 8443]
Certificates must contain DNS:localhost. Bind is deliberately loopback-only.
"""
import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
from pathlib import Path
import secrets
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit


def self_check(openssl):
    # The positive signer is OpenSSL, independent of CryptoKit/native encoders.
    # The temporary directory is mode 0700 and removed even if an assertion fails.
    with tempfile.TemporaryDirectory(prefix="wsurf-owned-webauthn-") as directory:
        root = Path(directory)
        key = root / "private.pem"
        key.touch(mode=0o600)
        run(openssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key))
        public = run(openssl, "pkey", "-in", str(key), "-pubout", "-outform", "DER")
        point = public[-65:]
        assert point[0] == 4 and len(point) == 65
        cose = cbor({1: 2, 3: -7, -1: 1, -2: point[1:33], -3: point[33:]})
        fixture = Fixture("https://localhost:8443", openssl)
        credential_id = secrets.token_bytes(32)

        def sign(data):
            message = root / "message.bin"
            message.write_bytes(data)
            return run(openssl, "dgst", "-sha256", "-sign", str(key), str(message))

        def response(operation, change=None, excluded=False, uv=True):
            options = fixture.options({"operation": operation, "username": "owned-01", "uv": "required",
                                       "exclude": excluded})
            pk = options["publicKey"]
            response_id = (secrets.token_bytes(32) if operation == "create" and fixture.credentials and not excluded
                           else credential_id)
            client = {"type": "webauthn.create" if operation == "create" else "webauthn.get",
                      "challenge": pk["challenge"], "origin": fixture.origin, "crossOrigin": False}
            if change == "challenge":
                client["challenge"] = b64(secrets.token_bytes(32))
            if change == "origin":
                client["origin"] = "https://not-owned.invalid"
            client_bytes = json.dumps(client, separators=(",", ":")).encode()
            rp_hash = hashlib.sha256(fixture.rp.encode()).digest()
            if change == "rp":
                rp_hash = bytes(32)
            auth = rp_hash + bytes([0x01 | (0x04 if uv else 0) | (0x40 if operation == "create" else 0)]) + bytes(4)
            if operation == "create":
                auth += bytes(16) + struct.pack(">H", len(response_id)) + response_id + cose
            signature = sign(auth + hashlib.sha256(client_bytes).digest())
            if change == "signature":
                signature = signature[:-1] + bytes([signature[-1] ^ 1])
            payload = {"clientDataJSON": b64(client_bytes)}
            if operation == "create":
                payload["attestationObject"] = b64(cbor({"fmt": "packed", "authData": auth,
                                                        "attStmt": {"alg": -7, "sig": signature}}))
            else:
                payload.update(authenticatorData=b64(auth), signature=b64(signature),
                               userHandle=pk["userHandle"])
            return {"session": options["session"], "credential": {"type": "public-key", "id": b64(response_id),
                     "rawId": b64(response_id), "response": payload}}

        def rejected(envelope, reason=None):
            try:
                fixture.verify(envelope)
            except (ValueError, KeyError, TypeError) as error:
                if reason is not None:
                    assert str(error) == reason, (reason, str(error))
                return True
            return False

        registration = response("create")
        assert fixture.verify(registration)["accepted"], "valid registration"
        assert rejected(registration), "registration challenge reuse"
        assertion = response("get")
        assert fixture.verify(assertion)["accepted"], "valid assertion"
        assert rejected(assertion), "assertion challenge reuse"
        for operation in ("create", "get"):
            for change in ("challenge", "origin", "rp", "signature"):
                assert rejected(response(operation, change)), (operation, change)
        assert rejected(response("create", excluded=True), "Credential excluded"), "excluded credential"
        assert rejected(response("get", uv=False)), "required UV"
        unknown = response("get")
        unknown["credential"]["id"] = unknown["credential"]["rawId"] = b64(secrets.token_bytes(32))
        assert rejected(unknown), "allow-list / unknown credential"
        # Known RFC 6238 outputs, including the full generator identity, not a current-code export.
        for algorithm, seed, digits, expected in (
            ("SHA1", b"12345678901234567890", 8, "94287082"),
            ("SHA256", b"12345678901234567890123456789012", 8, "46119246"),
            ("SHA512", b"1234567890" * 6 + b"1234", 8, "90693936"),
        ):
            assert totp({"secret": base64.b32encode(seed).decode(), "algorithm": algorithm,
                         "period": 30, "digits": digits}, 59) == expected
        for algorithm, seed, expected in (
            ("SHA1", b"12345678901234567890", "65353130"),
            ("SHA256", b"12345678901234567890123456789012", "77737706"),
            ("SHA512", b"1234567890" * 6 + b"1234", "47863826"),
        ):
            assert totp({"secret": base64.b32encode(seed).decode(), "algorithm": algorithm,
                         "period": 30, "digits": 8}, 20000000000) == expected
        account = fixture.accounts[0]
        assert fixture.login({"username": account["username"], "password": account["password"]})["accepted"]
        assert fixture.check_totp({"username": account["username"], "code": totp(account["totp"], 20000000000)},
                                  timestamp=20000000000)["accepted"]
        assert not fixture.login({"username": account["username"], "password": "wrong"})["accepted"]
        assert not fixture.check_totp({"username": account["username"], "code": "not-a-code"})["accepted"]
    print("PASS: independent OpenSSL ES256 registration/assertion; negative challenge/origin/RP/signature/reuse/exclusion/UV/allow-list; owned password/TOTP and RFC 6238")


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unb64(value, maximum=65536):
    if not isinstance(value, str) or len(value) > maximum * 2:
        raise ValueError("Invalid bounded base64url")
    try:
        data = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("Invalid base64url") from error
    if len(data) > maximum or b64(data) != value:
        raise ValueError("Noncanonical base64url")
    return data


def run(openssl, *arguments):
    completed = subprocess.run([openssl, *arguments], capture_output=True, timeout=10, check=False)
    if completed.returncode:
        # Never include command stderr, credential bytes or key paths in state/log output.
        raise ValueError("OpenSSL operation failed")
    return completed.stdout


def cbor(value):
    def head(major, number):
        for limit, marker, width in ((24, 0, 0), (256, 24, 1), (65536, 25, 2),
                                     (2**32, 26, 4), (2**64, 27, 8)):
            if number < limit:
                return bytes([(major << 5) | (number if not width else marker)]) + (number.to_bytes(width, "big") if width else b"")
        raise ValueError("CBOR integer too large")
    if isinstance(value, int):
        return head(0 if value >= 0 else 1, value if value >= 0 else -1 - value)
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, str):
        encoded = value.encode("utf-8")
        return head(3, len(encoded)) + encoded
    if isinstance(value, dict):
        return head(5, len(value)) + b"".join(cbor(key) + cbor(item) for key, item in value.items())
    raise ValueError("Unsupported CBOR value")


def decode_cbor(data, offset=0):
    # Only definite-length types used by COSE and WebAuthn. Bounded recursion/items.
    budget = [256]

    def parse(position, depth):
        budget[0] -= 1
        if depth > 8 or budget[0] < 0 or position >= len(data):
            raise ValueError("CBOR bounds")
        initial = data[position]
        position += 1
        major, additional = initial >> 5, initial & 31
        if additional < 24:
            length = additional
        elif additional in (24, 25, 26, 27):
            width = 1 << (additional - 24)
            if position + width > len(data):
                raise ValueError("Truncated CBOR")
            length = int.from_bytes(data[position:position + width], "big")
            position += width
        else:
            raise ValueError("Unsupported CBOR")
        if major in (0, 1):
            return length if major == 0 else -1 - length, position
        if major in (2, 3):
            if length > 65536 or position + length > len(data):
                raise ValueError("CBOR string bounds")
            value = data[position:position + length]
            return value if major == 2 else value.decode("utf-8"), position + length
        if major == 5:
            if length > 32:
                raise ValueError("CBOR map bounds")
            result = {}
            for _ in range(length):
                key, position = parse(position, depth + 1)
                if not isinstance(key, (str, int)) or key in result:
                    raise ValueError("Invalid CBOR key")
                result[key], position = parse(position, depth + 1)
            return result, position
        raise ValueError("Unsupported CBOR type")

    return parse(offset, 0)


def verify_signature(openssl, cose, signature, message):
    if not isinstance(cose, dict) or set(cose) != {1, 3, -1, -2, -3} or (cose[1], cose[3], cose[-1]) != (2, -7, 1):
        raise ValueError("Only EC2/ES256/P-256 is accepted")
    x, y = cose[-2], cose[-3]
    if not isinstance(x, bytes) or not isinstance(y, bytes) or len(x) != 32 or len(y) != 32:
        raise ValueError("Invalid P-256 coordinates")
    if not 8 <= len(signature) <= 80:
        raise ValueError("Invalid DER signature")
    # id-ecPublicKey + prime256v1 + uncompressed point. OpenSSL validates/uses the key.
    spki = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004") + x + y
    pem = b"-----BEGIN PUBLIC KEY-----\n" + base64.encodebytes(spki) + b"-----END PUBLIC KEY-----\n"
    with tempfile.TemporaryDirectory(prefix="wsurf-owned-verifier-") as directory:
        root = Path(directory)
        (root / "public.pem").write_bytes(pem)
        (root / "signature.der").write_bytes(signature)
        (root / "message.bin").write_bytes(message)
        run(openssl, "dgst", "-sha256", "-verify", str(root / "public.pem"),
            "-signature", str(root / "signature.der"), str(root / "message.bin"))


def totp(generator, timestamp):
    algorithm = generator["algorithm"].replace("-", "").lower()
    if algorithm not in ("sha1", "sha256", "sha512"):
        raise ValueError("Unsupported TOTP algorithm")
    period, digits = generator["period"], generator["digits"]
    if not isinstance(period, int) or not 1 <= period <= 65535 or not isinstance(digits, int) or not 6 <= digits <= 10:
        raise ValueError("Invalid TOTP parameters")
    counter = int(timestamp) // period
    digest = hmac.new(base64.b32decode(generator["secret"]), struct.pack(">Q", counter), algorithm).digest()
    offset = digest[-1] & 15
    number = int.from_bytes(digest[offset:offset + 4], "big") & 0x7fffffff
    return str(number % (10**digits)).zfill(digits)


class Fixture:
    def __init__(self, origin, openssl):
        self.origin, self.openssl = origin, openssl
        self.rp = "localhost"
        self.pending, self.credentials = {}, {}
        self.lock = threading.Lock()
        self.accounts = []
        for index in range(1, 11):
            username = f"owned-{index:02d}"
            generator = {"secret": base64.b32encode(secrets.token_bytes(32)).decode(),
                         "algorithm": ("SHA1", "SHA256", "SHA512")[(index - 1) % 3],
                         "period": 30 if index < 4 else 45,
                         "digits": 6 if index < 4 else 6 + (index % 5),
                         "issuer": "WSurf Owned Fixture", "sourceUsername": username}
            label = quote(generator["issuer"] + ":" + username, safe="")
            generator["otpauthURI"] = (f"otpauth://totp/{label}?secret={generator['secret']}"
                f"&issuer={quote(generator['issuer'])}&algorithm={generator['algorithm']}"
                f"&period={generator['period']}&digits={generator['digits']}")
            self.accounts.append({"id": username, "username": username, "userHandle": b64(username.encode()),
                                  "url": origin + "/login", "password": secrets.token_urlsafe(24), "totp": generator})

    def account(self, username):
        return next((item for item in self.accounts if item["username"] == username), None)

    def options(self, request):
        operation, username = request.get("operation"), request.get("username", "owned-01")
        uv = request.get("uv", "required")
        account = self.account(username)
        if (operation not in ("create", "get") or account is None or uv not in ("required", "preferred", "discouraged")
                or not isinstance(request.get("exclude", True), bool)):
            raise ValueError("Invalid operation, identity or UV")
        challenge, session = b64(secrets.token_bytes(32)), secrets.token_urlsafe(24)
        user = unb64(account["userHandle"])
        with self.lock:
            self.pending = {key: item for key, item in self.pending.items() if item["expires"] > time.monotonic()}
            if len(self.pending) >= 128 or (operation == "create" and len(self.credentials) >= 128):
                raise ValueError("Fixture ceremony capacity reached")
            ids = [key for key, item in self.credentials.items() if item["user"] == user]
            excluded = ids if request.get("exclude", True) else []
            policy = {"operation": operation, "challenge": challenge, "user": user, "uv": uv,
                      "allowed": ids, "excluded": excluded, "expires": time.monotonic() + 120}
            self.pending[session] = policy
        common = {"challenge": challenge, "timeout": 60000}
        if operation == "create":
            common.update(rp={"id": self.rp, "name": "WSurf Owned Fixture"},
                          user={"id": account["userHandle"], "name": username, "displayName": username},
                          pubKeyCredParams=[{"type": "public-key", "alg": -7}],
                          authenticatorSelection={"userVerification": uv}, attestation="direct",
                          excludeCredentials=[{"type": "public-key", "id": b64(item)} for item in excluded])
        else:
            common.update(rpId=self.rp, userVerification=uv, userHandle=account["userHandle"],
                          allowCredentials=[{"type": "public-key", "id": b64(item)} for item in ids])
        return {"session": session, "publicKey": common}

    def verify(self, envelope):
        session, credential = envelope["session"], envelope["credential"]
        with self.lock:
            policy = self.pending.pop(session, None)  # every attempted challenge is single-use
            if not policy or policy["expires"] <= time.monotonic():
                raise ValueError("Expired or consumed challenge")
            if not isinstance(credential, dict) or credential.get("type") != "public-key":
                raise ValueError("Expected public-key credential")
            credential_id = unb64(credential["rawId"], 1024)
            if not credential_id or credential["id"] != b64(credential_id):
                raise ValueError("Credential identity mismatch")
            response = credential["response"]
            if not isinstance(response, dict):
                raise ValueError("Invalid credential response")
            client_bytes = unb64(response["clientDataJSON"], 8192)
            client = json.loads(client_bytes)
            expected_type = "webauthn.create" if policy["operation"] == "create" else "webauthn.get"
            if (not isinstance(client, dict) or client.get("type") != expected_type or client.get("challenge") != policy["challenge"]
                    or client.get("origin") != self.origin or client.get("crossOrigin") is not False
                    or "topOrigin" in client):
                raise ValueError("Client challenge/origin/type mismatch")
            if policy["operation"] == "create":
                if credential_id in policy["excluded"]:
                    raise ValueError("Credential excluded")
                if credential_id in self.credentials:
                    raise ValueError("Credential already registered")
                attestation = unb64(response["attestationObject"])
                att, end = decode_cbor(attestation)
                if end != len(attestation) or not isinstance(att, dict) or set(att) != {"fmt", "authData", "attStmt"}:
                    raise ValueError("Invalid attestation object")
                auth = att["authData"]
                if (att["fmt"] != "packed" or not isinstance(att["attStmt"], dict)
                        or set(att["attStmt"]) != {"alg", "sig"} or att["attStmt"]["alg"] != -7):
                    raise ValueError("Fixture requires ES256 self-attestation, not a hardware claim")
            else:
                auth = unb64(response["authenticatorData"], 4096)
            if not isinstance(auth, bytes) or len(auth) < 37 or auth[:32] != hashlib.sha256(self.rp.encode()).digest():
                raise ValueError("RP hash mismatch")
            flags = auth[32]
            if not flags & 1 or (policy["uv"] == "required" and not flags & 4):
                raise ValueError("Missing UP/UV")
            if flags & ~0x45 or auth[33:37] != bytes(4):
                raise ValueError("Unexpected flags or software counter")
            if policy["operation"] == "create":
                if not flags & 0x40 or len(auth) < 55 or auth[37:53] != bytes(16):
                    raise ValueError("Missing software attested credential data")
                length = int.from_bytes(auth[53:55], "big")
                if not 1 <= length <= 1024 or auth[55:55 + length] != credential_id:
                    raise ValueError("Attested credential identity mismatch")
                cose, end = decode_cbor(auth, 55 + length)
                if end != len(auth):
                    raise ValueError("Unexpected authenticator data")
                verify_signature(self.openssl, cose, att["attStmt"]["sig"], auth + hashlib.sha256(client_bytes).digest())
                self.credentials[credential_id] = {"user": policy["user"], "cose": cose}
            else:
                stored = self.credentials.get(credential_id)
                if flags & 0x40 or len(auth) != 37 or not stored or credential_id not in policy["allowed"]:
                    raise ValueError("Unknown/disallowed credential")
                if stored["user"] != policy["user"] or unb64(response["userHandle"], 64) != stored["user"]:
                    raise ValueError("User handle mismatch")
                verify_signature(self.openssl, stored["cose"], unb64(response["signature"], 80),
                                 auth + hashlib.sha256(client_bytes).digest())
        return {"accepted": True, "operation": policy["operation"], "credentialID": b64(credential_id),
                "userHandle": b64(policy["user"]), "uv": bool(flags & 4)}

    def login(self, request):
        account = self.account(request.get("username"))
        accepted = bool(account and isinstance(request.get("password"), str)
                        and hmac.compare_digest(account["password"], request["password"]))
        return {"accepted": accepted, "username": account["username"] if accepted else None}

    def check_totp(self, request, timestamp=None):
        account, code = self.account(request.get("username")), request.get("code")
        accepted = bool(account and isinstance(code, str) and code.isascii()
                        and hmac.compare_digest(totp(account["totp"], time.time() if timestamp is None else timestamp), code))
        return {"accepted": accepted, "username": account["username"] if accepted else None}


WEBAUTHN_PAGE = r"""<!doctype html><meta charset="utf-8"><title>Owned WSurf credential fixture</title>
<script>
const atDocumentStart = navigator.credentials?.create?.__wsurfOwnedProbe === true;
</script>
<h1>Owned WebAuthn fixture</h1>
<p>All ceremonies require a foreground button, native confirmation and fresh UV when required.
Native adapters reject iframes with unknown native policy. No Apple fallback.</p>
<label>Identity <select id="username"></select></label>
<label>UV <select id="uv"><option>required</option><option>preferred</option><option>discouraged</option></select></label>
<p><button id="create">Register</button> <button id="get">Assert</button>
<button id="exclude">Excluded registration</button> <button id="abort">Abort pending assertion</button>
<button id="preabort">Already-aborted assertion</button> <button id="rp">Invalid RP</button>
<button id="plain">Non-public-key behavior</button> <button id="iframe">Iframe rejection</button>
<button id="hidden">Hidden iframe rejection</button> <button id="replace">Replace pending iframe</button>
<button id="navigate">Navigate during pending request</button></p>
<p><a href="/login">Password/TOTP login</a> | <a href="/username">Username-first login</a></p>
<pre id="result"></pre><div id="frames"></div>
<script>
const out = document.querySelector('#result');
const show = v => out.textContent = JSON.stringify(v, null, 2);
const check = (value, message) => { if (!value) throw Error(message); };
const encode = value => {
  check(value instanceof ArrayBuffer, 'response is not an ArrayBuffer');
  return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
};
const decode = value => Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+'='.repeat((4-value.length%4)%4)), c=>c.charCodeAt(0)).buffer;
async function api(path, body) {
  const response = await fetch(path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
  const value = await response.json();
  if (!response.ok) throw Error(value.error || response.status);
  return value;
}
function options(pk, operation) {
  // Deliberate nonzero-offset views catch adapters that accidentally encode the backing buffer.
  const view = value => { const bytes=new Uint8Array(decode(value));const padded=new Uint8Array(bytes.length+7);
    padded.fill(0xee);padded.set(bytes,3);return new DataView(padded.buffer,3,bytes.length); };
  const result = {...pk, challenge:view(pk.challenge)};
  delete result.userHandle;
  if (operation === 'create') result.user = {...pk.user, id:view(pk.user.id)};
  const list = operation === 'create' ? 'excludeCredentials' : 'allowCredentials';
  result[list] = pk[list].map(item=>({...item,id:decode(item.id)}));
  return result;
}
function serialize(credential, operation, challenge) {
  check(credential instanceof PublicKeyCredential, 'PublicKeyCredential prototype');
  check(credential.rawId instanceof ArrayBuffer, 'rawId ArrayBuffer');
  check(credential.type === 'public-key' && credential.id === encode(credential.rawId), 'credential ID');
  const r = credential.response;
  check(r instanceof (operation === 'create' ? AuthenticatorAttestationResponse : AuthenticatorAssertionResponse), 'response prototype');
  const client = JSON.parse(new TextDecoder().decode(r.clientDataJSON));
  check(client.challenge === challenge && client.origin === location.origin && client.crossOrigin === false, 'byte-exact client data');
  check(JSON.stringify(credential.getClientExtensionResults()) === '{}', 'extension helper');
  const response = {clientDataJSON:encode(r.clientDataJSON)};
  if (operation === 'create') {
    response.attestationObject = encode(r.attestationObject);
    check(r.getPublicKeyAlgorithm() === -7, 'algorithm helper');
    check(r.getPublicKey() instanceof ArrayBuffer && r.getPublicKey().byteLength === 91, 'SPKI helper');
    check(r.getAuthenticatorData() instanceof ArrayBuffer && r.getAuthenticatorData().byteLength > 55, 'authenticator-data helper');
    check(JSON.stringify(r.getTransports()) === '["internal"]', 'transport helper');
  } else {
    response.authenticatorData = encode(r.authenticatorData);
    response.signature = encode(r.signature);
    response.userHandle = encode(r.userHandle);
    check(r.authenticatorData.byteLength === 37, 'assertion authenticator-data bytes');
  }
  const json = credential.toJSON();
  check(json.id === credential.id && json.rawId === encode(credential.rawId), 'credential JSON helper');
  return {type:credential.type,id:credential.id,rawId:encode(credential.rawId),response};
}
async function ceremony(operation, mode='normal') {
  check(atDocumentStart, 'RED: adapter absent at document start; native fixture handler not reached');
  const issued = await api('/webauthn/options', {operation, username:username.value, uv:uv.value, exclude:true});
  const pk = options(issued.publicKey, operation);
  if (mode === 'rp') { if (operation === 'create') pk.rp.id='not-owned.invalid'; else pk.rpId='not-owned.invalid'; }
  const controller = new AbortController();
  if (mode === 'preabort') controller.abort();
  const promise = navigator.credentials[operation]({publicKey:pk, signal:controller.signal});
  if (mode === 'abort') setTimeout(()=>controller.abort(), 300);
  if (mode === 'navigate') { setTimeout(()=>location.assign('/?navigated=1'), 300); return; }
  try {
    const credential = await promise;
    if (['abort','preabort','rp','exclude'].includes(mode)) throw Error('negative case unexpectedly resolved');
    const result = await api('/webauthn/verify', {session:issued.session, credential:serialize(credential, operation, issued.publicKey.challenge)});
    check(result.accepted, 'server rejected');
    show({atDocumentStart, server:result, helpers:'ArrayBuffer/prototype/byte-exact/helper checks accepted'});
  } catch(error) {
    const expected = {abort:'AbortError',preabort:'AbortError',rp:'SecurityError',exclude:'InvalidStateError'}[mode];
    if (expected && error.name !== expected) throw Error('expected '+expected+', got '+error.name+': '+error.message);
    show({atDocumentStart, case:mode, name:error.name, message:error.message, expectedRejection:!!expected});
    if (!expected) throw error;
  }
}
for (let i=1;i<=10;i++) username.add(new Option('owned-'+String(i).padStart(2,'0'), 'owned-'+String(i).padStart(2,'0')));
for (const [id,op,mode] of [['create','create','normal'],['get','get','normal'],['exclude','create','exclude'],
                           ['abort','get','abort'],['preabort','get','preabort'],['rp','get','rp'],['navigate','get','navigate']])
  document.querySelector('#'+id).onclick=()=>ceremony(op,mode).catch(e=>show({error:e.message,name:e.name}));
plain.onclick = async () => {
  const original = globalThis.__wsurfOwnedProbeOriginal;
  check(original && atDocumentStart, 'owned adapter not armed');
  async function outcome(fn) { try { const v=await fn({}); return ['resolved', v === null ? 'null' : typeof v]; } catch(e) { return ['rejected',e.name]; } }
  const expected = await outcome(original.get);
  const actual = await outcome(navigator.credentials.get.bind(navigator.credentials));
  check(JSON.stringify(expected) === JSON.stringify(actual), 'non-public-key behavior changed');
  show({nonPublicKey:{expected,actual},unchanged:true});
};
function frame(mode) {
  const f=document.createElement('iframe');
  f.src='/frame';
  f.allow='publickey-credentials-create; publickey-credentials-get';
  if(mode==='hidden') f.hidden=true;
  f.onload=()=>{
    f.contentWindow.postMessage({ownedFixtureCase:mode},location.origin);
    if(mode==='replace') setTimeout(()=>f.remove(),300);
  };
  document.querySelector('#frames').append(f);
}
iframe.onclick=()=>frame('normal'); hidden.onclick=()=>frame('hidden'); replace.onclick=()=>frame('replace');
addEventListener('message',event=>{
  if(event.origin===location.origin && event.data?.ownedFixtureResult)
    show({iframe:event.data.ownedFixtureResult, nativePolicy:'expected rejection; policy unavailable'});
});
show({atDocumentStart, secureContext:isSecureContext, origin:location.origin, nativeGate:'unverified until server accepts and native evidence is observed'});
</script>"""


FRAME_PAGE = r"""<!doctype html><meta charset="utf-8"><title>Owned rejected iframe</title>
<button id="request">Request in iframe</button><pre id="output"></pre><script>
async function start() {
  if (!navigator.credentials.get.__wsurfOwnedProbe) {
    output.textContent='RED: owned adapter absent; no native handler or platform fallback invoked';return;
  }
  const issued=await fetch('/webauthn/options',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({operation:'get',username:'owned-01',uv:'required'})}).then(r=>r.json());
  const pk=issued.publicKey;
  const d=s=>Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')+'='.repeat((4-s.length%4)%4)),c=>c.charCodeAt(0)).buffer;
  pk.challenge=d(pk.challenge);pk.allowCredentials=pk.allowCredentials.map(v=>({...v,id:d(v.id)}));
  let result;
  try { await navigator.credentials.get({publicKey:pk});result={case:'iframe',accepted:true,error:'FAIL: iframe unexpectedly accepted'}; }
  catch(e) { result={case:'iframe',accepted:false,name:e.name,message:e.message}; }
  output.textContent=JSON.stringify(result);
  parent.postMessage({ownedFixtureResult:result},location.origin);
}
request.onclick=()=>start();
addEventListener('message',event=>{
  if(event.origin===location.origin && event.source===parent && event.data?.ownedFixtureCase) start();
});
</script>"""


def login_page(path, query):
    username = parse_qs(query).get("username", [""])[0]
    # Values go through JSON/DOM properties, never concatenated into HTML attributes.
    return """<!doctype html><meta charset="utf-8"><title>Owned password/TOTP fixture</title>
<h1>Owned identity-preserving login</h1>
<form id="login"><label>Username <input id="username" name="username" autocomplete="username"></label>
<label id="passwordLabel">Password <input id="password" name="password" type="password" autocomplete="current-password"></label>
<button>Continue</button></form>
<form id="otp" hidden><label>Verification code <input name="code" autocomplete="one-time-code" inputmode="numeric"></label>
<button>Verify TOTP</button></form><pre id="result"></pre><script>
const identity=""" + json.dumps(username).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026") + """;
const first=""" + ("true" if path == "/username" else "false") + """;
username.value=identity; passwordLabel.hidden=first;
login.onsubmit=async e=>{
  e.preventDefault();
  if(first) { location.assign('/password?username='+encodeURIComponent(username.value));return; }
  const value=await fetch('/fixtures/login',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({username:username.value,password:password.value})}).then(r=>r.json());
  result.textContent=JSON.stringify(value);
  if(value.accepted){login.hidden=true;otp.hidden=false;otp.dataset.username=value.username;}
};
otp.onsubmit=async e=>{
  e.preventDefault();
  const value=await fetch('/fixtures/totp',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({username:otp.dataset.username,code:otp.elements.code.value})}).then(r=>r.json());
  result.textContent=JSON.stringify(value);
};
</script>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "OwnedCredentialFixture"

    def log_message(self, *_):
        pass  # request paths/bodies can contain identity; no credential state/log persistence

    def send(self, status, value, content_type="application/json"):
        body = json.dumps(value).encode() if content_type == "application/json" else value.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Permissions-Policy", "publickey-credentials-create=(self), publickey-credentials-get=(self)")
        self.end_headers()
        self.wfile.write(body)

    def owned(self):
        if not ipaddress.ip_address(self.client_address[0]).is_loopback:
            raise ValueError("Loopback clients only")
        if self.headers.get("Host") != urlsplit(self.server.fixture.origin).netloc:
            raise ValueError("Exact owned Host required")
        origin = self.headers.get("Origin")
        if origin is not None and origin != self.server.fixture.origin:
            raise ValueError("Cross-origin access denied")
        if self.headers.get("Sec-Fetch-Site") in ("cross-site",):
            raise ValueError("Cross-site access denied")

    def do_GET(self):
        try:
            self.owned()
            parsed = urlsplit(self.path)
            if parsed.path == "/health":
                self.send(200, {"owned": True, "origin": self.server.fixture.origin, "rpID": "localhost"})
            elif parsed.path == "/fixtures/accounts":
                self.send(200, {"accounts": self.server.fixture.accounts, "persistence": "memory-only owned data"})
            elif parsed.path == "/":
                self.send(200, WEBAUTHN_PAGE, "text/html")
            elif parsed.path == "/frame":
                self.send(200, FRAME_PAGE, "text/html")
            elif parsed.path in ("/login", "/username", "/password"):
                self.send(200, login_page(parsed.path, parsed.query), "text/html")
            else:
                self.send(404, {"error": "Not found"})
        except (ValueError, TypeError):
            self.send(403, {"error": "Not an owned fixture context"})

    def do_POST(self):
        try:
            self.owned()
            if self.headers.get_content_type() != "application/json":
                raise ValueError("JSON required")
            size = int(self.headers.get("Content-Length", "0"))
            if not 1 <= size <= 131072:
                raise ValueError("Bounded request required")
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError("JSON object required")
            actions = {"/webauthn/options": self.server.fixture.options, "/webauthn/verify": self.server.fixture.verify,
                       "/fixtures/login": self.server.fixture.login, "/fixtures/totp": self.server.fixture.check_totp}
            action = actions.get(urlsplit(self.path).path)
            if not action:
                self.send(404, {"error": "Not found"})
                return
            self.send(200, action(body))
        except (ValueError, KeyError, TypeError, UnicodeError, struct.error):
            self.send(400, {"error": "Fixture rejected request or credential"})
        except subprocess.TimeoutExpired:
            self.send(503, {"error": "Independent verifier timed out"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--openssl", default="/usr/bin/openssl")
    parser.add_argument("--cert", type=Path)
    parser.add_argument("--key", type=Path)
    parser.add_argument("--port", type=int, default=8443)
    args = parser.parse_args()
    if args.self_check:
        self_check(args.openssl)
        return
    if not args.cert or not args.key or not 1024 <= args.port <= 65535:
        parser.error("--cert, --key and a loopback port in 1024...65535 are required")
    if args.key.stat().st_mode & 0o077:
        parser.error("Owned TLS private key must not be group/world accessible")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.fixture = Fixture(f"https://localhost:{args.port}", args.openssl)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"Owned memory-only fixture: {server.fixture.origin}; no TLS trust installed")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
