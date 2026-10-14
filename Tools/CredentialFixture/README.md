# Credential fixture (Gate B)

A synthetic relying party for the user's own Gate B (G2) sign-in checks: password, TOTP
(RFC 6238, ±1 step) and ES256 WebAuthn. Python 3 stdlib + the system `openssl` only; state is in
memory (restart = reset); passwords, TOTP secrets and request bodies are never logged.

```sh
python3 Tools/CredentialFixture/server.py --origin https://HOST[:PORT] --cert PEM --key PEM [--bind ADDR]
```

You provide `HOST`, its certificate (trusted by the machine that browses it) and its DNS/hosts
entry; none are created or changed here. `HOST` is the WebAuthn rpID; a `:443` in `--origin` is
normalised away (browsers omit it), any other port is part of the expected origin. The server listens on
`127.0.0.1` unless `--bind` is given, and on the origin's port (443 if omitted).

Open the origin in the browser under test: set up the username, password and TOTP secret once per
run (use the values of the items you made in your own password manager), then run the password,
TOTP and passkey checks. The server verifies exact origin, rpID hash, challenge (single use, 5
minutes), clientData type, user-presence flag and the signature (`openssl dgst -sha256 -verify`),
and rejects a non-increasing signature counter (a counter that stays 0 is accepted, as platform
passkeys do). Registration accepts `fmt: none` and never replaces a stored key.

Limits: one user, no sessions, no attestation checks, no TOTP replay memory, ES256 only.
`--now UNIX` freezes the TOTP clock for the selftest and must not be used for real checks.

`python3 Tools/CredentialFixture/selftest.py` exercises the server over real HTTPS on localhost
with a throwaway CA, synthetic passwords and a synthetic P-256 passkey. It proves this server only;
it makes no claim about WSurf, Apple Passwords, platform authenticators or PRF.
