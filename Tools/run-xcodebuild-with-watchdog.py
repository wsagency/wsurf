#!/usr/bin/env python3
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

"""Run CI tests and stop xcodebuild if it hangs after the test summary.

With WSURF_CI_RAW_LOG set, every output line is appended byte for byte to that file first, and the console gets a compact
view (ConsoleFilter) unless WSURF_CI_VERBOSE=1. Without WSURF_CI_RAW_LOG the output passes through unchanged. The deadline
logic always looks at the raw line, and the watchdog's own ::error:: / ::warning:: lines bypass the filter.
"""

from __future__ import annotations

import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


SUITE_SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (?:passed|failed)")
TOTAL_LIMIT_SECONDS = int(os.getenv("WSURF_CI_TEST_LIMIT_SECONDS", 20 * 60))
FINALIZATION_LIMIT_SECONDS = int(os.getenv("WSURF_CI_FINALIZATION_LIMIT_SECONDS", 2 * 60))


# The host's os_log mirror (OS_ACTIVITY_DT_MODE=YES): microseconds and a time zone. xcodebuild's own timestamps have
# milliseconds and no zone, so they never match.
HOST_LOG = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6}[+-]\d{4} \S+\[\d+:\d+\] ")
# Always drop (system and own noise, see LOG-noise.md). They override the keep list below.
DENY = re.compile(
    r"Conn 0x0 is not a valid connection ID|CRASHSTRING: rdar://problem/28724618|XPCConnectionTerminationWatchdog"
    r"|Failed to set up CFPasteboardRef|Connection to 'pboard' server|networkd_settings_read_from_file_locked"
    r"|Sandbox restriction|XPCErrorDescription|Invalidation reason|\[NSCGS\]|AudioComponentPluginMgr"
    r"|Could not signal service com\.apple\.WebKit|\[autofill\] (?:save)?scriptReady"
    r"|kLSServerConnectionStatusProcessIsDaemonMask|\[cas\] |TCCAccessRequest_block_invoke|Handshake aborted"
    r"|does not allow access to RunningBoard|bootstrap_lookup2 for name of coreservicesd"
    r"|com\.apple\.linkd|Error registering app with intents framework|send_message_with_reply_sync\(\): XPC_ERROR"
    r"|\[assertion\] Error acquiring assertion"
)
# Kept even when they look like host noise.
KEEP_ALWAYS = re.compile(
    r" \[fault\] |[Ff]atal error|Assertion failed|Precondition failed|Terminating app due to uncaught exception"
    r"|NSInternalInconsistencyException|Thread \d+ Crashed|EXC_BAD_ACCESS|SIG(?:TRAP|SEGV|ABRT)|Test crashed with signal"
    r"|Restarting after unexpected exit"
)
# Lines that end a test run or flag trouble: the held "started" lines are printed before them.
TROUBLE = re.compile(
    r"Restarting after unexpected exit|crashed|Thread \d+ Crashed|EXC_BAD_ACCESS|SIG(?:TRAP|SEGV|ABRT)|[Ff]atal error"
    r"|Terminating app due to uncaught exception|Test crashed with signal|exceeded its time limit"
)
# Framework and tool result lines that no deny pattern may ever remove.
PROTECTED = re.compile(r"^(?:✘|✔ Test run|◇ Test run|\*\*|::|===|---|error:|Test (?:Case|Suite) .* failed|\s*Executed \d)")
# Stdout and the os_log mirror share one pipe, so a result can land in the middle of a host line. Such a line passes.
MIDLINE_RESULT = re.compile(r"✘|Test run with \d|\*\* TEST|Test Case '.*' failed|Executed \d+ tests?, with [1-9]")
CONTINUATION = re.compile(r"^(?:\t\"|\}$|\), NS|    \"LocalDataTask )")
STARTED = re.compile(r"^◇ ((?:Test|Suite) .*?) started\.?\s*$")
PASSED = re.compile(r"^✔ (Test (?!run with)(?:case )?.*?) passed after ([\d.]+) seconds?")
RESULT = re.compile(r"^[✔✘] ((?:Test|Suite) .*?) (?:passed|failed|with \d+ test cases? (?:passed|failed)|recorded)\b")
CASE_COUNT = re.compile(r" with \d+ test cases?$")
COUNTER_SECONDS = 30.0


class ConsoleFilter:
    """Compact console view. When in doubt a line passes: only host os_log mirror lines and known noise are dropped."""

    def __init__(self, raw_path: str) -> None:
        self.raw_path = raw_path
        self.dropped = 0
        self.in_dropped_record = False
        self.started: dict[str, str] = {}  # test key -> its "started" line, for tests with no result yet
        self.last_counter = time.monotonic()

    def feed(self, line: str) -> list[str]:
        text = line.lstrip("\u200b").rstrip("\r\n")
        out: list[str] = []
        if self.in_dropped_record and CONTINUATION.match(text):
            self.dropped += 1
            return out
        self.in_dropped_record = False
        if not PROTECTED.match(text) and not MIDLINE_RESULT.search(text) and DENY.search(text):
            return self._drop(out)
        if not KEEP_ALWAYS.search(text):
            if HOST_LOG.match(text) and not MIDLINE_RESULT.search(text):
                return self._drop(out)
        started = STARTED.match(text)
        if started:
            self.started[started.group(1)] = line  # held; printed only if no result follows
            return out
        passed = PASSED.match(text)
        if passed:
            self.settle(passed.group(1))
            if float(passed.group(2).rstrip(".") or 0) >= 1.0:
                out.append(line)
            else:
                self.dropped += 1
            return out
        result = RESULT.match(text)
        if result:
            self.settle(result.group(1))
        if TROUBLE.search(text):
            out.extend(self.flush_started())
        out.append(line)
        return out

    def settle(self, key: str) -> None:
        """A result for a test also settles its parameterized cases: they get no result line of their own."""
        key = CASE_COUNT.sub("", key)
        self.started.pop(key, None)
        function = key.removeprefix("Test ")
        for held in [k for k in self.started if k.startswith("Test case ") and k.endswith(" to " + function)]:
            del self.started[held]

    def _drop(self, out: list[str]) -> list[str]:
        self.dropped += 1
        self.in_dropped_record = True
        return out

    def flush_started(self) -> list[str]:
        held = list(self.started.values())
        self.started.clear()
        return held

    def counter(self, force: bool = False) -> list[str]:
        now = time.monotonic()
        if not force and now - self.last_counter < COUNTER_SECONDS:
            return []
        self.last_counter = now
        return [f"filtered {self.dropped} host-log lines (raw: {self.raw_path})\n"]


def capture_diagnostics(process: subprocess.Popen[str]) -> None:
    # Samples only the child this watchdog launched; never lists or samples other host processes.
    if process.poll() is not None:
        return
    directory = Path("build/ci-diagnostics")
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["sample", str(process.pid), "5", "-file", str(directory / "xcodebuild.txt")],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=15,
        check=False,
    )


def stop(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def main() -> int:
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        print("usage: run-xcodebuild-with-watchdog.py -- xcodebuild test ...", file=sys.stderr)
        return 2

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    lines: queue.Queue[bytes | None] = queue.Queue()
    raw_path = os.getenv("WSURF_CI_RAW_LOG")
    raw = open(raw_path, "ab", buffering=0) if raw_path else None  # byte for byte, before any filtering
    console = ConsoleFilter(raw_path) if raw_path and os.getenv("WSURF_CI_VERBOSE") != "1" else None

    def read_output() -> None:
        assert process.stdout is not None
        try:
            for line in process.stdout:
                lines.put(line)
        finally:
            lines.put(None)

    threading.Thread(target=read_output, daemon=True).start()
    deadline = time.monotonic() + TOTAL_LIMIT_SECONDS
    saw_summary = False
    output_closed = False
    while True:
        try:
            line = lines.get(timeout=0.5)
        except queue.Empty:
            line = ""
        if line is None:
            output_closed = True
        if console is not None and not line:
            for shown in console.counter():
                print(shown, end="", flush=True)
        if line:
            if raw is not None:
                raw.write(line)
            line = line.decode("utf-8", errors="replace")
            if console is None:
                print(line, end="", flush=True)
            else:
                for shown in console.feed(line):
                    print(shown, end="", flush=True)
            if not saw_summary and SUITE_SUMMARY.search(line):
                saw_summary = True
                deadline = min(deadline, time.monotonic() + FINALIZATION_LIMIT_SECONDS)
        if output_closed and process.poll() is not None:
            if console is not None:
                for shown in console.flush_started() + console.counter(force=True):
                    print(shown, end="", flush=True)
            return process.wait()
        if time.monotonic() >= deadline:
            reason = "test result finalization" if saw_summary else "test command"
            if console is not None:
                for shown in console.flush_started() + console.counter(force=True):
                    print(shown, end="", flush=True)
            print(f"::error::{reason} exceeded its time limit; saving process diagnostics", flush=True)
            try:
                capture_diagnostics(process)
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                print(f"::warning::could not save all process diagnostics: {error}", flush=True)
            finally:
                stop(process)
            return 124


if __name__ == "__main__":
    sys.exit(main())
