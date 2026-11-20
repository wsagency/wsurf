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
EXCHANGE = HOST + ".CredentialExchange"
TEAM = "5X68L55TNU"
BASE = Path(__file__).resolve().parents[1] / "WSurf/WSurf.entitlements"
PREFIX = "com.apple.developer."
SERVICES = PREFIX + "icloud-services"
CONTAINERS = PREFIX + "icloud-container-identifiers"
DEV_CONTAINERS = PREFIX + "icloud-container-development-container-identifiers"
DOMAINS = PREFIX + "associated-domains"
PROVIDER = PREFIX + "authentication-services.autofill-credential-provider"
GROUPS = "keychain-access-groups"
TEAM_KEY = PREFIX + "team-identifier"
CLOUD = {
    CONTAINERS: ["iCloud.io.wsagency.wsurf"],
    SERVICES: ["CloudKit"],
    PREFIX + "icloud-container-environment": "Development",
    PREFIX + "aps-environment": "development",
}
APP_ID = "com.apple.application-identifier"


def read_plist(*args):
    return plistlib.loads(subprocess.check_output(args, stderr=subprocess.DEVNULL))


def read_profile(path):
    return read_plist("/usr/bin/security", "cms", "-D", "-i", path)


def profile_prefix(profile, bundle_id):
    grants = profile["Entitlements"]
    if "OSX" not in profile["Platform"] or not profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        raise ValueError(f"{bundle_id} needs a macOS development profile with registered devices")
    if profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError(f"the profile for {bundle_id} has expired")
    if profile.get("TeamIdentifier") != [TEAM] or grants.get(TEAM_KEY) != TEAM or not profile.get("DeveloperCertificates"):
        raise ValueError(f"the profile for {bundle_id} needs the WSurf team and a signing certificate")
    if grants.get(PROVIDER) is not True:
        raise ValueError(f"the profile for {bundle_id} must grant {PROVIDER}")
    for prefix in profile["ApplicationIdentifierPrefix"]:
        if grants.get(APP_ID) == f"{prefix}.{bundle_id}":
            return prefix
    raise ValueError(f"the profile must grant the exact {bundle_id} app ID")


def values(value):
    if isinstance(value, str):
        return [value]
    return value if isinstance(value, list) else []


def required_host_claims(prefix):
    return {GROUPS: [f"{prefix}.{HOST}"], DOMAINS: ["webcredentials:wsurf.app"], PROVIDER: True, **CLOUD}


def check_host_profile(profile):
    prefix = profile_prefix(profile, HOST)
    grants = profile["Entitlements"]
    required = required_host_claims(prefix)
    # Wildcards are allowed only on the profile side. Keychain groups are scoped to the App ID prefix.
    groups = values(grants.get(GROUPS))
    for group in required[GROUPS]:
        if group in groups:
            continue
        prefixes = (grant[:-1] for grant in groups if isinstance(grant, str) and grant.startswith(prefix + ".") and grant.endswith("*"))
        if not any(group.startswith(allowed) for allowed in prefixes):
            raise ValueError(f"the host profile must grant {GROUPS} for {group}")
    expected = {DOMAINS: required[DOMAINS], **CLOUD, DEV_CONTAINERS: CLOUD[CONTAINERS]}
    for key, value in expected.items():
        allowed = values(grants.get(key))
        if (key in (DOMAINS, SERVICES) and "*" in allowed) or all(item in allowed for item in values(value)):
            continue
        raise ValueError(f"the host profile must grant {key} for {value}")
    return prefix


def development_entitlements(base, profile):
    check_host_profile(profile)
    return {**base, **CLOUD}


def cloud_keys(signed):
    return {key for key in signed if key in ("aps-environment", PREFIX + "aps-environment")
            or key.startswith((PREFIX + "icloud-", PREFIX + "ubiquity-"))}


def check_signed(signed, required, identifier):
    for key, expected in required.items():
        actual = signed.get(key)
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"the signature for {identifier} must carry {key} = {expected}")


def check_artifact(signed, profile, extension, exchange_profile, expected_uuid):
    prefix = check_host_profile(profile)
    profile_prefix(exchange_profile, EXCHANGE)
    if profile["UUID"].lower() != expected_uuid.lower():
        raise ValueError("the app embeds a different provisioning profile")
    check_signed(signed, {APP_ID: profile["Entitlements"][APP_ID], TEAM_KEY: TEAM, **required_host_claims(prefix)}, HOST)
    check_signed(extension, {APP_ID: exchange_profile["Entitlements"][APP_ID], TEAM_KEY: TEAM, PROVIDER: True}, EXCHANGE)
    for claims, allowed, identifier in ((signed, CLOUD.keys(), HOST), (extension, set(), EXCHANGE)):
        extras = cloud_keys(claims) - allowed
        if extras:
            raise ValueError(f"{identifier} has unexpected iCloud or push entitlements: {', '.join(sorted(extras))}")


def signed_entitlements(bundle, identifier, profile):
    # Code signing requirements match a certificate by its SHA-1 fingerprint.
    leaves = [f'certificate leaf = H"{hashlib.sha1(cert).hexdigest()}"' for cert in profile["DeveloperCertificates"]]
    if not leaves:
        raise ValueError(f"the profile for {identifier} grants no signing certificates")
    allowed_leaf = " or ".join(leaves)
    requirement = (f'anchor apple generic and identifier "{identifier}" '
                   'and certificate leaf[subject.CN] = "Apple Development:"* '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.12] exists '
                   f'and certificate leaf[subject.OU] = "{TEAM}" and ({allowed_leaf})')
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, bundle])
    if result.returncode:
        raise ValueError(f"{identifier} needs a valid signature from an Apple Development certificate in its profile")
    return read_plist("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", bundle)


def verify(app, expected_uuid):
    extension = app / "Contents/PlugIns/WSurfCredentialExchange.appex"
    host_profile = read_profile(app / "Contents/embedded.provisionprofile")
    signed = signed_entitlements(app, HOST, host_profile)
    exchange_profile = read_profile(extension / "Contents/embedded.provisionprofile")
    exchange_signed = signed_entitlements(extension, EXCHANGE, exchange_profile)
    check_artifact(signed, host_profile, exchange_signed, exchange_profile, expected_uuid)


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
