#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

"""Round-trip one synthetic MacSetting between two signed-in Macs over noninteractive SSH."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import subprocess
import sys
import time
import uuid


HERE = Path(__file__).resolve().parent
APP = "WSurfCloudTransport.app"
BINARY = APP + "/Contents/MacOS/WSurfCloudTransport"
STEPS = (("studio", "begin"), ("air", "answer"), ("studio", "confirm"), ("studio", "cleanup"))
RESULTS = {"begin": "PASS Studio wrote 125%.", "answer": "PASS Air acknowledged the trial at 150%.",
           "confirm": "PASS Studio read the 150% reply.\nPASS explicit-owner metadata matched its full-record tag.",
           "cleanup": "PASS Studio verified the stored reset."}

# Verify the same pinned signed archive on each Mac before executing its helper.
STAGE = """
import hashlib, os, pathlib, plistlib, shutil, subprocess, sys, tempfile
sha, commit, app_name = sys.argv[1:]
os.umask(0o077)
root = pathlib.Path(tempfile.mkdtemp(prefix="wsurf-settings-"))
try:
    archive = root / "probe.zip"
    with archive.open("xb") as stream:
        shutil.copyfileobj(sys.stdin.buffer, stream)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
        raise ValueError("archive digest mismatch")
    subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, root], check=True)
    app = root / app_name
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", app], check=True)
    with (app / "Contents/Info.plist").open("rb") as f:
        plist = plistlib.load(f)
    if (plist.get("WSurfProbeCommit") != commit or plist.get("WSurfDevelopmentTransportProbe") is not True
        or plist.get("CFBundleIdentifier") != "io.wsagency.wsurf"
        or plist.get("CFBundleExecutable") != "WSurfCloudTransport"):
        raise ValueError("unexpected probe identity")
    print(root)
except BaseException:
    shutil.rmtree(root)
    raise
"""


def checked_host(value):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.@-]*", value):
        raise argparse.ArgumentTypeError("use an SSH alias or local")
    return value


def remote(host, args, *, stdin=None):
    command = args if host == "local" else [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes",
        "--", host, shlex.join(args)]
    result = subprocess.run(command, stdin=stdin, capture_output=True, timeout=120)
    if result.returncode:
        # The Swift helper emits only a stable error name or numeric CloudKit code.
        lines = result.stderr.decode(errors="replace").splitlines()
        diagnostic = next((line for line in lines if line.startswith("Probe failed: ")), "transport or staging failure")
        raise RuntimeError(f"{host} exited {result.returncode} ({diagnostic})")
    return result.stdout.decode().strip()


def write_state(path, state):
    pending = path.with_suffix(".tmp")
    with pending.open("w") as stream:
        json.dump(state, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(pending, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def drive(state, persist, invoke):
    """Persist the next command so a restart can replay a lost response."""
    if state.get("aborted"):
        raise RuntimeError("this failed trial already reset its record")
    tags = state["tags"]
    for role in ("studio", "air"):
        if role not in tags:
            tag = invoke(role, "tag", None)
            if str(uuid.UUID(tag)) != tag:
                raise ValueError("invalid probe tag")
            tags[role] = tag
            persist()
    if tags["studio"] == tags["air"]:
        raise ValueError("the two endpoints report the same product model")
    for index in range(state["next"], len(STEPS)):
        role, verb = STEPS[index]
        peer = tags["studio" if role == "air" else "air"]
        try:
            status = invoke(role, verb, peer)
            if status != RESULTS[verb]:
                raise RuntimeError(f"unexpected result for {verb}")
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            state["error"] = str(error)
            persist()
            # A successful abort retains the original failure. An offline or foreign record retains the recovery state.
            if verb != "cleanup":
                try:
                    if invoke("studio", "cleanup", tags["air"]) != RESULTS["cleanup"]:
                        raise RuntimeError("unexpected result for cleanup")
                except (OSError, subprocess.SubprocessError, RuntimeError) as cleanup_error:
                    state["cleanup_error"] = str(cleanup_error)
                else:
                    state["aborted"] = True
                persist()
            raise
        state["steps"].append({"host": role, "command": verb, "result": status})
        state["next"] = index + 1
        state.pop("error", None)
        state.pop("cleanup_error", None)
        persist()
        print(status, flush=True)


def run(archive, pinned_sha, path, hosts, commit):
    if not re.fullmatch(r"[0-9a-f]{64}", pinned_sha) or hashlib.sha256(archive.read_bytes()).hexdigest() != pinned_sha:
        raise ValueError("archive SHA-256 differs from the verified signing output")
    config = {"archive_sha256": pinned_sha, "commit": commit, "hosts": hosts}
    if path.exists():
        state = json.loads(path.read_text())
        if state["source"] != config:
            raise ValueError("resume with the same archive, source and endpoints")
    else:
        state = {"source": config, "nonce": str(uuid.uuid4()), "dirs": {}, "tags": {}, "next": 0, "steps": []}
        write_state(path, state)
    if state["next"] == len(STEPS):
        print("PASS round trip and stored reset already verified")
        return

    for role, host in hosts.items():
        if role not in state["dirs"]:
            with archive.open("rb") as stream:
                directory = remote(host, ["python3", "-c", STAGE, pinned_sha, commit, APP], stdin=stream)
            if not Path(directory).is_absolute() or not Path(directory).name.startswith("wsurf-settings-"):
                raise ValueError("unexpected staging path")
            state["dirs"][role] = directory
            write_state(path, state)

    def invoke(role, verb, peer):
        directory = state["dirs"][role]
        arguments = ["settings-" + verb, state["nonce"]] + ([peer] if peer else [])
        code = "import os,sys; os.chdir(sys.argv[1]); os.execv(sys.argv[2],sys.argv[2:])"
        args = ["python3", "-c", code, directory, "./" + BINARY, *arguments]
        for attempt in range(4):
            try:
                return remote(hosts[role], args)
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                if attempt == 3 or any(reason in str(error) for reason in (
                    "unexpectedRecord", "developmentSignatureRequired", "receiptRequired", "alreadyCleaned", "useSecondMac")):
                    raise
                time.sleep(2 ** attempt)

    drive(state, lambda: write_state(path, state), invoke)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("sha256", help="SHA-256 of the verified signed helper archive")
    parser.add_argument("evidence", type=Path, help="owned evidence directory; use it again to resume")
    parser.add_argument("--studio", type=checked_host, required=True)
    parser.add_argument("--air", type=checked_host, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        commit = runpy.run_path(str(HERE / "build.py"))["merged_source"]()
        args.evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = args.evidence / "settings-trial.json"
        with (args.evidence / "settings-trial.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run(args.archive, args.sha256, path, {"studio": args.studio, "air": args.air}, commit)
        print("Evidence " + str(path))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Mac settings trial failed: {error}\n")


if __name__ == "__main__":
    main()
