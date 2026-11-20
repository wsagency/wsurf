#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Exercise development signing with synthetic profiles and the project's target settings."""

import datetime
import json
import plistlib
import runpy
from unittest.mock import patch
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "WSurf/WSurf.entitlements"
EXTENSION = ROOT / "WSurfCredentialExchange/WSurfCredentialExchange.entitlements"
CHECKER = ROOT / "Tools/check-icloud-development-signing.py"
CONTAINER = "com.apple.developer.icloud-container-identifiers"
SERVICES = "com.apple.developer.icloud-services"
ENVIRONMENT = "com.apple.developer.icloud-container-environment"
PUSH = "com.apple.developer.aps-environment"
CLOUD = {
    CONTAINER: ["iCloud.io.wsagency.wsurf"],
    SERVICES: ["CloudKit"],
    ENVIRONMENT: "Development",
    PUSH: "development",
}


APP = "io.wsagency.wsurf"
EXCHANGE = APP + ".CredentialExchange"
APP_ID = "com.apple.application-identifier"
TEAM = "5X68L55TNU"
TEAM_KEY = "com.apple.developer.team-identifier"
DEV_CONTAINERS = "com.apple.developer.icloud-container-development-container-identifiers"
KV_STORE = "com.apple.developer.ubiquity-kvstore-identifier"
GROUPS = "keychain-access-groups"
DOMAINS = "com.apple.developer.associated-domains"
PROVIDER = "com.apple.developer.authentication-services.autofill-credential-provider"


class DevelopmentSigningTests(unittest.TestCase):
    def test_only_the_host_has_the_opt_in_for_debug_and_release(self):
        project = json.loads(subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", ROOT / "WSurf.xcodeproj/project.pbxproj"]
        ))["objects"]
        for target in project.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            configs = project[target["buildConfigurationList"]]["buildConfigurations"]
            for config in configs:
                build = project[config]["buildSettings"]
                with self.subTest(target=target["name"], config=project[config]["name"]):
                    if target["name"] == "WSurf":
                        self.assertEqual(build.get("WSURF_HOST_ENTITLEMENTS"), "WSurf/WSurf.entitlements")
                        self.assertEqual(build["CODE_SIGN_ENTITLEMENTS"], "$(WSURF_HOST_ENTITLEMENTS)")
                    elif target["name"] == "WSurfCredentialExchange":
                        self.assertEqual(build["CODE_SIGN_ENTITLEMENTS"], str(EXTENSION.relative_to(ROOT)))
                    else:
                        self.assertNotIn("WSURF_HOST_ENTITLEMENTS", build.get("CODE_SIGN_ENTITLEMENTS", ""))

    def setUp(self):
        self.base = plistlib.loads(BASE.read_bytes())
        self.extension = plistlib.loads(EXTENSION.read_bytes())
        self.profile = {
            "UUID": "synthetic-profile",
            "Platform": ["OSX"],
            "ExpirationDate": datetime.datetime(2099, 1, 1),
            "ProvisionedDevices": ["synthetic-device"],
            "ApplicationIdentifierPrefix": ["EXAMPLE"],
            "TeamIdentifier": [TEAM],
            "DeveloperCertificates": [b"same synthetic development certificate"],
            "Entitlements": {
                APP_ID: "EXAMPLE." + APP, TEAM_KEY: TEAM,
                DOMAINS: "*", GROUPS: ["EXAMPLE.*"], PROVIDER: True,
                CONTAINER: CLOUD[CONTAINER], DEV_CONTAINERS: CLOUD[CONTAINER],
                SERVICES: "*", ENVIRONMENT: ["Production", "Development"], PUSH: "development",
            },
        }
        self.exchange_profile = {
            **self.profile, "UUID": "exchange-profile",
            "Entitlements": {APP_ID: "EXAMPLE." + EXCHANGE, TEAM_KEY: TEAM, PROVIDER: True, GROUPS: ["EXAMPLE.*"]},
        }
        self.signed = {**self.base, **CLOUD, GROUPS: ["EXAMPLE." + APP], APP_ID: "EXAMPLE." + APP, TEAM_KEY: TEAM}
        self.signed_extension = {**self.extension, APP_ID: "EXAMPLE." + EXCHANGE, TEAM_KEY: TEAM}
        self.check = runpy.run_path(str(CHECKER))

    def verify(self, host=None, signed=None, extension=None, exchange=None, uuid="synthetic-profile"):
        # The CLI normally obtains these four independent documents from codesign and security cms.
        verify = self.check["verify"]
        with patch.dict(verify.__globals__, {
            "read_profile": lambda path: (exchange or self.exchange_profile) if ".appex" in str(path) else (host or self.profile),
            "signed_entitlements": lambda bundle, ident, profile: (extension or self.signed_extension) if ident == EXCHANGE else (signed or self.signed),
        }):
            verify(Path("fixture/WSurf.app"), uuid)

    @staticmethod
    def grants(profile, changes):
        return {**profile, "Entitlements": {**profile["Entitlements"], **changes}}

    def test_generated_entitlements_add_only_the_four_approved_host_keys(self):
        check = runpy.run_path(str(CHECKER))
        self.assertTrue(CLOUD.keys().isdisjoint(self.base))
        self.assertTrue(CLOUD.keys().isdisjoint(self.extension))
        self.assertEqual(check["development_entitlements"](self.base, self.profile), {**self.base, **CLOUD})

    def test_wrong_profile_or_missing_grant_is_rejected(self):
        check = runpy.run_path(str(CHECKER))
        for key, value in [
            (CONTAINER, ["*"]), (SERVICES, ["CloudDocuments"]), (ENVIRONMENT, ["Production"]),
            (PUSH, "production"), ("com.apple.application-identifier", "EXAMPLE.io.wsagency.other"),
        ]:
            with self.subTest(key=key):
                altered = {**self.profile, "Entitlements": {**self.profile["Entitlements"], key: value}}
                with self.assertRaises(ValueError):
                    check["development_entitlements"](self.base, altered)
        for changes in [{"ProvisionedDevices": []}, {"ExpirationDate": datetime.datetime(2000, 1, 1)}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                check["development_entitlements"](self.base, {**self.profile, **changes})

    def test_wrong_signed_environment_profile_or_extension_is_rejected(self):
        self.verify()
        for key, value in [(CONTAINER, ["iCloud.example"]), (SERVICES, []), (ENVIRONMENT, "Production"), (PUSH, "production")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify(signed={**self.signed, key: value})
            with self.subTest(extension=key), self.assertRaises(ValueError):
                self.verify(extension={**self.signed_extension, key: value})
        for key in ["aps-environment", DEV_CONTAINERS]:
            with self.subTest(extension=key), self.assertRaises(ValueError):
                self.verify(extension={**self.signed_extension, key: []})
        with self.assertRaises(ValueError):
            self.verify(uuid="another-profile")

    def test_host_baseline_grants_and_signed_values(self):
        for key, bad in [(GROUPS, ["OTHER.*"]), (DOMAINS, ["webcredentials:other.example"]), (PROVIDER, False)]:
            for value in [None, bad]:
                profile = self.grants(self.profile, {key: value})
                with self.subTest(key=key, value=value, mode="prepare"), self.assertRaises(ValueError):
                    self.check["development_entitlements"](self.base, profile)
                with self.subTest(key=key, value=value, mode="verify-grant"), self.assertRaises(ValueError):
                    self.verify(host=profile)
                with self.subTest(key=key, value=value, mode="verify-signed"), self.assertRaises(ValueError):
                    self.verify(signed={**self.signed, key: value})
        for group in ["EXAMPLE.*", "EXAMPLE.io.wsagency.*", "EXAMPLE." + APP]:
            for domains in ["*", ["*"], ["webcredentials:wsurf.app"]]:
                with self.subTest(group=group, domains=domains):
                    self.verify(host=self.grants(self.profile, {GROUPS: [group], DOMAINS: domains}))
        for wrong in ["*", "OTHER.*", "EXAMPLE.io.other.*", "EXAMPLE.io.*.wsurf"]:
            with self.subTest(keychain_grant=wrong), self.assertRaises(ValueError):
                self.verify(host=self.grants(self.profile, {GROUPS: [wrong]}))
        for key, value in [(GROUPS, ["EXAMPLE.*"]), (DOMAINS, ["*"]), (PROVIDER, 1)]:
            with self.subTest(signed=key), self.assertRaises(ValueError):
                self.verify(signed={**self.signed, key: value})

    def test_both_container_grants_must_include_the_host_container(self):
        other = ["iCloud.example.other"]
        for key in [CONTAINER, DEV_CONTAINERS]:
            for value in [None, other, ["*"]]:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    self.check["development_entitlements"](self.base, self.grants(self.profile, {key: value}))
        # A profile can grant different additional containers in Development and Production.
        self.verify(host=self.grants(self.profile, {
            CONTAINER: ["iCloud.example.prod", *CLOUD[CONTAINER]], DEV_CONTAINERS: [*CLOUD[CONTAINER], "iCloud.example.dev"],
        }))

    def test_host_rejects_unexpected_cloud_signature_keys(self):
        for key in [KV_STORE, DEV_CONTAINERS, "com.apple.developer.ubiquity-container-identifiers", "aps-environment"]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify(signed={**self.signed, key: "unused"})

    def test_exchange_must_have_its_own_current_development_profile_and_grants(self):
        invalid = [
            self.profile,  # The very same certificate is authorized on both valid profiles.
            {**self.exchange_profile, "ExpirationDate": datetime.datetime(2000, 1, 1)},
            {**self.exchange_profile, "ProvisionedDevices": []},
            {**self.exchange_profile, "TeamIdentifier": ["OTHERTEAM0"]},
            {**self.exchange_profile, "DeveloperCertificates": []},
            self.grants(self.exchange_profile, {TEAM_KEY: "OTHERTEAM0"}),
            self.grants(self.exchange_profile, {PROVIDER: False}),
        ]
        for index, profile in enumerate(invalid):
            with self.subTest(profile=index), self.assertRaises(ValueError):
                self.verify(exchange=profile)
        for key, value in [(TEAM_KEY, "OTHERTEAM0"), (APP_ID, "EXAMPLE." + APP), (PROVIDER, None), (PROVIDER, 1)]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.verify(extension={**self.signed_extension, key: value})


if __name__ == "__main__":
    unittest.main()
