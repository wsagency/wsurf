#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Offline tests for publishing a verified transport probe."""

from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


class ProbeBuildTests(unittest.TestCase):
    def test_standalone_helper_compiles_the_apps_setting_and_record_mapping(self):
        compile_probe = runpy.run_path(str(Path(__file__).with_name("build.py")))["compile_probe"]
        root = compile_probe.__globals__["ROOT"]
        with patch("subprocess.run") as command:
            compile_probe(Path("fixture"), Path("cache"))
        inputs = {Path(value) for value in command.call_args.args[0] if str(value).endswith(".swift")}
        self.assertIn(root / "WSurf/Sync/MacSettingChannel.swift", inputs)
        self.assertIn(root / "Packages/WSurfCore/Sources/WSurfCore/CloudKitRecordMapping.swift", inputs)

    def test_failed_signing_check_leaves_the_same_destination_available_for_retry(self):
        build = runpy.run_path(str(Path(__file__).with_name("build.py")))["signed_probe"]
        settings = build.__globals__
        check = settings["CHECK"]
        root = settings["ROOT"]
        scratch = root / "build/icloud-transport"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            path = Path(temp)
            output = path / "signed"
            fixture = path / "fixture.profile"
            fixture.write_bytes(b"synthetic profile")
            claims = {check["APP_ID"]: "fixture.app", check["TEAM_KEY"]: "fixture.team"}
            profile = {"UUID": "fixture", "Entitlements": claims}
            with (
                patch.dict(settings, merged_source=lambda: "a" * 40, compile_probe=lambda *args: None),
                patch.dict(check, read_profile=lambda _: profile, check_host_profile=lambda _: None,
                           development_entitlements=lambda *_: {}, signed_entitlements=lambda *_: {}),
                patch("subprocess.run") as tool,
            ):
                with self.assertRaisesRegex(ValueError, "entitlements"):
                    build(fixture, "fixture identity", output)
                self.assertFalse(output.exists(), "unverified bundle was published")
                self.assertEqual(set(path.iterdir()), {fixture})
                with patch.dict(check, signed_entitlements=lambda *_: claims), patch("builtins.print"):
                    build(fixture, "fixture identity", output)
                self.assertTrue((output / "WSurfCloudTransport.app/Contents/Info.plist").is_file())
                self.assertEqual(set(path.iterdir()), {fixture, output})
                with self.assertRaises(ValueError):
                    build(fixture, "fixture identity", output)
                self.assertTrue(tool.called)


if __name__ == "__main__":
    unittest.main()
