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
# Real signal, kept even when it sits in a host os_log line (a crash report, a failed assertion) and even in a dropped record.
KEEP_HOST = re.compile(
    r" \[fault\] |[Ff]atal error|Assertion failed|Assertion failure|Precondition failed"
    r"|Terminating app due to uncaught exception|NSInternalInconsistencyException|Thread \d+ Crashed|EXC_[A-Z_]+"
    r"|SIG(?:TRAP|SEGV|ABRT|ILL|BUS|KILL)|Test crashed with signal|Restarting after unexpected exit|reason=Crash"
    r"|exceeded execution time allowance"
)
KEEP_ERROR = re.compile(r": error: |error: -\[")
KEEP_ALWAYS = re.compile(KEEP_HOST.pattern + "|" + KEEP_ERROR.pattern)
# Lines that end a test run or flag trouble: the held "started" lines are printed before them.
TROUBLE = re.compile(
    r"Restarting after unexpected exit|crashed|Thread \d+ Crashed|EXC_[A-Z_]+|SIG(?:TRAP|SEGV|ABRT|ILL|BUS|KILL)|[Ff]atal error"
    r"|Terminating app due to uncaught exception|Test crashed with signal|exceeded its time limit"
    r"|exceeded execution time allowance|reason=Crash"
)
# Framework and tool result lines that no deny pattern may ever remove.
PROTECTED = re.compile(r"^(?:✘|✔ Test run|◇ Test run|\*\*|::|===|---|error:|Test (?:Case|Suite) .* failed|\s*Executed \d|\s*↳)")
# Stdout and the os_log mirror share one pipe, so test output can be glued behind (part of) a host line. The host line is cut
# at the first of these markers: the test part goes on through the filter, only the host part is dropped.
SPLIT = re.compile(
    r"\u200b?(?:◇ (?:Test|Suite) |[✔✘] |Test Suite '|Test Case '|\*\* TEST|\s*Executed \d+ tests?|Test run with \d)"
    r"|/\S*?\.swift:\d+(?::\d+)?: error: "
)
GLUED_STARTED = re.compile(r"\u200b?◇ (?:Test|Suite) .*? started\.?\s*$")
CONTINUATION = re.compile(r"^(?:\t\"|\}$|Invalidation reason: |\), NS|    \"LocalDataTask )")
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
        self.counted = -1  # the count the last counter line showed
        self.in_dropped_record = False
        self.started: dict[str, str] = {}  # test key -> its "started" line, for tests with no result yet
        self.last_counter = time.monotonic()

    def feed(self, line: str) -> list[str]:
        text = line.lstrip("\u200b").rstrip("\r\n")
        out: list[str] = []
        if self.in_dropped_record and CONTINUATION.match(text):
            self.dropped += 1
            return out
        in_record, self.in_dropped_record = self.in_dropped_record, False
        host = HOST_LOG.match(text)
        if host:
            if not KEEP_HOST.search(text):
                marker = SPLIT.search(text, host.end())
                if marker is None:
                    if not KEEP_ERROR.search(text):
                        return self._drop(out)
                else:
                    self.dropped += 1  # the host part; the test part carries on as a line of its own
                    text = text[marker.start():].lstrip("\u200b")
                    line = text + "\n"
        elif in_record and DENY.search(text) and not PROTECTED.match(text) and not KEEP_ALWAYS.search(text):
            return self._drop(out)  # DENY applies only to host lines and to the rest of a dropped record
        else:
            glued = GLUED_STARTED.search(text)
            if glued and glued.start() > 0 and not KEEP_ALWAYS.search(text):
                prefix = text[: glued.start()]
                if prefix.strip():
                    out.append(prefix + "\n")
                text = text[glued.start():].lstrip("\u200b")
                line = text + "\n"
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
        if force and self.dropped == self.counted:
            return []
        self.last_counter = now
        self.counted = self.dropped
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

    raw_path = os.getenv("WSURF_CI_RAW_LOG")
    raw = open(raw_path, "ab", buffering=0) if raw_path else None  # byte for byte, before any filtering; opened first
    console = ConsoleFilter(raw_path) if raw_path and os.getenv("WSURF_CI_VERBOSE") != "1" else None
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    lines: queue.Queue[bytes | None] = queue.Queue()

    def read_output() -> None:
        assert process.stdout is not None
        try:
            for line in process.stdout:
                lines.put(line)
        finally:
            lines.put(None)

    def show(text: str) -> None:
        print(text, end="", flush=True)

    def own(text: str) -> None:
        """The watchdog's own lines bypass the filter and are part of the raw log."""
        show(text)
        if raw is not None:
            raw.write(text.encode("utf-8", errors="replace"))

    def emit(data: bytes) -> str:
        if raw is not None:
            raw.write(data)
        text = data.decode("utf-8", errors="replace")
        if console is None:
            show(text)
        else:
            for shown in console.feed(text):
                show(shown)
        return text

    def finish_console() -> None:
        if console is not None:
            for shown in console.flush_started() + console.counter(force=True):
                show(shown)

    threading.Thread(target=read_output, daemon=True).start()
    deadline = time.monotonic() + TOTAL_LIMIT_SECONDS
    saw_summary = False
    output_closed = False
    while True:
        try:
            line = lines.get(timeout=0.5)
        except queue.Empty:
            line = b""
        if line is None:
            output_closed = True
        if console is not None and not line:
            for shown in console.counter():
                show(shown)
        if line:
            text = emit(line)
            if not saw_summary and SUITE_SUMMARY.search(text):
                saw_summary = True
                deadline = min(deadline, time.monotonic() + FINALIZATION_LIMIT_SECONDS)
        if output_closed and process.poll() is not None:
            finish_console()
            return process.wait()
        if time.monotonic() >= deadline:
            reason = "test result finalization" if saw_summary else "test command"
            if console is not None:
                for shown in console.flush_started():
                    show(shown)
            own(f"::error::{reason} exceeded its time limit; saving process diagnostics\n")
            try:
                capture_diagnostics(process)
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                own(f"::warning::could not save all process diagnostics: {error}\n")
            finally:
                stop(process)
            # What the child printed while it was being stopped (its interruption banner, the .xcresult path) is signal.
            drain_until = time.monotonic() + 5
            while not output_closed and time.monotonic() < drain_until:
                try:
                    last = lines.get(timeout=0.5)
                except queue.Empty:
                    continue
                if last is None:
                    output_closed = True
                else:
                    emit(last)
            finish_console()
            return 124


if __name__ == "__main__":
    sys.exit(main())
