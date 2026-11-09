#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
"""Check the CI watchdog's timeout and privacy contract with its own throwaway child.

It also checks the compact console (WSURF_CI_RAW_LOG): the raw log equals the child's output byte for byte, every result,
failure, crash and time-limit line reaches the console, and the known host noise (including the CRASHSTRING and
XPCConnectionTerminationWatchdog bait lines) does not.

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


ZW = "\u200b"
NOISE_ONLY = "2026-11-09 09:50:34.217941+0100 WSurf[17395:89331466] [default] WebContent[17716] Conn 0x0 is not a valid connection ID."
HOST = "2026-11-09 09:50:34.217941+0100 WSurf[17395:89331466] "
XCODE_TS = "2026-11-09 10:01:11.769 xcodebuild[17295:89331162] [MT] IDETestOperationsObserverDebug: 646.767 elapsed -- Testing started completed."

# (line, what the console must show for it: False = nothing, True = the line itself, a string = that text, i.e. the test part
# of a line with host output glued in front). Order matters: the kept lines must appear in this order.
FIXTURE: list[tuple[str, bool | str | None]] = [
    ("=== Test", True),
    ("--- WSurf-Serial-1 (193 selection arguments, 1s into the tests)", True),
    (HOST + "[default] WebContent[17716] Conn 0x0 is not a valid connection ID.", False),
    (HOST + "[general] WebContent[17716] Connection to 'pboard' server had an error: <dictionary: 0x1ef00a080> { count = 1, contents =", False),
    ('\t"XPCErrorDescription" => <string: 0x1ef00a1c0> { string cache = 0x0, length = 18, contents = "Connection invalid" }', False),
    ("}", False),
    ("Invalidation reason: Connection init failed at lookup with error 159 - Sandbox restriction", False),
    (HOST + "[general] WebContent[17716] Failed to set up CFPasteboardRef 'Apple CFPasteboard general'. Error: <dictionary: 0x1> {", False),
    (HOST + "WebContent[17889] networkd_settings_read_from_file_locked Sandbox is preventing this process from reading", False),
    (HOST + "[autofill] scriptReady kind=password count=0", False),
    (HOST + "[autofill] saveScriptReady kind=password count=0", False),
    (HOST + "[NSCGS] Ignoring request to entangle context after pre-commit", False),
    (HOST + "[access] WebContent[17716] TCCAccessRequest_block_invoke: Connection invalid", False),
    (HOST + "[connection] WebContent[17716] Handshake aborted as the connection has been invalidated", False),
    (HOST + "[cas] WebContent[17716] CONNECT: Attempt to connect to launchservicesd prohibited because kLSServerConnectionStatusProcessIsDaemonMask is set.", False),
    (HOST + "[cas] WebContent[17716] CRASHSTRING: rdar://problem/28724618 Couldn't connect to launchservicesd.", False),
    (HOST + "[x] CRASHSTRING: rdar://problem/28724618 bait without the [cas] category", False),
    (HOST + "[connection] WebContent[17716] The sandbox in this process does not allow access to RunningBoard.", False),
    (HOST + "[sharedcache] WebContent[17716] checkinWithServer Failed bootstrap_lookup2 for name of coreservicesd, kern_return_t=#1100", False),
    (HOST + "[Connection] WebContent[17716] Missing com.apple.linkd.application-service mach-lookup entitlement", False),
    (HOST + "[Application] WebContent[17716] Error registering app with intents framework: Error Domain=LNProcessInstanceRegistryClientErrorDomain", False),
    (HOST + "Could not signal service com.apple.WebKit.WebContent: 113: Could not find specified service", False),
    (HOST + "[audiocomp] WebContent[17716] AudioComponentPluginMgr.mm:591   reg server remote proxy error", False),
    (HOST + "[ProcessSuspension] 0x1231981e0 - ProcessAssertion::acquireSync Failed to acquire RBS assertion 'XPCConnectionTerminationWatchdog' for process", False),
    (HOST + "[assertion] Error acquiring assertion: <Error Domain=RBSServiceErrorDomain Code=1", False),
    (HOST + "[pipeline] bootstrap: begin", False),
    ("◇ Test passingQuickly() started.", False),
    ("✔ Test passingQuickly() passed after 0.008 seconds.", False),
    ("◇ Test slowButFine() started.", False),
    ("✔ Test slowButFine() passed after 1.250 seconds.", True),
    ("◇ Test x() started.", False),
    ("◇ Test case passing 1 argument engine \u2192 .chromium to x(engine:) started.", False),
    (ZW + "◇ Test case passing 2 arguments engine \u2192 .webKit to x(engine:) started.", False),
    ("✔ Test x(engine:) with 2 test cases passed after 0.4 seconds.", False),
    ("✘ Test x() recorded an issue at A.swift:3:5: Expectation failed: (a \u2192 1) == (b \u2192 2)", True),
    (ZW + "✘ Test case passing 1 argument engine \u2192 .chromium to y(engine:) failed after 1.2 seconds with 1 issue.", True),
    ("✘ Test y(engine:) failed after 1.3 seconds with 1 issue.", True),
    ("✔ Suite FastTests passed after 0.003 seconds.", True),
    ("✘ Suite SlowTests failed after 2.5 seconds with 1 issue.", True),
    (XCODE_TS, True),
    ("✘ Test run with 3 tests in 1 suite failed after 2.0 seconds with 1 issue.", True),
    ("✔ Test run with 4 tests in 1 suite passed after 0.412 seconds.", True),
    ("✔ Test run with 1924 tests in 182 suites passed after 625.646 seconds.", True),
    ("Test Case '-[WSurfTests.X testY]' failed (0.010 seconds).", True),
    ("A.swift:12: error: -[WSurfTests.X testY] : XCTAssertTrue failed", True),
    ("\t Executed 94 tests, with 1 failure (0 unexpected) in 359.349 (359.386) seconds", True),
    # A result that lands in the middle of a host line (stdout and the os_log mirror share one pipe) must survive.
    (HOST + "[default] WebContent[1] Conn 0x0 is not a valid connection ID.\u2718 Test glued() failed after 0.1 seconds.",
     "\u2718 Test glued() failed after 0.1 seconds."),
    (HOST + "[default] WebContent[1] Conn 0x0 is not a valid connection ID.Test Suite 'GluedTests' failed at 2026-11-09 09:50:34.2.",
     "Test Suite 'GluedTests' failed at 2026-11-09 09:50:34.2."),
    (HOST + "[default] WebContent[1] Conn 0x0 is not a valid connection ID./p/PasteTests.swift:41: error: -[WSurfTests.PasteTests testA] : XCTAssertTrue failed",
     "/p/PasteTests.swift:41: error: -[WSurfTests.PasteTests testA] : XCTAssertTrue failed"),
    (HOST + "[x] Test case '-[WSurfTests.SlowTests testB]' exceeded execution time allowance of 120 seconds", True),
    # L3: host lines that report a crash are signal.
    (HOST + "[x] Exception Type: EXC_BAD_INSTRUCTION (SIGILL)", True),
    (HOST + "[x] Received SIGBUS", True),
    (HOST + "[x] Terminated with SIGKILL", True),
    (HOST + "[x] *** Assertion failure in -[WSurfFoo bar], WSurfFoo.m:12", True),
    (HOST + "[Process] WebProcessProxy::processDidTerminateOrFailedToLaunch: reason=Crash", True),
    # S1: DENY applies to host lines and dropped records only. After a dropped host line, these are still test output.
    (HOST + "[default] WebContent[17716] Conn 0x0 is not a valid connection ID.", False),
    ("/p/PasteTests.swift:42: error: -[WSurfTests.PasteTests testA] : XCTAssertNil failed: \"Connection to 'pboard' server had an error\"", True),
    (HOST + "[default] WebContent[17716] Conn 0x0 is not a valid connection ID.", False),
    ("/p/F.swift:9: Fatal error: Handshake aborted unexpectedly", True),
    (HOST + "[default] WebContent[17716] Conn 0x0 is not a valid connection ID.", False),
    ("/p/G.swift:3:1: error: cannot find 'XPCErrorDescription' in scope", True),
    (HOST + "[default] WebContent[17716] Conn 0x0 is not a valid connection ID.", False),
    ("    \u21b3 expected nothing, got a Sandbox restriction", True),
    (HOST + "[default] WebContent[17716] Conn 0x0 is not a valid connection ID.", False),
    ("/p/H.swift:5: error: -[X y] : failed " + HOST + "[default] WebContent[1] Conn 0x0 is not a valid connection ID.", True),
    ("WAIT-EXPIRED A.swift:9 after 25s", True),
    (HOST + "[logging] fault: something [fault] broke", True),
    (HOST + "[x] Received SIGTRAP in the test host", True),
    (HOST + "[x] Swift runtime: Fatal error: Index out of range", True),
    # Nothing settles these before the crash line below, so they are printed, in this order, just before it (checked below).
    ("◇ Test hanging() started.", None),
    # A glued start line is held like any other, so a test that then hangs is named.
    (HOST + "[x] some host text\u25c7 Test gluedHang() started.", None),
    ("Barrier\u25c7 Test gluedHang2() started.", "Barrier"),
    ("Restarting after unexpected exit, crash, or test timeout in X.y()", True),
    ("Test crashed with signal trap", True),
    ("Fatal error: boom", True),
    ("Thread 0 Crashed:", True),
    ("** TEST EXECUTE FAILED **", True),
    ("::error::test command exceeded its time limit; saving process diagnostics", True),
    ("error: failed test runs: WSurf-Serial-2", True),
    ("ci-local: FAIL", True),
]


def check_console_filter(root: Path, env: dict[str, str]) -> None:
    fixture = root / "fixture.txt"
    fixture.write_bytes(("".join(line + "\n" for line, _ in FIXTURE)).encode() + b"\xff partial invalid utf8\n")
    raw = root / "console.raw.log"
    filtered_env = {**env, "WSURF_CI_RAW_LOG": str(raw)}
    result = watchdog(["cat", str(fixture)], root, filtered_env)
    assert result.returncode == 0, result
    assert raw.read_bytes() == fixture.read_bytes(), "raw log is not byte for byte the child's output"
    shown = result.stdout.splitlines()
    cursor = 0
    for line, kept in FIXTURE:
        if kept is None:
            continue
        if kept:
            expected = kept if isinstance(kept, str) else line
            assert expected in shown[cursor:], f"must-keep line missing or out of order: {expected!r}\n{result.stdout}"
            cursor = shown.index(expected, cursor) + 1
        else:
            assert line not in shown, f"noise line reached the console: {line!r}"
    assert any(line.startswith("filtered ") and "host-log lines" in line and str(raw) in line for line in shown), shown
    crash = shown.index("Restarting after unexpected exit, crash, or test timeout in X.y()")
    held = [shown.index(t) for t in ("◇ Test hanging() started.", "◇ Test gluedHang() started.", "◇ Test gluedHang2() started.")]
    assert held == sorted(held) and held[-1] < crash, "unsettled start lines (also the glued ones) must name the hung test before the crash"
    assert not any("slowButFine" in line and "started" in line for line in shown), "a settled start line was printed"
    # WSURF_CI_VERBOSE=1: raw log kept, console unfiltered.
    raw.unlink()
    verbose = watchdog(["cat", str(fixture)], root, {**filtered_env, "WSURF_CI_VERBOSE": "1"})
    assert NOISE_ONLY in verbose.stdout.splitlines() and raw.read_bytes() == fixture.read_bytes(), "verbose must print pure noise"
    # No raw log variable: the output is untouched.
    plain = watchdog(["cat", str(fixture)], root, env)
    assert NOISE_ONLY in plain.stdout.splitlines() and "filtered " not in plain.stdout
    # Exit code passes through, and a hung child prints its unsettled start line before the time-limit error, exit 124.
    raw.unlink()
    assert watchdog(["sh", "-c", "echo hi; exit 7"], root, filtered_env).returncode == 7
    hung = watchdog(["sh", "-c", "echo '◇ Test stuck() started.'; sleep 30"], root, filtered_env)
    assert hung.returncode == 124, hung
    out = hung.stdout.splitlines()
    assert "::error::test command exceeded its time limit; saving process diagnostics" in raw.read_text().splitlines(), "own line not in raw"
    # The child's last words while being stopped reach the console and the raw log (exit 124 path).
    raw.unlink()
    last_words = (
        "trap 'echo \"** TEST EXECUTE INTERRUPTED **\"; echo /p/x.xcresult; exit 143' TERM; "
        "echo '◇ Test stuck2() started.'; while :; do sleep 0.1; done"
    )
    interrupted = watchdog(["sh", "-c", last_words], root, filtered_env)
    assert interrupted.returncode == 124, interrupted
    for needed in ("** TEST EXECUTE INTERRUPTED **", "/p/x.xcresult", "◇ Test stuck2() started."):
        assert needed in interrupted.stdout.splitlines(), (needed, interrupted.stdout)
        assert needed in raw.read_text().splitlines(), (needed, raw.read_text())
    assert out.index("◇ Test stuck() started.") < next(i for i, l in enumerate(out) if l.startswith("::error::test command exceeded")), out


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in ("ps", "sample"):
            fake = bin_dir / name
            fake.write_text(f'#!/bin/sh\necho "{name} $*" >> "{root}/calls.log"\n')
            fake.chmod(0o755)
        # ci-local exports WSURF_CI_RAW_LOG; this check must not inherit any WSURF_CI_* setting (it would filter the "plain" case
        # and append to ci-local's real raw log).
        base = {k: v for k, v in os.environ.items() if not k.startswith("WSURF_CI_")}
        env = {**base, "PATH": f"{bin_dir}:{os.environ['PATH']}", "WSURF_CI_TEST_LIMIT_SECONDS": "2"}
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
            check_console_filter(root, env)
            if "WSURF_CHECK_WATCHDOG_INNER" not in os.environ:
                # As ci-local runs it: with WSURF_CI_RAW_LOG (and VERBOSE) in the environment. Must pass, and must leave that
                # raw log untouched.
                outer_raw = root / "outer.raw.log"
                outer_raw.write_text("untouched\n")
                inner = subprocess.run(
                    [sys.executable, __file__],
                    env={**os.environ, "WSURF_CHECK_WATCHDOG_INNER": "1", "WSURF_CI_RAW_LOG": str(outer_raw), "WSURF_CI_VERBOSE": "1"},
                    capture_output=True, text=True, timeout=120,
                )
                assert inner.returncode == 0, inner
                assert outer_raw.read_text() == "untouched\n", "the check wrote into the caller's raw log"
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
