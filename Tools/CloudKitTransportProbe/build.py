#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Build and check the two-Mac Development transport probe."""

import argparse
import ctypes
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CHECK = runpy.run_path(str(ROOT / "Tools/check-icloud-development-signing.py"))


def compile_probe(executable, cache):
    subprocess.run([
        "/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "-target", "arm64-apple-macos26.0", "-module-cache-path", str(cache),
        str(HERE / "Probe.swift"), str(HERE / "OfflineChecks.swift"),
        "-o", str(executable),
    ], env={"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", **os.environ}, check=True)


def merged_source():
    def git(*args):
        return subprocess.check_output(["git", "-C", ROOT, *args], text=True).strip()
    commit = git("rev-parse", "HEAD")
    if git("status", "--porcelain") or commit not in git("rev-list", "--first-parent", "origin/main").splitlines():
        raise ValueError("sign the helper from a clean, validated commit on main")
    return commit


def signed_probe(profile_path, identity, output):
    commit = merged_source()
    profile = CHECK["read_profile"](profile_path)
    grants = profile["Entitlements"]
    requested = CHECK["development_entitlements"]({}, profile)
    for key in (CHECK["APP_ID"], CHECK["TEAM_KEY"]):
        requested[key] = grants[key]
    output = output.resolve()
    if not output.is_relative_to(ROOT / "build") or output.exists():
        raise ValueError("choose a new output directory inside this worktree's build folder")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".wsurf-probe-", dir=output.parent) as scratch:
        candidate = Path(scratch) / "verified"
        candidate.mkdir(mode=0o700)
        verify_candidate(candidate, profile_path, profile, identity, requested, commit)
        # Darwin's RENAME_EXCL atomically refuses an output another process has already published.
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        if rename(os.fsencode(candidate), os.fsencode(output), 0x00000004) != 0:
            number = ctypes.get_errno()
            raise OSError(number, os.strerror(number), output)
    print(f"Verified {output / 'WSurfCloudTransport.app'} from {commit}.")


def verify_candidate(candidate, profile_path, profile, identity, requested, commit):
    app = candidate / "WSurfCloudTransport.app"
    contents = app / "Contents"
    executable = contents / "MacOS" / "WSurfCloudTransport"
    executable.parent.mkdir(parents=True)
    info = {
        "CFBundleIdentifier": CHECK["HOST"],
        "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL",
        "CFBundleName": "WSurf Cloud Transport Probe",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "LSMinimumSystemVersion": "26.0",
        "LSBackgroundOnly": True,
        "WSurfDevelopmentTransportProbe": True,
        "WSurfProbeCommit": commit,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copyfile(profile_path, contents / "embedded.provisionprofile")
    entitlements = candidate / "Probe.entitlements"
    entitlements.write_bytes(plistlib.dumps(requested))
    compile_probe(executable, candidate.parent / "modules")
    subprocess.run([
        "/usr/bin/codesign", "--sign", identity, "--force", "--options", "runtime", "--timestamp=none",
        "--entitlements", entitlements, app,
    ], check=True)
    embedded = CHECK["read_profile"](contents / "embedded.provisionprofile")
    CHECK["check_host_profile"](embedded)
    if embedded["UUID"] != profile["UUID"]:
        raise ValueError("the embedded host profile differs from the selected profile")
    actual = CHECK["signed_entitlements"](app, CHECK["HOST"], embedded)
    if actual != requested:
        raise ValueError("the helper's signed entitlements differ from its restricted request")
    subprocess.run([executable, "self-test"], cwd=candidate, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    cmds = parser.add_subparsers(dest="command", required=True)
    cmds.add_parser("self-test", help="compile and test offline in this worktree's build directory")
    sign = cmds.add_parser("sign", help="build and sign the dedicated helper from merged source")
    sign.add_argument("profile", type=Path)
    sign.add_argument("identity", help="Apple Development signing identity selector")
    sign.add_argument("output", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "sign":
            signed_probe(args.profile, args.identity, args.output)
        else:
            scratch = ROOT / "build/icloud-transport"
            scratch.mkdir(parents=True, exist_ok=True)
            subprocess.run([sys.executable, "-B", HERE / "test_build.py"], check=True)
            with tempfile.TemporaryDirectory(dir=scratch) as directory:
                binary = Path(directory) / "offline-probe"
                compile_probe(binary, scratch / "modules")
                subprocess.run([binary, "self-test"], cwd=directory, check=True)
    except (OSError, KeyError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"WSurf transport helper: {error}\n")


if __name__ == "__main__":
    main()
