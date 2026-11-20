#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Exercise development signing with synthetic profiles and the project's target settings."""

import datetime
import json
import plistlib
import runpy
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
            "Entitlements": {
                "com.apple.application-identifier": "EXAMPLE.io.wsagency.wsurf",
                CONTAINER: CLOUD[CONTAINER],
                SERVICES: "*",
                ENVIRONMENT: ["Production", "Development"],
                PUSH: "development",
            },
        }

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
        check = runpy.run_path(str(CHECKER))
        signed = {**self.base, **CLOUD, "com.apple.application-identifier": "EXAMPLE.io.wsagency.wsurf"}
        verify = check["check_artifact"]
        verify(signed, self.profile, self.extension, self.profile["UUID"])
        for key, value in [(CONTAINER, ["iCloud.example"]), (SERVICES, []), (ENVIRONMENT, "Production"), (PUSH, "production")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify({**signed, key: value}, self.profile, self.extension, self.profile["UUID"])
            with self.subTest(extension=key), self.assertRaises(ValueError):
                verify(signed, self.profile, {**self.extension, key: value}, self.profile["UUID"])
        for key in ["aps-environment", "com.apple.developer.icloud-container-development-container-identifiers"]:
            with self.subTest(extension=key), self.assertRaises(ValueError):
                verify(signed, self.profile, {**self.extension, key: []}, self.profile["UUID"])
        with self.assertRaises(ValueError):
            verify(signed, self.profile, self.extension, "another-profile")


if __name__ == "__main__":
    unittest.main()
