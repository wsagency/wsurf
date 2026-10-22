#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
#
# Cross-implementation check of a passkey assertion: WSurf's own PKCS#8 import (PasskeyKeyEncoding) and assertion encoding
# (WebAuthnEncoding) sign authenticatorData || SHA256(clientDataJSON) for github.com, and OpenSSL verifies the DER signature with
# the public key it derives itself from the ORIGINAL key bytes. Keys: one written by OpenSSL, one by CryptoKit (Apple's PKCS#8
# encoder, the closest local stand-in for an Apple Passwords export). Needs only the Command Line Tools; no app build.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sources=WSurf/Web/Credentials

cat > "$work/stubs.swift" <<'EOF'
import Foundation
nonisolated enum CredentialVaultError: Error { case invalidData }
nonisolated enum WebsiteAuthenticatorError: Error { case invalidCredential, invalidRequest }
nonisolated struct WebAuthnClientData: Sendable { var origin: String; var topOrigin: String?; var crossOrigin: Bool; var rpID: String }
EOF
cat > "$work/main.swift" <<'EOF'
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
if arguments[1] == "--cryptokit-key" {
    try P256.Signing.PrivateKey().derRepresentation.write(to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}
let key = try PasskeyKeyEncoding.importPKCS8(Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let client = WebAuthnClientData(origin: "https://github.com", topOrigin: nil, crossOrigin: false, rpID: "github.com")
let clientDataJSON = WebAuthnEncoding.clientDataJSON(type: "webauthn.get", challenge: Data((0..<32).map { UInt8($0) }), client: client)
let authenticatorData = WebAuthnEncoding.assertionAuthenticatorData(
    rpID: "github.com", userVerified: true, backupEligible: true, backupState: true
)
guard authenticatorData.count == 37, authenticatorData.prefix(32) == Data(SHA256.hash(data: Data("github.com".utf8))),
      authenticatorData[32] == 0x1D, authenticatorData.suffix(4) == Data(count: 4) else {
    print("authenticatorData is not UP|UV|BE|BS with a zero counter under SHA-256(github.com)")
    exit(1)
}
var signed = authenticatorData
signed.append(Data(SHA256.hash(data: clientDataJSON)))
try signed.write(to: URL(fileURLWithPath: arguments[2] + "/data.bin"))
try key.signature(for: signed).derRepresentation.write(to: URL(fileURLWithPath: arguments[2] + "/sig.der"))
EOF
xcrun swiftc -O -o "$work/probe" "$work/stubs.swift" "$sources/PasskeyKeyEncoding.swift" "$sources/WebAuthnEncoding.swift" "$work/main.swift"

/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$work/sec1.pem"
/usr/bin/openssl pkcs8 -topk8 -nocrypt -in "$work/sec1.pem" -outform DER -out "$work/openssl.p8"
"$work/probe" --cryptokit-key "$work/cryptokit.p8"
for name in openssl cryptokit; do
  mkdir "$work/$name"
  "$work/probe" "$work/$name.p8" "$work/$name"
  /usr/bin/openssl pkey -inform DER -in "$work/$name.p8" -pubout -out "$work/$name/pub.pem"
  /usr/bin/openssl dgst -sha256 -verify "$work/$name/pub.pem" -signature "$work/$name/sig.der" "$work/$name/data.bin" >/dev/null
  echo "passkey assertion: OpenSSL verifies WSurf's signature for a $name-encoded key"
done
