#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Prepare or verify WSurf host entitlements for an Apple Development CloudKit build."""

import argparse
import datetime
import hashlib
import plistlib
import subprocess
import sys
from pathlib import Path


HOST = "io.wsagency.wsurf"
BASE = Path(__file__).resolve().parents[1] / "WSurf/WSurf.entitlements"
PREFIX = "com.apple.developer."
SERVICES = PREFIX + "icloud-services"
CLOUD = {
    PREFIX + "icloud-container-identifiers": ["iCloud.io.wsagency.wsurf"],
    SERVICES: ["CloudKit"],
    PREFIX + "icloud-container-environment": "Development",
    PREFIX + "aps-environment": "development",
}
APP_ID = "com.apple.application-identifier"


def read_plist(*args):
    return plistlib.loads(subprocess.check_output(args, stderr=subprocess.DEVNULL))


def read_profile(path):
    return read_plist("/usr/bin/security", "cms", "-D", "-i", path)


def check_profile(profile):
    grants = profile["Entitlements"]
    if "OSX" not in profile["Platform"] or not profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        raise ValueError("an installed macOS development profile with registered devices is required")
    if profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("the development profile has expired")
    if grants.get(APP_ID) not in [f"{prefix}.{HOST}" for prefix in profile["ApplicationIdentifierPrefix"]]:
        raise ValueError(f"the development profile must grant the exact {HOST} app ID")
    for key, value in CLOUD.items():
        allowed = grants.get(key)
        if isinstance(allowed, str):
            allowed = [allowed]
        expected = value if isinstance(value, list) else [value]
        if isinstance(allowed, list):
            if set(expected).issubset(allowed) or (key == SERVICES and "*" in allowed):
                continue
        raise ValueError(f"the host profile must grant {key} for {value}")


def development_entitlements(base, profile):
    check_profile(profile)
    return {**base, **CLOUD}


def check_artifact(signed, profile, extension, expected_uuid):
    check_profile(profile)
    if profile["UUID"].lower() != expected_uuid.lower():
        raise ValueError("the app embeds a different provisioning profile")
    if signed.get(APP_ID) != profile["Entitlements"][APP_ID]:
        raise ValueError("the signed host app ID differs from its embedded profile")
    for key, value in CLOUD.items():
        if signed.get(key) != value:
            raise ValueError(f"the host signature must carry {key} = {value}")
    for key in extension:
        if key in ("aps-environment", PREFIX + "aps-environment") or key.startswith((PREFIX + "icloud-", PREFIX + "ubiquity-")):
            raise ValueError(f"the credential exchange extension must omit {key}")


def signed_entitlements(bundle, identifier, profile):
    # Code signing requirements match a certificate by its SHA-1 fingerprint.
    leaves = [f'certificate leaf = H"{hashlib.sha1(cert).hexdigest()}"' for cert in profile["DeveloperCertificates"]]
    if not leaves:
        raise ValueError(f"the profile for {identifier} grants no signing certificates")
    allowed_leaf = " or ".join(leaves)
    requirement = (f'anchor apple generic and identifier "{identifier}" '
                   'and certificate leaf[subject.CN] = "Apple Development:"* '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.12] exists '
                   f'and ({allowed_leaf})')
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, bundle])
    if result.returncode:
        raise ValueError(f"{identifier} needs a valid signature from an Apple Development certificate in its profile")
    return read_plist("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", bundle)


def verify(app, expected_uuid):
    extension = app / "Contents/PlugIns/WSurfCredentialExchange.appex"
    host_profile = read_profile(app / "Contents/embedded.provisionprofile")
    signed = signed_entitlements(app, HOST, host_profile)
    exchange_profile = read_profile(extension / "Contents/embedded.provisionprofile")
    exchange_signed = signed_entitlements(extension, HOST + ".CredentialExchange", exchange_profile)
    check_artifact(signed, host_profile, exchange_signed, expected_uuid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="write the host entitlement plist to standard output")
    prepare.add_argument("profile", type=Path)
    inspect = commands.add_parser("verify", help="verify the signatures, embedded host profile and iCloud entitlements")
    inspect.add_argument("app", type=Path)
    inspect.add_argument("profile_uuid")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            base = plistlib.loads(BASE.read_bytes())
            sys.stdout.buffer.write(plistlib.dumps(development_entitlements(base, read_profile(args.profile))))
        else:
            verify(args.app, args.profile_uuid)
            print("Verified Apple Development signing for iCloud.io.wsagency.wsurf.")
    except (OSError, subprocess.CalledProcessError, KeyError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"WSurf development signing: {error}\n")


if __name__ == "__main__":
    main()
