#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: Apache-2.0

"""Refuse to launch a test host whose built identity is not the isolated one.

Usage: check-built-identity.py DERIVED_DATA_PATH XCTESTRUN   (suffix from WSURF_BUNDLE_ID_SUFFIX)

Inspects the artifact `xcodebuild build-for-testing` produced: Info.plist and
code-signature identifiers of the app, the credential-exchange extension and the
five Chromium helpers, a deep strict signature check, and that XCTESTRUN is the
only generated run in this DerivedData and its test targets name this app and its
WSurfTests bundle (a run with no test target, or a target missing its host or
bundle, fails). The caller must then run tests with exactly `-xctestrun XCTESTRUN`.
Exits non-zero before any host launch.
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

PRODUCTION = "io.wsagency.wsurf"
HELPERS = {"": "", " (Alerts)": ".Alerts", " (GPU)": ".GPU", " (Plugin)": ".Plugin", " (Renderer)": ".Renderer"}


def bundle_id(bundle: Path) -> str:
    with (bundle / "Contents/Info.plist").open("rb") as file:
        return plistlib.load(file)["CFBundleIdentifier"]


def signed_id(bundle: Path) -> str:
    result = subprocess.run(["codesign", "-dv", str(bundle)], capture_output=True, text=True, check=False)
    match = re.search(r"^Identifier=(.+)$", result.stderr, re.MULTILINE)
    return match.group(1) if match else f"<unsigned: {result.stderr.strip()}>"


def test_targets(node: object):
    if isinstance(node, dict):
        if "TestHostPath" in node or "TestBundlePath" in node:
            yield node
        for value in node.values():
            yield from test_targets(value)
    elif isinstance(node, list):
        for value in node:
            yield from test_targets(value)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    suffix = os.environ.get("WSURF_BUNDLE_ID_SUFFIX", "")
    stage = sorted(key for key in os.environ if key.startswith("WSURF_STAGE"))
    if stage:
        print(f"::error::Stage environment inherited: {', '.join(stage)}")
        return 1
    if not re.fullmatch(r"\.[A-Za-z0-9][A-Za-z0-9-]*", suffix):
        print(f"::error::WSURF_BUNDLE_ID_SUFFIX={suffix!r} would build the production identity or an invalid one")
        return 1

    problems: list[str] = []
    expected = PRODUCTION + suffix
    products = (Path(sys.argv[1]) / "Build/Products").resolve()
    app = products / "Debug/WSurf.app"
    appex = app / "Contents/PlugIns/WSurfCredentialExchange.appex"
    wanted = {app: expected, appex: f"{expected}.CredentialExchange"}
    for name, kind in HELPERS.items():
        wanted[app / f"Contents/Frameworks/WSurf Helper{name}.app"] = f"{expected}.helper{kind}"
    for bundle, identifier in wanted.items():
        if not bundle.is_dir():
            problems.append(f"missing {bundle}")
            continue
        for label, found in (("Info.plist", bundle_id(bundle)), ("codesign", signed_id(bundle))):
            if found != identifier:
                problems.append(f"{bundle.name}: {label} identifier {found!r}, expected {identifier!r}")
    if app.is_dir():
        verify = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True, check=False
        )
        if verify.returncode != 0:
            problems.append(f"codesign --verify --deep --strict failed: {verify.stderr.strip()}")

    test_bundle = app / "Contents/PlugIns/WSurfTests.xctest"
    if not test_bundle.is_dir():
        problems.append(f"missing test bundle {test_bundle}")
    runs = sorted(products.glob("*.xctestrun"))
    chosen = Path(sys.argv[2]).resolve()
    if runs != [chosen]:
        problems.append(f"expected exactly one generated run {chosen}, found {[str(run) for run in runs]}")
    elif chosen.is_file():
        with chosen.open("rb") as file:
            document = plistlib.load(file)
        targets = list(test_targets(document))
        if not targets:
            problems.append(f"{chosen.name}: no test target")
        for target in targets:
            host = str(target.get("TestHostPath", "")).replace("__TESTROOT__", str(products))
            bundle = str(target.get("TestBundlePath", "")).replace("__TESTROOT__", str(products))
            bundle = bundle.replace("__TESTHOST__", host)
            if "__" in host or "__" in bundle or not host or not bundle:
                problems.append(f"{chosen.name}: unresolved or missing host {host!r} / bundle {bundle!r}")
                continue
            if Path(host).resolve() not in {app, app / "Contents/MacOS/WSurf"}:
                problems.append(f"{chosen.name}: TestHostPath is {host}, not this app")
            if Path(bundle).resolve() != test_bundle:
                problems.append(f"{chosen.name}: TestBundlePath is {bundle}, not {test_bundle}")
            host_id = target.get("TestHostBundleIdentifier")
            if host_id is not None and host_id != expected:
                problems.append(f"{chosen.name}: TestHostBundleIdentifier {host_id!r}, expected {expected!r}")

    for problem in problems:
        print(f"::error::{problem}")
    if not problems:
        print(f"Built identity verified: {expected}; run {chosen.name}; test bundle {test_bundle}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
