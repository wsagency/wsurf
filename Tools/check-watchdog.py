#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: Apache-2.0
"""Check the CI watchdog's timeout and privacy contract with its own throwaway child.

On a timeout the watchdog must terminate its child with exit 124 and may inspect only that child. Fake `ps` and
`sample` come first on PATH and merely record their arguments, so no host process is read. Exit codes pass through.
"""

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WATCHDOG = Path(__file__).resolve().parent / "run-xcodebuild-with-watchdog.py"


def watchdog(args: list[str], cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(WATCHDOG), "--", *args], cwd=cwd, env=env, capture_output=True, text=True, timeout=60
    )


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in ("ps", "sample"):
            fake = bin_dir / name
            fake.write_text(f'#!/bin/sh\necho "{name} $*" >> "{root}/calls.log"\n')
            fake.chmod(0o755)
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "WSURF_CI_TEST_LIMIT_SECONDS": "2"}
        pid_file = root / "child.pid"
        stop_file = root / "child.stop"
        # Cooperative child: exits by itself when the stop file appears or after 30s, so nothing needs a signal.
        child_script = (
            f'echo $$ > "{pid_file}"; i=0; '
            f'while [ ! -e "{stop_file}" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done'
        )
        try:
            timed_out = watchdog(["sh", "-c", child_script], root, env)
            child = int(pid_file.read_text())
            calls = (root / "calls.log").read_text().splitlines() if (root / "calls.log").exists() else []
            assert timed_out.returncode == 124, timed_out
            assert not any(call.startswith("ps ") for call in calls), f"host-wide process query: {calls}"
            samples = [call.split() for call in calls if call.startswith("sample ")]
            assert all(call[1] == str(child) for call in samples), f"sampled a process that is not ours: {calls}"
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("watchdog left its child running")
            assert watchdog(["sh", "-c", "exit 7"], root, env).returncode == 7
            assert watchdog(["true"], root, env).returncode == 0
        finally:
            # Never signal a pid: ask our own child to stop, and give it a bounded moment before the directory goes.
            stop_file.touch()
            if pid_file.exists():
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        os.kill(int(pid_file.read_text()), 0)  # signal 0 only tests existence
                    except (ProcessLookupError, ValueError):
                        break
                    time.sleep(0.1)
    print("watchdog: timeout and privacy contract holds")


if __name__ == "__main__":
    main()
